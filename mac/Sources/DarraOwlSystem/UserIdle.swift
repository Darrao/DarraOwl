import CoreGraphics
import DarraOwlCore
import Foundation
import Synchronization

/// Seconds since the user last typed, clicked, scrolled or moved the
/// pointer. Read per input type: the activity presence mode declares every
/// minute resets the overall idle time, but it is not an input event. The
/// pointer moves of "Bouger la souris" are not the user's either.
public enum UserIdle {
    static let inputTypes: [CGEventType] = [
        .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]
    private static let ownMove = Mutex<Date?>(nil)

    /// Called by the mouse nudge as it moves the pointer.
    public static func noteOwnMove() {
        ownMove.withLock { $0 = Date() }
    }

    public static func seconds() -> TimeInterval {
        let others = inputTypes.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        let moved = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let own = ownMove.withLock { $0 }.map { Date().timeIntervalSince($0) }
        return IdleTime.seconds(others: others, moved: moved, ownMove: own)
    }
}
