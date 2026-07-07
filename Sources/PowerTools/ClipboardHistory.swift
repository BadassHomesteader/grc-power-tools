import Cocoa

/// Clipboard history — the Windows Win+V gap. A lightweight watcher records text
/// copies into SQLite; hold hotkey + H opens a palette of recent clips, pick one
/// and it pastes into the app you came from (and becomes the current clipboard).
///
/// Privacy rules: items marked `org.nspasteboard.ConcealedType` (password
/// managers) or `org.nspasteboard.TransientType`, and our own clipboard-swap
/// writes (session-tagged + concealed), are never recorded.
@MainActor
final class ClipboardHistory {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let maxChars = 100_000

    private let store: Store
    private var timer: Timer?
    private var lastChangeCount: Int
    var enabled: Bool

    init(store: Store, enabled: Bool) {
        self.store = store
        self.enabled = enabled
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer?.invalidate()
        // Poll changeCount — the standard technique; there is no pasteboard
        // notification API. A no-change poll is two integer reads.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard enabled else { return }
        guard let items = pb.pasteboardItems,
              !items.contains(where: { $0.types.contains(Self.concealed) || $0.types.contains(Self.transient) })
        else { return }
        guard let text = pb.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.count <= Self.maxChars else { return }
        store.addClip(text)
    }
}

/// The hold + H palette: recent clips, digits/arrows to pick, Esc to close.
@MainActor
final class ClipboardPalette {
    private var window: NSWindow?
    private var keyMonitor: Any?

    var isVisible: Bool { window != nil }

    func present(clips: [ClipEntry], dark: Bool, screen: NSScreen,
                 onPick: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        let view = ClipboardPaletteView(clips: clips, dark: dark)
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
        view.onPick = { [weak self] text in self?.dismiss(); onPick(text) }
        view.onCancel = { [weak self] in self?.dismiss(); onCancel() }
        win.contentView = view
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)

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

final class ClipboardPaletteView: NSView {
    private let clips: [ClipEntry]
    private let dark: Bool
    var onPick: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var highlighted = 0
    private static let width: CGFloat = 480
    private static let rowH: CGFloat = 44
    private static let headerH: CGFloat = 40
    private static let footerH: CGFloat = 28

    init(clips: [ClipEntry], dark: Bool) {
        self.clips = clips
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: Self.headerH + CGFloat(clips.count) * Self.rowH + Self.footerH)
    }

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 8, y: Self.headerH + CGFloat(i) * Self.rowH, width: bounds.width - 16, height: Self.rowH - 4)
    }

    /// "3m ago" style stamp from the stored ISO timestamp.
    private func age(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).setClip()
        bg.setFill()
        bounds.fill()

        ("Clipboard history" as NSString).draw(at: NSPoint(x: 20, y: 12),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: fg])

        for (i, clip) in clips.enumerated() {
            let r = rowRect(i)
            if i == highlighted {
                accent.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
            }
            let onAccent = (i == highlighted)
            let titleColor = onAccent ? NSColor.white : fg
            let subColor = onAccent ? NSColor.white.withAlphaComponent(0.8) : dim

            let badge = NSRect(x: r.minX + 10, y: r.midY - 11, width: 22, height: 22)
            (onAccent ? NSColor.white.withAlphaComponent(0.25) : (dark ? NSColor.white : .black).withAlphaComponent(0.1)).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            ("\(i + 1)" as NSString).draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 3),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: titleColor])

            let firstLine = clip.content
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            (firstLine as NSString).draw(in: NSRect(x: r.minX + 44, y: r.minY + 6, width: r.width - 56, height: 18),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: titleColor,
                                 .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }()])
            let lines = clip.content.filter { $0 == "\n" }.count + 1
            let meta = lines > 1 ? "\(age(clip.timestamp)) · \(lines) lines" : "\(age(clip.timestamp)) · \(clip.content.count) chars"
            (meta as NSString).draw(at: NSPoint(x: r.minX + 44, y: r.minY + 24),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: subColor])
        }

        let footer = "1–\(clips.count) or click · ↵ paste · esc" as NSString
        footer.draw(at: NSPoint(x: 20, y: bounds.height - 21),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim])
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = clips.indices.first(where: { rowRect($0).contains(p) }), i != highlighted {
            highlighted = i
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = clips.indices.first(where: { rowRect($0).contains(p) }) { onPick?(clips[i].content) }
        else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: onCancel?(); return true
        case 36, 76: onPick?(clips[highlighted].content); return true
        case 125: highlighted = min(highlighted + 1, clips.count - 1); needsDisplay = true; return true
        case 126: highlighted = max(highlighted - 1, 0); needsDisplay = true; return true
        default:
            if let ch = event.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= clips.count {
                onPick?(clips[n - 1].content)
                return true
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
