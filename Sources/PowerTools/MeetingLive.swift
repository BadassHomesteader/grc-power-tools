import AppKit
import FoundationModels

// Live meeting assist. While a meeting records, the transcript so far (plus
// your notes and the previous list) goes to the AI about once a minute and
// comes back as three short lists: action items, questions worth asking now, and
// decisions. Each refresh REPLACES the list, so nothing piles up or repeats.
// "Ask" answers a question from the transcript so far — during the call or after.
// Shown in the window's Live tab and in a floating panel that stays above the
// call window without taking focus.

enum MeetingLive {
    /// Seconds between automatic refreshes while recording.
    static var interval: TimeInterval = 60

    /// When the meeting has an agenda, the list leads with a checklist of it.
    static func instructions(hasAgenda: Bool) -> String {
        guard hasAgenda else { return instructions }
        return instructions.replacingOccurrences(of: "## Action items\n", with: """
        ## Agenda
        - ✓ <agenda topic> — <a few words on what was said>
        - ◐ <agenda topic> — <touched on; what's still open>
        - ○ <agenda topic>

        ## Action items

        """) + """

        Agenda: list EVERY topic from the AGENDA, in its order, worded short — ✓ when \
        it was clearly discussed, ◐ when only touched on, ○ when not yet. If the AGENDA \
        is a pasted invite or email, pull out just the topics.
        """
    }

    static let instructions = """
    You assist the user LIVE during a meeting. "Me" is the user; "Speaker 1/2/3…" are \
    other people in the room (told apart by voice — labels can be wrong); "Them" is \
    everyone on the call. From the transcript so far (and the user's notes), return \
    EXACTLY this Markdown and nothing else:

    ## Action items
    - <Owner> — <task> — <due, only if a time was actually said>

    ## Questions to ask
    - <a short question the user could ask right now>

    ## Decisions
    - <only things actually agreed>

    Rules: an action item is something a specific person committed to or was \
    asked to do — one item per person per task, the owner FIRST: the person's \
    name when anyone says it (e.g. "Dana"), otherwise "Me", "Speaker 2" or "Them" — or \
    "Unassigned" when something clearly needs doing but nobody took it. Leave the \
    due part off entirely unless a time was stated — never write "ASAP" or guess. \
    At most 8 action items, 3 questions, 5 decisions. Questions target what was \
    left vague, undecided, or missing (owners, dates, numbers, scope) — never \
    something already answered. Under a heading with nothing yet, write \
    "- (none yet)". If a PREVIOUS list is given, keep the wording of items that \
    still hold so the list stays stable; drop questions that have since been \
    answered. Never invent facts.
    """

    static func prompt(_ m: Meeting) -> String {
        let notes = MeetingImages.rewrite(m.notes) { _ in "[picture]" }.trimmingCharacters(in: .whitespacesAndNewlines)
        let agenda = m.agenda?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return """
        <AGENDA>
        \(agenda.isEmpty ? "(none)" : agenda)
        </AGENDA>
        <PREVIOUS>
        \(m.live?.isEmpty == false ? m.live! : "(none)")
        </PREVIOUS>
        <MY_NOTES>
        \(notes.isEmpty ? "(none)" : notes)
        </MY_NOTES>
        <TRANSCRIPT_SO_FAR>
        \(tail(MeetingText.plain(m), words: 6000))
        </TRANSCRIPT_SO_FAR>
        """
    }

    /// The last `words` words — long meetings keep the recent talk; the
    /// PREVIOUS list carries what was settled earlier.
    static func tail(_ text: String, words: Int) -> String {
        let w = text.split(separator: " ", omittingEmptySubsequences: false)
        guard w.count > words else { return text }
        return "…" + w.suffix(words).joined(separator: " ")
    }

    /// Claude → OpenAI → on-device (which only sees the last few minutes).
    static func complete(instructions: String, prompt: String, onDevicePrompt: () -> String,
                         config: Config) async throws -> String {
        if let key = Keychain.get("claude"), !key.isEmpty {
            return try await CloudPolish.claude(instructions: instructions, prompt: prompt, model: config.claudeModel,
                                                apiKey: key, maxTokens: 900, timeout: 45)
        }
        if let key = Keychain.get("openai"), !key.isEmpty {
            return try await CloudPolish.openai(instructions: instructions, prompt: prompt, model: config.openaiModel,
                                                apiKey: key, maxTokens: 900, timeout: 45)
        }
        guard Polisher.llmAvailable else {
            throw NSError(domain: "GRCWhisper", code: 24, userInfo: [NSLocalizedDescriptionKey:
                "Live needs AI — add a Claude or OpenAI key in Settings ▸ AI, or turn on Apple Intelligence"])
        }
        let s = LanguageModelSession(instructions: instructions)
        return try await s.respond(to: onDevicePrompt()).content
    }

    static func refresh(_ m: Meeting, config: Config) async throws -> String {
        let hasAgenda = !(m.agenda ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = try await complete(instructions: instructions(hasAgenda: hasAgenda), prompt: prompt(m), onDevicePrompt: {
            // Apple's model has a few-thousand-token window: last ~5 minutes only.
            var recent = m
            let latest = m.segments.map(\.start).max() ?? 0
            recent.segments = m.segments.filter { $0.start >= latest - 300 }
            return prompt(recent)
        }, config: config)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let askInstructions = """
    Answer the user's question about the meeting from the transcript (and their \
    notes). "Me" is the user; "Speaker N" are others in the room; "Them" is the call. One to three sentences, \
    plain text. If it wasn't discussed, say so briefly — never guess.
    """

    static func ask(_ question: String, _ m: Meeting, config: Config) async throws -> String {
        let notes = MeetingImages.rewrite(m.notes) { _ in "[picture]" }
        func p(_ transcript: String) -> String {
            "<MY_NOTES>\n\(notes.isEmpty ? "(none)" : notes)\n</MY_NOTES>\n<TRANSCRIPT>\n\(transcript)\n</TRANSCRIPT>\n\nQuestion: \(question)"
        }
        let full = MeetingText.plain(m)
        return try await complete(instructions: askInstructions, prompt: p(tail(full, words: 15000)),
                                  onDevicePrompt: { p(tail(full, words: 1500)) }, config: config)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Rendering

    struct Answer { let question: String; var answer: String? }

    /// Agenda lines as typed/pasted, cleaned of bullets and numbering — shown
    /// as all-open (○) until the first live refresh checks them off.
    static func agendaItems(_ agenda: String?) -> [String] {
        (agenda ?? "").components(separatedBy: .newlines).compactMap { raw in
            var t = raw.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^([-*•○◐✓]|\d+[.)]|\[[ xX]\])\s*"#, options: .regularExpression) { t.removeSubrange(r) }
            t = t.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.count > 140 ? nil : t
        }.prefix(20).map { $0 }
    }

    static func attributed(live: String?, answers: [Answer], agenda: String? = nil, cue: MeetingCoach.Cue? = nil) -> NSAttributedString {
        var live = live
        let hasAgendaSection = live?.range(of: #"(?m)^#+\s*Agenda"#, options: .regularExpression) != nil
        let items = agendaItems(agenda)
        if !hasAgendaSection, !items.isEmpty {
            live = "## Agenda\n" + items.map { "- ○ \($0)" }.joined(separator: "\n") + "\n\n" + (live ?? "")
        }
        let out = NSMutableAttributedString()
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                   .foregroundColor: NSColor.secondaryLabelColor]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: NSColor.textColor]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: NSColor.tertiaryLabelColor]
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .foregroundColor: NSColor.textColor]
        func heading(_ s: String) {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = out.length > 0 ? 12 : 0
            para.paragraphSpacing = 4
            var a = head
            a[.paragraphStyle] = para
            out.append(NSAttributedString(string: s.uppercased() + "\n", attributes: a))
        }
        func bullet(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            let para = NSMutableParagraphStyle()
            para.headIndent = 16
            para.paragraphSpacing = 3
            para.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
            var a = attrs
            a[.paragraphStyle] = para
            // Agenda checkmarks replace the bullet: ✓ covered · ◐ partly · ○ not yet.
            var mark = "•", text = s, markColor: NSColor?
            for (m, c) in [("✓", NSColor.systemGreen), ("◐", NSColor.systemOrange), ("○", NSColor.tertiaryLabelColor)]
                where s.hasPrefix(m) {
                mark = m; markColor = c
                text = String(s.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
            }
            let start = out.length
            out.append(NSAttributedString(string: mark + "\t" + text + "\n", attributes: a))
            if let markColor {
                out.addAttributes([.foregroundColor: markColor, .font: NSFont.systemFont(ofSize: 13.5, weight: .bold)],
                                  range: NSRange(location: start, length: (mark as NSString).length))
                if mark == "○" { out.addAttribute(.foregroundColor, value: NSColor.textColor,
                                                   range: NSRange(location: start + 2, length: (text as NSString).length)) }
            }
        }
        // The coach's latest cue sits on top: one move, one sentence, why.
        if let cue {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 4
            var h = head
            h[.foregroundColor] = NSColor.systemOrange
            h[.paragraphStyle] = para
            let age = Int(Date().timeIntervalSince(cue.at))
            let when = age < 60 ? "just now" : "\(age / 60) min ago"
            out.append(NSAttributedString(string: "COACH · \(when)\n", attributes: h))
            var c = bold
            c[.paragraphStyle] = para
            out.append(NSAttributedString(string: cue.cue + "\n", attributes: c))
            if let say = cue.say {
                var s = body
                s[.font] = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13.5), toHaveTrait: .italicFontMask)
                s[.paragraphStyle] = para
                out.append(NSAttributedString(string: "“\(say)”\n", attributes: s))
            }
            if let reason = cue.reason {
                var r = dim
                r[.font] = NSFont.systemFont(ofSize: 12)
                out.append(NSAttributedString(string: reason + "\n", attributes: r))
            }
        }
        var ownerFirst = false  // under "Action items" (or the older "Next steps")
        for raw in (live ?? "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                ownerFirst = title.lowercased().contains("action") || title.lowercased().contains("next step")
                heading(title)
                continue
            }
            var item = line
            for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where item.hasPrefix(prefix) {
                item = String(item.dropFirst(prefix.count)); break
            }
            if item.hasPrefix("(none") { bullet(item, dim); continue }
            if ownerFirst, let dash = item.range(of: " — ") {
                // "Dana — call about gutters — tomorrow": the owner in bold.
                let start = out.length
                bullet(item, body)
                let ownerLen = (String(item[..<dash.lowerBound]) as NSString).length
                out.addAttributes(bold.filter { $0.key == .font },
                                  range: NSRange(location: start + 2, length: ownerLen))
                continue
            }
            bullet(item, body)
        }
        if !answers.isEmpty {
            heading("Answers")
            for a in answers.reversed() {
                let para = NSMutableParagraphStyle()
                para.paragraphSpacing = 2
                var q = bold
                q[.paragraphStyle] = para
                out.append(NSAttributedString(string: a.question + "\n", attributes: q))
                let p2 = NSMutableParagraphStyle()
                p2.paragraphSpacing = 10
                var b = a.answer == nil ? dim : body
                b[.paragraphStyle] = p2
                out.append(NSAttributedString(string: (a.answer ?? "Thinking…") + "\n", attributes: b))
            }
        }
        return out
    }
}

// MARK: - Floating panel

/// Small always-on-top panel beside the call: the live lists plus an Ask box.
/// Non-activating, so clicking it doesn't pull focus from Teams/Zoom — only the
/// Ask field takes the keyboard, and only while you're typing in it.
@MainActor
final class MeetingLivePanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let panel: NSPanel
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 330, height: 380))
    private let askField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    var onAsk: ((String) -> Void)?
    var onRefresh: (() -> Void)?
    /// Coach on/off from the panel (MeetingCoach).
    var onCoachToggle: (() -> Void)?
    private let coachButton = NSButton()
    /// Fired when the user closes it with ✕ (hide() doesn't fire it).
    var onUserClose: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init(dark: Bool) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Live"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 260, height: 240)
        panel.delegate = self
        panel.setFrameAutosaveName("GRCWhisperLivePanel")
        setDark(dark)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 330, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        askField.placeholderString = "Ask about this meeting…"
        askField.bezelStyle = .roundedBezel
        askField.target = self
        askField.action = #selector(askSubmitted)
        let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh now")!,
                               target: self, action: #selector(refreshClicked))
        refresh.bezelStyle = .texturedRounded
        refresh.isBordered = false
        refresh.toolTip = "Refresh now"
        coachButton.image = NSImage(systemSymbolName: "person.wave.2", accessibilityDescription: "Coach")
        coachButton.bezelStyle = .texturedRounded
        coachButton.isBordered = false
        coachButton.target = self
        coachButton.action = #selector(coachClicked)
        setCoach(MeetingCoach.enabled)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        // Paint our own ground so the panel reads the same in every appearance.
        let content = panel.contentView!
        let ground = NSBox()
        ground.boxType = .custom
        ground.borderWidth = 0
        ground.fillColor = .windowBackgroundColor
        ground.frame = content.bounds
        ground.autoresizingMask = [.width, .height]
        content.addSubview(ground)
        for v in [scroll, askField, refresh, coachButton, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: askField.topAnchor, constant: -8),
            askField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            askField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            askField.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: askField.leadingAnchor, constant: 2),
            status.trailingAnchor.constraint(equalTo: coachButton.leadingAnchor, constant: -6),
            coachButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            coachButton.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -6),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            refresh.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            refresh.trailingAnchor.constraint(equalTo: askField.trailingAnchor),
        ])
    }

    func setDark(_ dark: Bool) { panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }

    /// First show goes to the top-right of the screen (beside a call window);
    /// after that the autosaved frame wins.
    func show() {
        if !panel.isVisible, UserDefaults.standard.string(forKey: "NSWindow Frame GRCWhisperLivePanel") == nil,
           let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 16, y: vf.maxY - panel.frame.height - 16))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    func update(title: String, content: NSAttributedString, status text: String) {
        panel.title = "Live — " + title
        textView.textStorage?.setAttributedString(content.length > 0 ? content : NSAttributedString(
            string: "Action items, questions to ask, and decisions show up here about once a minute while the meeting records.",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]))
        status.stringValue = text
    }

    @objc private func askSubmitted() {
        let q = askField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askField.stringValue = ""
        onAsk?(q)
    }

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func coachClicked() { onCoachToggle?() }

    /// Orange while the coach listens; dim when it's off.
    func setCoach(_ on: Bool) {
        coachButton.contentTintColor = on ? .systemOrange : .tertiaryLabelColor
        coachButton.toolTip = on ? "Coach is on — click to turn it off" : "Coach is off — click for private cues during the conversation"
    }

    func windowWillClose(_ notification: Notification) {
        onUserClose?()
    }

    /// Offscreen render for `meeting-preview … livepanel`.
    func snapshot() -> NSBitmapImageRep? {
        guard let content = panel.contentView else { return nil }
        panel.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep
    }
}
