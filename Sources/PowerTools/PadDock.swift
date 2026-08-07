import Cocoa

/// Shared docking geometry for the floating pads (AgentPad, MacroPad): drop a
/// panel near a corner or edge midpoint and it snaps there; the owning pad
/// re-anchors on every re-render so size changes (mini↔full, row growth) stay
/// parked in the same spot until the user drags the pad away again.
enum PadDock: String, CaseIterable, Codable {
    case topLeft, topMid, topRight, midLeft, midRight, bottomLeft, bottomMid, bottomRight

    static let snapDistance: CGFloat = 96
    static let margin: CGFloat = 12

    func origin(for size: NSSize, in vf: NSRect) -> NSPoint {
        let m = Self.margin
        let x: CGFloat, y: CGFloat
        switch self {
        case .topLeft, .midLeft, .bottomLeft: x = vf.minX + m
        case .topMid, .bottomMid: x = vf.midX - size.width / 2
        case .topRight, .midRight, .bottomRight: x = vf.maxX - m - size.width
        }
        switch self {
        case .topLeft, .topMid, .topRight: y = vf.maxY - m - size.height
        case .midLeft, .midRight: y = vf.midY - size.height / 2
        case .bottomLeft, .bottomMid, .bottomRight: y = vf.minY + m
        }
        return NSPoint(x: x, y: y)
    }

    /// The anchor nearest to a panel dropped at `origin`, or nil when none is
    /// within snapping distance (the panel stays free-floating).
    static func nearest(to origin: NSPoint, size: NSSize, in vf: NSRect) -> (anchor: PadDock, origin: NSPoint)? {
        var best: (anchor: PadDock, origin: NSPoint, dist: CGFloat)?
        for anchor in allCases {
            let o = anchor.origin(for: size, in: vf)
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
}

/// Drag-time dock UI (Window-Org style): while a pad is being dragged, a
/// pass-through overlay marks the eight snap anchors; the anchor that would
/// catch the drop lights up and a dashed ghost previews exactly where the pad
/// will land. Purely visual — it ignores the mouse and vanishes on drop.
@MainActor
final class PadDockOverlay {
    private var window: NSWindow?
    private var view: PadDockOverlayView?

    func update(padFrame: NSRect, on screen: NSScreen, dark: Bool) {
        let vf = screen.visibleFrame
        if window == nil {
            let win = NSWindow(contentRect: vf, styleMask: .borderless, backing: .buffered, defer: false)
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
        window?.setFrame(vf, display: false)
        view?.configure(vf: vf, padFrame: padFrame, dark: dark)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        view = nil
    }
}

/// The overlay canvas. Bottom-left coordinates matching the screen's
/// visibleFrame (the window is sized to it), so anchor math maps 1:1.
final class PadDockOverlayView: NSView {
    private var vf = NSRect.zero
    private var padFrame = NSRect.zero
    private var dark = true

    func configure(vf: NSRect, padFrame: NSRect, dark: Bool) {
        self.vf = vf
        self.padFrame = padFrame
        self.dark = dark
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard vf.width > 0 else { return }
        let active = PadDock.nearest(to: padFrame.origin, size: padFrame.size, in: vf)?.anchor
        let accent = NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)
        let base = dark ? NSColor.white : NSColor.black
        let markerSize = NSSize(width: 34, height: 34)
        for anchor in PadDock.allCases {
            let o = anchor.origin(for: markerSize, in: vf)
            let r = NSRect(origin: NSPoint(x: o.x - vf.minX, y: o.y - vf.minY), size: markerSize)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            (anchor == active ? accent.withAlphaComponent(0.85) : base.withAlphaComponent(0.18)).setFill()
            path.fill()
            (anchor == active ? accent : base.withAlphaComponent(0.4)).setStroke()
            path.lineWidth = anchor == active ? 2 : 1
            path.stroke()
        }
        // Dashed ghost of the landing rect for the anchor that would catch.
        if let active {
            let o = active.origin(for: padFrame.size, in: vf)
            let ghost = NSRect(origin: NSPoint(x: o.x - vf.minX, y: o.y - vf.minY), size: padFrame.size)
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
