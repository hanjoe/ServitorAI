import AppKit

enum PanelAction {
    case copyAnswer
    case pasteAnswer
    case regenerate
}

protocol ChatPanelDelegate: AnyObject {
    func chatPanel(_ panel: ChatPanel, didSubmit text: String)
    func chatPanelDidRequestCancel(_ panel: ChatPanel)
    func chatPanelDidRequestNewChat(_ panel: ChatPanel)
    func chatPanel(_ panel: ChatPanel, didInvoke action: PanelAction)
}

/// NSPanel subclass: borderless windows refuse key status by default, which
/// prevented the input field from ever receiving keyboard focus.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ChatPanel: NSObject, NSTextFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    weak var delegate: ChatPanelDelegate?

    /// Menus supplied by the owner.
    var onModelMenu: (() -> NSMenu)?
    var onHistoryMenu: (() -> NSMenu)?

    // MARK: Views

    private let panel: NSPanel
    private let backButton = NSButton()
    private let newButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "New Chat")
    private let modelButton = NSButton()
    private let inputField = NSTextField()
    private let scrollView: NSScrollView
    private let outputView: NSTextView
    private let emptyStateView = NSView()
    private let emptyTitle = NSTextField(labelWithString: "Ask anything")
    private let emptySubtitle = NSTextField(labelWithString: "The quickest way to ask AI, right in the launcher.")
    private let busySpinner = NSProgressIndicator()
    private let watermarkView = NSImageView()
    private let toastLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    private let T = ServitorTheme.self

    // MARK: Transcript model

    private final class Item {
        enum Kind { case user, assistant, notice }
        let kind: Kind
        var text: String
        var done: Bool
        var rendered: NSAttributedString?
        var renderedAsLast = false
        var codeBlocks: [String] = []
        init(_ kind: Kind, _ text: String, done: Bool = true) {
            self.kind = kind; self.text = text; self.done = done
        }
    }

    private var items: [Item] = []
    private var rebuildScheduled = false
    private var layoutWidth: CGFloat = 0
    private var toastToken = 0

    static let defaultSize = NSSize(width: 960, height: 700)

    /// The one-line cheat sheet shown above the input and in the empty state.
    static func hintText() -> String {
        let k = Keymap.shared
        return [
            "\(k.display(for: .actionsMenu)) actions",
            "\(k.display(for: .copyAnswer)) copy",
            "\(k.display(for: .copyCode)) code",
            "\(k.display(for: .regenerate)) retry",
            "\(k.display(for: .newChat)) new",
            "\(k.display(for: .cycleModel)) model",
            "⌃1-9 pick",
            "\(k.display(for: .prevChat))/\(k.display(for: .nextChat)) chats",
            "esc close",
        ].joined(separator: " · ")
    }

    private static func initialSize() -> NSSize {
        let d = UserDefaults.standard
        var w = d.double(forKey: "panelWidth")
        var h = d.double(forKey: "panelHeight")
        if w < 640 || h < 420 { w = defaultSize.width; h = defaultSize.height }
        if let vf = NSScreen.main?.visibleFrame {
            w = min(w, vf.width * 0.94)
            h = min(h, vf.height * 0.94)
        }
        return NSSize(width: w, height: h)
    }

    override init() {
        // NSTextView.scrollableTextView() wires up wrapping / resizing correctly
        // (a bare NSTextView has an unbounded container and never wraps).
        let sv = NSTextView.scrollableTextView()
        scrollView = sv
        outputView = sv.documentView as! NSTextView
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: ChatPanel.initialSize()),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
    }

    // MARK: - Layout

    private func build() {
        ServitorTheme.registerFonts()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.minSize = NSSize(width: 640, height: 420)
        panel.delegate = self

        let content = panel.contentView!
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = T.base.cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = T.surface1.cgColor

        // Faded winged-skull watermark — bundled PNG, falling back to the drawn sigil.
        let bundled: NSImage? = {
            guard let res = Bundle.main.resourcePath else { return nil }
            return NSImage(contentsOf: URL(fileURLWithPath: res + "/servitor-skull.png"))
        }()
        watermarkView.image = bundled ?? Sigil.wingedSkull(size: 300)
        watermarkView.imageScaling = .scaleProportionallyUpOrDown
        if bundled == nil { watermarkView.contentTintColor = T.brass }
        watermarkView.alphaValue = 0.18
        watermarkView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(watermarkView)

        // --- Header ---
        let symbol = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "History")?.withSymbolConfiguration(symbol)
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.isBordered = false
        backButton.contentTintColor = T.subtext
        backButton.toolTip = "Recent chats (⌘[ / ⌘])"

        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New chat")?.withSymbolConfiguration(symbol)
        newButton.target = self
        newButton.action = #selector(newTapped)
        newButton.isBordered = false
        newButton.contentTintColor = T.subtext
        newButton.toolTip = "New chat (⌘N)"

        titleLabel.font = T.pixel(10)
        titleLabel.textColor = T.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modelButton.target = self
        modelButton.action = #selector(modelTapped)
        modelButton.isBordered = false
        modelButton.toolTip = "Change model (⌘M cycles · ⌘1–9 pick · ⌘⇧M menu)"
        setModelLabel("Model")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [backButton, newButton, titleLabel, spacer, modelButton])
        header.orientation = .horizontal
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 12, right: 18)
        header.translatesAutoresizingMaskIntoConstraints = false

        // --- Output (wraps to the visible width) ---
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.drawsBackground = false
        outputView.allowsUndo = false
        outputView.isAutomaticLinkDetectionEnabled = false
        outputView.textContainerInset = NSSize(width: 18, height: 14)
        outputView.textContainer?.lineFragmentPadding = 0
        outputView.delegate = self
        outputView.linkTextAttributes = [
            .foregroundColor: T.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        outputView.selectedTextAttributes = [
            .backgroundColor: T.surface1,
            .foregroundColor: T.text,
        ]

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // --- Empty state (centered) ---
        emptyTitle.font = T.pixel(20)
        emptyTitle.textColor = T.text
        emptyTitle.alignment = .center
        emptySubtitle.font = T.body(24)
        emptySubtitle.textColor = T.subtext
        emptySubtitle.alignment = .center

        let emptyHints = NSTextField(labelWithString: ChatPanel.hintText())
        emptyHints.font = T.pixel(12)
        emptyHints.textColor = T.overlay0
        emptyHints.alignment = .center

        let emptyStack = NSStackView(views: [emptyTitle, emptySubtitle, emptyHints])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 14
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyStack)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
        ])

        // --- Busy spinner ---
        busySpinner.style = .spinning
        busySpinner.controlSize = .regular
        busySpinner.isDisplayedWhenStopped = false
        busySpinner.translatesAutoresizingMaskIntoConstraints = false

        // --- Input (rounded) ---
        let inputContainer = NSView()
        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 12
        inputContainer.layer?.backgroundColor = T.surface0.cgColor
        inputContainer.translatesAutoresizingMaskIntoConstraints = false

        inputField.placeholderAttributedString = NSAttributedString(string: "Ask the servitor…", attributes: [
            .font: T.inputFont, .foregroundColor: T.overlay0,
        ])
        inputField.font = T.inputFont
        inputField.textColor = T.text
        inputField.delegate = self
        inputField.isBezeled = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.translatesAutoresizingMaskIntoConstraints = false

        inputContainer.addSubview(inputField)
        inputContainer.addSubview(busySpinner)
        NSLayoutConstraint.activate([
            inputField.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 16),
            inputField.trailingAnchor.constraint(equalTo: busySpinner.leadingAnchor, constant: -10),
            inputField.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            busySpinner.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -14),
            busySpinner.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            inputContainer.heightAnchor.constraint(equalToConstant: 56),
        ])

        // --- Keyboard hints (always visible above the input) ---
        hintLabel.stringValue = ChatPanel.hintText()
        NotificationCenter.default.addObserver(forName: Keymap.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.hintLabel.stringValue = ChatPanel.hintText()
            self.items.forEach { $0.rendered = nil }
            self.rebuild()
        }
        hintLabel.font = T.pixel(11)
        hintLabel.textColor = T.overlay0
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        // --- Toast ---
        toastLabel.wantsLayer = true
        toastLabel.drawsBackground = true
        toastLabel.backgroundColor = T.surface1
        toastLabel.layer?.cornerRadius = 7
        toastLabel.layer?.masksToBounds = true
        toastLabel.alignment = .center
        toastLabel.isHidden = true
        toastLabel.translatesAutoresizingMaskIntoConstraints = false

        // --- Assemble ---
        for v in [header, scrollView, emptyStateView, hintLabel, inputContainer, toastLabel] {
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            watermarkView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            watermarkView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            watermarkView.widthAnchor.constraint(equalToConstant: 300),
            watermarkView.heightAnchor.constraint(equalToConstant: 300),

            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -12),

            emptyStateView.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -12),

            inputContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            inputContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            inputContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            toastLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -20),
            toastLabel.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    // MARK: - Button actions

    @objc private func backTapped() { showHistoryMenu() }
    @objc private func newTapped() { delegate?.chatPanelDidRequestNewChat(self) }
    @objc private func modelTapped() { showModelMenu() }

    // MARK: - Public API

    func setModelLabel(_ text: String) {
        modelButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: T.pixel(9), .foregroundColor: T.brass,
        ])
    }

    func setChatTitle(_ text: String) {
        titleLabel.stringValue = text.isEmpty ? "New Chat" : text
    }

    func show() {
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        inputField.window?.makeFirstResponder(inputField)
    }

    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }
    func focusInput() { inputField.window?.makeFirstResponder(inputField) }

    func setBusy(_ busy: Bool) {
        if busy { busySpinner.startAnimation(nil) } else { busySpinner.stopAnimation(nil) }
    }

    func showModelMenu() {
        guard let menu = onModelMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelButton.bounds.height + 2), in: modelButton)
    }

    func showHistoryMenu() {
        guard let menu = onHistoryMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: backButton.bounds.height + 2), in: backButton)
    }

    /// Pops a menu (e.g. the ⌘K actions menu) near the top-right of the panel.
    func popUpMenu(_ menu: NSMenu) {
        guard let content = panel.contentView else { return }
        let x = max(20, content.bounds.width - 340)
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: content.bounds.height - 50), in: content)
    }

    func toast(_ text: String) {
        toastLabel.attributedStringValue = NSAttributedString(string: "   \(text)   ", attributes: [
            .font: T.pixel(9), .foregroundColor: T.bone,
        ])
        toastLabel.isHidden = false
        toastLabel.alphaValue = 1
        toastToken += 1
        let token = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.toastToken == token else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.toastLabel.animator().alphaValue = 0
            }, completionHandler: {
                if self.toastToken == token { self.toastLabel.isHidden = true }
            })
        }
    }

    // MARK: - Transcript API

    func appendUser(_ text: String) {
        items.append(Item(.user, text))
        emptyStateView.isHidden = true
        rebuild()
    }

    func beginAssistant() {
        items.append(Item(.assistant, "", done: false))
        emptyStateView.isHidden = true
        rebuild()
    }

    func appendRawAssistant(_ delta: String) {
        if let last = items.last, last.kind == .assistant, !last.done {
            last.text += delta
        } else {
            items.append(Item(.assistant, delta, done: false))
        }
        emptyStateView.isHidden = true
        scheduleRebuild()
    }

    func finishAssistant() {
        if let last = items.last, last.kind == .assistant { last.done = true }
        rebuild()
    }

    func showNotice(_ text: String) {
        items.append(Item(.notice, text))
        emptyStateView.isHidden = true
        rebuild()
    }

    func clear() {
        items.removeAll()
        emptyStateView.isHidden = false
        rebuild()
    }

    func render(messages: [ChatMessage]) {
        items = messages.map { Item($0.role == "user" ? .user : .assistant, $0.text) }
        emptyStateView.isHidden = !items.isEmpty
        rebuild()
    }

    // MARK: - Rendering

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    private func isNearBottom() -> Bool {
        guard let doc = scrollView.documentView else { return true }
        return scrollView.contentView.bounds.maxY >= doc.frame.height - 60
    }

    private func rebuild() {
        let stick = isNearBottom()
        let origin = scrollView.contentView.bounds.origin

        let width = round(scrollView.contentSize.width)
        if width != layoutWidth {
            layoutWidth = width
            items.forEach { $0.rendered = nil }
        }

        let lastAnswer = items.lastIndex(where: { $0.kind == .assistant })
        let full = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            full.append(attributed(item, index: i, isLastAnswer: i == lastAnswer))
        }
        outputView.textStorage?.setAttributedString(full)
        outputView.layoutManager?.ensureLayout(for: outputView.textContainer!)

        if stick {
            outputView.scrollToEndOfDocument(nil)
        } else {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func userMargin() -> CGFloat {
        let w = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : panel.frame.width
        return max(120, (w * 0.2).rounded())
    }

    private func attributed(_ item: Item, index: Int, isLastAnswer: Bool) -> NSAttributedString {
        if item.done, let cached = item.rendered, item.renderedAsLast == isLastAnswer { return cached }

        let out = NSMutableAttributedString()
        switch item.kind {
        case .user:
            // Omnissiah: right-aligned, wrapping inside the right-hand column.
            let margin = userMargin()
            let labelStyle = Markdown.para(first: margin, head: margin, spacingAfter: 4, alignment: .right)
            out.append(label("OMNISSIAH", color: T.brass, style: labelStyle))
            let bodyStyle = Markdown.para(first: margin, head: margin, spacingAfter: 6, alignment: .right)
            let body = NSMutableAttributedString(attributedString:
                Markdown.plain(item.text, font: T.bodyFont, color: T.text, style: bodyStyle))
            body.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: bodyStyle, .font: T.bodyFont]))
            out.append(body)

        case .assistant:
            // Servitor: left-aligned markdown.
            out.append(label("SERVITOR", color: T.machineTeal, style: Markdown.para(spacingAfter: 4)))
            let md = Markdown.render(item.text, item: index)
            item.codeBlocks = md.codeBlocks
            out.append(md.text)
            if !item.done {
                out.append(NSAttributedString(string: "▮\n", attributes: [
                    .font: T.bodyFont, .foregroundColor: T.machineTeal,
                    .paragraphStyle: Markdown.para(spacingAfter: 6),
                ]))
            } else if isLastAnswer && !item.text.isEmpty {
                out.append(actionsRow())
            }

        case .notice:
            out.append(NSAttributedString(string: item.text + "\n", attributes: [
                .font: T.body(22), .foregroundColor: T.warning,
                .paragraphStyle: Markdown.para(spacingAfter: 6),
            ]))
        }

        // spacer between messages
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: T.body(10), .paragraphStyle: Markdown.para(spacingAfter: 4),
        ]))

        if item.done {
            item.rendered = out
            item.renderedAsLast = isLastAnswer
        }
        return out
    }

    private func label(_ text: String, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: text + "\n", attributes: [
            .font: T.labelFont, .foregroundColor: color, .kern: 1.0, .paragraphStyle: style,
        ])
    }

    private func actionsRow() -> NSAttributedString {
        let style = Markdown.para(spacingBefore: 2, spacingAfter: 4)
        let row = NSMutableAttributedString()
        // Each button shows the key that triggers it.
        let k = Keymap.shared
        for (i, (title, key, target)) in [("COPY", k.display(for: .copyAnswer), "copy-answer"), ("RETRY", k.display(for: .regenerate), "regenerate")].enumerated() {
            if i > 0 { row.append(NSAttributedString(string: "    ", attributes: [.font: T.pixel(10)])) }
            let start = row.length
            row.append(NSAttributedString(string: "[ \(title) \(key) ]", attributes: [
                .font: T.pixel(10),
            ]))
            row.addAttribute(.link, value: URL(string: "servitor://\(target)") as Any,
                             range: NSRange(location: start, length: row.length - start))
        }
        row.append(NSAttributedString(string: "\n"))
        row.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: row.length))
        return row
    }

    // MARK: - Typing / focus helpers

    /// True when the (read-only) transcript owns keyboard focus.
    var isTranscriptFocused: Bool { panel.firstResponder === outputView }

    /// If a printable key is pressed while the transcript is focused, move
    /// focus to the input and type it there. Returns true if handled.
    func routeTypingToInput(_ event: NSEvent) -> Bool {
        guard isTranscriptFocused,
              let chars = event.characters,
              let scalar = chars.unicodeScalars.first else { return false }
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (0xF700...0xF8FF).contains(v) { return false }
        panel.makeFirstResponder(inputField)
        (inputField.currentEditor() as? NSTextView)?
            .insertText(chars, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    // MARK: - NSTextViewDelegate (links)

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        guard url.scheme == "servitor" else {
            NSWorkspace.shared.open(url)
            return true
        }
        switch url.host {
        case "copy-code":
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count == 2, let i = Int(parts[0]), let b = Int(parts[1]),
               items.indices.contains(i), items[i].codeBlocks.indices.contains(b) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items[i].codeBlocks[b], forType: .string)
                toast("Code copied")
            }
        case "copy-answer": delegate?.chatPanel(self, didInvoke: .copyAnswer)
        case "paste": delegate?.chatPanel(self, didInvoke: .pasteAnswer)
        case "regenerate": delegate?.chatPanel(self, didInvoke: .regenerate)
        default: break
        }
        return true
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            inputField.stringValue = ""
            delegate?.chatPanel(self, didSubmit: text)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            delegate?.chatPanelDidRequestCancel(self)
            return true
        }
        return false
    }

    // MARK: - Debug

    /// Renders the panel to a PNG (no Screen Recording permission needed) and
    /// logs the transcript's layout metrics. Triggered via a Darwin notification.
    func dumpSnapshot(to path: String) {
        guard let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        let used = outputView.layoutManager.map { $0.usedRect(for: outputView.textContainer!) } ?? .zero
        let links = countLinks()
        Debug.log("dump: key=\(panel.isKeyWindow) appActive=\(NSApp.isActive) fr=\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") input=\"\(inputField.stringValue.prefix(40))\" panel=\(NSStringFromSize(panel.frame.size)) clipW=\(scrollView.contentSize.width) containerW=\(outputView.textContainer?.size.width ?? -1) usedW=\(used.width) usedH=\(used.height) items=\(items.count) links=\(links)")
    }

    private func countLinks() -> Int {
        guard let s = outputView.textStorage else { return 0 }
        var n = 0
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { v, _, _ in if v != nil { n += 1 } }
        return n
    }
}

extension ChatPanel {
    func windowDidBecomeKey(_ notification: Notification) {
        // Borderless panels need explicit focus management so typing always
        // lands in the input field.
        focusInput()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleRebuild()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        let size = panel.frame.size
        UserDefaults.standard.set(Double(size.width), forKey: "panelWidth")
        UserDefaults.standard.set(Double(size.height), forKey: "panelHeight")
    }
}
