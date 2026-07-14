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
    /// Panel top-left, preserved across re-renders and off/on toggles so the
    /// pad stays where the user dragged it.
    private var savedTopLeft: NSPoint?
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

    func present(profiles: [Config.MacroProfile], dark: Bool, screen: NSScreen,
                 frontApp: NSRunningApplication?,
                 onAction: @escaping (Config.MacroButton, String) -> Void) {
        self.profiles = profiles
        self.dark = dark
        self.onAction = onAction
        if let app = frontApp, app.bundleIdentifier != "com.grc.whisper" {
            currentBundleID = app.bundleIdentifier
            currentAppName = app.localizedName ?? "App"
        }
        buildPanel(on: screen)
        render(on: screen)
        startSuggestTimer()
    }

    func dismiss() {
        if let panel { savedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY) }
        invalidateScan()
        suggestTimer?.invalidate()
        suggestTimer = nil
        lastCapture = nil
        panel?.orderOut(nil)
        panel = nil
        padView = nil
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

    private func render(on screen: NSScreen? = nil) {
        guard let panel, let view = padView else { return }
        lastCapture = nil   // configure() clears highlights; force the next scan to re-OCR
        var current: Config.MacroProfile?
        if let id = currentBundleID { current = profile(for: id) }
        view.configure(appName: currentAppName.isEmpty ? "No app" : currentAppName,
                       buttons: current?.buttons ?? [], dark: dark)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)

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
    var suggested: Set<Int> = [] { didSet { needsDisplay = true } }
    var scanning = false { didSet { needsDisplay = true } }

    private var appName = ""
    private var buttons: [Config.MacroButton] = []
    private var dark: Bool
    private var hovered: Int?
    private var pressed: Int?

    private static let width: CGFloat = 220
    private static let pad: CGFloat = 10
    private static let headerH: CGFloat = 30
    private static let btnH: CGFloat = 30
    private static let gap: CGFloat = 5
    private static let emptyH: CGFloat = 52

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(appName: String, buttons: [Config.MacroButton], dark: Bool) {
        self.appName = appName
        self.buttons = buttons
        self.dark = dark
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
        let content = buttons.isEmpty
            ? Self.emptyH
            : CGFloat(buttons.count) * Self.btnH + CGFloat(buttons.count - 1) * Self.gap
        return NSSize(width: Self.width, height: Self.pad + Self.headerH + content + Self.pad)
    }

    // Same palette as the other panels so everything feels like one system.
    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private func buttonRect(_ i: Int) -> NSRect {
        NSRect(x: Self.pad, y: Self.pad + Self.headerH + CGFloat(i) * (Self.btnH + Self.gap),
               width: Self.width - Self.pad * 2, height: Self.btnH)
    }

    private var closeRect: NSRect { NSRect(x: Self.width - Self.pad - 18, y: Self.pad + 2, width: 18, height: 18) }
    private var rescanRect: NSRect { NSRect(x: Self.width - Self.pad - 40, y: Self.pad + 2, width: 18, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).setClip()
        bg.setFill()
        bounds.fill()

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
            title.draw(in: NSRect(x: r.minX + 10, y: r.minY + 7, width: r.width - 20, height: 16), withAttributes: attrs)
        }
    }

    /// Preview hook (macropad-preview CLI) — set state without live capture.
    func previewState(hover: Int?, suggested: Set<Int>) {
        hovered = hover
        self.suggested = suggested
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) { onClose?(); return }
        if rescanRect.insetBy(dx: -4, dy: -4).contains(p) { onRescan?(); return }
        if let i = buttons.indices.first(where: { buttonRect($0).contains(p) }) {
            pressed = i
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(140)) { [weak self] in
                self?.pressed = nil
                self?.needsDisplay = true
            }
            onTap?(i)
            return
        }
        window?.performDrag(with: event)   // anywhere else moves the pad
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = buttons.indices.first { buttonRect($0).contains(p) }
        if h != hovered {
            hovered = h
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
}
