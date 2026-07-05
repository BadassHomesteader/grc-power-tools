import Cocoa
import ApplicationServices

/// Snaps the focused window of the frontmost app to a screen region via the
/// Accessibility API (same permission the hotkey tap already uses — no new grant).
///
/// Coordinate note: the AX API is TOP-left origin (like CGDisplay), while NSScreen
/// is BOTTOM-left. We compute targets in NSScreen (visibleFrame, so we never cover
/// the menu bar or Dock) and flip to AX coords when setting.
enum WindowManager {
    /// A direction the user pressed (arrow) or a whole-screen action.
    enum Move { case left, right, up, down, maximize }
    enum Edge { case left, right, top, bottom }

    /// Snap to `fraction` of the screen along `edge` (0.5 = half, 1/3, 2/3…).
    @discardableResult
    static func snap(edge: Edge, fraction: CGFloat) -> Bool {
        guard let window = focusedWindow(), let screen = targetScreen(window) else { return false }
        let vf = screen.visibleFrame
        let r: NSRect
        switch edge {
        case .left:   r = NSRect(x: vf.minX, y: vf.minY, width: vf.width * fraction, height: vf.height)
        case .right:  r = NSRect(x: vf.maxX - vf.width * fraction, y: vf.minY, width: vf.width * fraction, height: vf.height)
        case .top:    r = NSRect(x: vf.minX, y: vf.maxY - vf.height * fraction, width: vf.width, height: vf.height * fraction)
        case .bottom: r = NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height * fraction)
        }
        setFrame(window, r)
        return true
    }

    @discardableResult
    static func maximize() -> Bool {
        guard let window = focusedWindow(), let screen = targetScreen(window) else { return false }
        setFrame(window, screen.visibleFrame)
        return true
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

    private static func targetScreen(_ window: AXUIElement) -> NSScreen? {
        guard let f = currentFrame(window) else { return NSScreen.main }
        let center = NSPoint(x: f.midX, y: f.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
    }

    /// Current window frame in NSScreen (bottom-left) coords, or nil.
    private static func currentFrame(_ window: AXUIElement) -> NSRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        let cocoaY = primaryHeight() - pos.y - size.height
        return NSRect(x: pos.x, y: cocoaY, width: size.width, height: size.height)
    }

    private static func setFrame(_ window: AXUIElement, _ cocoaRect: NSRect) {
        let axY = primaryHeight() - cocoaRect.origin.y - cocoaRect.height
        var pos = CGPoint(x: cocoaRect.origin.x, y: axY)
        var size = CGSize(width: cocoaRect.width, height: cocoaRect.height)
        // Set size, then position, then size again — a window with a min size can
        // otherwise land shifted after the size clamps it.
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
