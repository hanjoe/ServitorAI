import AppKit

// Everything this app (and the pi child it spawns) creates is owner-only:
// config, logs and chat sessions may contain secrets and private chats.
umask(0o077)

// Debug helper: render the servitor sigil to a PNG and exit.
//   ServitorAI --render-sigil /tmp/sigil.png
let args = CommandLine.arguments
if args.count >= 3 && args[1] == "--render-sigil" {
    let size: CGFloat = 512
    let bg = NSImage(size: NSSize(width: size, height: size))
    bg.lockFocus()
    ServitorTheme.base.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    let skull = Sigil.wingedSkull(size: size, color: ServitorTheme.brass, template: false)
    skull.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    bg.unlockFocus()
    if let tiff = bg.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: args[2]))
        print("wrote \(args[2])")
    }
    exit(0)
}

Paths.hardenPermissions()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()