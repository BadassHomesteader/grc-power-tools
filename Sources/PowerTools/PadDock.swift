import Cocoa

/// Shared docking geometry for the floating pads (AgentPad, MacroPad): drop a
/// panel near a corner, an edge midpoint, or one of the three notch berths and
/// it snaps there; the owning pad re-anchors on every re-render so size changes
/// (mini↔full, row growth) stay parked in the same spot until the user drags
/// the pad away again.
enum PadDock: String, CaseIterable, Codable {
    case topLeft, topMid, topRight, notchLeft, notchRight, notchBelow,
         midLeft, midRight, bottomLeft, bottomMid, bottomRight

    static let snapDistance: CGFloat = 96
    static let margin: CGFloat = 12

    /// The three berths around the camera housing. A pad parked on one lays its
    /// mini strip out HORIZONTALLY — a column of lights hanging off the menu bar
    /// would drape over whatever is underneath; a row tucks into the dead space
    /// the notch leaves behind.
    var isNotch: Bool { self == .notchLeft || self == .notchRight || self == .notchBelow }

    /// The shelf sits centred ON the housing rather than beside it, so it pads
    /// out to `Field.shellWidth` and the notch disappears into the pad.
    var absorbsNotch: Bool { self == .notchBelow }

    /// The screen geometry anchors resolve against. The eight edge anchors sit
    /// inside the working area; the notch berths hug the camera housing, which
    /// lives ABOVE it in the menu-bar strip — so visibleFrame alone can't
    /// describe both.
    struct Field {
        /// screen.visibleFrame — menu bar and Dock excluded.
        let visible: NSRect
        /// The camera housing: menu-bar tall, notch wide, flush with the top of
        /// the screen. A display without a notch gets a zero-width seam at the
        /// top centre instead, so a pad carrying a saved notch anchor onto an
        /// external monitor still lands somewhere sane.
        let notch: NSRect

        init(visible: NSRect, notch: NSRect) {
            self.visible = visible
            self.notch = notch
        }

        init(screen: NSScreen) {
            let frame = screen.frame
            visible = screen.visibleFrame
            // auxiliaryTop*Area are the menu-bar strips flanking the housing;
            // both are nil on a display without a notch.
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               right.minX > left.maxX {
                notch = NSRect(x: left.maxX, y: min(left.minY, right.minY),
                               width: right.minX - left.maxX,
                               height: max(left.height, right.height))
            } else {
                notch = NSRect(x: frame.midX, y: visible.maxY, width: 0,
                               height: max(frame.maxY - visible.maxY, 0))
            }
        }

        var hasNotch: Bool { notch.width > 0 }

        /// visibleFrame plus the menu-bar strip — every point an anchor can put
        /// a pad, and therefore the canvas the drag overlay has to cover.
        var canvas: NSRect {
            NSRect(x: visible.minX, y: visible.minY, width: visible.width,
                   height: max(visible.maxY, notch.maxY) - visible.minY)
        }
    }

    func origin(for size: NSSize, in field: Field) -> NSPoint {
        let vf = field.visible
        let notch = field.notch
        let m = Self.margin
        let x: CGFloat, y: CGFloat
        switch self {
        case .topLeft, .midLeft, .bottomLeft: x = vf.minX + m
        case .topMid, .bottomMid: x = vf.midX - size.width / 2
        case .topRight, .midRight, .bottomRight: x = vf.maxX - m - size.width
        // The shoulders tuck against the housing, the shelf centres under it —
        // all clamped on-screen for a pad wider than the space it parks in.
        case .notchLeft: x = max(notch.minX - m - size.width, vf.minX)
        case .notchRight: x = min(notch.maxX + m, max(vf.maxX - size.width, vf.minX))
        case .notchBelow: x = min(max(notch.midX - size.width / 2, vf.minX),
                                  max(vf.maxX - size.width, vf.minX))
        }
        switch self {
        case .topLeft, .topMid, .topRight: y = vf.maxY - m - size.height
        case .midLeft, .midRight: y = vf.midY - size.height / 2
        case .bottomLeft, .bottomMid, .bottomRight: y = vf.minY + m
        // All three berths HANG FROM THE TOP EDGE of the screen. That flush top
        // is the whole trick: square against the screen edge, rounded below, in
        // the housing's own black, the pad stops reading as a panel parked near
        // the notch and starts reading as the notch itself having grown.
        case .notchLeft, .notchRight, .notchBelow: y = notch.maxY - size.height
        }
        return NSPoint(x: x, y: y)
    }

    /// The anchors a pad may be dropped on. The notch is no longer one of them:
    /// `NotchStrip` is the single citizen of the housing now, so a pad parking
    /// there would sit on top of it. The berth cases survive in the enum for two
    /// reasons — `PadPlacement` has to keep decoding saved files that name them
    /// (see `migrateNotchAnchors`), and `notchBelow` still places the strip.
    static func anchors(in field: Field) -> [PadDock] {
        allCases.filter { !$0.isNotch }
    }

    /// The anchor nearest to a panel dropped at `origin`, or nil when none is
    /// within snapping distance (the panel stays free-floating).
    static func nearest(to origin: NSPoint, size: NSSize, in field: Field) -> (anchor: PadDock, origin: NSPoint)? {
        var best: (anchor: PadDock, origin: NSPoint, dist: CGFloat)?
        for anchor in anchors(in: field) {
            let o = anchor.origin(for: size, in: field)
            let d = hypot(origin.x - o.x, origin.y - o.y)
            if best == nil || d < best!.dist { best = (anchor, o, d) }
        }
        guard let best, best.dist <= snapDistance else { return nil }
        return (best.anchor, best.origin)
    }
}

/// Where a pad was last left — dock anchor or free-float top-left, plus the
/// mini (traffic-light strip) preference — persisted to pad-placement.json so
/// it all survives app restarts (in-memory-only placement meant every
/// update/relaunch silently reset pads to their spawn corner, full-size).
/// Keyed per pad ("macro", "agent").
struct PadPlacement: Codable {
    var anchor: PadDock?
    var x: CGFloat?
    var y: CGFloat?
    var mini: Bool?
    /// Open at last save — app quit/deploy leaves it true, user dismiss
    /// writes false; launch restores pads whose flag is still true.
    var open: Bool?
    /// Sessions whose pending permission the user had already seen when they
    /// collapsed the pad to the strip. Persisted so a permission that's stuck
    /// on-screen doesn't re-maximize the pad on every restart.
    var seen: [String]?

    private static var url: URL { Config.appSupportDir.appendingPathComponent("pad-placement.json") }

    static func load(_ key: String) -> PadPlacement? {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([String: PadPlacement].self, from: data) else { return nil }
        return all[key]
    }

    static func save(_ key: String, anchor: PadDock?, topLeft: NSPoint?, mini: Bool = false,
                     open: Bool = false, seen: [String] = []) {
        var all = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: PadPlacement].self, from: $0) } ?? [:]
        all[key] = PadPlacement(anchor: anchor, x: topLeft?.x, y: topLeft?.y, mini: mini,
                                open: open, seen: seen)
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }

    /// Move pads off the retired notch berths onto the nearest ordinary anchor.
    ///
    /// Run once, guarded by `Config.notchStripMigrated`. Note the shape of the
    /// hazard this avoids: `load` decodes the WHOLE dictionary in one go, so if
    /// the berth cases were simply deleted from the enum, a saved file naming
    /// one would throw and BOTH pads would lose their placement — not just the
    /// berthed one. Keeping the cases and rewriting the file is the safe order.
    ///
    /// Returns the pad keys that were sitting in the notch, so the caller can
    /// switch on the matching strip sources: what was in the notch stays in the
    /// notch, just as a published mark rather than a pad.
    @discardableResult
    static func migrateNotchAnchors() -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              var all = try? JSONDecoder().decode([String: PadPlacement].self, from: data)
        else { return [] }
        var moved: Set<String> = []
        for (key, var placement) in all {
            guard let anchor = placement.anchor, anchor.isNotch else { continue }
            switch anchor {
            case .notchLeft: placement.anchor = .topLeft
            case .notchRight: placement.anchor = .topRight
            default: placement.anchor = .topMid
            }
            all[key] = placement   // mini/open/seen/x/y ride along untouched
            moved.insert(key)
        }
        guard !moved.isEmpty else { return [] }
        if let out = try? JSONEncoder().encode(all) { try? out.write(to: url, options: .atomic) }
        return moved
    }
}

/// Drag-time dock UI (Window-Org style): while a pad is being dragged, a
/// pass-through overlay marks the snap anchors on offer; the anchor that would
/// catch the drop lights up and a dashed ghost previews exactly where the pad
/// will land. Purely visual — it ignores the mouse and vanishes on drop.
@MainActor
final class PadDockOverlay {
    private var window: NSWindow?
    private var view: PadDockOverlayView?

    func update(padFrame: NSRect, on screen: NSScreen, dark: Bool) {
        // The canvas, not visibleFrame: the notch anchors sit up in the menu-bar
        // strip, and markers outside the overlay window would simply be clipped.
        let field = PadDock.Field(screen: screen)
        let canvas = field.canvas
        if window == nil {
            let win = NSWindow(contentRect: canvas, styleMask: .borderless, backing: .buffered, defer: false)
            win.isOpaque = false
            win.backgroundColor = .clear
            // One notch under the pads so the dragged pad always stays on top.
            win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = PadDockOverlayView()
            win.contentView = v
            window = win
            view = v
            win.orderFrontRegardless()
        }
        window?.setFrame(canvas, display: false)
        view?.configure(field: field, padFrame: padFrame, dark: dark)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        view = nil
    }
}

/// The overlay canvas. Bottom-left coordinates matching the field's canvas rect
/// (the window is sized to it), so anchor math maps 1:1.
final class PadDockOverlayView: NSView {
    private var field = PadDock.Field(visible: .zero, notch: .zero)
    private var padFrame = NSRect.zero
    private var dark = true

    func configure(field: PadDock.Field, padFrame: NSRect, dark: Bool) {
        self.field = field
        self.padFrame = padFrame
        self.dark = dark
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard field.visible.width > 0 else { return }
        let canvas = field.canvas
        let active = PadDock.nearest(to: padFrame.origin, size: padFrame.size, in: field)?.anchor
        let accent = NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)
        let base = dark ? NSColor.white : NSColor.black
        let markerSize = NSSize(width: 34, height: 34)
        for anchor in PadDock.anchors(in: field) {
            let o = anchor.origin(for: markerSize, in: field)
            let r = NSRect(origin: NSPoint(x: o.x - canvas.minX, y: o.y - canvas.minY), size: markerSize)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            (anchor == active ? accent.withAlphaComponent(0.85) : base.withAlphaComponent(0.18)).setFill()
            path.fill()
            (anchor == active ? accent : base.withAlphaComponent(0.4)).setStroke()
            path.lineWidth = anchor == active ? 2 : 1
            path.stroke()
        }
        // Dashed ghost of the landing rect for the anchor that would catch.
        if let active {
            let o = active.origin(for: padFrame.size, in: field)
            let ghost = NSRect(origin: NSPoint(x: o.x - canvas.minX, y: o.y - canvas.minY), size: padFrame.size)
            let path = NSBezierPath(roundedRect: ghost, xRadius: 14, yRadius: 14)
            accent.withAlphaComponent(0.12).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}
