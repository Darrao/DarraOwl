@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

final class FakeAsserter: PresenceAsserting {
    var held = false
    var activity = 0
    var failHold = false

    func hold() throws {
        if failHold { throw FakeError(message: "assertion refused") }
        held = true
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
}
