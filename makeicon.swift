// Renders claude.svg in Claude orange on a cream rounded square into AppIcon.iconset.
import AppKit
let logo = NSImage(contentsOfFile: "claude.svg")!
try? FileManager.default.createDirectory(atPath: "AppIcon.iconset", withIntermediateDirectories: true)
for (px, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let bg = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1).setFill()
    NSBezierPath(roundedRect: bg, xRadius: bg.width * 0.225, yRadius: bg.width * 0.225).fill()
    let tinted = NSImage(size: logo.size, flipped: false) { r in
        logo.draw(in: r)
        NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: bg.insetBy(dx: bg.width * 0.2, dy: bg.width * 0.2))
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "AppIcon.iconset/icon_\(name).png"))
}
