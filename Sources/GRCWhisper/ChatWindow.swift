import AppKit

/// A lightweight chat window, opened by the AI leader (hold hotkey + A). Your
/// dictated words become the first message; Claude's reply streams in, and you
/// can keep the conversation going by typing or dictating again. Text-only, uses
/// your own Claude API key — nothing here runs unless you opt into the AI action.
@MainActor
final class ChatWindowController: NSWindowController {
    private var config: Config
    private var messages: [[String: String]] = []
    private var busy = false

    private let transcriptStack = NSStackView()
    private let scroll = NSScrollView()
    private let inputField = NSTextField()
    private let sendButton = NSButton()

    private static let systemPrompt = """
    You are a helpful, friendly assistant living in a macOS dictation app. The \
    user is usually talking to you by voice, so their messages may contain \
    transcription quirks, run-ons, or homophones — interpret them charitably. \
    Keep replies conversational and reasonably concise unless asked for depth.
    """

    init(config: Config) {
        self.config = config
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "GRC Whisper — AI Chat"
        window.center()
        window.setFrameAutosaveName("GRCWhisperChat")
        window.minSize = NSSize(width: 380, height: 360)
        super.init(window: window)
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
    }

    /// Static sample transcript for the offscreen `chat-preview` design check.
    func previewSeed() {
        addBubble(role: "user", text: "What does Wispr Flow use for its AI?")
        addBubble(role: "assistant", text: "Wispr Flow does its transcription in the cloud — it streams your audio to their servers rather than running on-device. GRC Whisper is the opposite: everything here runs locally on your Mac, and only this AI chat reaches out (with your own key).")
        addBubble(role: "user", text: "Nice. Summarize that in one line.")
        addBubble(role: "assistant", text: "Wispr Flow = cloud transcription; GRC Whisper = fully on-device, cloud only for opt-in AI.")
    }

    /// Send text (from voice or typed) and stream the reply. Coalesces if busy.
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        addBubble(role: "user", text: t)
        messages.append(["role": "user", "content": t])

        guard let key = Keychain.get("claude"), !key.isEmpty else {
            _ = addBubble(role: "assistant", text: "Add a Claude API key in Settings ▸ Cloud cleanup to start chatting.")
            return
        }

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
                            bubble.setText(partial)
                            self.scrollToBottom()
                        }
                    })
                await MainActor.run {
                    bubble.setText(final)
                    self.messages.append(["role": "assistant", "content": final])
                    self.finishTurn()
                }
            } catch {
                await MainActor.run {
                    bubble.setError("⚠️ \(error.localizedDescription)")
                    // Drop the failed user turn so a retry doesn't double it up.
                    if self.messages.last?["role"] == "user" { self.messages.removeLast() }
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
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(sendFromField)

        let inputRow = NSStackView(views: [inputField, sendButton])
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
    }

    private func scrollToBottom() {
        // Defer so the just-added bubble is laid out before we measure.
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentView?.layoutSubtreeIfNeeded()
            self?.scroll.documentView?.scrollToEndOfDocument(nil)
        }
    }

    @objc private func sendFromField() {
        let text = inputField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputField.stringValue = ""
        send(text)
    }
}

/// A single chat message bubble: rounded, accent-filled for you, subtle-gray for
/// the assistant. Recolors itself when the window's light/dark theme changes.
final class BubbleView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let isUser: Bool
    private var isError = false

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
    func setError(_ s: String) { isError = true; label.stringValue = s; applyColors() }

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
