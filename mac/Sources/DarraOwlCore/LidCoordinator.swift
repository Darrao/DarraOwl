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
        public var audio: any AudioControlling
        public var processes: any ProcessSnapshotting
        public var docker: any DockerProbing
        public var helper: any LidHelperGateway
        public var log: any EngineLogging
        public var sleep: (Duration) async -> Void

        public init(
            display: (any DisplayDimming)?,
            keyboard: (any KeyboardBacklighting)?,
            audio: any AudioControlling,
            processes: any ProcessSnapshotting,
            docker: any DockerProbing,
            helper: any LidHelperGateway,
            log: any EngineLogging,
            sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        ) {
            self.display = display
            self.keyboard = keyboard
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

        // 3. The close itself wakes the panel; ask it to sleep once it settled.
        if plan.displayBrightness != nil {
            await deps.sleep(.seconds(3))
            if generation == mine { deps.display?.requestSleep() }
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
