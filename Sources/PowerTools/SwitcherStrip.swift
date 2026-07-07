import Cocoa
import ScreenCaptureKit

/// The ⌘Tab strip: while ⌘ is held, a row of window tiles (live thumbnails via
/// ScreenCaptureKit, app icon + title while they load) with the selection
/// highlighted. Keyboard-only — the panel is nonactivating and click-through,
/// so it never steals focus from the window you're about to leave.
@MainActor
final class SwitcherStrip {
    struct Tile {
        let pid: pid_t
        let windowID: CGWindowID
        let title: String
        let icon: NSImage?
    }

    private var panel: NSPanel?
    private var view: SwitcherStripView?
    private var captureTask: Task<Void, Never>?

    var isVisible: Bool { panel != nil }

    func present(tiles: [Tile], highlight: Int, dark: Bool) {
        dismiss()
        let v = SwitcherStripView(tiles: tiles, dark: dark)
        v.highlighted = highlight
        let size = v.fittingSize
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        let win = NSPanel(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        v.frame = NSRect(origin: .zero, size: size)
        win.contentView = v
        panel = win
        view = v
        win.orderFrontRegardless()
        loadThumbnails(tiles)
    }

    func setHighlight(_ i: Int) {
        view?.highlighted = i
        view?.needsDisplay = true
    }

    func dismiss() {
        captureTask?.cancel()
        captureTask = nil
        panel?.orderOut(nil)
        panel = nil
        view = nil
    }

    /// One-shot SCK screenshots, filled in as they arrive (tiles show the app
    /// icon until then). Uses the existing Screen Recording grant.
    private func loadThumbnails(_ tiles: [Tile]) {
        captureTask = Task { [weak self] in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            else { return }
            for (i, tile) in tiles.enumerated() {
                if Task.isCancelled { return }
                guard let scWin = content.windows.first(where: { $0.windowID == tile.windowID }) else { continue }
                let aspect = max(scWin.frame.width, 1) / max(scWin.frame.height, 1)
                var w = SwitcherStripView.thumbW, h = w / aspect
                if h > SwitcherStripView.thumbH { h = SwitcherStripView.thumbH; w = h * aspect }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(w * 2)
                cfg.height = Int(h * 2)
                cfg.showsCursor = false
                let filter = SCContentFilter(desktopIndependentWindow: scWin)
                guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                else { continue }
                if Task.isCancelled { return }
                self?.view?.setThumbnail(NSImage(cgImage: cg, size: NSSize(width: w, height: h)), at: i)
            }
        }
    }
}

final class SwitcherStripView: NSView {
    static let thumbW: CGFloat = 168
    static let thumbH: CGFloat = 108
    private static let tileW: CGFloat = thumbW + 12
    private static let tileH: CGFloat = thumbH + 34
    private static let gap: CGFloat = 10
    private static let pad: CGFloat = 14

    private let tiles: [SwitcherStrip.Tile]
    private let dark: Bool
    private var thumbnails: [Int: NSImage] = [:]
    var highlighted = 0

    init(tiles: [SwitcherStrip.Tile], dark: Bool) {
        self.tiles = tiles
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize {
        let n = CGFloat(max(tiles.count, 1))
        return NSSize(width: Self.pad * 2 + n * Self.tileW + (n - 1) * Self.gap,
                      height: Self.pad * 2 + Self.tileH)
    }

    func setThumbnail(_ image: NSImage, at index: Int) {
        thumbnails[index] = image
        needsDisplay = true
    }

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.98) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 0.98) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.55) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }

    private func tileRect(_ i: Int) -> NSRect {
        NSRect(x: Self.pad + CGFloat(i) * (Self.tileW + Self.gap), y: Self.pad,
               width: Self.tileW, height: Self.tileH)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).setClip()
        bg.setFill()
        bounds.fill()

        for (i, tile) in tiles.enumerated() {
            let r = tileRect(i)
            if i == highlighted {
                accent.withAlphaComponent(0.16).setFill()
                let cell = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
                cell.fill()
                accent.setStroke()
                cell.lineWidth = 2.5
                cell.stroke()
            }
            // Thumbnail area (icon placeholder until the capture lands).
            let slot = NSRect(x: r.minX + 6, y: r.minY + 6, width: Self.thumbW, height: Self.thumbH)
            if let img = thumbnails[i] {
                let dest = NSRect(x: slot.midX - img.size.width / 2, y: slot.midY - img.size.height / 2,
                                  width: img.size.width, height: img.size.height)
                img.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                (dark ? NSColor.white : .black).withAlphaComponent(0.2).setStroke()
                let frame = NSBezierPath(roundedRect: dest, xRadius: 4, yRadius: 4)
                frame.lineWidth = 1
                frame.stroke()
            } else if let icon = tile.icon {
                let d: CGFloat = 52
                icon.draw(in: NSRect(x: slot.midX - d / 2, y: slot.midY - d / 2, width: d, height: d),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // Small app-icon badge on top of the thumbnail.
            if thumbnails[i] != nil, let icon = tile.icon {
                icon.draw(in: NSRect(x: slot.minX + 4, y: slot.maxY - 24, width: 20, height: 20),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            // Title.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: i == highlighted ? .semibold : .regular),
                .foregroundColor: i == highlighted ? fg : dim,
                .paragraphStyle: {
                    let p = NSMutableParagraphStyle()
                    p.lineBreakMode = .byTruncatingTail
                    p.alignment = .center
                    return p
                }(),
            ]
            (tile.title as NSString).draw(in: NSRect(x: r.minX + 4, y: r.maxY - 24, width: r.width - 8, height: 16),
                                          withAttributes: attrs)
        }
    }
}
