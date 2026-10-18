import Cocoa

/// Chord mode (hold + Space): the panel down the left edge listing what can
/// be typed for the front app, filtered as the code grows, and the bookkeeping
/// that turns the typed code into a ChordEntry on release. Display only —
/// it never takes key or mouse; HotkeyMonitor feeds it the keys.
@MainActor
final class ChordMode {
    private var panel: NSPanel?
    private var view: ChordPanelView?
    private var screen: NSScreen?
    /// The app in front when chord mode opened — the one the chord runs in.
    private(set) var targetApp: NSRunningApplication?
    private var entries: [ChordEntry] = []
    private var menuLoaded = true
    private var buffer = ""
    /// Bumped on every open and close, so a menu walk that lands late never
    /// touches a session it didn't start.
    private var gen = 0
    /// A release that came before the menu walk finished — resolved the
    /// moment it lands (or once the walk's budget is long past, with what there is).
    private var pendingFire: (code: String, run: (ChordEntry, NSRunningApplication?) -> Void)?

    var isVisible: Bool { panel != nil }

    func start(config: Config.ChordConfig, app: NSRunningApplication?, dark: Bool, screen: NSScreen) {
        close()
        gen += 1
        let g = gen
        targetApp = app
        self.screen = screen
        buffer = ""
        let bundleID = app?.bundleIdentifier
        entries = ChordCatalog.entries(config: config, bundleID: bundleID, menu: [])
        let pid = app?.processIdentifier
        menuLoaded = !(config.autoMenu && pid != nil)

        let v = ChordPanelView(dark: dark, appName: app?.localizedName ?? "")
        view = v
        let win = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = v
        panel = win
        render()
        win.orderFrontRegardless()

        guard !menuLoaded, let pid else { return }
        let appName = app?.localizedName ?? "?"
        Task.detached(priority: .userInitiated) {
            // Walked fresh every time, never cached: which items are greyed
            // out, and titles that name the selection, change from one
            // second to the next — and a walk is tens of milliseconds.
            let walk = MenuChords.walk(pid: pid)
            await MainActor.run { [weak self] in
                guard let self, self.gen == g else { return }
                log("chord: \(appName) menus — \(walk.items.count) items in \(walk.ms) ms\(walk.truncated ? ", truncated at the cap" : "")")
                self.entries = ChordCatalog.entries(config: config, bundleID: bundleID, menu: walk.items)
                self.menuLoaded = true
                if let p = self.pendingFire {
                    self.pendingFire = nil
                    self.finish(p.code, run: p.run)
                } else {
                    self.render()
                }
            }
        }
    }

    func update(_ code: String) {
        guard isVisible else { return }
        buffer = code
        render()
    }

    /// The hotkey was released with `code` typed: run the exact match, or say
    /// why nothing ran. `run` is called at most once.
    func finish(_ code: String, run: @escaping (ChordEntry, NSRunningApplication?) -> Void) {
        guard isVisible else { return }
        buffer = code
        if code.isEmpty { close(); return }
        if let e = ChordCatalog.exact(code, in: entries) {
            // A dimmed item is still tried: what Accessibility reports as
            // greyed out can lag the app's own state, and a failed press
            // says so anyway.
            let app = targetApp
            close()
            run(e, app)
            return
        }
        if !menuLoaded {
            // Typed faster than the menus could be read — wait for them.
            pendingFire = (code, run)
            let g = gen
            DispatchQueue.main.asyncAfter(deadline: .now() + MenuChords.budget + 0.4) { [weak self] in
                guard let self, self.gen == g, let p = self.pendingFire else { return }
                self.pendingFire = nil
                self.menuLoaded = true   // give up waiting; resolve with what there is
                self.finish(p.code, run: p.run)
            }
            render()
            return
        }
        flash("No chord “\(code)”")
    }

    /// Esc, or anything else that ends the session without running a chord.
    func close() {
        gen += 1
        pendingFire = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    /// The miss state — red edge and the reason — then gone.
    private func flash(_ message: String) {
        view?.missMessage = message
        render()
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.gen == g else { return }
            self.close()
        }
    }

    private func render() {
        guard let view, let panel, let screen else { return }
        view.setContent(buffer: buffer, entries: entries, loading: !menuLoaded)
        let size = view.fittingSize
        let vf = screen.visibleFrame
        // Pinned by its top-left corner so the panel grows and shrinks
        // downward as the list filters, instead of jumping about.
        let top = vf.maxY - 48
        panel.setFrame(NSRect(x: vf.minX + 14, y: top - size.height, width: size.width, height: size.height),
                       display: true)
        view.frame = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
    }

    // MARK: Running a chord

    /// A shell chord: /bin/zsh -lc, detached, output discarded. A non-zero
    /// exit is logged — there is no window to show it in.
    static func runShell(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            if proc.terminationStatus != 0 { log("chord: shell exited \(proc.terminationStatus): \(command)") }
        }
        do { try p.run() } catch { log("chord: shell failed to start: \(error.localizedDescription)") }
    }
}

final class ChordPanelView: NSView {
    private enum Row {
        case header(String)
        case entry(ChordEntry, exact: Bool)
        case note(String)
    }

    private let dark: Bool
    private let appName: String
    private var buffer = ""
    private var rows: [Row] = []
    var missMessage: String?

    init(dark: Bool, appName: String) {
        self.dark = dark
        self.appName = appName
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static let width: CGFloat = 340
    private static let pad: CGFloat = 14
    private static let topH: CGFloat = 54      // app name + the typed code
    private static let headerH: CGFloat = 22
    private static let rowH: CGFloat = 19
    private static let codeW: CGFloat = 46
    /// Rows of chords shown at once; the rest are a "keep typing" note.
    static let maxEntryRows = 24

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }
    private var miss: NSColor { NSColor(srgbRed: 0.93, green: 0.3, blue: 0.3, alpha: 1) }

    /// Rebuild the list for `buffer`: the user's chords for this app, then
    /// the global ones, then the menu chords under their top menu's name.
    func setContent(buffer: String, entries: [ChordEntry], loading: Bool) {
        self.buffer = buffer
        let matching = entries.filter { $0.code.hasPrefix(buffer) }
        var out: [Row] = []
        var shown = 0
        var hidden = 0
        var lastGroup: String?
        for e in matching {
            let group: String
            switch e.source {
            case .app: group = appName.isEmpty ? "This app" : appName
            case .global: group = "Everywhere"
            case .menu: group = "Menu · \(e.group)"
            }
            guard shown < Self.maxEntryRows else { hidden += 1; continue }
            if group != lastGroup { out.append(.header(group)); lastGroup = group }
            out.append(.entry(e, exact: !buffer.isEmpty && e.code == buffer))
            shown += 1
        }
        if hidden > 0 { out.append(.note("+\(hidden) more — keep typing")) }
        if matching.isEmpty, !buffer.isEmpty, !loading, missMessage == nil { out.append(.note("Nothing starts with “\(buffer)” · ⌫ backs up")) }
        if loading { out.append(.note("Reading menus…")) }
        if entries.isEmpty, !loading { out.append(.note("No chords for this app yet — add some in config.json")) }
        rows = out
    }

    override var fittingSize: NSSize {
        var h = Self.pad + Self.topH
        for r in rows {
            if case .header = r { h += Self.headerH } else { h += Self.rowH }
        }
        return NSSize(width: Self.width, height: h + Self.pad)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        shape.setClip()
        bg.setFill()
        bounds.fill()
        if missMessage != nil {
            miss.setStroke()
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
            edge.lineWidth = 2
            edge.stroke()
        }

        let x = Self.pad
        let innerW = Self.width - 2 * Self.pad
        let title = appName.isEmpty ? "Chords" : "Chords · \(appName)"
        draw(title, in: NSRect(x: x, y: Self.pad - 2, width: innerW, height: 16),
             font: .systemFont(ofSize: 11, weight: .semibold), color: dim)

        // The code as typed, or the reason nothing ran.
        let lineY = Self.pad + 18
        if let missMessage {
            draw(missMessage, in: NSRect(x: x, y: lineY + 4, width: innerW, height: 20),
                 font: .systemFont(ofSize: 13, weight: .semibold), color: miss)
        } else if buffer.isEmpty {
            draw("hold Space · type a code · let go to run · esc", in: NSRect(x: x, y: lineY + 4, width: innerW, height: 20),
                 font: .systemFont(ofSize: 13), color: dim)
        } else {
            draw(buffer + "▏", in: NSRect(x: x, y: lineY, width: innerW, height: 26),
                 font: .monospacedSystemFont(ofSize: 20, weight: .semibold), color: fg)
        }

        var y = Self.pad + Self.topH
        for r in rows {
            switch r {
            case .header(let t):
                draw(t.uppercased(), in: NSRect(x: x, y: y + 8, width: innerW, height: 12),
                     font: .systemFont(ofSize: 9, weight: .bold), color: dim.withAlphaComponent(0.35))
                y += Self.headerH
            case .note(let t):
                draw(t, in: NSRect(x: x, y: y + 2, width: innerW, height: Self.rowH),
                     font: .systemFont(ofSize: 11), color: dim)
                y += Self.rowH
            case .entry(let e, let exact):
                drawEntry(e, exact: exact, y: y, x: x, innerW: innerW)
                y += Self.rowH
            }
        }
    }

    private func drawEntry(_ e: ChordEntry, exact: Bool, y: CGFloat, x: CGFloat, innerW: CGFloat) {
        if exact {
            accent.withAlphaComponent(dark ? 0.28 : 0.16).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 6, y: y, width: innerW + 12, height: Self.rowH),
                         xRadius: 5, yRadius: 5).fill()
        }
        let alpha: CGFloat = e.enabled ? 1 : 0.4
        // The code: what's typed so far in the text color, what's left in
        // the accent — the remaining letters are the part to read.
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let typed = String(e.code.prefix(buffer.count))
        let rest = String(e.code.dropFirst(buffer.count))
        let code = NSMutableAttributedString(string: typed, attributes: [.font: mono, .foregroundColor: fg.withAlphaComponent(alpha)])
        code.append(NSAttributedString(string: rest, attributes: [.font: mono, .foregroundColor: accent.withAlphaComponent(alpha)]))
        code.draw(at: NSPoint(x: x, y: y + 2))

        let detailFont = NSFont.systemFont(ofSize: 10)
        let detailW = e.detail.isEmpty ? 0 : min(120, (e.detail as NSString).size(withAttributes: [.font: detailFont]).width + 2)
        let nameX = x + Self.codeW
        let nameW = innerW - Self.codeW - (detailW > 0 ? detailW + 8 : 0)
        draw(e.name, in: NSRect(x: nameX, y: y + 2, width: nameW, height: Self.rowH),
             font: .systemFont(ofSize: 11), color: fg.withAlphaComponent(0.85 * alpha))
        if detailW > 0 {
            draw(e.detail, in: NSRect(x: x + innerW - detailW, y: y + 3, width: detailW, height: Self.rowH),
                 font: detailFont, color: dim.withAlphaComponent(alpha), alignRight: true)
        }
    }

    private func draw(_ s: String, in rect: NSRect, font: NSFont, color: NSColor, alignRight: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = alignRight ? .right : .left
        (s as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    // MARK: Preview (CLI `chord-preview`)

    /// Offscreen render for design checks — no event tap, no Accessibility.
    static func previewPNG(dark: Bool, buffer: String, entries: [ChordEntry], appName: String,
                           loading: Bool = false, miss: String? = nil) -> Data? {
        let v = ChordPanelView(dark: dark, appName: appName)
        v.missMessage = miss
        v.setContent(buffer: buffer, entries: entries, loading: loading)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
