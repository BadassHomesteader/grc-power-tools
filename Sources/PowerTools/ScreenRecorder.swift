import Cocoa

/// Screen recording on hold + F — the moving-picture sibling of hold + S.
///
/// Flow: a full-screen `RegionPicker` on the mouse's screen (drag the area,
/// ⏎ = the whole display, Esc cancels) → the system recorder runs as a child
/// process, NON-interactive so the cursor is in the movie (`screencapture -C`
/// is refused in interactive mode, and a demo without the pointer is useless)
/// → a small ● badge counts the seconds and stops on click; hold + F again
/// stops too → the .mov lands on the Desktop, its file URL goes on the
/// clipboard (⌘V attaches it in Slack, Mail or Teams) and the Finder reveals
/// it.
///
/// No new permission: Screen Recording is already granted for T/S/G and the
/// app is the responsible process for its child. Deliberately independent of
/// the dictation state machine — dictating over a running recording is the
/// narrated-demo use case, not a conflict.
///
/// The movie is written only when the recorder stops (SIGINT is how it
/// finalizes — ctrl-C in a terminal), so nothing here may ever kill -9 it.
@MainActor
final class ScreenRecorder {
    enum Phase { case idle, picking, recording, stopping }
    private(set) var phase: Phase = .idle
    var isActive: Bool { phase != .idle }

    /// A movie was saved: its URL + how long it ran.
    var onSaved: ((URL, TimeInterval) -> Void)?
    var onFailed: ((String) -> Void)?
    var onCancelled: (() -> Void)?
    /// A movie finalized from a recorder the previous app instance left behind.
    var onRecovered: ((URL) -> Void)?
    /// Mirrored into the event tap: the F chord fires on keyDown, so the picker
    /// is up while the leader is still physically held — the tap must serve
    /// ⏎/Esc/arrows to the picker, not to the window chords.
    var onPickerVisibility: ((Bool) -> Void)?

    private let picker = RegionPicker()
    private let badge = RecordingBadge()
    private var process: Process?
    private var outputURL: URL?
    private var startedAt: Date?
    private var tickTimer: Timer?
    private var stopTimeout: Timer?
    /// Bumped per launch so a late termination callback from a previous
    /// recorder can't close the current one (house `cycle` pattern).
    private var generation = 0

    /// For harnesses: where the badge sits and whether it is kept out of captures.
    var badgeFrame: NSRect? { badge.frame }
    var badgeExcludedFromCapture: Bool { badge.sharingType == NSWindow.SharingType.none }

    /// Where movies go. Desktop matches the system's own ⇧⌘5 default — but the
    /// recorder only writes at STOP time, so an unwritable folder (Desktop
    /// access denied in Privacy & Security ▸ Files and Folders) would lose the
    /// whole recording. Probe first (this is also what raises the one-time
    /// Desktop prompt, before anything is recorded) and fall back to
    /// ~/Movies/Power Tools, which macOS never gates.
    static func resolveOutputFolder() -> URL {
        let fm = FileManager.default
        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first, isWritable(desktop) {
            return desktop
        }
        let movies = (fm.urls(for: .moviesDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser)
            .appendingPathComponent("Power Tools", isDirectory: true)
        try? fm.createDirectory(at: movies, withIntermediateDirectories: true)
        log("record: Desktop not writable — recording into \(movies.path)")
        return movies
    }

    private static func isWritable(_ dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".power-tools-write-probe")
        defer { try? FileManager.default.removeItem(at: probe) }
        return (try? Data().write(to: probe)) != nil
    }

    /// The system's own recordings use this exact naming, and a name only has
    /// second resolution — never hand the recorder a path that already exists
    /// (it would leave that file untouched on a failed save).
    static func uniqueURL(in folder: URL, now: Date = Date()) -> URL {
        let base = fileName(now: now)
        var url = folder.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(base.replacingOccurrences(of: ".mov", with: " \(n).mov"))
            n += 1
        }
        return url
    }

    // A crashed or force-quit app orphans the recorder: it keeps recording and
    // never finalizes, because SIGINT from us is its only save path. Remember
    // the child while it runs so the next launch can reap it.
    private static var stateURL: URL { Config.appSupportDir.appendingPathComponent("recording-in-progress.json") }
    private static func writeState(pid: Int32, path: String) {
        let obj: [String: Any] = ["pid": Int(pid), "path": path]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: stateURL) }
    }
    private static func clearState() { try? FileManager.default.removeItem(at: stateURL) }
    private static func commandName(_ pid: Int32) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Once at launch: finalize a recorder the previous instance left running.
    func recoverOrphan() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value,
              let path = obj["path"] as? String else { return }
        Self.clearState()
        guard kill(pid, 0) == 0, Self.commandName(pid).contains("screencapture") else {
            log("record: stale in-progress record (pid \(pid) is not a live recorder)")
            return
        }
        log("record: recovering an orphaned recorder from the last session (pid \(pid))")
        kill(pid, SIGINT)
        let url = URL(fileURLWithPath: path)
        Task { @MainActor [weak self] in
            for _ in 0..<40 {   // up to 8s for the movie to finalize
                try? await Task.sleep(nanoseconds: 200_000_000)
                if kill(pid, 0) != 0 { break }
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            if bytes > 0 {
                log("record: recovered \(url.lastPathComponent) \(bytes) bytes")
                self?.onRecovered?(url)
            } else {
                log("record: the orphaned recorder produced no movie")
            }
        }
    }

    /// hold + F while idle: pick an area, then record it.
    func begin(mic: Bool, dark: Bool) {
        guard phase == .idle else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { onFailed?("No display to record"); return }
        let prior = NSWorkspace.shared.frontmostApplication
        phase = .picking
        onPickerVisibility?(true)
        picker.present(screen: screen, dark: dark) { [weak self] region in
            guard let self else { return }
            self.onPickerVisibility?(false)
            // Give the user's app its focus back before the movie starts, so
            // the first frames show their work, not our picker's afterglow.
            prior?.activate()
            guard let region else {
                self.phase = .idle
                log("record: cancelled at the picker")
                self.onCancelled?()
                return
            }
            self.start(region: region, screen: screen, mic: mic, dark: dark)
        }
    }

    /// Leader-held ⏎ while the picker is up (routed through the tap).
    func pickWholeDisplay() { picker.chooseWholeDisplay() }

    /// Record `region` (global Cocoa coords, bottom-left origin) now. Internal
    /// so the `record-test` CLI can exercise the process path without a picker.
    func start(region requested: NSRect, screen: NSScreen, mic: Bool, dark: Bool) {
        guard phase == .idle || phase == .picking else { return }
        // A drag can run off the picked display (the window keeps mouse
        // capture); record only what is on that screen.
        let region = requested.intersection(screen.frame)
        // screencapture -R speaks CG coordinates: points, origin at the
        // primary display's TOP-left. Cocoa's origin is its BOTTOM-left.
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cg = CGRect(x: region.minX.rounded(), y: (primaryH - region.maxY).rounded(),
                        width: region.width.rounded(), height: region.height.rounded())
        guard !region.isNull, cg.width >= 2, cg.height >= 2 else {
            phase = .idle
            onFailed?("That area is too small to record")
            return
        }
        let url = Self.uniqueURL(in: Self.resolveOutputFolder())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        var args = ["-v", "-x", "-C", "-k",
                    "-R", "\(Int(cg.minX)),\(Int(cg.minY)),\(Int(cg.width)),\(Int(cg.height))"]
        if mic { args.append("-g") }
        args.append(url.path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()   // "Failed to save to final location …" belongs in the log
        p.standardError = errPipe
        generation += 1
        let gen = generation
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in self?.processEnded(gen: gen, status: status, stderr: err) }
        }
        do { try p.run() } catch {
            phase = .idle
            log("record: launch failed: \(error)")
            onFailed?("Couldn't start the screen recorder")
            return
        }
        process = p
        outputURL = url
        startedAt = Date()
        phase = .recording
        Self.writeState(pid: p.processIdentifier, path: url.path)
        log("record: started \(url.lastPathComponent) region \(Int(cg.minX)),\(Int(cg.minY)) \(Int(cg.width))×\(Int(cg.height))\(mic ? " +mic" : "")")
        badge.show(on: screen, around: region, dark: dark) { [weak self] in self?.stop() }
        tick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard phase == .recording, let startedAt else { return }
        badge.update(elapsed: Date().timeIntervalSince(startedAt))
    }

    /// hold + F while active, or a click on the badge. During the pick it just
    /// closes the picker.
    func stop() {
        switch phase {
        case .picking: picker.cancel(); return   // completion(nil) → idle
        case .recording: break
        case .idle, .stopping: return
        }
        phase = .stopping
        tickTimer?.invalidate(); tickTimer = nil
        badge.setSaving()
        process?.interrupt()   // SIGINT: the recorder writes the movie and exits
        let gen = generation
        stopTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.phase == .stopping else { return }
                log("record: recorder ignored SIGINT for 10s — terminating")
                self.process?.terminate()
            }
        }
    }

    private func processEnded(gen: Int, status: Int32, stderr: String) {
        guard gen == generation else { return }
        stopTimeout?.invalidate(); stopTimeout = nil
        tickTimer?.invalidate(); tickTimer = nil
        let askedToStop = phase == .stopping
        let began = startedAt ?? Date()
        let elapsed = Date().timeIntervalSince(began)
        let url = outputURL
        process = nil; outputURL = nil; startedAt = nil
        phase = .idle
        badge.hide()
        Self.clearState()
        if !stderr.isEmpty { log("record: recorder said: \(stderr)") }
        // Success = a movie THIS recording wrote (fresh mtime), not merely a
        // file at the path: the recorder leaves a pre-existing file untouched
        // when it fails to save, and its exit status alone is not the arbiter.
        let attrs = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let bytes = attrs?[.size] as? Int ?? 0
        let written = attrs?[.modificationDate] as? Date ?? .distantPast
        if let url, bytes > 0, written >= began.addingTimeInterval(-2) {
            log("record: saved \(url.lastPathComponent) \(bytes) bytes \(Int(elapsed))s status \(status)\(askedToStop ? "" : " (recorder ended on its own)")")
            onSaved?(url, elapsed)
        } else {
            log("record: nothing saved (status \(status), \(Int(elapsed))s, asked to stop: \(askedToStop), bytes \(bytes))")
            let folder = url?.deletingLastPathComponent().lastPathComponent ?? "the folder"
            onFailed?(stderr.contains("Failed to save")
                      ? "Recording failed — couldn't save into \(folder)"
                      : "Recording failed — nothing was saved")
        }
    }

    /// Quitting mid-recording: finalize rather than orphan the child, which
    /// would keep recording with no way left to stop it. Holds the quit for a
    /// few seconds at most.
    func shutdown() {
        guard let p = process, phase == .recording || phase == .stopping else { return }
        if phase == .recording { p.interrupt() }
        phase = .stopping
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        log("record: shutdown — recorder \(p.isRunning ? "still running" : "finalized")")
    }

    static func fileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screen Recording \(f.string(from: now)).mov"
    }

    /// "0:07", "12:34", "1:02:03" — a recording clock, not the agent pad's "2m".
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Full-screen "drag the area to record" overlay — the GridOverlay recipe
/// (KeyableWindow so Esc/⏎ arrive) minus the grid: a free rectangle, dimmed
/// outside, size readout, crosshair cursor. Covers the WHOLE screen (menu bar
/// included) so a full-display recording is one ⏎.
@MainActor
final class RegionPicker {
    private var window: NSWindow?
    private var completion: ((NSRect?) -> Void)?
    var isVisible: Bool { window != nil }

    /// `completion` gets the chosen rect in global Cocoa coords, or nil.
    func present(screen: NSScreen, dark: Bool, completion: @escaping (NSRect?) -> Void) {
        cancel()
        self.completion = completion
        let sf = screen.frame
        let win = KeyableWindow(contentRect: sf, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RegionPickView(dark: dark)
        view.frame = NSRect(origin: .zero, size: sf.size)
        view.onComplete = { [weak self] local in
            let global = local.map { NSRect(x: sf.minX + $0.minX, y: sf.minY + $0.minY,
                                            width: $0.width, height: $0.height) }
            self?.finish(global)
        }
        win.contentView = view
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)
        NSCursor.crosshair.set()
    }

    func cancel() { finish(nil) }
    func chooseWholeDisplay() { (window?.contentView as? RegionPickView)?.chooseWholeDisplay() }

    private func finish(_ rect: NSRect?) {
        guard let win = window else { return }
        window = nil
        win.orderOut(nil)
        NSCursor.arrow.set()
        let done = completion
        completion = nil
        done?(rect)
    }
}

/// The picker canvas. Non-flipped (y = 0 at the bottom) so rects are already
/// in Cocoa screen orientation.
final class RegionPickView: NSView {
    private let dark: Bool
    private var anchor: NSPoint?
    private var current: NSPoint?
    /// Selected rect in view coords, or nil to cancel.
    var onComplete: ((NSRect?) -> Void)?

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    /// For the offscreen `regionpicker-preview` design check.
    func previewSelect(_ a: NSPoint, _ b: NSPoint) {
        anchor = a; current = b; needsDisplay = true
    }

    private var selection: NSRect? {
        guard let a = anchor, let b = current else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The window keeps mouse capture during a drag, so the pointer can leave
    /// this display; the selection must not (GridView clamps the same way).
    private func clamped(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }
    func chooseWholeDisplay() { onComplete?(bounds) }

    override func mouseDown(with event: NSEvent) {
        anchor = clamped(event)
        current = anchor
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = clamped(event)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        current = clamped(event)
        // A bare click (or a twitch) cancels, like the grid — nobody wants a
        // 3-pixel movie.
        if let r = selection, r.width >= 20, r.height >= 20 { onComplete?(r.integral) }
        else { onComplete?(nil) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onComplete?(nil)            // Esc
        case 36, 76: chooseWholeDisplay()    // ⏎ / Enter — the whole display
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if let sel = selection { shade.appendRect(sel) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(dark ? 0.38 : 0.22).setFill()
        shade.fill()

        if let sel = selection {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
            outline.lineWidth = 1
            outline.stroke()
            let label = "\(Int(sel.width)) × \(Int(sel.height))"
            var at = NSPoint(x: sel.minX, y: sel.minY - 26)
            if at.y < 4 { at.y = sel.minY + 6 }
            drawPill(label, at: at)
        } else {
            let hint = "Drag the area to record   ·   ⏎ whole screen   ·   esc cancel"
            let size = pillSize(hint)
            drawPill(hint, at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 64))
        }
    }

    private var textAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
    }
    private func pillSize(_ text: String) -> NSSize {
        let s = (text as NSString).size(withAttributes: textAttrs)
        return NSSize(width: s.width + 20, height: s.height + 8)
    }
    private func drawPill(_ text: String, at origin: NSPoint) {
        let size = pillSize(text)
        let rect = NSRect(origin: origin, size: size)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: origin.x + 10, y: origin.y + 4), withAttributes: textAttrs)
    }
}

/// Exempt from CaptureVisibility on purpose: this one stays out of captures
/// even when the user shows Power Tools in them — a stop button in the middle
/// of your own demo is never wanted.
final class RecordingBadgePanel: NSPanel {}

/// The ● 0:12 pill: non-activating (clicking it never steals focus from the
/// app being recorded), click anywhere on it to stop.
@MainActor
final class RecordingBadge {
    private var panel: NSPanel?
    private var view: RecordingBadgeView?
    private var onStop: (() -> Void)?
    var frame: NSRect? { panel?.frame }
    var sharingType: NSWindow.SharingType? { panel?.sharingType }

    /// Sits just above the recorded region's top-right corner when there is
    /// room, else just below it, else inside its top-right — always on the
    /// same screen, covering as little of the region as it can.
    func show(on screen: NSScreen, around region: NSRect, dark: Bool, onStop: @escaping () -> Void) {
        hide()
        self.onStop = onStop
        let size = RecordingBadgeView.size
        let vf = screen.visibleFrame
        let x = min(max(region.maxX - size.width, vf.minX + 8), vf.maxX - size.width - 8)
        var y = region.maxY + 8
        if y + size.height > vf.maxY {
            y = region.minY - size.height - 8
            if y < vf.minY { y = region.maxY - size.height - 10 }
        }
        // A whole-display pick spans the menu bar: keep the badge below it.
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        let p = RecordingBadgePanel(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.sharingType = .none
        let v = RecordingBadgeView(dark: dark)
        v.frame = NSRect(origin: .zero, size: size)
        v.onClick = { [weak self] in self?.onStop?() }
        p.contentView = v
        panel = p
        view = v
        p.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval) { view?.elapsed = elapsed }
    func setSaving() { view?.saving = true }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
        onStop = nil
    }
}

final class RecordingBadgeView: NSView {
    static let size = NSSize(width: 112, height: 30)
    private let dark: Bool
    var elapsed: TimeInterval = 0 { didSet { needsDisplay = true } }
    var saving = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let fill = dark ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1)
                        : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1)
        let fg = dark ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.9)
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        ((pressed ? fill.blended(withFraction: 0.12, of: fg) : nil) ?? fill).setFill()
        pill.fill()
        if !dark {
            NSColor.black.withAlphaComponent(0.08).setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }

        // ● the record dot
        let dot = NSRect(x: 12, y: bounds.midY - 4.5, width: 9, height: 9)
        NSColor(srgbRed: 0.93, green: 0.23, blue: 0.2, alpha: 1).setFill()
        NSBezierPath(ovalIn: dot).fill()

        let text = saving ? "saving…" : ScreenRecorder.clock(elapsed)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: fg]
        let ts = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: 28, y: bounds.midY - ts.height / 2), withAttributes: attrs)

        // ■ the stop affordance
        if !saving {
            let sq = NSRect(x: bounds.maxX - 24, y: bounds.midY - 5, width: 10, height: 10)
            fg.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: sq, xRadius: 2, yRadius: 2).fill()
        }
    }
}
