import Cocoa

/// Agent Pad — a virtual Codex Micro for Claude Code. A floating,
/// NON-ACTIVATING panel (same discipline as MacroPad) listing every live
/// Claude Code session with its status at a glance: working, idle, needs
/// permission, needs input, failed. Click a row to focus that session's
/// terminal; per-row buttons send a prompt (typed or dictated), cycle the
/// permission/plan mode (⇧⇥), or interrupt (Esc); when a permission dialog
/// is waiting, the row swaps to Approve / Deny. State arrives via Claude
/// Code hooks → `ClaudeHookServer` → `ClaudeSessionRegistry`.
@MainActor
final class AgentPad: NSObject {
    enum Action {
        case focus, prompt, cycleMode, interrupt, accept, deny
        case closeChat          // row ✕ — drop a stale chat from the pad
        case setModel(String)   // sends "/model <alias>" into the session
        case modelPicker        // focuses the session and opens /model (effort lives there)
        case modelMenu          // the ✱ row button — handled in the view (pops the menu)
    }

    private var panel: NSPanel?
    private var padView: AgentPadView?
    private var dark = true
    private var hotkeyName = ""
    private var hooksInstalled = false
    private var savedTopLeft: NSPoint?
    /// Traffic-light mode: the header "–" collapses the pad to a strip of
    /// status squares; hovering the strip peeks the full pad, leaving it
    /// drops back to the strip. Sticky: survives dismiss and restarts.
    private var miniPreferred = false
    private var miniActive = false

    /// Docking: drop the pad near a corner or edge midpoint and it snaps
    /// there; every re-render (mini↔full, row-count changes) re-anchors to
    /// the same spot until the user drags it away again. Geometry in PadDock;
    /// placement persists across restarts via PadPlacement.
    private var dockAnchor: PadDock?
    private let dockOverlay = PadDockOverlay()
    private static let placementKey = "agent"

    /// After a drag: snap to the nearest anchor when dropped close enough,
    /// otherwise stay free-floating; either way the placement is persisted.
    private func snapAfterDrag() {
        guard let panel, let vf = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        if let hit = PadDock.nearest(to: panel.frame.origin, size: panel.frame.size, in: vf) {
            dockAnchor = hit.anchor
            panel.setFrame(NSRect(origin: hit.origin, size: panel.frame.size), display: true, animate: true)
        } else {
            dockAnchor = nil
        }
        persistPlacement()
    }
    /// Re-render every 10s so the "2m ago" ages and stale states stay honest.
    private var refreshTimer: Timer?
    /// Fired on that same tick — the controller re-runs discovery so IDE tab
    /// states (the log-derived attention dots) stay current while the pad is up.
    var onRefresh: (() -> Void)?
    private var sessions: [ClaudeSession] = []
    private var onAction: ((ClaudeSession, Action) -> Void)?

    var isVisible: Bool { panel != nil }
    /// Collapsed to the traffic-light strip (no ✓/✕ rows visible) — the
    /// permission toasts key off this.
    var isMini: Bool { miniActive }

    /// Triage order: blocked sessions first, then everything else by how fresh
    /// its state is — the pad exists to surface whoever needs the user now.
    nonisolated static func triageSorted(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        func rank(_ s: ClaudeSession) -> Int {
            switch s.state {
            case .needsPermission: return 0
            case .needsInput, .unseen: return 1
            case .error: return 2
            case .busy: return 3
            case .idle: return 4
            }
        }
        return sessions.sorted {
            let (a, b) = (rank($0), rank($1))
            return a != b ? a < b : $0.stateChanged > $1.stateChanged
        }
    }

    func present(sessions: [ClaudeSession], dark: Bool, screen: NSScreen, hotkeyName: String,
                 hooksInstalled: Bool, onAction: @escaping (ClaudeSession, Action) -> Void) {
        self.sessions = Self.triageSorted(sessions)
        self.dark = dark
        self.hotkeyName = hotkeyName
        self.hooksInstalled = hooksInstalled
        self.onAction = onAction
        // First present after launch: restore where the user last left the pad
        // (dock anchor or free-float corner) — placement survives restarts.
        if panel == nil, dockAnchor == nil, savedTopLeft == nil,
           let saved = PadPlacement.load(Self.placementKey) {
            dockAnchor = saved.anchor
            if saved.anchor == nil, let x = saved.x, let y = saved.y {
                savedTopLeft = NSPoint(x: x, y: y)
            }
            miniPreferred = saved.mini ?? false
            miniActive = miniPreferred
        }
        buildPanel(on: screen)
        render(on: screen)
        persistPlacement()   // open=true — survives quits/deploys for launch restore
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                self.render()
                self.onRefresh?()
            }
        }
    }

    func dismiss() {
        if let panel {
            savedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            persistPlacement(open: false)
        }
        dockOverlay.hide()
        refreshTimer?.invalidate()
        refreshTimer = nil
        panel?.orderOut(nil)
        panel = nil
        padView = nil
    }

    /// open defaults true — every save except the user's explicit dismiss
    /// happens while the pad is up, so a quit/deploy leaves open=true behind.
    private func persistPlacement(open: Bool = true) {
        guard let panel else { return }
        PadPlacement.save(Self.placementKey, anchor: dockAnchor,
                          topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY),
                          mini: miniPreferred, open: open)
    }

    /// Live update from the registry (hook events land while the pad is open).
    func updateSessions(_ sessions: [ClaudeSession], hooksInstalled: Bool) {
        self.sessions = Self.triageSorted(sessions)
        self.hooksInstalled = hooksInstalled
        if isVisible { render() }
    }

    private func buildPanel(on screen: NSScreen) {
        if panel != nil { return }
        let view = AgentPadView(dark: dark)
        view.onRowAction = { [weak self] index, action in
            guard let self, index < self.sessions.count else { return }
            self.onAction?(self.sessions[index], action)
        }
        view.onRowMenu = { [weak self] index, event in
            guard let self, index < self.sessions.count else { return }
            self.showRowMenu(for: self.sessions[index], with: event)
        }
        view.onClose = { [weak self] in self?.dismiss() }
        view.onMinimize = { [weak self] in
            guard let self else { return }
            // Toggle: from full → traffic lights; from a peeked pad (hover-
            // expanded strip) → pin it back to full-time.
            self.miniPreferred.toggle()
            self.miniActive = self.miniPreferred
            self.render()
            self.persistPlacement()
        }
        view.onExpand = { [weak self] in
            guard let self, self.miniActive else { return }
            self.miniActive = false
            self.render()
        }
        view.onCollapse = { [weak self] in
            guard let self, self.miniPreferred, !self.miniActive else { return }
            self.miniActive = true
            self.render()
        }
        view.onDragMoved = { [weak self] in
            guard let self, let panel = self.panel, let screen = panel.screen ?? NSScreen.main else { return }
            self.dockOverlay.update(padFrame: panel.frame, on: screen, dark: self.dark)
        }
        view.onDragEnd = { [weak self] in
            self?.dockOverlay.hide()
            self?.snapAfterDrag()
        }
        let win = NSPanel(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view
        panel = win
        padView = view
        win.orderFrontRegardless()
    }

    // MARK: Row context menu — model / effort per conversation

    /// The session the open context menu refers to (menus outlive the render
    /// cycle, so the row index can't be trusted at action time).
    private var menuSession: ClaudeSession?

    private func showRowMenu(for session: ClaudeSession, with event: NSEvent) {
        menuSession = session
        let menu = NSMenu()
        let header = NSMenuItem(title: session.displayTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        // Watch-only rows: no model switching or injection — just Close.
        if session.isWatchOnly {
            let close = NSMenuItem(title: "Close Chat", action: #selector(menuCloseChat(_:)), keyEquivalent: "")
            close.target = self
            menu.addItem(close)
            if let view = padView {
                menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
            }
            return
        }
        for (title, alias) in [("Switch to Opus 4.8", "opus"),
                               ("Switch to Sonnet 5", "sonnet"),
                               ("Switch to Haiku 4.5", "haiku")] {
            let item = NSMenuItem(title: title, action: #selector(menuSetModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = alias
            menu.addItem(item)
        }
        menu.addItem(.separator())
        // Effort has no text command — it lives inside the /model dialog, so
        // open that in the session and let arrow keys take it from there.
        let picker = NSMenuItem(title: "Model & Effort Picker…", action: #selector(menuOpenPicker(_:)), keyEquivalent: "")
        picker.target = self
        menu.addItem(picker)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Chat", action: #selector(menuCloseChat(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        if let view = padView {
            menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        }
    }

    @objc private func menuSetModel(_ sender: NSMenuItem) {
        guard let session = menuSession, let alias = sender.representedObject as? String else { return }
        onAction?(session, .setModel(alias))
    }

    @objc private func menuOpenPicker(_ sender: NSMenuItem) {
        guard let session = menuSession else { return }
        onAction?(session, .modelPicker)
    }

    @objc private func menuCloseChat(_ sender: NSMenuItem) {
        guard let session = menuSession else { return }
        onAction?(session, .closeChat)
    }

    private func render(on screen: NSScreen? = nil) {
        guard let panel, let view = padView else { return }
        view.configure(sessions: sessions, dark: dark, hotkeyName: hotkeyName,
                       hooksInstalled: hooksInstalled, mini: miniActive,
                       peeking: miniPreferred && !miniActive)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)

        // Docked: pin to the anchor for whatever size this render came out at,
        // so the mini strip parks in the same corner as the full pad.
        if let dockAnchor, let vf = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame {
            savedTopLeft = nil
            panel.setFrame(NSRect(origin: dockAnchor.origin(for: size, in: vf), size: size), display: true)
            return
        }

        // Same top-left anchoring as MacroPad so re-renders don't move the pad.
        let topLeft: NSPoint
        if let saved = savedTopLeft {
            topLeft = saved
        } else if panel.frame.origin == .zero {
            let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            topLeft = NSPoint(x: vf.maxX - size.width - 24, y: vf.midY + size.height / 2)
        } else {
            topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        savedTopLeft = nil
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        if let vf = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, vf.minX + 8), vf.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, vf.minY + 8), vf.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: true)
    }
}

/// The pad canvas: header + one three-line row per session (title, state,
/// action buttons), each row tinted with its status color.
/// Same palette and drawing style as MacroPadView so it reads as one system.
final class AgentPadView: NSView {
    var onRowAction: ((Int, AgentPad.Action) -> Void)?
    var onRowMenu: ((Int, NSEvent) -> Void)?
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onDragMoved: (() -> Void)?
    var onDragEnd: (() -> Void)?

    /// Manual drag (instead of performDrag, which blocks until mouse-up and
    /// gives no positions) so the dock overlay can live-update mid-drag.
    /// Grab point in window coords; each drag event moves the window by the
    /// cursor's offset from it.
    private var dragGrab: NSPoint?
    private var dragDidMove = false

    private func beginDrag(_ event: NSEvent) {
        dragGrab = event.locationInWindow
        dragDidMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = dragGrab, let window else { return }
        dragDidMove = true
        let o = window.frame.origin
        window.setFrameOrigin(NSPoint(x: o.x + event.locationInWindow.x - grab.x,
                                      y: o.y + event.locationInWindow.y - grab.y))
        onDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragGrab != nil else { return }
        dragGrab = nil
        // A plain click on empty space is not a drop — only a real move snaps.
        if dragDidMove { onDragEnd?() }
        dragDidMove = false
    }

    private var sessions: [ClaudeSession] = []
    private var dark: Bool
    private var mini = false
    private var peeking = false   // hover-expanded from the strip; – becomes □
    private var hotkeyName = ""
    private var hooksInstalled = true
    private var hoveredRow: Int?
    private var hoveredButton: (row: Int, index: Int)?
    private var hoveredCloseRow: Int?
    private var pressedRow: Int?

    private static let width: CGFloat = 224
    private static let pad: CGFloat = 10
    private static let headerH: CGFloat = 30
    private static let rowH: CGFloat = 46        // resting: title + state line
    private static let rowHTall: CGFloat = 68    // needs-permission: ✓/✕ get their own line
    private static let gap: CGFloat = 5
    private static let emptyH: CGFloat = 64
    private static let footerH: CGFloat = 30
    private static let btnW: CGFloat = 26
    private static let btnH: CGFloat = 20
    private static let sq: CGFloat = 14      // traffic-light square
    private static let sqGap: CGFloat = 4
    private static let miniPad: CGFloat = 7

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(sessions: [ClaudeSession], dark: Bool, hotkeyName: String, hooksInstalled: Bool,
                   mini: Bool = false, peeking: Bool = false) {
        self.sessions = sessions
        self.dark = dark
        self.mini = mini
        self.peeking = peeking
        self.hotkeyName = hotkeyName
        self.hooksInstalled = hooksInstalled
        hoveredRow = nil
        hoveredButton = nil
        hoveredCloseRow = nil
        pressedRow = nil
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Mini strip: agent identity bar (3px) + gap beside each status square.
    private static let miniBarSpan: CGFloat = 6

    override var fittingSize: NSSize {
        if mini {
            let n = CGFloat(max(sessions.count, 1))
            return NSSize(width: Self.miniPad * 2 + Self.miniBarSpan + Self.sq,
                          height: Self.miniPad * 2 + n * Self.sq + (n - 1) * Self.sqGap)
        }
        let content = sessions.isEmpty
            ? Self.emptyH
            : sessions.indices.reduce(0) { $0 + rowHeight($1) } + CGFloat(sessions.count - 1) * Self.gap + Self.footerH
        return NSSize(width: Self.width, height: Self.pad + Self.headerH + content + Self.pad)
    }

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    /// Claude Code's own signal palette: terracotta (the tab-strip attention
    /// dot / Claude mark) for needs-you states, blue for a running turn.
    private static func stateColor(_ state: ClaudeSession.State) -> NSColor {
        switch state {
        case .busy: return NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 1)
        case .idle: return NSColor(srgbRed: 0.35, green: 0.75, blue: 0.45, alpha: 1)
        case .unseen, .needsPermission, .needsInput: return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .error: return NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1)
        }
    }

    private func rowHeight(_ i: Int) -> CGFloat {
        sessions[i].state == .needsPermission ? Self.rowHTall : Self.rowH
    }

    private func rowRect(_ i: Int) -> NSRect {
        var y = Self.pad + Self.headerH
        for j in 0..<i { y += rowHeight(j) + Self.gap }
        return NSRect(x: Self.pad, y: y, width: Self.width - Self.pad * 2, height: rowHeight(i))
    }

    /// Buttons show on demand — always for a waiting permission, on hover
    /// otherwise (they take over the state line, so nothing shifts).
    private func showsActions(_ i: Int) -> Bool {
        sessions[i].state == .needsPermission || hoveredRow == i
    }

    /// Buttons for row `i` — hover reveals them in place of the state line;
    /// a waiting permission keeps ✓/✕ visible on its own (taller) row.
    /// Agent identity color — the left-edge bar in rows AND the strip.
    static func agentColor(_ session: ClaudeSession) -> NSColor {
        if session.isCodex { return NSColor(srgbRed: 0.35, green: 0.45, blue: 1, alpha: 1) }
        if session.isCursor { return NSColor(srgbRed: 0.65, green: 0.4, blue: 0.95, alpha: 1) }
        return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)   // Claude terracotta
    }

    private func buttons(for session: ClaudeSession) -> [(glyph: String, action: AgentPad.Action, tint: NSColor?)] {
        // Watch-only agents (Codex, Cursor): no remote control — the row is
        // presence, state, and click-to-focus; hover reveals nothing.
        if session.isWatchOnly { return [] }
        if session.state == .needsPermission {
            return [("✓", .accept, NSColor(srgbRed: 0.35, green: 0.75, blue: 0.45, alpha: 1)),
                    ("✕", .deny, NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1))]
        }
        return [("✱", .modelMenu, nil), ("✎", .prompt, nil), ("⇆", .cycleMode, nil), ("■", .interrupt, nil)]
    }

    private func buttonRect(_ row: Int, _ index: Int, count: Int) -> NSRect {
        let r = rowRect(row)
        let x = r.maxX - 8 - CGFloat(count - index) * Self.btnW - CGFloat(count - 1 - index) * 4
        return NSRect(x: x, y: r.maxY - Self.btnH - 6, width: Self.btnW, height: Self.btnH)
    }

    private var closeRect: NSRect { NSRect(x: Self.width - Self.pad - 18, y: Self.pad + 2, width: 18, height: 18) }
    private var minimizeRect: NSRect { NSRect(x: closeRect.minX - 22, y: Self.pad + 2, width: 18, height: 18) }

    /// The per-row ✕ (close a stale chat), top-right corner of the row.
    private func rowCloseRect(_ i: Int) -> NSRect {
        let r = rowRect(i)
        return NSRect(x: r.maxX - 22, y: r.minY + 5, width: 16, height: 16)
    }

    private static func age(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: mini ? 9 : 14, yRadius: mini ? 9 : 14).setClip()
        bg.setFill()
        bounds.fill()

        // Traffic lights: one status square per session, stacked vertically in
        // the same triage order as the rows (most urgent on top), so each
        // light sits where its row lands when hover expands the full pad.
        if mini {
            if sessions.isEmpty {
                dim.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: NSRect(x: Self.miniPad + Self.miniBarSpan, y: Self.miniPad,
                                                 width: Self.sq, height: Self.sq),
                             xRadius: 4, yRadius: 4).fill()
                return
            }
            for (i, session) in sessions.enumerated() {
                let y = Self.miniPad + CGFloat(i) * (Self.sq + Self.sqGap)
                let stale = session.state == .idle
                    && session.stateChanged.timeIntervalSinceNow < -3600
                // Same identity bar as the full rows, scaled to the square.
                Self.agentColor(session).withAlphaComponent(stale ? 0.35 : 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: Self.miniPad, y: y + 1, width: 3, height: Self.sq - 2),
                             xRadius: 1.5, yRadius: 1.5).fill()
                let r = NSRect(x: Self.miniPad + Self.miniBarSpan, y: y,
                               width: Self.sq, height: Self.sq)
                Self.stateColor(session.state).withAlphaComponent(stale ? 0.35 : 0.9).setFill()
                let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                path.fill()
                if session.state == .needsPermission || session.state == .needsInput
                    || session.state == .unseen || session.state == .error {
                    fg.withAlphaComponent(0.9).setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
            return
        }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: fg]
        // The pad started Claude-only; with Codex (and Cursor next) it's a fleet.
        let padTitle = sessions.contains(where: { $0.kind != nil && $0.kind != "claude" }) ? "Agents" : "Claude Code"
        (padTitle as NSString).draw(at: NSPoint(x: Self.pad + 4, y: Self.pad + 3), withAttributes: titleAttrs)
        // Fleet state at a glance: total count, and how many are blocked on you.
        if !sessions.isEmpty {
            let attention = sessions.filter {
                $0.state == .needsPermission || $0.state == .needsInput
                    || $0.state == .unseen || $0.state == .error
            }.count
            var x = Self.pad + 4 + (padTitle as NSString).size(withAttributes: titleAttrs).width + 6
            var counts: [(String, NSColor)] = [("· \(sessions.count)", dim)]
            if attention > 0 {
                counts.append(("· \(attention) need\(attention == 1 ? "s" : "") you",
                               NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)))
            }
            for (text, color) in counts {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: color]
                (text as NSString).draw(at: NSPoint(x: x, y: Self.pad + 5), withAttributes: attrs)
                x += (text as NSString).size(withAttributes: attrs).width + 6
            }
        }
        ("✕" as NSString).draw(in: closeRect.offsetBy(dx: 3, dy: 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: dim])
        // – collapses to traffic lights; □ (while peeking) pins full mode back.
        ((peeking ? "□" : "–") as NSString).draw(in: minimizeRect.offsetBy(dx: 4, dy: 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: dim])

        if sessions.isEmpty {
            let msg = (hooksInstalled
                ? "No Claude Code sessions.\nStart `claude` in a terminal."
                : "Hooks not installed.\n⌘ menu ▸ Install Claude Code Hooks") as NSString
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineSpacing = 3
            msg.draw(in: NSRect(x: Self.pad, y: Self.pad + Self.headerH + 8,
                                width: Self.width - Self.pad * 2, height: Self.emptyH),
                     withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim, .paragraphStyle: p])
            return
        }

        for (i, session) in sessions.enumerated() {
            // Rows parked idle for over an hour recede so live work pops;
            // hovering restores full strength for reading.
            let stale = session.state == .idle && i != hoveredRow
                && session.stateChanged.timeIntervalSinceNow < -3600
            let ctx = NSGraphicsContext.current?.cgContext
            if stale, let ctx {
                ctx.saveGState()
                ctx.setAlpha(0.5)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            let r = rowRect(i)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            // The whole row wears its status color; hover/press just deepen it.
            let rowColor = Self.stateColor(session.state)
            if i == pressedRow {
                rowColor.withAlphaComponent(0.5).setFill()
            } else if i == hoveredRow && hoveredButton == nil {
                rowColor.withAlphaComponent(0.3).setFill()
            } else {
                rowColor.withAlphaComponent(0.15).setFill()
            }
            path.fill()
            // Attention ring for the states worth glancing at.
            if session.state == .needsPermission || session.state == .needsInput
                || session.state == .unseen || session.state == .error {
                Self.stateColor(session.state).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }

            // Agent identity: a solid left-edge bar — orange = Claude, blue =
            // Codex, purple = Cursor — its own channel, separate from the row
            // wash (= state).
            Self.agentColor(session).setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 4, y: r.minY + 6, width: 3, height: r.height - 12),
                         xRadius: 1.5, yRadius: 1.5).fill()

            // Title — the row tint itself is the status indicator.
            let btns = buttons(for: session)
            let textMaxX = r.maxX - 10
            (session.displayTitle as NSString).draw(
                in: NSRect(x: r.minX + 13, y: r.minY + 6, width: rowCloseRect(i).minX - 4 - (r.minX + 13), height: 16),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: fg,
                                 .paragraphStyle: truncating])

            // Row ✕ — close a stale chat.
            let cr = rowCloseRect(i)
            let closeColor: NSColor = hoveredCloseRow == i
                ? NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1) : dim.withAlphaComponent(0.4)
            let closeGlyph = "✕" as NSString
            let closeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: closeColor]
            let closeSize = closeGlyph.size(withAttributes: closeAttrs)
            closeGlyph.draw(at: NSPoint(x: cr.midX - closeSize.width / 2, y: cr.midY - closeSize.height / 2),
                            withAttributes: closeAttrs)

            // Second line: state · age · project (the project folder moves down
            // here once the title is the prompt; tty tag disambiguates twins).
            var line2 = "\(session.state.label) · \(Self.age(session.stateChanged))"
            line2 += " · \(session.kind ?? "claude")"
            if !session.label.isEmpty {
                line2 += " · \(session.projectName)"
            } else if !session.ttyTag.isEmpty,
                      sessions.contains(where: { $0.id != session.id && $0.projectName == session.projectName }) {
                line2 += " · \(session.ttyTag)"
            }
            if !session.detail.isEmpty {
                let d = session.detail.replacingOccurrences(of: "\n", with: " ")
                line2 = "\(session.state.label) · \(d)"
            }
            // Hover swaps this line for the buttons — except on rows that have
            // none (watch-only agents), where it would just blank out.
            if session.state == .needsPermission || i != hoveredRow || btns.isEmpty {
                (line2 as NSString).draw(
                    in: NSRect(x: r.minX + 13, y: r.minY + 24, width: textMaxX - (r.minX + 13), height: 14),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: dim,
                                     .paragraphStyle: truncating])
            }

            // Action buttons.
            for (bi, btn) in btns.enumerated() where showsActions(i) {
                let br = buttonRect(i, bi, count: btns.count)
                let bPath = NSBezierPath(roundedRect: br, xRadius: 5, yRadius: 5)
                let isHover = hoveredButton?.row == i && hoveredButton?.index == bi
                if let tint = btn.tint {
                    tint.withAlphaComponent(isHover ? 0.85 : 0.25).setFill()
                } else {
                    (isHover ? accent.withAlphaComponent(0.6)
                             : (dark ? NSColor.white : .black).withAlphaComponent(0.1)).setFill()
                }
                bPath.fill()
                let glyphColor: NSColor = (isHover || btn.tint != nil) ? (dark ? .white : (isHover ? .white : fg)) : dim
                let glyph = btn.glyph as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: glyphColor]
                let size = glyph.size(withAttributes: attrs)
                glyph.draw(at: NSPoint(x: br.midX - size.width / 2, y: br.midY - size.height / 2), withAttributes: attrs)
            }

            if stale, let ctx {
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }

        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: dim.withAlphaComponent(0.35),
        ]
        // Two lines — the one-liner doesn't fit the narrow pad.
        let hints = ["click = focus · ✱ = model/effort",
                     "hold \(hotkeyName.isEmpty ? "hotkey" : hotkeyName) + J"]
        for (hi, line) in hints.enumerated() {
            let hint = line as NSString
            let hintSize = hint.size(withAttributes: hintAttrs)
            hint.draw(at: NSPoint(x: bounds.midX - hintSize.width / 2,
                                  y: bounds.height - Self.pad - 25 + CGFloat(hi) * 13),
                      withAttributes: hintAttrs)
        }
    }

    private var truncating: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    /// Preview hook (agentpad-preview CLI) — set hover state without a mouse.
    func previewState(hoverRow: Int?, hoverButton: (row: Int, index: Int)?) {
        hoveredRow = hoverRow
        hoveredButton = hoverButton
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if mini {
            beginDrag(event)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { onClose?(); return }
        if minimizeRect.insetBy(dx: -4, dy: -4).contains(p) { onMinimize?(); return }
        for (i, session) in sessions.enumerated() {
            if rowCloseRect(i).insetBy(dx: -3, dy: -3).contains(p) {
                onRowAction?(i, .closeChat)
                return
            }
            let btns = buttons(for: session)
            for bi in btns.indices where showsActions(i) && buttonRect(i, bi, count: btns.count).insetBy(dx: -2, dy: -2).contains(p) {
                // The model button pops a menu, which needs the click event —
                // route it through the menu path instead of the action path.
                if case .modelMenu = btns[bi].action { onRowMenu?(i, event) } else { onRowAction?(i, btns[bi].action) }
                return
            }
            if rowRect(i).contains(p) {
                pressedRow = i
                needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(140)) { [weak self] in
                    self?.pressedRow = nil
                    self?.needsDisplay = true
                }
                onRowAction?(i, .focus)
                return
            }
        }
        beginDrag(event)   // anywhere else moves the pad
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = sessions.indices.first(where: { rowRect($0).contains(p) }) {
            onRowMenu?(i, event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if mini { onExpand?(); return }
        let p = convert(event.locationInWindow, from: nil)
        let newRow = sessions.indices.first { rowRect($0).contains(p) }
        var newButton: (row: Int, index: Int)?
        var newClose: Int?
        for (i, session) in sessions.enumerated() {
            // Buttons only exist where they're drawn: permission rows always,
            // other rows once the cursor is on them.
            if session.state == .needsPermission || newRow == i {
                let btns = buttons(for: session)
                for bi in btns.indices where buttonRect(i, bi, count: btns.count).contains(p) {
                    newButton = (i, bi)
                }
            }
            if rowCloseRect(i).insetBy(dx: -3, dy: -3).contains(p) { newClose = i }
        }
        if newRow != hoveredRow || newButton?.row != hoveredButton?.row || newButton?.index != hoveredButton?.index
            || newClose != hoveredCloseRow {
            hoveredRow = newRow
            hoveredButton = newButton
            hoveredCloseRow = newClose
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRow = nil
        hoveredButton = nil
        hoveredCloseRow = nil
        needsDisplay = true
        if !mini { onCollapse?() }   // no-op unless this pad lives in mini mode
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
}
