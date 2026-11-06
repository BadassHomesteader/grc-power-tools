import Cocoa

/// The hold + P drawer: every Advanced Paste option in a full-height list that
/// slides in from the right edge (the clipboard-history drawer's shape), with
/// "Suggested" rows for what is on the clipboard, type-to-filter, and a white
/// preview of the highlighted result — how it lands on an email's white page.
///
/// Like the history drawer it never activates Power Tools: the app you are in
/// keeps focus, the hotkey tap routes the drawer's keys (`pasteDrawerVisible`),
/// and a pick pastes straight in.
@MainActor
final class PasteDrawer {
    private static let slide: TimeInterval = 0.18

    private var window: NSPanel?
    private weak var view: PasteDrawerView?
    private var clickMonitors: [Any] = []
    private var cancelHandler: (() -> Void)?
    private var hiddenFrame = NSRect.zero
    /// Mirrored into the hotkey tap, which routes the drawer's keys while it is out.
    var onVisibility: ((Bool) -> Void)?

    var isVisible: Bool { window != nil }

    func present(input: PasteInput, dark: Bool, screen: NSScreen,
                 onPick: @escaping (AdvancedPaste.Transform) -> Void, onCancel: @escaping () -> Void) {
        dismiss(animated: false)
        let vf = screen.visibleFrame
        let width = PasteDrawerView.width
        let shown = NSRect(x: vf.maxX - width, y: vf.minY, width: width, height: vf.height)
        let hidden = shown.offsetBy(dx: width, dy: 0)
        hiddenFrame = hidden

        let view = PasteDrawerView(input: input, dark: dark)
        view.frame = NSRect(origin: .zero, size: shown.size)
        view.onPick = { [weak self] t in self?.dismiss(); onPick(t) }
        view.onCancel = { [weak self] in self?.cancel() }
        cancelHandler = onCancel

        let win = NSPanel(contentRect: hidden, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = view
        window = win
        self.view = view
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.slide
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().setFrame(shown, display: true)
        }
        onVisibility?(true)

        // A click anywhere but the drawer closes it, like a menu.
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: buttons, handler: { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: buttons, handler: { [weak self] event in
            let clicked = event.window
            MainActor.assumeIsolated {
                if let self, clicked !== self.window { self.dismiss() }
            }
            return event
        }) { clickMonitors.append(local) }
    }

    /// A key the hotkey tap routed here, with the character it types. -1 means
    /// a ⌘/⌃/⌥ combo: that closes the drawer and the key goes on to the app.
    func handleKey(_ code: Int, chars: String) {
        guard isVisible else { return }
        if code < 0 { dismiss(); return }
        view?.handleKey(code, chars: chars)
    }

    func cancel() {
        let handler = cancelHandler
        dismiss()
        handler?()
    }

    func dismiss(animated: Bool = true) {
        cancelHandler = nil
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors = []
        guard let win = window else { return }
        window = nil
        onVisibility?(false)
        guard animated else { win.orderOut(nil); return }
        let hidden = hiddenFrame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.slide
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().setFrame(hidden, display: true)
        }, completionHandler: {
            win.orderOut(nil)
        })
    }
}

final class PasteDrawerView: NSView {
    typealias Transform = AdvancedPaste.Transform

    static let width: CGFloat = 430
    private static let headerH: CGFloat = 100
    private static let footerH: CGFloat = 34
    private static let rowH: CGFloat = 50
    private static let sectionH: CGFloat = 30
    private static let side: CGFloat = 10

    private enum Row {
        case section(String, suggested: Bool)
        case item(Transform)
        case empty(String)
    }

    private let input: PasteInput
    private let dark: Bool
    private let suggested: [Transform]
    private let available: [Transform]
    private var filter = ""
    private var rows: [Row] = []
    private var itemRows: [Int] = []     // indices into `rows` that are items, in order
    private var highlighted = 0          // index into itemRows
    private var scrollY: CGFloat = 0
    var onPick: ((Transform) -> Void)?
    var onCancel: (() -> Void)?

    private let previewScroll = NSScrollView()
    /// TextKit 1: TextKit 2 (the default) lays a table out as one stacked column.
    private let previewText = NSTextView(usingTextLayoutManager: false)
    private var previewCache: [String: NSAttributedString] = [:]
    private var ocrText: String?         // nil until the background OCR finishes
    private var symbolCache: [String: NSImage] = [:]

    init(input: PasteInput, dark: Bool) {
        self.input = input
        self.dark = dark
        self.available = AdvancedPaste.available(for: input)
        self.suggested = AdvancedPaste.suggestions(for: input)
        super.init(frame: .zero)

        // The preview is a white page: the paste as it lands in an email.
        previewScroll.appearance = NSAppearance(named: .aqua)
        previewScroll.drawsBackground = true
        previewScroll.backgroundColor = .white
        previewScroll.hasVerticalScroller = true
        previewScroll.autohidesScrollers = true
        previewScroll.borderType = .noBorder
        previewScroll.wantsLayer = true
        previewScroll.layer?.cornerRadius = 8
        previewScroll.layer?.masksToBounds = true
        if !dark {   // white page on a near-white drawer needs an edge
            previewScroll.layer?.borderWidth = 1
            previewScroll.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        }
        previewText.isEditable = false
        previewText.isSelectable = false
        previewText.drawsBackground = true
        previewText.backgroundColor = .white
        previewText.textContainerInset = NSSize(width: 8, height: 8)
        previewText.isVerticallyResizable = true
        previewText.isHorizontallyResizable = false
        previewText.autoresizingMask = [.width]
        previewText.textContainer?.widthTracksTextView = true
        previewScroll.documentView = previewText
        addSubview(previewScroll)

        rebuild()
        if let image = input.image {
            Task.detached { [weak self] in
                let text = ScreenCapture.ocr(image)
                await MainActor.run {
                    guard let self else { return }
                    self.ocrText = text
                    self.previewCache["ocr"] = nil
                    self.updatePreview()
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The live drawer is screen-tall; this is the offscreen preview's size.
    override var fittingSize: NSSize { NSSize(width: Self.width, height: 1000) }

    // MARK: Colors and geometry

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var faint: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(dark ? 0.07 : 0.05) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private var previewH: CGFloat { min(300, max(bounds.height * 0.32, 180)) }
    private var previewTop: CGFloat { bounds.height - Self.footerH - previewH }
    private var listRect: NSRect {
        NSRect(x: 0, y: Self.headerH, width: bounds.width, height: max(previewTop - Self.headerH, 0))
    }
    private func rowHeight(_ r: Row) -> CGFloat {
        switch r { case .section: return Self.sectionH; case .item: return Self.rowH; case .empty: return 60 }
    }
    private var contentHeight: CGFloat { rows.reduce(0) { $0 + rowHeight($1) } + 8 }
    private var maxScroll: CGFloat { max(contentHeight - listRect.height, 0) }

    private func rowRect(_ i: Int) -> NSRect {
        var y = Self.headerH - scrollY
        for j in 0..<i { y += rowHeight(rows[j]) }
        return NSRect(x: Self.side, y: y, width: bounds.width - Self.side * 2, height: rowHeight(rows[i]))
    }

    override func layout() {
        super.layout()
        previewScroll.frame = NSRect(x: 14, y: previewTop + 30, width: bounds.width - 28, height: previewH - 40)
    }

    // MARK: Rows

    private func rebuild() {
        rows = []
        let f = filter.trimmingCharacters(in: .whitespaces)
        if f.isEmpty {
            if !suggested.isEmpty {
                rows.append(.section("Suggested", suggested: true))
                rows += suggested.map { .item($0) }
            }
            for g in AdvancedPaste.Group.allCases {
                let inGroup = available.filter { $0.group == g }
                guard !inGroup.isEmpty else { continue }
                rows.append(.section(g.rawValue, suggested: false))
                rows += inGroup.map { .item($0) }
            }
        } else {
            let hits = available.filter { AdvancedPaste.matches($0, filter: f) }
            if hits.isEmpty { rows.append(.empty("No option matches “\(f)”")) }
            else { rows += hits.map { .item($0) } }
        }
        if rows.isEmpty { rows.append(.empty("Nothing on the clipboard these options can use")) }
        itemRows = rows.indices.filter { if case .item = rows[$0] { return true }; return false }
        highlighted = 0
        scrollY = 0
        needsDisplay = true
        updatePreview()
    }

    private var current: Transform? {
        guard highlighted < itemRows.count, case .item(let t) = rows[itemRows[highlighted]] else { return nil }
        return t
    }

    // MARK: Preview

    private func updatePreview() {
        guard let t = current else {
            previewText.textStorage?.setAttributedString(note(filter.isEmpty ? "" : "Nothing to preview"))
            return
        }
        let shown = previewCache[t.id] ?? makePreview(t)
        previewCache[t.id] = shown
        previewText.textStorage?.setAttributedString(shown)
        previewText.scrollToBeginningOfDocument(nil)
    }

    private func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: String(s.prefix(20_000)), attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }
    private func note(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0.45, alpha: 1)])
    }

    private func makePreview(_ t: Transform) -> NSAttributedString {
        switch t.kind {
        case .ai:
            let start = input.text.prefix(240)
            return note("Runs on Claude with your key when you pick it. It gets the clipboard text:\n\n“\(start)\(input.text.count > 240 ? "…" : "")”")
        case .ocr:
            guard let ocrText else { return note("Reading the text in the image…") }
            return ocrText.isEmpty ? note("No text found in the image") : plain(ocrText)
        default:
            break
        }
        switch MainActor.assumeIsolated({ AdvancedPaste.run(t, on: input) }) {
        case .text(let s): return plain(s)
        case .failure(let msg): return note(msg)
        case .rich(let text, let flavors):
            // Render what the target will read: the HTML flavor, else the RTF.
            if let html = flavors.first(where: { $0.0 == .html })?.1,
               let a = NSAttributedString(html: Data("<style>body{font-family:'Helvetica Neue',Helvetica;font-size:13px}</style>".utf8) + html,
                                          options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
                return blackWhereUnset(a)
            }
            if let rtf = flavors.first(where: { $0.0 == .rtf })?.1, let a = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                return blackWhereUnset(a)
            }
            return plain(text)
        }
    }

    /// Text with no color of its own shows as the target's default: black on white.
    private func blackWhereUnset(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        m.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: m.length)) { v, r, _ in
            if v == nil { m.addAttribute(.foregroundColor, value: NSColor.black, range: r) }
        }
        return m
    }

    // MARK: Drawing

    private func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)|\(size)|\(color.description)"
        if let c = symbolCache[key] { return c }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let img = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil))?.withSymbolConfiguration(cfg)
        symbolCache[key] = img
        return img
    }

    private func drawSymbol(_ name: String, size: CGFloat, color: NSColor, centeredIn box: NSRect) {
        guard let img = symbol(name, size: size, color: color) else { return }
        let s = img.size
        img.draw(in: NSRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private var sourceSummary: String {
        var parts: [String] = []
        if !input.text.isEmpty {
            let n = input.text.count
            parts.append(n == 1 ? "1 character" : "\(n.formatted()) characters")
        }
        if input.hasRich { parts.append("formatted") }
        if input.image != nil { parts.append("image") }
        return "Clipboard: " + parts.joined(separator: " · ")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width + 24, height: bounds.height),
                     xRadius: 14, yRadius: 14).setClip()
        bg.setFill()
        bounds.fill()

        ("Paste as…" as NSString).draw(at: NSPoint(x: 20, y: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: fg])
        (sourceSummary as NSString).draw(at: NSPoint(x: 20, y: 38),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim])

        // The filter line. The drawer never has key focus; the tap feeds it.
        let field = NSRect(x: 14, y: 60, width: bounds.width - 28, height: 30)
        faint.setFill()
        NSBezierPath(roundedRect: field, xRadius: 8, yRadius: 8).fill()
        drawSymbol("magnifyingglass", size: 12, color: dim, centeredIn: NSRect(x: field.minX + 6, y: field.minY, width: 20, height: field.height))
        let typed = filter as NSString
        let fieldAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: filter.isEmpty ? dim : fg]
        let shown: NSString = filter.isEmpty ? "Type to filter" : typed
        let textSize = shown.size(withAttributes: fieldAttrs)
        shown.draw(at: NSPoint(x: field.minX + 30, y: field.midY - textSize.height / 2), withAttributes: fieldAttrs)
        if !filter.isEmpty {
            accent.setFill()
            NSRect(x: field.minX + 31 + textSize.width, y: field.minY + 7, width: 1.5, height: field.height - 14).fill()
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: listRect).addClip()
        for i in rows.indices {
            let r = rowRect(i)
            guard r.maxY >= listRect.minY, r.minY <= listRect.maxY else { continue }
            drawRow(i, in: r)
        }
        NSGraphicsContext.restoreGraphicsState()

        // Preview panel.
        (dark ? NSColor.white : .black).withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: previewTop, width: bounds.width, height: 1).fill()
        let label = "PREVIEW" + (current.map { " · \($0.title)" } ?? "")
        (label as NSString).draw(at: NSPoint(x: 20, y: previewTop + 10),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: dim])

        NSRect(x: 0, y: bounds.height - Self.footerH, width: bounds.width, height: 1).fill()
        ("type to filter · ↑↓ ↵ · 1–9 · esc · hold + P, then a letter, skips this" as NSString).draw(
            at: NSPoint(x: 20, y: bounds.height - Self.footerH + 10),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim])
    }

    private func drawRow(_ i: Int, in r: NSRect) {
        switch rows[i] {
        case .section(let name, let isSuggested):
            (name.uppercased() as NSString).draw(at: NSPoint(x: r.minX + 10, y: r.minY + 12),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                                 .foregroundColor: isSuggested ? accent : dim])
        case .empty(let message):
            (message as NSString).draw(at: NSPoint(x: r.minX + 10, y: r.minY + 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: dim])
        case .item(let t):
            let order = itemRows.firstIndex(of: i) ?? 0
            let hot = order == highlighted
            let card = r.insetBy(dx: 0, dy: 2)
            if hot {
                accent.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9).fill()
            }
            let titleColor = hot ? NSColor.white : fg
            let subColor = hot ? NSColor.white.withAlphaComponent(0.8) : dim

            if order < 9 {
                let badge = NSRect(x: card.minX + 8, y: card.midY - 10, width: 20, height: 20)
                (hot ? NSColor.white.withAlphaComponent(0.25) : (dark ? NSColor.white : .black).withAlphaComponent(0.1)).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
                let n = "\(order + 1)" as NSString
                let nAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: titleColor]
                let ns = n.size(withAttributes: nAttrs)
                n.draw(at: NSPoint(x: badge.midX - ns.width / 2, y: badge.midY - ns.height / 2), withAttributes: nAttrs)
            }

            // Icon tile.
            let tile = NSRect(x: card.minX + 36, y: card.midY - 15, width: 30, height: 30)
            (hot ? NSColor.white.withAlphaComponent(0.18) : faint).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
            drawSymbol(t.icon, size: 14, color: hot ? .white : (t.isAI ? accent : fg.withAlphaComponent(0.8)), centeredIn: tile)

            let textX = tile.maxX + 10
            let keyW: CGFloat = t.key == nil ? 0 : 28
            let textW = card.maxX - 10 - keyW - textX
            let one = NSMutableParagraphStyle()
            one.lineBreakMode = .byTruncatingTail
            (t.title as NSString).draw(with: NSRect(x: textX, y: card.minY + 7, width: textW, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: titleColor, .paragraphStyle: one])
            (t.subtitle as NSString).draw(with: NSRect(x: textX, y: card.minY + 25, width: textW, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: subColor, .paragraphStyle: one])

            // hold + P, then this letter.
            if let key = t.key {
                let kb = NSRect(x: card.maxX - 30, y: card.midY - 10, width: 20, height: 20)
                (hot ? NSColor.white.withAlphaComponent(0.6) : dim.withAlphaComponent(0.6)).setStroke()
                let path = NSBezierPath(roundedRect: kb.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                path.lineWidth = 1
                path.stroke()
                let k = String(key) as NSString
                let kAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: subColor]
                let ks = k.size(withAttributes: kAttrs)
                k.draw(at: NSPoint(x: kb.midX - ks.width / 2, y: kb.midY - ks.height / 2), withAttributes: kAttrs)
            }
        }
    }

    // MARK: Input

    private func itemAt(_ p: NSPoint) -> Int? {
        guard listRect.contains(p) else { return nil }
        return itemRows.firstIndex { rowRect($0).contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = itemAt(convert(event.locationInWindow, from: nil)), i != highlighted {
            highlighted = i
            needsDisplay = true
            updatePreview()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = itemAt(convert(event.locationInWindow, from: nil)), case .item(let t) = rows[itemRows[i]] { onPick?(t) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard listRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        let next = min(max(scrollY - dy, 0), maxScroll)
        guard next != scrollY else { return }
        scrollY = next
        needsDisplay = true
    }

    /// A key the tap routed here (the drawer never has key focus itself).
    func handleKey(_ code: Int, chars: String) {
        switch code {
        case 53:                                   // esc: clear the filter, then close
            if filter.isEmpty { onCancel?() } else { filter = ""; rebuild() }
        case 36, 76:
            if let t = current { onPick?(t) }
        case 125: move(to: highlighted + 1)
        case 126: move(to: highlighted - 1)
        case 51:                                   // delete
            if !filter.isEmpty { filter.removeLast(); rebuild() }
        default:
            if let n = Int(chars), (1...9).contains(n), chars.count == 1 {
                if n <= itemRows.count, case .item(let t) = rows[itemRows[n - 1]] { onPick?(t) }
                return
            }
            let printable = chars.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            guard !chars.isEmpty, printable, !(filter.isEmpty && chars == " ") else { return }
            filter += chars
            rebuild()
        }
    }

    private func move(to i: Int) {
        guard !itemRows.isEmpty else { return }
        highlighted = min(max(i, 0), itemRows.count - 1)
        // Keep the row in view; show its section header when it is the first in it.
        var r = rowRect(itemRows[highlighted])
        if itemRows[highlighted] > 0, case .section = rows[itemRows[highlighted] - 1] { r = r.union(rowRect(itemRows[highlighted] - 1)) }
        let list = listRect
        if r.minY < list.minY { scrollY -= list.minY - r.minY }
        else if r.maxY > list.maxY - 4 { scrollY += r.maxY - (list.maxY - 4) }
        scrollY = min(max(scrollY, 0), maxScroll)
        needsDisplay = true
        updatePreview()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}
