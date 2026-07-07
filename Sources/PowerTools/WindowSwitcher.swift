import Cocoa
import ApplicationServices

/// ⌘Tab, but like Windows Alt-Tab: WINDOW-level most-recently-used switching.
/// Two Excel windows are two entries; tap ⌘Tab to bounce to the last window
/// you used (any app), hold ⌘ and tap Tab again to walk deeper down the MRU
/// list (⇧⌘Tab walks backwards); releasing ⌘ commits. Each step raises the
/// window immediately, so you always see where you are — no HUD needed.
///
/// Tracking: app switches come from NSWorkspace activation notifications;
/// window switches WITHIN the frontmost app come from an AX observer on its
/// focused-window-changed notification (re-attached on each app activation).
@MainActor
final class WindowSwitcher {
    struct Entry: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
    }

    private var current: Entry?
    private var history: [Entry] = []      // most recently used first, excludes current

    /// Hold-⌘-and-Tab cycling session: a snapshot of [current] + history taken
    /// at the first Tab. Windows-style: stepping only moves the STRIP highlight;
    /// the chosen window raises when ⌘ is released (endCycle). Esc cancels.
    private var session: [Entry]?
    private var sessionIndex = 0
    private var suppress = false           // ignore focus events during a session
    private var lastCycleAt = Date.distantPast
    private let strip = SwitcherStrip()
    /// Mirrors the app theme for the strip (set by AppController on config change).
    var dark = true

    private var observer: AXObserver?
    private var observedPid: pid_t = 0

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                self.observeFocus(of: pid)
                // The newly active app's focused window needs a beat to settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                    self.noteFocusChange()
                }
            }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            observeFocus(of: pid)
            noteFocusChange()
        }
    }

    // MARK: Focus tracking

    /// Watch the (new) frontmost app for focused-window changes, so switching
    /// between two windows of the SAME app lands in the history too.
    private func observeFocus(of pid: pid_t) {
        guard pid != observedPid else { return }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPid = 0
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowSwitcher>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in me.noteFocusChange() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, axApp, kAXFocusedWindowChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPid = pid
    }

    private func focusedEntry(of pid: pid_t) -> Entry? {
        let axApp = AXUIElementCreateApplication(pid)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &f) == .success,
              let f else { return nil }
        var wid = CGWindowID(0)
        guard _AXUIElementGetWindow(f as! AXUIElement, &wid) == .success else { return nil }
        return Entry(pid: pid, windowID: wid)
    }

    private func noteFocusChange() {
        guard !suppress else { return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let entry = focusedEntry(of: pid), entry != current else { return }
        if let cur = current {
            history.removeAll { $0 == cur }
            history.insert(cur, at: 0)
        }
        history.removeAll { $0 == entry }
        if history.count > 20 { history.removeLast() }
        current = entry
    }

    // MARK: Cycling (⌘Tab held session)

    func cycle(back: Bool) {
        // Safety valve: if a ⌘-release was missed (sleep, tap hiccup), a stale
        // session would freeze history tracking forever.
        if session != nil, Date().timeIntervalSince(lastCycleAt) > 4 { endCycle() }
        lastCycleAt = Date()

        if session == nil {
            noteFocusChange()  // make sure `current` reflects reality at session start
            guard let cur = current else {
                log("switcher: nothing to cycle to")
                return
            }
            var snap = [cur] + history
            let actual = NSWorkspace.shared.frontmostApplication.flatMap { focusedEntry(of: $0.processIdentifier) }
            if actual != cur {
                // The frontmost app has no trackable window (e.g. window-less
                // Finder) — from here, `current` IS the last window, so a dead
                // sentinel fills slot 0 and the first Tab lands on `current`.
                snap.insert(Entry(pid: -1, windowID: 0), at: 0)
            }
            // Drop dead windows from the history part.
            snap = snap.enumerated().filter { $0.offset == 0 || liveWindow($0.element) }.map(\.element)
            // Windows-Alt-Tab completeness: append every other on-screen window
            // (front-to-back) that history hasn't seen yet, so apps you haven't
            // visited since launch still show up in the strip.
            for entry in onScreenWindows() where !snap.contains(entry) {
                snap.append(entry)
            }
            if snap.count > 8 { snap = Array(snap.prefix(8)) }
            guard snap.count > 1 else {
                log("switcher: nothing to cycle to")
                return
            }
            session = snap
            sessionIndex = 0
            suppress = true
            strip.present(tiles: snap.map(tile(for:)), highlight: 0, dark: dark)
        }
        guard let snap = session, snap.count > 1 else { return }
        sessionIndex = (sessionIndex + (back ? -1 : 1) + snap.count) % snap.count
        strip.setHighlight(sessionIndex)
    }

    /// ⌘ released: raise the highlighted window, commit it as most-recent.
    func endCycle() {
        strip.dismiss()
        guard var snap = session, snap.indices.contains(sessionIndex) else {
            session = nil
            suppress = false
            return
        }
        // Raise the selection; if it died mid-session, walk forward to the next
        // live one.
        var landed: Entry?
        var attempts = snap.count
        while attempts > 0 {
            attempts -= 1
            let target = snap[sessionIndex]
            if raise(target) { landed = target; break }
            snap.remove(at: sessionIndex)
            if snap.isEmpty { break }
            sessionIndex = sessionIndex % snap.count
        }
        session = nil
        suppress = false
        guard let landed else { return }
        if let cur = current, cur != landed {
            history.removeAll { $0 == cur }
            history.insert(cur, at: 0)
        }
        history.removeAll { $0 == landed }
        if history.count > 20 { history.removeLast() }
        current = landed
    }

    /// Esc while cycling: close the strip, switch nothing, keep history as-is.
    func cancelCycle() {
        strip.dismiss()
        session = nil
        suppress = false
    }

    /// All normal on-screen windows, front-to-back (CGWindowList z-order).
    private func onScreenWindows() -> [Entry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [Entry] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 120, (b["Height"] ?? 0) >= 90,
                  let wid = w[kCGWindowNumber as String] as? Int else { continue }
            out.append(Entry(pid: pid, windowID: CGWindowID(wid)))
        }
        return out
    }

    private func liveWindow(_ entry: Entry) -> Bool {
        guard entry.pid > 0,
              let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else { return false }
        return WindowManager.axWindow(pid: entry.pid, windowID: entry.windowID) != nil
    }

    private func tile(for entry: Entry) -> SwitcherStrip.Tile {
        if entry.pid <= 0 {
            // Sentinel slot: the frontmost app had no trackable window.
            let front = NSWorkspace.shared.frontmostApplication
            return SwitcherStrip.Tile(pid: -1, windowID: 0,
                                      title: front?.localizedName ?? "Here", icon: front?.icon)
        }
        let app = NSRunningApplication(processIdentifier: entry.pid)
        var title = ""
        if let win = WindowManager.axWindow(pid: entry.pid, windowID: entry.windowID) {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t) == .success {
                title = (t as? String) ?? ""
            }
        }
        if title.isEmpty { title = app?.localizedName ?? "" }
        return SwitcherStrip.Tile(pid: entry.pid, windowID: entry.windowID, title: title, icon: app?.icon)
    }

    /// Raise a specific window and bring its app frontmost. Returns false if
    /// the window no longer exists.
    private func raise(_ entry: Entry) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated,
              let win = WindowManager.axWindow(pid: entry.pid, windowID: entry.windowID) else {
            return false
        }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        // Background app activating another app: NSRunningApplication.activate()
        // alone is ignored under macOS 14+ cooperative activation; the AX
        // frontmost attribute is honored for Accessibility-trusted apps.
        let axApp = AXUIElementCreateApplication(entry.pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [.activateIgnoringOtherApps])
        log("switcher: → \(app.localizedName ?? "pid \(entry.pid)") window \(entry.windowID)")
        return true
    }
}
