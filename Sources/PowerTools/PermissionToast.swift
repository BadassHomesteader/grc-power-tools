import Cocoa

/// Permission toasts — when a Claude Code session hits needs-permission while
/// the Agent Pad can't be seen (closed, or collapsed to the strip), a small
/// NON-ACTIVATING card slides in top-right with the session title and the
/// FULL command text (approving truncated commands is blind), plus ✓ / ✕.
/// One card per waiting session, stacked; a card vanishes the moment its
/// permission resolves (hook event) or when acted on. The corner ✕ snoozes
/// that request — it won't re-toast unless a NEW permission arrives.
@MainActor
final class PermissionToast {
    private var panels: [String: NSPanel] = [:]   // session.id → card
    private var order: [String] = []              // stacking, oldest first
    /// Session ids the user dismissed with ✕ — suppressed until the session
    /// leaves needs-permission (a fresh request toasts again).
    private var snoozed: Set<String> = []

    func present(session: ClaudeSession, dark: Bool,
                 onApprove: @escaping () -> Void, onDeny: @escaping () -> Void) {
        guard !snoozed.contains(session.id) else { return }
        if let existing = panels[session.id] {
            (existing.contentView as? PermissionToastView)?.update(session: session)
            relayout()
            return
        }
        let view = PermissionToastView(session: session, dark: dark)
        view.onApprove = { [weak self] in
            self?.remove(session.id)
            onApprove()
        }
        view.onDeny = { [weak self] in
            self?.remove(session.id)
            onDeny()
        }
        view.onClose = { [weak self] in
            self?.snoozed.insert(session.id)
            self?.remove(session.id)
        }
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let win = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view
        panels[session.id] = win
        order.append(session.id)
        relayout()
        win.orderFrontRegardless()
    }

    /// Reconcile with the registry: drop cards (and snoozes) for sessions no
    /// longer waiting. Pass [] to clear everything (pad became visible).
    func sync(waitingIds: Set<String>) {
        for id in order where !waitingIds.contains(id) { remove(id) }
        snoozed.formIntersection(waitingIds)
    }

    private func remove(_ id: String) {
        panels[id]?.orderOut(nil)
        panels[id] = nil
        order.removeAll { $0 == id }
        relayout()
    }

    /// Top-right stack under the menu bar, newest below older cards.
    private func relayout() {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        var y = vf.maxY - 12
        for id in order {
            guard let win = panels[id] else { continue }
            let size = win.frame.size
            win.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 12, y: y - size.height))
            y -= size.height + 8
        }
    }
}

/// One card: title row, "needs permission · project", the full command, ✓ / ✕.
final class PermissionToastView: NSView {
    var onApprove: (() -> Void)?
    var onDeny: (() -> Void)?
    var onClose: (() -> Void)?

    private var session: ClaudeSession
    private let dark: Bool
    private var hoveredButton: Int?   // 0 approve, 1 deny

    private static let width: CGFloat = 340
    private static let pad: CGFloat = 12
    private static let btnH: CGFloat = 24
    private static let detailFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    init(session: ClaudeSession, dark: Bool) {
        self.session = session
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(session: ClaudeSession) {
        self.session = session
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    /// Claude's terracotta attention color — same as the pad's waiting rows.
    private var attention: NSColor { NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1) }

    private var detailText: String {
        session.detail.isEmpty ? "Permission requested" : session.detail
    }

    private var detailHeight: CGFloat {
        let rect = (detailText as NSString).boundingRect(
            with: NSSize(width: Self.width - Self.pad * 2, height: 5 * 14),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.detailFont])
        return min(ceil(rect.height) + 2, 5 * 14)
    }

    override var fittingSize: NSSize {
        NSSize(width: Self.width,
               height: Self.pad + 16 + 15 + 6 + detailHeight + 8 + Self.btnH + Self.pad)
    }

    private var closeRect: NSRect { NSRect(x: Self.width - Self.pad - 14, y: Self.pad, width: 14, height: 14) }
    private var buttonsY: CGFloat { fittingSize.height - Self.pad - Self.btnH }
    private func buttonRect(_ i: Int) -> NSRect {
        NSRect(x: Self.width - Self.pad - CGFloat(2 - i) * 92 - CGFloat(1 - i) * 6,
               y: buttonsY, width: 92, height: Self.btnH)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        path.setClip()
        bg.setFill()
        bounds.fill()
        attention.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        (session.displayTitle as NSString).draw(
            in: NSRect(x: Self.pad, y: Self.pad, width: closeRect.minX - 6 - Self.pad, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: fg,
                             .paragraphStyle: truncating])
        ("✕" as NSString).draw(in: closeRect.offsetBy(dx: 2, dy: 0), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: dim])
        ("needs permission · \(session.projectName)" as NSString).draw(
            at: NSPoint(x: Self.pad, y: Self.pad + 17),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: attention])

        (detailText as NSString).draw(
            in: NSRect(x: Self.pad, y: Self.pad + 16 + 15 + 6,
                       width: Self.width - Self.pad * 2, height: detailHeight),
            withAttributes: [.font: Self.detailFont, .foregroundColor: fg.withAlphaComponent(0.85)])

        let labels = [("✓ Approve", NSColor(srgbRed: 0.35, green: 0.75, blue: 0.45, alpha: 1)),
                      ("✕ Deny", NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1))]
        for (i, (label, tint)) in labels.enumerated() {
            let r = buttonRect(i)
            let bp = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            tint.withAlphaComponent(hoveredButton == i ? 0.85 : 0.22).setFill()
            bp.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: hoveredButton == i ? NSColor.white : fg]
            let s = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2),
                                     withAttributes: attrs)
        }
    }

    private var truncating: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { onClose?(); return }
        if buttonRect(0).contains(p) { onApprove?(); return }
        if buttonRect(1).contains(p) { onDeny?(); return }
        window?.performDrag(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = [0, 1].first { buttonRect($0).contains(p) }
        if h != hoveredButton {
            hoveredButton = h
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredButton = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
}
