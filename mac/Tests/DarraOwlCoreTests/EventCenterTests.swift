@testable import DarraOwlCore
import DarraOwlShared
import Foundation
import Testing

@Suite struct EventCenterTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let session = Session(startedAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_007_200), origin: .menuBar)

    func input(at offset: TimeInterval, session: Session?, battery: Int = 80, ac: Bool = false, thermal: ThermalLevel = .nominal,
               lid: Bool? = false, toEmpty: Int? = nil, network: Bool = true, bytes: Int64? = nil, end: SessionEndRecord? = nil,
               alerts: AlertSettings = AlertSettings()) -> EventCenter.Input {
        EventCenter.Input(now: t0.addingTimeInterval(offset), session: session,
                          power: PowerSnapshot(battery: .percent(battery), onExternalPower: ac, thermal: thermal, lidClosed: lid, minutesToEmpty: toEmpty),
                          networkUp: network, sessionBytes: bytes, lastEnd: end, alerts: alerts)
    }

    @Test func firstUpdateReplaysNothing() {
        var c = EventCenter()
        let end = SessionEndRecord(sessionID: UUID(), startedAt: t0, endedAt: t0, reason: .expired, failures: [])
        #expect(c.update(input(at: 0, session: session, thermal: .serious, end: end)).isEmpty)
    }

    @Test func endingSoonOnce() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session))
        #expect(c.update(input(at: 6000, session: session)).isEmpty)
        #expect(c.update(input(at: 6601, session: session)).map(\.kind) == [.endingSoon])
        #expect(c.update(input(at: 6700, session: session)).isEmpty)
    }

    @Test func batteryWillNotLast() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session))
        let events = c.update(input(at: 60, session: session, battery: 30, toEmpty: 45))
        #expect(events.map(\.kind) == [.batteryShort])
        #expect(c.update(input(at: 120, session: session, battery: 29, toEmpty: 40)).isEmpty)
    }

    @Test func noBatteryWarningOnCharger() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session, ac: true))
        #expect(c.update(input(at: 60, session: session, ac: true, toEmpty: 10)).isEmpty)
    }

    @Test func heatOnceEachTime() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session))
        #expect(c.update(input(at: 10, session: session, thermal: .serious)).map(\.kind) == [.hot])
        #expect(c.update(input(at: 20, session: session, thermal: .critical)).isEmpty)
        _ = c.update(input(at: 30, session: session, thermal: .nominal))
        #expect(c.update(input(at: 40, session: session, thermal: .serious)).map(\.kind) == [.hot])
    }

    func locked(_ isLocked: Bool, at offset: TimeInterval, session: Session?, lid: Bool = false, presence: Bool = false,
                idle: TimeInterval = 300, alerts: AlertSettings = AlertSettings()) -> EventCenter.Input {
        var i = input(at: offset, session: session, lid: lid, alerts: alerts)
        i.screenLocked = isLocked
        i.presenceActive = presence
        i.userIdle = idle
        return i
    }

    /// Locked during a session or Toujours actif: Teams shows Away.
    @Test func aLockAfterIdleIsReported() {
        var c = EventCenter()
        _ = c.update(locked(false, at: 0, session: session))
        #expect(c.update(locked(true, at: 5, session: session, idle: 1200)).map(\.kind) == [.macLocked])
        var p = EventCenter()
        _ = p.update(locked(false, at: 0, session: nil, presence: true))
        #expect(p.update(locked(true, at: 5, session: nil, presence: true, idle: 1200)).map(\.kind) == [.macLocked])
    }

    /// The user locking it on purpose, lid open, is not news; lid closed, it is.
    @Test func aDeliberateLockIsNotReported() {
        var c = EventCenter()
        _ = c.update(locked(false, at: 0, session: session))
        #expect(c.update(locked(true, at: 5, session: session, idle: 3)).isEmpty)
        var closed = EventCenter()
        _ = closed.update(locked(false, at: 0, session: session, lid: true))
        #expect(closed.update(locked(true, at: 5, session: session, lid: true, idle: 3)).map(\.kind) == [.macLocked])
    }

    /// Nothing running, the option off, or a lock moments after the last one: quiet.
    @Test func lockReportsAreRareAndOptional() {
        var idle = EventCenter()
        _ = idle.update(locked(false, at: 0, session: nil))
        #expect(idle.update(locked(true, at: 5, session: nil)).isEmpty)
        var off = EventCenter()
        _ = off.update(locked(false, at: 0, session: session, alerts: AlertSettings(macLocked: false)))
        #expect(off.update(locked(true, at: 5, session: session, alerts: AlertSettings(macLocked: false))).isEmpty)
        var c = EventCenter()
        _ = c.update(locked(false, at: 0, session: session))
        #expect(c.update(locked(true, at: 5, session: session)).count == 1)
        _ = c.update(locked(false, at: 60, session: session))
        #expect(c.update(locked(true, at: 120, session: session)).isEmpty, "within ten minutes")
        _ = c.update(locked(false, at: 700, session: session))
        #expect(c.update(locked(true, at: 710, session: session)).count == 1)
    }

    @Test func antitheft() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session, ac: true, lid: true))
        #expect(c.update(input(at: 10, session: session, ac: true, lid: false)).map(\.kind) == [.lidOpened])
        #expect(c.update(input(at: 20, session: session, ac: false, lid: false)).map(\.kind) == [.chargerUnplugged])
    }

    @Test func antitheftOff() {
        var c = EventCenter()
        let off = AlertSettings(antitheft: false)
        _ = c.update(input(at: 0, session: session, ac: true, lid: true, alerts: off))
        #expect(c.update(input(at: 10, session: session, ac: false, lid: false, alerts: off)).isEmpty)
    }

    @Test func networkOutageReportedWhenOver() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session))
        #expect(c.update(input(at: 10, session: session, network: false)).isEmpty)
        #expect(c.update(input(at: 200, session: session)).map(\.kind) == [.networkRestored])
        _ = c.update(input(at: 210, session: session, network: false))
        #expect(c.update(input(at: 240, session: session)).isEmpty, "30 s is below the threshold")
    }

    @Test func dataThreshold() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session, bytes: 0))
        #expect(c.update(input(at: 10, session: session, bytes: 999_000_000)).isEmpty)
        #expect(c.update(input(at: 20, session: session, bytes: 1_000_000_000)).map(\.kind) == [.dataThreshold])
    }

    @Test func recapAtEnd() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session, battery: 90, bytes: 0))
        _ = c.update(input(at: 60, session: session, battery: 80, bytes: 350_000_000))
        let end = SessionEndRecord(sessionID: session.id, startedAt: t0, endedAt: t0.addingTimeInterval(5400), reason: .userStopped, failures: [])
        let events = c.update(input(at: 5400, session: nil, battery: 70, bytes: 400_000_000, end: end))
        #expect(events.map(\.kind) == [.ended])
        #expect(events.first?.body == "Arrêtée après 1 h 30. Batterie : 20 points. Data : 400 Mo.")
        #expect(c.update(input(at: 5410, session: nil, end: end)).isEmpty)
    }

    @Test func newSessionResetsOnceEvents() {
        var c = EventCenter()
        _ = c.update(input(at: 0, session: session))
        _ = c.update(input(at: 6601, session: session))
        let next = Session(startedAt: t0.addingTimeInterval(7200), endsAt: t0.addingTimeInterval(9000), origin: .phone)
        #expect(c.update(input(at: 7200, session: next)).isEmpty)
        #expect(c.update(input(at: 8500, session: next)).map(\.kind) == [.endingSoon])
    }
}

@Suite struct DataMeterTests {
    @Test func countsAndSurvivesCounterReset() {
        var m = DataMeter()
        let s = UUID()
        #expect(m.update(session: s, counter: 1000) == 0)
        #expect(m.update(session: s, counter: 1500) == 500)
        #expect(m.update(session: s, counter: 200) == 500, "counter reset: new baseline")
        #expect(m.update(session: s, counter: 300) == 600)
        #expect(m.update(session: nil, counter: 400) == nil)
        #expect(m.update(session: UUID(), counter: 400) == 0)
    }
}
