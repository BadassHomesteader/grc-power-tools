import Cocoa

/// The Power Ring's designable action catalog: stable ids (persisted in
/// config.powerRingSlots) → glyph + title. Nonisolated so Config can read the
/// defaults; the run closures are bound by id in AppController.ringRun.
enum PowerRingCatalog {
    struct Entry { let id: String; let glyph: String; let title: String }

    static let all: [Entry] = [
        .init(id: "screenText", glyph: "⌖", title: "Screen Text"),
        .init(id: "screenshot", glyph: "✂", title: "Screenshot"),
        .init(id: "search", glyph: "⌕", title: "Shot → Search"),
        .init(id: "whiteboard", glyph: "✐", title: "Annotate"),
        .init(id: "clipboard", glyph: "☰", title: "Clipboard"),
        .init(id: "pasteAs", glyph: "⎘", title: "Paste As"),
        .init(id: "readAloud", glyph: "▷", title: "Read Aloud"),
        .init(id: "color", glyph: "◉", title: "Color Picker"),
        .init(id: "findMouse", glyph: "✜", title: "Find Mouse"),
        .init(id: "newDoc", glyph: "✎", title: "New Doc"),
        .init(id: "grid", glyph: "▦", title: "Grid Place"),
        .init(id: "palette", glyph: "◫", title: "Snap Palette"),
        .init(id: "macroPad", glyph: "▤", title: "Macro Pad"),
        .init(id: "agentPad", glyph: "✱", title: "Agent Pad"),
        .init(id: "cheatSheet", glyph: "?", title: "Hotkeys"),
    ]

    static let defaultSlots = ["screenText", "screenshot", "clipboard", "pasteAs",
                               "agentPad", "macroPad", "color", "readAloud"]

    static func entry(_ id: String) -> Entry? { all.first { $0.id == id } }
}

/// Power Ring — radial menu on leader + right-click. Logi-Options-style
/// visuals (small circular buttons around a hub, always-visible label pills)
/// with Fusion-style hit zones: the full 45° sector around each button fires,
/// so a sloppy flick still lands. NON-ACTIVATING; either mouse button picks;
/// hub / click-away / Esc-free timeout dismisses.
@MainActor
final class PowerRing {
    struct Action {
        let glyph: String
        let title: String
        let run: () -> Void
    }

    private var panel: NSPanel?
    private var clickAway: Any?
    private var timeout: Timer?
    var isVisible: Bool { panel != nil }
    /// Fired on every show/hide (all dismissal paths) — the hotkey tap
    /// mirrors this so a plain Esc can close the ring.
    var onVisibility: ((Bool) -> Void)?

    func present(at point: NSPoint, dark: Bool, actions: [Action]) {
        dismiss()
        let view = PowerRingView(actions: Array(actions.prefix(8)), dark: dark)
        let size = PowerRingView.canvas
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let vf = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size.height - 4)
        }
        let win = NSPanel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false   // pills/buttons carry their own shadows; a window shadow would box the transparent canvas
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.frame = NSRect(origin: .zero, size: size)
        view.onPick = { [weak self] action in
            self?.dismiss()
            action.run()
        }
        view.onCancel = { [weak self] in self?.dismiss() }
        win.contentView = view
        panel = win
        win.orderFrontRegardless()
        // A click in any OTHER app dismisses, like a menu (a global monitor
        // never sees events aimed at our own windows).
        clickAway = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        // Don't leave an orphaned ring up if the user walks away.
        timeout = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        onVisibility?(true)
    }

    func dismiss() {
        timeout?.invalidate()
        timeout = nil
        if let clickAway { NSEvent.removeMonitor(clickAway) }
        clickAway = nil
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        onVisibility?(false)
    }
}

/// The ring canvas: 8 circular buttons around a small ✕ hub, each with an
/// always-visible label pill floated outward. The space between elements is
/// transparent — the screen shows through, unlike the old solid donut.
final class PowerRingView: NSView {
    static let canvas = NSSize(width: 520, height: 440)
    private static let btnR: CGFloat = 27       // button circle radius
    private static let ringR: CGFloat = 96      // button centers from hub
    private static let pillR: CGFloat = 172     // label pill centers from hub
    private static let hubR: CGFloat = 16
    private static let pickMaxR: CGFloat = 214  // sector hit zone outer edge

    var onPick: ((PowerRing.Action) -> Void)?
    var onCancel: (() -> Void)?

    private let actions: [PowerRing.Action]
    private let dark: Bool
    private var hovered: Int?

    init(actions: [PowerRing.Action], dark: Bool) {
        self.actions = actions
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }
    /// Logi look: near-black buttons with white glyphs in light mode; in dark
    /// mode the buttons lighten a touch so they separate from dark desktops.
    private var buttonColor: NSColor { dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.08, alpha: 1) }
    private var pillColor: NSColor { dark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.98) : .white }
    private var pillText: NSColor { dark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.85) }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    /// Slot 0 sits at 12 o'clock; indices run clockwise.
    private func slotAngle(_ i: Int) -> CGFloat { (90 - 45 * CGFloat(i)) * .pi / 180 }

    private func slotPoint(_ i: Int, radius: CGFloat) -> NSPoint {
        let a = slotAngle(i)
        return NSPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }

    /// nil = dead space; -1 = hub; 0…7 = slot. The WHOLE sector out to
    /// pickMaxR fires (Fusion-style), not just the circle.
    private func hitSlot(_ p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let dist = hypot(dx, dy)
        if dist < Self.hubR + 5 { return -1 }
        guard dist <= Self.pickMaxR else { return nil }
        let deg = atan2(dy, dx) * 180 / .pi
        let i = Int((((90 - deg) / 45).rounded()).truncatingRemainder(dividingBy: 8))
        let idx = (i + 8) % 8
        return idx < actions.count ? idx : nil
    }

    private func withShadow(_ draw: () -> Void) {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.18)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        draw()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, action) in actions.enumerated() {
            let isHover = i == hovered

            // Label pill — always visible (the discoverability win over the
            // old wedge text), floated outward past the button.
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: pillText]
            let ts = (action.title as NSString).size(withAttributes: titleAttrs)
            let pc = slotPoint(i, radius: Self.pillR)
            var pill = NSRect(x: pc.x - (ts.width + 26) / 2, y: pc.y - 15, width: ts.width + 26, height: 30)
            pill.origin.x = min(max(pill.minX, 4), bounds.width - pill.width - 4)
            pill.origin.y = min(max(pill.minY, 4), bounds.height - pill.height - 4)
            let pillPath = NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8)
            withShadow {
                pillColor.setFill()
                pillPath.fill()
            }
            if isHover {
                accent.setStroke()
                pillPath.lineWidth = 1.5
                pillPath.stroke()
            }
            (action.title as NSString).draw(
                at: NSPoint(x: pill.midX - ts.width / 2, y: pill.midY - ts.height / 2),
                withAttributes: titleAttrs)

            // Button circle — hovered grows a touch and lights accent.
            let r = Self.btnR + (isHover ? 3 : 0)
            let bc = slotPoint(i, radius: Self.ringR)
            let circle = NSBezierPath(ovalIn: NSRect(x: bc.x - r, y: bc.y - r, width: r * 2, height: r * 2))
            withShadow {
                (isHover ? accent : buttonColor).setFill()
                circle.fill()
            }
            let ga: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white]
            let gs = (action.glyph as NSString).size(withAttributes: ga)
            (action.glyph as NSString).draw(at: NSPoint(x: bc.x - gs.width / 2, y: bc.y - gs.height / 2),
                                            withAttributes: ga)
        }

        // Hub — small quiet ✕, like Logi's.
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - Self.hubR, y: center.y - Self.hubR,
                                              width: Self.hubR * 2, height: Self.hubR * 2))
        withShadow {
            (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            hub.fill()
        }
        let xa: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: dark ? NSColor.white.withAlphaComponent(0.7) : NSColor.black.withAlphaComponent(0.55)]
        let xs = ("✕" as NSString).size(withAttributes: xa)
        ("✕" as NSString).draw(at: NSPoint(x: center.x - xs.width / 2, y: center.y - xs.height / 2),
                               withAttributes: xa)
    }

    /// Preview hook (powerring-preview CLI) — set hover without a mouse.
    func previewState(hover: Int?) {
        hovered = hover
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let hit = hitSlot(convert(event.locationInWindow, from: nil))
        let newHover = (hit ?? -1) >= 0 ? hit : nil
        if newHover != hovered {
            hovered = newHover
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { fire(event) }
    override func rightMouseDown(with event: NSEvent) { fire(event) }

    private func fire(_ event: NSEvent) {
        switch hitSlot(convert(event.locationInWindow, from: nil)) {
        case .some(let i) where i >= 0: onPick?(actions[i])
        default: onCancel?()   // hub or the dead corners
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
}
