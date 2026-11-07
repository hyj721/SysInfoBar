import AppKit

/// Menu bar glyph: a gauge (270° arc, needle, hub). Drawn as a template image so
/// macOS tints it for light / dark menu bars and the highlighted state.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { rect in
            // Designed on a 24×24 grid, y pointing down.
            let s = rect.width / 24
            let t = NSAffineTransform()
            t.scale(by: s)
            t.concat()
            NSColor.black.set()

            let center = NSPoint(x: 12, y: 13)
            let arc = NSBezierPath()
            // Flipped coordinates: 135° is lower-left, 45° lower-right; go the long way over the top.
            arc.appendArc(withCenter: center, radius: 8, startAngle: 135, endAngle: 45, clockwise: false)
            arc.lineWidth = 2.0
            arc.lineCapStyle = .round
            arc.stroke()

            let needle = NSBezierPath()
            needle.move(to: center)
            needle.line(to: NSPoint(x: 15.9, y: 9.1))
            needle.lineWidth = 2.0
            needle.lineCapStyle = .round
            needle.stroke()

            NSBezierPath(ovalIn: NSRect(x: center.x - 1.7, y: center.y - 1.7, width: 3.4, height: 3.4)).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "SysInfoBar"
        return img
    }()
}
