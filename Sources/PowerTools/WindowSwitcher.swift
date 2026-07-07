import Cocoa
import ApplicationServices

/// ⌘` fixed: jump to the LAST WINDOW YOU USED, regardless of app. macOS's own
/// ⌘` only cycles windows of the frontmost app; this makes it an Alt-Tab-style
/// quick toggle — tap to go back to the previous window, tap again to return —
/// without touching ⌘Tab (which still switches whole apps).
///
/// v1 semantics: "previous window" = the focused window of the previously
/// active app (tracked via NSWorkspace activation history, resolved via AX at
/// press time so closed windows never go stale). Within-app window focus
/// changes aren't tracked — that would need per-app AX observers.
@MainActor
final class WindowSwitcher {
    private var current: pid_t = 0
    private var history: [pid_t] = []   // most recently used first, excludes current

    func start() {
        current = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in self?.activated(pid) }
        }
    }

    private func activated(_ pid: pid_t) {
        guard pid != current else { return }
        if current != 0 {
            history.removeAll { $0 == current }
            history.insert(current, at: 0)
            if history.count > 8 { history.removeLast() }
        }
        current = pid
    }

    /// Raise the previous app's focused window and activate it. Skips apps that
    /// have quit; falls back to a plain app activation if no window resolves
    /// (e.g. Finder with no windows). Returns false if there's nowhere to go.
    @discardableResult
    func switchToPrevious() -> Bool {
        while let pid = history.first {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                history.removeFirst()
                continue
            }
            let axApp = AXUIElementCreateApplication(pid)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
               let win = focused {
                // Raise just that window — it becomes key without dragging the
                // app's other windows forward.
                AXUIElementPerformAction(win as! AXUIElement, kAXRaiseAction as CFString)
            }
            // We're a BACKGROUND app here, so NSRunningApplication.activate()
            // alone is ignored under macOS 14+ cooperative activation. The AX
            // frontmost attribute is honored for Accessibility-trusted apps.
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            app.activate(options: [.activateIgnoringOtherApps])
            log("switcher: → \(app.localizedName ?? "pid \(pid)")")
            return true
        }
        log("switcher: no previous window to switch to")
        return false
    }
}
