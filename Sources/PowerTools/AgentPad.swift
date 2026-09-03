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
    /// The pad expanded itself for a new permission rather than the user
    /// hovering the strip. Same `miniPreferred && !miniActive` shape, opposite
    /// intent — a hover-peek offers "pin me open" ("□"), a permission-max
    /// offers "back to the strip" ("–"), so the header button has to tell them
    /// apart or there's no one-click way home.
    private var maxedForPermission = false

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
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let field = PadDock.Field(screen: screen)
        if let hit = PadDock.nearest(to: panel.frame.origin, size: panel.frame.size, in: field) {
            dockAnchor = hit.anchor
            panel.setFrame(NSRect(origin: hit.origin, size: panel.frame.size), display: true, animate: true)
            // A notch berth flips the mini strip horizontal, so re-render at the
            // new size and let the anchor re-place it.
            render()
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
    /// Fired when the pad actually goes away (header ✕ or the hotkey toggle) —
    /// the controller uses it to remember which permissions the user was
    /// looking at, so auto-reveal doesn't drag the pad straight back.
    var onDismiss: (() -> Void)?
    /// The registry's full list as last handed to us; `sessions` is the
    /// visible-and-triaged subset. Kept so the 10s tick can re-hide sessions
    /// that age past the idle cutoff without waiting on a registry event.
    private var allSessions: [ClaudeSession] = []
    private var sessions: [ClaudeSession] = []
    private var onAction: ((ClaudeSession, Action) -> Void)?

    /// Re-derive the visible rows from the raw list (drop long-idle, triage).
    private func applyVisible() {
        sessions = Self.triageSorted(Self.visible(allSessions)).map(Self.enriched)
    }

    /// Fold in the row metadata the pad draws but the hooks never send: branch,
    /// model, turns, tokens, and Claude Code's own session title. Both readers
    /// are cached and incremental, so this runs on every 10s refresh.
    private static func enriched(_ session: ClaudeSession) -> ClaudeSession {
        var s = session
        s.branch = GitBranch.shared.branch(forCwd: s.cwd)
        let totals = TranscriptStats.shared.totals(for: s.transcriptPath)
        s.model = totals.model
        s.msgs = totals.msgs
        s.tokens = totals.tokens
        // Claude Code's generated title beats the first-prompt backfill.
        if !totals.title.isEmpty { s.label = totals.title }
        return s
    }

    var isVisible: Bool { panel != nil }
    /// Collapsed to the traffic-light strip (no ✓/✕ rows visible).
    var isMini: Bool { miniActive }
    /// Permissions the user had already seen when they collapsed the pad to
    /// the strip. Auto-max ignores these — collapsing means "I've seen these,
    /// leave me alone", and a permission stuck on-screen (answered in the
    /// terminal, tab flag never cleared) must not re-maximize the pad on
    /// every registry event. A session drops out the moment it stops waiting,
    /// so its *next* ask counts as fresh again.
    private var seenPermissions: Set<String> = []

    /// A permission the pad hasn't surfaced yet — the one thing that overrides
    /// the user's mini preference, so a new ask never goes silent in the strip
    /// (the pad maxes itself instead of a separate popup surfacing it).
    /// Prunes `seenPermissions` as a side effect: answered asks stop counting.
    private func hasFreshPermission() -> Bool {
        let waiting = Set(sessions.filter { $0.state == .needsPermission }.map(\.id))
        seenPermissions.formIntersection(waiting)
        return !waiting.subtracting(seenPermissions).isEmpty
    }

    /// Everything on screen is now "seen" — called when the user collapses the
    /// pad, so only a later ask brings it back up.
    private func markPermissionsSeen() {
        seenPermissions = Set(sessions.filter { $0.state == .needsPermission }.map(\.id))
    }

    /// A session the user has plainly walked away from stops cluttering the
    /// pad: once it has sat idle past this, its card drops off entirely (the
    /// `claude` process may still be alive — it just no longer needs surfacing).
    /// Any non-idle state, or fresh activity, brings the card right back.
    nonisolated private static let hideIdleAfter: TimeInterval = 3 * 3600

    /// Filter out long-idle sessions before they reach the pad, so the full
    /// rows, the mini traffic-light strip, and the header counts all agree.
    /// Long-idle sessions aren't live work, but deleting them from the pad threw
    /// away the answer to "what was I just doing?" — they fold under a Recent
    /// header instead, capped so a week of chats can't push the pad off-screen.
    nonisolated static func isRecent(_ s: ClaudeSession) -> Bool {
        s.state == .idle && s.stateChanged.timeIntervalSinceNow < -hideIdleAfter
    }
    nonisolated private static let maxRecent = 3

    nonisolated static func visible(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        let live = sessions.filter { !isRecent($0) }
        let recent = sessions.filter(isRecent)
            .sorted { $0.stateChanged > $1.stateChanged }
            .prefix(maxRecent)
        return live + recent
    }

    /// Triage order: blocked sessions first, then everything else by how fresh
    /// its state is — the pad exists to surface whoever needs the user now.
    nonisolated static func triageSorted(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        func rank(_ s: ClaudeSession) -> Int {
            switch s.state {
            case .needsPermission: return 0
            case .needsInput, .unseen: return 1
            case .error: return 2
            case .busy: return 3
            case .idle: return isRecent(s) ? 5 : 4
            }
        }
        return sessions.sorted {
            let (a, b) = (rank($0), rank($1))
            return a != b ? a < b : $0.stateChanged > $1.stateChanged
        }
    }

    func present(sessions: [ClaudeSession], dark: Bool, screen: NSScreen, hotkeyName: String,
                 hooksInstalled: Bool, onAction: @escaping (ClaudeSession, Action) -> Void) {
        self.allSessions = sessions
        applyVisible()
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
            seenPermissions = Set(saved.seen ?? [])   // a stuck ask stays "seen" across restarts
        }
        if hasFreshPermission() {
            miniActive = false
            maxedForPermission = miniPreferred
        }
        buildPanel(on: screen)
        render(on: screen)
        persistPlacement()   // open=true — survives quits/deploys for launch restore
        // Quota only matters while the pad is up, so it is fetched here rather
        // than on a background schedule. Self-throttling: this is a no-op until
        // the snapshot ages out.
        UsageReader.shared.onUpdate = { [weak self] in
            guard let self else { return }
            self.render()
            // Refill a menu that is open right now, so a cold read that lands
            // while the user is staring at "Reading…" replaces it in place.
            if let menu = self.openUsageMenu { self.populateUsageMenu(menu) }
        }
        UsageReader.shared.refreshIfStale()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                // Re-hide sessions that have aged past the idle cutoff since the
                // last registry event, then redraw so the "2m ago" stays honest.
                self.applyVisible()
                self.render()
                self.onRefresh?()
                UsageReader.shared.refreshIfStale()
            }
        }
    }

    func dismiss() {
        let wasVisible = panel != nil
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
        if wasVisible { onDismiss?() }
    }

    /// open defaults true — every save except the user's explicit dismiss
    /// happens while the pad is up, so a quit/deploy leaves open=true behind.
    private func persistPlacement(open: Bool = true) {
        guard let panel else { return }
        PadPlacement.save(Self.placementKey, anchor: dockAnchor,
                          topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY),
                          mini: miniPreferred, open: open, seen: Array(seenPermissions))
    }

    /// Live update from the registry (hook events land while the pad is open).
    func updateSessions(_ sessions: [ClaudeSession], hooksInstalled: Bool) {
        self.allSessions = sessions
        applyVisible()
        self.hooksInstalled = hooksInstalled
        if hasFreshPermission() {
            miniActive = false
            maxedForPermission = miniPreferred
        } else if miniPreferred {
            miniActive = true
            maxedForPermission = false
        }
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
        view.onUsage = { [weak self] event in self?.showUsageMenu(with: event) }
        view.onClose = { [weak self] in self?.dismiss() }
        view.onMinimize = { [weak self] in
            guard let self else { return }
            if self.miniPreferred, !self.miniActive, !self.maxedForPermission {
                // Peeked strip ("□") → pin it back to full-time.
                self.miniPreferred = false
                self.miniActive = false
                self.seenPermissions.removeAll()
            } else {
                // Full pad, or one the pad maxed itself for a permission ("–")
                // → the strip. Collapsing banks every permission on screen as
                // seen, so it stays a strip until a *new* one lands.
                self.miniPreferred = true
                self.miniActive = true
                self.maxedForPermission = false
                self.markPermissionsSeen()
            }
            self.render()
            self.persistPlacement()
        }
        view.onExpand = { [weak self] in
            guard let self, self.miniActive else { return }
            self.miniActive = false
            self.render()
        }
        view.onCollapse = { [weak self] in
            guard let self, self.miniPreferred, !self.miniActive, !self.hasFreshPermission() else { return }
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

    /// Header ◔ — provider quota, one disabled item per window. Read-only by
    /// design: this answers "have I got runway to start this", and there is
    /// nothing here to click.
    private func showUsageMenu(with event: NSEvent) {
        // Opening is a user action, so it is also the right moment to catch a
        // stale snapshot up — refreshIfStale self-throttles.
        UsageReader.shared.refreshIfStale()

        let menu = NSMenu()
        populateUsageMenu(menu)
        // A cold read takes ~45s (it spawns a Claude session to scrape /usage),
        // which is far longer than anyone will hold a menu open. NSMenu builds
        // its items once at pop-up time, so without refilling in place the menu
        // would sit on "Reading…" forever and only ever show numbers on a
        // second opening.
        openUsageMenu = menu
        if let view = padView {
            menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
        }
        openUsageMenu = nil
    }

    /// The menu currently on screen, so a fetch landing mid-open can refill it.
    private var openUsageMenu: NSMenu?

    private func populateUsageMenu(_ menu: NSMenu) {
        let reader = UsageReader.shared
        menu.removeAllItems()

        let age = reader.ageDescription
        let header = NSMenuItem(
            title: age.isEmpty ? "Provider limits" : "Provider limits · \(age)",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if reader.providers.isEmpty {
            let empty = NSMenuItem(
                title: reader.fetchedAt == nil ? "Reading… (~45s)" : "No limits reported.",
                action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for provider in reader.providers {
            let name = provider.plan.isEmpty ? provider.name : "\(provider.name) · \(provider.plan)"
            let title = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            title.isEnabled = false
            title.attributedTitle = NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            menu.addItem(title)

            for window in provider.windows {
                let reset = window.resetDescription
                let line = "    \(window.label)  \(window.usedPercent)%"
                    + (reset.isEmpty ? "" : "  ·  \(reset)")
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                // Colour by pressure, matching the pad's own attention palette.
                let color: NSColor = window.usedPercent >= 90
                    ? NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1)
                    : (window.usedPercent >= 75
                        ? NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
                        : .secondaryLabelColor)
                item.attributedTitle = NSAttributedString(string: line, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: color])
                menu.addItem(item)
            }

            // Only worth saying when it cost us the numbers.
            if provider.windows.isEmpty, !provider.error.isEmpty {
                let item = NSMenuItem(title: "    \(provider.error)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
    }

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
        // Only the SHELF berth swallows the housing — it alone has to clear the
        // housing's dead band and pad out around it. The shoulders sit in real
        // menu-bar pixels and need neither. The screen is the controller's to
        // know, not the view's.
        var shellWidth: CGFloat = 0
        var shellTopInset: CGFloat = 0
        if dockAnchor?.absorbsNotch == true,
           let s = screen ?? panel.screen ?? NSScreen.main {
            let field = PadDock.Field(screen: s)
            shellWidth = field.shellWidth
            shellTopInset = field.notch.height
        }
        view.configure(sessions: sessions, dark: dark, hotkeyName: hotkeyName,
                       hooksInstalled: hooksInstalled, mini: miniActive,
                       peeking: miniPreferred && !miniActive && !maxedForPermission,
                       berth: dockAnchor?.isNotch == true, shellWidth: shellWidth,
                       shellTopInset: shellTopInset)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        // A panel shadow over the menu bar is the loudest tell that this is a
        // floating window rather than a bar item.
        panel.hasShadow = !view.berth

        // Docked: pin to the anchor for whatever size this render came out at,
        // so the mini strip parks in the same corner as the full pad.
        if let dockAnchor, let padScreen = screen ?? panel.screen ?? NSScreen.main {
            savedTopLeft = nil
            let origin = dockAnchor.origin(for: size, in: PadDock.Field(screen: padScreen))
            let target = NSRect(origin: origin, size: size)
            // Berthed: grow and shrink OUT OF the notch instead of cutting to
            // the new size. The top edge is pinned to the screen, so animating
            // the frame reads as the housing itself opening and closing.
            if dockAnchor.isNotch, panel.isVisible, panel.frame.size != size {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                }
            } else {
                panel.setFrame(target, display: true)
            }
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
    /// Header ◔ — carries the event because the handler pops an NSMenu.
    var onUsage: ((NSEvent) -> Void)?
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

    // Three lines per row — identity+chips, task, activity+spend — need more
    // width than the old two-line row; 300 still tucks beside the notch.
    private static let width: CGFloat = 300
    private static let pad: CGFloat = 10
    private static let headerH: CGFloat = 30
    private static let rowH: CGFloat = 58        // repo/chips · task · activity
    private static let rowHTall: CGFloat = 80    // needs-permission: ✓/✕ get their own line
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
                   mini: Bool = false, peeking: Bool = false, berth: Bool = false, shellWidth: CGFloat = 0, shellTopInset: CGFloat = 0) {
        self.sessions = sessions
        self.dark = dark
        self.mini = mini
        self.berth = berth
        self.shellWidth = shellWidth
        self.shellTopInset = shellTopInset
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

    /// Mini strip: agent identity bar (3px) + gap beside each status square
    /// (above it, when a notch berth turns the strip on its side).
    private static let miniBarSpan: CGFloat = 6
    /// Parked on a notch berth: the strip lies down into a row (a column would
    /// drape off the menu bar and down the screen) and the pad takes on the
    /// housing's silhouette and black — see `shellClip`.
    private(set) var berth = false
    /// On the SHELF berth the pad pads out to at least this wide so the
    /// housing disappears into it; 0 elsewhere. Set by the controller,
    /// which is the side that knows the screen.
    private var shellWidth: CGFloat = 0
    /// Height of the camera housing, on the shelf berth only. The pad's top
    /// band lies BEHIND the housing, where the display has no pixels at all —
    /// anything drawn there lands in the framebuffer (screenshots even show it)
    /// but never on the glass. So the plate fills the whole shell, to fuse with
    /// the housing, and the CONTENT starts below this.
    private var shellTopInset: CGFloat = 0
    private var contentTop: CGFloat { berth ? shellTopInset : 0 }

    /// Mouse point in content space — see `contentTop`.
    private func localPoint(_ event: NSEvent) -> NSPoint {
        var p = convert(event.locationInWindow, from: nil)
        p.y -= contentTop
        return p
    }

    /// The status square for light `i` — the strip runs down on the edge
    /// anchors and across on the notch berths, identity bar on the near side.
    private func miniLight(_ i: Int) -> NSRect {
        let step = CGFloat(i) * (Self.sq + Self.sqGap)
        // Centred in the shell: on the shelf the pill is padded out to swallow
        // the notch, so the lights belong in the middle of it.
        let n = CGFloat(max(sessions.count, 1))
        let run = n * Self.sq + (n - 1) * Self.sqGap
        let lead = max((bounds.width - run) / 2, Self.miniPad)
        return berth
            ? NSRect(x: lead + step, y: Self.miniPad + Self.miniBarSpan,
                     width: Self.sq, height: Self.sq)
            : NSRect(x: Self.miniPad + Self.miniBarSpan, y: Self.miniPad + step,
                     width: Self.sq, height: Self.sq)
    }

    override var fittingSize: NSSize {
        if mini {
            let n = CGFloat(max(sessions.count, 1))
            let run = n * Self.sq + (n - 1) * Self.sqGap
            return berth
                ? NSSize(width: max(Self.miniPad * 2 + run, shellWidth),
                         height: Self.miniPad * 2 + Self.miniBarSpan + Self.sq + contentTop)
                : NSSize(width: Self.miniPad * 2 + Self.miniBarSpan + Self.sq,
                         height: Self.miniPad * 2 + run)
        }
        let content = sessions.isEmpty
            ? Self.emptyH
            : sessions.indices.reduce(0) { $0 + rowHeight($1) } + CGFloat(sessions.count - 1) * Self.gap
                + (firstRecent == nil ? 0 : Self.recentHeaderH) + Self.footerH
        return NSSize(width: Self.width,
                      height: Self.pad + Self.headerH + content + Self.pad + contentTop)
    }



    /// Parked on a notch berth, the pad wears the housing's own silhouette and
    /// colour: square against the top edge of the screen, rounded below, in
    /// black. The app's Dark/Lite setting does not enter into it — the camera
    /// housing is black on every Mac in every appearance, and matching it is
    /// what makes the pad read as the notch having grown rather than as a panel
    /// that happens to be parked nearby.
    private var shellRadius: CGFloat { mini ? 12 : 18 }

    /// Overshooting the top edge by the corner radius leaves ONLY the bottom
    /// corners rounded — the top butts flush against the screen edge.
    private func shellClip() -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 0, y: -shellRadius, width: bounds.width,
                                         height: bounds.height + shellRadius),
                     xRadius: shellRadius, yRadius: shellRadius)
    }

    private var onDark: Bool { berth ? true : dark }

    private var bg: NSColor {
        if berth { return NSColor(white: 0.04, alpha: 0.97) }
        return dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98)
                    : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98)
    }
    private var fg: NSColor { onDark ? .white : .black }
    private var dim: NSColor { (onDark ? NSColor.white : .black).withAlphaComponent(0.5) }
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

    /// A small pill: the row's dense-metadata language, one per fact.
    /// Returns the x to continue at.
    @discardableResult
    private func drawChip(_ text: String, at x: CGFloat, y: CGFloat, color: NSColor) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: color]
        let w = (text as NSString).size(withAttributes: attrs).width
        let r = NSRect(x: x, y: y, width: w + 9, height: 13)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5).fill()
        (text as NSString).draw(at: NSPoint(x: x + 4.5, y: y + 1), withAttributes: attrs)
        return r.maxX + 4
    }

    /// One tint per model family, so "which of these is on Opus" is a glance.
    private static func modelColor(_ model: String) -> NSColor {
        switch model {
        case "Opus": return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case "Sonnet": return NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)
        case "Haiku": return NSColor(srgbRed: 0.35, green: 0.75, blue: 0.45, alpha: 1)
        default: return NSColor(srgbRed: 0.6, green: 0.55, blue: 0.75, alpha: 1)
        }
    }

    /// 50421 → "50.4k". The row has no room for digits nobody reads.
    private static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func rowHeight(_ i: Int) -> CGFloat {
        sessions[i].state == .needsPermission ? Self.rowHTall : Self.rowH
    }

    private static let recentHeaderH: CGFloat = 17

    /// Index of the first long-idle row, i.e. where the Recent group starts.
    private var firstRecent: Int? {
        sessions.firstIndex(where: AgentPad.isRecent)
    }

    private func rowRect(_ i: Int) -> NSRect {
        var y = Self.pad + Self.headerH
        for j in 0..<i { y += rowHeight(j) + Self.gap }
        if let firstRecent, i >= firstRecent { y += Self.recentHeaderH }
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
    /// ◔ — provider quota. Absent entirely when there is no reader installed,
    /// so the header does not grow a button that can only disappoint.
    private var usageRect: NSRect {
        UsageReader.isAvailable
            ? NSRect(x: minimizeRect.minX - 22, y: Self.pad + 2, width: 18, height: 18)
            : .zero
    }

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
        (berth ? shellClip()
               : NSBezierPath(roundedRect: bounds, xRadius: mini ? 9 : 14, yRadius: mini ? 9 : 14)).setClip()
        bg.setFill()
        bounds.fill()
        // Plate first, at full height, so the shell fuses with the housing —
        // then push every bit of content clear of the housing's dead band.
        if contentTop > 0 { NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: contentTop) }

        // Traffic lights: one status square per session in the same triage order
        // as the rows (most urgent first) — a column on the edge anchors, a row
        // on the notch berths.
        if mini {
            if sessions.isEmpty {
                dim.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: miniLight(0), xRadius: 4, yRadius: 4).fill()
                return
            }
            for (i, session) in sessions.enumerated() {
                let stale = session.state == .idle
                    && session.stateChanged.timeIntervalSinceNow < -3600
                let r = miniLight(i)
                // Same identity bar as the full rows, scaled to the square —
                // beside it in a column, over it in a row.
                Self.agentColor(session).withAlphaComponent(stale ? 0.35 : 1).setFill()
                let bar = berth
                    ? NSRect(x: r.minX + 1, y: Self.miniPad, width: Self.sq - 2, height: 3)
                    : NSRect(x: Self.miniPad, y: r.minY + 1, width: 3, height: Self.sq - 2)
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
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
        if !usageRect.isEmpty {
            // Tinted once any window is close to spent, so the pad can say
            // "you're nearly out" without being opened.
            let worst = UsageReader.shared.providers
                .flatMap(\.windows).map(\.usedPercent).max() ?? 0
            let tint = worst >= 90
                ? NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1)
                : (worst >= 75 ? NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1) : dim)
            ("◔" as NSString).draw(in: usageRect.offsetBy(dx: 3, dy: 1), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: tint])
        }

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

        if let firstRecent {
            let r = rowRect(firstRecent)
            ("Recent" as NSString).draw(
                at: NSPoint(x: r.minX + 3, y: r.minY - Self.recentHeaderH + 2),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                                 .foregroundColor: dim.withAlphaComponent(0.55)])
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

            let btns = buttons(for: session)
            let x0 = r.minX + 13
            let rightEdge = r.maxX - 10

            // LINE 1 — identity: repo, what it is doing, what it is doing it
            // with. Branch sits at the right until hover swaps in the ✕.
            var x = x0
            let repoAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: fg,
                .paragraphStyle: truncating]
            let repo = session.projectName as NSString
            let repoW = min(repo.size(withAttributes: repoAttrs).width, 110)
            repo.draw(in: NSRect(x: x, y: r.minY + 5, width: repoW, height: 15), withAttributes: repoAttrs)
            x += repoW + 6
            x = drawChip(session.state.chip, at: x, y: r.minY + 6, color: Self.stateColor(session.state))
            if !session.model.isEmpty {
                x = drawChip(session.model, at: x, y: r.minY + 6, color: Self.modelColor(session.model))
            }

            // Row ✕ on hover only — otherwise that corner carries the branch,
            // which is what tells two sessions in one repo apart.
            let cr = rowCloseRect(i)
            if i == hoveredRow {
                let closeColor: NSColor = hoveredCloseRow == i
                    ? NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1) : dim.withAlphaComponent(0.5)
                let closeGlyph = "✕" as NSString
                let closeAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: closeColor]
                let closeSize = closeGlyph.size(withAttributes: closeAttrs)
                closeGlyph.draw(at: NSPoint(x: cr.midX - closeSize.width / 2, y: cr.midY - closeSize.height / 2),
                                withAttributes: closeAttrs)
            } else if !session.branch.isEmpty {
                let bAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: dim.withAlphaComponent(0.7),
                    .paragraphStyle: truncating]
                let room = rightEdge - x - 4
                // Shed the prefix before shedding characters: "feature/pipeline-sheet"
                // reads as "pipeline-sheet", never as "…eature/pipeline-sheet".
                var text = "⑂ \(session.branch)"
                if (text as NSString).size(withAttributes: bAttrs).width > room,
                   let tail = session.branch.split(separator: "/").last {
                    text = "⑂ \(tail)"
                }
                let w = min((text as NSString).size(withAttributes: bAttrs).width, room)
                if w > 26 {
                    (text as NSString).draw(in: NSRect(x: rightEdge - w, y: r.minY + 7, width: w, height: 12),
                                            withAttributes: bAttrs)
                }
            }

            // LINE 2 — the task. LINE 3 — what it is touching right now, in
            // mono because it is a path or a command. With no task yet, the
            // activity moves up so the row never carries a dead line.
            let task = session.label
            let activity = session.detail.replacingOccurrences(of: "\n", with: " ")
            var lineY = r.minY + 22
            if !task.isEmpty {
                (task as NSString).draw(
                    in: NSRect(x: x0, y: lineY, width: rightEdge - x0, height: 15),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: fg.withAlphaComponent(0.8),
                                     .paragraphStyle: truncating])
                lineY += 17
            }

            // Spend, right-aligned on the last line — hover gives the space to
            // the action buttons instead.
            // Whatever is on the right of the last line — spend, or the action
            // buttons — bounds the activity text so the two never overlap.
            var metricsX = rightEdge
            if showsActions(i), !btns.isEmpty {
                metricsX = buttonRect(i, 0, count: btns.count).minX - 6
            } else if session.msgs > 0 {
                let mAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: dim.withAlphaComponent(0.75)]
                let text = "\(session.msgs) msgs · \(Self.compact(session.tokens)) tok" as NSString
                let w = text.size(withAttributes: mAttrs).width
                metricsX = rightEdge - w
                text.draw(at: NSPoint(x: metricsX, y: lineY + 1), withAttributes: mAttrs)
            }
            if !activity.isEmpty {
                (activity as NSString).draw(
                    in: NSRect(x: x0, y: lineY, width: max(metricsX - 6 - x0, 20), height: 13),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                                     .foregroundColor: dim, .paragraphStyle: truncating])
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

    private var truncatingHead: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingHead
        p.alignment = .right
        return p
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
        let p = localPoint(event)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { onClose?(); return }
        if minimizeRect.insetBy(dx: -4, dy: -4).contains(p) { onMinimize?(); return }
        // Pops a menu, so it needs the click event rather than a bare callback.
        if !usageRect.isEmpty, usageRect.insetBy(dx: -4, dy: -4).contains(p) {
            onUsage?(event)
            return
        }
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
        let p = localPoint(event)
        if let i = sessions.indices.first(where: { rowRect($0).contains(p) }) {
            onRowMenu?(i, event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if mini { onExpand?(); return }
        let p = localPoint(event)
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
