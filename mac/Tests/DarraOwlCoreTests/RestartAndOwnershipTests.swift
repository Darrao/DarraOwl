@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

/// Restarts, interrupted uninstalls, who may act, and the lid seen by the helper alone.
@Suite struct RestartAndOwnershipTests {
    /// Panic, power loss, power button held: no SIGTERM, the journal still
    /// holds the session. Safety rule 3: sleep is back at startup.
    @Test func aSessionFromBeforeARestartEndsAtStartup() async throws {
        let before = Harness(bootSession: "BOOT-A")
        _ = await before.engine.reconcile()
        _ = try await before.engine.start(duration: 4 * 3600, origin: .menuBar)
        let journal = try #require(before.journal.value)

        let after = Harness(power: .init(sleepDisabled: true, lowPowerOnBattery: false, lowPowerOnAC: false), journal: journal, bootSession: "BOOT-B")
        let status = await after.engine.reconcile()

        #expect(status.session == nil)
        #expect(status.lastEnd?.reason == .macRestarted)
        #expect(!after.power.current.sleepDisabled)
    }

    /// The helper crashed or was updated: same boot, the session goes on.
    @Test func aHelperRestartInTheSameBootResumes() async throws {
        let before = Harness(bootSession: "BOOT-A")
        _ = await before.engine.reconcile()
        _ = try await before.engine.start(duration: 4 * 3600, origin: .menuBar)
        let journal = try #require(before.journal.value)

        let after = Harness(power: .init(sleepDisabled: true, lowPowerOnBattery: false, lowPowerOnAC: false), journal: journal, bootSession: "BOOT-A")
        let status = await after.engine.reconcile()

        #expect(status.session != nil)
        #expect(after.power.current.sleepDisabled)
    }

    /// The uninstall stopped after the helper removed its files: once its
    /// window is over, sessions are written to disk again, their end too.
    @Test func anAbandonedUninstallStopsBlockingAndJournalsAgain() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = await h.engine.prepareUninstall()
        await #expect(throws: EngineError.uninstalling) { try await h.engine.start(duration: 3600, origin: .menuBar) }

        h.clock.advance(SessionEngine.uninstallWindow + 1)
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        #expect(h.journal.value?.session != nil)
        _ = try await h.engine.stop(reason: .userStopped)

        #expect(h.journal.value?.session == nil, "the end reached the disk")
        #expect(h.journal.value?.sleep == nil)
        #expect(h.journal.value?.lastEnd?.reason == .userStopped)
    }

    @Test func theSessionKnowsWhoStartedIt() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .cli, requesterUID: 501)
        #expect(await h.engine.sessionOwner() == 501)
        _ = try await h.engine.stop(reason: .userStopped)
        #expect(await h.engine.sessionOwner() == nil)
    }

    /// An update's restart only happens with nothing held.
    @Test func restartingForAnUpdateWaitsForAnIdleHelper() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        #expect(await h.engine.shutDownIfIdle() == false)
        _ = try await h.engine.stop(reason: .userStopped)
        #expect(await h.engine.shutDownIfIdle() == true)
    }

    /// The app crashed with the lid closed: opening the lid resumes the apps
    /// all the same.
    @Test func pausedAppsResumeWhenTheLidOpensWithoutTheApp() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.processes.set(100, FakeProcesses.state(start: 1))
        h.source.set(PowerSnapshot(battery: .percent(80), onExternalPower: true, thermal: .nominal, lidClosed: true))
        _ = await h.engine.evaluate()
        h.clock.advance(SessionEngine.lidSettle + 0.1)
        _ = await h.engine.evaluate()
        let target = FreezeTarget(pid: 100, identity: ProcessIdentity(startSeconds: 1, startMicros: 7, bootSession: FakeProcesses.boot))
        _ = try await h.engine.freeze([FreezeGroup(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", targets: [target])], requesterUID: 501)
        #expect(h.processes.state(100)?.stopped == true)

        h.source.set(PowerSnapshot(battery: .percent(80), onExternalPower: true, thermal: .nominal, lidClosed: false))
        _ = await h.engine.evaluate()
        #expect(h.processes.state(100)?.stopped == true, "a lid bounce is not an open")
        h.clock.advance(SessionEngine.lidSettle + 0.1)
        let status = await h.engine.evaluate()

        #expect(h.processes.state(100)?.stopped == false)
        #expect(status.frozen.isEmpty)
        #expect(status.session != nil)
    }

    /// Following agents only: "+1 h" keeps the Mac awake at least that long.
    @Test func extendingAnAgentSessionKeepsTheMacAwakeThatLong() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.processes.set(300, FakeProcesses.state(uid: 501, start: 1000))
        let agent = WatchedProcess(pid: 300, name: "claude", project: "DarraOwl", startSeconds: 1000, startMicros: 7)
        _ = try await h.engine.watch(agent, seconds: nil, origin: .agent, requesterUID: 501)

        let extended = try await h.engine.extend(by: 3600)
        #expect(extended.session?.keepUntil == h.clock.now().addingTimeInterval(3600))

        h.clock.advance(60)
        h.processes.set(300, nil)
        let status = await h.engine.evaluate()
        #expect(status.session != nil, "the agent is done, the hour is not")
        #expect(status.session?.endsAt == h.clock.now().addingTimeInterval(3600 - 60))
    }

    /// A Mac on a desk with an external display: no Low Power Mode for the
    /// closed lid. In a bag: Low Power Mode.
    @Test func noLowPowerModeForADockedMac() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = await h.engine.setExternalDisplay(true)
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .percent(80), onExternalPower: true, thermal: .nominal, lidClosed: true))
        _ = await h.engine.evaluate()
        h.clock.advance(SessionEngine.lidSettle + 0.1)
        #expect(await h.engine.evaluate().lowPowerHeld == false)

        let undocked = await h.engine.setExternalDisplay(false)
        #expect(undocked.lowPowerHeld)
    }

    /// Low Power Mode cannot be managed on this Mac (no plain lowpowermode
    /// line): pmset is not read again at every check.
    @Test func anUnmanageableLowPowerModeIsNotReadAgainAndAgain() async throws {
        let h = Harness(power: .init(sleepDisabled: false, lowPowerOnBattery: nil, lowPowerOnAC: nil))
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .percent(80), onExternalPower: true, thermal: .serious))
        _ = await h.engine.evaluate()
        let reads = h.power.reads
        for _ in 0..<3 { _ = await h.engine.evaluate() }
        #expect(h.power.reads == reads)
    }
}
