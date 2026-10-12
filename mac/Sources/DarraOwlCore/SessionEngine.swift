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
    /// Processes paused at lid close.
    public var frozen: [FrozenProcess]
    /// Brightness and sound saved at lid close, for the app to restore.
    public var userChanges: UserChanges
    /// Recent problems worth showing in the menu, newest last.
    public var notices: [String]
    public var uninstalling: Bool
    /// The external display as the helper knows it: forgotten when it
    /// restarts, so the app tells it again (nil: an older helper).
    public var externalDisplay: Bool? = nil
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
    case processGone
    case notYourProcess
    case tooManyWatched

    public var errorDescription: String? {
        switch self {
        case let .invalidDuration(min, max):
            "Durée invalide : entre \(DurationText.short(min)) et \(DurationText.short(max))."
        case .alreadyActive: "Une session est déjà en cours."
        case .noActiveSession: "Aucune session en cours."
        case let .refused(reason): "Session refusée : \(reason.inlineLabel)."
        case let .undoPending(steps): "La session précédente n'est pas entièrement annulée : \(steps.joined(separator: " ; "))"
        case let .journal(m): "Journal : \(m)"
        case let .power(m): "Réglages d'alimentation : \(m)"
        case .invalidSettings: "Réglages invalides."
        case .uninstalling: "Désinstallation en cours."
        case .processGone: "Ce processus ne tourne plus."
        case .notYourProcess: "Ce processus appartient à un autre utilisateur."
        case .tooManyWatched: "Trop de processus suivis dans cette session."
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
        public var processes: any ProcessControlling
        public var clock: any NowProviding
        public var journalStore: any ValueStoring<Journal>
        public var settingsStore: any ValueStoring<PowerSettings>
        public var log: any EngineLogging
        /// `kern.bootsessionuuid` of this boot ("" when unknown): a session
        /// journaled under another boot does not survive the restart.
        public var bootSession: String

        public init(
            power: any PowerControlling,
            source: any PowerSourceReading,
            processes: any ProcessControlling,
            clock: any NowProviding,
            journalStore: any ValueStoring<Journal>,
            settingsStore: any ValueStoring<PowerSettings>,
            log: any EngineLogging,
            bootSession: String = ""
        ) {
            self.power = power
            self.source = source
            self.processes = processes
            self.clock = clock
            self.journalStore = journalStore
            self.settingsStore = settingsStore
            self.log = log
            self.bootSession = bootSession
        }
    }

    public static let idlePollInterval: TimeInterval = 30
    public static let activePollInterval: TimeInterval = 10
    static let maxNotices = 5
    public static let maxWatched = 16
    /// A lid state counts once it held this long: a lid closed slowly or a
    /// laptop moved while closing makes the sensor bounce for a few seconds.
    public static let lidSettle: TimeInterval = 2

    private let deps: Dependencies
    private var journal = Journal()
    private var settings = PowerSettings.default
    private var lastPower: PowerSnapshot?
    /// Last raw lid reading and when it started.
    private var lidRaw: (closed: Bool?, since: Date)?
    /// The lid state the rules and the status use.
    private var lidSettled: Bool?
    private var lidKnown = false
    /// The settled lid state at the previous check, to see it open.
    private var lidAtLastCheck: Bool?
    /// An external display is on, as the app last said (memory only).
    private var externalDisplay = false
    /// Since when the battery level has been unreadable (on battery or not).
    private var unreadableSince: Date?
    /// An unreadable level ends a session on battery once it lasted this long:
    /// a single IOKit miss is tolerated, however close the next check is.
    static let unreadableGrace: TimeInterval = 10
    private var pendingUndo: [String] = []
    private var notices: [String] = []
    /// Set by `prepareUninstall`: new sessions are refused for a while. An
    /// uninstall that stopped halfway does not block DarraOwl for good.
    private var uninstallingSince: Date?
    static let uninstallWindow: TimeInterval = 15 * 60
    private var filesRemoved = false
    /// Low Power Mode is left alone while the floors ask for it: it was
    /// already on in both profiles (the user's, not ours), or this Mac does
    /// not report a plain lowpowermode. Not re-read until they stop asking.
    private var lowPowerLeftAlone = false
    /// Switching Low Power Mode on failed: not retried for a while.
    private var lowPowerFailedAt: Date?
    static let lowPowerRetryDelay: TimeInterval = 5 * 60

    public init(_ deps: Dependencies) {
        self.deps = deps
    }

    // MARK: One request at a time

    /// Every change awaits pmset, and an actor lets another call in at each
    /// await: two requests could then both start a session, or undo and
    /// redo the same setting. Public entry points take their turn here;
    /// internal steps never call a public entry point.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            // The turn passes on: busy stays true.
            waiting.removeFirst().resume()
        }
    }

    private var uninstalling: Bool {
        guard let since = uninstallingSince else { return false }
        return deps.clock.now().timeIntervalSince(since) < Self.uninstallWindow
    }

    // MARK: Lifecycle

    /// Runs once when the helper starts (boot, crash, update). Restores an
    /// expired or unreadable session, or one from before a restart; resumes
    /// a valid one after a helper crash or update.
    public func reconcile() async -> EngineStatus {
        await enter()
        defer { leave() }
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
            } else if let boot = journal.bootSession, !deps.bootSession.isEmpty, boot != deps.bootSession {
                // Safety rule 3: after a restart (panic, power loss, forced
                // shutdown) sleep is back at startup, whatever the end time.
                deps.log.info("reconcile: session \(session.id) began before a restart, restoring")
                await end(reason: .macRestarted)
            } else {
                deps.log.info("reconcile: resuming session ending \(session.endsAt)")
                await holdSleepForResumedSession()
            }
        } else if !journal.isClean {
            deps.log.info("reconcile: no session but the journal is not clean, restoring")
            _ = await undoAll()
        }
        return await evaluateLocked()
    }

    /// Periodic and event-driven check: end time, battery, heat, retries.
    public func evaluate() async -> EngineStatus {
        await enter()
        defer { leave() }
        return await evaluateLocked()
    }

    private func evaluateLocked() async -> EngineStatus {
        let now = deps.clock.now()
        var snapshot = deps.source.read()
        snapshot.lidClosed = settledLid(snapshot.lidClosed, now: now)
        lastPower = snapshot
        // The lid opened: apps paused at its close start again here too, so
        // they do not stay stopped when the app crashed or was quit.
        if lidAtLastCheck == true, snapshot.lidClosed == false, !journal.frozen.isEmpty {
            deps.log.info("lid opened: resuming paused apps")
            let failures = resumeFrozen(onlyBundleID: nil)
            if !failures.isEmpty { addNotice(failures.joined(separator: " ; ")) }
        }
        lidAtLastCheck = snapshot.lidClosed
        if case .unreadable = snapshot.battery {
            if unreadableSince == nil { unreadableSince = now }
        } else {
            unreadableSince = nil
        }
        // FloorRules counts misses: one is tolerated, a lasting one is not.
        let unreadableReads = unreadableSince.map { now.timeIntervalSince($0) >= Self.unreadableGrace ? FloorRules.unreadableReadsBeforeEnd : 1 } ?? 0

        // The clock moved back: the end time stays within the cap from now.
        if var session = journal.session, session.endsAt > now.addingTimeInterval(settings.maxSessionDuration) {
            session.endsAt = now.addingTimeInterval(settings.maxSessionDuration)
            if let keep = session.keepUntil, keep > session.endsAt { session.keepUntil = session.endsAt }
            journal.session = session
            persist()
        }
        if let session = journal.session {
            if session.isExpired(at: now) {
                await end(reason: .expired)
            } else {
                let decision = FloorRules.decide(power: snapshot, unreadableReads: unreadableReads, settings: settings, docked: externalDisplay)
                if let reason = decision.endReason {
                    await end(reason: reason)
                } else if await followWatched() {
                    await applyLowPower(wanted: decision.wantsLowPower)
                }
            }
        } else if !journal.isClean {
            _ = await undoAll()
        }
        return status()
    }

    /// The helper received SIGTERM (unregistered, shutdown, update). The turn
    /// is never given back: the process exits right after, and no request
    /// queued meanwhile runs against a machine being restored.
    public func handleTermination() async {
        await enter()
        if journal.session != nil {
            await end(reason: .helperTerminated)
        } else if !journal.isClean {
            _ = await undoAll()
        }
    }

    /// Seconds until the next `evaluate()` is due.
    public func nextCheckDelay() -> TimeInterval {
        if let session = journal.session {
            let now = deps.clock.now()
            var delay = min(Self.activePollInterval, max(0.2, session.remaining(at: now)))
            // A lid change waiting to settle is looked at as soon as it may.
            if let raw = lidRaw, raw.closed != lidSettled {
                delay = min(delay, max(0.2, Self.lidSettle - now.timeIntervalSince(raw.since) + 0.1))
            }
            return delay
        }
        return journal.isClean ? Self.idlePollInterval : Self.activePollInterval
    }

    /// For a restart (update): true when nothing is held, and then the turn
    /// is kept, so no request can start anything before the process exits.
    public func shutDownIfIdle() async -> Bool {
        await enter()
        if journal.session == nil, journal.isClean { return true }
        leave()
        return false
    }

    /// The app saw an external display come or go.
    public func setExternalDisplay(_ on: Bool) async -> EngineStatus {
        await enter()
        defer { leave() }
        guard on != externalDisplay else { return status() }
        externalDisplay = on
        return await evaluateLocked()
    }

    /// The user who started the running session, when known.
    public func sessionOwner() -> UInt32? {
        journal.session == nil ? nil : journal.ownerUID
    }

    // MARK: Commands

    /// `requesterUID`: the user who asked (nil: the helper itself or a test).
    public func start(duration: TimeInterval, origin: SessionOrigin, requesterUID: UInt32? = nil) async throws(EngineError) -> EngineStatus {
        await enter()
        defer { leave() }
        return try await startLocked(duration: duration, origin: origin, watching: [], owner: requesterUID)
    }

    private func startLocked(
        duration: TimeInterval, origin: SessionOrigin, watching: [WatchedProcess], owner: UInt32?
    ) async throws(EngineError) -> EngineStatus {
        guard !uninstalling else { throw .uninstalling }
        await endIfExpired()
        guard journal.session == nil else { throw .alreadyActive }
        if !journal.isClean {
            let failures = await undoAll()
            guard journal.isClean else { throw .undoPending(failures) }
        }
        guard duration >= Policy.minimumSessionDuration, duration <= settings.maxSessionDuration else {
            throw .invalidDuration(min: Policy.minimumSessionDuration, max: settings.maxSessionDuration)
        }
        var snapshot = deps.source.read()
        snapshot.lidClosed = settledLid(snapshot.lidClosed, now: deps.clock.now())
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
        let session = Session(startedAt: now, endsAt: now.addingTimeInterval(duration), origin: origin, watching: watching)
        journal.session = session
        journal.sleep = SleepEntry(previouslyDisabled: state.sleepDisabled)
        journal.bootSession = deps.bootSession.isEmpty ? nil : deps.bootSession
        journal.ownerUID = owner
        // An uninstall that stopped halfway removed the files: they are
        // written again from now on (start is refused during the uninstall).
        filesRemoved = false
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.session = nil
            journal.sleep = nil
            journal.bootSession = nil
            journal.ownerUID = nil
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
        unreadableSince = nil
        deps.log.info("session \(session.id) started by \(origin.rawValue), ends \(session.endsAt)\(watching.isEmpty ? "" : ", following \(watching.map(\.pid))")")
        return await evaluateLocked()
    }

    /// A session past its end that the loop has not ended yet is ended now,
    /// so a new request does not meet it.
    private func endIfExpired() async {
        if let session = journal.session, session.isExpired(at: deps.clock.now()) {
            await end(reason: .expired)
        }
    }

    /// Moves the end time later by `seconds`, never past now + the cap.
    public func extend(by seconds: TimeInterval) async throws(EngineError) -> EngineStatus {
        await enter()
        defer { leave() }
        guard !uninstalling else { throw .uninstalling }
        await endIfExpired()
        let now = deps.clock.now()
        guard var session = journal.session, !session.isExpired(at: now) else { throw .noActiveSession }
        guard seconds > 0 else {
            throw .invalidDuration(min: Policy.minimumSessionDuration, max: settings.maxSessionDuration)
        }
        let previous = session.endsAt
        let previousKeep = session.keepUntil
        session.endsAt = Session.extendedEnd(session.endsAt, by: seconds, now: now, maxDuration: settings.maxSessionDuration)
        // A timed session an agent joined: its own planned end moves too.
        if let keep = session.keepUntil {
            session.keepUntil = min(max(keep, now).addingTimeInterval(seconds), session.endsAt)
        } else if session.isAgentMode {
            // Agents only: "+1 h" keeps the Mac awake at least that long,
            // even if they finish sooner.
            session.keepUntil = min(now.addingTimeInterval(seconds), session.endsAt)
        }
        journal.session = session
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.session?.endsAt = previous
            journal.session?.keepUntil = previousKeep
            throw .journal(error.localizedDescription)
        }
        deps.log.info("session \(session.id) now ends \(session.endsAt)")
        return status()
    }

    public func stop(reason: SessionEndReason) async throws(EngineError) -> EngineStatus {
        await enter()
        defer { leave() }
        guard journal.session != nil else { throw .noActiveSession }
        await end(reason: reason)
        return status()
    }

    /// Ends any session (everything undone), then puts the Mac to sleep.
    public func sleepNow() async throws(EngineError) -> EngineStatus {
        await enter()
        defer { leave() }
        if journal.session != nil {
            await end(reason: .sleepRequested)
        }
        do {
            try await deps.power.sleepNow()
        } catch {
            throw .power(error.localizedDescription)
        }
        deps.log.info("sleep requested")
        return status()
    }

    public func updateSettings(_ new: PowerSettings) async throws(EngineError) -> EngineStatus {
        await enter()
        defer { leave() }
        guard !uninstalling else { throw .uninstalling }
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
            let end = now.addingTimeInterval(new.maxSessionDuration)
            journal.session?.endsAt = end
            if let keep = session.keepUntil, keep > end { journal.session?.keepUntil = end }
            persist()
        }
        return await evaluateLocked()
    }

    /// Ends any session, undoes everything and, once the journal is clean,
    /// deletes the helper's files. Refuses new sessions from then on.
    public func prepareUninstall() async -> EngineStatus {
        await enter()
        defer { leave() }
        uninstallingSince = deps.clock.now()
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

    // MARK: Agent mode

    /// Keeps the Mac awake while `process` runs, at most `seconds` (the cap
    /// when nil). Starts a session, or makes the running one follow the
    /// process too: it then lasts until its own end or the process exit,
    /// whichever is later, never past the cap (safety rule 2).
    public func watch(
        _ process: WatchedProcess, seconds: TimeInterval?, origin: SessionOrigin, requesterUID: UInt32
    ) async throws(EngineError) -> EngineStatus {
        await enter()
        defer { leave() }
        guard !uninstalling else { throw .uninstalling }
        guard process.pid > 1, case let .present(state) = deps.processes.lookup(process.pid), Self.matches(process, state) else {
            throw .processGone
        }
        guard state.uid == requesterUID else { throw .notYourProcess }
        let cap = settings.maxSessionDuration
        let duration = seconds ?? cap
        guard duration >= Policy.minimumSessionDuration, duration <= cap else {
            throw .invalidDuration(min: Policy.minimumSessionDuration, max: cap)
        }
        await endIfExpired()
        let now = deps.clock.now()
        guard var session = journal.session else {
            return try await startLocked(duration: duration, origin: origin, watching: [process], owner: requesterUID)
        }
        let previous = session
        session.watching.removeAll { $0.pid == process.pid }
        guard session.watching.count < Self.maxWatched else { throw .tooManyWatched }
        if session.watching.isEmpty, session.keepUntil == nil, !previous.isAgentMode {
            session.keepUntil = session.endsAt
        }
        session.watching.append(process)
        session.endsAt = min(max(session.endsAt, now.addingTimeInterval(duration)), now.addingTimeInterval(cap))
        journal.session = session
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.session = previous
            throw .journal(error.localizedDescription)
        }
        deps.log.info("session \(session.id) now follows pid \(process.pid) (\(process.name)), ends at the latest \(session.endsAt)")
        return status()
    }

    /// The CLI's command finished: stop following its process now rather
    /// than at the next check.
    public func release(pid: Int32) async -> EngineStatus {
        await enter()
        defer { leave() }
        guard var session = journal.session, session.watching.contains(where: { $0.pid == pid }) else { return status() }
        session.watching.removeAll { $0.pid == pid }
        await settle(session)
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
            frozen: journal.frozen,
            userChanges: journal.user,
            notices: notices,
            uninstalling: uninstalling,
            externalDisplay: externalDisplay
        )
    }

    // MARK: Lid close

    /// Journals the brightness and sound values the app is about to change.
    /// The app changes them only after this returned.
    public func recordUserChanges(_ changes: UserChanges) async throws(EngineError) -> EngineStatus {
        await enter()
        defer { leave() }
        guard journal.session != nil else { throw .noActiveSession }
        let previous = journal.user
        journal.user.merge(changes)
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.user = previous
            throw .journal(error.localizedDescription)
        }
        return status()
    }

    /// The app restored these values.
    public func clearUserChanges(_ kinds: [UserChangeKind]) async -> EngineStatus {
        await enter()
        defer { leave() }
        for kind in kinds {
            switch kind {
            case .display: journal.user.displayBrightness = nil
            case .keyboard: journal.user.keyboardBrightness = nil
            case let .audio(uid): journal.user.audio.removeAll { $0.deviceUID == uid }
            }
        }
        persist()
        return status()
    }

    /// Pauses processes of the requesting user. Each one is checked against
    /// the identity the app read, journaled, and only then sent SIGSTOP.
    /// Root processes, other users' processes, already stopped processes and
    /// changed identities are skipped.
    public func freeze(_ groups: [FreezeGroup], requesterUID: UInt32) async throws(EngineError) -> EngineStatus {
        await enter()
        defer { leave() }
        guard !uninstalling else { throw .uninstalling }
        guard journal.session != nil else { throw .noActiveSession }
        guard requesterUID != 0 else { return status() }

        var candidates: [FrozenProcess] = []
        let known = Set(journal.frozen.map(\.pid))
        for group in groups {
            guard group.bundleID == PausePolicy.dockerBundleID || !PausePolicy.isProtected(group.bundleID) else {
                deps.log.error("freeze: refused protected app \(group.bundleID)")
                continue
            }
            for target in group.targets where target.pid > 1 && !known.contains(target.pid) {
                guard case let .present(state) = deps.processes.lookup(target.pid),
                      state.uid == requesterUID, !state.stopped, state.identity == target.identity
                else { continue }
                candidates.append(FrozenProcess(pid: target.pid, identity: target.identity, bundleID: group.bundleID, name: group.name))
            }
        }
        guard !candidates.isEmpty else { return status() }

        journal.frozen += candidates
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.frozen.removeAll { p in candidates.contains(p) }
            throw .journal(error.localizedDescription)
        }

        var notStopped: [FrozenProcess] = []
        for p in candidates {
            // The identity is checked again right before the signal.
            guard case let .present(state) = deps.processes.lookup(p.pid), state.identity == p.identity,
                  deps.processes.signal(p.pid, SIGSTOP) == 0
            else {
                notStopped.append(p)
                continue
            }
        }
        if !notStopped.isEmpty {
            journal.frozen.removeAll { notStopped.contains($0) }
            persist()
        }
        let names = Set(candidates.filter { !notStopped.contains($0) }.map(\.name)).sorted()
        deps.log.info("paused \(candidates.count - notStopped.count) process(es): \(names.joined(separator: ", "))")
        return status()
    }

    /// Resumes paused processes: all of them (lid open), or one app's.
    public func resume(onlyBundleID: String? = nil) async -> EngineStatus {
        await enter()
        defer { leave() }
        let failures = resumeFrozen(onlyBundleID: onlyBundleID)
        if !failures.isEmpty { addNotice(failures.joined(separator: " ; ")) }
        return status()
    }

    // MARK: Private

    /// The first reading counts at once; a change counts once it held
    /// `lidSettle` seconds.
    private func settledLid(_ raw: Bool?, now: Date) -> Bool? {
        if lidRaw == nil || lidRaw?.closed != raw { lidRaw = (raw, now) }
        // Without a session nothing acts on the lid: the reading counts at
        // once, so a session started right after opening it sees it open.
        if journal.session == nil {
            lidKnown = true
            lidSettled = raw
            return raw
        }
        if !lidKnown {
            lidKnown = true
            lidSettled = raw
        } else if let r = lidRaw, now.timeIntervalSince(r.since) >= Self.lidSettle {
            lidSettled = r.closed
        }
        return lidSettled
    }

    static func matches(_ p: WatchedProcess, _ state: ProcessState) -> Bool {
        state.identity.startSeconds == p.startSeconds && state.identity.startMicros == p.startMicros
    }

    /// Drops the watched processes that exited. Returns false when that
    /// ended the session.
    private func followWatched() async -> Bool {
        guard var session = journal.session, session.isAgentMode else { return true }
        let running = session.watching.filter { p in
            switch deps.processes.lookup(p.pid) {
            case .absent: false
            // Nothing can be concluded: keep following it.
            case .unreadable: true
            case let .present(state): Self.matches(p, state)
            }
        }
        guard running.count != session.watching.count else { return true }
        session.watching = running
        await settle(session)
        return journal.session != nil
    }

    /// After a watched process left: keep following the others, go back to
    /// the planned end of a timed session, or end.
    private func settle(_ updated: Session) async {
        var session = updated
        let now = deps.clock.now()
        if !session.watching.isEmpty {
            journal.session = session
            persist()
            return
        }
        if let keep = session.keepUntil, keep > now {
            session.endsAt = min(session.endsAt, keep)
            session.keepUntil = nil
            journal.session = session
            persist()
            deps.log.info("session \(session.id): agents done, back to its planned end \(session.endsAt)")
            return
        }
        journal.session = session
        await end(reason: .agentFinished)
    }

    /// SIGCONT to each journaled process that is still the one we stopped.
    /// A process that exited, or whose pid now belongs to another process or
    /// to an earlier boot, is dropped without a signal.
    private func resumeFrozen(onlyBundleID: String?) -> [String] {
        var failures: [String] = []
        var kept: [FrozenProcess] = []
        var resumed = 0
        for p in journal.frozen {
            if let only = onlyBundleID, p.bundleID != only {
                kept.append(p)
                continue
            }
            switch deps.processes.lookup(p.pid) {
            case .absent:
                continue
            case .unreadable:
                kept.append(p)
                failures.append("\(p.name) (pid \(p.pid)) : état illisible")
            case let .present(state):
                guard state.identity == p.identity else { continue }
                if deps.processes.signal(p.pid, SIGCONT) == 0 {
                    resumed += 1
                } else {
                    kept.append(p)
                    failures.append("\(p.name) (pid \(p.pid)) : reprise refusée")
                }
            }
        }
        if kept != journal.frozen {
            journal.frozen = kept
            persist()
        }
        if resumed > 0 { deps.log.info("resumed \(resumed) process(es)") }
        return failures
    }

    private func end(reason: SessionEndReason) async {
        guard let session = journal.session else { return }
        let now = deps.clock.now()
        journal.session = nil
        journal.bootSession = nil
        journal.ownerUID = nil
        journal.lastEnd = SessionEndRecord(sessionID: session.id, startedAt: session.startedAt, endedAt: now, reason: reason, failures: [])
        persist()
        let failures = await undoAll()
        journal.lastEnd?.failures = failures
        persist()
        lowPowerLeftAlone = false
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
        failures += resumeFrozen(onlyBundleID: nil)
        pendingUndo = failures
        return failures
    }

    private func applyLowPower(wanted: Bool) async {
        if !wanted {
            lowPowerLeftAlone = false
            lowPowerFailedAt = nil
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
        guard journal.lowPower == nil, !lowPowerLeftAlone, !uninstalling else { return }
        if let failed = lowPowerFailedAt, deps.clock.now().timeIntervalSince(failed) < Self.lowPowerRetryDelay { return }
        let state: PowerSettingsState
        do {
            state = try await deps.power.readState()
        } catch {
            deps.log.error("low power: cannot read pmset: \(error.localizedDescription)")
            lowPowerFailedAt = deps.clock.now()
            return
        }
        // This Mac does not report a plain lowpowermode: left alone.
        guard let onAC = state.lowPowerOnAC else {
            lowPowerLeftAlone = true
            return
        }
        if onAC, state.lowPowerOnBattery ?? true {
            lowPowerLeftAlone = true
            return
        }
        let entry = LowPowerEntry(previousOnBattery: state.lowPowerOnBattery, previousOnAC: onAC)
        journal.lowPower = entry
        do {
            try deps.journalStore.save(journal)
        } catch {
            journal.lowPower = nil
            addNotice("Mode économie d'énergie non activé : journal non écrit")
            return
        }
        do {
            try await deps.power.setLowPowerMode(onBattery: state.lowPowerOnBattery == nil ? nil : true, onAC: true)
            deps.log.info("low power mode on")
        } catch {
            deps.log.error("low power on failed: \(error.localizedDescription)")
            lowPowerFailedAt = deps.clock.now()
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
        let moved = (try? deps.journalStore.quarantine()) ?? nil
        addNotice(moved.map { "Journal illisible, mis de côté : \($0)" } ?? "Journal illisible")
        journal = Journal()
        // What it held is unknown. Sleep is the one change that must not
        // outlive a session: unless pmset says it is enabled, it is put back,
        // journaled first so a failure is retried like any other undo.
        let disabled = (try? await deps.power.readState())?.sleepDisabled ?? true
        guard disabled else { return }
        journal.sleep = SleepEntry(previouslyDisabled: false)
        persist()
        _ = await undoAll()
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
        // While an uninstall is under way the files stay deleted.
        guard !(filesRemoved && uninstalling) else { return }
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
