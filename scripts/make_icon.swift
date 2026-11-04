import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, size) in variants {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(red: 0.45, green: 0.41, blue: 0.94, alpha: 1),
               ending: NSColor(red: 0.29, green: 0.25, blue: 0.69, alpha: 1))!.draw(in: background, angle: -55)
    NSColor.white.withAlphaComponent(0.94).setFill()
    NSBezierPath(roundedRect: NSRect(x: 229, y: 260, width: 566, height: 425), xRadius: 50, yRadius: 50).fill()
    NSBezierPath(roundedRect: NSRect(x: 201, y: 645, width: 622, height: 115), xRadius: 29, yRadius: 29).fill()
    NSColor(red: 0.30, green: 0.25, blue: 0.64, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 435, y: 260, width: 154, height: 500), xRadius: 12, yRadius: 12).fill()
    NSColor(red: 0.85, green: 0.82, blue: 1, alpha: 1).setFill()
    for index in 0..<7 {
        NSBezierPath(roundedRect: NSRect(x: index.isMultiple(of: 2) ? 469 : 509, y: 355 + index * 49,
                                       width: 45, height: 24), xRadius: 5, yRadius: 5).fill()
    }
    NSBezierPath(roundedRect: NSRect(x: 467, y: 287, width: 90, height: 62), xRadius: 15, yRadius: 15).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name + ".png"))
}
