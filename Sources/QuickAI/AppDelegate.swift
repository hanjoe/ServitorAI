import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, PiRpcClientDelegate, ChatPanelDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private let config = AppConfig.load()
    private var rpc: PiRpcClient!
    private var panel: ChatPanel!

    private var messages: [ChatMessage] = []
    private var currentAssistantText = ""
    private var isStreaming = false
    private var currentId = ""
    private var restartScheduled = false

    private var currentModelIndex = 0
    private var lastShownFailure: String?
    private var navList: [String] = []
    private var navIndex = -1

    // MARK: - Bootstrap

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        buildPanel()
        buildHotKey()
        buildKeyMonitor()
        resolveInitialModelIndex()
        startRpc()
        warnIfKeyMissing()
    }

    private func resolveInitialModelIndex() {
        if let idx = config.models.firstIndex(where: { $0.modelId == config.model && $0.provider == config.provider }) {
            currentModelIndex = idx
        }
    }

    /// Warn up front when the default provider cannot authenticate (e.g. the
    /// config still has the placeholder key), so failure is visible before
    /// the first prompt instead of a silent spinner.
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

    private func buildKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.keyCode == 53 { // Esc
                self.cancelOrAbort()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = mods.contains(.command)
            let shift = mods.contains(.shift)
            guard cmd, let c = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch c {
            case "n": self.newChat(); return nil
            case "w": self.panel.hide(); return nil
            case "r": self.regenerate(); return nil
            case "m": self.cycleModel(); return nil
            case "[": self.navigateChat(-1); return nil
            case "]": self.navigateChat(1); return nil
            case "c": if shift { self.quickCopy(); return nil }; return event
            default: return event
            }
        }
    }

    private func currentModelLabel() -> String {
        if config.models.indices.contains(currentModelIndex) {
            return config.models[currentModelIndex].label
        }
        return config.model
    }

    // MARK: - Menus

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open ServitorAI", action: #selector(togglePanel), keyEquivalent: "A")
        open.keyEquivalentModifierMask = [.command, .shift]
        open.target = self
        menu.addItem(open)

        let newChat = NSMenuItem(title: "New Chat", action: #selector(newChatFromMenu), keyEquivalent: "n")
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
            let item = NSMenuItem(title: m.label, action: #selector(selectModel(_:)), keyEquivalent: "")
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
        let recent = SessionStore.recent(limit: 3, excludeId: currentId.isEmpty ? nil : currentId)
        return recent.map { meta in
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
        let when = formatter.localizedString(for: meta.updated, relativeTo: Date())
        return "\(title) · \(when)"
    }

    // MARK: - Actions

    @objc private func togglePanel() {
        if panel.isVisible { panel.hide() } else { panel.show() }
    }

    @objc private func newChatFromMenu() { newChat() }

    @objc private func resumeSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        resume(id: id)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int, config.models.indices.contains(i) else { return }
        switchModel(config.models[i])
    }

    // MARK: - Model switching

    private func switchModel(_ m: ModelOption) {
        currentModelIndex = config.models.firstIndex(where: { $0.modelId == m.modelId && $0.provider == m.provider }) ?? currentModelIndex
        rpc.setModel(provider: m.provider, modelId: m.modelId) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.panel.setModelLabel(m.label)
                self.statusItem.button?.toolTip = "ServitorAI · \(m.label)"
            }
        }
    }

    private func cycleModel() {
        guard !config.models.isEmpty else { return }
        currentModelIndex = (currentModelIndex + 1) % config.models.count
        switchModel(config.models[currentModelIndex])
    }

    // MARK: - Chat logic

    private func newChat() {
        saveCurrentSession()
        messages = []
        currentAssistantText = ""
        isStreaming = false
        currentId = ""
        panel.clear()
        panel.setBusy(false)
        rpc.newSession { [weak self] in self?.refreshAfterChange() }
    }

    private func resume(id: String) {
        guard let meta = SessionStore.load(id: id) else { return }
        saveCurrentSession()
        messages = meta.messages
        currentId = meta.id
        currentAssistantText = ""
        isStreaming = false
        panel.render(messages: messages)
        rpc.switchSession(path: meta.sessionFile) { [weak self] in self?.refreshAfterChange() }
        panel.show()
    }

    private func regenerate() {
        guard let lastUser = messages.last(where: { $0.role == "user" })?.text else { return }
        submit(text: lastUser)
    }

    private func navigateChat(_ dir: Int) {
        if navList.isEmpty || navIndex < 0 { refreshNavList() }
        guard !navList.isEmpty else { return }
        let next = navIndex + dir
        guard next >= 0 && next < navList.count else { return }
        navIndex = next
        let id = navList[next]
        if id != currentId { resume(id: id) }
    }

    private func refreshNavList() {
        navList = SessionStore.recent(limit: 6, excludeId: nil).map { $0.id }
        if let idx = navList.firstIndex(of: currentId) { navIndex = idx }
        else if !navList.isEmpty { navIndex = 0 }
    }

    private func refreshAfterChange() {
        refreshMenu()
        refreshNavList()
    }

    private func quickCopy() {
        guard let last = messages.last(where: { $0.role == "assistant" })?.text, !last.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(last, forType: .string)
    }

    private func saveCurrentSession() {
        guard !messages.isEmpty else { return }
        let id = currentId.isEmpty ? "session-\(Int(Date().timeIntervalSince1970))" : currentId
        let firstUser = messages.first { $0.role == "user" }?.text ?? ""
        let title = String(firstUser.prefix(40))
        let meta = SessionMeta(
            id: id,
            sessionFile: rpc.sessionFile ?? "",
            title: title,
            updated: Date(),
            messages: messages
        )
        SessionStore.save(meta)
    }

    private func refreshMenu() {
        statusItem.menu = makeStatusMenu()
    }

    private func adoptCurrentId() {
        if let file = rpc.sessionFile {
            currentId = (file as NSString).deletingPathExtension
        }
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

    // MARK: - ChatPanelDelegate

    func chatPanel(_ panel: ChatPanel, didSubmit text: String) {
        submit(text: text)
    }

    private func submit(text: String) {
        Debug.log("submit(text: \"\(text.prefix(40))\") provider=\(config.provider) model=\(config.model)")
        messages.append(ChatMessage(role: "user", text: text))
        currentAssistantText = ""
        isStreaming = true
        panel.appendUser(text)
        panel.beginAssistant()
        panel.setBusy(true)
        adoptCurrentId()
        rpc.prompt(text)
        Debug.log("rpc.prompt() called")
    }

    func chatPanelDidRequestCancel(_ panel: ChatPanel) {
        cancelOrAbort()
    }

    func chatPanelDidRequestNewChat(_ panel: ChatPanel) {
        newChat()
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
            // Startup / idle failures (e.g. pi never managed to launch) are
            // otherwise completely silent — always surface them.
            panel.showNotice("⚠ \(error)")
        }
        lastShownFailure = error
        // Always retry: a dead or never-started pi process must self-heal
        // regardless of what the failure message happens to say.
        scheduleRpcRestart()
    }

    func piClient(_ client: PiRpcClient, didUpdateSession file: String?, id: String?, name: String?) {
        if let file { currentId = (file as NSString).deletingPathExtension }
    }
}
