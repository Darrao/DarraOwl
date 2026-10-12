@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

/// Sound, apps and agents driven from the phone.
@MainActor
@Suite struct RemoteControlTests {
    // MARK: Sound

    @Test func muteDuringASessionIsJournaledFirstAndUndoneAtTheEnd() async throws {
        let rig = LidRig()
        try await rig.startSession()

        try await rig.coordinator.setMuted(true, saved: [])

        let events = rig.h.events.all
        let save = try #require(events.firstIndex(of: "save journal"))
        let mute = try #require(events.firstIndex(of: "mute spk"))
        #expect(save < mute)
        #expect(await rig.h.engine.status().userChanges.audio.first?.volume == 0.6)
    }

    @Test func muteOutsideASessionIsAPlainMute() async throws {
        let rig = LidRig()
        _ = await rig.h.engine.reconcile()

        try await rig.coordinator.setMuted(true, saved: [])

        #expect(rig.audio.devices["spk"]?.muted == true)
        #expect(!rig.h.events.all.contains("save journal"))
    }

    @Test func unmuteGivesBackTheSavedLevelAndClearsIt() async throws {
        let rig = LidRig()
        try await rig.startSession()
        try await rig.coordinator.setMuted(true, saved: [])
        let saved = await rig.h.engine.status().userChanges.audio

        try await rig.coordinator.setMuted(false, saved: saved)

        #expect(rig.audio.devices["spk"]?.muted == false)
        #expect(rig.audio.devices["spk"]?.volume == 0.6)
        #expect(await rig.h.engine.status().userChanges.audio.isEmpty)
    }

    @Test func unmuteAtVolumeZeroIsAudible() async throws {
        let rig = LidRig()
        rig.audio.devices["spk"] = AudioOutput(deviceUID: "spk", name: nil, volume: 0, muted: true)
        try await rig.coordinator.setMuted(false, saved: [])
        #expect(rig.audio.devices["spk"]?.volume == LidCoordinator.audibleVolume)
    }

    // MARK: Apps

    @Test func pauseAndResumeTheListedApps() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.tinyspeck.slackmacgap", name: "Slack", pid: 100, children: [101])

        try await rig.coordinator.pauseApps(LidSettings().pausedApps)
        #expect(rig.h.processes.state(101)?.stopped == true)

        let frozen = await rig.h.engine.status().frozen.map(\.bundleID)
        try await rig.coordinator.resumeApps(frozen)
        #expect(rig.h.processes.state(101)?.stopped == false)
        #expect(await rig.h.engine.status().frozen.isEmpty)
    }

    @Test func pauseWithNothingOpenSaysSo() async throws {
        let rig = LidRig()
        try await rig.startSession()
        await #expect(throws: LidError.noAppToPause) {
            try await rig.coordinator.pauseApps(LidSettings().pausedApps)
        }
    }

    @Test func pauseOutsideASessionIsRefusedByTheHelper() async {
        let rig = LidRig()
        _ = await rig.h.engine.reconcile()
        rig.addApp("com.tinyspeck.slackmacgap", name: "Slack", pid: 100)
        await #expect(throws: EngineError.noActiveSession) {
            try await rig.coordinator.pauseApps(LidSettings().pausedApps)
        }
        #expect(rig.h.processes.state(100)?.stopped == false)
    }

    // MARK: Agents

    func identity(_ start: Int64) -> ProcessIdentity {
        ProcessIdentity(startSeconds: start, startMicros: 7, bootSession: FakeProcesses.boot)
    }

    @Test func anAgentThatQuitsOnCtrlCGetsNothingMore() async {
        let log = EventLog()
        let processes = FakeProcesses(log: log, [300: FakeProcesses.state(start: 1000)])
        let stopper = AgentStopper(processes: processes, sleep: { _ in processes.set(300, nil) })

        #expect(await stopper.stop(pid: 300, identity: identity(1000)) == .stopped)
        #expect(log.all.count == 1, "SIGINT only")
    }

    @Test func anAgentThatIgnoresCtrlCGetsSIGTERM() async {
        let log = EventLog()
        let processes = FakeProcesses(log: log, [300: FakeProcesses.state(start: 1000)])
        var calls = 0
        let stopper = AgentStopper(processes: processes, sleep: { _ in
            calls += 1
            if calls == 2 { processes.set(300, nil) }
        })
        #expect(await stopper.stop(pid: 300, identity: identity(1000)) == .stopped)
        #expect(log.all.count == 2)
    }

    @Test func aReusedPidIsNeverSignalled() async {
        let log = EventLog()
        let processes = FakeProcesses(log: log, [300: FakeProcesses.state(start: 5000)])
        let stopper = AgentStopper(processes: processes, sleep: { _ in })
        #expect(await stopper.stop(pid: 300, identity: identity(1000)) == .stopped)
        #expect(log.all.isEmpty)
    }

    @Test func aStubbornAgentIsReported() async {
        let log = EventLog()
        let processes = FakeProcesses(log: log, [300: FakeProcesses.state(start: 1000)])
        let stopper = AgentStopper(processes: processes, sleep: { _ in })
        #expect(await stopper.stop(pid: 300, identity: identity(1000)) == .stillRunning)
    }
}

/// Lid-close actions in the cases the 2026-10-12 review found.
@MainActor
@Suite struct LidCloseCasesTests {
    @Test func aDockedMacKeepsItsScreenSoundAndApps() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.tinyspeck.slackmacgap", name: "Slack", pid: 100)
        rig.environment.externalDisplay = true
        await rig.coordinator.lidClosed(settings: LidSettings())
        #expect(!rig.h.events.all.contains { $0.hasPrefix("display") || $0.hasPrefix("mute") || $0.hasPrefix("SIGSTOP") })
    }

    @Test func neitherSoundNorAppsAreTouchedDuringACall() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.tinyspeck.slackmacgap", name: "Slack", pid: 100)
        rig.environment.microphone = true
        await rig.coordinator.lidClosed(settings: LidSettings())
        #expect(rig.h.processes.state(100)?.stopped == false)
        #expect(!rig.h.events.all.contains("mute spk"), "the call stays audible")
        #expect(rig.h.events.all.contains { $0.hasPrefix("display") }, "the panel under the lid still goes dark")
    }

    @Test func anAppRunningAnAgentIsNeverPaused() async throws {
        let rig = LidRig()
        try await rig.startSession()
        rig.addApp("com.googlecode.iterm2", name: "iTerm2", pid: 100, children: [101, 102])
        var settings = LidSettings()
        settings.pausedApps = ["com.googlecode.iterm2"]
        await rig.coordinator.lidClosed(settings: settings, keeping: [102])
        #expect(rig.h.processes.state(102)?.stopped == false)
        #expect(rig.h.processes.state(100)?.stopped == false)
    }

    @Test func soundMutedFromThePhoneStaysMutedWhenTheLidOpens() async throws {
        let rig = LidRig()
        try await rig.startSession()
        try await rig.coordinator.setMuted(true, saved: [])
        await rig.coordinator.lidClosed(settings: LidSettings())
        await rig.coordinator.lidOpened(sessionActive: true)
        #expect(rig.audio.devices["spk"]?.muted == true)
        // The session ends: the sound comes back.
        _ = try await rig.h.engine.stop(reason: .userStopped)
        await rig.coordinator.lidOpened(sessionActive: false)
        #expect(rig.audio.devices["spk"]?.muted == false)
        #expect(rig.audio.devices["spk"]?.volume == 0.6)
    }

    @Test func pausingAppsAlreadyPausedIsNotAnError() async throws {
        let rig = LidRig()
        try await rig.startSession()
        try await rig.coordinator.pauseApps(["com.tinyspeck.slackmacgap"], alreadyPaused: ["com.tinyspeck.slackmacgap"])
    }
}
