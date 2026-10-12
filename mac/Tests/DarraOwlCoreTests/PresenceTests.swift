@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

final class FakeAsserter: PresenceAsserting {
    var held = false
    /// What is held: the display (true) or only the system (false).
    var display = false
    var activity = 0
    var failHold = false

    func hold(display: Bool) throws {
        if failHold { throw FakeError(message: "assertion refused") }
        held = true
        self.display = display
    }

    func release() { held = false }
    func declareActivity() { activity += 1 }
}

@MainActor
@Suite struct PresenceTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let battery = PowerSnapshot(battery: .percent(80), onExternalPower: false, thermal: .nominal)

    @Test func indefiniteHoldsAndDeclaresActivityEveryMinute() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: nil, now: t0)
        #expect(a.held && a.activity == 1)

        p.tick(now: t0.addingTimeInterval(30), power: battery, settings: .default)
        #expect(a.activity == 1)
        p.tick(now: t0.addingTimeInterval(60), power: battery, settings: .default)
        #expect(a.activity == 2)
        p.tick(now: t0.addingTimeInterval(10 * 86_400), power: battery, settings: .default)
        #expect(p.isActive, "no end time means it never stops by itself")
    }

    @Test func stopsAtEndTimeAndReleases() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: t0.addingTimeInterval(3600), now: t0)
        p.tick(now: t0.addingTimeInterval(3600), power: battery, settings: .default)
        #expect(!p.isActive && !a.held)
        #expect(p.lastStop == .timeUp)
    }

    @Test func stopsUnderBatteryEndFloor() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: nil, now: t0)
        p.tick(now: t0, power: PowerSnapshot(battery: .percent(10), onExternalPower: false, thermal: .nominal), settings: .default)
        #expect(p.lastStop == .batteryLow)
        #expect(!a.held)
    }

    @Test func chargerKeepsItGoing() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: nil, now: t0)
        p.tick(now: t0, power: PowerSnapshot(battery: .percent(10), onExternalPower: true, thermal: .nominal), settings: .default)
        #expect(p.isActive)
    }

    @Test func criticalHeatStops() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: nil, now: t0)
        p.tick(now: t0, power: PowerSnapshot(battery: .percent(90), onExternalPower: true, thermal: .critical), settings: .default)
        #expect(p.lastStop == .thermalCritical)
    }

    @Test func unknownPowerKeepsItGoing() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: nil, now: t0)
        p.tick(now: t0.addingTimeInterval(120), power: nil, settings: .default)
        #expect(p.isActive && a.activity == 2)
    }

    @Test func refusedAssertionLeavesItOff() {
        let a = FakeAsserter()
        a.failHold = true
        let p = PresenceController(asserter: a)
        #expect(throws: FakeError.self) { try p.start(until: nil, now: t0) }
        #expect(!p.isActive)
    }

    @Test func lidClosedReleasesTheAssertion() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: nil, now: t0)
        p.setSuspended(true)
        #expect(!a.held && p.isActive)
        p.tick(now: t0.addingTimeInterval(120), power: battery, settings: .default)
        #expect(a.activity == 1, "no activity declared while the lid is closed")
        p.setSuspended(false)
        #expect(a.held)
    }

    @Test func changingTheEndKeepsOneAssertion() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: t0.addingTimeInterval(60), now: t0)
        a.failHold = true // a second hold would throw
        try p.start(until: nil, now: t0)
        #expect(p.isActive && p.until == nil)
    }

    /// Turned on from the phone with the lid closed: nothing lights the panel.
    @Test func startingWithTheLidClosedHoldsNothingUntilItOpens() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        p.setSuspended(true, now: t0)
        try p.start(until: nil, now: t0)
        #expect(!a.held && a.activity == 0)
        p.tick(now: t0.addingTimeInterval(120), power: battery, settings: .default)
        #expect(a.activity == 0)
        p.setSuspended(false, now: t0.addingTimeInterval(130))
        #expect(a.held && a.activity == 1)
    }

    /// "Éteindre l'écran" from the phone: no activity until the display
    /// wakes, but the Mac itself stays awake.
    @Test func aDisplayTurnedOffOnPurposeStaysOffAndTheMacAwake() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: nil, now: t0)
        #expect(a.held && a.display)
        p.setQuiet(true, now: t0)
        #expect(a.held && !a.display, "system kept awake, display free to sleep")
        p.tick(now: t0.addingTimeInterval(120), power: battery, settings: .default)
        #expect(a.activity == 1)
        p.setQuiet(false, now: t0.addingTimeInterval(200))
        #expect(a.held && a.display && a.activity == 2)
    }

    /// Display off from the phone, then "Toujours actif": the Mac stays
    /// awake and the display stays dark until someone wakes it.
    @Test func presenceTurnedOnAfterTheDisplayWentOffHoldsTheSystem() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        p.setQuiet(true, now: t0)
        try p.start(until: nil, now: t0)
        #expect(a.held && !a.display && a.activity == 0)
        p.stop(.user)
        #expect(!a.held)
    }

    /// Option off (the default): a closed lid declares nothing, session or not.
    @Test func aClosedLidDeclaresNothingByDefault() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        try p.start(until: nil, now: t0)
        p.setSessionRunning(true, now: t0)
        p.setSuspended(true, now: t0)
        p.tick(now: t0.addingTimeInterval(600), power: battery, settings: .default)
        #expect(!a.held && a.activity == 1)
    }

    /// Option on, during a session: activity every 4 minutes with the lid
    /// closed, nothing held on the display, and the display darkened again.
    @Test func withTheOptionAClosedLidStillDeclaresActivityDuringASession() throws {
        let a = FakeAsserter()
        let p = PresenceController(asserter: a)
        var darkened = 0
        p.onClosedActivity = { darkened += 1 }
        p.setWhileClosed(true, now: t0)
        try p.start(until: nil, now: t0)
        p.setSessionRunning(true, now: t0)
        p.setSuspended(true, now: t0)
        #expect(!a.held, "no display assertion under the lid")
        #expect(a.activity == 2 && darkened == 1)

        p.tick(now: t0.addingTimeInterval(120), power: battery, settings: .default)
        #expect(a.activity == 2, "not every minute: each one wakes the display")
        p.tick(now: t0.addingTimeInterval(PresenceController.closedActivityInterval), power: battery, settings: .default)
        #expect(a.activity == 3 && darkened == 2)

        // The session ends: a closed lid sleeps, nothing more is declared.
        p.setSessionRunning(false, now: t0.addingTimeInterval(300))
        p.tick(now: t0.addingTimeInterval(900), power: battery, settings: .default)
        #expect(a.activity == 3)

        // Lid open again: back to the display and every minute.
        p.setSessionRunning(true, now: t0.addingTimeInterval(901))
        p.setSuspended(false, now: t0.addingTimeInterval(902))
        #expect(a.held && a.display)
    }
}
