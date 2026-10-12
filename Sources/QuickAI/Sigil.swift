import AppKit

/// The ServitorAI sigil: a stylized winged skull (Warhammer / Adeptus
/// Mechanicus style), drawn as a tintable template image.
enum Sigil {
    static func wingedSkull(size s: CGFloat, color: NSColor = .white, template: Bool = true) -> NSImage {
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        color.setFill()

        // --- Wings: three swept feathers per side, fanning upward ---
        for side: CGFloat in [-1, 1] {
            for i in 0..<3 {
                let startY = 0.52 + CGFloat(i) * 0.085
                let reach = 0.20 + CGFloat(i) * 0.05
                let lift = 0.04 + CGFloat(i) * 0.03
                let rootX = s * (0.5 + side * 0.14)
                let rootY = s * startY
                let tipX = s * (0.5 + side * (0.14 + reach))
                let tipY = s * (startY + lift)
                let f = NSBezierPath()
                f.move(to: NSPoint(x: rootX, y: rootY))
                f.curve(to: NSPoint(x: tipX, y: tipY),
                        controlPoint1: NSPoint(x: rootX + side * s * 0.10, y: rootY + s * 0.07),
                        controlPoint2: NSPoint(x: tipX - side * s * 0.06, y: tipY + s * 0.04))
                f.curve(to: NSPoint(x: rootX, y: rootY - s * 0.035),
                        controlPoint1: NSPoint(x: tipX - side * s * 0.05, y: tipY - s * 0.05),
                        controlPoint2: NSPoint(x: rootX + side * s * 0.08, y: rootY - s * 0.04))
                f.close()
                f.fill()
            }
        }

        // --- Cranium with eye sockets (even-odd holes) ---
        let cranium = NSBezierPath()
        cranium.append(NSBezierPath(ovalIn: NSRect(x: s * 0.335, y: s * 0.44, width: s * 0.33, height: s * 0.32)))
        for ex: CGFloat in [0.415, 0.535] {
            cranium.append(NSBezierPath(ovalIn: NSRect(x: s * ex, y: s * 0.55, width: s * 0.075, height: s * 0.10)))
        }
        cranium.windingRule = .evenOdd
        cranium.fill()

        // --- Jaw with nasal cavity ---
        let jaw = NSBezierPath()
        jaw.append(NSBezierPath(roundedRect: NSRect(x: s * 0.385, y: s * 0.30, width: s * 0.23, height: s * 0.17), xRadius: s * 0.03, yRadius: s * 0.03))
        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: s * 0.483, y: s * 0.435))
        nose.line(to: NSPoint(x: s * 0.517, y: s * 0.435))
        nose.line(to: NSPoint(x: s * 0.500, y: s * 0.385))
        nose.close()
        jaw.append(nose)
        jaw.windingRule = .evenOdd
        jaw.fill()

        img.unlockFocus()
        img.isTemplate = template
        return img
    }
}