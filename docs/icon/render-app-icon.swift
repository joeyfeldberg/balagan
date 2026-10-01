// Renders the app icon, 1024×1024 with transparency, to Sources/BalaganApp/Resources/AppIcon.png
// (or the path given as the first argument). Run from the repo root, outside the agent sandbox:
//   swift docs/icon/render-app-icon.swift
import AppKit
let S: CGFloat = 1024
let tileR = CGRect(x: 100, y: 100, width: 824, height: 824)
func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func tilePath() -> CGPath { CGPath(roundedRect: tileR, cornerWidth: 185, cornerHeight: 185, transform: nil) }
func lin(_ c: CGContext, _ colors: [UInt32], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map { hex($0) } as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func tile(_ c: CGContext, _ colors: [UInt32]) {
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: hex(0, 0.35))
    c.addPath(tilePath()); c.setFillColor(hex(colors.last!)); c.fillPath()
    c.restoreGState()
    c.saveGState(); c.addPath(tilePath()); c.clip()
    lin(c, colors, from: CGPoint(x: 250, y: 924), to: CGPoint(x: 774, y: 100))
    // soft top light
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [hex(0xFFFFFF, 0.18), hex(0xFFFFFF, 0)] as CFArray, locations: nil)!
    c.drawRadialGradient(g, startCenter: CGPoint(x: 420, y: 900), startRadius: 0, endCenter: CGPoint(x: 420, y: 900), endRadius: 620, options: [])
    c.restoreGState()
    c.saveGState(); c.addPath(CGPath(roundedRect: tileR.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    c.setStrokeColor(hex(0xFFFFFF, 0.14)); c.setLineWidth(3); c.strokePath(); c.restoreGState()
}
func render(to path: String, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func prompt(_ c: CGContext, scale: CGFloat, center: CGPoint, cursor: UInt32) {
    // ❯ and the cursor block, sized as one glyph group centred on `center`.
    let w: CGFloat = 92 * scale
    let chev = CGMutablePath()
    chev.move(to: CGPoint(x: center.x - 215 * scale, y: center.y + 165 * scale))
    chev.addLine(to: CGPoint(x: center.x - 35 * scale, y: center.y))
    chev.addLine(to: CGPoint(x: center.x - 215 * scale, y: center.y - 165 * scale))
    c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: hex(0, 0.35))
    c.addPath(chev); c.setLineWidth(w); c.setLineCap(.round); c.setLineJoin(.round); c.setStrokeColor(hex(0xFFFFFF)); c.strokePath()
    c.restoreGState()
    c.saveGState(); c.setShadow(offset: .zero, blur: 40, color: hex(cursor, 0.75))
    c.addPath(CGPath(roundedRect: CGRect(x: center.x + 25 * scale, y: center.y - 205 * scale, width: 200 * scale, height: 78 * scale),
                     cornerWidth: 22 * scale, cornerHeight: 22 * scale, transform: nil))
    c.setFillColor(hex(cursor)); c.fillPath(); c.restoreGState()
}
func confetti(_ c: CGContext, _ pieces: [(CGFloat, CGFloat, CGFloat, UInt32, CGFloat)]) {
    for (x, y, deg, col, size) in pieces {
        c.saveGState(); c.translateBy(x: x, y: y); c.rotate(by: deg * .pi / 180)
        c.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: hex(0, 0.4))
        c.addPath(CGPath(roundedRect: CGRect(x: -size / 2, y: -size * 0.31, width: size, height: size * 0.62),
                         cornerWidth: size * 0.16, cornerHeight: size * 0.16, transform: nil))
        c.setFillColor(hex(col)); c.fillPath(); c.restoreGState()
    }
}
// A big `❯_` prompt with kanban-card confetti spraying off it, on a vivid violet tile — the balagan
// around the one thing that matters, and bright enough to pick out in a Dock full of dark icons.
render(to: CommandLine.arguments.dropFirst().first ?? "Sources/BalaganApp/Resources/AppIcon.png") { c in
    tile(c, [0x5B6CFF, 0x7A3CF0, 0x3A1A8C])
    confetti(c, [(640, 760, 28, 0xFF5E7E, 120), (790, 640, -22, 0xFFC23D, 110), (770, 820, 52, 0x4CE0FF, 96),
                 (560, 860, -14, 0x3FD07F, 88), (840, 470, 36, 0xFFFFFF, 84)])
    prompt(c, scale: 1, center: CGPoint(x: 500, y: 470), cursor: 0x3FD07F)
}
