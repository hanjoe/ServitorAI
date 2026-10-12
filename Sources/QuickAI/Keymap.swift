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

/// Persisted, user-editable keybinds. Defaults are all ctrl-based per the
/// Omnissiah's decree; a Settings window records new bindings live.
final class Keymap {
    static let shared = Keymap()
    static let changed = Notification.Name("ServitorKeymapChanged")
    private let storeKey = "servitorai.keymap.v1"

    private(set) var bindings: [AppAction: KeyBinding]

    /// Display titles for the settings window and menus.
    static let titles: [AppAction: String] = [
        .actionsMenu: "Actions Menu", .settings: "Settings",
        .copyAnswer: "Copy Answer", .copyCode: "Copy Last Code Block", .pasteAnswer: "Paste Answer to App",
        .regenerate: "Regenerate", .regenerateNextModel: "Regenerate with Next Model",
        .newChat: "New Chat", .prevChat: "Previous Chat", .nextChat: "Next Chat",
        .prevChatAlt: "Previous Chat (alt keys)", .nextChatAlt: "Next Chat (alt keys)",
        .cycleModel: "Cycle Model", .modelPicker: "Model Picker", .recentChats: "Recent Chats",
        .focusInput: "Focus Input", .hide: "Hide Panel", .quit: "Quit",
    ]

    private static func ctrl(_ key: String, _ extra: NSEvent.ModifierFlags = []) -> KeyBinding {
        KeyBinding(key: key, modifiers: NSEvent.ModifierFlags(arrayLiteral: [.control, extra]).rawValue)
    }

    private static var defaults: [AppAction: KeyBinding] {
        [
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
            // alt arrow bindings unset by default: ctrl+arrows would break
            // word-jumping while editing the input. Recordable in Settings.
        ]
    }

    init() {
        bindings = [:]
        load()
    }

    /// nil means "use default" for bound actions, or "not bound at all"
    /// for the optional alt actions.
    func binding(for a: AppAction) -> KeyBinding? {
        bindings[a] ?? Self.defaults[a]
    }

    func display(for a: AppAction) -> String {
        guard let b = binding(for: a) else { return "(unset)" }
        let mods = NSEvent.ModifierFlags(rawValue: b.modifiers)
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + pretty(b.key)
    }

    private func pretty(_ k: String) -> String {
        let arrows: [UInt16: String] = [UInt16(NSLeftArrowFunctionKey): "←", UInt16(NSRightArrowFunctionKey): "→",
                                        UInt16(NSUpArrowFunctionKey): "↑", UInt16(NSDownArrowFunctionKey): "↓"]
        if k == "\r" { return "↵" }
        for (code, name) in arrows where k == String(Character(UnicodeScalar(code)!)) { return name }
        return k
    }

    func set(_ binding: KeyBinding?, for a: AppAction) {
        bindings[a] = binding
        save()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func load() {
        bindings = [:]
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data) else { return }
        for (raw, value) in decoded {
            if let action = AppAction(rawValue: raw) { bindings[action] = value }
        }
    }

    private func save() {
        let dict = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}