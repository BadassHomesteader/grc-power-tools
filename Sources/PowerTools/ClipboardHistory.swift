import Cocoa
import ImageIO

/// Clipboard history — the Windows Win+V gap. A lightweight watcher records text
/// copies into SQLite; hold hotkey + H slides in a drawer of recent clips from the
/// right edge — pick one and it pastes into the app you came from (and becomes
/// the current clipboard).
///
/// Privacy rules: items marked `org.nspasteboard.ConcealedType` (password
/// managers) or `org.nspasteboard.TransientType`, and our own clipboard-swap
/// writes (session-tagged + concealed), are never recorded.
@MainActor
final class ClipboardHistory {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let maxChars = 100_000
    private static let maxImageBytes = 5_000_000

    private let store: Store
    private var timer: Timer?
    private var lastChangeCount: Int
    var enabled: Bool

    init(store: Store, enabled: Bool) {
        self.store = store
        self.enabled = enabled
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer?.invalidate()
        // Poll changeCount — the standard technique; there is no pasteboard
        // notification API. A no-change poll is two integer reads.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard enabled else { return }
        guard let items = pb.pasteboardItems,
              !items.contains(where: { $0.types.contains(Self.concealed) || $0.types.contains(Self.transient) })
        else { return }
        // Image data present means the user copied an image (screenshot, browser
        // image, …) — record that; otherwise record the text representation.
        if let png = Self.pngFromPasteboard(pb) {
            guard png.count <= Self.maxImageBytes else { return }
            let label: String
            if let rep = NSBitmapImageRep(data: png) {
                label = "Image · \(rep.pixelsWide)×\(rep.pixelsHigh)"
            } else {
                label = "Image"
            }
            store.addImageClip(png, label: label)
            return
        }
        guard let text = pb.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.count <= Self.maxChars else { return }
        store.addClip(text)
    }

    /// Image off the pasteboard, normalized to PNG (so storage and re-paste are
    /// format-stable regardless of what the source app provided).
    static func pngFromPasteboard(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
}

/// The hold + H drawer: recent clips in a narrow, full-height list that slides in
/// from the right edge of the screen (Ledge's shape) and back out. Arrows, digits
/// or a click pick; Esc, hold + H again, or a click anywhere else closes.
///
/// It never activates Power Tools. Activating to take the keyboard raised the
/// app's other windows (Settings, chat) over the document you were in and moved
/// focus off it; now that app keeps focus the whole time, the drawer's keys come
/// through the hotkey tap (`clipboardDrawerVisible`), and a pick pastes straight in.
@MainActor
final class ClipboardPalette {
    private static let slide: TimeInterval = 0.18

    private var window: NSPanel?
    private weak var view: ClipboardPaletteView?
    private var clickMonitors: [Any] = []
    private var cancelHandler: (() -> Void)?
    /// Just past the screen's right edge — where the drawer slides from and back to.
    private var hiddenFrame = NSRect.zero
    /// Mirrored into the hotkey tap, which routes the drawer's keys while it is out.
    var onVisibility: ((Bool) -> Void)?

    var isVisible: Bool { window != nil }

    func present(clips: [ClipEntry], dark: Bool, screen: NSScreen,
                 onPick: @escaping (ClipEntry) -> Void, onCancel: @escaping () -> Void) {
        dismiss(animated: false)
        let vf = screen.visibleFrame
        let width = ClipboardPaletteView.width
        let shown = NSRect(x: vf.maxX - width, y: vf.minY, width: width, height: vf.height)
        let hidden = shown.offsetBy(dx: width, dy: 0)
        hiddenFrame = hidden

        let view = ClipboardPaletteView(clips: clips, dark: dark)
        view.frame = NSRect(origin: .zero, size: shown.size)
        view.onPick = { [weak self] clip in self?.dismiss(); onPick(clip) }
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

        // A click anywhere but the drawer closes it, like a menu: the global
        // monitor hears other apps, the local one our other windows. Nothing is
        // swallowed — the click still lands where it was aimed.
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

    /// A key the hotkey tap routed here. -1 means some other key was pressed:
    /// that closes the drawer and the key goes on to the app you are in.
    func handleKey(_ code: Int) {
        guard isVisible else { return }
        if code < 0 { dismiss(); return }
        view?.handleKeyCode(code)
    }

    /// Close and return focus to the app the drawer was opened over (Esc, or
    /// hold + H a second time).
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

final class ClipboardPaletteView: NSView {
    static let width: CGFloat = 360
    private static let headerH: CGFloat = 56
    private static let footerH: CGFloat = 34
    private static let textCardH: CGFloat = 70
    private static let imageCardH: CGFloat = 132
    private static let gap: CGFloat = 8
    private static let side: CGFloat = 12

    private let clips: [ClipEntry]
    private let dark: Bool
    /// Built once: decoding every full-size PNG, or flattening a 100k-character
    /// clip, on each scroll redraw would stutter.
    private let thumbs: [NSImage?]
    private let previews: [String]
    var onPick: ((ClipEntry) -> Void)?
    var onCancel: (() -> Void)?

    private var highlighted = 0
    private var scrollY: CGFloat = 0

    init(clips: [ClipEntry], dark: Bool) {
        self.clips = clips
        self.dark = dark
        self.thumbs = clips.map { $0.image.flatMap { Self.thumbnail($0, maxPixels: 640) } }
        self.previews = clips.map {
            String($0.content.prefix(400)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// The drawer never takes key, so the first click has to act, not focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The live drawer is as tall as the screen; this is the offscreen preview's
    /// size — every card, capped at a laptop screen's worth.
    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: min(Self.headerH + contentHeight + Self.footerH, 900))
    }

    private static func thumbnail(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1) }
    private var cardFill: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(dark ? 0.06 : 0.045) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private func cardHeight(_ i: Int) -> CGFloat { clips[i].image != nil ? Self.imageCardH : Self.textCardH }
    private var contentHeight: CGFloat {
        clips.indices.reduce(0) { $0 + cardHeight($1) + Self.gap }
    }
    /// Between the header and the footer — the part that scrolls.
    private var listRect: NSRect {
        NSRect(x: 0, y: Self.headerH, width: bounds.width,
               height: max(bounds.height - Self.headerH - Self.footerH, 0))
    }
    private var maxScroll: CGFloat { max(contentHeight - listRect.height, 0) }

    /// A card in view coordinates, scroll applied. Heights vary by kind, so this
    /// is a prefix sum — the same rect feeds drawing and hit-testing.
    private func cardRect(_ i: Int) -> NSRect {
        var y = Self.headerH - scrollY
        for j in 0..<i { y += cardHeight(j) + Self.gap }
        return NSRect(x: Self.side, y: y, width: bounds.width - Self.side * 2, height: cardHeight(i))
    }

    private func cardAt(_ p: NSPoint) -> Int? {
        guard listRect.contains(p) else { return nil }
        return clips.indices.first { cardRect($0).contains(p) }
    }

    /// "3m ago" style stamp from the stored ISO timestamp.
    private func age(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    override func draw(_ dirtyRect: NSRect) {
        // Flush against the screen edge: only the leading corners round, so the
        // rounded rect runs past the right side of the view.
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width + 24, height: bounds.height),
                     xRadius: 14, yRadius: 14).setClip()
        bg.setFill()
        bounds.fill()

        ("Clipboard history" as NSString).draw(at: NSPoint(x: 20, y: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: fg])
        let count = "\(clips.count)" as NSString
        let countAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: dim]
        count.draw(at: NSPoint(x: bounds.width - 20 - count.size(withAttributes: countAttrs).width, y: 21),
                   withAttributes: countAttrs)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: listRect).addClip()
        for i in clips.indices {
            let r = cardRect(i)
            guard r.maxY >= listRect.minY, r.minY <= listRect.maxY else { continue }
            drawCard(i, in: r)
        }
        NSGraphicsContext.restoreGraphicsState()

        (dark ? NSColor.white : .black).withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: bounds.height - Self.footerH, width: bounds.width, height: 1).fill()
        ("↑↓ or scroll · ↵ paste · 1–9 · esc" as NSString).draw(
            at: NSPoint(x: 20, y: bounds.height - Self.footerH + 10),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim])
    }

    private func drawCard(_ i: Int, in r: NSRect) {
        let clip = clips[i]
        let hot = i == highlighted
        (hot ? accent.withAlphaComponent(0.9) : cardFill).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        let titleColor = hot ? NSColor.white : fg
        let subColor = hot ? NSColor.white.withAlphaComponent(0.8) : dim

        // Digits 1–9 pick the first nine without the arrows.
        if i < 9 {
            let badge = NSRect(x: r.minX + 10, y: r.minY + 10, width: 20, height: 20)
            (hot ? NSColor.white.withAlphaComponent(0.25) : (dark ? NSColor.white : .black).withAlphaComponent(0.1)).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            let n = "\(i + 1)" as NSString
            let nAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: titleColor]
            let ns = n.size(withAttributes: nAttrs)
            n.draw(at: NSPoint(x: badge.midX - ns.width / 2, y: badge.midY - ns.height / 2), withAttributes: nAttrs)
        }
        let textX = r.minX + 40
        let textW = r.maxX - 12 - textX

        let meta: String
        if let thumb = thumbs[i] {
            // An image fills the card above its meta line, aspect-fit, never upscaled.
            let slot = NSRect(x: textX, y: r.minY + 10, width: textW, height: r.height - 38)
            let scale = min(slot.width / max(thumb.size.width, 1), slot.height / max(thumb.size.height, 1), 1)
            let w = thumb.size.width * scale, h = thumb.size.height * scale
            let dest = NSRect(x: slot.minX, y: slot.midY - h / 2, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: dest, xRadius: 6, yRadius: 6).addClip()
            thumb.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            meta = "\(clip.content) · \(age(clip.timestamp))"
        } else {
            // Text: two lines of it, whitespace collapsed, truncated at the end.
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byWordWrapping
            (previews[i] as NSString).draw(
                with: NSRect(x: textX, y: r.minY + 9, width: textW, height: 36),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                             .foregroundColor: titleColor, .paragraphStyle: p])
            let lines = clip.content.filter { $0 == "\n" }.count + 1
            meta = lines > 1 ? "\(age(clip.timestamp)) · \(lines) lines"
                             : "\(age(clip.timestamp)) · \(clip.content.count) chars"
        }
        (meta as NSString).draw(at: NSPoint(x: textX, y: r.maxY - 22),
            withAttributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: subColor])
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = cardAt(p), i != highlighted {
            highlighted = i
            needsDisplay = true
        }
    }

    /// A card pastes; the header, footer and gaps do nothing — closing is Esc or
    /// a click outside the drawer.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = cardAt(p) { onPick?(clips[i]) }
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        let next = min(max(scrollY - dy, 0), maxScroll)
        guard next != scrollY else { return }
        scrollY = next
        needsDisplay = true
    }

    /// Digits 1–9 by virtual key code — the tap hands over codes, not characters.
    private static let digitForKeyCode: [Int: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    /// A key the tap routed to the drawer (which never has key focus itself).
    func handleKeyCode(_ code: Int) {
        switch code {
        case 53: onCancel?()
        case 36, 76: if !clips.isEmpty { onPick?(clips[highlighted]) }
        case 125: move(to: highlighted + 1)
        case 126: move(to: highlighted - 1)
        default:
            if let n = Self.digitForKeyCode[code], n <= clips.count { onPick?(clips[n - 1]) }
        }
    }

    /// Arrow to a card and scroll just far enough to keep it in view.
    private func move(to i: Int) {
        guard !clips.isEmpty else { return }
        highlighted = min(max(i, 0), clips.count - 1)
        let r = cardRect(highlighted)
        let list = listRect
        if r.minY < list.minY + Self.gap {
            scrollY -= list.minY + Self.gap - r.minY
        } else if r.maxY > list.maxY - Self.gap {
            scrollY += r.maxY - (list.maxY - Self.gap)
        }
        scrollY = min(max(scrollY, 0), maxScroll)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}
