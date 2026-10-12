import DarraOwlShared
import Foundation

// MARK: Dependencies of the lid-close actions (live ones in DarraOwlSystem)

/// Built-in display brightness. Live: private DisplayServices, behind a
/// macOS version guard.
@MainActor
public protocol DisplayDimming: AnyObject {
    func readBrightness() throws -> Float
    func setBrightness(_ value: Float) throws
    /// Best effort `IORequestIdle`, what `pmset displaysleepnow` does.
    func requestSleep()
    /// Declares user activity so a sleeping display wakes.
    func wake()
    func isAsleep() -> Bool
    /// The built-in panel is online (false: lid closed with an external display).
    func builtInOnline() -> Bool
}

/// Public display sleep request (`IORequestIdle`, what `pmset
/// displaysleepnow` does). Works on every macOS; powerd defers it about 30 s
/// after a wake, and the lid closing is such a wake.
@MainActor
public protocol DisplaySleepRequesting: AnyObject {
    func requestSleep()
}

/// Built-in keyboard backlight. Live: private CoreBrightness, behind a
/// method signature guard.
@MainActor
public protocol KeyboardBacklighting: AnyObject {
    /// nil when there is no built-in backlight.
    func readBrightness() throws -> Float?
    func setBrightness(_ value: Float) throws
}

public struct AudioOutput: Equatable, Sendable {
    public var deviceUID: String
    public var name: String?
    public var volume: Float
    public var muted: Bool

    public init(deviceUID: String, name: String?, volume: Float, muted: Bool) {
        self.deviceUID = deviceUID
        self.name = name
        self.volume = volume
        self.muted = muted
    }
}

/// The device a journal entry names is not connected.
public struct AudioDeviceMissing: Error, Equatable, Sendable {
    public let deviceUID: String
    public init(deviceUID: String) { self.deviceUID = deviceUID }
}

@MainActor
public protocol AudioControlling: AnyObject {
    func readDefaultOutput() throws -> AudioOutput
    func mute(deviceUID: String) throws
    /// Throws `AudioDeviceMissing` when no connected device has this UID.
    func apply(volume: Float, muted: Bool, deviceUID: String) throws
}

public struct RunningApp: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    public var name: String

    public init(pid: Int32, bundleID: String, name: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
    }
}

@MainActor
public protocol ProcessSnapshotting: AnyObject {
    func runningApps() -> [RunningApp]
    /// Every process, keyed by pid.
    func processTable() -> [Int32: ProcessState]
    var currentUID: UInt32 { get }
}

@MainActor
public protocol DockerProbing: AnyObject {
    /// True only on a clean, empty `docker ps -q` from Docker Desktop's own socket.
    func isIdle() async throws -> Bool
}

/// The requests the coordinator sends to the helper.
@MainActor
public protocol LidHelperGateway: AnyObject {
    func recordUserChanges(_ changes: UserChanges) async throws -> EngineStatus
    func clearUserChanges(_ kinds: [UserChangeKind]) async throws -> EngineStatus
    func freeze(_ groups: [FreezeGroup]) async throws -> EngineStatus
    func resume(bundleID: String?) async throws -> EngineStatus
    func lidChanged() async throws -> EngineStatus
}

// MARK: Coordinator

/// Runs the lid-close actions in the app (they belong to the user's session)
/// with every value journaled by the helper first. Lid open, session end and
/// app launch put them back from the journal, never from memory.
@MainActor
public final class LidCoordinator {
    public struct Dependencies {
        public var display: (any DisplayDimming)?
        public var keyboard: (any KeyboardBacklighting)?
        /// Always present, even where the private brightness calls are refused.
        public var displaySleep: (any DisplaySleepRequesting)?
        public var audio: any AudioControlling
        public var processes: any ProcessSnapshotting
        public var docker: any DockerProbing
        public var helper: any LidHelperGateway
        public var log: any EngineLogging
        public var sleep: (Duration) async -> Void
        /// An external display is on: the lid is closed on a docked Mac.
        public var externalDisplayActive: () -> Bool
        /// The microphone is in use: a call is probably going on.
        public var microphoneInUse: () -> Bool

        public init(
            display: (any DisplayDimming)?,
            keyboard: (any KeyboardBacklighting)?,
            displaySleep: (any DisplaySleepRequesting)? = nil,
            audio: any AudioControlling,
            processes: any ProcessSnapshotting,
            docker: any DockerProbing,
            helper: any LidHelperGateway,
            log: any EngineLogging,
            sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
            externalDisplayActive: @escaping () -> Bool = { false },
            microphoneInUse: @escaping () -> Bool = { false }
        ) {
            self.display = display
            self.keyboard = keyboard
            self.displaySleep = displaySleep
            self.audio = audio
            self.processes = processes
            self.docker = docker
            self.helper = helper
            self.log = log
            self.sleep = sleep
            self.externalDisplayActive = externalDisplayActive
            self.microphoneInUse = microphoneInUse
        }
    }

    private let deps: Dependencies
    /// Last brightness read with the lid open and the user present. The
    /// closing lid covers the light sensor and auto-brightness has already
    /// dimmed the panel by the time the close is reported, so the value
    /// read then is not the user's.
    public private(set) var displaySample: Float?
    public private(set) var keyboardSample: Float?
    /// Bumped by every lid event: a later event cancels the delayed steps
    /// of an earlier one.
    private var generation = 0
    public private(set) var isBusy = false
    /// The last open could not resume the apps (helper unreachable): it is
    /// to be done again once the helper answers.
    public private(set) var resumeFailed = false
    /// Helper requests go one operation at a time, in the order the events
    /// came: XPC keeps no order between messages in flight together, and a
    /// close's freeze must never land after the next open's resume.
    private let lane = Lane()

    public init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Call every 30 s while the lid is open, the display awake and the user active.
    public func sampleBrightness() {
        if let display = deps.display, !display.isAsleep(), let v = try? display.readBrightness(), v > 0 {
            displaySample = v
        }
        if let keyboard = deps.keyboard, let v = try? keyboard.readBrightness() {
            keyboardSample = v
        }
    }

    /// Cancels the delayed steps of a lid close (the open could not be
    /// handled: helper unreachable).
    public func cancelPending() {
        generation += 1
        isBusy = false
    }

    /// Lid closed during a session. Returns problems worth showing.
    /// `keeping`: processes never paused (running agents, followed processes),
    /// with every app whose tree holds one of them.
    @discardableResult
    public func lidClosed(settings: LidSettings, keeping: Set<Int32> = []) async -> [String] {
        generation += 1
        let mine = generation
        isBusy = true
        defer { if generation == mine { isBusy = false } }
        var problems: [String] = []
        await lane.enter()
        // Opened again while an earlier operation ran: nothing to do.
        guard generation == mine else {
            lane.leave()
            return problems
        }
        _ = try? await deps.helper.lidChanged()
        // Docked: the lid is closed but someone works on the external display.
        if deps.externalDisplayActive() {
            deps.log.info("lid closed with an external display: nothing darkened, muted or paused")
            lane.leave()
            return problems
        }

        // A call (microphone in use): neither the sound nor the apps are
        // touched, or the call would go silent or hang up.
        let onACall = deps.microphoneInUse()

        // 1. Brightness and sound: journal, then change.
        var plan = UserChanges()
        if settings.darkenDisplay {
            if let display = deps.display {
                let value = displaySample ?? (try? display.readBrightness())
                if let value, value > 0 { plan.displayBrightness = value }
            }
            if let keyboard = deps.keyboard {
                let value = keyboardSample ?? (try? keyboard.readBrightness()) ?? nil
                if let value, value > 0 { plan.keyboardBrightness = value }
            }
        }
        if settings.mute, !onACall, let output = try? deps.audio.readDefaultOutput(), !output.muted {
            plan.audio = [AudioEntry(deviceUID: output.deviceUID, name: output.name, volume: output.volume, muted: output.muted)]
        }
        if !plan.isEmpty {
            do {
                _ = try await deps.helper.recordUserChanges(plan)
                // Opened again while the helper was answering: the open
                // already restored; darkening now would leave it dark.
                guard generation == mine else {
                    lane.leave()
                    return problems
                }
                apply(plan, &problems)
            } catch {
                problems.append("Écran et son laissés tels quels : journal non écrit (\(error.localizedDescription))")
            }
        }

        // 2. Apps and Docker: the helper journals, then stops them.
        var groups = onACall ? [] : appGroups(settings.pausedApps, keeping: keeping)
        if settings.pauseDocker, let docker = await idleDockerGroup(), generation == mine {
            groups.append(docker)
        }
        if !groups.isEmpty, generation == mine {
            do {
                _ = try await deps.helper.freeze(groups)
            } catch {
                problems.append("Apps non mises en pause : \(error.localizedDescription)")
            }
        }
        lane.leave()

        // 3. The close itself wakes the panel, and powerd defers a display
        // sleep request for about 30 s after a wake: ask at 3 s and again
        // at 35 s. This is the public path; it turns the panel and the
        // keyboard backlight off even where brightness cannot be written.
        problems.forEach { deps.log.error("lid close: \($0)") }
        if settings.darkenDisplay, let sleeper = deps.displaySleep {
            await deps.sleep(.seconds(3))
            // Opened (or closed again) meanwhile: that event decides.
            guard generation == mine else { return problems }
            sleeper.requestSleep()
            await deps.sleep(.seconds(32))
            guard generation == mine else { return problems }
            sleeper.requestSleep()
        }
        return problems
    }

    /// Activity was declared with the lid closed ("Toujours actif" option):
    /// the display it woke goes dark again, as at the close. Only what the
    /// journal already holds is set to 0 again: nothing new is changed.
    public func darkenAgain(saved: UserChanges, settings: LidSettings) async {
        // Docked: a display sleep would black out the screen in use.
        guard settings.darkenDisplay, !deps.externalDisplayActive() else { return }
        let mine = generation
        if saved.displayBrightness != nil { try? deps.display?.setBrightness(0) }
        if saved.keyboardBrightness != nil { try? deps.keyboard?.setBrightness(0) }
        guard let sleeper = deps.displaySleep else { return }
        // powerd defers a display sleep request for about 30 s after a wake.
        await deps.sleep(.seconds(3))
        guard generation == mine else { return }
        sleeper.requestSleep()
        await deps.sleep(.seconds(32))
        guard generation == mine else { return }
        sleeper.requestSleep()
    }

    /// Lid opened: resume apps, then restore what the journal holds. Sound
    /// muted from the phone stays muted while the session goes on.
    @discardableResult
    public func lidOpened(sessionActive: Bool) async -> [String] {
        generation += 1
        let mine = generation
        isBusy = true
        defer { if generation == mine { isBusy = false } }
        await lane.enter()
        guard generation == mine else {
            // Closed again meanwhile: that close does what is needed.
            lane.leave()
            return []
        }
        var problems: [String] = []
        let changes: UserChanges
        do {
            let status = try await deps.helper.resume(bundleID: nil)
            resumeFailed = false
            if sessionActive { _ = try? await deps.helper.lidChanged() }
            changes = sessionActive ? status.userChanges.withoutHeld : status.userChanges
        } catch {
            resumeFailed = true
            lane.leave()
            return ["Composant système injoignable : \(error.localizedDescription)"]
        }
        guard generation == mine else {
            lane.leave()
            return problems
        }
        let done = await restoreInLane(changes, &problems)
        lane.leave()
        await writeAgain(changes, done: done, generation: mine)
        return problems
    }

    /// Puts back saved brightness and sound, then clears what was restored.
    /// A device that is not connected keeps its entry for a later try.
    @discardableResult
    public func restore(_ changes: UserChanges) async -> [String] {
        guard !changes.isEmpty else { return [] }
        await lane.enter()
        let mine = generation
        var problems: [String] = []
        let done = await restoreInLane(changes, &problems)
        lane.leave()
        await writeAgain(changes, done: done, generation: mine)
        return problems
    }

    private func restoreInLane(_ changes: UserChanges, _ problems: inout [String]) async -> [UserChangeKind] {
        guard !changes.isEmpty else { return [] }
        var done: [UserChangeKind] = []

        if let value = changes.displayBrightness {
            if let display = deps.display, !display.builtInOnline() {
                // Lid closed on a docked Mac: kept for when the panel is back,
                // and no wake (it would keep the Mac from idle sleep).
            } else if let display = deps.display {
                display.wake()
                do {
                    try display.setBrightness(value)
                    done.append(.display)
                    displaySample = value
                } catch {
                    problems.append("Luminosité de l'écran : \(error.localizedDescription)")
                }
            } else {
                done.append(.display) // nothing on this Mac can write it
            }
        }
        if let value = changes.keyboardBrightness {
            do {
                try deps.keyboard?.setBrightness(value)
                done.append(.keyboard)
                keyboardSample = value
            } catch {
                problems.append("Rétroéclairage du clavier : \(error.localizedDescription)")
            }
        }
        for entry in changes.audio {
            do {
                try deps.audio.apply(volume: entry.volume, muted: entry.muted, deviceUID: entry.deviceUID)
                done.append(.audio(deviceUID: entry.deviceUID))
            } catch is AudioDeviceMissing {
                // Restored when the device is back.
            } catch {
                problems.append("Son de \(entry.name ?? entry.deviceUID) : \(error.localizedDescription)")
            }
        }
        if !done.isEmpty {
            _ = try? await deps.helper.clearUserChanges(done)
        }
        return done
    }

    /// powerd re-applies its own brightness shortly after a wake and can
    /// undo the first write: write once more 2 s later, unless the lid
    /// moved meanwhile.
    private func writeAgain(_ changes: UserChanges, done: [UserChangeKind], generation mine: Int) async {
        guard done.contains(.display) || done.contains(.keyboard) else { return }
        await deps.sleep(.seconds(2))
        guard generation == mine else { return }
        if done.contains(.display), let v = changes.displayBrightness { try? deps.display?.setBrightness(v) }
        if done.contains(.keyboard), let v = changes.keyboardBrightness { try? deps.keyboard?.setBrightness(v) }
    }

    /// Phone request: pause Docker Desktop now, with the same two checks
    /// as at lid close. Throws when it is not running or a container runs.
    public func pauseDocker() async throws {
        guard deps.processes.runningApps().contains(where: { $0.bundleID == PausePolicy.dockerBundleID }) else {
            throw LidError.dockerNotRunning
        }
        guard let group = await idleDockerGroup() else { throw LidError.dockerBusy }
        await lane.enter()
        defer { lane.leave() }
        _ = try await deps.helper.freeze([group])
    }

    public func resumeDocker() async throws {
        await lane.enter()
        defer { lane.leave() }
        _ = try await deps.helper.resume(bundleID: PausePolicy.dockerBundleID)
    }

    /// Phone request: mute or unmute the default output. During a session
    /// the level is journaled before muting, so the end of the session puts
    /// it back; outside a session it is a plain mute, as with the key.
    public func setMuted(_ muted: Bool, saved: [AudioEntry]) async throws {
        await lane.enter()
        defer { lane.leave() }
        let output = try deps.audio.readDefaultOutput()
        if muted {
            guard !output.muted else { return }
            // Journaled whenever the helper has a session, even one this app
            // has not seen yet (started from the Terminal a moment ago).
            let entry = AudioEntry(deviceUID: output.deviceUID, name: output.name, volume: output.volume, muted: output.muted, held: true)
            do {
                _ = try await deps.helper.recordUserChanges(UserChanges(audio: [entry]))
            } catch where Self.saysNoSession(error) {
                // No session: a plain mute, as with the key.
            }
            try deps.audio.mute(deviceUID: output.deviceUID)
        } else {
            let previous = saved.first { $0.deviceUID == output.deviceUID }
            // The saved level, or an audible one: unmuting at 0 would stay silent.
            let wanted = previous?.volume ?? output.volume
            let volume = wanted >= Self.audibleVolume / 5 ? wanted : Self.audibleVolume
            try deps.audio.apply(volume: volume, muted: false, deviceUID: output.deviceUID)
            if previous != nil { _ = try? await deps.helper.clearUserChanges([.audio(deviceUID: output.deviceUID)]) }
        }
    }

    static let audibleVolume: Float = 0.25

    static func saysNoSession(_ error: Error) -> Bool {
        if let error = error as? EngineError { return error == .noActiveSession }
        if let refusal = error as? LidHelperRefusal { return refusal.status.map { $0.session == nil } ?? false }
        return false
    }

    /// Phone request: pause the listed apps now (the helper refuses outside
    /// a session: they are resumed at its end). Apps already paused are fine.
    public func pauseApps(_ bundleIDs: [String], alreadyPaused: Set<String> = [], keeping: Set<Int32> = []) async throws {
        let wanted = bundleIDs.filter { !alreadyPaused.contains($0) }
        let groups = appGroups(wanted, keeping: keeping)
        guard !groups.isEmpty else {
            if bundleIDs.contains(where: alreadyPaused.contains) { return }
            // Open, but an agent runs in each of them.
            if !appGroups(wanted).isEmpty { throw LidError.appsRunAnAgent }
            throw LidError.noAppToPause
        }
        await lane.enter()
        defer { lane.leave() }
        _ = try await deps.helper.freeze(groups)
    }

    /// Phone request: resume the paused apps, Docker excepted.
    public func resumeApps(_ frozenBundleIDs: [String]) async throws {
        await lane.enter()
        defer { lane.leave() }
        for id in Set(frozenBundleIDs) where id != PausePolicy.dockerBundleID {
            _ = try await deps.helper.resume(bundleID: id)
        }
    }

    /// Gives up on a device that will not come back: its sound stays as it is.
    public func forgetAudio(deviceUID: String) async {
        await lane.enter()
        defer { lane.leave() }
        _ = try? await deps.helper.clearUserChanges([.audio(deviceUID: deviceUID)])
    }

    // MARK: Private

    private func apply(_ plan: UserChanges, _ problems: inout [String]) {
        if plan.displayBrightness != nil {
            do { try deps.display?.setBrightness(0) } catch { problems.append("Écran non assombri : \(error.localizedDescription)") }
        }
        if plan.keyboardBrightness != nil {
            do { try deps.keyboard?.setBrightness(0) } catch { problems.append("Clavier non éteint : \(error.localizedDescription)") }
        }
        for entry in plan.audio {
            do { try deps.audio.mute(deviceUID: entry.deviceUID) } catch { problems.append("Son non coupé : \(error.localizedDescription)") }
        }
    }

    /// Each listed app that runs, with every process it started, owned by
    /// this user. Protected apps are never included, whatever the list says,
    /// nor an app whose tree holds a process to keep (an agent running in
    /// that terminal or editor).
    func appGroups(_ bundleIDs: [String], keeping: Set<Int32> = []) -> [FreezeGroup] {
        let wanted = Set(bundleIDs.filter { !PausePolicy.isProtected($0) })
        guard !wanted.isEmpty else { return [] }
        let apps = deps.processes.runningApps().filter { wanted.contains($0.bundleID) }
        guard !apps.isEmpty else { return [] }
        let table = deps.processes.processTable()
        return apps.map { group(for: $0, table: table) }.filter { group in
            !group.targets.isEmpty && !group.targets.contains { keeping.contains($0.pid) }
        }
    }

    private func group(for app: RunningApp, table: [Int32: ProcessState]) -> FreezeGroup {
        let parents = table.mapValues(\.ppid)
        let uid = deps.processes.currentUID
        let targets = ProcessTree.descendants(of: app.pid, parents: parents).compactMap { pid -> FreezeTarget? in
            guard let state = table[pid], state.uid == uid, !state.stopped else { return nil }
            return FreezeTarget(pid: pid, identity: state.identity)
        }
        return FreezeGroup(bundleID: app.bundleID, name: app.name, targets: targets)
    }

    /// Docker Desktop's tree, only when it runs and two probes, one right
    /// before the pause, find no container. Any error leaves Docker running.
    private func idleDockerGroup() async -> FreezeGroup? {
        guard let app = deps.processes.runningApps().first(where: { $0.bundleID == PausePolicy.dockerBundleID }) else { return nil }
        do {
            guard try await deps.docker.isIdle() else {
                deps.log.info("docker: containers running, left alone")
                return nil
            }
            let group = self.group(for: app, table: deps.processes.processTable())
            guard try await deps.docker.isIdle() else {
                deps.log.info("docker: a container started meanwhile, left alone")
                return nil
            }
            return group
        } catch {
            deps.log.error("docker: probe failed, left alone: \(error.localizedDescription)")
            return nil
        }
    }
}

public enum LidError: Error, LocalizedError, Sendable {
    case dockerNotRunning
    case dockerBusy
    case noAppToPause
    case appsRunAnAgent

    public var errorDescription: String? {
        switch self {
        case .dockerNotRunning: "Docker Desktop n'est pas ouvert."
        case .noAppToPause: "Aucune des apps à mettre en pause n'est ouverte."
        case .appsRunAnAgent: "Un agent tourne dans ces apps : elles ne sont pas mises en pause."
        case .dockerBusy: "Des conteneurs tournent, ou Docker ne répond pas : Docker laissé tel quel."
        }
    }
}

/// The helper answered with a refusal; `status` is its state at that moment.
public struct LidHelperRefusal: Error, LocalizedError, Sendable {
    public let message: String
    public let status: EngineStatus?

    public init(message: String, status: EngineStatus?) {
        self.message = message
        self.status = status
    }

    public var errorDescription: String? { message }
}

/// First come, first served, one at a time.
@MainActor
final class Lane {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            // The turn passes on: busy stays true.
            waiting.removeFirst().resume()
        }
    }
}
