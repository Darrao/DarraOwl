@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

@Suite struct SessionStartTests {
    @Test func journalIsWrittenBeforeSleepIsDisabled() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.events.clear()

        let status = try await h.engine.start(duration: 3600, origin: .menuBar)

        #expect(Array(h.events.all.prefix(2)) == ["save journal", "pmset disablesleep 1"])
        #expect(status.session?.endsAt == h.clock.now().addingTimeInterval(3600))
        #expect(status.sleepHeld)
        #expect(h.power.current.sleepDisabled)
        #expect(h.journal.value?.sleep == SleepEntry(previouslyDisabled: false))
    }

    @Test func journalWriteFailureAppliesNothing() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.journal.update { $0.failWrites = true }

        await #expect(throws: EngineError.self) {
            _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        }
        #expect(!h.power.current.sleepDisabled)
        #expect(await h.engine.status().session == nil)
    }

    @Test func pmsetFailureRollsBack() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.power.update { $0.failSetSleep = true }

        await #expect(throws: EngineError.self) {
            _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        }
        let status = await h.engine.status()
        #expect(status.session == nil)
        #expect(!status.sleepHeld)
        #expect(h.journal.value?.session == nil)
        #expect(h.journal.value?.sleep == nil)
    }

    @Test(arguments: [0, 30, 13 * 3600] as [TimeInterval])
    func durationOutsideLimitsIsRefused(duration: TimeInterval) async {
        let h = Harness()
        _ = await h.engine.reconcile()
        await #expect(throws: EngineError.invalidDuration(min: 60, max: 12 * 3600)) {
            _ = try await h.engine.start(duration: duration, origin: .menuBar)
        }
        #expect(h.events.all.isEmpty)
    }

    @Test func secondStartIsRefused() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        await #expect(throws: EngineError.alreadyActive) {
            _ = try await h.engine.start(duration: 3600, origin: .phone)
        }
    }

    @Test func lowBatteryRefusesStart() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.source.set(PowerSnapshot(battery: .percent(10), onExternalPower: false, thermal: .nominal))
        await #expect(throws: EngineError.refused(.batteryLow)) {
            _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        }
    }

    @Test func lowBatteryOnChargerIsAllowed() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.source.set(PowerSnapshot(battery: .percent(10), onExternalPower: true, thermal: .nominal))
        let status = try await h.engine.start(duration: 3600, origin: .menuBar)
        #expect(status.session != nil)
    }

    @Test func criticalHeatRefusesStart() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        h.source.set(PowerSnapshot(battery: .percent(90), onExternalPower: true, thermal: .critical))
        await #expect(throws: EngineError.refused(.thermalCritical)) {
            _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        }
    }

    @Test func sleepAlreadyDisabledByOthersIsLeftDisabled() async throws {
        let h = Harness(power: .init(sleepDisabled: true, lowPowerOnBattery: false, lowPowerOnAC: false))
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        #expect(!h.events.all.contains("pmset disablesleep 1"))
        _ = try await h.engine.stop(reason: .userStopped)
        #expect(h.power.current.sleepDisabled, "the undo restores the previous value, which was disabled")
        #expect(!h.events.all.contains("pmset disablesleep 0"))
    }
}

@Suite struct SessionEndTests {
    @Test func expiryRestoresSleep() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 600, origin: .menuBar)
        h.clock.advance(600)

        let status = await h.engine.evaluate()

        #expect(status.session == nil)
        #expect(status.lastEnd?.reason == .expired)
        #expect(status.lastEnd?.failures == [])
        #expect(!h.power.current.sleepDisabled)
        #expect(h.journal.value?.isClean == true)
    }

    @Test func stopRestoresSleep() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 600, origin: .menuBar)
        let status = try await h.engine.stop(reason: .userStopped)
        #expect(status.lastEnd?.reason == .userStopped)
        #expect(!h.power.current.sleepDisabled)
    }

    @Test func failedUndoStaysJournaledAndIsRetried() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 600, origin: .menuBar)
        h.power.update { $0.failSetSleep = false }

        var status = try await h.engine.stop(reason: .userStopped)
        #expect(status.sleepHeld)
        #expect(status.pendingUndo.count == 1)
        #expect(status.lastEnd?.failures.count == 1)
        #expect(h.journal.value?.sleep != nil)
        #expect(h.power.current.sleepDisabled)

        h.power.update { $0.failSetSleep = nil }
        status = await h.engine.evaluate()
        #expect(!status.sleepHeld)
        #expect(status.pendingUndo.isEmpty)
        #expect(!h.power.current.sleepDisabled)
    }

    @Test func startIsRefusedWhileUndoIsPending() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 600, origin: .menuBar)
        h.power.update { $0.failSetSleep = false }
        _ = try await h.engine.stop(reason: .userStopped)

        await #expect(throws: EngineError.self) {
            _ = try await h.engine.start(duration: 600, origin: .menuBar)
        }
    }

    @Test func batteryUnderEndFloorEndsSession() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .percent(14), onExternalPower: false, thermal: .nominal))

        let status = await h.engine.evaluate()
        #expect(status.session == nil)
        #expect(status.lastEnd?.reason == .batteryLow)
        #expect(!h.power.current.sleepDisabled)
    }

    @Test func criticalHeatEndsSession() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .percent(90), onExternalPower: true, thermal: .critical))

        let status = await h.engine.evaluate()
        #expect(status.lastEnd?.reason == .thermalCritical)
    }

    @Test func secondUnreadableBatteryReadEndsSession() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .unreadable, onExternalPower: false, thermal: .nominal))

        #expect(await h.engine.evaluate().session != nil, "one miss is tolerated")
        let status = await h.engine.evaluate()
        #expect(status.lastEnd?.reason == .batteryUnreadable)
    }

    @Test func terminationEndsSession() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        await h.engine.handleTermination()
        let status = await h.engine.status()
        #expect(status.lastEnd?.reason == .helperTerminated)
        #expect(!h.power.current.sleepDisabled)
    }
}

@Suite struct ExtendTests {
    @Test func extendAddsTime() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        let start = try await h.engine.start(duration: 3600, origin: .menuBar)
        let status = try await h.engine.extend(by: 1800)
        #expect(status.session?.endsAt == start.session!.endsAt.addingTimeInterval(1800))
        #expect(h.journal.value?.session?.endsAt == status.session?.endsAt)
    }

    @Test func extendIsCappedAtMaximumFromNow() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 11 * 3600, origin: .menuBar)
        let status = try await h.engine.extend(by: 3600 * 3)
        #expect(status.session?.endsAt == h.clock.now().addingTimeInterval(12 * 3600))
    }

    @Test func extendWithoutSessionFails() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        await #expect(throws: EngineError.noActiveSession) {
            _ = try await h.engine.extend(by: 1800)
        }
    }

    @Test func lowerCapShortensRunningSession() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 10 * 3600, origin: .menuBar)
        let status = try await h.engine.updateSettings(PowerSettings(maxSessionDuration: 4 * 3600))
        #expect(status.session?.endsAt == h.clock.now().addingTimeInterval(4 * 3600))
        #expect(h.settings.value?.maxSessionDuration == TimeInterval(4 * 3600))
    }

    @Test func invalidSettingsAreRefused() async {
        let h = Harness()
        _ = await h.engine.reconcile()
        await #expect(throws: EngineError.invalidSettings(.endFloorOutOfRange)) {
            _ = try await h.engine.updateSettings(PowerSettings(lowPowerFloor: 40, endFloor: 1))
        }
    }
}

@Suite struct LowPowerTests {
    @Test func batteryUnderFloorSwitchesLowPowerOnAndRestoresEachProfile() async throws {
        // The user keeps Low Power Mode on battery only.
        let h = Harness(power: .init(sleepDisabled: false, lowPowerOnBattery: true, lowPowerOnAC: false))
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.events.clear()
        h.source.set(PowerSnapshot(battery: .percent(35), onExternalPower: false, thermal: .nominal))

        var status = await h.engine.evaluate()
        #expect(status.lowPowerHeld)
        #expect(h.events.all == ["save journal", "pmset lowpowermode b=1 c=1"])
        #expect(h.journal.value?.lowPower == LowPowerEntry(previousOnBattery: true, previousOnAC: false))

        status = try await h.engine.stop(reason: .userStopped)
        #expect(!status.lowPowerHeld)
        #expect(h.power.current.lowPowerOnBattery == true)
        #expect(h.power.current.lowPowerOnAC == false)
    }

    @Test func chargerRestoresLowPowerDuringSession() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .percent(35), onExternalPower: false, thermal: .nominal))
        _ = await h.engine.evaluate()
        h.source.set(PowerSnapshot(battery: .percent(35), onExternalPower: true, thermal: .nominal))
        let status = await h.engine.evaluate()
        #expect(!status.lowPowerHeld)
        #expect(h.power.current.lowPowerOnBattery == false)
        #expect(status.session != nil)
    }

    @Test func seriousHeatSwitchesLowPowerOn() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .percent(90), onExternalPower: true, thermal: .serious))
        let status = await h.engine.evaluate()
        #expect(status.lowPowerHeld)
        #expect(h.power.current.lowPowerOnAC == true)
    }

    @Test func lowPowerAlreadyOnEverywhereIsNotClaimed() async throws {
        let h = Harness(power: .init(sleepDisabled: false, lowPowerOnBattery: true, lowPowerOnAC: true))
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.source.set(PowerSnapshot(battery: .percent(35), onExternalPower: false, thermal: .nominal))
        let status = await h.engine.evaluate()
        #expect(!status.lowPowerHeld)
        _ = try await h.engine.stop(reason: .userStopped)
        #expect(h.power.current.lowPowerOnBattery == true && h.power.current.lowPowerOnAC == true)
    }
}

@Suite struct ReconcileTests {
    @Test func expiredSessionIsRestoredAtBoot() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        var journal = Journal()
        journal.session = Session(startedAt: clock.addingTimeInterval(-7200), endsAt: clock.addingTimeInterval(-60), origin: .menuBar)
        journal.sleep = SleepEntry(previouslyDisabled: false)
        let h = Harness(power: .init(sleepDisabled: true, lowPowerOnBattery: false, lowPowerOnAC: false), journal: journal)

        let status = await h.engine.reconcile()

        #expect(status.session == nil)
        #expect(status.lastEnd?.reason == .expired)
        #expect(!h.power.current.sleepDisabled)
    }

    @Test func validSessionIsResumedAndSleepHeldAgain() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        var journal = Journal()
        journal.session = Session(startedAt: clock.addingTimeInterval(-600), endsAt: clock.addingTimeInterval(3000), origin: .menuBar)
        journal.sleep = SleepEntry(previouslyDisabled: false)
        // After a reboot the setting may have been reset.
        let h = Harness(power: .init(sleepDisabled: false, lowPowerOnBattery: false, lowPowerOnAC: false), journal: journal)

        let status = await h.engine.reconcile()

        #expect(status.session != nil)
        #expect(h.power.current.sleepDisabled)
    }

    @Test func dirtyJournalWithoutSessionIsRestored() async {
        var journal = Journal()
        journal.lowPower = LowPowerEntry(previousOnBattery: false, previousOnAC: false)
        let h = Harness(power: .init(sleepDisabled: false, lowPowerOnBattery: true, lowPowerOnAC: true), journal: journal)

        let status = await h.engine.reconcile()

        #expect(!status.lowPowerHeld)
        #expect(h.power.current.lowPowerOnBattery == false)
        #expect(h.power.current.lowPowerOnAC == false)
    }

    @Test func unreadableJournalIsSetAsideAndSleepRestored() async {
        let h = Harness(power: .init(sleepDisabled: true, lowPowerOnBattery: false, lowPowerOnAC: false))
        h.journal.update { $0.unreadable = true }

        let status = await h.engine.reconcile()

        #expect(h.journal.snapshot.quarantined == 1)
        #expect(!h.power.current.sleepDisabled)
        #expect(status.notices.contains { $0.contains("Journal illisible") })
    }

    @Test func sessionEndingImplausiblyFarIsEnded() async {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        var journal = Journal()
        journal.session = Session(startedAt: clock, endsAt: clock.addingTimeInterval(30 * 24 * 3600), origin: .menuBar)
        journal.sleep = SleepEntry(previouslyDisabled: false)
        let h = Harness(power: .init(sleepDisabled: true, lowPowerOnBattery: false, lowPowerOnAC: false), journal: journal)
        let status = await h.engine.reconcile()
        #expect(status.session == nil)
        #expect(!h.power.current.sleepDisabled)
    }
}

@Suite struct UninstallTests {
    @Test func prepareUninstallEndsRestoresAndRemovesFiles() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)

        let status = await h.engine.prepareUninstall()

        #expect(status.lastEnd?.reason == .uninstall)
        #expect(!h.power.current.sleepDisabled)
        #expect(h.journal.snapshot.removed)
        #expect(h.settings.snapshot.removed)
        await #expect(throws: EngineError.uninstalling) {
            _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        }
    }

    @Test func prepareUninstallKeepsFilesWhenUndoFails() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .menuBar)
        h.power.update { $0.failSetSleep = false }

        let status = await h.engine.prepareUninstall()

        #expect(!status.pendingUndo.isEmpty)
        #expect(!h.journal.snapshot.removed)
    }
}

@Suite struct SleepNowTests {
    @Test func sleepNowRestoresBeforeSleeping() async throws {
        let h = Harness()
        _ = await h.engine.reconcile()
        _ = try await h.engine.start(duration: 3600, origin: .phone)
        h.events.clear()
        let status = try await h.engine.sleepNow()
        #expect(status.lastEnd?.reason == .sleepRequested)
        let events = h.events.all
        #expect(events.firstIndex(of: "pmset disablesleep 0")! < events.firstIndex(of: "pmset sleepnow")!)
    }
}
