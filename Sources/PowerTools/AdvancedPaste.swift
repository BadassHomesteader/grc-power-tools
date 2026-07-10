import Cocoa

/// Advanced Paste: hold hotkey + P → a palette of ways to transform whatever's on
/// the clipboard before pasting it — plain text, or AI transforms (summarize,
/// rewrite, markdown, translate…) via your Claude key. Reuses the app's paste path.
@MainActor
final class AdvancedPaste {
    private var window: NSWindow?
    private var keyMonitor: Any?

    struct Transform {
        let digit: Int
        let title: String
        let subtitle: String
        let ai: Bool
        let instruction: String?  // Claude system prompt for AI transforms
        var localTransform: ((String) -> String)? = nil  // instant, offline case/text transforms
    }

    static let transforms: [Transform] = [
        Transform(digit: 1, title: "Plain text", subtitle: "strip all formatting", ai: false, instruction: nil),
        Transform(digit: 2, title: "Clean text", subtitle: "trim, collapse spaces, straighten quotes", ai: false, instruction: nil,
                  localTransform: { TextOps.clean($0) }),
        Transform(digit: 3, title: "Single line", subtitle: "flatten line breaks into one line", ai: false, instruction: nil,
                  localTransform: { TextOps.singleLine($0) }),
        Transform(digit: 4, title: "Proper Case", subtitle: "Capitalize Each Word", ai: false, instruction: nil,
                  localTransform: { $0.capitalized }),
        Transform(digit: 5, title: "Sentence case", subtitle: "Capitalize each sentence", ai: false, instruction: nil,
                  localTransform: { TextOps.sentenceCase($0) }),
        Transform(digit: 6, title: "lowercase", subtitle: "all lower", ai: false, instruction: nil,
                  localTransform: { $0.lowercased() }),
        Transform(digit: 7, title: "UPPERCASE", subtitle: "all caps", ai: false, instruction: nil,
                  localTransform: { $0.uppercased() }),
        Transform(digit: 8, title: "Numbers only", subtitle: "strip $ , % — paste as values", ai: false, instruction: nil,
                  localTransform: { TextOps.numbersOnly($0) }),
        Transform(digit: 9, title: "Summarize", subtitle: "AI · the key points", ai: true,
                  instruction: "Summarize the following text concisely. Output only the summary."),
        Transform(digit: 10, title: "Rewrite", subtitle: "AI · fix grammar, tighten", ai: true,
                  instruction: "Rewrite the following to fix grammar and make it clear and concise, keeping the meaning and tone. Output only the rewrite."),
        Transform(digit: 11, title: "Bullet points", subtitle: "AI · as a list", ai: true,
                  instruction: "Rewrite the following as a concise bulleted list using '- '. Output only the list."),
        Transform(digit: 12, title: "Markdown", subtitle: "AI · clean markdown", ai: true,
                  instruction: "Reformat the following as clean, well-structured Markdown. Output only the Markdown."),
        Transform(digit: 13, title: "Translate → English", subtitle: "AI", ai: true,
                  instruction: "Translate the following into natural English. If it's already English, correct it lightly. Output only the translation."),
    ]

    func present(clipboard: String, dark: Bool, screen: NSScreen,
                 onPick: @escaping (Transform) -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        let view = AdvancedPasteView(clipboard: clipboard, dark: dark)
        let size = view.fittingSize
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        let win = KeyableWindow(contentRect: NSRect(origin: origin, size: size),
                                styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.frame = NSRect(origin: .zero, size: size)
        view.onPick = { [weak self] t in self?.dismiss(); onPick(t) }
        view.onCancel = { [weak self] in self?.dismiss(); onCancel() }
        win.contentView = view
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)

        // Bulletproof key handling: a borderless window doesn't always hold key
        // focus, so a local monitor catches Esc / digits / arrows regardless.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
            guard let self, self.window != nil, let view else { return event }
            return view.handleKey(event) ? nil : event
        }
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
    }
}

/// Instant, offline text transforms for the Advanced Paste palette. No network,
/// no AI — pure string work applied to whatever's on the clipboard.
enum TextOps {
    /// "Paste values" for text: straighten smart quotes/dashes, collapse runs of
    /// spaces/tabs within each line, trim each line, and drop blank lines.
    static func clean(_ s: String) -> String {
        let straightened = s
            .replacingOccurrences(of: "\u{201C}", with: "\"")   // “
            .replacingOccurrences(of: "\u{201D}", with: "\"")   // ”
            .replacingOccurrences(of: "\u{2018}", with: "'")    // ‘
            .replacingOccurrences(of: "\u{2019}", with: "'")    // ’
            .replacingOccurrences(of: "\u{2013}", with: "-")    // en dash
            .replacingOccurrences(of: "\u{2014}", with: "-")    // em dash
        return straightened
            .components(separatedBy: .newlines)
            .map { (line: String) in line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Flatten every line break into a single line — for search boxes, URL bars,
    /// spreadsheet cells. Trims each line and drops empties so it reads clean.
    static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Spreadsheet "paste values" for figures: strip currency symbols, thousands
    /// commas, and % per line so numbers land as numbers, not text. Keeps tabs,
    /// so a copied cell range stays a range.
    static func numbersOnly(_ s: String) -> String {
        let strip = CharacterSet(charactersIn: "$€£¥,%")
        return s.components(separatedBy: .newlines).map { line in
            String(line.unicodeScalars.filter { !strip.contains($0) })
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// Lowercase everything, then capitalize the first letter of the text and of
    /// each sentence (after . ! ?). Fixes ALL-CAPS or shouty notes.
    static func sentenceCase(_ s: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in s.lowercased() {
            if capitalizeNext, ch.isLetter {
                result += ch.uppercased()
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." || ch == "!" || ch == "?" { capitalizeNext = true }
            }
        }
        return result
    }
}

final class AdvancedPasteView: NSView {
    private let clipboard: String
    private let dark: Bool
    var onPick: ((AdvancedPaste.Transform) -> Void)?
    var onCancel: (() -> Void)?

    private var highlighted = 0
    private let rows = AdvancedPaste.transforms
    private static let width: CGFloat = 440
    private static let rowH: CGFloat = 46
    private static let headerH: CGFloat = 58
    private static let footerH: CGFloat = 30

    init(clipboard: String, dark: Bool) {
        self.clipboard = clipboard
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: Self.headerH + CGFloat(rows.count) * Self.rowH + Self.footerH)
    }

    // Palette colors.
    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 8, y: Self.headerH + CGFloat(i) * Self.rowH, width: bounds.width - 16, height: Self.rowH - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).setClip()
        bg.setFill(); bounds.fill()

        // Header: title + clipboard preview.
        ("Paste as…" as NSString).draw(at: NSPoint(x: 20, y: 14),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: fg])
        let preview = clipboard.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        (preview as NSString).draw(in: NSRect(x: 20, y: 34, width: bounds.width - 40, height: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim,
                             .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }()])

        for (i, t) in rows.enumerated() {
            let r = rowRect(i)
            if i == highlighted {
                accent.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
            }
            let onAccent = (i == highlighted)
            let titleColor = onAccent ? NSColor.white : fg
            let subColor = onAccent ? NSColor.white.withAlphaComponent(0.8) : dim
            // digit badge
            let badge = NSRect(x: r.minX + 10, y: r.midY - 11, width: 22, height: 22)
            (onAccent ? NSColor.white.withAlphaComponent(0.25) : (dark ? NSColor.white : .black).withAlphaComponent(0.1)).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            ("\(t.digit)" as NSString).draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 3),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: titleColor])
            // title + subtitle
            (t.title as NSString).draw(at: NSPoint(x: r.minX + 44, y: r.minY + 7),
                withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: titleColor])
            (t.subtitle as NSString).draw(at: NSPoint(x: r.minX + 44, y: r.minY + 25),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: subColor])
        }

        let footer = "1–\(min(rows.count, 9)) or click  ·  ↑↓ ↵  ·  esc" as NSString
        footer.draw(at: NSPoint(x: 20, y: bounds.height - 22),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim])
    }

    override func mouseMoved(with event: NSEvent) { updateHighlight(convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rows.indices.first(where: { rowRect($0).contains(p) }) { onPick?(rows[i]) }
        else { onCancel?() }
    }
    private func updateHighlight(_ p: NSPoint) {
        if let i = rows.indices.first(where: { rowRect($0).contains(p) }), i != highlighted { highlighted = i; needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) { if !handleKey(event) { super.keyDown(with: event) } }

    /// Returns true if the key was consumed. Called from keyDown AND the controller's
    /// local event monitor (so Esc works even if this view isn't first responder).
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: onCancel?(); return true                                   // esc
        case 36, 76: onPick?(rows[highlighted]); return true               // return / enter
        case 125: highlighted = min(highlighted + 1, rows.count - 1); needsDisplay = true; return true  // down
        case 126: highlighted = max(highlighted - 1, 0); needsDisplay = true; return true               // up
        default:
            if let ch = event.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= rows.count {
                onPick?(rows[n - 1]); return true
            }
            return false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}
