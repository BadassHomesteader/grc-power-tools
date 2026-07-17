import Cocoa

/// Shared docking geometry for the floating pads (AgentPad, MacroPad): drop a
/// panel near a corner or edge midpoint and it snaps there; the owning pad
/// re-anchors on every re-render so size changes (mini↔full, row growth) stay
/// parked in the same spot until the user drags the pad away again.
enum PadDock: CaseIterable {
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
