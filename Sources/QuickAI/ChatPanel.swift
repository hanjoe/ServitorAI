import AppKit

protocol ChatPanelDelegate: AnyObject {
    func chatPanel(_ panel: ChatPanel, didSubmit text: String)
    func chatPanelDidRequestCancel(_ panel: ChatPanel)
    func chatPanelDidRequestNewChat(_ panel: ChatPanel)
}

/// NSPanel subclass: borderless windows refuse key status by default, which
/// prevented the input field from ever receiving keyboard focus.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ChatPanel: NSObject, NSTextFieldDelegate {
    weak var delegate: ChatPanelDelegate?

    /// Menus supplied by the owner.
    var onModelMenu: (() -> NSMenu)?
    var onHistoryMenu: (() -> NSMenu)?

    private let panel: NSPanel
    private let backButton = NSButton()
    private let newButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "New Chat")
    private let modelButton = NSButton()
    private let inputField = NSTextField()
    private let outputView = NSTextView()
    private let scrollView = NSScrollView()
    private let emptyStateView = NSView()
    private let emptyTitle = NSTextField(labelWithString: "Ask anything")
    private let emptySubtitle = NSTextField(labelWithString: "The quickest way to ask AI, right in the launcher.")
    private let busySpinner = NSProgressIndicator()
    private let watermarkView = NSImageView()

    private let T = ServitorTheme.self

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        build()
    }

    // MARK: - Layout

    private func build() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.delegate = self

        let content = panel.contentView!
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = T.base.cgColor
        content.layer?.borderWidth = 1
        content.layer?.borderColor = T.surface1.cgColor

        // Faded winged-skull watermark (Adeptus Mechanicus) — bundled PNG,
        // falling back to the drawn sigil when unbundled.
        let bundled: NSImage? = {
            guard let res = Bundle.main.resourcePath else { return nil }
            return NSImage(contentsOf: URL(fileURLWithPath: res + "/servitor-skull.png"))
        }()
        watermarkView.image = bundled ?? Sigil.wingedSkull(size: 260)
        watermarkView.imageScaling = .scaleProportionallyUpOrDown
        if bundled == nil { watermarkView.contentTintColor = T.brass }
        watermarkView.alphaValue = 0.18
        watermarkView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(watermarkView)

        // --- Header ---
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "History")
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.isBordered = false
        backButton.contentTintColor = T.subtext
        backButton.toolTip = "Recent chats (⌘[ / ⌘])"

        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New chat")
        newButton.target = self
        newButton.action = #selector(newTapped)
        newButton.isBordered = false
        newButton.contentTintColor = T.subtext
        newButton.toolTip = "New chat (⌘N)"

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = T.text

        modelButton.title = "Model"
        modelButton.target = self
        modelButton.action = #selector(modelTapped)
        modelButton.isBordered = false
        modelButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modelButton.contentTintColor = T.brass

        let spacer = NSView()
        let header = NSStackView(views: [backButton, newButton, titleLabel, spacer, modelButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false

        // --- Output ---
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.drawsBackground = false
        outputView.font = T.bodyFont
        outputView.textColor = T.text
        outputView.textContainerInset = NSSize(width: 12, height: 12)
        outputView.isVerticallyResizable = true
        outputView.isHorizontallyResizable = false
        outputView.textContainer?.widthTracksTextView = true
        outputView.insertionPointColor = T.machineTeal

        scrollView.documentView = outputView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // --- Empty state (centered) ---
        emptyTitle.font = NSFont.systemFont(ofSize: 26, weight: .semibold)
        emptyTitle.textColor = T.text
        emptyTitle.alignment = .center

        emptySubtitle.font = NSFont.systemFont(ofSize: 13)
        emptySubtitle.textColor = T.subtext
        emptySubtitle.alignment = .center

        let emptyStack = NSStackView(views: [emptyTitle, emptySubtitle])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 6
        emptyStack.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView.addSubview(emptyStack)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
        ])

        // --- Busy spinner ---
        busySpinner.style = .spinning
        busySpinner.controlSize = .small
        busySpinner.isDisplayedWhenStopped = false
        busySpinner.translatesAutoresizingMaskIntoConstraints = false

        // --- Input (rounded) ---
        let inputContainer = NSView()
        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 10
        inputContainer.layer?.backgroundColor = T.surface0.cgColor
        inputContainer.translatesAutoresizingMaskIntoConstraints = false

        inputField.placeholderString = "Ask the servitor…"
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
            inputField.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 12),
            inputField.trailingAnchor.constraint(equalTo: busySpinner.leadingAnchor, constant: -8),
            inputField.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            busySpinner.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -10),
            busySpinner.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            inputContainer.heightAnchor.constraint(equalToConstant: 40),
        ])

        // --- Assemble ---
        for v in [header, scrollView, emptyStateView, inputContainer] {
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            watermarkView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            watermarkView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            watermarkView.widthAnchor.constraint(equalToConstant: 260),
            watermarkView.heightAnchor.constraint(equalToConstant: 260),

            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -10),

            emptyStateView.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -10),

            inputContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            inputContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            inputContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Button actions

    @objc private func backTapped() {
        if let menu = onHistoryMenu?() {
            let p = NSPoint(x: 0, y: backButton.bounds.height + 2)
            menu.popUp(positioning: nil, at: p, in: backButton)
        }
    }
    @objc private func newTapped() { delegate?.chatPanelDidRequestNewChat(self) }
    @objc private func modelTapped() {
        if let menu = onModelMenu?() {
            let p = NSPoint(x: 0, y: modelButton.bounds.height + 2)
            menu.popUp(positioning: nil, at: p, in: modelButton)
        }
    }

    // MARK: - Public API

    func setModelLabel(_ text: String) { modelButton.title = text }

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

    // MARK: - Rendering

    func appendUser(_ text: String) {
        emptyStateView.isHidden = true
        outputView.textStorage?.append(label("OMNISSIAH", color: T.brass))
        outputView.textStorage?.append(NSAttributedString(string: "\n" + text + "\n\n", attributes: [
            .font: T.bodyFont, .foregroundColor: T.text
        ]))
        scrollToBottom()
    }

    func beginAssistant() {
        outputView.textStorage?.append(label("SERVITOR", color: T.machineTeal))
        outputView.textStorage?.append(NSAttributedString(string: "\n"))
        scrollToBottom()
    }

    func appendRawAssistant(_ delta: String) {
        outputView.textStorage?.append(NSAttributedString(string: delta, attributes: [
            .font: T.bodyFont, .foregroundColor: T.text
        ]))
        scrollToBottom()
    }

    func finishAssistant() {
        outputView.textStorage?.append(NSAttributedString(string: "\n\n"))
        scrollToBottom()
    }

    func clear() {
        outputView.textStorage?.setAttributedString(NSAttributedString())
        emptyStateView.isHidden = false
    }

    /// Show a plain notice line (hides the empty-state overlay).
    func showNotice(_ text: String) {
        emptyStateView.isHidden = true
        outputView.textStorage?.append(NSAttributedString(string: text + "\n\n", attributes: [
            .font: T.bodyFont, .foregroundColor: T.warning
        ]))
        scrollToBottom()
    }

    func render(messages: [ChatMessage]) {
        emptyStateView.isHidden = !messages.isEmpty
        let s = NSMutableAttributedString()
        for m in messages {
            if m.role == "user" {
                s.append(label("OMNISSIAH", color: T.brass))
                s.append(NSAttributedString(string: "\n" + m.text + "\n\n", attributes: [
                    .font: T.bodyFont, .foregroundColor: T.text
                ]))
            } else {
                s.append(label("SERVITOR", color: T.machineTeal))
                s.append(NSAttributedString(string: "\n" + m.text + "\n\n", attributes: [
                    .font: T.bodyFont, .foregroundColor: T.text
                ]))
            }
        }
        outputView.textStorage?.setAttributedString(s)
        scrollToBottom()
    }

    private func label(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: T.labelFont, .foregroundColor: color,
            .kern: 0.5,
        ])
    }

    private func scrollToBottom() {
        guard let storage = outputView.textStorage else { return }
        outputView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
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
}

extension ChatPanel: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        // Borderless panels need explicit focus management so typing always
        // lands in the input field.
        focusInput()
    }
}
