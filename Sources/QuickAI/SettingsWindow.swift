import AppKit

/// Settings window: lists every rebindable action; click its button, press a
/// key combo, done. Esc cancels recording. Right-click resets to default.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var recordingAction: AppAction?
    private var monitor: Any?
    private var buttons: [AppAction: NSButton] = [:]
    private var observer: NSObjectProtocol?

    func show() {
        if window == nil { build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "ServitorAI — Keybinds"
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w

        let content = w.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = ServitorTheme.base.cgColor

        let heading = NSTextField(labelWithString: "KEYBINDS")
        heading.font = ServitorTheme.pixel(14)
        heading.textColor = ServitorTheme.marsRed

        let hint = NSTextField(labelWithString: "Click a shortcut, then press the new combo. Esc cancels · right-click resets.")
        hint.font = ServitorTheme.body(20)
        hint.textColor = ServitorTheme.subtext
        hint.lineBreakMode = .byWordWrapping
        hint.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let fixed = NSTextField(labelWithString: "Fixed: Esc cancel/hide · Enter submit · ⌘⇧A toggle panel (global)")
        fixed.font = ServitorTheme.body(20)
        fixed.textColor = ServitorTheme.overlay0

        content.addSubview(heading)
        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(fixed)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: fixed.topAnchor, constant: -10),
            fixed.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            fixed.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        for action in AppAction.allCases {
            list.addView(row(for: action), in: .leading)
        }

        observer = NotificationCenter.default.addObserver(forName: Keymap.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refreshButtons()
        }
    }

    private func row(for action: AppAction) -> NSView {
        let title = NSTextField(labelWithString: Keymap.titles[action] ?? action.rawValue)
        title.font = ServitorTheme.body(22)
        title.textColor = ServitorTheme.text

        let button = NSButton(title: Keymap.shared.display(for: action), target: self, action: #selector(record(_:)))
        button.font = ServitorTheme.pixel(9)
        button.bezelStyle = .rounded
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = ServitorTheme.surface0.cgColor
        button.attributedTitle = NSAttributedString(string: "  \(Keymap.shared.display(for: action))  ", attributes: [
            .font: ServitorTheme.pixel(9), .foregroundColor: ServitorTheme.brass,
        ])
        button.tag = AppAction.allCases.firstIndex(of: action)!
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        buttons[action] = button

        let row = NSStackView(views: [title, NSView(), button])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func refreshButtons() {
        for (action, button) in buttons {
            button.attributedTitle = NSAttributedString(string: "  \(Keymap.shared.display(for: action))  ", attributes: [
                .font: ServitorTheme.pixel(9),
                .foregroundColor: recordingAction == action ? ServitorTheme.machineTeal : ServitorTheme.brass,
            ])
        }
    }

    @objc private func record(_ sender: NSButton) {
        let action = AppAction.allCases[sender.tag]
        if let current = recordingAction { stopRecording(cancelled: true) }

        if NSApp.currentEvent?.type == .rightMouseUp {
            Keymap.shared.set(nil, for: action)   // reset to default / unset
            return
        }

        recordingAction = action
        sender.attributedTitle = NSAttributedString(string: "  press keys… (esc)  ", attributes: [
            .font: ServitorTheme.pixel(9), .foregroundColor: ServitorTheme.machineTeal,
        ])
        installMonitor()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = self.recordingAction else { return event }
            if event.keyCode == 53 { self.stopRecording(cancelled: true); return nil }   // Esc
            guard let key = Self.keyString(for: event) else { return nil }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.subtracting(.function).isEmpty else { return nil }               // needs a modifier
            Keymap.shared.set(KeyBinding(key: key, modifiers: mods.rawValue), for: action)
            Debug.log("keybind: \(action.rawValue) -> \(Keymap.shared.display(for: action))")
            self.stopRecording(cancelled: false)
            return nil
        }
    }

    private func stopRecording(cancelled: Bool) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recordingAction = nil
        refreshButtons()
    }

    private static func keyString(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36, 76: return "\r"
        case 123: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case 124: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case 125: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case 126: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1 else { return nil }
            let c = chars.first!
            if c.isLetter || c.isNumber { return String(c) }
            if "[]{}()/\\-=?;:'\",.<>`~+*|_!@#$%^&".contains(c) { return String(c) }
            return nil
        }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }
}