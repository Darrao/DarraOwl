import DarraOwlShared
import Foundation

/// A command's effect shown on the lock screen before the Mac's answer:
/// states that do not show it yet are taken for ones from before the
/// command, until the answer shows or the command expired.
public struct LocalChange: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "+N" on a timed session whose end on screen was `baseline`.
        case extended(baseline: Date, seconds: TimeInterval, firedAt: Date)
        case stopped
    }

    public var kind: Kind
    /// Past this the command has expired: the Mac's state is right again.
    public var until: Date

    public init(kind: Kind, until: Date) {
        self.kind = kind
        self.until = until
    }

    /// The state shows the change, or that nothing runs any more: then it
    /// is the Mac's word again. An extension is judged with the cap the
    /// state carries: a capped answer counts, an older state that merely
    /// ends later than the screen showed does not.
    public func isShown(by state: MacState) -> Bool {
        guard state.power == .awake, let session = state.session else { return true }
        switch kind {
        case .stopped:
            return false
        case let .extended(baseline, seconds, firedAt):
            let expected = Session.extendedEnd(baseline, by: seconds, now: firedAt, maxDuration: state.settings.maxSessionDuration)
            return session.endsAt >= expected.addingTimeInterval(-5)
        }
    }
}
