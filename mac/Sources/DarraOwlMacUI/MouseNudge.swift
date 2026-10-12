import ApplicationServices
import CoreGraphics
import DarraOwlSystem
import Foundation

/// Moves the pointer one pixel and back, as a real mouse would: some apps
/// (Teams) may count only real input events, not declared activity. Posting
/// input needs the Accessibility permission, which the user grants.
enum MouseNudge {
    static var allowed: Bool { AXIsProcessTrusted() }

    /// Set once DarraOwl asked for Accessibility: the uninstaller then
    /// reminds to take it back.
    static let askedKey = "presenceMouseNudgeAsked"

    /// Shows macOS's own prompt pointing to Réglages Système >
    /// Confidentialité et sécurité > Accessibilité.
    static func askPermission() {
        UserDefaults.standard.set(true, forKey: askedKey)
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Never under the user's hand: not while a button is down, nor when
    /// the user typed, clicked or moved in the last few seconds (no need
    /// then anyway, and a hidden pointer would show while typing).
    static func nudge() {
        guard allowed, let here = CGEvent(source: nil)?.location, UserIdle.seconds() >= 5,
              ![CGMouseButton.left, .right, .center].contains(where: { CGEventSource.buttonState(.hidSystemState, button: $0) })
        else { return }
        // Known as DarraOwl's own: not taken for someone at the Mac.
        UserIdle.noteOwnMove()
        let source = CGEventSource(stateID: .hidSystemState)
        for point in [CGPoint(x: here.x + 1, y: here.y), here] {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
}
