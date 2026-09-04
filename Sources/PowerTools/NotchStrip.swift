import Cocoa

/// The one thing that lives in the notch.
///
/// Before this, the Macro Pad and the Agent Pad each grew their own notch
/// rendering and then competed for the same housing — two windows, one piece of
/// hardware, and ~70 lines of identical berth code in each. This replaces both
/// with a single surface that features PUBLISH into, the way MacNotch's "Live
/// Activities" does: one strip, several sources, priority-ordered.
///
/// It has exactly three sizes and never grows past the middle one:
///
///   Min — marks flanking the housing, inside the menu-bar band.
///   Mid — one notification-shaped card hanging below the housing.
///   Max — NOT here. Clicking a mark opens the owning feature's own window at
///         its ordinary anchor. The notch never becomes a full panel.
///
/// Min and Mid are the same window at two sizes, animating between them, which
/// is what makes it read as the housing opening rather than as a panel
/// appearing next to it.
@MainActor
final class NotchStrip {
    /// One dot in the collapsed strip.
    struct Mark {
        var color: NSColor
        /// Outline it — needs-you, or a quota window nearly spent.
        var ring = false
        /// Recede it — stale, or a snapshot too old to trust.
        var dim = false
        var tooltip = ""
        /// Four small squares instead of a dot: the module mark is a nav
        /// glyph, not another status light, and should not read as one.
        var grid = false
    }

    /// The Mid state, and the whole reason Mid exists: a permission ask is
    /// notification-shaped, so it gets a notification, with the answer on it.
    struct Card {
        var title: String
        var subtitle: String
        var accent: NSColor
        /// The rest of the Agent Pad's row, so the expanded notch shows what
        /// the pad shows rather than a thinner summary of it. All optional —
        /// a source with nothing to put here just gets title + subtitle.
        var repo = ""
        var state = ""          // chip
        var model = ""          // chip
        var branch = ""
        var metrics = ""        // "82 msgs · 543.7k tok"
        /// The row's controls — the same set the Agent Pad's rows carry.
        var actions: [(glyph: String, tint: NSColor?, run: () -> Void)] = []
        /// Shown on every row rather than only the hovered one. A waiting
        /// permission does this, so ✓/✕ are visible without hunting for them.
        var actionsAlways = false
    }

    /// A publisher. Closures rather than a protocol, matching `PowerRing.Action`
    /// and `AgentPad.Action` — two implementers do not justify a type hierarchy.
    struct Source {
        let id: String          // "agents" | "quota" — also the Config key
        let priority: Int       // 0 agents, 10 quota; gaps leave room to insert
        var maxMarks: Int = 5
        let marks: () -> [Mark]
        /// Mid content for a mark, or nil if this source has nothing to expand to.
        let card: (Int) -> Card?
        /// Click — open this source's own full surface, elsewhere on screen.
        let activate: (Int) -> Void
    }

    // Geometry, lifted from the pads so the pixels do not move. `pad` is
    // reserved on BOTH sides of a cluster: with only the inner side padded the
    // outermost dot lands flush on the plate edge and bleeds into the menu bar.
    static let dot: CGFloat = 9
    static let gap: CGFloat = 5
    static let pad: CGFloat = 7
    static let groupGap: CGFloat = 9
    /// Mid is capped, not fitted. The notch must never reach full-panel size,
    /// so this is a ceiling the layout is clamped to rather than a hint.
    static let midWidthFactor: CGFloat = 2
    static let midCardHeight: CGFloat = 56
    static let midCardHeightWithActions: CGFloat = 74
    /// The hover list carries the Agent Pad's full row — repo, state, model,
    /// branch, task, spend — because a one-line summary was not what anyone
    /// wanted to see when they looked. The ROW CAP is what keeps it an
    /// expansion of the notch rather than a second copy of the pad.
    static let listRow: CGFloat = 56
    static let listPad: CGFloat = 8
    static let maxListRows = 5

    /// Where a mark ends up, in view coordinates. One array, read by BOTH
    /// `draw` and `mouseDown` — the pads recompute this in two places and the
    /// two drifting apart is exactly how a click lands on the wrong row.
    struct Placed {
        let source: Int
        let mark: Int
        let rect: NSRect
    }

    /// Two states, and the notch NEVER opens itself. A permission arriving
    /// makes its dot ring; it does not throw a banner over your work. The
    /// ✓/✕ live on the row, one hover away — which is the difference between
    /// a status surface and an interruption.
    enum Mode: Equatable {
        case min
        case list(source: Int)
        /// The module row — what the grid mark opens.
        case picker
        /// One module filling the space below the housing.
        case module(index: Int)
    }

    /// A panel the notch HOSTS, as opposed to a Source, which publishes into
    /// it. Modules are opened deliberately; sources speak up on their own.
    /// Everything the app can already show in its own window can be a module,
    /// which is what turns the notch from a status strip into a control centre.
    struct Module {
        let id: String
        let glyph: String
        let title: String
        /// Content height below the housing, clamped to `maxModuleContent` —
        /// the notch stays a notch.
        let height: CGFloat
        let make: () -> NSView
    }

    /// Ceiling on a module's content, the same discipline the list has: the
    /// notch expands, it does not become a window.
    static let maxModuleContent: CGFloat = 320
    static let pickerRow: CGFloat = 64
    /// While a module is open, its siblings stay one click away on a tab row
    /// under the housing. Without it a module was a dead end — there was no way
    /// back to the row and no way out at all.
    static let moduleTabRow: CGFloat = 28

    private var panel: NSPanel?
    private var view: NotchStripView?
    private var sources: [Source] = []
    private var modules: [Module] = []
    /// The hosted module's view, kept so it can be torn down on collapse.
    private var moduleView: NSView?
    private var timer: Timer?
    private(set) var mode: Mode = .min {
        didSet {
            guard oldValue != mode else { return }
            syncClickAway()
            // Transitions are user actions, so this is a breadcrumb trail, not
            // a firehose — it is what makes "the notch did X on its own"
            // diagnosable from the log instead of by guessing.
            onLog?("notch: \(oldValue) → \(mode)")
        }
    }
    /// Global + local mouse monitors, armed only while the notch is open.
    private var clickAway: [Any] = []
    /// Opened by a click rather than a hover, so leaving does not close it.
    private var pinned = false
    /// Which source ids the user has switched on, plus the master toggle.
    private var enabledIDs: Set<String> = []
    private var masterOn = true
    /// on screen doesn't re-present the banner on every 10s refresh.

    var onLog: ((String) -> Void)?

    // MARK: Registration and config

    func register(_ source: Source) {
        sources.append(source)
        sources.sort { $0.priority < $1.priority }
    }

    func registerModule(_ module: Module) { modules.append(module) }

    /// The grid mark (four squares) rides at the end of the strip as its own pseudo-source, so it
    /// gets the existing layout, hit-testing and cutout safety for free.
    private var moduleMarkGroup: Int? { modules.isEmpty ? nil : activeSources.count }

    /// Master switch plus one flag per source id.
    func apply(master: Bool, enabled: Set<String>) {
        masterOn = master
        enabledIDs = enabled
        refresh()
    }

    private var activeSources: [Source] {
        masterOn ? sources.filter { enabledIDs.contains($0.id) } : []
    }

    // MARK: Screen

    /// Only a display with a real camera housing gets a strip. `Field.notch`
    /// degrades to a ZERO-WIDTH seam on everything else, so placing by it would
    /// silently park a pill in the middle of an external monitor's menu bar.
    private var notchScreen: NSScreen? {
        NSScreen.screens.first { PadDock.Field(screen: $0).hasNotch }
    }

    func start() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenChanged() }
            }
        startTimer()
        refresh()
    }

    private func screenChanged() {
        // Lid closed, display connected, resolution changed: the housing may
        // have moved or gone. Rebuild from scratch rather than re-placing.
        teardown()
        refresh()
    }

    // MARK: Content

    /// Current marks per active source, already capped, with an overflow dot
    /// standing in for whatever the cap dropped.
    private func groups() -> [[Mark]] {
        var out = sourceGroups()
        if !modules.isEmpty {
            out.append([Mark(color: NSColor(white: 0.75, alpha: 1), dim: true, tooltip: "Modules", grid: true)])
        }
        return out
    }

    private func sourceGroups() -> [[Mark]] {
        activeSources.map { source in
            let all = source.marks()
            guard all.count > source.maxMarks else { return all }
            let shown = Array(all.prefix(source.maxMarks))
            let dropped = all.dropFirst(source.maxMarks)
            // Carry attention forward: a ringed mark hidden by the cap must not
            // become invisible, or the cap could swallow the one urgent thing.
            var overflow = Mark(color: .white, dim: true)
            overflow.ring = dropped.contains { $0.ring }
            overflow.tooltip = "+\(dropped.count) more"
            return shown + [overflow]
        }
    }

    func refresh() {
        let live = groups()
        // No empty state, deliberately: zero marks means zero pixels. That is
        // what makes "on by default" safe — a quiet machine shows nothing at
        // all rather than a placeholder dot sitting in the menu bar forever.
        // The grid mark alone is not a reason to occupy the menu bar: an app with
        // nothing to say still shows nothing.
        guard let screen = notchScreen, sourceGroups().contains(where: { !$0.isEmpty }) else {
            teardown()
            return
        }
        let field = PadDock.Field(screen: screen)
        let firstShow = panel == nil
        build(on: screen)
        if firstShow { onLog?("notch: strip up — \(live.map(\.count)) mark(s) per source") }
        // A Mid whose source or mark has gone away falls back to Min.
        if case let .list(si) = mode, si >= activeSources.count || live[si].isEmpty { mode = .min }
        if case let .module(i) = mode, i >= modules.count { mode = .min }
        var cards: [Card] = []
        var listMode = false
        switch mode {
        case .min: break
        case let .list(si) where si < activeSources.count:
            listMode = true
            // Built from the source's REAL count, not from the capped marks:
            // after capping, the last mark is the overflow dot, and asking the
            // source for a card at that index hands back a genuine item wearing
            // the overflow's slot. The list caps itself separately.
            let total = activeSources[si].marks().count
            cards = (0..<Swift.min(total, NotchStrip.maxListRows)).compactMap { activeSources[si].card($0) }
            if cards.isEmpty { mode = .min }
        case .picker, .module:
            break   // these carry no cards; they are handled by the view
        case .list:
            mode = .min   // a list whose source went away
        }
        if case let .list(si) = mode { view?.listSource = si }
        view?.configure(groups: live, cards: cards, listMode: listMode, field: field,
                        picker: pickerEntries, moduleHeight: hostedHeight, tabs: moduleTabs)
        hostModuleIfNeeded(field: field)
        place(field: field, animated: true)
    }

    private var pickerEntries: [(glyph: String, title: String)] {
        if case .picker = mode { return modules.map { ($0.glyph, $0.title) } }
        return []
    }

    /// The module's own content height — the tab row is charged against the
    /// same ceiling, so adding it cannot push the notch past its cap.
    private var hostedHeight: CGFloat {
        guard case let .module(i) = mode, i < modules.count else { return 0 }
        return Swift.min(modules[i].height,
                         NotchStrip.maxModuleContent - NotchStrip.moduleTabRow)
    }

    private var moduleTabs: [(glyph: String, title: String, active: Bool)] {
        guard case let .module(i) = mode else { return [] }
        return modules.enumerated().map { ($1.glyph, $1.title, $0 == i) }
    }

    /// Put the module's own view in the space below the housing. The strip's
    /// layer masks it, so a module never has to know about the shell's shape.
    private func hostModuleIfNeeded(field: PadDock.Field) {
        guard case let .module(i) = mode, i < modules.count, let view else {
            moduleView?.removeFromSuperview()
            moduleView = nil
            return
        }
        if moduleView == nil {
            let v = modules[i].make()
            view.addSubview(v)
            moduleView = v
        }
        moduleView?.frame = NSRect(x: 0, y: field.notch.height + NotchStrip.moduleTabRow,
                                   width: view.fittingSize.width, height: hostedHeight)
    }

    // MARK: Window

    private func build(on screen: NSScreen) {
        if panel != nil { return }
        let v = NotchStripView()
        v.onHover = { [weak self] hit in self?.hover(hit) }
        v.onExit = { [weak self] genuinelyOutside in self?.hoverOut(outside: genuinelyOutside) }
        v.onClick = { [weak self] hit in self?.click(hit) }
        // -1 closes; anything else switches module.
        v.onModuleTab = { [weak self] i in
            guard let self else { return }
            if i < 0 { self.collapse() } else { self.openModule(i) }
        }
        let win = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        // A shadow over the menu bar is the loudest tell that a thing is a
        // window rather than part of the hardware.
        win.hasShadow = false
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = v
        panel = win
        view = v
        win.orderFrontRegardless()
    }

    /// Note the timer is NOT torn down here: the strip has to keep breathing
    /// while it has nothing to show, or it can never come back. It used to be
    /// started inside `build()`, which meant an empty strip had no heartbeat at
    /// all — it woke only on a registry change, and a change that landed before
    /// the sources were registered left it invisible until the next one.
    private func teardown() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
        mode = .min
    }

    private func startTimer() {
        timer?.invalidate()
        // Runs whether or not the strip is on screen — see `teardown`. The tick
        // never triggers a quota FETCH, only a redraw of the snapshot: a fetch
        // shells out for ~45s, so polling it on a timer would mean burning
        // quota to measure quota, forever.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func place(field: PadDock.Field, animated: Bool) {
        guard let panel, let view else { return }
        let target = view.targetFrame(in: field)
        guard panel.frame != target else { return }
        if animated, panel.isVisible, panel.frame.size != target.size {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    // MARK: Interaction

    /// Hovering any dot opens that source's whole list — one dot at a time was
    /// the wrong answer to "what have I got running?".
    private func hover(_ hit: Placed?) {
        guard let hit else { return }
        if case .picker = mode { return }
        if case .module = mode { return }
        // The grid mark opens the module row on hover, the way a dot opens its
        // list — and, like the list, UNPINNED: leave and it folds back. A tile
        // click is what keeps it (the module opens pinned). Crossing the menu
        // bar over it therefore shows the row only for as long as the cursor
        // is on it.
        if hit.source == moduleMarkGroup {
            mode = .picker
            refresh()
            pinned = false
            return
        }
        guard hit.source < activeSources.count else { return }
        if case .list(hit.source) = mode { return }   // already showing it
        mode = .list(source: hit.source)
        refresh()
        pinned = false
    }

    /// Clicking stays IN the notch. A dot pins the list open so it can be read
    /// and acted on without holding the cursor still; a row acts on that row.
    /// Neither one opens the pad — that is what the hotkey and the menu bar are
    /// for, and a status surface that launches windows when touched is not a
    /// status surface.
    private func click(_ hit: Placed?) {
        guard let hit, hit.source <= activeSources.count else { return }
        switch mode {
        case .min:
            if hit.source == moduleMarkGroup { openPicker(); return }
            pinned = true
            openList(source: hit.source)
        case .list:
            activeSources[hit.source].activate(hit.mark)
            pinned = false
            collapse()
        case .picker:
            openModule(hit.mark)
        case .module:
            collapse()
        }
    }

    /// The cursor left the WHOLE surface — a pinned list stays, a hovered one
    /// goes. `outside` is the load-bearing word: opening the row resizes the
    /// window, every resize rebuilds the tracking area, and removing a tracking
    /// area under the cursor fires a spurious `mouseExited` whose location is
    /// still inside the bounds. Collapsing on that produced an open→resize→
    /// exit→collapse→resize→enter→open flap that never let a hover-opened row
    /// stand. So only a genuine leave (cursor truly off the window) collapses;
    /// moving DOWN onto a tile keeps it open, exactly like a menu.
    private func hoverOut(outside: Bool) {
        guard outside else { return }
        if mode != .min { onLog?("notch: cursor left\(pinned ? " (pinned, stays)" : "")") }
        guard !pinned else { return }
        collapse()
    }

    func collapse() {
        pinned = false
        guard mode != .min else { return }
        mode = .min
        moduleView?.removeFromSuperview()
        moduleView = nil
        refresh()
    }

    /// Clicking OFF the notch folds it back into the housing, the way a menu
    /// closes — the ✕ on the tab row is a way out, not the only one. Armed by
    /// `mode`: a global monitor hears clicks in other apps (it never sees our
    /// own windows), a local one hears clicks on our other windows. Nothing
    /// here swallows anything; the click still lands where it was aimed.
    private func syncClickAway() {
        if mode == .min {
            clickAway.forEach { NSEvent.removeMonitor($0) }
            clickAway = []
            return
        }
        guard clickAway.isEmpty else { return }
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { [weak self] _ in
            Task { @MainActor in self?.clickedAway(in: nil) }
        }) { clickAway.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated { self?.clickedAway(in: window) }
            return event
        }) { clickAway.append(l) }
    }

    /// The decision behind the monitors, kept apart so the harness can drive
    /// it. `nil` is a click in another app. Our own panel stays open, and so
    /// does anything riding ABOVE the status-bar level — the ✱ menu popped from
    /// a row, a tooltip — because that click is part of using the notch.
    func clickedAway(in window: NSWindow?) {
        guard mode != .min else { return }
        if let window {
            if window === panel { return }
            if window.level.rawValue > NSWindow.Level.statusBar.rawValue { return }
        }
        collapse()
    }

    /// Open the module row, or a module by index.
    func openPicker() { mode = .picker; pinned = true; refresh() }
    func openModule(_ i: Int) {
        guard i < modules.count else { return }
        moduleView?.removeFromSuperview(); moduleView = nil
        mode = .module(index: i)
        pinned = true
        refresh()
    }
    var moduleCount: Int { modules.count }

    // MARK: Test hooks

    /// Show a source's whole list — the hover shape, exposed for the harness.
    func openList(source: Int) {
        guard source < activeSources.count else { return }
        mode = .list(source: source)
        refresh()
    }

    /// Every rect the view draws content into, in SCREEN coordinates. The
    /// harness asserts none of these intersect the housing — see the note on
    /// `NotchStripView.contentRects`.
    var contentRectsInScreen: [NSRect] {
        guard let panel, let view else { return [] }
        return view.contentRects.map { r in
            NSRect(x: panel.frame.minX + r.minX,
                   y: panel.frame.maxY - r.maxY,   // view is flipped
                   width: r.width, height: r.height)
        }
    }

    /// Test hook: the real panel and view, so the harness can synthesise clicks
    /// against the SAME layout array that `draw` uses. Hit-testing and drawing
    /// reading different arrays is how a click lands on the wrong mark.
    var testSurface: (panel: NSPanel, view: NotchStripView)? {
        guard let panel, let view else { return nil }
        return (panel, view)
    }

    var frame: NSRect { panel?.frame ?? .zero }
    var isVisible: Bool { panel?.isVisible ?? false }
    var placedMarks: [Placed] { view?.placed ?? [] }
}

/// The strip canvas. Flipped, like the pads, so y grows downward from the top of
/// the screen — which is also the top of the housing.
final class NotchStripView: NSView {
    var onHover: ((NotchStrip.Placed?) -> Void)?
    /// Bool: the cursor is genuinely off the window, not a tracking-area
    /// rebuild artifact whose exit location is still inside the bounds.
    var onExit: ((Bool) -> Void)?
    var onClick: ((NotchStrip.Placed?) -> Void)?
    /// Tab index, or -1 for the close button.
    var onModuleTab: ((Int) -> Void)?

    private var groups: [[NotchStrip.Mark]] = []
    private var cards: [NotchStrip.Card] = []
    /// Which source the open list belongs to, so a row click routes to it.
    var listSource = 0
    private var listMode = false
    /// There is no single-card state any more; kept only so the collapsed
    /// path reads clearly.
    private var card: NotchStrip.Card? { nil }
    private var hoveredRow: Int?
    private var hoveredAction: (row: Int, index: Int)?
    /// Rebuilt each draw; read by mouseDown so a click lands on what was drawn.
    private var rowActionRects: [(row: Int, index: Int, rect: NSRect)] = []
    private var notchSpan: CGFloat = 0
    private var notchHeight: CGFloat = 0
    private var maxWidth: CGFloat = 10_000
    private var hovered: Int?

    /// COMPUTED, never cached. Caching it in `draw` meant that between a
    /// configure and the next redraw the array described the PREVIOUS content
    /// while the window already had its new frame — so `contentRects` reported
    /// phantom positions and, worse, `mouseDown` hit-tested against rects that
    /// no longer matched what was on screen.
    var placed: [NotchStrip.Placed] { computePlacement() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var picker: [(glyph: String, title: String)] = []
    private var moduleHeight: CGFloat = 0
    private var tabs: [(glyph: String, title: String, active: Bool)] = []
    private var hoveredTile: Int?
    private var hoveredTab: Int?

    func configure(groups: [[NotchStrip.Mark]], cards: [NotchStrip.Card], listMode: Bool,
                   field: PadDock.Field,
                   picker: [(glyph: String, title: String)] = [],
                   moduleHeight: CGFloat = 0,
                   tabs: [(glyph: String, title: String, active: Bool)] = []) {
        self.picker = picker
        self.moduleHeight = moduleHeight
        self.tabs = tabs
        hoveredTile = nil
        hoveredTab = nil
        self.groups = groups
        self.cards = cards
        self.listMode = listMode
        hoveredRow = nil
        self.notchSpan = field.notch.width
        self.notchHeight = field.notch.height
        self.maxWidth = field.visible.width - PadDock.margin * 2
        // LAST, not first: shellRadius reads isMid, which depends on cards and
        // listMode above — computing it earlier used the PREVIOUS state's shape.
        // The corner set matters too: this view is FLIPPED, so its backing layer
        // is geometry-flipped and layer minY is the TOP. Masking "MinY" squared
        // the bottom and rounded the edge against the screen, the exact opposite
        // of the shell it is meant to match.
        wantsLayer = true
        layer?.cornerRadius = shellRadius
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true
        hovered = nil
        needsDisplay = true
    }

    // MARK: Geometry

    private func run(_ n: Int) -> CGFloat {
        n <= 0 ? 0 : CGFloat(n) * NotchStrip.dot + CGFloat(n - 1) * NotchStrip.gap
    }

    /// Leading shoulder gets the highest-priority source; everything else goes
    /// trailing, in priority order. Fixed, never rebalanced by count — a source
    /// that hops sides as sessions come and go is unreadable at a glance.
    private var leadRun: CGFloat { groups.isEmpty ? 0 : run(groups[0].count) }
    private var trailRun: CGFloat {
        let rest = groups.dropFirst().filter { !$0.isEmpty }
        guard !rest.isEmpty else { return 0 }
        return rest.reduce(0) { $0 + run($1.count) } + NotchStrip.groupGap * CGFloat(rest.count - 1)
    }
    /// Each shoulder is sized for ITS OWN cluster, and a shoulder with nothing
    /// on it takes no width at all. Sizing both to the wider one (which is what
    /// centring the pill forces) left a slab of empty black plate beside the
    /// housing whenever the sources were lopsided — with only agents on, that
    /// was 79pt of nothing to the right of the notch.
    private var leadFlank: CGFloat { leadRun > 0 ? leadRun + NotchStrip.pad * 2 : 0 }
    private var trailFlank: CGFloat { trailRun > 0 ? trailRun + NotchStrip.pad * 2 : 0 }

    /// Mid is CLAMPED, never fitted: the notch must not reach full-panel size.
    private var midWidth: CGFloat {
        min(notchSpan * NotchStrip.midWidthFactor, maxWidth)
    }
    private var midHeight: CGFloat {
        notchHeight + ((card?.actions.isEmpty ?? true)
                       ? NotchStrip.midCardHeight : NotchStrip.midCardHeightWithActions)
    }
    /// The list is capped at `maxListRows`, not fitted to the source — that cap
    /// is what keeps the hover shape Mid rather than sliding into Max.
    private var listHeight: CGFloat {
        notchHeight + NotchStrip.listPad * 2
            + CGFloat(min(cards.count, NotchStrip.maxListRows)) * NotchStrip.listRow
    }
    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 12, y: notchHeight + NotchStrip.listPad + CGFloat(i) * NotchStrip.listRow,
               width: bounds.width - 24, height: NotchStrip.listRow)
    }
    private var visibleRows: Int { min(cards.count, NotchStrip.maxListRows) }

    override var fittingSize: NSSize {
        if moduleHeight > 0 {
            return NSSize(width: midWidth, height: notchHeight + NotchStrip.moduleTabRow + moduleHeight)
        }
        if !picker.isEmpty { return NSSize(width: midWidth, height: notchHeight + NotchStrip.pickerRow) }
        if listMode, !cards.isEmpty { return NSSize(width: midWidth, height: listHeight) }
        if card != nil { return NSSize(width: midWidth, height: midHeight) }
        return NSSize(width: leadFlank + notchSpan + trailFlank,
                      height: max(notchHeight, NotchStrip.dot + NotchStrip.pad * 2))
    }

    /// Where the window goes. The view owns this because only it knows how wide
    /// each shoulder came out. Min hangs off the housing shoulder-by-shoulder;
    /// Mid is centred on the housing. Both are flush with the top of the screen.
    func targetFrame(in field: PadDock.Field) -> NSRect {
        let size = fittingSize
        let x = isMid ? field.notch.midX - size.width / 2
                      : field.notch.minX - leadFlank
        let clamped = min(max(x, field.visible.minX), max(field.visible.maxX - size.width, field.visible.minX))
        return NSRect(x: clamped, y: field.notch.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Marks laid out around the housing. Whole groups only — splitting one
    /// source across the cutout would make it impossible to tell whose dot is
    /// whose, which is the entire point of grouping them.
    /// Any expanded shape — list, module row, or a hosted module.
    var isMid: Bool { (listMode && !cards.isEmpty) || card != nil || !picker.isEmpty || moduleHeight > 0 }

    private func computePlacement() -> [NotchStrip.Placed] {
        guard !isMid, !groups.isEmpty else { return [] }
        var out: [NotchStrip.Placed] = []
        let y = (bounds.height - NotchStrip.dot) / 2
        let step = NotchStrip.dot + NotchStrip.gap

        // Leading: right-aligned against the housing's left edge.
        var x = leadFlank - NotchStrip.pad - run(groups[0].count)
        for (i, _) in groups[0].enumerated() {
            out.append(.init(source: 0, mark: i,
                             rect: NSRect(x: x + CGFloat(i) * step, y: y,
                                          width: NotchStrip.dot, height: NotchStrip.dot)))
        }
        // Trailing: left-aligned from the housing's right edge outward, higher
        // priority nearest the housing so the eye reads outward from the notch.
        x = leadFlank + notchSpan + NotchStrip.pad
        for (gi, group) in groups.enumerated().dropFirst() where !group.isEmpty {
            for (i, _) in group.enumerated() {
                out.append(.init(source: gi, mark: i,
                                 rect: NSRect(x: x + CGFloat(i) * step, y: y,
                                              width: NotchStrip.dot, height: NotchStrip.dot)))
            }
            x += run(group.count) + NotchStrip.groupGap
        }
        return out
    }

    /// Everything the view actually paints content into. The harness asserts
    /// none of it intersects the housing — and it must assert on GEOMETRY, not
    /// on a screenshot: the framebuffer faithfully contains the pixels behind
    /// the camera that no human can see, so a screenshot check passes on
    /// precisely the bug it exists to catch.
    /// A tab in the module bar. The last slot is the close button.
    func tabRect(_ i: Int) -> NSRect {
        let closeW: CGFloat = 34
        let w = (bounds.width - closeW) / CGFloat(max(tabs.count, 1))
        if i < 0 { return NSRect(x: bounds.width - closeW, y: notchHeight, width: closeW, height: NotchStrip.moduleTabRow) }
        return NSRect(x: CGFloat(i) * w, y: notchHeight, width: w, height: NotchStrip.moduleTabRow)
    }

    /// The module row's tiles.
    func tileRect(_ i: Int) -> NSRect {
        let w = bounds.width / CGFloat(max(picker.count, 1))
        return NSRect(x: CGFloat(i) * w, y: notchHeight, width: w, height: NotchStrip.pickerRow)
    }

    var contentRects: [NSRect] {
        if moduleHeight > 0 {
            return [NSRect(x: 0, y: notchHeight, width: bounds.width,
                           height: NotchStrip.moduleTabRow + moduleHeight)]
        }
        if !picker.isEmpty { return picker.indices.map(tileRect) }
        if listMode, !cards.isEmpty { return (0..<visibleRows).map(rowRect) }
        return card == nil ? placed.map(\.rect) : ([cardTextRect] + actionRects)
    }

    /// Test hook: the row rects, so a click can be aimed at one.
    var listRowRects: [NSRect] { listMode ? (0..<visibleRows).map(rowRect) : [] }
    /// Test hook: the ✓/✕ rects drawn on the rows.
    var listActionRects: [(row: Int, index: Int, rect: NSRect)] { rowActionRects }

    /// Also computed — same reasoning as `placed`.
    var actionRects: [NSRect] {
        guard let card, !card.actions.isEmpty else { return [] }
        return card.actions.indices.map { i in
            NSRect(x: bounds.width - 14 - CGFloat(card.actions.count - i) * 34,
                   y: notchHeight + 14, width: 30, height: 26)
        }
    }

    private var cardTextRect: NSRect {
        NSRect(x: 14, y: notchHeight + 8, width: bounds.width - 28 - CGFloat(card?.actions.count ?? 0) * 34,
               height: bounds.height - notchHeight - 16)
    }

    // MARK: Drawing

    /// Square against the top edge of the screen, rounded below — overshooting
    /// the top by the corner radius drops those corners off-view. Same trick
    /// the pads used, and it is what fuses the plate to the housing.
    /// Tighter when collapsed into the menu-bar band, generous when expanded —
    /// and the layer mask uses the SAME number, or the drawn silhouette and the
    /// clip disagree at the corners.
    private var shellRadius: CGFloat { isMid ? 18 : 12 }

    private func shellClip(radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 0, y: -radius, width: bounds.width,
                                         height: bounds.height + radius),
                     xRadius: radius, yRadius: radius)
    }

    override func draw(_ dirtyRect: NSRect) {
        shellClip(radius: shellRadius).setClip()
        // The housing's own black, in every appearance — the camera is black on
        // every Mac, so matching it is what makes the two read as one shape.
        NSColor(white: 0.04, alpha: 0.97).setFill()
        bounds.fill()

        // A hosted module paints itself; the strip supplies the shell and the
        // tab row that gets you back out of it.
        if moduleHeight > 0 {
            drawTabs()
            return
        }
        if !picker.isEmpty {
            drawPicker()
            return
        }
        if listMode, !cards.isEmpty {
            drawList()
            return
        }
        if let card {
            drawCard(card)
            return
        }
        let layout = placed
        for (idx, p) in layout.enumerated() {
            guard p.source < groups.count, p.mark < groups[p.source].count else { continue }
            let mark = groups[p.source][p.mark]
                // The grid mark is dim like the overflow dot but a notch
                // brighter, or four 4pt squares smear into a smudge.
                let alpha: CGFloat = mark.dim ? (mark.grid ? 0.5 : 0.35) : 0.9
                let lit = hovered == idx
                mark.color.withAlphaComponent(lit ? 1 : alpha).setFill()
                if mark.grid {
                    // Four squares in the dot's own box: 4pt each, 1pt apart,
                    // so the layout, hit-testing and cutout math see a 9pt mark.
                    let s = (p.rect.width - 1) / 2
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let r = NSRect(x: p.rect.minX + CGFloat(dx) * (s + 1),
                                       y: p.rect.minY + CGFloat(dy) * (s + 1),
                                       width: s, height: s)
                        NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
                    }
                    continue
                }
                let path = NSBezierPath(roundedRect: p.rect,
                                        xRadius: p.rect.width / 2, yRadius: p.rect.width / 2)
                path.fill()
                if mark.ring {
                    NSColor.white.withAlphaComponent(0.9).setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
        }
    }

    /// The module bar: every module one click away, plus a way out.
    private func drawTabs() {
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: notchHeight, width: bounds.width, height: NotchStrip.moduleTabRow).fill()
        for (i, t) in tabs.enumerated() {
            let r = tabRect(i)
            if t.active {
                NSColor.white.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 4), xRadius: 6, yRadius: 6).fill()
            } else if hoveredTab == i {
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 4), xRadius: 6, yRadius: 6).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white.withAlphaComponent(t.active ? 1 : 0.55)]
            let label = "\(t.glyph)  \(t.title)" as NSString
            let sz = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
        }
        let close = tabRect(-1)
        if hoveredTab == -1 {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: close.insetBy(dx: 6, dy: 4), xRadius: 6, yRadius: 6).fill()
        }
        let x = "✕" as NSString
        let xa: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white.withAlphaComponent(0.7)]
        let xs = x.size(withAttributes: xa)
        x.draw(at: NSPoint(x: close.midX - xs.width / 2, y: close.midY - xs.height / 2), withAttributes: xa)
    }

    /// The module row: glyph over title, one tile each.
    private func drawPicker() {
        for (i, m) in picker.enumerated() {
            let r = tileRect(i)
            if hoveredTile == i {
                NSColor.white.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 6), xRadius: 8, yRadius: 8).fill()
            }
            let g: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white]
            let t: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.7)]
            let gs = (m.glyph as NSString).size(withAttributes: g)
            (m.glyph as NSString).draw(at: NSPoint(x: r.midX - gs.width / 2, y: r.minY + 12), withAttributes: g)
            let ts = (m.title as NSString).size(withAttributes: t)
            (m.title as NSString).draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.minY + 40), withAttributes: t)
        }
    }

    /// A small pill — the row's dense metadata, same language as the pad's.
    @discardableResult
    private func chip(_ text: String, at x: CGFloat, y: CGFloat, color: NSColor) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: color]
        let w = (text as NSString).size(withAttributes: attrs).width
        let r = NSRect(x: x, y: y, width: w + 9, height: 13)
        color.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5).fill()
        (text as NSString).draw(at: NSPoint(x: x + 4.5, y: y + 1), withAttributes: attrs)
        return r.maxX + 4
    }

    /// Hover: the Agent Pad's rows, in the housing's black. Everything sits
    /// BELOW the housing — the band above is plate only, because there is no
    /// display behind the camera and anything drawn there never reaches the
    /// glass.
    private func drawList() {
        rowActionRects = []
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let white = NSColor.white
        let dim = white.withAlphaComponent(0.55)

        for i in 0..<visibleRows {
            let r = rowRect(i).insetBy(dx: 0, dy: 3)
            let c = cards[i]
            // The row wears its status colour, as the pad's rows do.
            let wash = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            c.accent.withAlphaComponent(hoveredRow == i ? 0.3 : 0.15).setFill()
            wash.fill()
            if c.actionsAlways {
                c.accent.setStroke(); wash.lineWidth = 1.5; wash.stroke()
            }
            c.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX + 4, y: r.minY + 6, width: 3, height: r.height - 12),
                         xRadius: 1.5, yRadius: 1.5).fill()

            let x0 = r.minX + 13, right = r.maxX - 10
            // Line 1 — identity: repo, what it is doing, what with; branch right.
            var x = x0
            let repoAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: white, .paragraphStyle: p]
            let repo = (c.repo.isEmpty ? c.title : c.repo) as NSString
            let repoW = min(repo.size(withAttributes: repoAttrs).width, 130)
            repo.draw(in: NSRect(x: x, y: r.minY + 5, width: repoW, height: 15), withAttributes: repoAttrs)
            x += repoW + 6
            if !c.state.isEmpty { x = chip(c.state, at: x, y: r.minY + 6, color: c.accent) }
            if !c.model.isEmpty {
                x = chip(c.model, at: x, y: r.minY + 6, color: NotchStripView.modelColor(c.model))
            }
            if !c.branch.isEmpty {
                let bAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: white.withAlphaComponent(0.7), .paragraphStyle: p]
                var text = "⑂ \(c.branch)"
                let room = right - x - 4
                if (text as NSString).size(withAttributes: bAttrs).width > room,
                   let tail = c.branch.split(separator: "/").last { text = "⑂ \(tail)" }
                let w = min((text as NSString).size(withAttributes: bAttrs).width, room)
                if w > 26 {
                    (text as NSString).draw(in: NSRect(x: right - w, y: r.minY + 7, width: w, height: 12),
                                            withAttributes: bAttrs)
                }
            }
            // Line 2 — the task.
            if !c.title.isEmpty, !c.repo.isEmpty {
                (c.title as NSString).draw(
                    in: NSRect(x: x0, y: r.minY + 22, width: right - x0, height: 15),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                     .foregroundColor: white.withAlphaComponent(0.85),
                                     .paragraphStyle: p])
            }
            // The row's controls, on the row itself — the notch carries the same
            // set the pad does. Revealed on hover, except a waiting permission,
            // whose ✓/✕ stay put so the answer is never hidden.
            var right2 = right
            if !c.actions.isEmpty, c.actionsAlways || hoveredRow == i {
                for (ai, action) in c.actions.enumerated() {
                    let br = NSRect(x: right - CGFloat(c.actions.count - ai) * 34, y: r.minY + 24,
                                    width: 30, height: 24)
                    rowActionRects.append((row: i, index: ai, rect: br))
                    let path = NSBezierPath(roundedRect: br, xRadius: 6, yRadius: 6)
                    let hot = hoveredAction?.row == i && hoveredAction?.index == ai
                    (action.tint ?? white).withAlphaComponent(hot ? 0.95 : 0.35).setFill()
                    path.fill()
                    let aAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: white]
                    let sz = (action.glyph as NSString).size(withAttributes: aAttrs)
                    (action.glyph as NSString).draw(at: NSPoint(x: br.midX - sz.width / 2,
                                                               y: br.midY - sz.height / 2),
                                                    withAttributes: aAttrs)
                }
                right2 = right - CGFloat(c.actions.count) * 34 - 6
            }
            // The attention ring belongs to the state, not to whether the
            // buttons happen to be showing.


            // Line 3 — what it is touching, and what it has spent.
            var metricsX = right2
            if !c.metrics.isEmpty {
                let mAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: dim]
                let w = (c.metrics as NSString).size(withAttributes: mAttrs).width
                metricsX = right2 - w
                (c.metrics as NSString).draw(at: NSPoint(x: metricsX, y: r.minY + 40), withAttributes: mAttrs)
            }
            if !c.subtitle.isEmpty {
                (c.subtitle as NSString).draw(
                    in: NSRect(x: x0, y: r.minY + 39, width: max(metricsX - 6 - x0, 20), height: 13),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                                     .foregroundColor: dim, .paragraphStyle: p])
            }
        }
    }

    /// One tint per model family, matching the pad.
    static func modelColor(_ model: String) -> NSColor {
        switch model {
        case "Opus": return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case "Sonnet": return NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)
        case "Haiku": return NSColor(srgbRed: 0.35, green: 0.75, blue: 0.45, alpha: 1)
        default: return NSColor(srgbRed: 0.6, green: 0.55, blue: 0.75, alpha: 1)
        }
    }

    private func drawCard(_ card: NotchStrip.Card) {
        // Everything sits BELOW the housing. The band above it is plate only —
        // there is no display behind the camera, so anything drawn there lands
        // in the framebuffer and never on the glass.
        var textRect = cardTextRect
        let accentBar = NSRect(x: 14, y: notchHeight + 10, width: 3, height: textRect.height - 4)
        card.accent.setFill()
        NSBezierPath(roundedRect: accentBar, xRadius: 1.5, yRadius: 1.5).fill()
        textRect.origin.x += 11
        textRect.size.width -= 11

        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        (card.title as NSString).draw(
            in: NSRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: NSColor.white, .paragraphStyle: p])
        (card.subtitle as NSString).draw(
            in: NSRect(x: textRect.minX, y: textRect.minY + 18, width: textRect.width, height: 15),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.6),
                             .paragraphStyle: p])

        let buttons = actionRects
        for (i, action) in card.actions.enumerated() where i < buttons.count {
            let r = buttons[i]
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            (action.tint ?? NSColor.white).withAlphaComponent(action.tint == nil ? 0.14 : 0.85).setFill()
            path.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
            let size = (action.glyph as NSString).size(withAttributes: attrs)
            (action.glyph as NSString).draw(at: NSPoint(x: r.midX - size.width / 2,
                                                       y: r.midY - size.height / 2),
                                            withAttributes: attrs)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func hit(_ event: NSEvent) -> NotchStrip.Placed? {
        let p = convert(event.locationInWindow, from: nil)
        return placed.first { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }
    }

    /// Marks move when the window resizes, so the hover index has to go with it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hovered = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if !picker.isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            let t = picker.indices.first { tileRect($0).contains(p) }
            if t != hoveredTile { hoveredTile = t; needsDisplay = true }
            return
        }
        if moduleHeight > 0 {
            let p = convert(event.locationInWindow, from: nil)
            var h: Int?
            if tabRect(-1).contains(p) { h = -1 }
            else { h = tabs.indices.first { tabRect($0).contains(p) } }
            if h != hoveredTab { hoveredTab = h; needsDisplay = true }
            return
        }
        if listMode, !cards.isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            let row = (0..<visibleRows).first { rowRect($0).insetBy(dx: -4, dy: 0).contains(p) }
            let act = rowActionRects.first { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }
            let newAct = act.map { (row: $0.row, index: $0.index) }
            if row != hoveredRow || newAct?.row != hoveredAction?.row
                || newAct?.index != hoveredAction?.index {
                hoveredRow = row
                hoveredAction = newAct
                needsDisplay = true
            }
            return
        }
        let layout = placed
        let h = hit(event)
        let idx = h.flatMap { x in layout.firstIndex { $0.source == x.source && $0.mark == x.mark } }
        if idx != hovered {
            hovered = idx
            needsDisplay = true
        }
        if let h { onHover?(h) }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        // A resize rebuilds the tracking area and fires an exit whose location
        // is still inside us — that is not a leave. A real leave lands outside
        // the bounds. Only the latter should fold the row away.
        let p = convert(event.locationInWindow, from: nil)
        onExit?(!bounds.contains(p))
    }

    override func mouseDown(with event: NSEvent) {
        if !picker.isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            if let t = picker.indices.first(where: { tileRect($0).contains(p) }) {
                onClick?(NotchStrip.Placed(source: 0, mark: t, rect: tileRect(t)))
            }
            return
        }
        if moduleHeight > 0 {
            // The tab row belongs to the strip; everything below it is the
            // module's own business.
            let p = convert(event.locationInWindow, from: nil)
            if tabRect(-1).contains(p) { onModuleTab?(-1); return }
            if let i = tabs.indices.first(where: { tabRect($0).contains(p) }) {
                onModuleTab?(i)
            }
            return
        }
        if listMode, !cards.isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            // A ✓/✕ answers in place; anywhere else on the row opens the pad.
            if let hit = rowActionRects.first(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }),
               hit.row < cards.count, hit.index < cards[hit.row].actions.count {
                cards[hit.row].actions[hit.index].run()
                return
            }
            if let row = (0..<visibleRows).first(where: { rowRect($0).insetBy(dx: -4, dy: 0).contains(p) }) {
                onClick?(NotchStrip.Placed(source: listSource, mark: row, rect: rowRect(row)))
            }
            return
        }
        if card != nil {
            let p = convert(event.locationInWindow, from: nil)
            if let card, let i = actionRects.firstIndex(where: { $0.contains(p) }),
               i < card.actions.count {
                card.actions[i].run()
                onExit?(true)   // acted on the card — close, as before
                return
            }
            return
        }
        onClick?(hit(event))
    }
}


/// Menu items need an @objc target. A closure box is cheaper than teaching
/// AppController a selector per item.
final class NotchMenuTarget: NSObject {
    private let run: (String) -> Void
    init(_ run: @escaping (String) -> Void) { self.run = run }
    @objc func fire(_ sender: NSMenuItem) {
        run((sender.representedObject as? String) ?? "")
    }
}
