import Foundation

/// The user's idle time without DarraOwl's own pointer moves ("Bouger la
/// souris"): those must not pass for someone at the Mac, or "Claude a fini"
/// would not reach the phone and an update would never install.
public enum IdleTime {
    /// `others`: seconds since the last key, click or scroll. `moved`: since
    /// the last pointer move, whoever made it. `ownMove`: since DarraOwl's
    /// own last move, if any. A move within 2 s of DarraOwl's own is taken
    /// for it.
    public static func seconds(others: TimeInterval, moved: TimeInterval, ownMove: TimeInterval?) -> TimeInterval {
        if let ownMove, abs(moved - ownMove) < 2 { return others }
        return min(others, moved)
    }
}
