@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

@MainActor
final class FakeDisplay: DisplayDimming {
    let log: EventLog
    var brightness: Float = 0.7
    var asleep = false
    init(log: EventLog) { self.log = log }
    func readBrightness() throws -> Float { brightness }
    func setBrightness(_ value: Float) throws { brightness = value; log.add("display \(value)") }
    func requestSleep() { log.add("display sleep") }
    func wake() { log.add("display wake") }
    func isAsleep() -> Bool { asleep }
    var online = true
    func builtInOnline() -> Bool { online }
}

@MainActor
final class FakeDisplaySleep: DisplaySleepRequesting {
    let log: EventLog
    init(log: EventLog) { self.log = log }
    func requestSleep() { log.add("display sleep") }
}

@MainActor
final class FakeKeyboard: KeyboardBacklighting {
    let log: EventLog
    var brightness: Float? = 0.5
    init(log: EventLog) { self.log = log }
    func readBrightness() throws -> Float? { brightness }
    func setBrightness(_ value: Float) throws { brightness = value; log.add("keyboard \(value)") }
}

@MainActor
final class FakeAudio: AudioControlling {
    let log: EventLog
    var devices: [String: AudioOutput] = ["spk": AudioOutput(deviceUID: "spk", name: "Haut-parleurs", volume: 0.6, muted: false)]
    var defaultUID = "spk"
    init(log: EventLog) { self.log = log }
    func readDefaultOutput() throws -> AudioOutput { devices[defaultUID]! }
    func mute(deviceUID: String) throws {
        guard devices[deviceUID] != nil else { throw AudioDeviceMissing(deviceUID: deviceUID) }
        devices[deviceUID]!.muted = true
        log.add("mute \(deviceUID)")
    }
    func apply(volume: Float, muted: Bool, deviceUID: String) throws {
        guard devices[deviceUID] != nil else { throw AudioDeviceMissing(deviceUID: deviceUID) }
        devices[deviceUID]!.volume = volume
        devices[deviceUID]!.muted = muted
        log.add("audio \(deviceUID) \(volume) \(muted)")
    }
}

@MainActor
final class FakeSnapshot: ProcessSnapshotting {
    var apps: [RunningApp] = []
    var table: [Int32: ProcessState] = [:]
    let currentUID: UInt32 = 501
    func runningApps() -> [RunningApp] { apps }
    func processTable() -> [Int32: ProcessState] { table }
}

@MainActor
final class FakeDocker: DockerProbing {
    var answers: [Bool] = []
    var calls = 0
    func isIdle() async throws -> Bool {
        calls += 1
        guard !answers.isEmpty else { throw FakeError(message: "no docker") }
        return answers.removeFirst()
    }
}

/// Talks straight to a real SessionEngine with fakes, so the journal order
/// across app and helper is what the test sees.
@MainActor
final class EngineGateway: LidHelperGateway {
    let engine: SessionEngine
    let log: EventLog
    init(engine: SessionEngine, log: EventLog) { self.engine = engine; self.log = log }
    func recordUserChanges(_ changes: UserChanges) async throws -> EngineStatus { try await engine.recordUserChanges(changes) }
    func clearUserChanges(_ kinds: [UserChangeKind]) async throws -> EngineStatus { await engine.clearUserChanges(kinds) }
    func freeze(_ groups: [FreezeGroup]) async throws -> EngineStatus { try await engine.freeze(groups, requesterUID: 501) }
    func resume(bundleID: String?) async throws -> EngineStatus { await engine.resume(onlyBundleID: bundleID) }
    func lidChanged() async throws -> EngineStatus { await engine.evaluate() }
}

/// What the room looks like when the lid closes.
@MainActor
final class LidEnvironment {
    var externalDisplay = false
    var microphone = false
}

@MainActor
struct LidRig {
    let h = Harness()
    let display: FakeDisplay
    let keyboard: FakeKeyboard
    let audio: FakeAudio
    let snapshot = FakeSnapshot()
    let docker = FakeDocker()
    let coordinator: LidCoordinator
    let environment = LidEnvironment()

    init() {
        display = FakeDisplay(log: h.events)
        keyboard = FakeKeyboard(log: h.events)
        audio = FakeAudio(log: h.events)
        let environment = environment
        coordinator = LidCoordinator(.init(
            display: display, keyboard: keyboard, displaySleep: FakeDisplaySleep(log: h.events),
            audio: audio, processes: snapshot, docker: docker,
            helper: EngineGateway(engine: h.engine, log: h.events), log: SilentLog(), sleep: { _ in },
            externalDisplayActive: { environment.externalDisplay },
            microphoneInUse: { environment.microphone }
        ))
    }

    func startSession() async throws {
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.events.clear()
    }

    func addApp(_ bundleID: String, name: String, pid: Int32, children: [Int32] = []) {
        snapshot.apps.append(RunningApp(pid: pid, bundleID: bundleID, name: name))
        for (i, p) in ([pid] + children).enumerated() {
            let state = ProcessState(ppid: i == 0 ? 1 : pid, uid: 501, stopped: false,
                                     identity: ProcessIdentity(startSeconds: Int64(p), startMicros: 7, bootSession: FakeProcesses.boot))
            snapshot.table[p] = state
            h.processes.set(p, state)
        }
    }
}

@MainActor
@Suite struct LidCoordinatorTests {
    @Test func closeJournalsThenDarkensMutesAndPauses() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.tinyspeck.slackmacgap", name: "Slack", pid: 100, children: [101, 102])
        rig.coordinator.sampleBrightness()
        rig.display.brightness = 0.3 // auto-brightness under the closing lid

        let problems = await rig.coordinator.lidClosed(settings: LidSettings())

        #expect(problems.isEmpty)
        let events = rig.h.events.all
        let save = try #require(events.firstIndex(of: "save journal"))
        let darken = try #require(events.firstIndex(of: "display 0.0"))
        #expect(save < darken, "journal before change")
        #expect(events.contains("keyboard 0.0"))
        #expect(events.contains("mute spk"))
        #expect(events.contains("SIGSTOP 101"))
        #expect(events.suffix(2) == ["display sleep", "display sleep"], "asked twice: at 3 s and after powerd's 30 s deferral")

        let status = await rig.h.engine.status()
        #expect(status.userChanges.displayBrightness == 0.7, "the open-lid sample, not the dimmed read")
        #expect(status.frozen.map(\.pid).sorted() == [100, 101, 102])
    }

    @Test func openResumesAndRestores() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.hnc.Discord", name: "Discord", pid: 100)
        rig.coordinator.sampleBrightness()
        await rig.coordinator.lidClosed(settings: LidSettings())

        let problems = await rig.coordinator.lidOpened(sessionActive: true)

        #expect(problems.isEmpty)
        #expect(rig.display.brightness == 0.7)
        #expect(rig.keyboard.brightness == 0.5)
        #expect(rig.audio.devices["spk"]?.muted == false)
        #expect(rig.audio.devices["spk"]?.volume == 0.6)
        let status = await rig.h.engine.status()
        #expect(status.userChanges.isEmpty)
        #expect(status.frozen.isEmpty)
        #expect(rig.h.processes.state(100)?.stopped == false)
    }

    @Test func protectedAppsInTheListAreSkipped() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.microsoft.teams2", name: "Teams", pid: 200)
        #expect(rig.coordinator.appGroups(["com.microsoft.teams2"]).isEmpty)
    }

    @Test func otherUsersChildrenAreLeftOut() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.hnc.Discord", name: "Discord", pid: 100, children: [101])
        rig.snapshot.table[101]?.uid = 0
        #expect(rig.coordinator.appGroups(["com.hnc.Discord"]).first?.targets.map(\.pid) == [100])
    }

    @Test func dockerPausedOnlyWhenBothProbesFindNoContainer() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp(PausePolicy.dockerBundleID, name: "Docker Desktop", pid: 300, children: [301])

        rig.docker.answers = [true, false]
        await rig.coordinator.lidClosed(settings: LidSettings(pausedApps: []))
        #expect(await rig.h.engine.status().frozen.isEmpty)

        await rig.coordinator.lidOpened(sessionActive: true)
        rig.docker.answers = [true, true]
        await rig.coordinator.lidClosed(settings: LidSettings(pausedApps: []))
        #expect(await rig.h.engine.status().frozen.map(\.pid).sorted() == [300, 301])
    }

    @Test func dockerProbeErrorLeavesDockerRunning() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp(PausePolicy.dockerBundleID, name: "Docker Desktop", pid: 300)
        rig.docker.answers = []
        await rig.coordinator.lidClosed(settings: LidSettings(pausedApps: []))
        #expect(await rig.h.engine.status().frozen.isEmpty)
    }

    @Test func journalFailureChangesNothing() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.h.journal.update { $0.failWrites = true }
        let problems = await rig.coordinator.lidClosed(settings: LidSettings(pausedApps: [], pauseDocker: false))
        #expect(!problems.isEmpty)
        #expect(rig.display.brightness == 0.7)
        #expect(rig.audio.devices["spk"]?.muted == false)
    }

    @Test func settingsOffDoNothing() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.hnc.Discord", name: "Discord", pid: 100)
        await rig.coordinator.lidClosed(settings: LidSettings(darkenDisplay: false, mute: false, lowPower: false, pausedApps: [], pauseDocker: false))
        #expect(rig.h.events.all.allSatisfy { !$0.hasPrefix("display") && !$0.hasPrefix("mute") && !$0.hasPrefix("SIGSTOP") })
    }

    @Test func disconnectedHeadsetKeepsItsEntry() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.audio.devices["airpods"] = AudioOutput(deviceUID: "airpods", name: "AirPods", volume: 0.5, muted: false)
        rig.audio.defaultUID = "airpods"
        await rig.coordinator.lidClosed(settings: LidSettings(darkenDisplay: false, pausedApps: [], pauseDocker: false))
        rig.audio.devices["airpods"] = nil

        await rig.coordinator.lidOpened(sessionActive: true)
        #expect(await rig.h.engine.status().userChanges.audio.map(\.deviceUID) == ["airpods"])

        await rig.coordinator.forgetAudio(deviceUID: "airpods")
        #expect(await rig.h.engine.status().userChanges.audio.isEmpty)
    }

    @Test func refusedPrivateCallsStillAskTheDisplayToSleep() async throws {
        let rig = LidRig()
        try await rig.startSession()
        let fallback = LidCoordinator(.init(
            display: nil, keyboard: nil, displaySleep: FakeDisplaySleep(log: rig.h.events),
            audio: rig.audio, processes: rig.snapshot, docker: rig.docker,
            helper: EngineGateway(engine: rig.h.engine, log: rig.h.events), log: SilentLog(), sleep: { _ in }
        ))
        await fallback.lidClosed(settings: LidSettings(mute: false, pausedApps: [], pauseDocker: false))
        #expect(rig.h.events.all.filter { $0 == "display sleep" }.count == 2)
        #expect(await rig.h.engine.status().userChanges.displayBrightness == nil, "nothing to restore: brightness untouched")
    }

    @Test func alreadyMutedOrDarkIsNotJournaled() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.display.brightness = 0
        rig.keyboard.brightness = 0
        rig.audio.devices["spk"]?.muted = true
        await rig.coordinator.lidClosed(settings: LidSettings(pausedApps: [], pauseDocker: false))
        #expect(await rig.h.engine.status().userChanges.isEmpty)
    }

    /// "Rester disponible capot fermé": after each declared activity the
    /// display goes dark again, but only values the journal already holds.
    @Test func darkenAgainOnlyTouchesWhatTheJournalHolds() async throws {
        let rig = LidRig()
        try await rig.startSession()
        await rig.coordinator.lidClosed(settings: LidSettings(pausedApps: [], pauseDocker: false))
        let saved = await rig.h.engine.status().userChanges
        #expect(saved.displayBrightness != nil)

        rig.display.brightness = 0.7 // the wake brought it back
        rig.h.events.clear()
        await rig.coordinator.darkenAgain(saved: saved, settings: LidSettings())
        #expect(rig.display.brightness == 0)
        #expect(rig.h.events.all.filter { $0 == "display sleep" }.count == 2)

        // Nothing journaled: nothing changed.
        rig.display.brightness = 0.7
        await rig.coordinator.darkenAgain(saved: UserChanges(), settings: LidSettings())
        #expect(rig.display.brightness == 0.7)
    }
}

