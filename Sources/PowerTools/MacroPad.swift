import Cocoa
import ScreenCaptureKit
import Carbon.HIToolbox

/// On-screen macro pad — a software Stream Deck. A floating, NON-ACTIVATING
/// panel of buttons that swaps its profile with the frontmost app; clicking a
/// button never steals focus, so the synthesized keystrokes land in the app
/// in front. First shipped profile shape: Outlook folder filing — each button
/// runs ⌘⇧M → types the folder name into the Move dialog's filter → ⏎.
///
/// Suggestions: buttons may carry keywords ("APS", "american water"). While
/// the pad is open over its profile's app, the right half of that app's window
/// (the reading pane — the left half is the folder sidebar, whose folder NAMES
/// would false-match every keyword) is screenshotted and OCR'd on-device, and
/// buttons whose keywords appear get highlighted. Nothing leaves the Mac.
@MainActor
final class MacroPad {
    private var panel: NSPanel?
    private var padView: MacroPadView?
    private var profiles: [Config.MacroProfile] = []
    private var dark = true
    private var onAction: ((Config.MacroButton, String) -> Void)?
    /// Last non-self frontmost app: the profile shown AND the macro target.
    private(set) var currentBundleID: String?
    private var currentAppName = ""
    /// Hotkey display name for the footer hint ("hold ⌥⇧ + digit").
    private var hotkeyName = ""
    /// Panel top-left, preserved across re-renders and off/on toggles so the
    /// pad stays where the user dragged it.
    private var savedTopLeft: NSPoint?
    /// Traffic-light mode (same discipline as AgentPad): the header "–"
    /// collapses the pad to a strip of squares — one per macro, lit when its
    /// keywords are on screen — hovering the strip peeks the full pad, leaving
    /// it drops back to the strip. Sticky: survives dismiss and restarts.
    private var miniPreferred = false
    private var miniActive = false
    /// Docking: drop the pad near a corner or edge midpoint and it snaps
    /// there; every re-render (mini↔full, profile swaps) re-anchors to the
    /// same spot until the user drags it away again. Geometry in PadDock;
    /// placement persists across restarts via PadPlacement.
    private var dockAnchor: PadDock?
    private let dockOverlay = PadDockOverlay()
    private static let placementKey = "macro"
    private var suggestTask: Task<Void, Never>?
    private var suggestTimer: Timer?
    /// Generation counter: a scan may only touch shared state (suggestTask,
    /// scanning flag, highlights) while its generation is still current —
    /// dismiss/app-switch bump it so a stale scan's cleanup can't clobber the
    /// registration of a newer one (same discipline as AppController.cycle).
    private var scanGen = 0
    /// Skip re-OCR when the window pixels haven't changed since the last scan.
    private var lastCapture: Data?

    var isVisible: Bool { panel != nil }
    /// Fired on show/hide and profile swaps so the hotkey tap knows when (and
    /// for how many buttons) leader digits should fire.
    var onStateChanged: ((_ visible: Bool, _ buttonCount: Int) -> Void)?

    private func notifyState() {
        var count = 0
        if isVisible, let id = currentBundleID { count = profile(for: id)?.buttons.count ?? 0 }
        onStateChanged?(isVisible, count)
    }

    /// Button `index` of the current profile, for leader-digit firing.
    func buttonForDigit(_ index: Int) -> (button: Config.MacroButton, bundleID: String)? {
        guard isVisible, let id = currentBundleID, let profile = profile(for: id),
              index < profile.buttons.count else { return nil }
        return (profile.buttons[index], id)
    }

    /// Brief pressed-state flash so a leader-digit fire is visible on the pad.
    func flashButton(_ index: Int) {
        padView?.flash(index)
    }

    func present(profiles: [Config.MacroProfile], dark: Bool, screen: NSScreen,
                 hotkeyName: String, frontApp: NSRunningApplication?,
                 onAction: @escaping (Config.MacroButton, String) -> Void) {
        self.profiles = profiles
        self.dark = dark
        self.hotkeyName = hotkeyName
        self.onAction = onAction
        if let app = frontApp, app.bundleIdentifier != "com.grc.whisper" {
            currentBundleID = app.bundleIdentifier
            currentAppName = app.localizedName ?? "App"
        }
        // First present after launch: restore where the user last left the pad
        // (dock anchor or free-float corner) — placement survives restarts.
        if panel == nil, dockAnchor == nil, savedTopLeft == nil,
           let saved = PadPlacement.load(Self.placementKey) {
            dockAnchor = saved.anchor
            if saved.anchor == nil, let x = saved.x, let y = saved.y {
                savedTopLeft = NSPoint(x: x, y: y)
            }
            miniPreferred = saved.mini ?? false
            miniActive = miniPreferred
        }
        buildPanel(on: screen)
        render(on: screen)   // render ends with notifyState()
        startSuggestTimer()
        persistPlacement()   // open=true — survives quits/deploys for launch restore
    }

    func dismiss() {
        if let panel {
            savedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
            persistPlacement(open: false)
        }
        dockOverlay.hide()
        invalidateScan()
        suggestTimer?.invalidate()
        suggestTimer = nil
        lastCapture = nil
        panel?.orderOut(nil)
        panel = nil
        padView = nil
        notifyState()
    }

    /// open defaults true — every save except the user's explicit dismiss
    /// happens while the pad is up, so a quit/deploy leaves open=true behind.
    private func persistPlacement(open: Bool = true) {
        guard let panel else { return }
        PadPlacement.save(Self.placementKey, anchor: dockAnchor,
                          topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY),
                          mini: miniPreferred, open: open)
    }

    /// After a drag: snap to the nearest anchor when dropped close enough,
    /// otherwise stay free-floating; either way the placement is persisted.
    /// Internal (not private) so the macropad-live-test harness can invoke it
    /// without a real mouse drag.
    func snapAfterDrag() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let field = PadDock.Field(screen: screen)
        if let hit = PadDock.nearest(to: panel.frame.origin, size: panel.frame.size, in: field) {
            dockAnchor = hit.anchor
            panel.setFrame(NSRect(origin: hit.origin, size: panel.frame.size), display: true, animate: true)
            // A notch berth flips the mini strip horizontal, so re-render at the
            // new size and let the anchor re-place it.
            render(preservingHighlights: true)
        } else {
            dockAnchor = nil
        }
        persistPlacement()
    }

    /// Cancel any in-flight scan and retire its generation so its cleanup /
    /// result can no longer touch current state.
    private func invalidateScan() {
        scanGen += 1
        suggestTask?.cancel()
        suggestTask = nil
        padView?.scanning = false
    }

    /// Live config propagation (Settings edits apply without reopening).
    func update(enabled: Bool, profiles: [Config.MacroProfile], dark: Bool) {
        self.profiles = profiles
        self.dark = dark
        if !enabled { dismiss(); return }
        if isVisible { render() }
    }

    /// Frontmost app changed (fed from AppController's workspace observer).
    /// Our own app is ignored so opening Settings doesn't blank the pad.
    func frontmostChanged(bundleID: String?, name: String?) {
        guard let bundleID, bundleID != "com.grc.whisper" else { return }
        guard bundleID != currentBundleID else { return }
        currentBundleID = bundleID
        currentAppName = name ?? "App"
        lastCapture = nil
        // A scan of the OLD app's window must not light up the NEW profile.
        invalidateScan()
        if isVisible { render() }
    }

    // MARK: Panel

    private func buildPanel(on screen: NSScreen) {
        if panel != nil { return }
        let view = MacroPadView(dark: dark)
        view.onTap = { [weak self] index in
            guard let self, let bundleID = self.currentBundleID,
                  let profile = self.profile(for: bundleID),
                  index < profile.buttons.count else { return }
            self.onAction?(profile.buttons[index], bundleID)
        }
        view.onClose = { [weak self] in self?.dismiss() }
        view.onRescan = { [weak self] in
            self?.lastCapture = nil
            self?.refreshSuggestions()
        }
        view.onMinimize = { [weak self] in
            guard let self else { return }
            // Toggle: from full → traffic lights; from a peeked pad (hover-
            // expanded strip) → pin it back to full-time.
            self.miniPreferred.toggle()
            self.miniActive = self.miniPreferred
            self.render(preservingHighlights: true)
            self.persistPlacement()
        }
        view.onExpand = { [weak self] in
            guard let self, self.miniActive else { return }
            self.miniActive = false
            self.render(preservingHighlights: true)
        }
        view.onCollapse = { [weak self] in
            guard let self, self.miniPreferred, !self.miniActive else { return }
            self.miniActive = true
            self.render(preservingHighlights: true)
        }
        view.onDragMoved = { [weak self] in
            guard let self, let panel = self.panel, let screen = panel.screen ?? NSScreen.main else { return }
            self.dockOverlay.update(padFrame: panel.frame, on: screen, dark: self.dark)
        }
        view.onDragEnd = { [weak self] in
            self?.dockOverlay.hide()
            self?.snapAfterDrag()
        }
        let win = NSPanel(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view
        panel = win
        padView = view
        win.orderFrontRegardless()
    }

    private func render(on screen: NSScreen? = nil, preservingHighlights: Bool = false) {
        guard let panel, let view = padView else { return }
        // Mini↔full toggles keep the current OCR highlights (the strip's lit
        // squares are why the user peeked); every other render clears them via
        // configure() and forces the next scan to re-OCR.
        let hits = preservingHighlights ? view.suggested : []
        if !preservingHighlights { lastCapture = nil }
        // Only the SHELF berth straddles the housing, so it alone needs the
        // housing's box: collapsed it lays marks either side of it, expanded it
        // hangs below it. The shoulders sit in plain menu-bar pixels and need
        // neither. The screen is the controller's to know, not the view's.
        let shelf = dockAnchor?.absorbsNotch == true
        var notchSpan: CGFloat = 0
        var notchHeight: CGFloat = 0
        if shelf, let s = screen ?? panel.screen ?? NSScreen.main {
            let notch = PadDock.Field(screen: s).notch
            notchSpan = notch.width
            notchHeight = notch.height
        }
        var current: Config.MacroProfile?
        if let id = currentBundleID { current = profile(for: id) }
        view.configure(appName: currentAppName.isEmpty ? "No app" : currentAppName,
                       buttons: current?.buttons ?? [], dark: dark, hotkeyName: hotkeyName,
                       mini: miniActive, peeking: miniPreferred && !miniActive,
                       berth: dockAnchor?.isNotch == true, shelf: shelf,
                       notchSpan: notchSpan, notchHeight: notchHeight)
        view.suggested = hits
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        // A panel shadow over the menu bar is the loudest tell that this is a
        // floating window rather than a bar item.
        panel.hasShadow = !view.berth

        // Docked: pin to the anchor for whatever size this render came out at,
        // so the mini strip parks in the same corner as the full pad.
        if let dockAnchor, let padScreen = screen ?? panel.screen ?? NSScreen.main {
            savedTopLeft = nil
            let origin = dockAnchor.origin(for: size, in: PadDock.Field(screen: padScreen))
            let target = NSRect(origin: origin, size: size)
            // Berthed: grow and shrink OUT OF the notch instead of cutting to
            // the new size. The top edge is pinned to the screen, so animating
            // the frame reads as the housing itself opening and closing.
            if dockAnchor.isNotch, panel.isVisible, panel.frame.size != size {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(target, display: true)
                }
            } else {
                panel.setFrame(target, display: true)
            }
            refreshSuggestions()
            notifyState()
            return
        }

        // Keep the top-left corner anchored so profile swaps don't make the pad
        // jump; first show defaults to the right edge of the screen.
        let topLeft: NSPoint
        if let saved = savedTopLeft {
            topLeft = saved
        } else if panel.frame.origin == .zero {
            let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            topLeft = NSPoint(x: vf.maxX - size.width - 24, y: vf.midY + size.height / 2)
        } else {
            topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        savedTopLeft = nil
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        // Clamp fully on-screen (a grown button list must not sink off the bottom).
        if let vf = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, vf.minX + 8), vf.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, vf.minY + 8), vf.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: true)
        refreshSuggestions()
        notifyState()
    }

    private func profile(for bundleID: String) -> Config.MacroProfile? {
        profiles.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    // MARK: Chords

    /// "cmd+shift+m" → keycode + flags. Last token is the key (letter, digit,
    /// or return/enter/tab/space/esc/delete); the rest are modifiers.
    static func parseChord(_ chord: String) -> (key: CGKeyCode, flags: CGEventFlags)? {
        let parts = chord.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyToken = parts.last, !keyToken.isEmpty else { return nil }
        var flags: CGEventFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            default: return nil
            }
        }
        let named: [String: Int64] = [
            "return": 36, "enter": 76, "tab": 48, "space": 49, "esc": 53, "escape": 53, "delete": 51,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        ]
        if let kc = named[keyToken] { return (CGKeyCode(kc), flags) }
        if keyToken.count == 1, let kc = HotkeyMonitor.keyCode(forLetter: keyToken) { return (CGKeyCode(kc), flags) }
        return nil
    }

    // MARK: Suggestions

    private func startSuggestTimer() {
        suggestTimer?.invalidate()
        suggestTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSuggestions() }
        }
    }

    private func refreshSuggestions() {
        guard isVisible, let bundleID = currentBundleID, let profile = profile(for: bundleID) else { return }
        let keyworded = profile.buttons.contains { !$0.keywords.trimmingCharacters(in: .whitespaces).isEmpty }
        guard keyworded, CGPreflightScreenCaptureAccess() else { return }
        // Only scan while the target app is actually in front — its window is
        // what the user is reading, and capture of an occluded window is stale.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
        guard suggestTask == nil else { return }   // one scan in flight at a time
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let wid = Self.frontWindowID(pid: app.processIdentifier) else { return }

        scanGen += 1
        let gen = scanGen
        padView?.scanning = true
        suggestTask = Task { [weak self] in
            defer {
                // Only the still-current scan may clear the registration — a
                // superseded one would clobber its successor's bookkeeping.
                if let self, self.scanGen == gen {
                    self.suggestTask = nil
                    self.padView?.scanning = false
                }
            }
            guard let png = await Self.captureReadingPanePNG(windowID: wid) else { return }
            guard let self, self.scanGen == gen, !Task.isCancelled else { return }
            if png == self.lastCapture { return }   // window unchanged — keep current highlights
            self.lastCapture = png
            let text = await Task.detached(priority: .utility) { ScreenCapture.ocr(png).lowercased() }.value
            guard self.scanGen == gen, !Task.isCancelled,
                  let id = self.currentBundleID, let profile = self.profile(for: id) else { return }
            var hits: Set<Int> = []
            for (i, btn) in profile.buttons.enumerated() {
                let kws = btn.keywords.lowercased().split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if kws.contains(where: { text.contains($0) }) { hits.insert(i) }
            }
            self.padView?.suggested = hits
        }
    }

    /// Frontmost (layer-0, reasonably sized) window of `pid`; the CGWindowList
    /// is front-to-back so the first match is the one the user sees.
    private static func frontWindowID(pid: pid_t) -> CGWindowID? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]]) ?? []
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 300, (b["Height"] ?? 0) >= 200,
                  let wid = w[kCGWindowNumber as String] as? Int else { continue }
            return CGWindowID(wid)
        }
        return nil
    }

    /// One-shot SCK screenshot of the window, cropped to its right half — in a
    /// mail client that's the reading pane; the left half holds the folder
    /// sidebar and message list, which would false-match folder keywords.
    private static func captureReadingPanePNG(windowID: CGWindowID) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let scWin = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(scWin.frame.width * 2)    // 2× for OCR-able text on retina
        cfg.height = Int(scWin.frame.height * 2)
        cfg.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: scWin)
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        else { return nil }
        let half = cg.cropping(to: CGRect(x: cg.width / 2, y: 0,
                                          width: cg.width - cg.width / 2, height: cg.height)) ?? cg
        return NSBitmapImageRep(cgImage: half).representation(using: .png, properties: [:])
    }
}

/// The pad canvas: app-name header with rescan (↻) and close (✕), then one
/// full-width button per macro. Suggested buttons get an accent ring. Empty
/// area drags the panel.
final class MacroPadView: NSView {
    var onTap: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onRescan: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onDragMoved: (() -> Void)?
    var onDragEnd: (() -> Void)?

    /// Manual drag (instead of performDrag, which blocks until mouse-up and
    /// gives no positions) so the dock overlay can live-update mid-drag.
    /// Grab point in window coords; each drag event moves the window by the
    /// cursor's offset from it.
    private var dragGrab: NSPoint?
    private var dragDidMove = false

    fileprivate func beginDrag(_ event: NSEvent) {
        dragGrab = event.locationInWindow
        dragDidMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab = dragGrab, let window else { return }
        dragDidMove = true
        let o = window.frame.origin
        window.setFrameOrigin(NSPoint(x: o.x + event.locationInWindow.x - grab.x,
                                      y: o.y + event.locationInWindow.y - grab.y))
        onDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragGrab != nil else { return }
        dragGrab = nil
        // A plain click on empty space is not a drop — only a real move snaps.
        if dragDidMove { onDragEnd?() }
        dragDidMove = false
    }
    var suggested: Set<Int> = [] { didSet { needsDisplay = true } }
    var scanning = false { didSet { needsDisplay = true } }

    private var appName = ""
    private var buttons: [Config.MacroButton] = []
    private var dark: Bool
    private var mini = false
    /// Parked on a notch berth: the strip lies down into a row (a column would
    /// drape off the menu bar and down the screen) and the pad takes on the
    /// housing's silhouette and black — see `shellClip`.
    private(set) var berth = false
    /// On the SHELF berth the pad pads out to at least this wide so the
    /// housing disappears into it; 0 elsewhere. Set by the controller,
    /// which is the side that knows the screen.
    private var shelf = false
    /// The housing's own box, on the shelf berth. The middle of that box has no
    /// display behind it — anything drawn there lands in the framebuffer (a
    /// screencapture even shows it) but never on the glass.
    private var notchSpan: CGFloat = 0
    private var notchHeight: CGFloat = 0

    /// COLLAPSED on the shelf, the marks FLANK the housing: a leading cluster in
    /// the left shoulder, a trailing one in the right, both real pixels. That is
    /// the compact Dynamic Island layout, and it beats hanging below the housing
    /// because it costs no vertical space at all.
    private var flanked: Bool { shelf && mini && notchSpan > 0 }
    /// EXPANDED there is nothing like enough room in the shoulders, so the pad
    /// hangs below the housing and its top band is dead space kept black to
    /// fuse with the hardware.
    private var contentTop: CGFloat { shelf && !mini ? notchHeight : 0 }

    /// Mouse point in content space — see `contentTop`.
    private func localPoint(_ event: NSEvent) -> NSPoint {
        var p = convert(event.locationInWindow, from: nil)
        p.y -= contentTop
        return p
    }

    /// Marks are split as evenly as possible, the extra one going leading.
    /// Where macro light `i` sits: a column on the edge anchors, a row on a
    /// shoulder berth, and split either side of the housing on the shelf —
    /// where the middle of the pill has no display behind it.
    private func miniMark(_ i: Int) -> NSRect {
        guard berth else {
            return NSRect(x: Self.miniPad, y: Self.miniPad + CGFloat(i) * (Self.sq + Self.sqGap),
                          width: Self.sq, height: Self.sq)
        }
        let step = Self.berthSq + Self.berthGap
        guard flanked else {
            return NSRect(x: Self.miniPad + CGFloat(i) * step, y: Self.miniPad,
                          width: Self.berthSq, height: Self.berthSq)
        }
        let (lead, _) = flankSplit(buttons.count)
        let y = (bounds.height - Self.berthSq) / 2
        if i < lead {
            let x0 = (bounds.width - notchSpan) / 2 - Self.miniPad - markRun(lead)
            return NSRect(x: x0 + CGFloat(i) * step, y: y, width: Self.berthSq, height: Self.berthSq)
        }
        let x0 = (bounds.width + notchSpan) / 2 + Self.miniPad
        return NSRect(x: x0 + CGFloat(i - lead) * step, y: y, width: Self.berthSq, height: Self.berthSq)
    }

    /// Width of a row of `count` marks.
    private func markRun(_ count: Int) -> CGFloat {
        count <= 0 ? 0 : CGFloat(count) * Self.berthSq + CGFloat(count - 1) * Self.berthGap
    }

    private func flankSplit(_ total: Int) -> (leading: Int, trailing: Int) {
        let n = max(total, 1)
        let leading = (n + 1) / 2
        return (leading, n - leading)
    }
    private var peeking = false   // hover-expanded from the strip; – becomes □
    private var hotkeyName = ""
    private var hovered: Int?
    private var pressed: Int?

    private static let width: CGFloat = 220
    private static let pad: CGFloat = 10
    private static let headerH: CGFloat = 30
    private static let btnH: CGFloat = 30
    private static let gap: CGFloat = 5
    private static let emptyH: CGFloat = 52
    private static let footerH: CGFloat = 17
    private static let sq: CGFloat = 14      // traffic-light square
    private static let sqGap: CGFloat = 4
    private static let miniPad: CGFloat = 7
    /// The notch strip runs smaller than the edge-anchor strip — there is very
    /// little room beside the housing.
    private static let berthSq: CGFloat = 9
    private static let berthGap: CGFloat = 5

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(appName: String, buttons: [Config.MacroButton], dark: Bool, hotkeyName: String = "",
                   mini: Bool = false, peeking: Bool = false, berth: Bool = false, shelf: Bool = false,
                   notchSpan: CGFloat = 0, notchHeight: CGFloat = 0) {
        self.appName = appName
        self.buttons = buttons
        self.dark = dark
        self.mini = mini
        self.berth = berth
        self.shelf = shelf
        self.notchSpan = notchSpan
        self.notchHeight = notchHeight
        self.peeking = peeking
        self.hotkeyName = hotkeyName
        hovered = nil
        pressed = nil
        suggested = []
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    /// First click must register even while another app is active — that's the
    /// entire point of a non-activating pad.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var fittingSize: NSSize {
        if mini {
            let n = CGFloat(max(buttons.count, 1))
            if flanked {
                let (lead, trail) = flankSplit(buttons.count)
                let flank = max(markRun(lead), markRun(trail)) + Self.miniPad
                return NSSize(width: notchSpan + flank * 2,
                              height: max(notchHeight, Self.berthSq + Self.miniPad * 2))
            }
            if berth {
                return NSSize(width: Self.miniPad * 2 + markRun(Int(n)),
                              height: Self.miniPad * 2 + Self.berthSq)
            }
            let run = n * Self.sq + (n - 1) * Self.sqGap
            return NSSize(width: Self.miniPad * 2 + Self.sq, height: Self.miniPad * 2 + run)
        }
        let content = buttons.isEmpty
            ? Self.emptyH
            : CGFloat(buttons.count) * Self.btnH + CGFloat(buttons.count - 1) * Self.gap + Self.footerH
        return NSSize(width: Self.width,
                      height: Self.pad + Self.headerH + content + Self.pad + contentTop)
    }



    /// Parked on a notch berth, the pad wears the housing's own silhouette and
    /// colour: square against the top edge of the screen, rounded below, in
    /// black. The app's Dark/Lite setting does not enter into it — the camera
    /// housing is black on every Mac in every appearance, and matching it is
    /// what makes the pad read as the notch having grown rather than as a panel
    /// that happens to be parked nearby.
    private var shellRadius: CGFloat { mini ? 12 : 18 }

    /// Overshooting the top edge by the corner radius leaves ONLY the bottom
    /// corners rounded — the top butts flush against the screen edge.
    private func shellClip() -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 0, y: -shellRadius, width: bounds.width,
                                         height: bounds.height + shellRadius),
                     xRadius: shellRadius, yRadius: shellRadius)
    }

    private var onDark: Bool { berth ? true : dark }

    // Same palette as the other panels so everything feels like one system.
    private var bg: NSColor {
        if berth { return NSColor(white: 0.04, alpha: 0.97) }
        return dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98)
                    : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98)
    }
    private var fg: NSColor { onDark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private func buttonRect(_ i: Int) -> NSRect {
        NSRect(x: Self.pad, y: Self.pad + Self.headerH + CGFloat(i) * (Self.btnH + Self.gap),
               width: Self.width - Self.pad * 2, height: Self.btnH)
    }

    private var closeRect: NSRect { NSRect(x: Self.width - Self.pad - 18, y: Self.pad + 2, width: 18, height: 18) }
    private var rescanRect: NSRect { NSRect(x: Self.width - Self.pad - 40, y: Self.pad + 2, width: 18, height: 18) }
    private var minimizeRect: NSRect { NSRect(x: Self.width - Self.pad - 62, y: Self.pad + 2, width: 18, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        (berth ? shellClip()
               : NSBezierPath(roundedRect: bounds, xRadius: mini ? 9 : 14, yRadius: mini ? 9 : 14)).setClip()
        bg.setFill()
        bounds.fill()
        // Plate first, at full height, so the shell fuses with the housing —
        // then push every bit of content clear of the housing's dead band.
        if contentTop > 0 { NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: contentTop) }

        // Traffic lights: one square per macro in button order — a column on the
        // edge anchors, a row on the notch berths; a square lights up when its
        // keywords are on screen, so the collapsed strip still signals a match.
        if mini {
            if buttons.isEmpty {
                dim.withAlphaComponent(0.3).setFill()
                let empty = miniMark(0)
                NSBezierPath(roundedRect: empty, xRadius: berth ? 3 : 4, yRadius: berth ? 3 : 4).fill()
                return
            }
            for i in buttons.indices {
                let r = miniMark(i)
                let path = NSBezierPath(roundedRect: r, xRadius: berth ? 3 : 4, yRadius: berth ? 3 : 4)
                if i == pressed {
                    accent.withAlphaComponent(0.95).setFill()
                } else if suggested.contains(i) {
                    accent.withAlphaComponent(0.4).setFill()
                } else {
                    // In the bar there's no plate to read the empty slots
                    // against, so they carry their own contrast.
                    (onDark ? NSColor.white : .black).withAlphaComponent(berth ? 0.22 : 0.12).setFill()
                }
                path.fill()
                if suggested.contains(i) {
                    accent.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
            return
        }

        (appName as NSString).draw(
            at: NSPoint(x: Self.pad + 4, y: Self.pad + 3),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: fg])

        let glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: dim.withAlphaComponent(scanning ? 0.25 : 0.5),
        ]
        ("↻" as NSString).draw(in: rescanRect.offsetBy(dx: 3, dy: 1), withAttributes: glyphAttrs)
        ("✕" as NSString).draw(in: closeRect.offsetBy(dx: 3, dy: 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: dim])
        // – collapses to traffic lights; □ (while peeking) pins full mode back.
        ((peeking ? "□" : "–") as NSString).draw(in: minimizeRect.offsetBy(dx: 4, dy: 1), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: dim])

        if buttons.isEmpty {
            let msg = "No macros for \(appName)\nAdd them in Settings ▸ Macro Pad" as NSString
            let p = NSMutableParagraphStyle()
            p.alignment = .center
            p.lineSpacing = 3
            msg.draw(in: NSRect(x: Self.pad, y: Self.pad + Self.headerH + 6,
                                width: Self.width - Self.pad * 2, height: Self.emptyH),
                     withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim, .paragraphStyle: p])
            return
        }

        for (i, btn) in buttons.enumerated() {
            let r = buttonRect(i)
            let isHover = i == hovered
            let isPressed = i == pressed
            let isSuggested = suggested.contains(i)
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            if isPressed {
                accent.withAlphaComponent(0.85).setFill()
            } else if isHover {
                accent.withAlphaComponent(0.35).setFill()
            } else if isSuggested {
                accent.withAlphaComponent(0.18).setFill()
            } else {
                (dark ? NSColor.white : .black).withAlphaComponent(0.06).setFill()
            }
            path.fill()
            if isSuggested {
                accent.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            // Digit badge for the first ten buttons (hold hotkey + digit fires it).
            var titleX = r.minX + 10
            if i < 10 {
                let digit = "\((i + 1) % 10)" as NSString
                digit.draw(at: NSPoint(x: r.minX + 8, y: r.minY + 9), withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: isPressed ? NSColor.white.withAlphaComponent(0.85) : dim,
                ])
                titleX = r.minX + 22
            }
            let title = btn.title as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isSuggested ? .semibold : .regular),
                .foregroundColor: isPressed ? NSColor.white : fg,
                .paragraphStyle: {
                    let p = NSMutableParagraphStyle()
                    p.lineBreakMode = .byTruncatingTail
                    return p
                }(),
            ]
            title.draw(in: NSRect(x: titleX, y: r.minY + 7, width: r.maxX - 10 - titleX, height: 16), withAttributes: attrs)
        }

        // The digits are LEADER keys — without this line nobody guesses that.
        let hint = "hold \(hotkeyName.isEmpty ? "hotkey" : hotkeyName) + digit · click also works" as NSString
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: dim.withAlphaComponent(0.35),
        ]
        let hintSize = hint.size(withAttributes: hintAttrs)
        hint.draw(at: NSPoint(x: bounds.midX - hintSize.width / 2, y: bounds.height - Self.pad - 12),
                  withAttributes: hintAttrs)
    }

    /// Preview hook (macropad-preview CLI) — set state without live capture.
    func previewState(hover: Int?, suggested: Set<Int>) {
        hovered = hover
        self.suggested = suggested
        needsDisplay = true
    }

    /// Pressed-state flash (mouse click and leader-digit fire share it).
    func flash(_ i: Int) {
        pressed = i
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(140)) { [weak self] in
            self?.pressed = nil
            self?.needsDisplay = true
        }
    }

    /// Test hook: how many lights the strip is actually drawing, so a size
    /// assertion can tell "collapsed to one" from "collapsed to four".
    var buttonCount: Int { buttons.count }

    override func mouseDown(with event: NSEvent) {
        if mini {
            beginDrag(event)
            return
        }
        let p = localPoint(event)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { onClose?(); return }
        if rescanRect.insetBy(dx: -4, dy: -4).contains(p) { onRescan?(); return }
        if minimizeRect.insetBy(dx: -4, dy: -4).contains(p) { onMinimize?(); return }
        if let i = buttons.indices.first(where: { buttonRect($0).contains(p) }) {
            flash(i)
            onTap?(i)
            return
        }
        beginDrag(event)   // anywhere else moves the pad
    }

    override func mouseMoved(with event: NSEvent) {
        if mini { onExpand?(); return }
        let p = localPoint(event)
        let h = buttons.indices.first { buttonRect($0).contains(p) }
        if h != hovered {
            hovered = h
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        if !mini { onCollapse?() }   // no-op unless this pad lives in mini mode
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
}
