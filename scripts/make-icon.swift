// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
    NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.92, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204).fill()
    let ink = NSColor(calibratedRed: 0.12, green: 0.34, blue: 0.31, alpha: 1)
    ink.setStroke()
    let stream = NSBezierPath(); stream.lineWidth = 64; stream.lineCapStyle = .round; stream.lineJoinStyle = .round
    stream.move(to: NSPoint(x: 328, y: 714)); stream.line(to: NSPoint(x: 659, y: 714))
    stream.curve(to: NSPoint(x: 659, y: 510), controlPoint1: NSPoint(x: 795, y: 714), controlPoint2: NSPoint(x: 795, y: 510))
    stream.line(to: NSPoint(x: 365, y: 510))
    stream.curve(to: NSPoint(x: 365, y: 306), controlPoint1: NSPoint(x: 229, y: 510), controlPoint2: NSPoint(x: 229, y: 306))
    stream.line(to: NSPoint(x: 626, y: 306)); stream.stroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 56; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 585, y: 376)); arrow.line(to: NSPoint(x: 661, y: 306)); arrow.line(to: NSPoint(x: 585, y: 236)); arrow.stroke()
    NSColor(calibratedRed: 0.83, green: 0.57, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 249, y: 681, width: 66, height: 66)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
