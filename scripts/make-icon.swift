// Draws App/AppIcon.icns. Run: swift scripts/make-icon.swift [--preview out.png]
import AppKit

// Tunables (all in points on a 1024 canvas)
let top = NSColor(red: 0.36, green: 0.42, blue: 0.86, alpha: 1)   // gradient top
let bottom = NSColor(red: 0.09, green: 0.11, blue: 0.36, alpha: 1) // gradient bottom
let barHeights: [CGFloat] = [540, 380, 250, 130]            // loud to quiet, left to right
let barWidth: CGFloat = 112
let barGap: CGFloat = 68
let glyphScale: CGFloat = 1.24 // the glyph is sized for a 824 tile; the artwork is full-bleed so macOS applies its own mask

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)), angle: -90)
    let t = NSAffineTransform(); t.translateX(by: CGFloat(px) / 2, yBy: CGFloat(px) / 2)
    t.scale(by: CGFloat(px) / 1024 * glyphScale); t.translateX(by: -512, yBy: -512); t.concat()
    NSColor.white.setFill()
    let total = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barGap
    for (i, h) in barHeights.enumerated() {
        let b = NSRect(x: 512 - total / 2 + CGFloat(i) * (barWidth + barGap), y: 512 - h / 2, width: barWidth, height: h)
        NSBezierPath(roundedRect: b, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    try render(1024).write(to: URL(fileURLWithPath: args[i + 1]))
}
let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }
for s in [16, 32, 128, 256, 512] {
    try render(s).write(to: tmp.appendingPathComponent("icon_\(s)x\(s).png"))
    try render(s * 2).write(to: tmp.appendingPathComponent("icon_\(s)x\(s)@2x.png"))
}
let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/AppIcon.icns")
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out.path]
try p.run(); p.waitUntilExit()
exit(p.terminationStatus)
