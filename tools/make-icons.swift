// Draws the DarraOwl icon (the menu bar owl, white on black) as 1024 px PNGs.
// Run: swift tools/make-icons.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size = 1024.0

func owl(in ctx: CGContext, scale s: Double, origin o: CGPoint) {
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.setLineWidth(1.3 * s)
    ctx.move(to: p(4, 15.5))
    ctx.addLine(to: p(6.5, 13.6))
    ctx.addCurve(to: p(11.5, 13.6), control1: p(8, 14.3), control2: p(10, 14.3))
    ctx.addLine(to: p(14, 15.5))
    ctx.addCurve(to: p(9, 1.5), control1: p(16, 9), control2: p(14, 1.5))
    ctx.addCurve(to: p(4, 15.5), control1: p(4, 1.5), control2: p(2, 9))
    ctx.closePath()
    ctx.strokePath()
    ctx.setLineWidth(1.1 * s)
    for x in [6.6, 11.4] {
        ctx.strokeEllipse(in: CGRect(x: o.x + (x - 2.2) * s, y: o.y + 8.0 * s, width: 4.4 * s, height: 4.4 * s))
        ctx.fillEllipse(in: CGRect(x: o.x + (x - 0.95) * s, y: o.y + 9.25 * s, width: 1.9 * s, height: 1.9 * s))
    }
    ctx.move(to: p(8.2, 7.6))
    ctx.addLine(to: p(9.8, 7.6))
    ctx.addLine(to: p(9, 5.9))
    ctx.closePath()
    ctx.fillPath()
}

func render(_ name: String) throws {
    // RGB without alpha: App Store icons must be opaque.
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.07, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    // The owl spans 18 units; leave a generous margin.
    let s = size * 0.62 / 18
    owl(in: ctx, scale: s, origin: CGPoint(x: (size - 18 * s) / 2, y: (size - 18 * s) / 2 - s * 0.2))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: name))
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try render("AppIcon-1024.png")
print("ok")
