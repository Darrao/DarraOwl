import CoreGraphics
import Foundation

/// Seconds since the user last typed, clicked, scrolled or moved the
/// pointer. Read per input type: the activity presence mode declares every
/// minute resets the overall idle time, but it is not an input event.
public enum UserIdle {
    static let inputTypes: [CGEventType] = [
        .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ]

    public static func seconds() -> TimeInterval {
        inputTypes.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }
}
