import SwiftUI

/// The monochrome owl, same drawing as the Mac's menu bar icon, on an
/// 18 x 18 grid. `openness`: 1 eyes open (the Mac awake), 0 closed (normal
/// sleep), in between while it blinks.
struct OwlShape: Shape {
    var openness: Double
    /// See `OwlEyes.swapLids`.
    var swapLids = false

    init(awake: Bool) { openness = awake ? 1 : 0 }
    init(openness: Double, swapLids: Bool = false) {
        self.openness = openness
        self.swapLids = swapLids
    }

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = OwlHead().path(in: rect)
        path.addPath(OwlEyes(openness: openness, swapLids: swapLids).path(in: rect))
        return path
    }
}

/// Head, body and beak: what does not move.
struct OwlHead: Shape {
    func path(in rect: CGRect) -> Path {
        let p = OwlGrid(rect).point
        var path = Path()
        path.move(to: p(4, 15.5))
        path.addLine(to: p(6.5, 13.6))
        path.addCurve(to: p(11.5, 13.6), control1: p(8, 14.3), control2: p(10, 14.3))
        path.addLine(to: p(14, 15.5))
        path.addCurve(to: p(9, 1.5), control1: p(16, 9), control2: p(14, 1.5))
        path.addCurve(to: p(4, 15.5), control1: p(4, 1.5), control2: p(2, 9))
        path.closeSubpath()
        path.move(to: p(8.2, 7.6))
        path.addLine(to: p(9.8, 7.6))
        path.addLine(to: p(9, 5.9))
        path.closeSubpath()
        return path
    }
}

/// The eyes. Closing, the upper lid comes down onto the lower one, which
/// flattens into the closed eye's curve.
struct OwlEyes: Shape {
    var openness: Double
    /// The same eyes, drawn lower lid first. A Live Activity morphs one
    /// drawing into the next, point by point: from one order to the other
    /// the lids meet in the middle, a blink. So its owl blinks at each new
    /// state by swapping the order.
    var swapLids = false

    var animatableData: Double {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let p = OwlGrid(rect).point
        let o = min(max(openness, 0), 1)
        // Radius 2.2: a cubic with controls 4/3 r away draws a half circle.
        let r = 2.2, y = 10.2, k = r * 4 / 3, closed = 0.27
        let upper = -k * closed + k * (1 + closed) * o
        let lower = -k * (closed + (1 - closed) * o)
        let (first, second) = swapLids ? (lower, upper) : (upper, lower)
        var path = Path()
        for x in [6.6, 11.4] {
            path.move(to: p(x - r, y))
            path.addCurve(to: p(x + r, y), control1: p(x - r, y + first), control2: p(x + r, y + first))
            path.addCurve(to: p(x - r, y), control1: p(x + r, y + second), control2: p(x - r, y + second))
            path.closeSubpath()
        }
        return path
    }
}

/// The 18 x 18 grid of the drawing, y up, in a square of the rect.
private struct OwlGrid {
    let rect: CGRect
    init(_ rect: CGRect) { self.rect = rect }

    func point(_ x: Double, _ y: Double) -> CGPoint {
        let s = min(rect.width, rect.height) / 18
        return CGPoint(x: rect.minX + x * s, y: rect.minY + (18 - y) * s)
    }
}

/// The owl of the apps: it blinks now and then while the Mac is awake, and
/// closes its eyes slowly when the Mac goes back to normal sleep. Still
/// with Reduce Motion, and on a dimmed watch face.
struct BlinkingOwl: View {
    var awake: Bool
    var lineWidth: CGFloat
    @State private var openness: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed

    init(awake: Bool, lineWidth: CGFloat) {
        self.awake = awake
        self.lineWidth = lineWidth
        _openness = State(initialValue: awake ? 1 : 0)
    }

    var body: some View {
        OwlShape(openness: openness)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .onChange(of: awake) { _, now in
                if reduceMotion {
                    openness = now ? 1 : 0
                } else {
                    withAnimation(.easeInOut(duration: now ? 0.35 : 0.9)) { openness = now ? 1 : 0 }
                }
            }
            .task(id: awake && !reduceMotion && !dimmed) {
                // A blink cut short (the watch face dimmed) does not leave
                // the eyes shut.
                if awake, openness < 1 { openness = 1 }
                guard awake, !reduceMotion, !dimmed else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 5...9)))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeIn(duration: 0.07)) { openness = 0.05 }
                    try? await Task.sleep(for: .milliseconds(90))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.13)) { openness = 1 }
                }
            }
    }
}
