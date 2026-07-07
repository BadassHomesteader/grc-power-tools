import Cocoa
import ApplicationServices

/// Moom-style snap palette: hold hotkey + W → a compact panel of window targets.
/// Row 1: Fill + four halves (hold ⌥: Center + four quarters). Row 2: thirds.
/// Below: a mini-grid — drag across it to sketch any rectangle without leaving
/// the palette. Highlighting a button previews the landing rect on the real
/// screen; digits/click/Return apply; Tab retargets another display.
@MainActor
final class WindowPalette {
    private var window: NSWindow?
    private weak var paletteView: WindowPaletteView?
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private let preview = SnapPreviewPanel()

    var isVisible: Bool { window != nil }

    /// `target`: the AX window captured before the palette stole focus.
    /// `done`: always called (apply or cancel) so the caller can refocus the app.
    /// `layouts`: up to 3 saved-layout chips (A/B/C restore, S saves current).
    func present(dark: Bool, gridCols: Int, gridRows: Int,
                 target: AXUIElement, screen: NSScreen,
                 layouts: [(entry: LayoutEntry, label: String)] = [],
                 onSaveLayout: (() -> Void)? = nil,
                 onRestoreLayout: ((LayoutEntry) -> Void)? = nil,
                 done: @escaping () -> Void) {
        dismiss()
        let view = WindowPaletteView(dark: dark, gridCols: gridCols, gridRows: gridRows,
                                     screens: NSScreen.screens, initialScreen: screen)
        view.layouts = layouts
        view.onSaveLayout = { [weak self] in self?.dismiss(); onSaveLayout?() }
        view.onRestoreLayout = { [weak self] entry in self?.dismiss(); onRestoreLayout?(entry) }
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)

        view.onApply = { [weak self] norm, targetScreen in
            self?.preview.hide()
            self?.dismiss()
            WindowManager.setWindow(target, cocoaFrame: Self.cocoaRect(norm, on: targetScreen))
            done()
        }
        view.onCancel = { [weak self] in
            self?.dismiss()
            done()
        }
        view.onPreview = { [weak self] norm, targetScreen in
            guard let self else { return }
            if let norm {
                self.preview.show(rect: Self.cocoaRect(norm, on: targetScreen), below: self.window)
            } else {
                self.preview.hide()
            }
        }

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
        win.contentView = view
        window = win
        paletteView = view
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)

        // Borderless windows don't always hold key focus — a local monitor catches
        // digits/arrows/Esc regardless (same pattern as Advanced Paste).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
            guard let self, self.window != nil, let view else { return event }
            return view.handleKey(event) ? nil : event
        }
        // ⌥ swaps row 1 between halves and quarters — live, whether ⌥ is part of a
        // still-held leader (Option+Shift) or pressed on its own later.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self, weak view] event in
            guard self?.window != nil, let view else { return event }
            view.setQuarters(event.modifierFlags.contains(.option))
            return event
        }
        view.setQuarters(NSEvent.modifierFlags.contains(.option))
    }

    /// Arrows/Return forwarded by AppController while the leader is still held —
    /// the event tap swallows those keys, so the local monitor never sees them.
    func leaderKey(_ move: WindowManager.Move) {
        guard let view = paletteView else { return }
        switch move {
        case .maximize: view.applyHighlighted()
        case .left:     view.nudgeHighlight(dc: -1, dr: 0)
        case .right:    view.nudgeHighlight(dc: 1, dr: 0)
        case .up:       view.nudgeHighlight(dc: 0, dr: -1)
        case .down:     view.nudgeHighlight(dc: 0, dr: 1)
        }
    }

    /// A digit the event tap consumed itself (only "3", the grid chord) while the
    /// palette is open — treat it as the palette digit it was meant to be.
    func applyDigit(_ digit: String) {
        paletteView?.applyDigit(digit)
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        preview.hide()
        window?.orderOut(nil)
        window = nil
        paletteView = nil
    }

    /// Normalized (top-left origin) rect → global bottom-left rect on `screen`.
    static func cocoaRect(_ n: NSRect, on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        return NSRect(x: vf.minX + n.minX * vf.width,
                      y: vf.minY + (1 - n.minY - n.height) * vf.height,
                      width: n.width * vf.width,
                      height: n.height * vf.height)
    }
}

/// Click-through outline showing where the window WILL land while you browse the
/// palette (the "refined Moom feel": see it before you commit).
@MainActor
final class SnapPreviewPanel {
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = SnapPreviewView()
    }

    /// `below` keeps the outline under the palette so its buttons stay readable
    /// when the target rect (e.g. Fill) covers the palette itself.
    func show(rect: NSRect, below window: NSWindow?) {
        panel.setFrame(rect, display: true)
        if let window {
            panel.order(.below, relativeTo: window.windowNumber)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() { panel.orderOut(nil) }
}

final class SnapPreviewView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)
        let r = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        accent.withAlphaComponent(0.16).setFill()
        path.fill()
        accent.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }
}

/// The palette canvas: two rows of snap-target buttons drawn as mini window
/// diagrams (not text — instantly readable), then a mini-grid drag area.
final class WindowPaletteView: NSView {
    struct Action {
        let key: String       // digit that applies it
        let title: String
        let region: NSRect    // normalized, top-left origin (WindowDiagramView convention)
    }

    private let dark: Bool
    private let gridCols: Int
    private let gridRows: Int
    private let screens: [NSScreen]
    private var screenIndex: Int

    /// Applied rect (normalized top-left) + the display it targets.
    var onApply: ((NSRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    /// Live preview: nil hides the outline.
    var onPreview: ((NSRect?, NSScreen) -> Void)?
    /// Saved layouts: chips A/B/C restore, S saves the current arrangement.
    var layouts: [(entry: LayoutEntry, label: String)] = []
    var onSaveLayout: (() -> Void)?
    var onRestoreLayout: ((LayoutEntry) -> Void)?

    private var quarters = false
    private var highlighted = 0
    private var gridStart: (c: Int, r: Int)?
    private var gridCurrent: (c: Int, r: Int)?

    private static let width: CGFloat = 500
    private static let pad: CGFloat = 14
    private static let headerH: CGFloat = 42
    private static let perRow = 6
    private static let btnW: CGFloat = 72
    private static let btnH: CGFloat = 58
    private static let btnGap: CGFloat = 8
    private static let gridGap: CGFloat = 10
    private static let gridAreaH: CGFloat = 185
    private static let layoutsH: CGFloat = 36
    private static let footerH: CGFloat = 28

    init(dark: Bool, gridCols: Int, gridRows: Int, screens: [NSScreen], initialScreen: NSScreen) {
        self.dark = dark
        self.gridCols = gridCols
        self.gridRows = gridRows
        self.screens = screens.isEmpty ? [initialScreen] : screens
        self.screenIndex = screens.firstIndex(of: initialScreen) ?? 0
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var fittingSize: NSSize {
        NSSize(width: Self.width,
               height: Self.headerH + Self.btnH * 2 + Self.btnGap + Self.gridGap + Self.gridAreaH + Self.layoutsH + Self.footerH)
    }

    private var targetScreen: NSScreen { screens[min(screenIndex, screens.count - 1)] }

    // Same palette as AdvancedPasteView so the two feel like one system.
    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    // MARK: Actions

    private var row1: [Action] {
        quarters
        ? [Action(key: "1", title: "Fill", region: NSRect(x: 0, y: 0, width: 1, height: 1)),
           Action(key: "2", title: "Top Left", region: NSRect(x: 0, y: 0, width: 0.5, height: 0.5)),
           Action(key: "3", title: "Top Right", region: NSRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
           Action(key: "4", title: "Btm Left", region: NSRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
           Action(key: "5", title: "Btm Right", region: NSRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
           Action(key: "6", title: "Center", region: NSRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))]
        : [Action(key: "1", title: "Fill", region: NSRect(x: 0, y: 0, width: 1, height: 1)),
           Action(key: "2", title: "Left ½", region: NSRect(x: 0, y: 0, width: 0.5, height: 1)),
           Action(key: "3", title: "Center ½", region: NSRect(x: 0.25, y: 0, width: 0.5, height: 1)),
           Action(key: "4", title: "Right ½", region: NSRect(x: 0.5, y: 0, width: 0.5, height: 1)),
           Action(key: "5", title: "Top ½", region: NSRect(x: 0, y: 0, width: 1, height: 0.5)),
           Action(key: "6", title: "Bottom ½", region: NSRect(x: 0, y: 0.5, width: 1, height: 0.5))]
    }

    private var row2: [Action] {
        let t = 1.0 / 3.0
        return [Action(key: "7", title: "Fill", region: NSRect(x: 0, y: 0, width: 1, height: 1)),
                Action(key: "8", title: "Left ⅓", region: NSRect(x: 0, y: 0, width: t, height: 1)),
                Action(key: "9", title: "Center ⅓", region: NSRect(x: t, y: 0, width: t, height: 1)),
                Action(key: "0", title: "Right ⅓", region: NSRect(x: 2 * t, y: 0, width: t, height: 1)),
                Action(key: "-", title: "Left ⅔", region: NSRect(x: 0, y: 0, width: 2 * t, height: 1)),
                Action(key: "=", title: "Right ⅔", region: NSRect(x: t, y: 0, width: 2 * t, height: 1))]
    }

    private var actions: [Action] { row1 + row2 }

    // MARK: Layout

    private func buttonRect(_ i: Int) -> NSRect {
        let row = i / Self.perRow, col = i % Self.perRow
        return NSRect(x: Self.pad + CGFloat(col) * (Self.btnW + Self.btnGap),
                      y: Self.headerH + CGFloat(row) * (Self.btnH + Self.btnGap),
                      width: Self.btnW, height: Self.btnH)
    }

    private var gridAreaRect: NSRect {
        NSRect(x: Self.pad,
               y: Self.headerH + Self.btnH * 2 + Self.btnGap + Self.gridGap,
               width: Self.width - Self.pad * 2, height: Self.gridAreaH)
    }

    /// The drawable mini-grid, aspect-fit to the target display inside its area
    /// so the sketch is a faithful miniature of that screen.
    private var gridRect: NSRect {
        let area = gridAreaRect
        let vf = targetScreen.visibleFrame
        let aspect = vf.width / max(vf.height, 1)
        var w = area.width, h = w / aspect
        if h > area.height { h = area.height; w = h * aspect }
        return NSRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    private var cellW: CGFloat { gridRect.width / CGFloat(gridCols) }
    private var cellH: CGFloat { gridRect.height / CGFloat(gridRows) }

    private func gridCell(at p: NSPoint) -> (c: Int, r: Int) {
        let g = gridRect
        let c = min(max(Int((p.x - g.minX) / cellW), 0), gridCols - 1)
        let r = min(max(Int((p.y - g.minY) / cellH), 0), gridRows - 1)
        return (c, r)
    }

    private func gridNormRect() -> NSRect? {
        guard let a = gridStart, let b = gridCurrent else { return nil }
        let minC = min(a.c, b.c), maxC = max(a.c, b.c)
        let minR = min(a.r, b.r), maxR = max(a.r, b.r)
        return NSRect(x: CGFloat(minC) / CGFloat(gridCols),
                      y: CGFloat(minR) / CGFloat(gridRows),
                      width: CGFloat(maxC - minC + 1) / CGFloat(gridCols),
                      height: CGFloat(maxR - minR + 1) / CGFloat(gridRows))
    }

    /// For the offscreen `palette-preview` design check.
    func previewState(highlight: Int, gridSel: ((Int, Int), (Int, Int))? = nil, quarters: Bool = false) {
        highlighted = highlight
        self.quarters = quarters
        if let g = gridSel {
            gridStart = (c: g.0.0, r: g.0.1)
            gridCurrent = (c: g.1.0, r: g.1.1)
        }
        needsDisplay = true
    }

    // MARK: Interaction

    func setQuarters(_ on: Bool) {
        guard quarters != on else { return }
        quarters = on
        needsDisplay = true
        if highlighted < Self.perRow { previewHighlighted() }
    }

    func nudgeHighlight(dc: Int, dr: Int) {
        var row = highlighted / Self.perRow, col = highlighted % Self.perRow
        col = min(max(col + dc, 0), Self.perRow - 1)
        row = min(max(row + dr, 0), 1)
        setHighlight(row * Self.perRow + col)
    }

    func applyHighlighted() {
        onApply?(actions[highlighted].region, targetScreen)
    }

    func applyDigit(_ digit: String) {
        if let a = actions.first(where: { $0.key == digit }) {
            onApply?(a.region, targetScreen)
        }
    }

    private func setHighlight(_ i: Int) {
        guard i != highlighted else { return }
        highlighted = i
        needsDisplay = true
        previewHighlighted()
    }

    private func previewHighlighted() {
        onPreview?(actions[highlighted].region, targetScreen)
    }

    private func cycleDisplay() {
        guard screens.count > 1 else { return }
        screenIndex = (screenIndex + 1) % screens.count
        needsDisplay = true
        previewHighlighted()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = actions.indices.first(where: { buttonRect($0).contains(p) }) {
            onApply?(actions[i].region, targetScreen)
            return
        }
        if let i = layoutChipRects.indices.first(where: { layoutChipRects[$0].contains(p) }) {
            onRestoreLayout?(layouts[i].entry)
            return
        }
        if saveChipRect.contains(p) {
            onSaveLayout?()
            return
        }
        if gridRect.contains(p) {
            gridStart = gridCell(at: p)
            gridCurrent = gridStart
            needsDisplay = true
            if let n = gridNormRect() { onPreview?(n, targetScreen) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard gridStart != nil else { return }
        gridCurrent = gridCell(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
        if let n = gridNormRect() { onPreview?(n, targetScreen) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let a = gridStart, let b = gridCurrent else { return }
        let norm = gridNormRect()
        gridStart = nil
        gridCurrent = nil
        // A bare click on a single cell is a mis-click, not a placement.
        if a.c == b.c && a.r == b.r {
            needsDisplay = true
            onPreview?(nil, targetScreen)
        } else if let norm {
            onApply?(norm, targetScreen)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = actions.indices.first(where: { buttonRect($0).contains(p) }) {
            setHighlight(i)
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// Returns true if consumed. Called from keyDown AND the local event monitor.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: onCancel?(); return true                                    // esc
        case 36, 76: applyHighlighted(); return true                         // return / enter
        case 48: cycleDisplay(); return true                                 // tab
        case 123: nudgeHighlight(dc: -1, dr: 0); return true                 // ←
        case 124: nudgeHighlight(dc: 1, dr: 0); return true                  // →
        case 125: nudgeHighlight(dc: 0, dr: 1); return true                  // ↓
        case 126: nudgeHighlight(dc: 0, dr: -1); return true                 // ↑
        default:
            if let ch = event.charactersIgnoringModifiers {
                if actions.contains(where: { $0.key == ch }) {
                    applyDigit(ch)
                    return true
                }
                let upper = ch.uppercased()
                if upper == "S" {
                    onSaveLayout?()
                    return true
                }
                if let i = Self.chipKeys.firstIndex(of: upper), i < layouts.count {
                    onRestoreLayout?(layouts[i].entry)
                    return true
                }
            }
            return false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).setClip()
        bg.setFill()
        bounds.fill()

        // Header: title left; display target right (only when there's a choice).
        ("Move & size" as NSString).draw(at: NSPoint(x: Self.pad + 6, y: 13),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: fg])
        if screens.count > 1 {
            let label = "⇥ Display \(screenIndex + 1) of \(screens.count)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: dim]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - Self.pad - 6 - size.width, y: 16), withAttributes: attrs)
        }

        for (i, action) in actions.enumerated() {
            drawButton(action, in: buttonRect(i), highlighted: i == highlighted)
        }

        drawGrid()
        drawLayoutChips()

        let tabHint = screens.count > 1 ? " · ⇥ display" : ""
        let footer = "keys or click · ⌥ quarters\(tabHint) · esc" as NSString
        footer.draw(at: NSPoint(x: Self.pad + 6, y: bounds.height - 21),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim])
    }

    /// A button is a mini window diagram (screen outline + filled target region),
    /// with its digit badged in the corner and a small caption below.
    private func drawButton(_ action: Action, in rect: NSRect, highlighted: Bool) {
        if highlighted {
            accent.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        } else {
            (dark ? NSColor.white : .black).withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        }
        let mainColor = highlighted ? NSColor.white : fg
        let regionFill = highlighted ? NSColor.white : accent

        // Diagram: 44×26 centered near the top.
        let box = NSRect(x: rect.midX - 22, y: rect.minY + 7, width: 44, height: 26)
        let outline = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        mainColor.withAlphaComponent(0.45).setStroke()
        outline.lineWidth = 1.5
        outline.stroke()
        let r = NSRect(x: box.minX + action.region.minX * box.width,
                       y: box.minY + action.region.minY * box.height,
                       width: action.region.width * box.width,
                       height: action.region.height * box.height).insetBy(dx: 1.5, dy: 1.5)
        regionFill.setFill()
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()

        // Caption.
        let caption = action.title as NSString
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: highlighted ? NSColor.white.withAlphaComponent(0.9) : dim,
        ]
        let capSize = caption.size(withAttributes: capAttrs)
        caption.draw(at: NSPoint(x: rect.midX - capSize.width / 2, y: rect.maxY - 17), withAttributes: capAttrs)

        // Digit badge, top-left.
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: highlighted ? NSColor.white.withAlphaComponent(0.85) : dim,
        ]
        (action.key as NSString).draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 4), withAttributes: badgeAttrs)
    }

    // MARK: Saved-layout chips

    private static let chipKeys = ["A", "B", "C"]
    private var layoutChipRects: [NSRect] = []
    private var saveChipRect: NSRect = .zero

    private var layoutsRowRect: NSRect {
        NSRect(x: Self.pad,
               y: Self.headerH + Self.btnH * 2 + Self.btnGap + Self.gridGap + Self.gridAreaH + 6,
               width: Self.width - Self.pad * 2, height: Self.layoutsH - 12)
    }

    private func drawLayoutChips() {
        let row = layoutsRowRect
        layoutChipRects = []
        var x = row.minX + 6
        let h = row.height
        let chipAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: fg]
        let keyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: dim]

        func chip(_ key: String, _ label: String, emphasized: Bool) -> NSRect {
            let text = label as NSString
            let tw = text.size(withAttributes: chipAttrs).width
            let kw = (key as NSString).size(withAttributes: keyAttrs).width
            let rect = NSRect(x: x, y: row.minY, width: kw + tw + 26, height: h)
            (dark ? NSColor.white : .black).withAlphaComponent(emphasized ? 0.1 : 0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            (key as NSString).draw(at: NSPoint(x: rect.minX + 9, y: rect.midY - 6), withAttributes: keyAttrs)
            text.draw(at: NSPoint(x: rect.minX + 9 + kw + 6, y: rect.midY - 7), withAttributes: chipAttrs)
            x = rect.maxX + 8
            return rect
        }

        for (i, l) in layouts.prefix(3).enumerated() {
            layoutChipRects.append(chip(Self.chipKeys[i], l.label, emphasized: true))
        }
        saveChipRect = chip("S", layouts.isEmpty ? "save this window layout" : "save layout", emphasized: false)
    }

    private func drawGrid() {
        let g = gridRect
        // Backing card so the grid reads as one interactive area.
        (dark ? NSColor.white : .black).withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: g.insetBy(dx: -4, dy: -4), xRadius: 9, yRadius: 9).fill()

        fg.withAlphaComponent(0.18).setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = 1
        for c in 0...gridCols {
            let x = g.minX + CGFloat(c) * cellW
            lines.move(to: NSPoint(x: x, y: g.minY))
            lines.line(to: NSPoint(x: x, y: g.maxY))
        }
        for r in 0...gridRows {
            let y = g.minY + CGFloat(r) * cellH
            lines.move(to: NSPoint(x: g.minX, y: y))
            lines.line(to: NSPoint(x: g.maxX, y: y))
        }
        lines.stroke()

        if let norm = gridNormRect() {
            let sel = NSRect(x: g.minX + norm.minX * g.width,
                             y: g.minY + norm.minY * g.height,
                             width: norm.width * g.width,
                             height: norm.height * g.height)
            accent.withAlphaComponent(0.35).setFill()
            let path = NSBezierPath(roundedRect: sel.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
            path.fill()
            accent.setStroke()
            path.lineWidth = 2
            path.stroke()
        } else {
            let hint = "drag to place · \(gridCols)×\(gridRows)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: dim.withAlphaComponent(0.35)]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: g.midX - size.width / 2, y: g.maxY - 18), withAttributes: attrs)
        }
    }
}
