import Cocoa

/// Hold + Q — the hotkey cheat sheet. A floating, NON-ACTIVATING reference
/// card listing every leader chord, grouped by job, plus any user-assigned
/// Quick Capture leaders. Toggle with Q (or ✕); drag anywhere to move.
/// Same visual system as the pads so it reads as one family.
@MainActor
final class HotkeyCheatSheet {
    private var panel: NSPanel?
    var isVisible: Bool { panel != nil }

    func toggle(dark: Bool, screen: NSScreen, hotkeyName: String,
                connections: [(key: String, name: String)]) {
        if isVisible { dismiss(); return }
        let view = HotkeyCheatSheetView(dark: dark, hotkeyName: hotkeyName, connections: connections)
        view.onClose = { [weak self] in self?.dismiss() }
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        let win = NSPanel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view
        panel = win
        win.orderFrontRegardless()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class HotkeyCheatSheetView: NSView {
    var onClose: (() -> Void)?

    private let dark: Bool
    private let hotkeyName: String
    private let sections: [(title: String, rows: [(key: String, title: String)])]

    /// One place for the chord list — additions to HotkeyMonitor's leader
    /// switch belong here too (kept adjacent by convention, checked by eye).
    private static func buildSections(_ connections: [(key: String, name: String)])
        -> [(title: String, rows: [(key: String, title: String)])] {
        var s: [(String, [(String, String)])] = [
            ("Dictation", [
                ("hold", "dictate · insert on release"),
                ("A", "AI — command or rewrite"),
                ("esc", "cancel"),
            ]),
            ("Capture", [
                ("T", "screen text → clipboard"),
                ("S", "screenshot"),
                ("G", "screenshot → search"),
                ("R", "read screen aloud"),
                ("K", "color picker (hex)"),
                ("M", "find my mouse"),
            ]),
            ("Clipboard & files", [
                ("H", "clipboard history"),
                ("P", "paste as…"),
                ("C·X·V", "Finder copy / cut / paste"),
                ("D", "new document here"),
            ]),
            ("Windows", [
                ("←→↑↓", "snap · repeat to shrink"),
                ("⏎", "maximize"),
                ("3", "draw a grid to place"),
                ("W", "snap palette"),
            ]),
            ("Pads & panels", [
                ("B", "Macro Pad"),
                ("1…0", "fire macro button (pad open)"),
                ("J", "Agent Pad (Claude Code)"),
                ("r-click", "Power Ring"),
                ("Q", "this cheat sheet"),
            ]),
        ]
        if !connections.isEmpty {
            s.append(("Quick capture", connections.map { ($0.key.uppercased(), "→ \($0.name)") }))
        }
        return s
    }

    init(dark: Bool, hotkeyName: String, connections: [(key: String, name: String)]) {
        self.dark = dark
        self.hotkeyName = hotkeyName
        self.sections = Self.buildSections(connections)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let width: CGFloat = 300
    private static let pad: CGFloat = 14
    private static let headerH: CGFloat = 26
    private static let sectionH: CGFloat = 24
    private static let rowH: CGFloat = 19
    private static let keyW: CGFloat = 52

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    override var fittingSize: NSSize {
        let rows = sections.reduce(0) { $0 + $1.rows.count }
        let h = Self.pad + Self.headerH + CGFloat(sections.count) * Self.sectionH
            + CGFloat(rows) * Self.rowH + Self.pad
        return NSSize(width: Self.width, height: h)
    }

    private var closeRect: NSRect { NSRect(x: Self.width - Self.pad - 16, y: Self.pad - 2, width: 16, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).setClip()
        bg.setFill()
        bounds.fill()

        ("Hold \(hotkeyName) +" as NSString).draw(
            at: NSPoint(x: Self.pad, y: Self.pad - 1),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: fg])
        ("✕" as NSString).draw(in: closeRect.offsetBy(dx: 3, dy: 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: dim])

        var y = Self.pad + Self.headerH
        for section in sections {
            (section.title.uppercased() as NSString).draw(
                at: NSPoint(x: Self.pad, y: y + 8),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold),
                                 .foregroundColor: dim.withAlphaComponent(0.35)])
            y += Self.sectionH
            for row in section.rows {
                // Key chip, right-aligned in its column so titles line up.
                let chipAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: accent]
                let keySize = (row.key as NSString).size(withAttributes: chipAttrs)
                (row.key as NSString).draw(
                    at: NSPoint(x: Self.pad + Self.keyW - keySize.width, y: y + 2),
                    withAttributes: chipAttrs)
                (row.title as NSString).draw(
                    at: NSPoint(x: Self.pad + Self.keyW + 10, y: y + 2),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: fg.withAlphaComponent(0.85)])
                y += Self.rowH
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { onClose?(); return }
        window?.performDrag(with: event)
    }
}
