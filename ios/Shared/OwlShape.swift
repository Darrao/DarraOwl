import SwiftUI

/// The monochrome owl, same drawing as the Mac's menu bar icon.
struct OwlShape: Shape {
    var awake: Bool

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 18
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + (18 - y) * s) }
        var path = Path()
        path.move(to: p(4, 15.5))
        path.addLine(to: p(6.5, 13.6))
        path.addCurve(to: p(11.5, 13.6), control1: p(8, 14.3), control2: p(10, 14.3))
        path.addLine(to: p(14, 15.5))
        path.addCurve(to: p(9, 1.5), control1: p(16, 9), control2: p(14, 1.5))
        path.addCurve(to: p(4, 15.5), control1: p(4, 1.5), control2: p(2, 9))
        path.closeSubpath()
        for x in [6.6, 11.4] {
            if awake {
                path.addEllipse(in: CGRect(origin: p(x - 2.2, 12.4), size: CGSize(width: 4.4 * s, height: 4.4 * s)))
            } else {
                path.move(to: p(x - 2, 10.4))
                path.addQuadCurve(to: p(x + 2, 10.4), control: p(x, 9.2))
            }
        }
        path.move(to: p(8.2, 7.6))
        path.addLine(to: p(9.8, 7.6))
        path.addLine(to: p(9, 5.9))
        path.closeSubpath()
        return path
    }
}
