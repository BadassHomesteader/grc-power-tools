import AppKit

/// A lightweight chat window, opened by the AI leader (hold hotkey + A). Your
/// dictated words become the first message; Claude's reply streams in, and you
/// can keep the conversation going by typing or dictating again. Text-only, uses
/// your own Claude API key — nothing here runs unless you opt into the AI action.
/// Esc closes the chat window (instead of ringing the bell / doing nothing).
/// Closing just hides it — Power Tools keeps running; reopening restores the chat.
final class ChatWindowPanel: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

@MainActor
final class ChatWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private var config: Config
    private var messages: [[String: String]] = []
    private var busy = false
    private var queue: [String] = []

    private let transcriptStack = NSStackView()
    private let scroll = NSScrollView()
    private let inputField = NSTextField()
    private let sendButton = NSButton()
    private let browserButton = NSButton()
    private var lastUserText = ""

    private static let systemPrompt = """
    You are a helpful, friendly assistant living in a macOS dictation app. The \
    user is usually talking to you by voice, so their messages may contain \
    transcription quirks, run-ons, or homophones — interpret them charitably. \
    Keep replies conversational and reasonably concise unless asked for depth.
    """

    init(config: Config) {
        self.config = config
        let window = ChatWindowPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Power Tools — AI Chat"
        window.center()
        window.setFrameAutosaveName("GRCWhisperChat")
        window.minSize = NSSize(width: 380, height: 360)
        window.isReleasedWhenClosed = false  // closing hides it; the chat persists
        super.init(window: window)
        window.delegate = self
        buildUI()
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(inputField)
        scrollToBottom()
    }

    func updateConfig(_ c: Config) {
        config = c
        applyAppearance()
        browserButton.isHidden = config.aiChatMode != .both
    }

    @objc private func openInBrowser() {
        ClaudeWeb.open(lastUserText)
    }

    /// Static sample transcript for the offscreen `chat-preview` design check.
    func previewSeed() {
        addBubble(role: "user", text: "What can Power Tools do?")
        addBubble(role: "assistant", text: "Hold Option+Shift and you get a whole toolbox: dictate into any app, snap and tile windows, OCR the screen, transform your clipboard, and more. The core tools run on-device — this AI chat is the one part that reaches out, with your own key.")
        addBubble(role: "user", text: "Nice. Summarize that in one line.")
        addBubble(role: "assistant", text: "One hotkey, many tools — local by default, cloud only for opt-in AI.")
    }

    /// Send text (from voice or typed). If a reply is already streaming, the new
    /// message is QUEUED (not dropped) and sent when the current turn finishes.
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if busy { queue.append(t); return }
        process(t)
    }

    private func drainQueue() {
        guard !busy, !queue.isEmpty else { return }
        process(queue.removeFirst())
    }

    private func process(_ t: String) {
        lastUserText = t
        let userBubble = addBubble(role: "user", text: t)

        guard let key = Keychain.get("claude"), !key.isEmpty else {
            // Show the message but DON'T add it to history — nothing was sent, so
            // committing it would leave two consecutive user turns (API rejects that).
            _ = addBubble(role: "assistant", text: "Add a Claude API key in Settings ▸ AI to start chatting.")
            drainQueue()
            return
        }
        messages.append(["role": "user", "content": t])

        busy = true
        sendButton.isEnabled = false
        let bubble = addBubble(role: "assistant", text: "…")
        let convo = messages
        let model = config.claudeModel

        Task {
            do {
                let final = try await CloudPolish.claudeChatStream(
                    messages: convo, system: Self.systemPrompt, model: model, apiKey: key,
                    onUpdate: { partial in
                        Task { @MainActor in
                            bubble.setStreaming(partial)   // ignored once finalized
                            self.scrollToBottom()
                        }
                    })
                await MainActor.run {
                    bubble.setFinal(final)                 // authoritative; blocks late partials
                    self.messages.append(["role": "assistant", "content": final])
                    self.finishTurn()
                }
            } catch {
                await MainActor.run {
                    // Roll the failed turn back so the visible transcript matches the
                    // history we send to the API (both drop it); put the text back so
                    // it isn't lost.
                    if self.messages.last?["role"] == "user" { self.messages.removeLast() }
                    userBubble.superview?.removeFromSuperview()
                    bubble.setError("⚠️ \(error.localizedDescription) — your message is back in the box.")
                    if self.inputField.stringValue.isEmpty { self.inputField.stringValue = t }
                    self.finishTurn()
                }
            }
        }
    }

    // MARK: Build

    private func buildUI() {
        transcriptStack.orientation = .vertical
        transcriptStack.alignment = .leading
        transcriptStack.spacing = 10
        transcriptStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(transcriptStack)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            transcriptStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 14),
            transcriptStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 14),
            transcriptStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -14),
            transcriptStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -14),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        inputField.placeholderString = "Message… (or hold your hotkey + A to talk)"
        inputField.font = .systemFont(ofSize: 13)
        inputField.target = self
        inputField.action = #selector(sendFromField)
        inputField.delegate = self
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendFromField)

        browserButton.title = "claude.ai ↗"
        browserButton.bezelStyle = .rounded
        browserButton.target = self
        browserButton.action = #selector(openInBrowser)
        browserButton.toolTip = "Continue this in claude.ai"
        browserButton.isHidden = config.aiChatMode != .both

        let inputRow = NSStackView(views: [inputField, browserButton, sendButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        inputRow.alignment = .centerY
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(inputRow)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: inputRow.topAnchor, constant: -10),
            inputRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            inputRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            inputRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        window?.contentView = container
    }

    private func applyAppearance() {
        window?.appearance = NSAppearance(named: config.appearance.isDark ? .darkAqua : .aqua)
    }

    // MARK: Bubbles

    @discardableResult
    private func addBubble(role: String, text: String) -> BubbleView {
        let bubble = BubbleView(role: role)
        bubble.setText(text)
        bubble.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.86),
        ])
        if role == "user" {
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        } else {
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
        }
        transcriptStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: transcriptStack.widthAnchor).isActive = true
        scrollToBottom()
        return bubble
    }

    private func finishTurn() {
        busy = false
        sendButton.isEnabled = true
        drainQueue()
    }

    private func scrollToBottom() {
        // Defer so the just-added bubble is laid out before we measure.
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.scroll.documentView else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            // The document view is a plain (flipped) NSView, so it does NOT respond
            // to scrollToEndOfDocument: — scroll the clip view to the bottom directly.
            let clip = self.scroll.contentView
            let y = max(0, doc.bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: y))
            self.scroll.reflectScrolledClipView(clip)
        }
    }

    @objc private func sendFromField() {
        let text = inputField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputField.stringValue = ""
        send(text)
    }

    /// When the chat closes, return to whatever app you were using instead of
    /// surfacing the Settings window that sits behind it.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.hide(nil) }
    }

    /// Esc while typing closes the chat (the field editor swallows the key otherwise).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            window?.performClose(nil)
            return true
        }
        return false
    }
}

/// A single chat message bubble: rounded, accent-filled for you, subtle-gray for
/// the assistant. Recolors itself when the window's light/dark theme changes.
final class BubbleView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let isUser: Bool
    private var isError = false
    private var finalized = false

    init(role: String) {
        isUser = role == "user"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 380
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setText(_ s: String) { isError = false; label.stringValue = s; applyColors() }

    /// Live streaming update — ignored once finalized, and only grows (so an
    /// out-of-order partial can't make the text jump backwards).
    func setStreaming(_ s: String) {
        guard !finalized else { return }
        guard s.count >= label.stringValue.count || label.stringValue == "…" else { return }
        isError = false
        label.stringValue = s
        applyColors()
    }

    /// Authoritative final text — locks the bubble so a late partial can't clobber it.
    func setFinal(_ s: String) {
        finalized = true
        isError = false
        label.stringValue = s
        applyColors()
    }

    func setError(_ s: String) {
        finalized = true
        isError = true
        label.stringValue = s
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        let bg: NSColor = isUser ? .controlAccentColor
            : (isError ? NSColor.systemRed.withAlphaComponent(0.18)
                       : NSColor.systemGray.withAlphaComponent(0.22))
        label.textColor = isUser ? .white : (isError ? .systemRed : .labelColor)
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = bg.cgColor
        }
    }
}

/// Top-anchored document view so the transcript grows downward and scrolls to the newest line.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Opens claude.ai in the default browser, pre-filling the message when possible.
enum ClaudeWeb {
    static func open(_ text: String) {
        var comps = URLComponents(string: "https://claude.ai/new")!
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { comps.queryItems = [URLQueryItem(name: "q", value: t)] }
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}
