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
    }

    /// The Mid state, and the whole reason Mid exists: a permission ask is
    /// notification-shaped, so it gets a notification, with the answer on it.
    struct Card {
        var title: String
        var subtitle: String
        var accent: NSColor
        /// At most two — ✓ / ✕. More than that is a panel, and panels are Max.
        var actions: [(glyph: String, tint: NSColor?, run: () -> Void)] = []
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

    /// Where a mark ends up, in view coordinates. One array, read by BOTH
    /// `draw` and `mouseDown` — the pads recompute this in two places and the
    /// two drifting apart is exactly how a click lands on the wrong row.
    struct Placed {
        let source: Int
        let mark: Int
        let rect: NSRect
    }

    enum Mode: Equatable {
        case min
        case mid(source: Int, mark: Int)
    }

    private var panel: NSPanel?
    private var view: NotchStripView?
    private var sources: [Source] = []
    private var timer: Timer?
    private var midTimer: Timer?
    private(set) var mode: Mode = .min
    /// Which source ids the user has switched on, plus the master toggle.
    private var enabledIDs: Set<String> = []
    private var masterOn = true
    /// Sessions already announced with a Mid card, so a permission that stays
    /// on screen doesn't re-present the banner on every 10s refresh.
    private var announced: Set<String> = []

    var onLog: ((String) -> Void)?

    // MARK: Registration and config

    func register(_ source: Source) {
        sources.append(source)
        sources.sort { $0.priority < $1.priority }
    }

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
        guard let screen = notchScreen, live.contains(where: { !$0.isEmpty }) else {
            teardown()
            return
        }
        let field = PadDock.Field(screen: screen)
        build(on: screen)
        // A Mid card whose source or mark has gone away falls back to Min.
        if case let .mid(si, mi) = mode, si >= live.count || mi >= live[si].count {
            mode = .min
        }
        var card: Card?
        if case let .mid(si, mi) = mode, si < activeSources.count {
            card = activeSources[si].card(mi)
            if card == nil { mode = .min }
        }
        view?.configure(groups: live, card: card, field: field)
        place(field: field, animated: true)
    }

    // MARK: Window

    private func build(on screen: NSScreen) {
        if panel != nil { return }
        let v = NotchStripView()
        v.onHover = { [weak self] hit in self?.hover(hit) }
        v.onExit = { [weak self] in self?.collapse() }
        v.onClick = { [weak self] hit in self?.click(hit) }
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
        startTimer()
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        midTimer?.invalidate(); midTimer = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
        mode = .min
    }

    private func startTimer() {
        timer?.invalidate()
        // Only while the strip is actually up, same guard the pads use — and
        // note this tick never triggers a quota FETCH, only a redraw of the
        // snapshot. A fetch shells out for ~45s; polling it on a timer would
        // mean burning quota to measure quota, forever.
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

    private func hover(_ hit: Placed?) {
        guard let hit else { return }
        guard case .min = mode else { return }
        open(source: hit.source, mark: hit.mark, hold: nil)
    }

    private func click(_ hit: Placed?) {
        guard let hit, hit.source < activeSources.count else { return }
        // Click is the way OUT of the notch: the owning feature opens its own
        // window, and the strip drops back to a glance.
        collapse()
        activeSources[hit.source].activate(hit.mark)
    }

    /// Present a card. `hold` auto-collapses after that many seconds — used by
    /// the permission banner, which has to stand on its own without a cursor.
    func open(source: Int, mark: Int, hold: TimeInterval?) {
        guard source < activeSources.count, activeSources[source].card(mark) != nil else { return }
        mode = .mid(source: source, mark: mark)
        midTimer?.invalidate(); midTimer = nil
        if let hold {
            midTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.collapse() }
            }
        }
        refresh()
    }

    func collapse() {
        midTimer?.invalidate(); midTimer = nil
        guard mode != .min else { return }
        mode = .min
        refresh()
    }

    /// Announce a session that wants an answer, once. Replaces flinging the
    /// whole Agent Pad open — this is smaller, carries ✓/✕ itself, and gets out
    /// of the way on its own.
    func announce(sessionID: String, source id: String, mark: Int, hold: TimeInterval = 6) {
        guard !announced.contains(sessionID),
              let si = activeSources.firstIndex(where: { $0.id == id }) else { return }
        announced.insert(sessionID)
        open(source: si, mark: mark, hold: hold)
    }

    /// Forget sessions that are no longer waiting, so the SAME session asking
    /// again later still gets a banner.
    func forgetAnnounced(keeping live: Set<String>) {
        announced.formIntersection(live)
    }

    // MARK: Test hooks

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
    var onExit: (() -> Void)?
    var onClick: ((NotchStrip.Placed?) -> Void)?

    private var groups: [[NotchStrip.Mark]] = []
    private var card: NotchStrip.Card?
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

    func configure(groups: [[NotchStrip.Mark]], card: NotchStrip.Card?, field: PadDock.Field) {
        self.groups = groups
        self.card = card
        self.notchSpan = field.notch.width
        self.notchHeight = field.notch.height
        self.maxWidth = field.visible.width - PadDock.margin * 2
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

    override var fittingSize: NSSize {
        if card != nil { return NSSize(width: midWidth, height: midHeight) }
        return NSSize(width: leadFlank + notchSpan + trailFlank,
                      height: max(notchHeight, NotchStrip.dot + NotchStrip.pad * 2))
    }

    /// Where the window goes. The view owns this because only it knows how wide
    /// each shoulder came out. Min hangs off the housing shoulder-by-shoulder;
    /// Mid is centred on the housing. Both are flush with the top of the screen.
    func targetFrame(in field: PadDock.Field) -> NSRect {
        let size = fittingSize
        let x = card == nil ? field.notch.minX - leadFlank
                            : field.notch.midX - size.width / 2
        let clamped = min(max(x, field.visible.minX), max(field.visible.maxX - size.width, field.visible.minX))
        return NSRect(x: clamped, y: field.notch.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Marks laid out around the housing. Whole groups only — splitting one
    /// source across the cutout would make it impossible to tell whose dot is
    /// whose, which is the entire point of grouping them.
    private func computePlacement() -> [NotchStrip.Placed] {
        guard card == nil, !groups.isEmpty else { return [] }
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
    var contentRects: [NSRect] {
        card == nil ? placed.map(\.rect) : ([cardTextRect] + actionRects)
    }

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
    private func shellClip(radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 0, y: -radius, width: bounds.width,
                                         height: bounds.height + radius),
                     xRadius: radius, yRadius: radius)
    }

    override func draw(_ dirtyRect: NSRect) {
        shellClip(radius: card == nil ? 12 : 18).setClip()
        // The housing's own black, in every appearance — the camera is black on
        // every Mac, so matching it is what makes the two read as one shape.
        NSColor(white: 0.04, alpha: 0.97).setFill()
        bounds.fill()

        if let card {
            drawCard(card)
            return
        }
        let layout = placed
        for (idx, p) in layout.enumerated() {
            guard p.source < groups.count, p.mark < groups[p.source].count else { continue }
            let mark = groups[p.source][p.mark]
                let alpha: CGFloat = mark.dim ? 0.35 : 0.9
                let lit = hovered == idx
                mark.color.withAlphaComponent(lit ? 1 : alpha).setFill()
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
        onExit?()
    }

    override func mouseDown(with event: NSEvent) {
        if card != nil {
            let p = convert(event.locationInWindow, from: nil)
            if let card, let i = actionRects.firstIndex(where: { $0.contains(p) }),
               i < card.actions.count {
                card.actions[i].run()
                onExit?()
                return
            }
            return
        }
        onClick?(hit(event))
    }
}
