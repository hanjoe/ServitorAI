import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, PiRpcClientDelegate, ChatPanelDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private let config = AppConfig.load()
    private var rpc: PiRpcClient!
    private var panel: ChatPanel!
    private var previousApp: NSRunningApplication?

    private var messages: [ChatMessage] = []
    private var currentAssistantText = ""
    private var isStreaming = false
    /// Stable app-level chat id (NOT the pi session path — that changes on fork).
    private var currentChatId = UUID().uuidString
    private var restartScheduled = false
    private var currentModelIndex = 0
    private var lastShownFailure: String?

    // MARK: - Bootstrap

    func applicationDidFinishLaunching(_ notification: Notification) {
        ServitorTheme.registerFonts()
        buildMainMenu()
        buildStatusItem()
        buildPanel()
        buildHotKey()
        buildKeyMonitor()
        resolveInitialModelIndex()
        startRpc()
        warnIfKeyMissing()
        registerDebugHooks()
        NotificationCenter.default.addObserver(forName: Keymap.changed, object: nil, queue: .main) { [weak self] _ in
            self?.buildMainMenu()
        }
    }

    /// Accessory apps have no menu bar, so ⌘C/⌘V/⌘X/⌘A/⌘Z never reach text
    /// fields unless an Edit menu exists. It stays invisible but wires them up.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "ServitorAI")
        // All bindings come from the (rebindable) Keymap — ctrl-based by default.
        func bind(_ title: String, _ action: Selector, _ appAction: AppAction) {
            guard let b = Keymap.shared.binding(for: appAction) else { return }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: b.key)
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: b.modifiers)
            item.target = self
            appMenu.addItem(item)
        }
        bind("Actions Menu", #selector(actShowActions), .actionsMenu)
        bind("Settings…", #selector(actSettings), .settings)
        appMenu.addItem(.separator())
        bind("Copy Answer", #selector(actCopyAnswer), .copyAnswer)
        bind("Copy Last Code Block", #selector(actCopyCode), .copyCode)
        bind("Paste Answer to App", #selector(actPaste), .pasteAnswer)
        bind("Regenerate", #selector(actRegenerate), .regenerate)
        bind("Regenerate with Next Model", #selector(actRegenerateNextModel), .regenerateNextModel)
        appMenu.addItem(.separator())
        bind("New Chat", #selector(actNewChat), .newChat)
        bind("Previous Chat", #selector(actPrevChat), .prevChat)
        bind("Next Chat", #selector(actNextChat), .nextChat)
        bind("Previous Chat (alt)", #selector(actPrevChat), .prevChatAlt)
        bind("Next Chat (alt)", #selector(actNextChat), .nextChatAlt)
        bind("Cycle Model", #selector(actCycleModel), .cycleModel)
        bind("Model Picker", #selector(actShowModelPicker), .modelPicker)
        for i in 0..<min(9, config.models.count) {
            let item = NSMenuItem(title: "Model \(i + 1): \(config.models[i].label)", action: #selector(selectModelByTag(_:)), keyEquivalent: String(i + 1))
            item.keyEquivalentModifierMask = [.control]
            item.target = self
            item.tag = i
            appMenu.addItem(item)
        }
        bind("Recent Chats", #selector(actShowHistory), .recentChats)
        bind("Focus Input", #selector(actFocusInput), .focusInput)
        appMenu.addItem(.separator())
        bind("Hide", #selector(actHide), .hide)
        bind("Quit", #selector(NSApplication.terminate(_:)), .quit)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Posting the distributed notification `com.johanneswitt.servitorai.dump`
    /// writes /tmp/servitorai-dump.png (the panel rendered by the app itself,
    /// so no Screen Recording permission is needed) and logs layout metrics.
    private func registerDebugHooks() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.johanneswitt.servitorai.dump"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel.dumpSnapshot(to: "/tmp/servitorai-dump.png")
        }
        // Submit hook for automated testing: posts the text found in
        // /tmp/servitorai-submit.txt straight through the chat pipeline.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.johanneswitt.servitorai.submit"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard let text = try? String(contentsOfFile: "/tmp/servitorai-submit.txt", encoding: .utf8) else {
                Debug.log("submit-hook: no submit file"); return
            }
            panel.show()
            submit(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            try? FileManager.default.removeItem(atPath: "/tmp/servitorai-submit.txt")
        }
    }

    private func resolveInitialModelIndex() {
        if let idx = config.models.firstIndex(where: { $0.modelId == config.model && $0.provider == config.provider }) {
            currentModelIndex = idx
        }
    }

    /// Warn up front when the default provider cannot authenticate.
    private func warnIfKeyMissing() {
        guard config.provider == "ollama-cloud" else { return }
        let fromEnv = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"]
        let effective = fromEnv ?? config.env?["OLLAMA_API_KEY"]
        if effective == nil || effective == "PASTE_YOUR_KEY_HERE" {
            panel.showNotice("⚠ OLLAMA_API_KEY is missing or still the placeholder — DeepSeek will fail. Paste your key into ~/.config/servitorai/config.json, or press ⌘M and pick Claude Haiku (no key needed).")
        }
    }

    private func startRpc() {
        rpc = PiRpcClient(config: config)
        rpc.delegate = self
        rpc.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.rpc.refreshState()
        }
    }

    private func scheduleRpcRestart() {
        guard !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            self.startRpc()
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "ServitorAI")
        statusItem.button?.toolTip = "ServitorAI · \(currentModelLabel())"
        statusItem.menu = makeStatusMenu()
    }

    private func buildPanel() {
        panel = ChatPanel()
        panel.delegate = self
        panel.setModelLabel(currentModelLabel())
        panel.onModelMenu = { [weak self] in self?.modelMenu() ?? NSMenu() }
        panel.onHistoryMenu = { [weak self] in self?.recentSessionsMenu() ?? NSMenu() }
    }

    private func buildHotKey() {
        hotKey = GlobalHotKey(keyCode: 0, modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.togglePanel()
        }
        if hotKey == nil { NSLog("ServitorAI: failed to register ⌘⇧A hotkey") }
    }

    // MARK: - Keyboard shortcuts (active while the panel has focus)

    private func buildKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
    }

    /// Returns nil when the event was consumed. All action shortcuts are real
    /// NSMenu key equivalents (rebuilt from the Keymap); this only handles Esc
    /// and routing typed characters to the input box.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else { return event }
        if event.keyCode == 53 && !event.modifierFlags.contains(.command) {
            cancelOrAbort(); return nil                                     // Esc
        }
        if panel.routeTypingToInput(event) { return nil }
        return event
    }

    // MARK: - Menus

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open ServitorAI", action: #selector(togglePanel), keyEquivalent: "A")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)

        let newChat = NSMenuItem(title: "New Chat", action: #selector(actNewChat), keyEquivalent: "n")
        newChat.keyEquivalentModifierMask = [.command]
        newChat.target = self
        menu.addItem(newChat)

        let recent = recentItems()
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent Chats", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            recent.forEach { menu.addItem($0) }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ServitorAI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func modelMenu() -> NSMenu {
        let menu = NSMenu()
        for (i, m) in config.models.enumerated() {
            let item = NSMenuItem(title: m.label, action: #selector(selectModel(_:)),
                                  keyEquivalent: i < 9 ? String(i + 1) : "")
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            item.representedObject = i
            item.state = (i == currentModelIndex) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func recentSessionsMenu() -> NSMenu {
        let menu = NSMenu()
        let items = recentItems()
        if items.isEmpty {
            let none = NSMenuItem(title: "No previous chats", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            items.forEach { menu.addItem($0) }
        }
        return menu
    }

    private func recentItems() -> [NSMenuItem] {
        SessionStore.recent(limit: 8, excludeId: currentChatId).map { meta in
            let item = NSMenuItem(title: sessionMenuTitle(meta), action: #selector(resumeSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = meta.id
            return item
        }
    }

    private func sessionMenuTitle(_ meta: SessionMeta) -> String {
        let title = meta.title.isEmpty ? "Untitled" : meta.title
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "\(title) · \(formatter.localizedString(for: meta.updated, relativeTo: Date()))"
    }

    /// Actions panel — every action with its current shortcut (from the Keymap).
    private func showActionsMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector, _ action: AppAction) {
            let item = NSMenuItem(title: "\(title)    \(Keymap.shared.display(for: action))", action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Copy Answer", #selector(actCopyAnswer), .copyAnswer)
        add("Copy Last Code Block", #selector(actCopyCode), .copyCode)
        add("Paste Answer to App", #selector(actPaste), .pasteAnswer)
        menu.addItem(.separator())
        add("Regenerate", #selector(actRegenerate), .regenerate)
        add("Regenerate with Next Model", #selector(actRegenerateNextModel), .regenerateNextModel)
        menu.addItem(.separator())
        add("New Chat", #selector(actNewChat), .newChat)
        add("Previous Chat", #selector(actPrevChat), .prevChat)
        add("Next Chat", #selector(actNextChat), .nextChat)

        menu.addItem(.separator())
        let models = NSMenuItem(title: "Change Model", action: nil, keyEquivalent: "")
        models.submenu = modelMenu()
        menu.addItem(models)
        add("Cycle Model", #selector(actCycleModel), .cycleModel)
        add("Model Picker", #selector(actShowModelPicker), .modelPicker)

        let recent = NSMenuItem(title: "Recent Chats", action: nil, keyEquivalent: "")
        recent.submenu = recentSessionsMenu()
        menu.addItem(recent)

        menu.addItem(.separator())
        add("Focus Input", #selector(actFocusInput), .focusInput)
        add("Settings…", #selector(actSettings), .settings)
        let reload = NSMenuItem(title: "Reload Keybinds", action: #selector(actReloadKeybinds), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        add("Hide", #selector(actHide), .hide)
        panel.popUpMenu(menu)
    }

    // MARK: - Menu / action selectors

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.hide()
        } else {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
            panel.show()
        }
    }

    @objc private func actShowActions() { showActionsMenu() }
    @objc private func actSettings() { openKeybindsConfigInEditor() }
    @objc private func actReloadKeybinds() { Keymap.shared.reloadFromDisk(); panel.toast("Keybinds reloaded") }

    /// Opens ~/.config/servitorai/keybinds.conf in the user's terminal editor
    /// (Ghostty running $EDITOR/$VISUAL, falling back to nvim, then to the
    /// OS-default handler for the file). Edits hot-reload automatically.
    private func openKeybindsConfigInEditor() {
        let path = Keymap.configPath.path
        let editor = ProcessInfo.processInfo.environment["EDITOR"]
            ?? ProcessInfo.processInfo.environment["VISUAL"]
            ?? "nvim"
        Debug.log("settings: opening \(path) via ghostty -e \(editor)")

        let ghostty = "/Applications/Ghostty.app"
        guard FileManager.default.fileExists(atPath: ghostty) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        // Ghostty's CLI docs: launching the terminal directly isn't supported
        // on macOS — `open -na Ghostty --args -e <cmd>` is the documented path.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", ghostty, "--args", "-e", editor, path]
        try? p.run()
    }
    @objc private func actShowModelPicker() { panel.showModelMenu() }
    @objc private func actShowHistory() { panel.showHistoryMenu() }
    @objc private func actFocusInput() { panel.focusInput() }
    @objc private func actNewChat() { newChat() }
    @objc private func selectModelByTag(_ sender: NSMenuItem) { pickModel(sender.tag) }
    @objc private func actCopyAnswer() { quickCopy() }
    @objc private func actCopyCode() { copyLastCodeBlock() }
    @objc private func actPaste() { pasteAnswer() }
    @objc private func actRegenerate() { regenerate(nextModel: false) }
    @objc private func actRegenerateNextModel() { regenerate(nextModel: true) }
    @objc private func actPrevChat() { navigateChat(-1) }
    @objc private func actNextChat() { navigateChat(1) }
    @objc private func actCycleModel() { cycleModel() }
    @objc private func actHide() { panel.hide() }

    @objc private func resumeSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        resume(id: id)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        pickModel(i)
    }

    // MARK: - Models

    private func currentModelLabel() -> String {
        config.models.indices.contains(currentModelIndex) ? config.models[currentModelIndex].label : config.model
    }

    private func switchModel(_ m: ModelOption) {
        Debug.log("action: switchModel \(m.provider)/\(m.modelId)")
        if let idx = config.models.firstIndex(where: { $0.modelId == m.modelId && $0.provider == m.provider }) {
            currentModelIndex = idx
        }
        panel.setModelLabel(m.label)
        statusItem.button?.toolTip = "ServitorAI · \(m.label)"
        rpc.setModel(provider: m.provider, modelId: m.modelId) { [weak self] data in
            self?.panel.toast(data == nil ? "Model switch failed" : "Model: \(m.label)")
        }
    }

    private func cycleModel() {
        guard !config.models.isEmpty else { return }
        switchModel(config.models[(currentModelIndex + 1) % config.models.count])
    }

    private func pickModel(_ index: Int) {
        guard config.models.indices.contains(index) else { return }
        switchModel(config.models[index])
    }

    // MARK: - Chat logic

    private func newChat() {
        Debug.log("action: newChat")
        if isStreaming { rpc.abort() }
        saveCurrentSession()
        messages = []
        currentAssistantText = ""
        isStreaming = false
        currentChatId = UUID().uuidString
        panel.clear()
        panel.setChatTitle("")
        panel.setBusy(false)
        rpc.newSession { [weak self] in self?.refreshAfterChange() }
        panel.toast("New chat")
    }

    private func resume(id: String) {
        guard let meta = SessionStore.load(id: id) else { return }
        Debug.log("action: resume \(meta.id) (\(meta.messages.count) messages)")
        if isStreaming { rpc.abort() }
        saveCurrentSession()
        messages = meta.messages
        currentChatId = meta.id
        currentAssistantText = ""
        isStreaming = false
        panel.setBusy(false)
        panel.render(messages: messages)
        panel.setChatTitle(meta.title)
        if !meta.sessionFile.isEmpty {
            rpc.switchSession(path: meta.sessionFile) { [weak self] in self?.refreshAfterChange() }
        }
        if !panel.isVisible { panel.show() }
        panel.toast("Chat: \(meta.title.isEmpty ? "Untitled" : meta.title)")
    }

    /// dir < 0 → older chat (⌘[), dir > 0 → newer chat (⌘]).
    private func navigateChat(_ dir: Int) {
        saveCurrentSession()
        let list = SessionStore.recent(limit: 16, excludeId: nil)   // newest first
        let target: Int?
        if let i = list.firstIndex(where: { $0.id == currentChatId }) {
            target = i + (dir < 0 ? 1 : -1)
        } else {
            target = dir < 0 ? 0 : nil
        }
        Debug.log("action: navigateChat(\(dir)) list=\(list.count) target=\(target.map(String.init) ?? "nil")")
        guard let t = target, list.indices.contains(t) else {
            panel.toast(dir < 0 ? "No older chat" : "No newer chat")
            return
        }
        resume(id: list[t].id)
    }

    private func submit(text: String) {
        Debug.log("submit(text: \"\(text.prefix(40))\") provider=\(config.provider) model=\(config.model)")
        messages.append(ChatMessage(role: "user", text: text))
        currentAssistantText = ""
        isStreaming = true
        panel.appendUser(text)
        panel.beginAssistant()
        panel.setBusy(true)
        panel.setChatTitle(chatTitle())
        rpc.prompt(text)
    }

    /// Esc: abort an in-flight answer (with visible feedback), or hide the panel.
    private func cancelOrAbort() {
        if isStreaming {
            isStreaming = false
            panel.setBusy(false)
            if !currentAssistantText.isEmpty {
                messages.append(ChatMessage(role: "assistant", text: currentAssistantText))
            }
            currentAssistantText = ""
            panel.appendRawAssistant("\n[aborted]\n")
            panel.finishAssistant()
            rpc.abort()
        } else {
            panel.hide()
        }
    }

    /// ⌘R — re-ask the last question. The previous exchange is dropped from
    /// pi's context by forking from the last user message (falls back to a
    /// plain re-ask if forking isn't possible). `nextModel` = ⇧⌘R.
    private func regenerate(nextModel: Bool) {
        guard !isStreaming, let lastUser = messages.last(where: { $0.role == "user" })?.text else {
            panel.toast("Nothing to regenerate")
            return
        }
        Debug.log("action: regenerate nextModel=\(nextModel)")
        while let last = messages.last, last.role != "user" { messages.removeLast() }
        if messages.last?.role == "user" { messages.removeLast() }
        panel.render(messages: messages)
        if nextModel { cycleModel() }

        rpc.getForkMessages { [weak self] ids in
            guard let self else { return }
            guard let last = ids.last else { self.submit(text: lastUser); return }
            self.rpc.fork(entryId: last) { ok in
                Debug.log("regenerate: fork \(ok ? "ok" : "failed")")
                self.rpc.refreshState { _ in self.submit(text: lastUser) }
            }
        }
    }

    private func chatTitle() -> String {
        let first = messages.first(where: { $0.role == "user" })?.text ?? ""
        let line = first.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return String(line.prefix(40))
    }

    private func saveCurrentSession() {
        guard !messages.isEmpty else { return }
        let meta = SessionMeta(
            id: currentChatId,
            sessionFile: rpc.sessionFile ?? "",
            title: chatTitle(),
            updated: Date(),
            messages: messages
        )
        SessionStore.save(meta)
    }

    private func refreshAfterChange() {
        statusItem.menu = makeStatusMenu()
    }

    // MARK: - Copy / paste

    private func lastAnswer() -> String? {
        if isStreaming, !currentAssistantText.isEmpty { return currentAssistantText }
        return messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text
    }

    private func setPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func quickCopy() {
        guard let text = lastAnswer() else { panel.toast("Nothing to copy"); return }
        setPasteboard(text)
        Debug.log("action: quickCopy (\(text.count) chars)")
        panel.toast("Answer copied")
    }

    private func copyLastCodeBlock() {
        guard let text = lastAnswer(), let code = Markdown.codeBlocks(in: text).last else {
            panel.toast("No code block")
            return
        }
        setPasteboard(code)
        Debug.log("action: copyLastCodeBlock (\(code.count) chars)")
        panel.toast("Code copied")
    }

    /// ⌘↵ — copy the answer, return to the app you came from, and paste it
    /// there (needs the Accessibility permission to send ⌘V).
    private func pasteAnswer() {
        guard let text = lastAnswer() else { panel.toast("Nothing to paste"); return }
        setPasteboard(text)
        Debug.log("action: pasteAnswer (\(text.count) chars) trusted=\(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            panel.toast("Copied · allow Accessibility to auto-paste")
            return
        }
        let target = previousApp
        panel.hide()
        target?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // 9 = V
                e?.flags = .maskCommand
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - ChatPanelDelegate

    func chatPanel(_ panel: ChatPanel, didSubmit text: String) { submit(text: text) }
    func chatPanelDidRequestCancel(_ panel: ChatPanel) { cancelOrAbort() }
    func chatPanelDidRequestNewChat(_ panel: ChatPanel) { newChat() }

    func chatPanel(_ panel: ChatPanel, didInvoke action: PanelAction) {
        switch action {
        case .copyAnswer: quickCopy()
        case .pasteAnswer: pasteAnswer()
        case .regenerate: regenerate(nextModel: false)
        }
    }

    // MARK: - PiRpcClientDelegate

    func piClient(_ client: PiRpcClient, didEmitText delta: String) {
        if currentAssistantText.isEmpty { Debug.log("didEmitText: first delta received") }
        currentAssistantText += delta
        panel.appendRawAssistant(delta)
    }

    func piClientDidSettle(_ client: PiRpcClient) {
        Debug.log("piClientDidSettle (isStreaming=\(isStreaming), collectedText=\(currentAssistantText.count) chars)")
        panel.setBusy(false)
        if isStreaming {
            isStreaming = false
            panel.finishAssistant()
            messages.append(ChatMessage(role: "assistant", text: currentAssistantText))
            currentAssistantText = ""
            saveCurrentSession()
            refreshAfterChange()
        }
    }

    func piClient(_ client: PiRpcClient, didFail error: String) {
        Debug.log("piClient didFail: \(error) (isStreaming=\(isStreaming))")
        panel.setBusy(false)
        if isStreaming {
            isStreaming = false
            panel.appendRawAssistant("\n[error: \(error)]\n")
            panel.finishAssistant()
            if !currentAssistantText.isEmpty {
                messages.append(ChatMessage(role: "assistant", text: currentAssistantText))
            }
            currentAssistantText = ""
        } else if error != lastShownFailure {
            panel.showNotice("⚠ \(error)")
        }
        lastShownFailure = error
        // Only restart when the pi process itself died — provider errors
        // (bad key, overload) must not kill the session.
        if error.contains("exited") || error.hasPrefix("Failed to start pi") {
            scheduleRpcRestart()
        }
    }

    func piClient(_ client: PiRpcClient, didUpdateSession file: String?, id: String?, name: String?) {}
}
