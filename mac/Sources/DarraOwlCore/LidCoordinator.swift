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

        public init(
            display: (any DisplayDimming)?,
            keyboard: (any KeyboardBacklighting)?,
            displaySleep: (any DisplaySleepRequesting)? = nil,
            audio: any AudioControlling,
            processes: any ProcessSnapshotting,
            docker: any DockerProbing,
            helper: any LidHelperGateway,
            log: any EngineLogging,
            sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
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

    /// Lid closed during a session. Returns problems worth showing.
    @discardableResult
    public func lidClosed(settings: LidSettings) async -> [String] {
        generation += 1
        let mine = generation
        isBusy = true
        defer { if generation == mine { isBusy = false } }
        var problems: [String] = []
        _ = try? await deps.helper.lidChanged()

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
        if settings.mute, let output = try? deps.audio.readDefaultOutput(), !output.muted {
            plan.audio = [AudioEntry(deviceUID: output.deviceUID, name: output.name, volume: output.volume, muted: output.muted)]
        }
        if !plan.isEmpty {
            do {
                _ = try await deps.helper.recordUserChanges(plan)
                apply(plan, &problems)
            } catch {
                problems.append("Écran et son laissés tels quels : journal non écrit (\(error.localizedDescription))")
            }
        }

        // 2. Apps and Docker: the helper journals, then stops them.
        var groups = appGroups(settings.pausedApps)
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

        // 3. The close itself wakes the panel, and powerd defers a display
        // sleep request for about 30 s after a wake: ask at 3 s and again
        // at 35 s. This is the public path; it turns the panel and the
        // keyboard backlight off even where brightness cannot be written.
        if settings.darkenDisplay, let sleeper = deps.displaySleep {
            await deps.sleep(.seconds(3))
            if generation == mine { sleeper.requestSleep() }
            await deps.sleep(.seconds(32))
            if generation == mine { sleeper.requestSleep() }
        }
        problems.forEach { deps.log.error("lid close: \($0)") }
        return problems
    }

    /// Lid opened: resume apps, then restore what the journal holds.
    @discardableResult
    public func lidOpened(sessionActive: Bool) async -> [String] {
        generation += 1
        isBusy = true
        defer { isBusy = false }
        var problems: [String] = []
        do {
            let status = try await deps.helper.resume(bundleID: nil)
            if sessionActive { _ = try? await deps.helper.lidChanged() }
            problems += await restore(status.userChanges)
        } catch {
            problems.append("Composant système injoignable : \(error.localizedDescription)")
        }
        return problems
    }

    /// Puts back saved brightness and sound, then clears what was restored.
    /// A device that is not connected keeps its entry for a later try.
    @discardableResult
    public func restore(_ changes: UserChanges) async -> [String] {
        guard !changes.isEmpty else { return [] }
        let mine = generation
        var done: [UserChangeKind] = []
        var problems: [String] = []

        if let value = changes.displayBrightness {
            if let display = deps.display {
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

        // powerd re-applies its own brightness shortly after a wake and can
        // undo the first write: write once more 2 s later.
        if done.contains(.display) || done.contains(.keyboard) {
            await deps.sleep(.seconds(2))
            if generation == mine {
                if done.contains(.display), let v = changes.displayBrightness { try? deps.display?.setBrightness(v) }
                if done.contains(.keyboard), let v = changes.keyboardBrightness { try? deps.keyboard?.setBrightness(v) }
            }
        }
        return problems
    }

    /// Phone request: pause Docker Desktop now, with the same two checks
    /// as at lid close. Throws when it is not running or a container runs.
    public func pauseDocker() async throws {
        guard deps.processes.runningApps().contains(where: { $0.bundleID == PausePolicy.dockerBundleID }) else {
            throw LidError.dockerNotRunning
        }
        guard let group = await idleDockerGroup() else { throw LidError.dockerBusy }
        _ = try await deps.helper.freeze([group])
    }

    public func resumeDocker() async throws {
        _ = try await deps.helper.resume(bundleID: PausePolicy.dockerBundleID)
    }

    /// Phone request: mute or unmute the default output. During a session
    /// the level is journaled before muting, so the end of the session puts
    /// it back; outside a session it is a plain mute, as with the key.
    public func setMuted(_ muted: Bool, sessionActive: Bool, saved: [AudioEntry]) async throws {
        let output = try deps.audio.readDefaultOutput()
        if muted {
            guard !output.muted else { return }
            if sessionActive {
                let entry = AudioEntry(deviceUID: output.deviceUID, name: output.name, volume: output.volume, muted: output.muted)
                _ = try await deps.helper.recordUserChanges(UserChanges(audio: [entry]))
            }
            try deps.audio.mute(deviceUID: output.deviceUID)
        } else {
            let previous = saved.first { $0.deviceUID == output.deviceUID }
            // Unmuting at volume 0 would still be silent.
            let volume = max(previous?.volume ?? output.volume, Self.audibleVolume)
            try deps.audio.apply(volume: volume, muted: false, deviceUID: output.deviceUID)
            if previous != nil { _ = try? await deps.helper.clearUserChanges([.audio(deviceUID: output.deviceUID)]) }
        }
    }

    static let audibleVolume: Float = 0.25

    /// Phone request: pause the listed apps now (the helper refuses outside
    /// a session: they are resumed at its end).
    public func pauseApps(_ bundleIDs: [String]) async throws {
        let groups = appGroups(bundleIDs)
        guard !groups.isEmpty else { throw LidError.noAppToPause }
        _ = try await deps.helper.freeze(groups)
    }

    /// Phone request: resume the paused apps, Docker excepted.
    public func resumeApps(_ frozenBundleIDs: [String]) async throws {
        for id in Set(frozenBundleIDs) where id != PausePolicy.dockerBundleID {
            _ = try await deps.helper.resume(bundleID: id)
        }
    }

    /// Gives up on a device that will not come back: its sound stays as it is.
    public func forgetAudio(deviceUID: String) async {
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
    /// this user. Protected apps are never included, whatever the list says.
    func appGroups(_ bundleIDs: [String]) -> [FreezeGroup] {
        let wanted = Set(bundleIDs.filter { !PausePolicy.isProtected($0) })
        guard !wanted.isEmpty else { return [] }
        let apps = deps.processes.runningApps().filter { wanted.contains($0.bundleID) }
        guard !apps.isEmpty else { return [] }
        let table = deps.processes.processTable()
        return apps.map { group(for: $0, table: table) }.filter { !$0.targets.isEmpty }
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

    public var errorDescription: String? {
        switch self {
        case .dockerNotRunning: "Docker Desktop n'est pas ouvert."
        case .noAppToPause: "Aucune des apps à mettre en pause n'est ouverte."
        case .dockerBusy: "Des conteneurs tournent, ou Docker ne répond pas : Docker laissé tel quel."
        }
    }
}
