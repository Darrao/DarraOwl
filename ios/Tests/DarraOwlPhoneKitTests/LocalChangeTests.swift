@testable import DarraOwlPhoneKit
import DarraOwlShared
import Foundation
import Testing

/// "+1 h" and "Arrêter" from the lock screen: which Mac states are its answer.
@Suite struct LocalChangeTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func state(endsAt: Date?, maxHours: Double = 12) -> MacState {
        var settings = PowerSettings.default
        settings.maxSessionDuration = maxHours * 3600
        let session = endsAt.map { Session(startedAt: t0.addingTimeInterval(-600), endsAt: $0, origin: .menuBar) }
        return MacState(macID: UUID(), macName: "MacBook", updatedAt: t0, power: .awake, session: session,
                        powerSnapshot: nil, lowPowerActive: false, pausedApps: [], network: nil, dockerPaused: false, settings: settings)
    }

    /// The screen showed an old end: the Mac had moved it later on its own.
    /// That older state is not the answer; the answer, later still, is.
    @Test func anOlderStateEndingLaterIsNotTheAnswer() {
        let shown = t0.addingTimeInterval(3600)
        let change = LocalChange(kind: .extended(baseline: shown, seconds: 3600, firedAt: t0), until: t0.addingTimeInterval(70))
        #expect(!change.isShown(by: state(endsAt: shown.addingTimeInterval(1800))))
        #expect(change.isShown(by: state(endsAt: shown.addingTimeInterval(5400))))
    }

    /// Capped by the Mac: the answer ends before "+1 h" and still counts.
    @Test func aCappedAnswerCounts() {
        let shown = t0.addingTimeInterval(3.5 * 3600)
        let change = LocalChange(kind: .extended(baseline: shown, seconds: 3600, firedAt: t0), until: t0.addingTimeInterval(70))
        #expect(!change.isShown(by: state(endsAt: shown, maxHours: 4)), "from before the command")
        #expect(change.isShown(by: state(endsAt: t0.addingTimeInterval(4 * 3600 + 3), maxHours: 4)))
    }

    @Test func aStopShowsOnceNothingRuns() {
        let change = LocalChange(kind: .stopped, until: t0.addingTimeInterval(70))
        #expect(!change.isShown(by: state(endsAt: t0.addingTimeInterval(600))))
        #expect(change.isShown(by: state(endsAt: nil)))
    }
}
