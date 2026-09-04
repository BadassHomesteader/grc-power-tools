import Cocoa

/// Keep Power Tools' floating surfaces out of screenshots, recordings and
/// screen sharing.
///
/// This became worth doing the moment the notch strip shipped: a pad you open
/// on purpose is one thing, but the strip lives in the menu bar permanently, so
/// without this it turns up in every demo capture and every call you share.
///
/// Scope is deliberately the OVERLAYS — the borderless, always-on-top surfaces
/// (the pads, the strip, the dictation HUD, every palette). Regular titled
/// windows (Settings, the chat) are left shareable, because those are things
/// you might actually mean to show someone.
///
/// `sharingType = .none` excludes a window from the captured image while leaving
/// it perfectly visible on your own display, and it still appears in the window
/// LIST — which is exactly how the test tells "hidden from capture" apart from
/// "not on screen".
@MainActor
enum CaptureVisibility {
    private(set) static var showInCaptures = true
    /// Windows are created lazily all over the app, so rather than teaching
    /// seventeen call sites to opt in, we re-apply whenever the window count
    /// moves. Comparing one Int per event-loop pass is cheaper than the bugs
    /// from a surface that forgot to ask.
    private static var lastCount = -1

    static func set(_ show: Bool) {
        guard show != showInCaptures || lastCount < 0 else { return }
        showInCaptures = show
        lastCount = -1
        apply()
    }

    static func applyIfWindowsChanged() {
        let n = NSApp.windows.count
        guard n != lastCount else { return }
        lastCount = n
        apply()
    }

    private static func apply() {
        let type: NSWindow.SharingType = showInCaptures ? .readOnly : .none
        for w in NSApp.windows where isOverlay(w) && w.sharingType != type {
            w.sharingType = type
        }
    }

    /// An overlay is borderless and floats above ordinary windows. A titled
    /// window is a document and stays in captures.
    private static func isOverlay(_ w: NSWindow) -> Bool {
        !w.styleMask.contains(.titled)
            && w.level.rawValue >= NSWindow.Level.floating.rawValue
    }
}
