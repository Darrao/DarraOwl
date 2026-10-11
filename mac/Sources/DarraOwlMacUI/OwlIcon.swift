import AppKit

/// The monochrome owl of the menu bar, drawn as a template image so macOS
/// tints it. Eyes open during a session, closed otherwise.
enum OwlIcon {
    static func image(awake: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.set()

            // Head and body.
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 4, y: 15.5))
            body.line(to: NSPoint(x: 6.5, y: 13.6))
            body.curve(to: NSPoint(x: 11.5, y: 13.6), controlPoint1: NSPoint(x: 8, y: 14.3), controlPoint2: NSPoint(x: 10, y: 14.3))
            body.line(to: NSPoint(x: 14, y: 15.5))
            body.curve(to: NSPoint(x: 9, y: 1.5), controlPoint1: NSPoint(x: 16, y: 9), controlPoint2: NSPoint(x: 14, y: 1.5))
            body.curve(to: NSPoint(x: 4, y: 15.5), controlPoint1: NSPoint(x: 4, y: 1.5), controlPoint2: NSPoint(x: 2, y: 9))
            body.close()
            body.lineWidth = 1.3
            body.lineJoinStyle = .round
            body.stroke()

            // Eyes.
            for x in [6.6, 11.4] {
                if awake {
                    let ring = NSBezierPath(ovalIn: NSRect(x: x - 2.2, y: 8.0, width: 4.4, height: 4.4))
                    ring.lineWidth = 1.1
                    ring.stroke()
                    NSBezierPath(ovalIn: NSRect(x: x - 0.95, y: 9.25, width: 1.9, height: 1.9)).fill()
                } else {
                    let lid = NSBezierPath()
                    lid.move(to: NSPoint(x: x - 2, y: 10.4))
                    lid.curve(to: NSPoint(x: x + 2, y: 10.4), controlPoint1: NSPoint(x: x - 1, y: 9.2), controlPoint2: NSPoint(x: x + 1, y: 9.2))
                    lid.lineWidth = 1.1
                    lid.lineCapStyle = .round
                    lid.stroke()
                }
            }

            // Beak.
            let beak = NSBezierPath()
            beak.move(to: NSPoint(x: 8.2, y: 7.6))
            beak.line(to: NSPoint(x: 9.8, y: 7.6))
            beak.line(to: NSPoint(x: 9, y: 5.9))
            beak.close()
            beak.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = awake ? "DarraOwl, session en cours" : "DarraOwl"
        return image
    }
}
