import Cocoa

/// Power Ring — a Fusion-360-style radial menu on leader + right-click: eight
/// sectors around the cursor, hover highlights, click (either button) fires.
/// NON-ACTIVATING, so the fired action lands on the app that was in front.
/// Click the center (or anywhere outside, or wait 8s) to dismiss.
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
        win.hasShadow = true
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
    }

    func dismiss() {
        timeout?.invalidate()
        timeout = nil
        if let clickAway { NSEvent.removeMonitor(clickAway) }
        clickAway = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// The ring canvas: a donut of up to 8 wedges, glyph + short title per wedge,
/// hovered wedge lit accent, center shows the hovered action's full title.
final class PowerRingView: NSView {
    static let canvas = NSSize(width: 300, height: 300)
    private static let outerR: CGFloat = 140
    private static let innerR: CGFloat = 46

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

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    /// Sector 0 sits at 12 o'clock; indices run clockwise (Fusion muscle
    /// memory: up, up-right, right, …).
    private func sectorMidAngle(_ i: Int) -> CGFloat { 90 - 45 * CGFloat(i) }

    private func sectorPath(_ i: Int) -> NSBezierPath {
        let mid = sectorMidAngle(i)
        let a0 = mid - 21.5, a1 = mid + 21.5   // 1° gap either side = wedge separation
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: Self.outerR, startAngle: a0, endAngle: a1)
        p.appendArc(withCenter: center, radius: Self.innerR, startAngle: a1, endAngle: a0, clockwise: true)
        p.close()
        return p
    }

    /// nil = outside the donut; -1 = center hub; 0…7 = wedge.
    private func hitSector(_ p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let dist = hypot(dx, dy)
        if dist < Self.innerR { return -1 }
        guard dist <= Self.outerR else { return nil }
        let deg = atan2(dy, dx) * 180 / .pi
        let i = Int((((90 - deg) / 45).rounded()).truncatingRemainder(dividingBy: 8))
        let idx = (i + 8) % 8
        return idx < actions.count ? idx : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, action) in actions.enumerated() {
            let path = sectorPath(i)
            (i == hovered ? accent.withAlphaComponent(0.9) : bg).setFill()
            path.fill()
            let mid = sectorMidAngle(i) * .pi / 180
            let r = (Self.outerR + Self.innerR) / 2 + 2
            let cx = center.x + r * cos(mid), cy = center.y + r * sin(mid)
            let glyphColor: NSColor = i == hovered ? .white : fg.withAlphaComponent(0.9)
            let glyph = action.glyph as NSString
            let ga: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: glyphColor]
            let gs = glyph.size(withAttributes: ga)
            glyph.draw(at: NSPoint(x: cx - gs.width / 2, y: cy - gs.height / 2 + 7), withAttributes: ga)
            let title = action.title as NSString
            let ta: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: i == hovered ? NSColor.white.withAlphaComponent(0.9) : dim]
            let ts = title.size(withAttributes: ta)
            title.draw(at: NSPoint(x: cx - ts.width / 2, y: cy - ts.height / 2 - 11), withAttributes: ta)
        }

        // Center hub: hovered action's full title, else ✕ (click to close).
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - Self.innerR + 6, y: center.y - Self.innerR + 6,
                                              width: (Self.innerR - 6) * 2, height: (Self.innerR - 6) * 2))
        bg.setFill()
        hub.fill()
        let label = (hovered.map { actions[$0].title } ?? "✕") as NSString
        let la: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: hovered == nil ? dim : fg]
        let ls = label.size(withAttributes: la)
        label.draw(at: NSPoint(x: center.x - ls.width / 2, y: center.y - ls.height / 2), withAttributes: la)
    }

    /// Preview hook (powerring-preview CLI) — set hover without a mouse.
    func previewState(hover: Int?) {
        hovered = hover
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let hit = hitSector(convert(event.locationInWindow, from: nil))
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
        switch hitSector(convert(event.locationInWindow, from: nil)) {
        case .some(let i) where i >= 0: onPick?(actions[i])
        default: onCancel?()   // hub or the corner dead space
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
