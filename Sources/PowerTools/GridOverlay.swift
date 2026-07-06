import Cocoa

/// A full-screen "draw where the window goes" grid (Moom-style). Triggered by the
/// hotkey + grid key; you drag across the grid to paint a rectangle and the target
/// window (captured before the grid stole focus) snaps to it on release.
/// Borderless windows can't become key by default (so keyDown/Esc never arrives).
/// This one can, so the grid is keyboard-cancellable.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class GridOverlay {
    private var window: NSWindow?

    var isVisible: Bool { window != nil }

    /// `screen`: where to draw. `snap`: called with the chosen global (bottom-left)
    /// rect. `done`: always called (snap or cancel) so the caller can refocus.
    func present(screen: NSScreen, cols: Int, rows: Int, dark: Bool,
                 snap: @escaping (NSRect) -> Void, done: @escaping () -> Void) {
        dismiss()
        let vf = screen.visibleFrame
        let win = KeyableWindow(contentRect: vf, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let grid = GridView(cols: cols, rows: rows, dark: dark)
        grid.frame = NSRect(origin: .zero, size: vf.size)
        grid.onComplete = { [weak self] rect in
            if let rect {
                snap(NSRect(x: vf.minX + rect.minX, y: vf.minY + rect.minY,
                            width: rect.width, height: rect.height))
            }
            self?.dismiss()
            done()
        }
        win.contentView = grid
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(grid)
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

/// The grid canvas: faint grid over a dimmed screen; drag to paint a cell rectangle.
final class GridView: NSView {
    private let cols: Int
    private let rows: Int
    private let dark: Bool
    private var startCell: (col: Int, row: Int)?
    private var currentCell: (col: Int, row: Int)?
    /// Called with the selected rect in view coords (bottom-left), or nil to cancel.
    var onComplete: ((NSRect?) -> Void)?

    init(cols: Int, rows: Int, dark: Bool) {
        self.cols = cols
        self.rows = rows
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }  // y=0 at bottom, matches NSScreen

    /// For the offscreen `grid-preview` design check.
    func previewSelect(_ a: (Int, Int), _ b: (Int, Int)) {
        startCell = a; currentCell = b; needsDisplay = true
    }

    private var cellW: CGFloat { bounds.width / CGFloat(cols) }
    private var cellH: CGFloat { bounds.height / CGFloat(rows) }

    private func cell(at p: NSPoint) -> (col: Int, row: Int) {
        let c = min(max(Int(p.x / cellW), 0), cols - 1)
        let r = min(max(Int(p.y / cellH), 0), rows - 1)
        return (c, r)
    }

    private func selectionRect() -> NSRect? {
        guard let a = startCell, let b = currentCell else { return nil }
        let minC = min(a.col, b.col), maxC = max(a.col, b.col)
        let minR = min(a.row, b.row), maxR = max(a.row, b.row)
        return NSRect(x: CGFloat(minC) * cellW, y: CGFloat(minR) * cellH,
                      width: CGFloat(maxC - minC + 1) * cellW,
                      height: CGFloat(maxR - minR + 1) * cellH)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startCell = cell(at: p); currentCell = startCell
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        currentCell = cell(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        // A bare click (no drag = same start/current cell) cancels instead of
        // snapping the window to a single tiny cell.
        if let a = startCell, let b = currentCell, a.col == b.col, a.row == b.row {
            onComplete?(nil)
        } else {
            onComplete?(selectionRect())
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil) }  // Esc cancels
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim the screen so the grid + selection read on any wallpaper.
        (dark ? NSColor.black.withAlphaComponent(0.34) : NSColor.black.withAlphaComponent(0.18)).setFill()
        bounds.fill()

        // Grid lines.
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        for c in 0...cols {
            let x = CGFloat(c) * cellW
            line.move(to: NSPoint(x: x, y: 0)); line.line(to: NSPoint(x: x, y: bounds.height))
        }
        for r in 0...rows {
            let y = CGFloat(r) * cellH
            line.move(to: NSPoint(x: 0, y: y)); line.line(to: NSPoint(x: bounds.width, y: y))
        }
        line.stroke()

        // Selection.
        if let sel = selectionRect() {
            let accent = NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)
            accent.withAlphaComponent(0.35).setFill()
            let path = NSBezierPath(roundedRect: sel.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            path.fill()
            accent.setStroke(); path.lineWidth = 2; path.stroke()
        }

        // Hint.
        let hint = "drag to place · esc to cancel" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.65),
        ]
        let size = hint.size(withAttributes: attrs)
        hint.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 14), withAttributes: attrs)
    }
}
