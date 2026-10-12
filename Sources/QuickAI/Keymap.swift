import AppKit

/// Every rebindable in-app action. Esc (cancel) and Enter (submit) are fixed.
enum AppAction: String, CaseIterable {
    case actionsMenu, settings
    case copyAnswer, copyCode, pasteAnswer
    case regenerate, regenerateNextModel
    case newChat, prevChat, nextChat
    case prevChatAlt, nextChatAlt
    case cycleModel, modelPicker, recentChats, focusInput, hide, quit
}

struct KeyBinding: Codable {
    var key: String        // keyEquivalent string ("c", "\r", "[", arrow function-key char)
    var modifiers: UInt    // NSEvent.ModifierFlags rawValue
}

/// Watches a single file's parent directory and debounces change
/// notifications — editors (nvim included) usually save via a temp-file +
/// rename, which replaces the inode, so the directory (not the file fd)
/// is what must be watched.
final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pending: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        let dir = (path as NSString).deletingLastPathComponent
        fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        let capturedFd = fd
        src.setCancelHandler { close(capturedFd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}

/// Keybinds live in a plain, commented config file the user edits directly
/// (⌘, opens it in their editor). Changes are hot-reloaded — no restart.
final class Keymap {
    static let shared = Keymap()
    static let changed = Notification.Name("ServitorKeymapChanged")

    static var configPath: URL { Paths.configDir.appendingPathComponent("keybinds.conf") }

    /// `nil` value = explicitly unset in the file; missing key = use default.
    private var overrides: [AppAction: KeyBinding?] = [:]
    private var watcher: ConfigWatcher?

    private static func ctrl(_ key: String, _ extra: NSEvent.ModifierFlags = []) -> KeyBinding {
        KeyBinding(key: key, modifiers: NSEvent.ModifierFlags(arrayLiteral: [.control, extra]).rawValue)
    }

    static let defaults: [AppAction: KeyBinding] = [
        .actionsMenu: ctrl("k"),
        .settings: KeyBinding(key: ",", modifiers: NSEvent.ModifierFlags.command.rawValue),
        .copyAnswer: ctrl("c"),
        .copyCode: ctrl("c", [.option]),
        .pasteAnswer: ctrl("\r"),
        .regenerate: ctrl("r"),
        .regenerateNextModel: ctrl("r", [.shift]),
        .newChat: ctrl("n"),
        .prevChat: ctrl("["),
        .nextChat: ctrl("]"),
        .cycleModel: ctrl("m"),
        .modelPicker: ctrl("m", [.shift]),
        .recentChats: ctrl("h", [.shift]),
        .focusInput: ctrl("l"),
        .hide: ctrl("w", [.shift]),
        .quit: ctrl("q"),
        // prevChatAlt / nextChatAlt unset by default: ctrl+arrows would
        // otherwise break word-jumping while editing the input.
    ]

    init() {
        ensureFileExists()
        reloadFromDisk()
        watcher = ConfigWatcher(path: Self.configPath.path) { [weak self] in
            self?.reloadFromDisk()
        }
    }

    func binding(for a: AppAction) -> KeyBinding? {
        if let entry = overrides[a] { return entry }
        return Self.defaults[a]
    }

    func display(for a: AppAction) -> String {
        guard let b = binding(for: a) else { return "(unset)" }
        let mods = NSEvent.ModifierFlags(rawValue: b.modifiers)
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + prettyKeyGlyph(b.key)
    }

    // MARK: - Reload

    func reloadFromDisk() {
        guard let text = try? String(contentsOf: Self.configPath, encoding: .utf8) else { return }
        overrides = Self.parse(text)
        Debug.log("keymap: reloaded \(overrides.count) line(s) from \(Self.configPath.path)")
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func ensureFileExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: Self.configPath.path) else { return }
        try? Self.defaultFileContents().write(to: Self.configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing ("action = ctrl+shift+c", "#" comments, "unset" to disable)

    static func parse(_ text: String) -> [AppAction: KeyBinding?] {
        var out: [AppAction: KeyBinding?] = [:]
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard let action = AppAction(rawValue: name) else {
                Debug.log("keymap: unknown action '\(name)' in keybinds.conf, ignoring")
                continue
            }
            out[action] = parseKeySpec(value)
        }
        return out
    }

    /// Returns nil for "unset"/"none"/empty/unparseable (all treated as disabled).
    static func parseKeySpec(_ raw: String) -> KeyBinding? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.lowercased() == "unset" || s.lowercased() == "none" { return nil }
        let parts = s.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let last = parts.last else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": mods.insert(.control)
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            default: break
            }
        }
        let key: String
        switch last {
        case "enter", "return": key = "\r"
        case "left": key = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case "right": key = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case "up": key = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case "down": key = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        default:
            guard last.count == 1 else { return nil }
            key = last
        }
        guard !mods.isEmpty else { return nil }   // every binding needs a modifier
        return KeyBinding(key: key, modifiers: mods.rawValue)
    }

    private func prettyKeyGlyph(_ k: String) -> String {
        if k == "\r" { return "↵" }
        if k == String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)) { return "←" }
        if k == String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)) { return "→" }
        if k == String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)) { return "↑" }
        if k == String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)) { return "↓" }
        return k
    }

    // MARK: - Default file (comments regenerated from `defaults`)

    private static func specString(_ b: KeyBinding) -> String {
        let mods = NSEvent.ModifierFlags(rawValue: b.modifiers)
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.command) { parts.append("cmd") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        let keyNames: [String: String] = [
            "\r": "enter",
            String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "left",
            String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "right",
            String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "up",
            String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "down",
        ]
        parts.append(keyNames[b.key] ?? b.key)
        return parts.joined(separator: "+")
    }

    private static func line(_ action: AppAction, _ comment: String) -> String {
        let spec = defaults[action].map(specString) ?? "unset"
        return "# \(comment)\n\(action.rawValue) = \(spec)\n"
    }

    static func defaultFileContents() -> String {
        """
        # ServitorAI keybinds
        # ---------------------------------------------------------------
        # Edit, save, done — ServitorAI reloads this file automatically,
        # no restart needed. Reopen it any time with ⌘, or the ⌃K menu.
        #
        # Format:  action = modifiers+key
        #   Modifiers : ctrl, cmd, shift, opt   (combine with +, any order)
        #   Keys      : a single character (a, 1, [, ], comma, ...)
        #               or one of: enter, left, right, up, down
        #   Disable   : set the value to "unset"
        #
        # Fixed, not configurable here:
        #   Esc              cancel current answer / hide the panel
        #   Enter            submit
        #   ⌘⇧A              toggle the panel (global — works from any app)
        #   ⌘C / ⌘V / ⌘A     native copy / paste / select-all while editing
        # ---------------------------------------------------------------

        \(line(.actionsMenu, "Open the actions menu (every command, with its key)"))
        \(line(.settings, "Open this config file in your editor"))

        \(line(.copyAnswer, "Copy the servitor's last full answer"))
        \(line(.copyCode, "Copy only the last fenced code block in the last answer"))
        \(line(.pasteAnswer, "Copy the last answer AND paste it into the app you came from"))

        \(line(.regenerate, "Re-ask the last question"))
        \(line(.regenerateNextModel, "Re-ask the last question with the next model"))

        \(line(.newChat, "Start a new chat"))
        \(line(.prevChat, "Switch to the previous (older) chat"))
        \(line(.nextChat, "Switch to the next (newer) chat"))
        \(line(.prevChatAlt, "Alternate binding for Previous Chat"))
        \(line(.nextChatAlt, "Alternate binding for Next Chat"))

        \(line(.cycleModel, "Cycle to the next model in your configured list"))
        \(line(.modelPicker, "Open a menu to pick a model directly"))

        \(line(.recentChats, "Open the recent-chats menu"))
        \(line(.focusInput, "Move keyboard focus to the input box"))
        \(line(.hide, "Hide the panel"))
        \(line(.quit, "Quit ServitorAI"))
        """
    }
}