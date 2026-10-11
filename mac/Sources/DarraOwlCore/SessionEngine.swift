import DarraOwlShared
import Foundation

/// What the helper reports to the app (and, from phase 3, to the phone).
public struct EngineStatus: Codable, Equatable, Sendable {
    public var now: Date
    public var session: Session?
    public var power: PowerSnapshot?
    public var settings: PowerSettings
    /// The journal holds a sleep entry: sleep is disabled by us or its undo is pending.
    public var sleepHeld: Bool
    /// The journal holds a Low Power Mode entry.
    public var lowPowerHeld: Bool
    /// Undo steps that failed and are retried.
    public var pendingUndo: [String]
    public var lastEnd: SessionEndRecord?
    /// Recent problems worth showing in the menu, newest last.
    public var notices: [String]
    public var uninstalling: Bool
}

public enum EngineError: Error, Equatable, Sendable, LocalizedError {
    case invalidDuration(min: TimeInterval, max: TimeInterval)
    case alreadyActive
    case noActiveSession
    case refused(SessionEndReason)
    case undoPending([String])
    case journal(String)
    case power(String)
    case invalidSettings(PowerSettings.ValidationError)
    case uninstalling

    public var errorDescription: String? {
        switch self {
        case let .invalidDuration(min, max):
            "Durée invalide : entre \(DurationText.short(min)) et \(DurationText.short(max))."
        case .alreadyActive: "Une session est déjà en cours."
        case .noActiveSession: "Aucune session en cours."
        case let .refused(reason): "Session refusée : \(reason.label.lowercased())."
        case let .undoPending(steps): "La session précédente n'est pas entièrement annulée : \(steps.joined(separator: " ; "))"
        case let .journal(m): "Journal : \(m)"
        case let .power(m): "Réglages d'alimentation : \(m)"
        case .invalidSettings: "Réglages invalides."
        case .uninstalling: "Désinstallation en cours."
        }
    }
}

/// The single source of truth for the session, its end time and the journal.
/// Runs inside the privileged helper. Every dependency is injected.
///
/// Invariants:
/// - sleep is disabled only while the journal holds a session with an end time;
/// - every change is in the journal on disk before it is made, and is undone
///   from the journal, never from memory alone;
/// - an entry leaves the journal only after its undo succeeded.
public actor SessionEngine {
    public struct Dependencies: Sendable {
        public var power: any PowerControlling
        public var source: any PowerSourceReading
        public var clock: any NowProviding
        public var journalStore: any ValueStoring<Journal>
        public var settingsStore: any ValueStoring<PowerSettings>
        public var log: any EngineLogging

        public init(
            power: any PowerControlling,
            source: any PowerSourceReading,
            clock: any NowProviding,
            journalStore: any ValueStoring<Journal>,
            settingsStore: any ValueStoring<PowerSettings>,
            log: any EngineLogging
        ) {
            self.power = power
            self.source = source
            self.clock = clock
            self.journalStore = journalStore
            self.settingsStore = settingsStore
            self.log = log
        }
    }

    public static let idlePollInterval: TimeInterval = 30
    public static let activePollInterval: TimeInterval = 10
    static let maxNotices = 5

    private let deps: Dependencies
    private var journal = Journal()
    private var settings = PowerSettings.default
    private var lastPower: PowerSnapshot?
    private var unreadableReads = 0
    private var pendingUndo: [String] = []
    private var notices: [String] = []
    private var uninstalling = false
    private var filesRemoved = false
    /// Low Power Mode was already on in both profiles when we wanted it: the
    /// user's, not ours. Not re-read until the floors stop asking for it.
    private var lowPowerAlreadyOn = false

    public init(_ deps: Dependencies) {
        self.deps = deps
    }

    // MARK: Lifecycle

    /// Runs once when the helper starts (boot, crash, update). Restores an
    /// expired or unreadable session, resumes a valid one.
    public func reconcile() async -> EngineStatus {
        loadSettings()
        do {
            journal = try deps.journalStore.load() ?? Journal()
        } catch {
            await recoverFromUnreadableJournal(error)
        }

        let now = deps.clock.now()
        if let session = journal.session {
            if session.isExpired(at: now) || session.endsAt > now.addingTimeInterval(Policy.absoluteMaxSessionDuration) {
                deps.log.info("reconcile: session \(session.id) is over, restoring")
                await end(reason: .expired)
            } else {
                deps.log.info("reconcile: resuming session ending \(session.endsAt)")
                await holdSleepForResumedSession()
            }
        } else if !journal.isClean {
            deps.log.info("reconcile: no session but the journal is not clean, restoring")
            _ = await undoAll()
        }
        return await evaluate()
    }

    /// Periodic and event-driven check: end time, battery, heat, retries.
    public func evaluate() async -> EngineStatus {
        let now = deps.clock.now()
        let snapshot = deps.source.read()
        lastPower = snapshot
        if case .unreadable = snapshot.battery { unreadableReads += 1 } else { unreadableReads = 0 }

        if let session = journal.session {
            if session.isExpired(at: now) {
                await end(reason: .expired)
            } else {
                let decision = FloorRules.decide(power: snapshot, unreadableReads: unreadableReads, settings: settings)
                if let reason = decision.endReason {
                    await end(reason: reason)
                } else {
                    await applyLowPower(wanted: decision.wantsLowPower)
                }
            }
        } else if !journal.isClean {
            _ = await undoAll()
        }
        return status()
    }

    /// The helper received SIGTERM (unregistered, shutdown, update).
    public func handleTermination() async {
        if journal.session != nil {
            await end(reason: .helperTerminated)
        } else if !journal.isClean {
            _ = await undoAll()
        }
    }

    /// Seconds until the next `evaluate()` is due.
    public func nextCheckDelay() -> TimeInterval {
        if let session = journal.session {
            let remaining = session.remaining(at: deps.clock.now())
            return min(Self.activePollInterval, max(0.2, remaining))
        }
        return journal.isClean ? Self.idlePollInterval : Self.activePollInterval
    }

    // MARK: Commands

    public func start(duration: TimeInterval, origin: SessionOrigin) async throws(EngineError) -> EngineStatus {
        guard !uninstalling else { throw .uninstalling }
        guard journal.session == nil else { throw .alreadyActive }
        if !journal.isClean {
            let failures = await undoAll()
            guard journal.isClean else { throw .undoPending(failures) }
        }
        guard duration >= Policy.minimumSessionDuration, duration <= settings.maxSessionDuration else {
            throw .invalidDuration(min: Policy.minimumSessionDuration, max: settings.maxSessionDuration)
        }
        let snapshot = deps.source.read()
        lastPower = snapshot
        if let reason = FloorRules.startRefusal(power: snapshot, settings: settings) {
            throw .refused(reason)
        }
        let state: PowerSettingsState
        do {
            state = try await deps.power.readState()
        } catch {
            throw .power(error.localizedDescription)
        }

        let now = deps.clock.now()
        let session = Session(startedAt: now, endsAt: now.addingTimeInterval(duration), origin: origin)
        journal.session = session
        journal.sleep = SleepEntry(previouslyDisabled: state.sleepDisabled)
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.session = nil
            journal.sleep = nil
            throw .journal(error.localizedDescription)
        }

        if !state.sleepDisabled {
            do {
                try await deps.power.setSleepDisabled(true)
            } catch {
                deps.log.error("start: disablesleep 1 failed: \(error.localizedDescription)")
                journal.session = nil
                // pmset may have gone through before failing: put sleep back.
                do {
                    try await deps.power.setSleepDisabled(false)
                    journal.sleep = nil
                } catch {
                    pendingUndo = ["Veille : \(error.localizedDescription)"]
                }
                persist()
                throw .power(error.localizedDescription)
            }
        }
        unreadableReads = 0
        deps.log.info("session \(session.id) started by \(origin.rawValue), ends \(session.endsAt)")
        return await evaluate()
    }

    /// Moves the end time later by `seconds`, never past now + the cap.
    public func extend(by seconds: TimeInterval) async throws(EngineError) -> EngineStatus {
        guard !uninstalling else { throw .uninstalling }
        let now = deps.clock.now()
        guard var session = journal.session, !session.isExpired(at: now) else { throw .noActiveSession }
        guard seconds > 0 else {
            throw .invalidDuration(min: Policy.minimumSessionDuration, max: settings.maxSessionDuration)
        }
        let previous = session.endsAt
        session.endsAt = min(max(session.endsAt, now).addingTimeInterval(seconds), now.addingTimeInterval(settings.maxSessionDuration))
        journal.session = session
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.session?.endsAt = previous
            throw .journal(error.localizedDescription)
        }
        deps.log.info("session \(session.id) now ends \(session.endsAt)")
        return status()
    }

    public func stop(reason: SessionEndReason) async throws(EngineError) -> EngineStatus {
        guard journal.session != nil else { throw .noActiveSession }
        await end(reason: reason)
        return status()
    }

    public func updateSettings(_ new: PowerSettings) async throws(EngineError) -> EngineStatus {
        do {
            try new.validate()
        } catch {
            throw .invalidSettings(error)
        }
        do {
            try deps.settingsStore.save(new)
        } catch {
            throw .journal(error.localizedDescription)
        }
        settings = new
        // A lower cap applies to the running session too.
        let now = deps.clock.now()
        if let session = journal.session, session.endsAt > now.addingTimeInterval(new.maxSessionDuration) {
            journal.session?.endsAt = now.addingTimeInterval(new.maxSessionDuration)
            persist()
        }
        return await evaluate()
    }

    /// Ends any session, undoes everything and, once the journal is clean,
    /// deletes the helper's files. Refuses new sessions from then on.
    public func prepareUninstall() async -> EngineStatus {
        uninstalling = true
        if journal.session != nil {
            await end(reason: .uninstall)
        } else if !journal.isClean {
            _ = await undoAll()
        }
        if journal.isClean {
            do {
                try deps.journalStore.remove()
                try deps.settingsStore.remove()
                filesRemoved = true
            } catch {
                addNotice("Fichiers du composant système : \(error.localizedDescription)")
            }
        }
        return status()
    }

    public func status() -> EngineStatus {
        EngineStatus(
            now: deps.clock.now(),
            session: journal.session,
            power: lastPower,
            settings: settings,
            sleepHeld: journal.sleep != nil,
            lowPowerHeld: journal.lowPower != nil,
            pendingUndo: pendingUndo,
            lastEnd: journal.lastEnd,
            notices: notices,
            uninstalling: uninstalling
        )
    }

    // MARK: Private

    private func end(reason: SessionEndReason) async {
        guard let session = journal.session else { return }
        let now = deps.clock.now()
        journal.session = nil
        journal.lastEnd = SessionEndRecord(sessionID: session.id, startedAt: session.startedAt, endedAt: now, reason: reason, failures: [])
        persist()
        let failures = await undoAll()
        journal.lastEnd?.failures = failures
        persist()
        lowPowerAlreadyOn = false
        deps.log.info("session \(session.id) ended (\(reason.rawValue))\(failures.isEmpty ? "" : ", undo incomplete: \(failures)")")
    }

    /// Undoes every journaled change, sleep first. Returns the steps that
    /// failed; their entries stay in the journal for the next try.
    private func undoAll() async -> [String] {
        var failures: [String] = []
        if let entry = journal.sleep {
            do {
                if !entry.previouslyDisabled {
                    try await deps.power.setSleepDisabled(false)
                }
                journal.sleep = nil
                persist()
                deps.log.info("sleep restored")
            } catch {
                failures.append("Veille : \(error.localizedDescription)")
                deps.log.error("sleep restore failed: \(error.localizedDescription)")
            }
        }
        if let entry = journal.lowPower {
            do {
                try await deps.power.setLowPowerMode(onBattery: entry.previousOnBattery, onAC: entry.previousOnAC)
                journal.lowPower = nil
                persist()
                deps.log.info("low power mode restored")
            } catch {
                failures.append("Mode économie d'énergie : \(error.localizedDescription)")
                deps.log.error("low power restore failed: \(error.localizedDescription)")
            }
        }
        pendingUndo = failures
        return failures
    }

    private func applyLowPower(wanted: Bool) async {
        if !wanted {
            lowPowerAlreadyOn = false
            guard let entry = journal.lowPower else { return }
            do {
                try await deps.power.setLowPowerMode(onBattery: entry.previousOnBattery, onAC: entry.previousOnAC)
                journal.lowPower = nil
                persist()
                deps.log.info("low power mode no longer needed, restored")
            } catch {
                deps.log.error("low power restore failed: \(error.localizedDescription)")
            }
            return
        }
        guard journal.lowPower == nil, !lowPowerAlreadyOn else { return }
        let state: PowerSettingsState
        do {
            state = try await deps.power.readState()
        } catch {
            deps.log.error("low power: cannot read pmset: \(error.localizedDescription)")
            return
        }
        if state.lowPowerOnBattery, state.lowPowerOnAC {
            lowPowerAlreadyOn = true
            return
        }
        let entry = LowPowerEntry(previousOnBattery: state.lowPowerOnBattery, previousOnAC: state.lowPowerOnAC)
        journal.lowPower = entry
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.lowPower = nil
            addNotice("Mode économie d'énergie non activé : journal non écrit")
            return
        }
        do {
            try await deps.power.setLowPowerMode(onBattery: true, onAC: true)
            deps.log.info("low power mode on")
        } catch {
            deps.log.error("low power on failed: \(error.localizedDescription)")
            do {
                try await deps.power.setLowPowerMode(onBattery: entry.previousOnBattery, onAC: entry.previousOnAC)
                journal.lowPower = nil
                persist()
            } catch {
                // Entry stays; the end of the session retries the undo.
            }
        }
    }

    private func holdSleepForResumedSession() async {
        let state: PowerSettingsState
        do {
            state = try await deps.power.readState()
        } catch {
            addNotice("Impossible de lire l'état de la veille : \(error.localizedDescription)")
            return
        }
        if journal.sleep == nil {
            journal.sleep = SleepEntry(previouslyDisabled: state.sleepDisabled)
            do {
                try deps.journalStore.save(journal)
            } catch {
                journal.sleep = nil
                addNotice("Session reprise sans veille désactivée : journal non écrit")
                return
            }
        }
        guard !state.sleepDisabled else { return }
        do {
            try await deps.power.setSleepDisabled(true)
        } catch {
            addNotice("Session reprise mais la veille n'a pas pu être désactivée : \(error.localizedDescription)")
        }
    }

    private func recoverFromUnreadableJournal(_ error: Error) async {
        deps.log.error("journal unreadable: \(error.localizedDescription)")
        let moved = try? deps.journalStore.quarantine()
        addNotice("Journal illisible, mis de côté\(moved.map { " : \($0)" } ?? "")")
        journal = Journal()
        // What it held is unknown. Sleep is the one change that must not
        // outlive a session, so a disabled sleep is put back.
        if let state = try? await deps.power.readState(), state.sleepDisabled {
            journal.sleep = SleepEntry(previouslyDisabled: false)
            persist()
            _ = await undoAll()
        }
    }

    private func loadSettings() {
        do {
            let loaded = try deps.settingsStore.load() ?? .default
            try loaded.validate()
            settings = loaded
        } catch {
            settings = .default
            addNotice("Réglages illisibles, valeurs par défaut utilisées")
            _ = try? deps.settingsStore.quarantine()
        }
    }

    /// Saves the journal where a failure must not stop an undo in progress.
    private func persist() {
        guard !filesRemoved else { return }
        do {
            try deps.journalStore.save(journal)
        } catch {
            addNotice("Journal non écrit : \(error.localizedDescription)")
            deps.log.error("journal write failed: \(error.localizedDescription)")
        }
    }

    private func addNotice(_ text: String) {
        notices.append(text)
        if notices.count > Self.maxNotices { notices.removeFirst(notices.count - Self.maxNotices) }
    }
}
