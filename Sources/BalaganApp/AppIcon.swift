import AppKit

/// The app's Dock icon, drawn in code (the app ships as a raw executable, not a bundled `.app`, so
/// there's no Assets `AppIcon`). Concept: a dark squircle tile with a terminal prompt — accent
/// chevron `❯` + a green cursor block (the embedded terminal) — over a row of kanban status dots
/// in the board's status colors (Todo / Doing / Done / Parked).
enum AppIcon {
    static func make() -> NSImage {
        // Prefer the bundled artwork (a big `❯_` prompt with kanban-card confetti on a violet tile, drawn by
        // docs/icon/render-app-icon.swift); fall back to the code-drawn mark if the resource is missing.
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let size = NSSize(width: 1024, height: 1024)
        return NSImage(size: size, flipped: false) { rect in
            draw(canvas: rect.width)
            return true
        }
    }

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func draw(canvas: CGFloat) {
        let margin = canvas * 0.098
        let tile = NSRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
        let radius = tile.width * 0.2237
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

        // Tile background: vertical dark gradient + a subtle top sheen.
        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        NSGradient(starting: color(0x14151B), ending: color(0x2E323A))?.draw(in: tile, angle: 90)
        let sheen = NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2)
        NSGradient(starting: NSColor.white.withAlphaComponent(0.06), ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: sheen, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Hairline inner edge.
        let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
        NSColor.white.withAlphaComponent(0.09).setStroke()
        edge.lineWidth = 3
        edge.stroke()

        let w = tile.width
        let groupCenterY = tile.midY + w * 0.05

        // Soft depth shadow shared by the prompt glyphs.
        let promptShadow = NSShadow()
        promptShadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
        promptShadow.shadowBlurRadius = w * 0.035
        promptShadow.shadowOffset = NSSize(width: 0, height: -w * 0.014)

        // Terminal prompt chevron "❯".
        let chevronBackX = tile.minX + w * 0.315
        let chevronApexX = tile.minX + w * 0.49
        let chevronHalf = w * 0.185
        let chevron = NSBezierPath()
        chevron.lineWidth = w * 0.094
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.move(to: NSPoint(x: chevronBackX, y: groupCenterY + chevronHalf))
        chevron.line(to: NSPoint(x: chevronApexX, y: groupCenterY))
        chevron.line(to: NSPoint(x: chevronBackX, y: groupCenterY - chevronHalf))
        NSGraphicsContext.saveGraphicsState()
        promptShadow.set()
        color(0x5B9BFF).setStroke()
        chevron.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Blinking-cursor block to the right of the prompt.
        let cursorWidth = w * 0.135
        let cursorHeight = w * 0.30
        let cursorRect = NSRect(
            x: tile.minX + w * 0.575,
            y: groupCenterY - cursorHeight / 2,
            width: cursorWidth,
            height: cursorHeight
        )
        let cursorPath = NSBezierPath(roundedRect: cursorRect, xRadius: w * 0.028, yRadius: w * 0.028)
        NSGraphicsContext.saveGraphicsState()
        promptShadow.set()
        color(0x3FB970).setFill()
        cursorPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Kanban status dots (Todo / Doing / Done / Parked) along the lower third.
        let dotRadius = w * 0.030
        let spacing = w * 0.105
        let dotY = tile.minY + w * 0.155
        let dotColors: [NSColor] = [color(0x8A93A6), color(0x4C8DFF), color(0x3FB970), color(0xC98A2B)]
        let startX = tile.midX - (spacing * CGFloat(dotColors.count - 1)) / 2
        for (index, dotColor) in dotColors.enumerated() {
            let cx = startX + spacing * CGFloat(index)
            let dot = NSBezierPath(ovalIn: NSRect(
                x: cx - dotRadius,
                y: dotY - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
            dotColor.setFill()
            dot.fill()
        }
    }
}
