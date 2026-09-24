import Cocoa
import CryptoKit

/// The Shelf: a tray you drag files, text and images onto to park them, then
/// drag back out somewhere else. It solves the drag nobody can do in one go —
/// across Spaces, between two windows that cannot both be on screen, out of a
/// mail message and into a folder you have not opened yet.
///
/// SESSION-ONLY. Nothing here is written to disk: no SQLite, no Application
/// Support file, no security-scoped bookmarks. Quitting Power Tools empties the
/// shelf, and the empty state says so. What IS persisted is where the panel
/// sits (pad-placement.json, key "shelf") — geometry, never contents.
struct ShelfItem: Identifiable {
    enum Kind {
        case file(URL)
        case text(String)
        case image(Data)     // PNG bytes, normalised on the way in
    }
    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    /// Built ONCE here. Decoding a full-size PNG on every scroll redraw is the
    /// stutter the clipboard drawer already learned to avoid.
    let thumb: NSImage?
    let dedupeKey: String
    let added = Date()

    var fileURL: URL? {
        if case .file(let u) = kind { return u }
        return nil
    }

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .file(let url):
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            title = url.lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            if url.pathExtension == "app" {
                // A bundle is a directory, but calling it a folder is a lie.
                subtitle = parent.isEmpty ? "App" : "App · \(parent)"
            } else if vals?.isDirectory == true {
                subtitle = parent.isEmpty ? "Folder" : "Folder · \(parent)"
            } else {
                let size = (vals?.fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0),
                                                                           countStyle: .file) }
                subtitle = [size, parent.isEmpty ? nil : parent].compactMap { $0 }.joined(separator: " · ")
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            thumb = icon
            dedupeKey = "file:" + url.standardizedFileURL.path
        case .text(let s):
            let flat = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = flat.split(whereSeparator: \.isNewline).first.map(String.init) ?? flat
            title = firstLine.count > 60 ? String(firstLine.prefix(57)) + "…" : firstLine
            let n = NumberFormatter.localizedString(from: NSNumber(value: flat.count), number: .decimal)
            subtitle = flat.hasPrefix("http") ? "Link" : "\(n) characters"
            thumb = nil
            dedupeKey = "text:" + flat
        case .image(let png):
            let rep = NSBitmapImageRep(data: png)
            let w = rep?.pixelsWide ?? 0, h = rep?.pixelsHigh ?? 0
            title = w > 0 ? "Image · \(w)×\(h)" : "Image"
            subtitle = ByteCountFormatter.string(fromByteCount: Int64(png.count), countStyle: .file)
            thumb = ClipboardPaletteView.thumbnail(png, maxPixels: 256)
            dedupeKey = "image:" + SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        }
    }
}

@MainActor final class ShelfStore {
    /// Guards reused from the clipboard watcher — the same shapes arrive here.
    static let maxImageBytes = 5_000_000
    static let maxChars = 100_000

    private(set) var items: [ShelfItem] = []
    var cap: Int
    var onChange: (() -> Void)?
    /// Set by the pad so a rejected drop can say why.
    var onReject: ((String) -> Void)?

    init(cap: Int = 40) { self.cap = max(5, min(200, cap)) }

    /// Everything a drop does, minus AppKit — which is what makes the whole
    /// drop path testable against a plain NSPasteboard, with no drag session
    /// and no window. Returns how many items were actually added.
    @discardableResult
    func ingest(_ pb: NSPasteboard) -> Int {
        var added = 0

        // Files first, and via readObjects: `pb.string(forType:)` and
        // `pb.data(forType:)` read ONLY THE FIRST pasteboard item, so dragging
        // five files out of Finder would otherwise land exactly one.
        let fileURLs = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        for url in fileURLs where add(.file(url)) { added += 1 }
        if added > 0 { return added }

        // A web link is text in v1: it drags out into anything that takes text,
        // and most apps re-linkify it. A separate kind would buy nothing yet.
        let webURLs = ((pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? [])
            .filter { ($0.scheme == "http" || $0.scheme == "https") }
        for url in webURLs where add(.text(url.absoluteString)) { added += 1 }
        if added > 0 { return added }

        if let png = ClipboardHistory.pngFromPasteboard(pb) {
            guard png.count <= Self.maxImageBytes else {
                onReject?("That image is too big for the shelf")
                return 0
            }
            if add(.image(png)) { added += 1 }
            return added
        }

        let strings = (pb.readObjects(forClasses: [NSString.self], options: nil) as? [String]) ?? []
        for s in strings {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= Self.maxChars else {
                onReject?("That text is too long for the shelf")
                continue
            }
            if add(.text(trimmed)) { added += 1 }
        }
        return added
    }

    /// Adds, or moves an existing item back to the top. False means it was
    /// already here — a re-drop is not a second copy.
    @discardableResult
    func add(_ kind: ShelfItem.Kind) -> Bool {
        let item = ShelfItem(kind: kind)
        if let i = items.firstIndex(where: { $0.dedupeKey == item.dedupeKey }) {
            let existing = items.remove(at: i)
            items.insert(existing, at: 0)
            onChange?()
            return false
        }
        items.insert(item, at: 0)
        if items.count > cap { items.removeLast(items.count - cap) }
        onChange?()
        return true
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        onChange?()
    }

    func clear() {
        items.removeAll()
        onChange?()
    }
}

/// The tray itself. A floating, dockable, NON-ACTIVATING panel — the shape the
/// Macro and Agent pads use — because a shelf has to stay visible and on top,
/// on every Space, while you work in another app. That is the whole job.
///
/// NOT the clipboard drawer's shape: that one dismisses itself on a global
/// mouse-down, and a drag from Finder BEGINS with exactly that event, so the
/// drawer would vanish the instant you picked a file up.
@MainActor final class ShelfPad {
    static let placementKey = "shelf"
    static let width: CGFloat = 280
    static let height: CGFloat = 340

    private var panel: NSPanel?
    private var view: ShelfView?
    private var dockAnchor: PadDock?
    private var savedTopLeft: NSPoint?
    private var dark = true
    private let dockOverlay = PadDockOverlay()

    let store: ShelfStore
    var onVisibility: ((Bool) -> Void)?
    /// Copy (the default) or move, chosen in the shelf's own header. A move
    /// relocates the user's real file, so it is never a hidden modifier — the
    /// header always says which mode is armed.
    var moveMode = false {
        didSet { view?.moveMode = moveMode }
    }
    var onModeChange: ((Bool) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(store: ShelfStore) {
        self.store = store
        store.onChange = { [weak self] in self?.render() }
    }

    func toggle(dark: Bool, screen: NSScreen) {
        if isVisible { dismiss() } else { present(dark: dark, screen: screen) }
    }

    func present(dark: Bool, screen: NSScreen) {
        self.dark = dark
        if panel == nil, dockAnchor == nil, savedTopLeft == nil,
           let saved = PadPlacement.load(Self.placementKey) {
            dockAnchor = saved.anchor
            if saved.anchor == nil, let x = saved.x, let y = saved.y { savedTopLeft = NSPoint(x: x, y: y) }
        }
        buildPanel(on: screen)
        render()
        persistPlacement(open: true)
        onVisibility?(true)
    }

    func dismiss() {
        guard panel != nil else { return }
        persistPlacement(open: false)
        dockOverlay.hide()
        panel?.orderOut(nil)
        panel = nil
        view = nil
        onVisibility?(false)
    }

    private func buildPanel(on screen: NSScreen) {
        if panel != nil { return }
        let v = ShelfView(dark: dark)
        v.store = store
        v.onClose = { [weak self] in self?.dismiss() }
        v.onDragMoved = { [weak self] in
            guard let self, let panel = self.panel, let screen = panel.screen else { return }
            self.dockOverlay.update(padFrame: panel.frame, on: screen, dark: self.dark)
        }
        v.onDragEnded = { [weak self] in self?.snapAfterDrag() }
        v.moveMode = moveMode
        v.onModeChange = { [weak self] move in
            guard let self else { return }
            self.moveMode = move
            self.onModeChange?(move)
        }
        view = v

        let win = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.becomesKeyOnlyIfNeeded = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.contentView = v
        panel = win

        let field = PadDock.Field(screen: screen)
        let size = NSSize(width: Self.width, height: Self.height)
        let origin = dockAnchor?.origin(for: size, in: field)
            ?? savedTopLeft.map { NSPoint(x: $0.x, y: $0.y - Self.height) }
            // Default berth: mid-right. Out of the way, a short drag from
            // anywhere, and the corner neither other pad spawns in.
            ?? PadDock.midRight.origin(for: size, in: field)
        win.setFrame(NSRect(origin: origin, size: size), display: true)
        win.orderFrontRegardless()
    }

    private func render() {
        view?.reload()
    }

    private func snapAfterDrag() {
        dockOverlay.hide()
        guard let panel, let screen = panel.screen else { return }
        let field = PadDock.Field(screen: screen)
        if let snap = PadDock.nearest(to: panel.frame.origin, size: panel.frame.size, in: field) {
            dockAnchor = snap.anchor
            savedTopLeft = nil
            panel.setFrameOrigin(snap.origin)
        } else {
            dockAnchor = nil
            savedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        persistPlacement(open: true)
    }

    private func persistPlacement(open: Bool) {
        guard let panel else { return }
        PadPlacement.save(Self.placementKey, anchor: dockAnchor,
                          topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY),
                          mini: false, open: open)
    }
}

/// Rows, the drop target and the drag source, in one view.
final class ShelfView: NSView, NSDraggingSource {
    private static let headerH: CGFloat = 32
    private static let rowH: CGFloat = 52

    private let dark: Bool
    weak var storeRef: AnyObject?
    var store: ShelfStore? {
        didSet { reload() }
    }
    var onClose: (() -> Void)?
    var onModeChange: ((Bool) -> Void)?
    var moveMode = false {
        didSet { needsDisplay = true }
    }
    var onDragMoved: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var items: [ShelfItem] = []
    private var dropTarget = false
    private var scrollY: CGFloat = 0
    private var hoverRow: Int?

    // Press bookkeeping: a press inside a row is the possible START of a drag
    // out; a press anywhere else moves the panel. They never share a pixel.
    private var panelDragGrab: NSPoint?
    private var pressRow: Int?
    private var pressPoint = NSPoint.zero
    private var draggingRow: Int?
    private var clearRect = NSRect.zero
    private var closeRect = NSRect.zero
    private var copyRect = NSRect.zero
    private var moveRect = NSRect.zero
    private var removeRects: [(id: UUID, rect: NSRect)] = []

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: NSRect(x: 0, y: 0, width: ShelfPad.width, height: ShelfPad.height))
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .rtf, .string])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// The panel never takes key and Power Tools is almost always inactive —
    /// without this the first click is spent on focus and no drag ever starts.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reload() {
        items = store?.items ?? []
        // Never re-lay-out under a live drag: a destination that re-registers
        // mid-hover aborts the drag session in progress.
        guard !dropTarget, draggingRow == nil else { return }
        needsDisplay = true
    }

    /// Preview hook: render a given set with no store behind it.
    func previewItems(_ items: [ShelfItem], dropping: Bool = false) {
        self.items = items
        dropTarget = dropping
        needsDisplay = true
    }

    private var bg: NSColor {
        dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98)
             : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98)
    }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private var maxScroll: CGFloat {
        max(0, CGFloat(items.count) * Self.rowH - (bounds.height - Self.headerH - 8))
    }

    func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 0, y: Self.headerH + CGFloat(i) * Self.rowH - scrollY,
               width: bounds.width, height: Self.rowH)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        removeRects = []
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).setClip()
        bg.setFill()
        bounds.fill()

        // Header — and the whole of it is the drag handle for the panel.
        ("Shelf" as NSString).draw(at: NSPoint(x: 12, y: 9),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: fg])
        // Copy / Move, right next to the title: a move takes the real file out
        // of its folder, so the armed mode is always on screen rather than
        // hiding behind a modifier held at drag time.
        let seg: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium)]
        let pill = NSRect(x: 58, y: 8, width: 78, height: 17)
        (dark ? NSColor.white : .black).withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        copyRect = NSRect(x: pill.minX, y: pill.minY, width: pill.width / 2, height: pill.height)
        moveRect = NSRect(x: pill.midX, y: pill.minY, width: pill.width / 2, height: pill.height)
        let on = moveMode ? moveRect : copyRect
        (moveMode ? NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1) : accent).setFill()
        NSBezierPath(roundedRect: on.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7).fill()
        for (label, r, active) in [("Copy", copyRect, !moveMode), ("Move", moveRect, moveMode)] {
            var a = seg
            a[.foregroundColor] = active ? NSColor.white : dim
            let ns = label as NSString
            let w = ns.size(withAttributes: a).width
            ns.draw(at: NSPoint(x: r.midX - w / 2, y: r.minY + 2), withAttributes: a)
        }

        let x = "✕" as NSString
        let xa: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: dim]
        closeRect = NSRect(x: bounds.width - 26, y: 8, width: 16, height: 16)
        x.draw(at: NSPoint(x: closeRect.minX + 2, y: closeRect.minY), withAttributes: xa)
        if !items.isEmpty {
            let clear = "Clear" as NSString
            let ca: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim]
            let cw = clear.size(withAttributes: ca).width
            clearRect = NSRect(x: closeRect.minX - 10 - cw, y: 8, width: cw, height: 16)
            clear.draw(at: NSPoint(x: clearRect.minX, y: clearRect.minY + 1), withAttributes: ca)
        } else {
            clearRect = .zero
        }
        (dark ? NSColor.white : .black).withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: Self.headerH - 1, width: bounds.width, height: 1).fill()

        guard !items.isEmpty else {
            let title = "Drop files, text or images here." as NSString
            let sub = "Drag them back out when you need them.\nCleared when Power Tools quits." as NSString
            let ta: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: dim]
            let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = 3
            let sa: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10),
                                                     .foregroundColor: dim.withAlphaComponent(0.6),
                                                     .paragraphStyle: p]
            let tw = title.size(withAttributes: ta).width
            title.draw(at: NSPoint(x: bounds.midX - tw / 2, y: bounds.midY - 26), withAttributes: ta)
            sub.draw(in: NSRect(x: 16, y: bounds.midY - 4, width: bounds.width - 32, height: 40),
                     withAttributes: sa)
            drawDropHighlight()
            return
        }

        NSBezierPath(rect: NSRect(x: 0, y: Self.headerH, width: bounds.width,
                                  height: bounds.height - Self.headerH)).setClip()
        for (i, item) in items.enumerated() {
            let r = rowRect(i)
            guard r.maxY > Self.headerH, r.minY < bounds.height else { continue }
            if draggingRow == i {
                accent.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 3), xRadius: 8, yRadius: 8).fill()
            } else if hoverRow == i {
                (dark ? NSColor.white : .black).withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 3), xRadius: 8, yRadius: 8).fill()
            }
            if let thumb = item.thumb {
                thumb.draw(in: NSRect(x: 12, y: r.minY + 10, width: 32, height: 32),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                ("¶" as NSString).draw(at: NSPoint(x: 20, y: r.minY + 12),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 20),
                                                        .foregroundColor: dim])
            }
            let remove = NSRect(x: bounds.width - 26, y: r.minY + 18, width: 16, height: 16)
            removeRects.append((item.id, remove))
            if hoverRow == i {
                ("✕" as NSString).draw(at: NSPoint(x: remove.minX + 3, y: remove.minY),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 11),
                                                        .foregroundColor: dim])
            }
            let textW = bounds.width - 52 - (hoverRow == i ? 30 : 14)
            // Truncate with an ellipsis rather than letting a long name run
            // off the edge mid-word.
            let clip = NSMutableParagraphStyle()
            clip.lineBreakMode = .byTruncatingTail
            (item.title as NSString).draw(in: NSRect(x: 52, y: r.minY + 9, width: textW, height: 16),
                                          withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                           .foregroundColor: fg,
                                                           .paragraphStyle: clip])
            (item.subtitle as NSString).draw(in: NSRect(x: 52, y: r.minY + 27, width: textW, height: 14),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                                              .foregroundColor: dim,
                                                              .paragraphStyle: clip])
        }
        NSBezierPath(rect: bounds).setClip()
        drawDropHighlight()
    }

    private func drawDropHighlight() {
        guard dropTarget else { return }
        accent.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 13, yRadius: 13).fill()
        accent.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 12, yRadius: 12)
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: Drop IN

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTarget = true
        needsDisplay = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget = false
        needsDisplay = true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropTarget = false
        reload()
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget = false
        let added = store?.ingest(sender.draggingPasteboard) ?? 0
        reload()
        return added > 0
    }

    // MARK: Drag OUT

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return [] }
        // Copy unless the header says Move — and only a FILE can move; text and
        // images have nowhere to move FROM, so they always copy.
        guard moveMode, let row = draggingRow, row < items.count, items[row].fileURL != nil else {
            return .copy
        }
        // Offering both lets the destination take the move if it can and fall
        // back to a copy if it cannot; endedAt tells us which it did.
        return [.move, .copy]
    }

    /// The header toggle is the ONLY thing that decides this. Without this, a ⌘
    /// held at drag time would silently turn a copy into a move of the user's
    /// real file — the mode should never be a modifier nobody can see.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint,
                         operation: NSDragOperation) {
        // A copy leaves the row alone — parking is sticky and repeatable. A
        // MOVE means the destination took the file away, so the row now points
        // at a path that no longer exists and has to go with it.
        if operation == .move, let row = draggingRow, row < items.count,
           let item = items.indices.contains(row) ? items[row] : nil, item.fileURL != nil {
            store?.remove(id: item.id)
        }
        draggingRow = nil
        needsDisplay = true
    }

    private func beginItemDrag(row: Int, event: NSEvent) {
        guard row < items.count else { return }
        let item = items[row]
        let writer: NSPasteboardWriting
        switch item.kind {
        case .file(let url): writer = url as NSURL          // a real public.file-url
        case .text(let s):
            let pbItem = NSPasteboardItem()
            pbItem.setString(s, forType: .string)
            writer = pbItem
        case .image(let png):
            let pbItem = NSPasteboardItem()
            pbItem.setData(png, forType: .png)
            writer = pbItem
        }
        let dragItem = NSDraggingItem(pasteboardWriter: writer)
        let r = rowRect(row)
        dragItem.setDraggingFrame(r, contents: rowSnapshot(row))
        draggingRow = row
        needsDisplay = true
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    private func rowSnapshot(_ i: Int) -> NSImage? {
        let r = rowRect(i)
        guard r.width > 0, r.height > 0, let rep = bitmapImageRepForCachingDisplay(in: r) else { return nil }
        cacheDisplay(in: r, to: rep)
        let image = NSImage(size: r.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = items.indices.first { rowRect($0).contains(p) }
        if row != hoverRow { hoverRow = row; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverRow != nil { hoverRow = nil; needsDisplay = true }
    }

    override func scrollWheel(with event: NSEvent) {
        guard maxScroll > 0 else { return }
        scrollY = min(max(0, scrollY - event.scrollingDeltaY), maxScroll)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressRow = nil
        panelDragGrab = nil

        if closeRect.insetBy(dx: -6, dy: -6).contains(p) { onClose?(); return }
        if copyRect.contains(p), moveMode { moveMode = false; onModeChange?(false); return }
        if moveRect.contains(p), !moveMode { moveMode = true; onModeChange?(true); return }
        if copyRect.union(moveRect).contains(p) { return }   // clicking the armed half does nothing
        if !clearRect.isEmpty, clearRect.insetBy(dx: -6, dy: -6).contains(p) { store?.clear(); return }
        // The ✕ is checked BEFORE the row press, so it can never start a drag.
        if let hit = removeRects.first(where: { $0.rect.insetBy(dx: -5, dy: -5).contains(p) }) {
            store?.remove(id: hit.id)
            return
        }
        if let row = items.indices.first(where: { rowRect($0).contains(p) }) {
            if event.clickCount == 2 { open(row: row); return }
            pressRow = row
            pressPoint = event.locationInWindow
            return
        }
        // Header, empty body, anywhere else: the panel moves.
        panelDragGrab = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        if let grab = panelDragGrab, let window {
            let o = window.frame.origin
            window.setFrameOrigin(NSPoint(x: o.x + event.locationInWindow.x - grab.x,
                                          y: o.y + event.locationInWindow.y - grab.y))
            onDragMoved?()
            return
        }
        guard let row = pressRow else { return }
        // A 4pt gate separates a click from a drag-out; it is never asked to
        // decide between moving the panel and dragging an item — those are
        // different zones entirely.
        let d = hypot(event.locationInWindow.x - pressPoint.x, event.locationInWindow.y - pressPoint.y)
        guard d > 4 else { return }
        pressRow = nil
        beginItemDrag(row: row, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if panelDragGrab != nil { onDragEnded?() }
        panelDragGrab = nil
        pressRow = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let row = items.indices.first(where: { rowRect($0).contains(p) }) else { return }
        let item = items[row]
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(menuCopy(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = item.id.uuidString
        menu.addItem(copy)
        if item.fileURL != nil {
            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(menuReveal(_:)), keyEquivalent: "")
            reveal.target = self; reveal.representedObject = item.id.uuidString
            menu.addItem(reveal)
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(menuRemove(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = item.id.uuidString
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: p, in: self)
    }

    private func item(for obj: Any?) -> ShelfItem? {
        guard let id = obj as? String else { return nil }
        return items.first { $0.id.uuidString == id }
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let item = item(for: sender.representedObject) else { return }
        copyToPasteboard(item)
    }
    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let url = item(for: sender.representedObject)?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func menuRemove(_ sender: NSMenuItem) {
        guard let item = item(for: sender.representedObject) else { return }
        store?.remove(id: item.id)
    }

    private func copyToPasteboard(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .file(let url): pb.writeObjects([url as NSURL])
        case .text(let s): pb.setString(s, forType: .string)
        case .image(let png): pb.setData(png, forType: .png)
        }
    }

    /// Double-click: a file opens, anything else goes to the clipboard.
    private func open(row: Int) {
        guard row < items.count else { return }
        let item = items[row]
        if let url = item.fileURL {
            NSWorkspace.shared.open(url)
        } else {
            copyToPasteboard(item)
        }
    }
}
