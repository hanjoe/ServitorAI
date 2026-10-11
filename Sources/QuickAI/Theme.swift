import AppKit

/// "Servitor" theme — Warhammer 40k Adeptus Mechanicus crossed with the
/// Catppuccin Mocha palette. Dark gothic base, mars-red accent, brass for the
/// operator, and a cold machine-spirit glow for the servitor's replies.
enum ServitorTheme {
    // Catppuccin Mocha base
    static let base = hex("#1e1e2e")       // panel background
    static let mantle = hex("#181825")     // deeper surface
    static let crust = hex("#11111b")      // deepest
    static let surface0 = hex("#313244")   // input / raised surface
    static let surface1 = hex("#45475a")   // borders
    static let overlay0 = hex("#6c7086")   // muted borders

    // Text
    static let text = hex("#cdd6f4")
    static let subtext = hex("#a6adc8")
    static let subtext1 = hex("#bac2de")

    // Servitor accents
    static let marsRed = hex("#f38ba8")      // Mechanicus blood-red (accent / You)
    static let brass = hex("#fab387")        // brass/gold (highlights)
    static let machineTeal = hex("#94e2d5")  // machine-spirit glow (Assistant)
    static let bone = hex("#f5e0dc")         // bone/cream
    static let warning = hex("#f9e2af")
    static let success = hex("#a6e3a1")
    static let error = hex("#f38ba8")

    // Fonts — monospace for the techno-gothic labels, system for readable body.
    static let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let inputFont = NSFont.systemFont(ofSize: 13)

    static func hex(_ s: String) -> NSColor {
        let cleaned = s.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
