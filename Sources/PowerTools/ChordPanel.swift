import Cocoa

/// Chord mode (hold + Space): the panel down the left edge listing what can
/// be typed for the front app, filtered as the code grows, and the bookkeeping
/// that turns the typed code into a ChordEntry on release. Display only —
/// it never takes key or mouse; HotkeyMonitor feeds it the keys.
@MainActor
final class ChordMode {
    /// Runs a chosen chord. The third value is the ribbon tab that was
    /// selected when chord mode opened — a ribbon press goes back to it.
    typealias Run = (ChordEntry, NSRunningApplication?, String?) -> Void

    private var panel: NSPanel?
    private var view: ChordPanelView?
    private var screen: NSScreen?
    /// The app in front when chord mode opened — the one the chord runs in.
    private(set) var targetApp: NSRunningApplication?
    private var config = Config.ChordConfig()
    private var bundleID: String?
    private var menuItems: [MenuChords.Item] = []
    private var entries: [ChordEntry] = []
    private var menuLoaded = true
    private var buffer = ""
    /// Bumped on every open and close, so a menu walk that lands late never
    /// touches a session it didn't start.
    private var gen = 0
    /// A release that came before the menus (or a ribbon tab) were read —
    /// resolved the moment they land, or after a timeout with what there is.
    private var pendingFire: (code: String, run: Run)?

    /// The Office ribbon, when the app has one: its tabs, the tab selected
    /// when chord mode opened (put back unless a ribbon chord ran), the tab
    /// selected now, and the now-selected tab's commands read live.
    private struct RibbonState {
        var tabs: [String]
        var original: String?
        var current: String?
        var live: [RibbonChords.Command]
        var disabled: Set<String>
    }
    private var ribbon: RibbonState?
    /// The tab being opened right now (typing a tab's code or name opens it).
    private var ribbonOpening: String?
    private var drillToken = 0
    /// A session that closed while a tab was still opening: once that open
    /// lands, put the ribbon back on this tab. Keyed by the session's gen.
    private var lateRestore: [Int: String] = [:]

    private var loading: Bool { !menuLoaded || ribbonOpening != nil }
    var isVisible: Bool { panel != nil }

    func start(config: Config.ChordConfig, app: NSRunningApplication?, dark: Bool, screen: NSScreen) {
        close()
        gen += 1
        let g = gen
        targetApp = app
        self.screen = screen
        self.config = config
        buffer = ""
        bundleID = app?.bundleIdentifier
        menuItems = []
        ribbon = nil
        ribbonOpening = nil
        rebuild()
        let pid = app?.processIdentifier
        let wantsRibbon = config.ribbon
        menuLoaded = !((config.autoMenu || wantsRibbon) && pid != nil)

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
        let autoMenu = config.autoMenu
        let bundleID = bundleID
        Task.detached(priority: .userInitiated) {
            // Walked fresh every time, never cached: which items are greyed
            // out, and titles that name the selection, change from one
            // second to the next — and a walk is tens of milliseconds.
            let walk = autoMenu ? MenuChords.walk(pid: pid) : MenuChords.Walk(items: [], ms: 0, truncated: false)
            let snap = wantsRibbon ? RibbonChords.snapshot(pid: pid) : nil
            if let snap, let bundleID, let sel = snap.selected, !snap.live.isEmpty {
                RibbonCache.shared.update(bundleID: bundleID, [sel: snap.live])
            }
            await MainActor.run { [weak self] in
                guard let self, self.gen == g else { return }
                log("chord: \(appName) menus — \(walk.items.count) items in \(walk.ms) ms\(walk.truncated ? ", truncated at the cap" : "")"
                    + (snap.map { ", ribbon \($0.tabs.count) tabs (on \($0.selected ?? "?"), \($0.live.count) commands)" } ?? ""))
                self.menuItems = walk.items
                if let snap {
                    self.ribbon = RibbonState(tabs: snap.tabs, original: snap.selected, current: snap.selected,
                                              live: snap.live, disabled: snap.disabled)
                }
                self.menuLoaded = true
                self.rebuild()
                self.settle()
            }
        }
    }

    func update(_ code: String) {
        guard isVisible else { return }
        buffer = code
        render()
        scheduleDrill()
    }

    /// The hotkey was released with `code` typed: run the exact code, else
    /// the best name match (the row the panel highlights), or say why
    /// nothing ran. `run` is called at most once.
    func finish(_ code: String, run: @escaping Run) {
        guard isVisible else { return }
        buffer = code
        if code.isEmpty { close(); return }
        if let e = ChordCatalog.exact(code, in: entries) {
            // A dimmed item is still tried: what Accessibility reports as
            // greyed out can lag the app's own state, and a failed press
            // says so anyway.
            runAndClose(e, run)
            return
        }
        if loading {
            // Typed faster than the menus (or a ribbon tab) could be read —
            // wait for them.
            pendingFire = (code, run)
            let g = gen
            DispatchQueue.main.asyncAfter(deadline: .now() + MenuChords.budget + 1.4) { [weak self] in
                guard let self, self.gen == g, let p = self.pendingFire else { return }
                self.pendingFire = nil
                self.menuLoaded = true   // give up waiting; resolve with what there is
                self.ribbonOpening = nil
                self.finish(p.code, run: p.run)
            }
            render()
            return
        }
        if let e = ChordCatalog.resolve(code, in: entries) {
            log("chord: “\(code)” matched by name → \(e.group.isEmpty ? "" : e.group + " ▸ ")\(e.name)")
            runAndClose(e, run)
            return
        }
        if let mq = ChordCatalog.menuQuery(code, in: entries), mq.whole, mq.rest.isEmpty {
            flash("That's \(mq.menu) — keep typing to pick an item")
            return
        }
        flash("No chord or name matches “\(code)”")
    }

    private func runAndClose(_ e: ChordEntry, _ run: Run) {
        let app = targetApp
        let original = ribbon?.original
        let ribbonRun: Bool
        switch e.action {
        case .ribbon, .ribbonTab, .ribbonLearn: ribbonRun = true
        default: ribbonRun = false
        }
        // A ribbon chord decides where the ribbon ends up itself; anything
        // else leaves the ribbon on the tab it was on before chord mode.
        close(restoreRibbon: !ribbonRun)
        run(e, app, original)
    }

    /// Esc, a miss, or anything else that ends the session without running
    /// a chord. Puts the ribbon back if typing a tab's name opened another.
    func close(restoreRibbon: Bool = true) {
        let ended = gen
        gen += 1
        pendingFire = nil
        drillToken += 1
        if restoreRibbon, let r = ribbon, let original = r.original, let pid = targetApp?.processIdentifier {
            if ribbonOpening != nil {
                lateRestore[ended] = original
            } else if r.current != original {
                log("chord: ribbon back to \(original)")
                Task.detached(priority: .userInitiated) { RibbonChords.openTab(pid: pid, tab: original, timeout: 0.6) }
            }
        }
        ribbon = nil
        ribbonOpening = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    // MARK: Ribbon tabs

    private func rebuild() {
        var input: ChordCatalog.RibbonInput?
        if let r = ribbon {
            var commands = bundleID.map { RibbonCache.shared.tabs(bundleID: $0) } ?? [:]
            if let cur = r.current, !r.live.isEmpty { commands[cur] = r.live }
            input = ChordCatalog.RibbonInput(tabs: r.tabs, commands: commands, liveTab: r.current, disabled: r.disabled)
        }
        entries = ChordCatalog.entries(config: config, bundleID: bundleID, menu: menuItems, ribbon: input)
    }

    /// Something finished loading: fire a waiting release, else redraw and
    /// open whatever tab the buffer now names.
    private func settle() {
        if let p = pendingFire, !loading {
            pendingFire = nil
            finish(p.code, run: p.run)
            return
        }
        render()
        drill()
    }

    /// The tab the buffer names: a tab code it starts with (".v", ".vgr" →
    /// View; the longest wins), or a whole tab name ("view", "viewgr").
    private func ribbonTarget(_ code: String) -> String? {
        guard let r = ribbon else { return nil }
        var best: (code: String, tab: String)?
        for e in entries where e.source == .ribbonTab {
            guard case .ribbonTab(let t) = e.action, code.hasPrefix(e.code) else { continue }
            if e.code.count > (best?.code.count ?? 0) { best = (e.code, t) }
        }
        if let best { return best.tab }
        if let mq = ChordCatalog.menuQuery(code, in: entries), mq.whole, r.tabs.contains(mq.menu) { return mq.menu }
        return nil
    }

    /// Typing pauses for a quarter second before a tab opens, so passing
    /// through ".d" on the way to ".da" doesn't flick the ribbon to Draw.
    private func scheduleDrill() {
        drillToken += 1
        let t = drillToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.drillToken == t else { return }
            self.drill()
        }
    }

    /// Open the tab the buffer names (like Alt+W opening View), read its
    /// commands, remember them, and list them.
    private func drill() {
        guard let r = ribbon, ribbonOpening == nil, let pid = targetApp?.processIdentifier,
              let tab = ribbonTarget(buffer), tab != r.current else { return }
        ribbonOpening = tab
        render()
        let g = gen
        let bundleID = bundleID
        Task.detached(priority: .userInitiated) {
            let cmds = RibbonChords.openTab(pid: pid, tab: tab)
            if let cmds, let bundleID { RibbonCache.shared.update(bundleID: bundleID, [tab: cmds]) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.gen == g else {
                    // The session ended while this tab was opening.
                    if let back = self.lateRestore.removeValue(forKey: g), back != tab {
                        Task.detached(priority: .userInitiated) { RibbonChords.openTab(pid: pid, tab: back, timeout: 0.6) }
                    }
                    return
                }
                log("chord: opened ribbon tab \(tab) — \(cmds?.count ?? 0) commands")
                self.ribbonOpening = nil
                if let cmds {
                    self.ribbon?.current = tab
                    self.ribbon?.live = cmds
                    self.ribbon?.disabled = []
                }
                self.rebuild()
                self.settle()
            }
        }
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
        let vf = screen.visibleFrame
        // Pinned by its top-left corner so the panel grows and shrinks
        // downward as the list filters, instead of jumping about. It may
        // take the rest of the screen: a big app (Excel, ~270 menu items)
        // flows into columns so everything is visible before typing.
        let top = vf.maxY - 48
        view.setContent(buffer: buffer, entries: entries, loading: loading,
                        maxSize: NSSize(width: vf.width - 28, height: top - (vf.minY + 14)))
        let size = view.fittingSize
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
        /// `typed`: how much of the code the buffer covers (0 for a name match).
        case entry(ChordEntry, highlighted: Bool, typed: Int)
        case note(String)
    }

    private let dark: Bool
    private let appName: String
    private var buffer = ""
    private var columns: [[Row]] = []
    var missMessage: String?

    init(dark: Bool, appName: String) {
        self.dark = dark
        self.appName = appName
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static let pad: CGFloat = 14
    private static let colW: CGFloat = 312     // one column = the old 340-wide panel
    private static let colGap: CGFloat = 22
    private static let topH: CGFloat = 54      // app name + the typed code
    private static let headerH: CGFloat = 22
    private static let rowH: CGFloat = 19
    private static let codeW: CGFloat = 46

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }
    private var miss: NSColor { NSColor(srgbRed: 0.93, green: 0.3, blue: 0.3, alpha: 1) }

    private static func height(_ r: Row) -> CGFloat {
        if case .header = r { return headerH }
        return rowH
    }

    /// Rebuild the list for `buffer` and flow it into as many columns as
    /// `maxSize` allows. Code matches are grouped as before — the user's
    /// chords for this app, the global ones, then each menu. Name matches
    /// ("filt" → AutoFilter) get their own section, FIRST when no code
    /// matches exactly, because its top row is what letting go runs.
    func setContent(buffer: String, entries: [ChordEntry], loading: Bool, maxSize: NSSize) {
        self.buffer = buffer
        let exact = buffer.isEmpty ? nil : ChordCatalog.exact(buffer, in: entries)
        let runs = ChordCatalog.resolve(buffer, in: entries)
        // Each entry shows once, in the first section that claims it.
        var claimed: Set<String> = []
        func claim(_ list: [ChordEntry]) -> [ChordEntry] {
            let fresh = list.filter { !claimed.contains($0.code) }
            claimed.formUnion(fresh.map(\.code))
            return fresh
        }
        func listed(_ e: ChordEntry) -> ChordEntry {
            let where_: String
            switch e.source {
            case .menu: where_ = e.group
            case .ribbon: where_ = "\(e.group) tab"
            case .ribbonTab: where_ = "Ribbon"
            case .app: where_ = appName
            case .global: where_ = "Everywhere"
            }
            let detail = e.source == .ribbon || e.detail.isEmpty ? where_ : "\(where_) ▸ \(e.detail)"
            return ChordEntry(code: e.code, name: e.name, detail: detail,
                              group: e.group, source: e.source, action: e.action, enabled: e.enabled)
        }
        // A typed menu name: that menu's items (narrowed by what follows the
        // name), ahead of everything but an exact code.
        var menuRows: [Row] = []
        if let mq = ChordCatalog.menuQuery(buffer, in: entries) {
            let items = mq.whole && !mq.rest.isEmpty
                ? ChordCatalog.scopedMatches(mq, in: entries)
                : ChordCatalog.inMenu(mq.menu, entries)
            let title = mq.rest.isEmpty ? "\(mq.menu) menu" : "\(mq.menu) menu ▸ “\(mq.rest)”"
            if exact != nil { claimed.insert(exact!.code) }
            let fresh = claim(items)
            if !fresh.isEmpty {
                menuRows.append(.header(title))
                for e in fresh {
                    let shown = ChordEntry(code: e.code, name: e.name, detail: e.detail, group: e.group,
                                           source: e.source, action: e.action, enabled: e.enabled)
                    menuRows.append(.entry(shown, highlighted: runs?.code == e.code, typed: 0))
                }
            }
            if exact != nil { claimed.remove(exact!.code) }
        }
        let byName = claim(ChordCatalog.nameMatches(buffer, in: entries))
        let byCode = entries.filter { $0.code.hasPrefix(buffer) && !claimed.contains($0.code) }

        var codeRows: [Row] = []
        var lastGroup: String?
        for e in byCode {
            let group: String
            switch e.source {
            case .app: group = appName.isEmpty ? "This app" : appName
            case .global: group = "Everywhere"
            case .menu: group = "Menu · \(e.group)"
            case .ribbonTab: group = "Ribbon tabs"
            case .ribbon: group = "Ribbon · \(e.group)"
            }
            if group != lastGroup { codeRows.append(.header(group)); lastGroup = group }
            codeRows.append(.entry(e, highlighted: runs?.code == e.code, typed: buffer.count))
        }
        var nameRows: [Row] = []
        if !byName.isEmpty {
            nameRows.append(.header("Names containing “\(buffer)”"))
            for e in byName {
                nameRows.append(.entry(listed(e), highlighted: runs?.code == e.code, typed: 0))
            }
        }
        var rows = exact == nil ? menuRows + nameRows + codeRows : codeRows + menuRows + nameRows
        if byCode.isEmpty, byName.isEmpty, menuRows.isEmpty, !buffer.isEmpty, !loading, missMessage == nil {
            rows.append(.note("Nothing matches “\(buffer)” · ⌫ backs up"))
        }
        if loading { rows.append(.note("Reading menus and ribbon…")) }
        if entries.isEmpty, !loading { rows.append(.note("No chords for this app yet — add some in config.json")) }
        columns = Self.flow(rows, maxSize: maxSize)
    }

    /// Fill a column top to bottom, then start the next. A section header
    /// never ends a column (it moves over with its first row). Whatever
    /// doesn't fit in the last column becomes one "+N more" note.
    private static func flow(_ rows: [Row], maxSize: NSSize) -> [[Row]] {
        let colH = max(rowH * 6, maxSize.height - 2 * pad - topH)
        let maxCols = max(1, Int((maxSize.width - 2 * pad + colGap) / (colW + colGap)))
        var cols: [[Row]] = [[]]
        var h: CGFloat = 0
        var i = 0
        var section: String?
        while i < rows.count {
            let r = rows[i]
            var need = height(r)
            if case .header = r, i + 1 < rows.count { need += height(rows[i + 1]) }
            if h + need > colH, !cols[cols.count - 1].isEmpty {
                if cols.count == maxCols {
                    let left = rows[i...].reduce(0) { n, r in
                        if case .entry = r { return n + 1 }
                        return n
                    }
                    // Make room for the note in the last column if needed.
                    if h + rowH > colH, !cols[cols.count - 1].isEmpty { cols[cols.count - 1].removeLast() }
                    if left > 0 { cols[cols.count - 1].append(.note("+\(left) more — keep typing")) }
                    return cols
                }
                cols.append([])
                h = 0
                // A section that runs over keeps its name at the top of the
                // new column, so a column never opens on unlabelled rows.
                if case .entry = r, let section {
                    cols[cols.count - 1].append(.header("\(section) (cont.)"))
                    h += headerH
                }
            }
            if case .header(let t) = r { section = t }
            cols[cols.count - 1].append(r)
            h += height(r)
            i += 1
        }
        return cols
    }

    override var fittingSize: NSSize {
        let n = CGFloat(max(columns.count, 1))
        let tallest = columns.map { $0.reduce(0) { $0 + Self.height($1) } }.max() ?? 0
        return NSSize(width: 2 * Self.pad + n * Self.colW + (n - 1) * Self.colGap,
                      height: Self.pad + Self.topH + tallest + Self.pad)
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

        let x0 = Self.pad
        let titleW = Self.colW
        let title = appName.isEmpty ? "Chords" : "Chords · \(appName)"
        draw(title, in: NSRect(x: x0, y: Self.pad - 2, width: titleW, height: 16),
             font: .systemFont(ofSize: 11, weight: .semibold), color: dim)

        // The code as typed, or the reason nothing ran.
        let lineY = Self.pad + 18
        let lineW = bounds.width - 2 * Self.pad
        if let missMessage {
            draw(missMessage, in: NSRect(x: x0, y: lineY + 4, width: lineW, height: 20),
                 font: .systemFont(ofSize: 13, weight: .semibold), color: miss)
        } else if buffer.isEmpty {
            draw("hold Space · type a code or a name · let go to run · esc", in: NSRect(x: x0, y: lineY + 4, width: lineW, height: 20),
                 font: .systemFont(ofSize: 13), color: dim)
        } else {
            draw(buffer + "▏", in: NSRect(x: x0, y: lineY, width: lineW, height: 26),
                 font: .monospacedSystemFont(ofSize: 20, weight: .semibold), color: fg)
        }

        for (c, column) in columns.enumerated() {
            let x = x0 + CGFloat(c) * (Self.colW + Self.colGap)
            var y = Self.pad + Self.topH
            for r in column {
                switch r {
                case .header(let t):
                    draw(t.uppercased(), in: NSRect(x: x, y: y + 8, width: Self.colW, height: 12),
                         font: .systemFont(ofSize: 9, weight: .bold), color: dim.withAlphaComponent(0.35))
                case .note(let t):
                    draw(t, in: NSRect(x: x, y: y + 2, width: Self.colW, height: Self.rowH),
                         font: .systemFont(ofSize: 11), color: dim)
                case .entry(let e, let highlighted, let typed):
                    drawEntry(e, highlighted: highlighted, typed: typed, y: y, x: x, innerW: Self.colW)
                }
                y += Self.height(r)
            }
        }
    }

    private func drawEntry(_ e: ChordEntry, highlighted: Bool, typed: Int, y: CGFloat, x: CGFloat, innerW: CGFloat) {
        if highlighted {
            accent.withAlphaComponent(dark ? 0.28 : 0.16).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 6, y: y, width: innerW + 12, height: Self.rowH),
                         xRadius: 5, yRadius: 5).fill()
        }
        let alpha: CGFloat = e.enabled ? 1 : 0.4
        // The code: what's typed so far in the text color, what's left in
        // the accent — the remaining letters are the part to read.
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let code = NSMutableAttributedString(string: String(e.code.prefix(typed)),
                                             attributes: [.font: mono, .foregroundColor: fg.withAlphaComponent(alpha)])
        code.append(NSAttributedString(string: String(e.code.dropFirst(typed)),
                                       attributes: [.font: mono, .foregroundColor: accent.withAlphaComponent(alpha)]))
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
                           loading: Bool = false, miss: String? = nil,
                           maxSize: NSSize = NSSize(width: 1700, height: 1000)) -> Data? {
        let v = ChordPanelView(dark: dark, appName: appName)
        v.missMessage = miss
        v.setContent(buffer: buffer, entries: entries, loading: loading, maxSize: maxSize)
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
