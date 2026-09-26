import Cocoa

/// The Macro Pad as a ring, summoned under the cursor by the hotkey + a
/// THREE-finger tap (four still brings the board).
///
/// Why a ring at all: the summoned pad is fire-once at the cursor, which is the
/// Power Ring's interaction exactly — every target the same distance from the
/// pointer, so you learn a DIRECTION instead of a position. What stopped the
/// ring before was the count: a flat ring caps at eight and an Outlook profile
/// has more, all of them folders wearing the same glyph.
///
/// Two levels fix that. The inner ring is the pad's COLUMNS — Move, Actions,
/// Favorites — so the first flick picks a kind of thing, and only that column's
/// buttons open around it. Nine buttons stop competing for eight sectors, and
/// the sector you want is a direction you can learn.
@MainActor final class MacroRing {
    private var panel: NSPanel?
    private var view: MacroRingView?

    /// Fires the chosen button, exactly as the pad's own tap does.
    var onAction: ((Config.MacroButton) -> Void)?
    /// The Move column is a search box, which a ring cannot hold — choosing it
    /// hands off to the board at the same spot.
    var onWantsBoard: (() -> Void)?
    var onVisibility: ((Bool) -> Void)?
    /// How many digits are live right now: 0 on the inner ring, the open
    /// column's size once one is open.
    var onDigitCount: ((Int) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(appName: String, buttons: [Config.MacroButton], moveSearch: Bool, at cursor: NSPoint) {
        dismiss()
        let v = MacroRingView(appName: appName, buttons: buttons, moveSearch: moveSearch)
        v.onPick = { [weak self] button in
            guard let self else { return }
            self.dismiss()
            self.onAction?(button)
        }
        v.onPickBoard = { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.onWantsBoard?()
        }
        v.onClose = { [weak self] in self?.dismiss() }
        v.onLevelChange = { [weak self] count in self?.onDigitCount?(count) }

        let size = v.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        // Centre it on the pointer, then pull it back on screen near an edge —
        // a ring half off the display is a ring you cannot aim at.
        var origin = NSPoint(x: cursor.x - size.width / 2, y: cursor.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        v.frame = NSRect(origin: .zero, size: size)
        // THE DIAL IS DRAWN AROUND THE POINTER, NOT THE PANEL. Clamping a
        // 520pt panel on screen moves its centre away from the cursor — summon
        // near the top of the display and the pointer ends up ABOVE the middle,
        // so the ring reads "up" before a flick happens and fires whatever
        // sector lives there. Handing the cursor's position in view coordinates
        // keeps the directions honest wherever the panel had to sit.
        v.hub = NSPoint(x: cursor.x - origin.x, y: cursor.y - origin.y)

        let win = NSPanel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false          // the buttons carry their own shadows
        win.ignoresMouseEvents = false
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = v
        panel = win
        view = v
        win.orderFrontRegardless()
        onVisibility?(true)
        onDigitCount?(0)          // the inner ring has nothing to fire yet
    }

    func dismiss() {
        guard panel != nil else { return }
        panel?.orderOut(nil)
        panel = nil
        view = nil
        onDigitCount?(0)
        onVisibility?(false)
    }

    /// hold + digit while the ring is up fires that button, like the pad.
    func fireDigit(_ index: Int) {
        view?.fireDigit(index)
    }
}

final class MacroRingView: NSView {
    private let appName: String
    private let groups: [(title: String, buttons: [Config.MacroButton])]
    private let moveSearch: Bool

    var onPick: ((Config.MacroButton) -> Void)?
    var onLevelChange: ((Int) -> Void)?
    var onPickBoard: (() -> Void)?
    var onClose: (() -> Void)?

    /// nil = the inner ring; otherwise the group whose buttons are showing.
    /// Three-Finger Drag is on for some people, and a quick three-finger tap
    /// can ride along with a synthetic click. The ring appears UNDER the
    /// cursor, so that click would land on a sector the instant it opened —
    /// the Power Ring learned this the same way. Ignore clicks for a moment.
    private let bornAt = Date()
    private var settled: Bool { Date().timeIntervalSince(bornAt) > 0.35 }

    /// Where the pointer was when the ring opened, in view coordinates — the
    /// dial's real centre. Defaults to the middle for offscreen previews.
    var hub: NSPoint? {
        didSet { needsDisplay = true }
    }

    private var openGroup: Int?
    private var hoveredInner: Int?
    private var hoveredOuter: Int?
    private var innerRects: [NSRect] = []
    private var outerRects: [NSRect] = []
    private var closeRect = NSRect.zero

    private static let innerRadius: CGFloat = 78
    private static let outerRadius: CGFloat = 150
    private static let button: CGFloat = 54
    private static let canvas: CGFloat = 520

    private let accent = NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)
    private let plate = NSColor(white: 0.10, alpha: 0.97)
    private let dim = NSColor.white.withAlphaComponent(0.55)

    init(appName: String, buttons: [Config.MacroButton], moveSearch: Bool) {
        self.appName = appName
        self.moveSearch = moveSearch
        // The pad's own columns, so the ring and the board group identically.
        let cols = PadColumns.columns(for: buttons).columns
        var g: [(String, [Config.MacroButton])] = []
        // Move rides first — it is the search, the way out to any folder at all
        // — then the rest, with Favorites last because it is the long one and
        // the straight-down flick is the easiest to repeat.
        if moveSearch { g.append(("Move", [])) }
        for col in cols where col.title.lowercased() != "favorites" {
            g.append((col.title, col.indices.map { buttons[$0] }))
        }
        for col in cols where col.title.lowercased() == "favorites" {
            g.append((col.title, col.indices.map { buttons[$0] }))
        }
        self.groups = g.map { (title: $0.0, buttons: $0.1) }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.canvas, height: Self.canvas))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var fittingSize: NSSize { NSSize(width: Self.canvas, height: Self.canvas) }
    /// Nothing here ever takes key, so the first click has to act.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var centre: NSPoint { hub ?? NSPoint(x: bounds.midX, y: bounds.midY) }

    /// Compass placement: up, right, down, left for the first four, then evenly
    /// around. Up-right-down is what three groups get, which is the whole
    /// point — Move up, Actions right, Favorites down.
    private func angle(_ i: Int, of n: Int) -> CGFloat {
        if n <= 4 {
            return [CGFloat.pi / 2, 0, -CGFloat.pi / 2, CGFloat.pi][i]
        }
        return CGFloat.pi / 2 - (CGFloat(i) / CGFloat(n)) * 2 * .pi
    }

    /// The second level FANS OUT the way you flicked instead of becoming
    /// another full circle. Flick down for Favorites and the folders spread
    /// across the bottom, so the hand keeps going in the direction it already
    /// started — a second ring asks you to come back to the middle and start
    /// again, which is the opposite of what a flick wants.
    private func fanAngles(count: Int, around parent: CGFloat) -> [CGFloat] {
        guard count > 1 else { return [parent] }
        let gap = min(0.44, 2.5 / CGFloat(count - 1))
        let span = gap * CGFloat(count - 1)
        // Laid left to right across the fan, so the digits read in order.
        return (0..<count).map { parent - span / 2 + CGFloat($0) * gap }
    }

    /// Every seat angle for whatever level is showing — one source for drawing
    /// and for aiming, so they cannot disagree.
    private func levelAngles() -> [CGFloat] {
        guard let g = openGroup, g < groups.count else {
            return (0..<groups.count).map { angle($0, of: groups.count) }
        }
        return fanAngles(count: groups[g].buttons.count, around: angle(g, of: groups.count))
    }

    private func seat(_ angle: CGFloat, radius: CGFloat) -> NSRect {
        NSRect(x: centre.x + radius * cos(angle) - Self.button / 2,
               y: centre.y + radius * sin(angle) - Self.button / 2,
               width: Self.button, height: Self.button)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        innerRects = []
        outerRects = []

        // A faint guide ring, so the seats read as one dial rather than loose dots.
        NSColor.white.withAlphaComponent(0.06).setStroke()
        let guideRadius = openGroup == nil ? Self.innerRadius : Self.outerRadius
        let guide = NSBezierPath(ovalIn: NSRect(x: centre.x - guideRadius, y: centre.y - guideRadius,
                                                width: guideRadius * 2, height: guideRadius * 2))
        guide.lineWidth = 1
        guide.stroke()

        // Centre: the app on the way in, a ✕ once something is open.
        closeRect = NSRect(x: centre.x - 24, y: centre.y - 24, width: 48, height: 48)
        plate.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: closeRect).fill()
        if openGroup == nil {
            drawCentred(String(appName.prefix(12)), at: NSPoint(x: centre.x, y: centre.y - 5),
                        size: 10, weight: .semibold, color: dim)
        } else if let g = openGroup, g < groups.count {
            // Where you are, and the way back — one target instead of a ghost
            // seat out on the spoke that nothing could see.
            drawCentred("↩", at: NSPoint(x: centre.x, y: centre.y + 2), size: 13, color: dim)
            drawCentred(groups[g].title.uppercased(), at: NSPoint(x: centre.x, y: centre.y - 15),
                        size: 8, weight: .bold, color: dim.withAlphaComponent(0.7))
        }

        if let g = openGroup, g < groups.count {
            // The column you flicked into, fanned out that same way.
            let items = groups[g].buttons
            for (i, b) in items.enumerated() {
                let r = seat(levelAngles()[i], radius: Self.outerRadius)
                outerRects.append(r)
                drawSeat(r, symbol: MacroPadView.symbolName(for: b), label: b.title,
                         digit: i < 10 ? (i + 1) % 10 : nil,
                         active: hoveredOuter == i, outward: true)
            }
            return
        }

        // First level: the columns.
        for (i, g) in groups.enumerated() {
            let r = seat(angle(i, of: groups.count), radius: Self.innerRadius)
            innerRects.append(r)
            let symbol = g.title.lowercased() == "move" ? "magnifyingglass"
                       : g.title.lowercased() == "favorites" ? "folder" : "bolt"
            let count = g.buttons.isEmpty ? "" : " \(g.buttons.count)"
            drawSeat(r, symbol: symbol, label: g.title + count, digit: nil,
                     active: hoveredInner == i, outward: true)
        }
    }

    private func drawSeat(_ r: NSRect, symbol: String, label: String, digit: Int?,
                          active: Bool, outward: Bool) {
        (active ? accent : plate).setFill()
        let path = NSBezierPath(ovalIn: r)
        path.fill()
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            let icon = img.withSymbolConfiguration(cfg) ?? img
            icon.draw(in: NSRect(x: r.midX - icon.size.width / 2, y: r.midY - icon.size.height / 2,
                                 width: icon.size.width, height: icon.size.height),
                      from: .zero, operation: .sourceOver, fraction: 0.95,
                      respectFlipped: true, hints: nil)
        }
        if let digit {
            let chip = NSRect(x: r.maxX - 16, y: r.minY - 2, width: 16, height: 16)
            NSColor(white: 0.16, alpha: 1).setFill()
            NSBezierPath(ovalIn: chip).fill()
            drawCentred("\(digit)", at: NSPoint(x: chip.midX, y: chip.minY + 3), size: 9,
                        weight: .bold, color: .white)
        }
        // The label rides further out along the same spoke, as a pill — pushed
        // out far enough to CLEAR the seat. A fixed offset works for the up and
        // down spokes and buries the pill in the button on the sideways ones,
        // because a wide pill reaches back along its own axis.
        let dx = r.midX - centre.x, dy = r.midY - centre.y
        let len = max(1, sqrt(dx * dx + dy * dy))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let w = (label as NSString).size(withAttributes: attrs).width
        let pillW = w + 18, pillH: CGFloat = 22
        // How far the pill itself reaches back toward the seat along this spoke.
        let reachBack = abs(dx) / len * pillW / 2 + abs(dy) / len * pillH / 2
        let out = len + Self.button / 2 + reachBack + 8
        let lp = NSPoint(x: centre.x + dx / len * out, y: centre.y + dy / len * out)
        let pill = NSRect(x: lp.x - pillW / 2, y: lp.y - pillH / 2, width: pillW, height: pillH)
        plate.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
        drawCentred(label, at: NSPoint(x: pill.midX, y: pill.minY + 5), size: 11, weight: .semibold)
    }

    private func drawCentred(_ s: String, at p: NSPoint, size: CGFloat,
                             weight: NSFont.Weight = .regular, color: NSColor = .white) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let ns = s as NSString
        ns.draw(at: NSPoint(x: p.x - ns.size(withAttributes: attrs).width / 2, y: p.y),
                withAttributes: attrs)
    }

    // MARK: Aiming

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if openGroup == nil {
            // A flick lands between seats as often as on one, so aim by
            // DIRECTION: the nearest sector wins once you are clear of the hub.
            let hit = sector(at: p, count: groups.count)
            if hit != hoveredInner { hoveredInner = hit; needsDisplay = true }
            if settled, let hit, !innerRects.isEmpty, reach(p) > Self.innerRadius * 0.55 {
                openInner(hit)
            }
        } else {
            let items = groups[openGroup!].buttons
            let hit = items.isEmpty ? nil : sector(at: p, count: items.count)
            if hit != hoveredOuter { hoveredOuter = hit; needsDisplay = true }
        }
    }

    private func reach(_ p: NSPoint) -> CGFloat {
        hypot(p.x - centre.x, p.y - centre.y)
    }

    /// Which seat a point is pointing at, by angle — not by hit-testing the
    /// circle, so the gap between seats still aims somewhere.
    private func sector(at p: NSPoint, count: Int) -> Int? {
        let targets = levelAngles()
        guard count > 0, !targets.isEmpty, reach(p) > 26 else { return nil }
        let a = atan2(p.y - centre.y, p.x - centre.x)
        var best: (i: Int, d: CGFloat)?
        for (i, target) in targets.enumerated() where i < count {
            var d = abs(atan2(sin(a - target), cos(a - target)))
            if d > .pi { d = 2 * .pi - d }
            if best == nil || d < best!.d { best = (i, d) }
        }
        // Claim the flick only if it really is near that spoke. A fan's seats
        // sit closer together than a ring's, so the tolerance follows the gap.
        let spread: CGFloat = targets.count > 1
            ? abs(atan2(sin(targets[1] - targets[0]), cos(targets[1] - targets[0]))) / 2 + 0.12
            : .pi
        guard let best, best.d < spread else { return nil }
        return best.i
    }

    private func openInner(_ i: Int) {
        guard i < groups.count else { return }
        if groups[i].buttons.isEmpty {
            // Move: the search box lives on the board, so hand off to it.
            onPickBoard?()
            return
        }
        openGroup = i
        hoveredOuter = nil
        onLevelChange?(groups[i].buttons.count)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard settled else { return }   // the tap's own click, arriving late
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) {
            if openGroup != nil {
                openGroup = nil
                hoveredOuter = nil
                onLevelChange?(0)
                needsDisplay = true
            } else {
                onClose?()
            }
            return
        }
        if let g = openGroup {
            let items = groups[g].buttons
            if let i = sector(at: p, count: items.count), i < items.count { onPick?(items[i]) }
            return
        }
        if let i = sector(at: p, count: groups.count) { openInner(i) }
    }

    /// hold + digit while the ring is open.
    func fireDigit(_ index: Int) {
        guard let g = openGroup, g < groups.count else { return }
        let items = groups[g].buttons
        guard index < items.count else { return }
        onPick?(items[index])
    }

    /// Test hook: open a column the way a flick would.
    func openForTest(_ i: Int) { openInner(i) }

    /// Test hook: which sector a point aims at, and how many groups there are.
    func sectorForTest(_ p: NSPoint) -> Int? { sector(at: p, count: groups.count) }
    var groupTitlesForTest: [String] { groups.map(\.title) }

    /// Preview hook: render the second level without a trackpad.
    func previewOpen(group: Int, hover: Int?) {
        openGroup = group
        hoveredOuter = hover
        needsDisplay = true
    }
}
