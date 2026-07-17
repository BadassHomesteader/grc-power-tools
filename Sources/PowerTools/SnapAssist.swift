import Cocoa

/// Windows-style Snap Assist: after you snap a window to one side, show the OTHER
/// on-screen windows as clickable thumbnails filling the empty space; click one to
/// snap it into that gap.
@MainActor
final class SnapAssist {
    private var window: NSWindow?
    private var timeout: Timer?

    struct Candidate {
        let pid: pid_t
        let windowID: CGWindowID
        let title: String
        let icon: NSImage?
    }

    var isVisible: Bool { window != nil }

    /// Show the picker filling `region` (global bottom-left rect). `onPick` gets the
    /// chosen window; `onCancel` fires on Esc / click-empty / timeout (e.g. to
    /// refocus the previous app). Does nothing if there are no candidates.
    func present(in region: CGRect, excluding excludeWID: CGWindowID, dark: Bool,
                 onPick: @escaping (Candidate) -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        let candidates = Array(Self.candidates(excluding: excludeWID).prefix(8))
        guard !candidates.isEmpty else { onCancel(); return }

        let win = KeyableWindow(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = SnapAssistView(candidates: candidates, dark: dark)
        view.frame = NSRect(origin: .zero, size: region.size)
        view.onPick = { [weak self] cand in self?.dismiss(); onPick(cand) }
        view.onCancel = { [weak self] in self?.dismiss(); onCancel() }
        win.contentView = view
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)

        // Don't leave a focus-stealing overlay up forever if the user walks away.
        timeout = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window != nil else { return }
                self.dismiss()
                onCancel()
            }
        }
    }

    func dismiss() {
        timeout?.invalidate(); timeout = nil
        window?.orderOut(nil)
        window = nil
    }

    // MARK: Enumeration

    static func candidates(excluding excludeWID: CGWindowID) -> [Candidate] {
        let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var out: [Candidate] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let wid = w[kCGWindowNumber as String] as? CGWindowID, wid != excludeWID else { continue }
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != myPID else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Power Tools" { continue }
            if (w[kCGWindowIsOnscreen as String] as? Bool) == false { continue }
            guard let bDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bDict) else { continue }
            if bounds.width < 120 || bounds.height < 90 { continue }  // skip tiny/util windows
            let title = w[kCGWindowName as String] as? String ?? ""
            let icon = NSRunningApplication(processIdentifier: pid)?.icon
            out.append(Candidate(pid: pid, windowID: wid,
                                 title: title.isEmpty ? owner : title, icon: icon))
        }
        return out
    }
}

/// The Snap Assist canvas: a dim panel of window tiles; click one, or Esc / click
/// empty space to cancel.
final class SnapAssistView: NSView {
    private let candidates: [SnapAssist.Candidate]
    private let dark: Bool
    var onPick: ((SnapAssist.Candidate) -> Void)?
    var onCancel: (() -> Void)?

    private var tiles: [NSRect] = []

    init(candidates: [SnapAssist.Candidate], dark: Bool) {
        self.candidates = candidates
        self.dark = dark
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func computeTiles() {
        tiles.removeAll()
        guard !candidates.isEmpty else { return }
        let pad: CGFloat = 24, gap: CGFloat = 16
        let avail = bounds.insetBy(dx: pad, dy: pad)
        guard avail.width > 40, avail.height > 40 else { return }
        let cols = max(1, min(candidates.count, Int(avail.width / 180)))
        let rows = Int(ceil(Double(candidates.count) / Double(cols)))
        let tileW = min(240, (avail.width - CGFloat(cols - 1) * gap) / CGFloat(cols))
        let tileH = min(tileW * 0.72, (avail.height - CGFloat(rows - 1) * gap) / CGFloat(max(rows, 1)))
        let gridW = CGFloat(cols) * tileW + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * tileH + CGFloat(rows - 1) * gap
        let ox = avail.minX + (avail.width - gridW) / 2
        let oy = avail.minY + max(0, (avail.height - gridH) / 2)
        for i in candidates.indices {
            let c = i % cols, r = i / cols
            tiles.append(NSRect(x: ox + CGFloat(c) * (tileW + gap),
                                y: oy + CGFloat(r) * (tileH + gap),
                                width: tileW, height: tileH))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        computeTiles()
        (dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.35)).setFill()
        bounds.fill()
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        for (i, tile) in tiles.enumerated() {
            let cand = candidates[i]
            // Card.
            let card = NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(0.12).setFill(); card.fill()
            NSColor.white.withAlphaComponent(0.25).setStroke(); card.lineWidth = 1; card.stroke()

            let titleH: CGFloat = 24
            let imgRect = NSRect(x: tile.minX + 8, y: tile.minY + 8,
                                 width: tile.width - 16, height: tile.height - titleH - 12)
            if let icon = cand.icon {
                let s = min(imgRect.width, imgRect.height, 72)
                icon.draw(in: NSRect(x: imgRect.midX - s / 2, y: imgRect.midY - s / 2, width: s, height: s))
            }
            let title = cand.title as NSString
            let tp = NSMutableParagraphStyle(); tp.alignment = .center; tp.lineBreakMode = .byTruncatingTail
            var ta = titleAttrs; ta[.paragraphStyle] = tp
            title.draw(in: NSRect(x: tile.minX + 8, y: tile.maxY - titleH + 4, width: tile.width - 16, height: 18),
                       withAttributes: ta)
        }
        // Hint.
        let hint = "click a window to fill the space · esc to skip" as NSString
        let ha: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let hs = hint.size(withAttributes: ha)
        hint.draw(at: NSPoint(x: (bounds.width - hs.width) / 2, y: bounds.height - 26), withAttributes: ha)
    }

    override func mouseDown(with event: NSEvent) {
        if tiles.isEmpty { computeTiles() }
        let p = convert(event.locationInWindow, from: nil)
        if let i = tiles.firstIndex(where: { $0.contains(p) }) {
            onPick?(candidates[i])
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }  // Esc
    }
}
