import AppKit
import CoreText

/// "Servitor" theme — Warhammer 40k Adeptus Mechanicus crossed with the
/// Catppuccin Mocha palette, rendered in 8-bit pixel fonts.
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
    static let marsRed = hex("#f38ba8")      // Mechanicus blood-red (accent)
    static let brass = hex("#fab387")        // brass/gold (Omnissiah)
    static let machineTeal = hex("#94e2d5")  // machine-spirit glow (Servitor)
    static let bone = hex("#f5e0dc")         // bone/cream (headings)
    static let warning = hex("#f9e2af")
    static let success = hex("#a6e3a1")
    static let error = hex("#f38ba8")

    // Rich-text roles
    static let link = hex("#89b4fa")         // highlighted links
    static let codeBg = hex("#11111b")
    static let codeFg = hex("#a6e3a1")
    static let inlineCode = hex("#f9e2af")
    static let quote = hex("#9399b2")

    // MARK: - Fonts (8-bit)

    /// Sizes, in points. VT323 has a small x-height, hence the large numbers.
    static let bodySize: CGFloat = 24
    static let codeSize: CGFloat = 22
    static let inputSize: CGFloat = 24
    static let labelSize: CGFloat = 9

    private static var fontsRegistered = false

    /// Registers the bundled pixel fonts for this process (idempotent).
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Fonts")) }
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/Fonts"))
        for dir in dirs {
            for name in ["PressStart2P-Regular.ttf", "VT323-Regular.ttf"] {
                let url = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }
    }

    /// Press Start 2P — the classic 8-bit display face (labels, headings).
    static func pixel(_ size: CGFloat) -> NSFont {
        registerFonts()
        return NSFont(name: "PressStart2P-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .heavy)
    }

    /// VT323 — a readable pixel terminal face (body text, code, input).
    static func body(_ size: CGFloat) -> NSFont {
        registerFonts()
        return NSFont(name: "VT323-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size * 0.62, weight: .regular)
    }

    static var labelFont: NSFont { pixel(labelSize) }
    static var bodyFont: NSFont { body(bodySize) }
    static var inputFont: NSFont { body(inputSize) }

    /// A serif face used only for the keybind legend (hint bar, empty-state
    /// hints, action-row buttons) — the blocky pixel font renders ⌘/⌥/⇧/⌃
    /// glyphs poorly at small sizes; a serif reads them cleanly.
    static func legend(_ size: CGFloat) -> NSFont {
        NSFont(name: "New York", size: size)
            ?? NSFont(name: "Georgia", size: size)
            ?? NSFont(descriptor: NSFontDescriptor(name: "System", size: size).withDesign(.serif) ?? NSFontDescriptor(), size: size)
            ?? NSFont.systemFont(ofSize: size)
    }

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
