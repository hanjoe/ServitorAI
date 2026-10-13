import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, PiRpcClientDelegate, ChatPanelDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
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
    /// Consecutive pi restarts without a completed answer; drives backoff.
    private var restartAttempts = 0
    private static let maxRestartAttempts = 6
    private var rpcGaveUp = false
    /// False until the first pi child has been launched (secrets resolve first).
    private var rpcLaunched = false
    private var availableModels: [ModelOption] = []
    /// Last model selected in ServitorAI, retained across pi child restarts.
    private var preferredModel: ModelOption?
    private var currentModelIndex = -1
    private var lastShownFailure: String?
    /// Proton Pass resolution result — computed once at launch, reused by
    /// every pi child restart so pass-cli is never invoked twice.
    private var secretsEnv: [String: String] = [:]
    private var secretsPassKeys: Set<String> = []
    private var secretsFailed: [String] = []
    private var approvedSearchExtension: SearchExtensionCandidate?
    private let searchSetupPromptedKey = "webSearchSetupPrompted"
    private let searchExtensionPathKey = "webSearchExtensionPath"
    private let searchExtensionToolKey = "webSearchExtensionTool"
    private let searchExtensionFingerprintKey = "webSearchExtensionFingerprint"

    // MARK: - Bootstrap

    func applicationDidFinishLaunching(_ notification: Notification) {
        ServitorTheme.registerFonts()
        buildMainMenu()
        buildStatusItem()
        buildPanel()
        buildHotKey()
        buildKeyMonitor()
        // The client exists immediately (commands queue inside it); the pi
        // process starts once secrets are resolved, off the main thread.
        rpc = PiRpcClient(config: config)
        rpc.delegate = self
        resolveSecretsThenStartRpc()
        registerDebugHooks()
        NotificationCenter.default.addObserver(forName: Keymap.changed, object: nil, queue: .main) { [weak self] _ in
            self?.buildMainMenu()
            self?.buildHotKey()
            self?.statusItem.menu = self?.makeStatusMenu()
        }
    }

    /// pass-cli can take seconds (8s cap per reference), so never run it on the
    /// main thread: resolve in the background, then launch pi.
    private func resolveSecretsThenStartRpc() {
        guard let env = config.env, !env.isEmpty else {
            prepareSearchExtension { [weak self] in self?.startRpc() }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Secrets.resolve(env)
            DispatchQueue.main.async {
                guard let self else { return }
                self.secretsEnv = result.values
                self.secretsPassKeys = result.passKeys
                self.secretsFailed = result.failed
                if !self.secretsFailed.isEmpty {
                    self.panel.showNotice("⚠ Proton Pass: couldn't resolve \(self.secretsFailed.joined(separator: ", ")) — run `pass-cli login` or fix the pass:// reference in config.json.")
                }
                self.prepareSearchExtension { [weak self] in self?.startRpc() }
            }
        }
    }

    /// Use a previously approved extension only while its source file still
    /// matches the fingerprint the user approved. First launch asks before any
    /// search extension code is loaded into the chat process.
    private func prepareSearchExtension(completion: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        let savedPath = defaults.string(forKey: searchExtensionPathKey)
        let savedTool = defaults.string(forKey: searchExtensionToolKey)
        let savedFingerprint = defaults.string(forKey: searchExtensionFingerprintKey)
        if let savedPath, let savedTool, let savedFingerprint,
           SearchExtensionCandidate.fingerprintOfFile(at: savedPath) == savedFingerprint {
            approvedSearchExtension = SearchExtensionCandidate(path: savedPath, toolName: savedTool,
                                                               description: "Previously approved pi web-search extension.",
                                                               fingerprint: savedFingerprint,
                                                               packageName: nil)
            completion()
            return
        }
        if savedPath != nil || !defaults.bool(forKey: searchSetupPromptedKey) {
            configureSearchExtension(initial: true) { _ in completion() }
        } else {
            approvedSearchExtension = nil
            completion()
        }
    }

    /// Presents candidate extensions without executing them. Consent is stored
    /// per source fingerprint, and the prompt explains that extensions execute
    /// with the same user permissions as pi.
    private func configureSearchExtension(initial: Bool, completion: @escaping (Bool) -> Void) {
        let candidates = SearchExtensionDiscovery.discover()
        guard !candidates.isEmpty else {
            if initial {
                UserDefaults.standard.set(true, forKey: searchSetupPromptedKey)
                panel.showNotice("Web search is off: no pi extension advertising a search tool was found. You can add one and choose Configure Web Search… later.")
            } else {
                panel.showNotice("No pi extension advertising a web-search tool was found.")
            }
            completion(false)
            return
        }

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        for candidate in candidates {
            picker.addItem(withTitle: candidate.displayName)
        }
        let alert = NSAlert()
        alert.messageText = "Allow a pi web-search extension in ServitorAI?"
        alert.informativeText = "The selected extension will run inside ServitorAI's pi process with your user permissions. Review its source and trust its author before enabling it. Only its search-named tool will be exposed to the model."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Enable Selected Extension")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        UserDefaults.standard.set(true, forKey: searchSetupPromptedKey)
        guard response == .alertFirstButtonReturn,
              candidates.indices.contains(picker.indexOfSelectedItem) else {
            if initial { approvedSearchExtension = nil }
            completion(false)
            return
        }
        let candidate = candidates[picker.indexOfSelectedItem]
        UserDefaults.standard.set(candidate.path, forKey: searchExtensionPathKey)
        UserDefaults.standard.set(candidate.toolName, forKey: searchExtensionToolKey)
        UserDefaults.standard.set(candidate.fingerprint, forKey: searchExtensionFingerprintKey)
        approvedSearchExtension = candidate
        completion(true)
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
        let search = NSMenuItem(title: "Search Transcript", action: #selector(actCopySearch), keyEquivalent: "/")
        search.keyEquivalentModifierMask = [.control]
        search.target = self
        appMenu.addItem(search)
        // ⌃⇧1-0 act on the n-th copyable/openable target visible in the
        // viewport: code blocks/inline code copy, web links open.
        for n in 1...10 {
            let item = NSMenuItem(title: "Target in View #\(n)", action: #selector(actVisibleTarget(_:)), keyEquivalent: n == 10 ? "0" : String(n))
            item.keyEquivalentModifierMask = [.control, .shift]
            item.target = self
            item.tag = n
            appMenu.addItem(item)
        }
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
        let searchSetup = NSMenuItem(title: "Configure Web Search…", action: #selector(actConfigureWebSearch), keyEquivalent: "")
        searchSetup.target = self
        appMenu.addItem(searchSetup)
        for i in 0..<min(9, availableModels.count) {
            let item = NSMenuItem(title: "Model \(i + 1): \(availableModels[i].label)", action: #selector(selectModelByTag(_:)), keyEquivalent: String(i + 1))
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

    /// Debug-only distributed-notification hooks (dump/submit). Compiled out
    /// of release builds so no local process can inject prompts or capture
    /// screenshots in a production install.
    #if DEBUG
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
    #else
    private func registerDebugHooks() {}
    #endif

    private func startRpc() {
        // The first launch reuses the client created at startup (it may hold
        // queued commands); every restart needs a fresh Process.
        if rpcLaunched {
            // Model choice is retained by AppDelegate and re-applied only after
            // pi's authenticated model catalog has been loaded.
            rpc = PiRpcClient(config: config)
            rpc.delegate = self
        }
        rpcLaunched = true
        let client = rpc!
        client.start(
            resolvedEnv: secretsEnv,
            passKeys: secretsPassKeys,
            searchExtensionPath: approvedSearchExtension?.path,
            searchToolName: approvedSearchExtension?.toolName,
            searchFingerprint: approvedSearchExtension?.fingerprint
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak client] in
            guard let self, let client, self.rpc === client else { return }
            self.loadPiModels(using: client)
        }
    }

    /// Exponential backoff (1.5s, 3s, 6s … capped at 60s) with a retry limit, so
    /// a missing or crashing pi binary can't spin in a tight restart loop.
    private func scheduleRpcRestart() {
        guard !restartScheduled, !rpcGaveUp else { return }
        guard restartAttempts < Self.maxRestartAttempts else {
            rpcGaveUp = true
            Debug.log("pi restart: giving up after \(restartAttempts) attempts")
            panel.showNotice("⚠ pi keeps exiting — check /opt/homebrew/bin/pi and ~/.config/servitorai/pi.log. Send a message to try again.")
            return
        }
        let delay = min(60.0, 1.5 * pow(2.0, Double(restartAttempts)))
        restartAttempts += 1
        restartScheduled = true
        Debug.log("pi restart: attempt \(restartAttempts) in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
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

    /// The global toggle binding lives in keybinds.conf like every other
    /// shortcut (default ⌘⇧A); when it's rebuildable it's re-registered on
    /// keymap changes, and "unset" disables the global hotkey entirely.
    private func buildHotKey() {
        hotKey = nil
        guard let b = Keymap.shared.binding(for: .togglePanel) else { return }
        guard let keyCode = Keymap.virtualKeyCode(for: b.key) else {
            NSLog("ServitorAI: no virtual key code for global hotkey '\(b.key)' — toggle hotkey not registered")
            return
        }
        hotKey = GlobalHotKey(keyCode: keyCode, modifiers: Keymap.carbonModifiers(b.modifiers)) { [weak self] in
            self?.togglePanel()
        }
        if hotKey == nil { NSLog("ServitorAI: failed to register toggle hotkey (Keymap: \(Keymap.shared.display(for: .togglePanel)))") }
    }

    // MARK: - Keyboard shortcuts (active while the panel has focus)

    private func buildKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.panel.noteTranscriptMouseDown(event)
            return event
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            // NSTextView updates selection after this monitor; inspect it on the
            // next main-loop turn, once AppKit has completed mouse selection.
            DispatchQueue.main.async { [weak self] in
                self?.panel.finishTranscriptMouseSelection()
            }
            return event
        }
    }

    /// Returns nil when the event was consumed. All action shortcuts are real
    /// NSMenu key equivalents (rebuilt from the Keymap); this only handles Esc
    /// and routing typed characters to the input box.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible else { return event }
        if panel.handleCopyModeKey(event) { return nil }
        if panel.scrollTranscriptPage(event.keyCode) { return nil }
        if event.keyCode == 53 && !event.modifierFlags.contains(.command) {
            cancelOrAbort(); return nil                                     // Esc
        }
        if panel.routeTypingToInput(event) { return nil }
        return event
    }

    // MARK: - Menus

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open ServitorAI", action: #selector(togglePanel), keyEquivalent: "")
        if let b = Keymap.shared.binding(for: .togglePanel) {
            open.keyEquivalent = b.key
            open.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: b.modifiers)
        }
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
        guard !availableModels.isEmpty else {
            let item = NSMenuItem(title: "No pi models available — sign in with pi /login", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        }
        for (i, m) in availableModels.enumerated() {
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
        add("Toggle Panel", #selector(togglePanel), .togglePanel)
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
    /// Opens ~/.config/servitorai/keybinds.conf in a terminal editor. Prefers
    /// Ghostty + $EDITOR when both are present, but neither is required:
    /// falls back to Terminal.app (ships on every Mac) and to nvim/vim/vi
    /// (vi is POSIX-guaranteed present) when $EDITOR/$VISUAL aren't set.
    private func openKeybindsConfigInEditor() {
        let path = Keymap.configPath.path
        let editor = resolveEditor()
        Debug.log("settings: opening \(path) with editor=\(editor)")

        if FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") {
            // Ghostty's own CLI docs: launching the terminal directly isn't
            // supported on macOS — `open -na Ghostty --args -e <cmd>` is the
            // documented path.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", "/Applications/Ghostty.app", "--args", "-e", editor, path]
            if (try? p.run()) != nil { return }
        }

        // Universal fallback: Terminal.app, present on every macOS install.
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let command = "\(editor) \"\(escapedPath)\"".replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        if (try? p.run()) != nil { return }

        // Nothing scriptable worked — hand the file to whatever macOS has
        // registered for it (likely TextEdit).
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// $EDITOR/$VISUAL first; then common absolute install paths (a
    /// GUI-launched app's PATH often lacks /opt/homebrew/bin); then `which`;
    /// then /usr/bin/vi, which every macOS install ships.
    private func resolveEditor() -> String {
        if let e = ProcessInfo.processInfo.environment["EDITOR"], !e.isEmpty { return e }
        if let e = ProcessInfo.processInfo.environment["VISUAL"], !e.isEmpty { return e }
        let candidates = [
            "/opt/homebrew/bin/nvim", "/usr/local/bin/nvim",
            "/opt/homebrew/bin/vim", "/usr/local/bin/vim", "/usr/bin/vim",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        if let found = which("nvim") ?? which("vim") { return found }
        return "/usr/bin/vi"
    }

    private func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !out.isEmpty else { return nil }
        return out
    }
    @objc private func actShowModelPicker() { panel.showModelMenu() }
    @objc private func actConfigureWebSearch() {
        configureSearchExtension(initial: false) { [weak self] changed in
            guard let self, changed else { return }
            self.panel.showNotice("✓ Web-search choice saved. Quit and relaunch ServitorAI to apply it.")
        }
    }
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
        availableModels.indices.contains(currentModelIndex) ? availableModels[currentModelIndex].label : "Loading pi models…"
    }

    private func setCurrentModel(_ model: ModelOption, on client: PiRpcClient) {
        preferredModel = model
        client.selectedModel = (model.provider, model.modelId)
        currentModelIndex = availableModels.firstIndex { $0.provider == model.provider && $0.modelId == model.modelId } ?? -1
        panel.setModelLabel(model.label)
        statusItem.button?.toolTip = "ServitorAI · \(model.label)"
        buildMainMenu()
    }

    private func loadPiModels(using client: PiRpcClient) {
        client.getAvailableModels { [weak self, weak client] models in
            guard let self, let client, self.rpc === client else { return }
            guard let models else {
                self.panel.showNotice("⚠ Couldn't read pi's available models. Check the pi process and ~/.config/servitorai/pi.log.")
                return
            }
            self.availableModels = ModelCatalog.ordered(available: models, favourites: self.config.models)
            self.buildMainMenu()
            client.refreshState { [weak self, weak client] state in
                guard let self, let client, self.rpc === client else { return }
                let current = state?["model"] as? [String: Any]
                let hadPreviousPick = self.preferredModel != nil
                let configuredAvailable = self.availableModels.contains {
                    $0.provider == self.config.provider && $0.modelId == self.config.model
                }
                let target = ModelCatalog.choose(
                    available: self.availableModels,
                    previous: self.preferredModel,
                    configuredProvider: self.config.provider,
                    configuredModel: self.config.model,
                    piCurrentProvider: current?["provider"] as? String,
                    piCurrentModel: current?["id"] as? String
                )
                guard let target else {
                    self.currentModelIndex = -1
                    self.panel.setModelLabel("No model available")
                    self.statusItem.button?.toolTip = "ServitorAI · No model available"
                    self.panel.showNotice("⚠ No models available. Sign in with `pi` → `/login`, or configure an API-key provider in pi's models.json.")
                    self.buildMainMenu()
                    return
                }
                let matchesCurrent = current?["provider"] as? String == target.provider
                    && current?["id"] as? String == target.modelId
                if matchesCurrent {
                    self.setCurrentModel(target, on: client)
                } else {
                    self.switchModel(target, showToast: false)
                }
                if !hadPreviousPick && !configuredAvailable {
                    self.panel.showNotice("ℹ Using \(target.label) — the configured default isn't currently available in pi.")
                }
            }
        }
    }

    private func switchModel(_ m: ModelOption, showToast: Bool = true) {
        Debug.log("action: switchModel \(m.provider)/\(m.modelId)")
        let previousIndex = currentModelIndex
        panel.setModelLabel(m.label)
        statusItem.button?.toolTip = "ServitorAI · \(m.label)"
        let client = rpc!
        client.setModel(provider: m.provider, modelId: m.modelId) { [weak self, weak client] data in
            guard let self, let client, self.rpc === client else { return }
            if data == nil {
                self.currentModelIndex = previousIndex
                self.panel.setModelLabel(self.currentModelLabel())
                self.statusItem.button?.toolTip = "ServitorAI · \(self.currentModelLabel())"
                if showToast { self.panel.toast("Model switch failed") }
            } else {
                self.setCurrentModel(m, on: client)
                if showToast { self.panel.toast("Model: \(m.label)") }
            }
        }
    }

    private func cycleModel() {
        guard !availableModels.isEmpty else { return }
        let next = currentModelIndex < 0 ? 0 : (currentModelIndex + 1) % availableModels.count
        switchModel(availableModels[next])
    }

    private func pickModel(_ index: Int) {
        guard availableModels.indices.contains(index) else { return }
        switchModel(availableModels[index])
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
        let modelDescription = preferredModel.map { "\($0.provider)/\($0.modelId)" } ?? "unavailable"
        Debug.log("submit(chars: \(text.count)) model=\(modelDescription)")
        if rpcGaveUp {
            // The user is trying again after we stopped auto-restarting.
            rpcGaveUp = false
            restartAttempts = 0
            startRpc()
        }
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

    /// ⌃⇧1-0 — copy or open the n-th visible code/link target.
    @objc private func actVisibleTarget(_ sender: NSMenuItem) {
        panel.invokeNumberedTarget(sender.tag)
    }

    @objc private func actCopySearch() { panel.beginCopySearch() }

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
        restartAttempts = 0   // pi is healthy again: reset the backoff
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

    func piClient(_ client: PiRpcClient, toolDidFail name: String, message: String) {
        guard let approved = approvedSearchExtension, name == approved.toolName else { return }
        panel.showNotice("⚠ Web search failed: \(message)")
    }
}
