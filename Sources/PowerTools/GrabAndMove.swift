import Cocoa
import ApplicationServices

/// Grab & Move: hold a modifier combo (default ⌃⌘) and left-drag anywhere
/// INSIDE a window to move it — no hunting for the title bar. The AltDrag /
/// Easy Move+Resize behavior PowerToys users expect.
///
/// A second, mouse-only CGEventTap, separate from HotkeyMonitor's keyboard tap:
/// - the drag session is claimed on mouseDown (window hit-test via AX), so the
///   app under the cursor never sees the click
/// - a swallowed mouseDown ALWAYS swallows its mouseUp — no orphan click-release
/// - AX position writes are coalesced onto a serial queue so a slow app
///   (Electron sets can take 10-30ms) can never stall the event tap callback
/// - same tap hardening as HotkeyMonitor: re-enable on timeout/user-input
///   disable, plus a health timer
final class GrabAndMove {
    /// Modifier bits we compare against (device-specific bits stripped).
    private static let modMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    /// Set on main, read on the tap thread. `enabled` follows the plain-Bool
    /// discipline used by HotkeyMonitor.held; the flags rawValue is a single
    /// aligned 64-bit word (atomic loads/stores on Apple Silicon).
    private var enabled = false
    private var requiredMods: UInt64 = CGEventFlags([.maskControl, .maskCommand]).rawValue

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var healthTimer: Timer?

    // Drag session state — touched ONLY on the tap thread.
    private var dragging = false
    private var window: AXUIElement?
    private var startMouse = CGPoint.zero
    private var startPos = CGPoint.zero

    // Coalesced AX writes: the tap thread just records the latest target; one
    // worker drains it. Slow apps drop intermediate positions instead of
    // queueing a backlog.
    private let applyQueue = DispatchQueue(label: "grc-whisper.grabmove.apply", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pendingPos: CGPoint?
    private var pendingWindow: AXUIElement?
    private var applyScheduled = false

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GrabAndMove>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("grabmove: tap creation FAILED (missing Accessibility permission?)")
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        let thread = Thread { [weak self] in
            guard let self, let source = self.runLoopSource else { return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: self.enabled)
            CFRunLoopRun()
        }
        thread.name = "grc-whisper.grabmove"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.enabled, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                log("grabmove: tap found disabled by health check, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        log("grabmove: listening (enabled \(enabled))")
        return true
    }

    func stop() {
        healthTimer?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop = threadRunLoop { CFRunLoopStop(runLoop) }
    }

    /// Live config push (main thread). Disabling also disables the tap itself,
    /// so an off feature costs zero per-click overhead.
    func update(enabled: Bool, modifiers: CGEventFlags) {
        requiredMods = modifiers.intersection(Self.modMask).rawValue
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("grabmove: tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        switch type {
        case .leftMouseDown:
            // A mouseDown while a session thinks it's dragging means we missed
            // the mouseUp (tap died mid-drag) — reset, never move on stale state.
            dragging = false
            window = nil
            guard enabled,
                  event.flags.intersection(Self.modMask).rawValue == requiredMods,
                  requiredMods != 0
            else { return Unmanaged.passUnretained(event) }
            let loc = event.location  // CG global, top-left origin — same space as AX
            guard let win = movableWindow(at: loc), let pos = axPosition(win) else {
                return Unmanaged.passUnretained(event)
            }
            window = win
            startMouse = loc
            startPos = pos
            dragging = true
            return nil  // claim the click — the app under the cursor never sees it

        case .leftMouseDragged:
            guard dragging, let win = window else { return Unmanaged.passUnretained(event) }
            let loc = event.location
            enqueueMove(win, to: CGPoint(x: startPos.x + (loc.x - startMouse.x),
                                         y: startPos.y + (loc.y - startMouse.y)))
            return nil

        case .leftMouseUp:
            guard dragging else { return Unmanaged.passUnretained(event) }
            dragging = false
            window = nil
            return nil  // pair of the swallowed mouseDown

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: Window hit-test (tap thread, mouseDown only)

    /// The movable window under a point, or nil to let the click through:
    /// no AX element there (desktop/menu bar), it's one of OUR windows
    /// (palettes/overlays), or its position isn't settable (Dock, fullscreen).
    private func movableWindow(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                               Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }

        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() { return nil }

        guard let win = containingWindow(of: element) else { return nil }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(win, kAXPositionAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        return win
    }

    /// The AXWindow that owns an element: its kAXWindowAttribute if present,
    /// else walk parents (bounded — AX trees are shallow but can be cyclic in
    /// buggy apps).
    private func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &ref) == .success,
           let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            return (ref as! AXUIElement)
        }
        var current = element
        for _ in 0..<12 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef) == .success,
               roleRef as? String == kAXWindowRole {
                return current
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return nil }
            current = (parentRef as! AXUIElement)
        }
        return nil
    }

    private func axPosition(_ win: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &pos) else { return nil }
        return pos
    }

    // MARK: Coalesced position writes

    private func enqueueMove(_ win: AXUIElement, to point: CGPoint) {
        pendingLock.lock()
        pendingPos = point
        pendingWindow = win
        let schedule = !applyScheduled
        if schedule { applyScheduled = true }
        pendingLock.unlock()
        guard schedule else { return }
        applyQueue.async { [weak self] in self?.drainMoves() }
    }

    private func drainMoves() {
        while true {
            pendingLock.lock()
            guard let point = pendingPos, let win = pendingWindow else {
                applyScheduled = false
                pendingLock.unlock()
                return
            }
            pendingPos = nil
            pendingLock.unlock()
            var pos = point
            if let val = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, val)
            }
        }
    }
}
