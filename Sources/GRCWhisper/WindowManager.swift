import Cocoa
import ApplicationServices

/// Snaps the focused window of the frontmost app to a screen region via the
/// Accessibility API (same permission the hotkey tap already uses — no new grant).
///
/// Coordinate note: the AX API is TOP-left origin (like CGDisplay), while NSScreen
/// is BOTTOM-left. We compute targets in NSScreen (visibleFrame, so we never cover
/// the menu bar or Dock) and flip to AX coords when setting.
enum WindowManager {
    enum Snap {
        case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center

        var label: String {
            switch self {
            case .leftHalf: return "Left half"
            case .rightHalf: return "Right half"
            case .topHalf: return "Top half"
            case .bottomHalf: return "Bottom half"
            case .maximize: return "Maximized"
            case .center: return "Centered"
            }
        }
    }

    /// Returns false if there was no window to move (e.g. Finder desktop focused).
    @discardableResult
    static func snap(_ snap: Snap) -> Bool {
        guard let window = focusedWindow() else { return false }
        guard let screen = screen(for: window) ?? NSScreen.main else { return false }
        let vf = screen.visibleFrame
        setFrame(window, targetRect(snap, in: vf))
        return true
    }

    // MARK: Target geometry (NSScreen bottom-left coords)

    private static func targetRect(_ snap: Snap, in vf: NSRect) -> NSRect {
        switch snap {
        case .leftHalf:   return NSRect(x: vf.minX, y: vf.minY, width: vf.width / 2, height: vf.height)
        case .rightHalf:  return NSRect(x: vf.midX, y: vf.minY, width: vf.width / 2, height: vf.height)
        case .topHalf:    return NSRect(x: vf.minX, y: vf.midY, width: vf.width, height: vf.height / 2)
        case .bottomHalf: return NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height / 2)
        case .maximize:   return vf
        case .center:
            let w = vf.width * 0.62, h = vf.height * 0.72
            return NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h)
        }
    }

    // MARK: AX plumbing

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let win = focused else { return nil }
        return (win as! AXUIElement)
    }

    /// Current window frame in NSScreen (bottom-left) coords, or nil.
    private static func currentFrame(_ window: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        let cocoaY = primaryHeight() - pos.y - size.height
        return NSRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
    }

    private static func screen(for window: AXUIElement) -> NSScreen? {
        guard let f = currentFrame(window) else { return nil }
        let center = NSPoint(x: f.midX, y: f.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
    }

    private static func setFrame(_ window: AXUIElement, _ cocoaRect: NSRect) {
        let axY = primaryHeight() - cocoaRect.origin.y - cocoaRect.height
        var pos = CGPoint(x: cocoaRect.origin.x, y: axY)
        var size = CGSize(width: cocoaRect.width, height: cocoaRect.height)
        // Set size first, then position, then position again — a window with a min
        // size can otherwise land shifted after the size clamps it.
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
        if let posVal = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    /// Height of the primary screen (menu-bar screen) — the anchor for AX↔Cocoa flip.
    private static func primaryHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }
}
