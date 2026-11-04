import Cocoa
import ApplicationServices

/// Private but widely-used AX SPI: get the CGWindowID for an AX window element.
/// Bridges CGWindowList entries (used for enumeration + thumbnails in Snap Assist)
/// to the AX handle we need to actually move a window.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

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

    struct SnapResult { let screen: NSScreen; let windowID: CGWindowID? }

    /// A window to move. Other apps' windows go through Accessibility; Power
    /// Tools' OWN windows (Meeting Notes, Settings, AI chat) can't — macOS answers
    /// an app's AX queries about itself with kAXErrorNotImplemented (-25208,
    /// verified by `ax-self-test`) — so those are moved directly as NSWindows.
    enum Target {
        case ax(AXUIElement)
        case own(NSWindow)
    }

    /// Snap to `fraction` of the screen along `edge` (0.5 = half, 1/3, 2/3…).
    /// Returns the screen used + the moved window's CGWindowID (for Snap Assist).
    @discardableResult
    static func snap(edge: Edge, fraction: CGFloat) -> SnapResult? {
        guard let window = focusedTarget(), let screen = targetScreen(window) else { return nil }
        let vf = screen.visibleFrame
        let r: NSRect
        switch edge {
        case .left:   r = NSRect(x: vf.minX, y: vf.minY, width: vf.width * fraction, height: vf.height)
        case .right:  r = NSRect(x: vf.maxX - vf.width * fraction, y: vf.minY, width: vf.width * fraction, height: vf.height)
        case .top:    r = NSRect(x: vf.minX, y: vf.maxY - vf.height * fraction, width: vf.width, height: vf.height * fraction)
        case .bottom: r = NSRect(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height * fraction)
        }
        setFrame(window, r)
        return SnapResult(screen: screen, windowID: cgWindowID(of: window))
    }

    /// Find the AX window element for a given app pid + CGWindowID (Snap Assist
    /// clicks a CGWindowList entry; we need its AX handle to move it).
    static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return nil }
        for w in windows {
            var wid = CGWindowID(0)
            if _AXUIElementGetWindow(w, &wid) == .success, wid == windowID { return w }
        }
        return nil
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    /// nil if the SPI fails — the caller must NOT use 0 as a real window ID (it
    /// would fail to exclude the just-snapped window from Snap Assist).
    private static func cgWindowID(of target: Target) -> CGWindowID? {
        switch target {
        case .own(let w): return CGWindowID(w.windowNumber)
        case .ax(let window):
            var wid = CGWindowID(0)
            return _AXUIElementGetWindow(window, &wid) == .success ? wid : nil
        }
    }

    /// Snap into a corner: a horizontal edge×fraction combined with a vertical
    /// edge×fraction (chained arrows — e.g. ← then ↑ = top-left quarter).
    @discardableResult
    static func snapCorner(hEdge: Edge, hFraction: CGFloat, vEdge: Edge, vFraction: CGFloat) -> SnapResult? {
        guard let window = focusedTarget(), let screen = targetScreen(window) else { return nil }
        let vf = screen.visibleFrame
        let w = vf.width * hFraction
        let h = vf.height * vFraction
        let x = hEdge == .left ? vf.minX : vf.maxX - w
        let y = vEdge == .bottom ? vf.minY : vf.maxY - h
        setFrame(window, NSRect(x: x, y: y, width: w, height: h))
        return SnapResult(screen: screen, windowID: cgWindowID(of: window))
    }

    /// The screen a window mostly sits on (palette placement).
    static func screen(of window: Target) -> NSScreen? { targetScreen(window) }

    @discardableResult
    static func maximize() -> Bool {
        guard let window = focusedTarget(), let screen = targetScreen(window) else { return false }
        setFrame(window, screen.visibleFrame)
        return true
    }

    /// The focused window of the frontmost app — capture this BEFORE showing any UI
    /// that steals focus (e.g. the grid overlay), then apply with `setWindow`.
    static func frontmostWindow() -> Target? { focusedTarget() }

    /// Move/resize a specific window to a global NSScreen (bottom-left) rect.
    static func setWindow(_ window: Target, cocoaFrame: NSRect) { setFrame(window, cocoaFrame) }
    static func setWindow(_ window: AXUIElement, cocoaFrame: NSRect) { setFrame(.ax(window), cocoaFrame) }

    /// Power Tools' own front document window, when Power Tools is frontmost —
    /// a titled, resizable, non-panel window (never a pad, palette, or overlay).
    static func ownFrontWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows.map { Optional($0) }
        return candidates.compactMap { $0 }.first {
            $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) && $0.styleMask.contains(.resizable)
        }
    }

    // MARK: AX plumbing

    private static func focusedTarget() -> Target? {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
            return ownFrontWindow().map { .own($0) }
        }
        return focusedWindow().map { .ax($0) }
    }

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let win = focused, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        return (win as! AXUIElement)   // type-checked above; CF has no conditional cast
    }

    private static func targetScreen(_ target: Target) -> NSScreen? {
        switch target {
        case .own(let w): return w.screen ?? NSScreen.main
        case .ax(let window): return targetScreen(window)
        }
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

    private static func setFrame(_ target: Target, _ cocoaRect: NSRect) {
        switch target {
        case .own(let w):
            var r = cocoaRect
            r.size.width = max(r.width, w.minSize.width)
            r.size.height = max(r.height, w.minSize.height)
            w.setFrame(r, display: true, animate: false)
        case .ax(let window): setFrame(window, cocoaRect)
        }
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
