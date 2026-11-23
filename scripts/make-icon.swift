// Draws App/AppIcon.icns (commit the result). Run: swift scripts/make-icon.swift
// Or write only a 1024 px preview: swift scripts/make-icon.swift --preview out.png
import AppKit

// Tunables. Geometry is in an 824-point tile (centre 412,412); the artwork is full-bleed on the 1024 canvas
// (macOS applies its own mask), so the whole composition is scaled by `scale` about the centre.
func hex(_ v: Int) -> NSColor { NSColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1) }
let top = hex(0x2B4686), bottom = hex(0x0F1B3D)   // background gradient (full square, not scaled)
let discColor = NSColor.white, discRadius: CGFloat = 300
let barColor = hex(0x13224B)
let barHeights: [CGFloat] = [80, 180, 320, 130, 240, 110]   // left to right
let barWidth: CGFloat = 40, barPitch: CGFloat = 64
let scale: CGFloat = 1024 / 824
// Small sizes (<= 32 px) use fewer, thicker bars snapped to whole pixels, or the six bars blur together.
// Per pixel size: disc radius as a fraction of the size, bar width and gap in pixels, bar heights in pixels (even, so edges stay on the grid).
let smallGlyph: [Int: (disc: CGFloat, width: Int, gap: Int, heights: [Int])] = [
    16: (0.40, 2, 2, [4, 10, 6]),
    32: (0.40, 3, 2, [8, 20, 12, 16]),
]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)), angle: -90)
    if let g = smallGlyph[px] {
        let c = CGFloat(px) / 2, r = g.disc * CGFloat(px)
        discColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: c - r, y: c - r, width: 2 * r, height: 2 * r)).fill()
        barColor.setFill()
        let x0 = (px - (g.heights.count * g.width + (g.heights.count - 1) * g.gap)) / 2
        for (i, h) in g.heights.enumerated() {
            let b = NSRect(x: x0 + i * (g.width + g.gap), y: (px - h) / 2, width: g.width, height: h)
            NSBezierPath(roundedRect: b, xRadius: CGFloat(g.width) / 2, yRadius: CGFloat(g.width) / 2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
    let t = NSAffineTransform(); t.translateX(by: CGFloat(px) / 2, yBy: CGFloat(px) / 2)
    t.scale(by: CGFloat(px) / 1024 * scale); t.concat()   // origin is now the tile centre
    discColor.setFill()
    NSBezierPath(ovalIn: NSRect(x: -discRadius, y: -discRadius, width: 2 * discRadius, height: 2 * discRadius)).fill()
    barColor.setFill()
    let total = CGFloat(barHeights.count - 1) * barPitch + barWidth
    for (i, h) in barHeights.enumerated() {
        let b = NSRect(x: -total / 2 + CGFloat(i) * barPitch, y: -h / 2, width: barWidth, height: h)
        NSBezierPath(roundedRect: b, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    try render(1024).write(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)   // preview only: leave the committed .icns alone
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
try? fm.removeItem(at: tmp)   // exit() skips the defer above
exit(p.terminationStatus)
