@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

/// What the 2026-10-12 review found in the engine.
@Suite struct EngineSafetyTests {
    func process(_ h: Harness, pid: Int32, start: Int64) -> WatchedProcess {
        h.processes.set(pid, FakeProcesses.state(uid: 501, start: start))
        return WatchedProcess(pid: pid, name: "job\(pid)", project: nil, startSeconds: start, startMicros: 7)
    }

    /// Two `darraowl run` at once: both must be followed by one session.
    @Test func concurrentWatchesShareOneSession() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.power.update { $0.delay = .milliseconds(20) }
        let a = process(h, pid: 300, start: 1000)
        let b = process(h, pid: 301, start: 2000)

        async let first = h.engine.watch(a, seconds: nil, origin: .cli, requesterUID: 501)
        async let second = h.engine.watch(b, seconds: nil, origin: .cli, requesterUID: 501)
        _ = try await (first, second)

        let session = try #require(await h.engine.status().session)
        #expect(Set(session.watching.map(\.pid)) == [300, 301])
        // job 301 ends: job 300 still runs, the Mac stays awake.
        h.processes.set(301, nil)
        #expect(await h.engine.evaluate().session != nil)
        #expect(h.power.current.sleepDisabled)
    }

    /// A stop arriving while `disablesleep 1` is still running must not leave
    /// sleep disabled with a clean journal.
    @Test func aStopDuringStartStillRestoresSleep() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.power.update { $0.delay = .milliseconds(20) }
        async let started = h.engine.start(duration: 3600, origin: .menuBar)
        try await Task.sleep(for: .milliseconds(5))
        async let stopped = try? h.engine.stop(reason: .userStopped)
        _ = try await started
        _ = await stopped
        let status = await h.engine.status()
        if status.session == nil {
            #expect(!h.power.current.sleepDisabled)
            #expect(!status.sleepHeld)
        } else {
            #expect(h.power.current.sleepDisabled, "the stop came first and found nothing to stop")
        }
    }

    @Test func anExpiredSessionDoesNotBlockANewOne() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.clock.advance(3601)
        // The loop has not run yet.
        let status = try await h.engine.start(duration: 1800, origin: .cli)
        #expect(status.session?.origin == .cli)
        #expect(status.lastEnd?.reason == .expired)
    }

    @Test func aClockMovedBackKeepsTheEndWithinTheCap() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.clock.advance(-2 * 86_400)
        let status = await h.engine.evaluate()
        let session = try #require(status.session)
        #expect(session.endsAt <= h.clock.now().addingTimeInterval(PowerSettings.default.maxSessionDuration))
    }

    /// A MacBook Pro that reports `powermode` instead of `lowpowermode`.
    @Test func aMacWithoutLowPowerModeLineStillStartsAndLeavesItAlone() async throws {
        let h = Harness(power: .init(sleepDisabled: false, lowPowerOnBattery: nil, lowPowerOnAC: nil))
        h.source.set(PowerSnapshot(battery: .percent(30), onExternalPower: false, thermal: .nominal))
        _ = await h.engine.reconcile()
        let status = try await h.engine.start(duration: 3600, origin: .menuBar)
        #expect(status.session != nil)
        #expect(!status.lowPowerHeld)
        #expect(!h.events.all.contains { $0.hasPrefix("pmset lowpowermode") })
    }

    /// A desktop has no battery profile: only the AC one is touched and put back.
    @Test func aDesktopOnlyTouchesTheACProfile() async throws {
        let h = Harness(power: .init(sleepDisabled: false, lowPowerOnBattery: nil, lowPowerOnAC: false))
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .none, onExternalPower: true, thermal: .serious))
        #expect(await h.engine.evaluate().lowPowerHeld)
        #expect(h.events.all.contains("pmset lowpowermode b=- c=1"))
        _ = try await h.engine.stop(reason: .userStopped)
        #expect(h.events.all.contains("pmset lowpowermode b=- c=0"))
        #expect(h.power.current.lowPowerOnAC == false)
    }

    @Test func aFailingLowPowerModeIsNotRetriedEveryCheck() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.power.update { $0.failLowPower = true }
        h.source.set(PowerSnapshot(battery: .percent(30), onExternalPower: false, thermal: .nominal))
        h.events.clear()
        for _ in 0..<5 {
            _ = await h.engine.evaluate()
            h.clock.advance(2)
        }
        #expect(h.events.all.filter { $0.hasPrefix("pmset lowpowermode") }.isEmpty, "the failed tries are not logged as done")
        let reads = h.events.all.count
        #expect(reads < 20)
        h.clock.advance(SessionEngine.lowPowerRetryDelay)
        h.power.update { $0.failLowPower = false }
        #expect(await h.engine.evaluate().lowPowerHeld)
    }

    @Test func anUnreadableJournalPutsSleepBackEvenWhenPmsetCannotBeRead() async {
        let h = Harness(power: .init(sleepDisabled: true, lowPowerOnBattery: false, lowPowerOnAC: false))
        h.journal.update { $0.unreadable = true }
        h.power.update { $0.failRead = true }
        let status = await h.engine.reconcile()
        #expect(!h.power.current.sleepDisabled)
        #expect(!status.sleepHeld)
    }

    @Test func anUninstallThatStoppedHalfwayDoesNotBlockForever() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = await h.engine.prepareUninstall()
        await #expect(throws: EngineError.uninstalling) {
            _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        }
        h.clock.advance(16 * 60)
        #expect(try await h.engine.start(duration: 3600, origin: .menuBar).session != nil)
    }

    @Test func withoutASessionTheLidCountsAtOnce() async throws {
        let h = Harness()
        h.source.set(PowerSnapshot(battery: .percent(90), onExternalPower: true, thermal: .nominal, lidClosed: true))
        _ = await h.engine.reconcile()
        h.source.set(PowerSnapshot(battery: .percent(90), onExternalPower: true, thermal: .nominal, lidClosed: false))
        let status = try await h.engine.start(duration: 3600, origin: .menuBar)
        #expect(status.power?.lidClosed == false)
        #expect(!status.lowPowerHeld)
    }
}
