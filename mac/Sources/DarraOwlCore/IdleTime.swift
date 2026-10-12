import Foundation

/// The user's idle time without DarraOwl's own pointer moves ("Bouger la
/// souris"): those must not pass for someone at the Mac, or "Claude a fini"
/// would not reach the phone and an update would never install.
public enum IdleTime {
    /// DarraOwl's last own move, and the user's last move before it.
    public struct OwnMove: Equatable, Sendable {
        public var at: Date
        public var userMovedAt: Date
    }

    /// A move DarraOwl is about to make. `lastMoveAge`: seconds since the
    /// last pointer move, which may be DarraOwl's previous one.
    public static func ownMove(now: Date, lastMoveAge: TimeInterval, previous: OwnMove?) -> OwnMove {
        let lastMove = now.addingTimeInterval(-lastMoveAge)
        if let previous, abs(lastMove.timeIntervalSince(previous.at)) < 2 {
            return OwnMove(at: now, userMovedAt: previous.userMovedAt)
        }
        return OwnMove(at: now, userMovedAt: lastMove)
    }

    /// `others`: seconds since the last key, click or scroll. `moved`: since
    /// the last pointer move, whoever made it. A move within 2 s of
    /// DarraOwl's own is taken for it: the user's move before it counts.
    public static func seconds(others: TimeInterval, moved: TimeInterval, own: OwnMove?, now: Date) -> TimeInterval {
        var userMoved = moved
        if let own, abs(moved - now.timeIntervalSince(own.at)) < 2 {
            userMoved = now.timeIntervalSince(own.userMovedAt)
        }
        return min(others, userMoved)
    }
}
