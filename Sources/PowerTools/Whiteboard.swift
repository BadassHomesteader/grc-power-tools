import Cocoa

/// Annotation whiteboard (hold hotkey + E): a full-screen dimmed overlay showing
/// the clipboard image (typically the hold + S shot just taken), centered at its
/// physical size. Draw pen / arrow / rect / text over it; ⏎ composites the ink at
/// the image's FULL original pixel resolution and copies the result to the
/// clipboard; Esc cancels. Same KeyableWindow + local-monitor recipe as the grid
/// and Quick Capture, because the text tool puts a field editor in play.
@MainActor
final class Whiteboard {
    private var window: NSWindow?
    private var keyMonitor: Any?

    var isVisible: Bool { window != nil }
    /// Mirrored into HotkeyMonitor.whiteboardVisible so the tap swallows plain
    /// Esc and routes it here even when the field editor (or another display's
    /// app) is first responder.
    var onVisibility: ((Bool) -> Void)?

    /// `onSave` gets the annotated PNG at the source image's pixel dimensions.
    /// One of onSave / onCancel is always called so the caller can refocus.
    func present(png: Data, dark: Bool, screen: NSScreen,
                 onSave: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        guard let view = WhiteboardView(png: png, dark: dark) else { onCancel(); return }
        let sf = screen.frame
        let win = KeyableWindow(contentRect: sf, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.frame = NSRect(origin: .zero, size: sf.size)
        view.onSave = { [weak self] data in self?.dismiss(); onSave(data) }
        view.onCancel = { [weak self] in self?.dismiss(); onCancel() }
        win.contentView = view
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)
        onVisibility?(true)

        // Esc typed into the text tool's field editor doesn't bubble to the view,
        // and the tap can silently die — this monitor is the fallback layer.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
            guard let self, self.window != nil, let view else { return event }
            if event.keyCode == 53 { self.handleEscape(); return nil }  // esc
            if view.isEditingText { return event }  // field editor owns typing (incl. its own ⌘Z)
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "z": view.undo(); return nil
                case "s": view.save(); return nil
                default: return event
                }
            }
            if event.keyCode == 36 || event.keyCode == 76 { view.save(); return nil }  // ⏎ / keypad enter
            if let n = Int(event.charactersIgnoringModifiers ?? ""), (1...4).contains(n) {
                view.selectTool(WBTool(rawValue: n - 1)!)
                return nil
            }
            return event
        }
    }

    /// Every Esc path (tap dispatch, local monitor, field editor) funnels here:
    /// a live text entry is cancelled first; the next Esc closes the board.
    func handleEscape() {
        guard let view = window?.contentView as? WhiteboardView else { return }
        if view.isEditingText { view.cancelActiveText() } else { view.onCancel?() }
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard window != nil else { return }
        window?.orderOut(nil)
        window = nil
        onVisibility?(false)
    }
}

enum WBTool: Int, CaseIterable {
    case pen = 0, arrow, rect, text
    var label: String { ["Pen 1", "Arrow 2", "Rect 3", "Text 4"][rawValue] }
}

/// One annotation, in IMAGE-LOCAL VIEW POINTS: relative to imageRect.origin,
/// unflipped. Export replays these under a scale CTM (pixels ÷ imageRect width),
/// so ink stays vector-crisp at the image's native resolution.
struct WBStroke {
    var tool: WBTool
    var color: NSColor
    var width: CGFloat = 3          // line width in image-local view points
    var points: [NSPoint]           // pen: full path; arrow/rect: [start, end]; text: [origin]
    var text: String = ""           // text tool only
    var fontSize: CGFloat = 18      // text tool only, image-local view points
}

final class WhiteboardView: NSView, NSTextFieldDelegate {
    var onSave: ((Data) -> Void)?
    var onCancel: (() -> Void)?

    private let pngOriginal: Data
    private let image: NSImage             // on-screen draw
    private let srcRep: NSBitmapImageRep   // pixel truth for geometry + export
    private let dark: Bool
    private var strokes: [WBStroke] = []
    private var current: WBStroke?         // in-progress drag
    private var tool: WBTool = .pen
    private var colorIndex = 0
    private var activeText: NSTextField?

    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1),   // red (default)
        NSColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1),     // yellow
        NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1),   // green
        NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1),      // app accent blue
        .white,
    ]
    private static let accent = NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)

    // Geometry, recomputed lazily whenever bounds change.
    private(set) var imageRect: NSRect = .zero
    private enum ToolbarItem { case tool(WBTool), color(Int), undo, save, cancel }
    private var toolbarItems: [(item: ToolbarItem, rect: NSRect)] = []
    private var toolbarFrame: NSRect = .zero
    private var geometryBounds: NSRect = .null

    init?(png: Data, dark: Bool) {
        guard let rep = NSBitmapImageRep(data: png), rep.pixelsWide > 0, rep.pixelsHigh > 0,
              let img = NSImage(data: png) else { return nil }
        self.pngOriginal = png
        self.srcRep = rep
        self.image = img
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }  // y up — matches strokes, bitmap contexts, NSString.draw

    var isEditingText: Bool { activeText != nil }
    /// Committed annotation count — the `whiteboard-live-test` harness asserts on it.
    var strokeCount: Int { strokes.count }
    /// The live text entry, for the harness to type into.
    var activeTextField: NSTextField? { activeText }

    /// For the offscreen `whiteboard-preview` / `whiteboard-export-test` checks.
    func previewSeed(strokes: [WBStroke], tool: WBTool, colorIndex: Int) {
        self.strokes = strokes
        self.tool = tool
        self.colorIndex = colorIndex
        needsDisplay = true
    }

    // MARK: - Geometry

    private func recalcIfNeeded() {
        guard geometryBounds != bounds, bounds.width > 0 else { return }
        geometryBounds = bounds

        // Image display size: pixels are truth (PNG DPI metadata lies); show at
        // physical size on this screen, shrink-to-fit, never enlarge.
        let pw = CGFloat(srcRep.pixelsWide), ph = CGFloat(srcRep.pixelsHigh)
        let scale = window?.screen?.backingScaleFactor ?? 2
        let baseW = pw / scale, baseH = ph / scale
        let toolbarBand: CGFloat = 76
        let avail = NSRect(x: bounds.minX + 40, y: bounds.minY + toolbarBand,
                           width: bounds.width - 80, height: bounds.height - toolbarBand - 40)
        let fit = min(1, avail.width / baseW, avail.height / baseH)
        let w = max(1, baseW * fit), h = max(1, baseH * fit)
        imageRect = NSRect(x: (bounds.width - w) / 2,
                           y: avail.minY + (avail.height - h) / 2, width: w, height: h)

        // Toolbar: measured chips + color dots in one centered backdrop bar.
        let chipFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let chipH: CGFloat = 30
        let dotSize: CGFloat = 18
        let gap: CGFloat = 8
        let sectionGap: CGFloat = 20

        enum Piece { case chip(ToolbarItem, String), dot(Int), gap(CGFloat) }
        var pieces: [Piece] = WBTool.allCases.map { .chip(.tool($0), $0.label) }
        pieces.append(.gap(sectionGap))
        pieces += (0..<Self.palette.count).map { .dot($0) }
        pieces.append(.gap(sectionGap))
        pieces.append(.chip(.undo, "Undo ⌘Z"))
        pieces.append(.gap(sectionGap))
        pieces.append(.chip(.save, "Save ⏎"))
        pieces.append(.chip(.cancel, "Cancel esc"))

        func pieceWidth(_ p: Piece) -> CGFloat {
            switch p {
            case .chip(_, let label):
                return ceil((label as NSString).size(withAttributes: [.font: chipFont]).width) + 24
            case .dot: return dotSize
            case .gap(let g): return g
            }
        }
        let contentW = pieces.reduce(0) { $0 + pieceWidth($1) } + gap * CGFloat(pieces.count - 1)
        let barH: CGFloat = 46
        toolbarFrame = NSRect(x: (bounds.width - contentW) / 2 - 14, y: 16,
                              width: contentW + 28, height: barH)
        let midY = toolbarFrame.midY
        var x = toolbarFrame.minX + 14
        toolbarItems = []
        for p in pieces {
            let w = pieceWidth(p)
            switch p {
            case .chip(let item, _):
                toolbarItems.append((item, NSRect(x: x, y: midY - chipH / 2, width: w, height: chipH)))
            case .dot(let i):
                toolbarItems.append((.color(i), NSRect(x: x, y: midY - dotSize / 2, width: dotSize, height: dotSize)))
            case .gap: break
            }
            x += w + gap
        }
    }

    private func toImageLocal(_ p: NSPoint) -> NSPoint {
        NSPoint(x: p.x - imageRect.minX, y: p.y - imageRect.minY)
    }

    private func clampedImageLocal(_ p: NSPoint) -> NSPoint {
        let ip = toImageLocal(p)
        return NSPoint(x: min(max(ip.x, 0), imageRect.width),
                       y: min(max(ip.y, 0), imageRect.height))
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        recalcIfNeeded()
        let p = convert(event.locationInWindow, from: nil)
        if let hit = toolbarItems.first(where: { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }) {
            commitActiveText()
            switch hit.item {
            case .tool(let t): tool = t
            case .color(let i): colorIndex = i
            case .undo: undo()
            case .save: save()
            case .cancel: onCancel?()
            }
            needsDisplay = true
            return
        }
        // Clicks on the dim area are no-ops (not click-to-cancel — too easy to lose ink).
        guard imageRect.contains(p) else { commitActiveText(); return }
        commitActiveText()
        let ip = toImageLocal(p)
        if tool == .text { beginText(at: ip); return }
        current = WBStroke(tool: tool, color: Self.palette[colorIndex],
                           points: tool == .pen ? [ip] : [ip, ip])
    }

    override func mouseDragged(with event: NSEvent) {
        guard current != nil else { return }
        let ip = clampedImageLocal(convert(event.locationInWindow, from: nil))
        if current!.tool == .pen { current!.points.append(ip) } else { current!.points[1] = ip }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = current else { return }
        current = nil
        // Drop degenerates: a bare click with pen, or a <3pt arrow/rect.
        switch s.tool {
        case .pen:
            if s.points.count >= 2 { strokes.append(s) }
        case .arrow, .rect:
            if hypot(s.points[1].x - s.points[0].x, s.points[1].y - s.points[0].y) >= 3 { strokes.append(s) }
        case .text:
            break
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }  // Esc — normally handled upstream; belt and braces
    }

    // MARK: - Actions

    func selectTool(_ t: WBTool) {
        commitActiveText()
        tool = t
        needsDisplay = true
    }

    func undo() {
        commitActiveText()
        _ = strokes.popLast()
        needsDisplay = true
    }

    func save() {
        commitActiveText()
        onSave?(renderAnnotatedPNG() ?? pngOriginal)
    }

    // MARK: - Text tool

    private func beginText(at imgLocal: NSPoint) {
        let origin = NSPoint(x: imgLocal.x + imageRect.minX, y: imgLocal.y + imageRect.minY)
        let width = max(80, imageRect.maxX - origin.x)
        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y, width: width, height: 26))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        field.textColor = Self.palette[colorIndex]
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = "text…"
        field.delegate = self
        field.target = self
        field.action = #selector(commitFromReturn)  // NSTextField fires its action on Return
        addSubview(field)
        activeText = field
        window?.makeFirstResponder(field)
    }

    @objc private func commitFromReturn() { commitActiveText() }

    func commitActiveText() {
        guard let field = activeText else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = toImageLocal(field.frame.origin)
        field.removeFromSuperview()
        activeText = nil
        if !value.isEmpty {
            strokes.append(WBStroke(tool: .text, color: field.textColor ?? Self.palette[colorIndex],
                                    points: [origin], text: value))
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func cancelActiveText() {
        activeText?.removeFromSuperview()
        activeText = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commitActiveText(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelActiveText(); return true }  // esc
        return false
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        recalcIfNeeded()

        // Dim the whole screen so the frozen image reads as "editing", not live UI.
        NSColor.black.withAlphaComponent(dark ? 0.5 : 0.35).setFill()
        bounds.fill()

        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.withAlphaComponent(0.25).setStroke()
        let frame = NSBezierPath(rect: imageRect.insetBy(dx: -0.5, dy: -0.5))
        frame.lineWidth = 1
        frame.stroke()

        // Ink, replayed via the same routine the export uses, clipped to the image.
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: imageRect).setClip()
        let t = NSAffineTransform()
        t.translateX(by: imageRect.minX, yBy: imageRect.minY)
        t.concat()
        for s in strokes { Self.drawStroke(s) }
        if let current { Self.drawStroke(current) }
        NSGraphicsContext.current?.restoreGraphicsState()

        drawToolbar()
    }

    private func drawToolbar() {
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: toolbarFrame, xRadius: 14, yRadius: 14).fill()

        let chipFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for (item, rect) in toolbarItems {
            switch item {
            case .color(let i):
                Self.palette[i].setFill()
                let dot = NSBezierPath(ovalIn: rect)
                dot.fill()
                if i == colorIndex {
                    NSColor.white.setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2.5, dy: -2.5))
                    ring.lineWidth = 2
                    ring.stroke()
                }
            case .tool(let t):
                drawChip(t.label, rect: rect, font: chipFont, selected: t == tool, filled: false)
            case .undo:
                drawChip("Undo ⌘Z", rect: rect, font: chipFont, selected: false, filled: false)
            case .save:
                drawChip("Save ⏎", rect: rect, font: chipFont, selected: false, filled: true)
            case .cancel:
                drawChip("Cancel esc", rect: rect, font: chipFont, selected: false, filled: false)
            }
        }
    }

    private func drawChip(_ label: String, rect: NSRect, font: NSFont, selected: Bool, filled: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if filled {
            Self.accent.setFill()
            path.fill()
        } else if selected {
            Self.accent.withAlphaComponent(0.35).setFill()
            path.fill()
            Self.accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else {
            NSColor.white.withAlphaComponent(0.1).setFill()
            path.fill()
        }
        let color: NSColor = (filled || selected) ? .white : NSColor.white.withAlphaComponent(0.85)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                 withAttributes: attrs)
    }

    /// Shared by on-screen draw (translate CTM) and export (scale CTM) — the
    /// only reason screen and file stay in agreement. Coordinates are
    /// image-local view points.
    private static func drawStroke(_ s: WBStroke) {
        s.color.set()
        switch s.tool {
        case .pen:
            guard s.points.count >= 2 else { return }
            let path = NSBezierPath()
            path.lineWidth = s.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: s.points[0])
            for p in s.points.dropFirst() { path.line(to: p) }
            path.stroke()
        case .rect:
            guard s.points.count >= 2 else { return }
            let r = NSRect(x: min(s.points[0].x, s.points[1].x), y: min(s.points[0].y, s.points[1].y),
                           width: abs(s.points[1].x - s.points[0].x), height: abs(s.points[1].y - s.points[0].y))
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            path.lineWidth = s.width
            path.lineJoinStyle = .round
            path.stroke()
        case .arrow:
            guard s.points.count >= 2 else { return }
            let a = s.points[0], b = s.points[1]
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(10, s.width * 3.5)
            let wing: CGFloat = .pi / 7
            // Shaft stops inside the head so the round cap doesn't poke past the tip.
            let shaftEnd = NSPoint(x: b.x - cos(angle) * head * 0.6, y: b.y - sin(angle) * head * 0.6)
            let shaft = NSBezierPath()
            shaft.lineWidth = s.width
            shaft.lineCapStyle = .round
            shaft.move(to: a)
            shaft.line(to: shaftEnd)
            shaft.stroke()
            let tip = NSBezierPath()
            tip.move(to: b)
            tip.line(to: NSPoint(x: b.x - cos(angle - wing) * head, y: b.y - sin(angle - wing) * head))
            tip.line(to: NSPoint(x: b.x - cos(angle + wing) * head, y: b.y - sin(angle + wing) * head))
            tip.close()
            tip.fill()
        case .text:
            guard let origin = s.points.first, !s.text.isEmpty else { return }
            (s.text as NSString).draw(at: origin, withAttributes: [
                .font: NSFont.systemFont(ofSize: s.fontSize, weight: .semibold),
                .foregroundColor: s.color,
            ])
        }
    }

    // MARK: - Export

    /// Composite base + ink at the source's full pixel dimensions. Deterministic
    /// bitmap context (not lockFocus, whose scale is device-dependent): with
    /// rep.size == pixel dims, 1 point == 1 pixel, and one uniform scale CTM maps
    /// image-local view points onto pixels — ink is vector, so it stays crisp.
    ///
    /// (Preview helpers for the `whiteboard-preview` / `whiteboard-export-test`
    /// subcommands live in the extension below.)
    func renderAnnotatedPNG() -> Data? {
        recalcIfNeeded()
        guard imageRect.width > 0 else { return nil }
        let pw = srcRep.pixelsWide, ph = srcRep.pixelsHigh
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: pw, height: ph)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: pw, height: ph),
                   from: .zero, operation: .copy, fraction: 1)
        let t = NSAffineTransform()
        t.scale(by: CGFloat(pw) / imageRect.width)
        t.concat()
        for s in strokes { Self.drawStroke(s) }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Offscreen preview support (whiteboard-preview / whiteboard-export-test)

extension WhiteboardView {
    /// Realizes geometry (normally done on first draw) and returns the
    /// image-local canvas size, so previews can place strokes proportionally.
    func previewCanvasSize() -> NSSize {
        recalcIfNeeded()
        return imageRect.size
    }

    /// One sample stroke per tool, spread across a canvas of the given size.
    static func sampleStrokes(in size: NSSize) -> [WBStroke] {
        let w = size.width, h = size.height
        var squiggle: [NSPoint] = []
        for i in 0...24 {
            squiggle.append(NSPoint(x: w * 0.08 + w * 0.3 * CGFloat(i) / 24,
                                    y: h * 0.22 + sin(CGFloat(i) / 3) * h * 0.06))
        }
        return [
            WBStroke(tool: .pen, color: palette[0], points: squiggle),
            WBStroke(tool: .arrow, color: palette[3],
                     points: [NSPoint(x: w * 0.5, y: h * 0.3), NSPoint(x: w * 0.72, y: h * 0.55)]),
            WBStroke(tool: .rect, color: palette[1],
                     points: [NSPoint(x: w * 0.12, y: h * 0.55), NSPoint(x: w * 0.4, y: h * 0.82)]),
            WBStroke(tool: .text, color: palette[0],
                     points: [NSPoint(x: w * 0.52, y: h * 0.72)], text: "wrong value"),
        ]
    }

    /// Deterministic 900×560 synthetic "screenshot" (explicit bitmap, not
    /// lockFocus, so pixel dims don't depend on the machine's display scale).
    static func syntheticShot() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 560,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: 900, height: 560)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(white: 0.82, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 900, height: 560).fill()
        NSColor.white.setFill(); NSRect(x: 60, y: 80, width: 420, height: 320).fill()
        NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 60, y: 400, width: 420, height: 36).fill()
        NSColor(white: 0.9, alpha: 1).setFill(); NSRect(x: 540, y: 140, width: 300, height: 296).fill()
        NSColor(white: 0.75, alpha: 1).setFill()
        for i in 0..<6 { NSRect(x: 84, y: 340 - CGFloat(i) * 36, width: 320, height: 12).fill() }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
