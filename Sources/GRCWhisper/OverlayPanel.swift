import AppKit

/// A live audio waveform: dense monochrome bars driven by mic level samples.
final class WaveformView: NSView {
    private var samples: [CGFloat]
    var barColor: NSColor = .black
    var barWidthFraction: CGFloat = 0.45

    init(bars: Int = 90) {
        samples = Array(repeating: 0.08, count: bars)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func push(_ level: CGFloat) {
        samples.removeFirst()
        samples.append(min(max(level, 0.08), 1))
        needsDisplay = true
    }
    func setSamples(_ values: [CGFloat]) { samples = values; needsDisplay = true }
    func idle() { samples = Array(repeating: 0.08, count: samples.count); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let n = samples.count
        guard n > 0, bounds.width > 0 else { return }
        let slot = bounds.width / CGFloat(n)
        let barW = max(1.5, slot * barWidthFraction)
        barColor.setFill()
        for (i, s) in samples.enumerated() {
            let h = max(barW, s * bounds.height)
            let x = CGFloat(i) * slot + (slot - barW) / 2
            let y = (bounds.height - h) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: h),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}

/// Flat, solid rounded pill — no blur. Draws its own fill so light/dark is exact
/// (and so the offscreen `render-overlay` preview matches the live look).
final class FlatPill: NSView {
    var fill: NSColor = .white
    var stroke: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 22, yRadius: 22)
        fill.setFill()
        path.fill()
        if let stroke {
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// The dictation HUD: a flat white/black pill (Claude-Desktop style) with a mic on
/// the left, a live waveform in the middle, and "release to stop" on the right.
/// Result/error text replaces the waveform briefly, then it hides.
final class OverlayPanel {
    static let width: CGFloat = 500
    static let height: CGFloat = 64
    private static let iconSize: CGFloat = 24
    private static var iconFrame: NSRect { NSRect(x: 20, y: (height - iconSize) / 2, width: iconSize, height: iconSize) }
    private static let hintWidth: CGFloat = 116
    private static var hintFrame: NSRect { NSRect(x: width - hintWidth - 18, y: (height - 20) / 2, width: hintWidth, height: 20) }
    private static var waveFrame: NSRect {
        let x = 20 + iconSize + 14
        return NSRect(x: x, y: (height - 26) / 2, width: (width - hintWidth - 18) - x - 12, height: 26)
    }
    private static var textFrame: NSRect {
        let x = 20 + iconSize + 14
        return NSRect(x: x, y: (height - 22) / 2, width: width - x - 18, height: 22)
    }

    var anchor: Config.OverlayPosition = .bottomCenter
    var scheme: Config.Appearance = .light { didSet { applyScheme() } }

    private let panel: NSPanel
    private let pill = FlatPill(frame: NSRect(x: 0, y: 0, width: OverlayPanel.width, height: OverlayPanel.height))
    private let iconView = NSImageView()
    private let waveform = WaveformView(bars: 90)
    private let hintLabel = NSTextField(labelWithString: "release to stop")
    private let textLabel = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    // Palette derived from the theme.
    private var fg: NSColor { scheme.isDark ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.9) }
    private var hintColor: NSColor { scheme.isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.42) }
    private var waveColor: NSColor { scheme.isDark ? NSColor.white.withAlphaComponent(0.82) : NSColor.black.withAlphaComponent(0.72) }
    private var pillFill: NSColor { scheme.isDark ? NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1) : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1) }
    private var pillStroke: NSColor? { scheme.isDark ? nil : NSColor.black.withAlphaComponent(0.08) }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        iconView.frame = Self.iconFrame
        iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "GRC Whisper")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        pill.addSubview(iconView)

        waveform.frame = Self.waveFrame
        pill.addSubview(waveform)

        hintLabel.frame = Self.hintFrame
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.alignment = .right
        pill.addSubview(hintLabel)

        textLabel.frame = Self.textFrame
        textLabel.font = .systemFont(ofSize: 14, weight: .medium)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.cell?.usesSingleLineMode = true
        textLabel.isHidden = true
        pill.addSubview(textLabel)

        panel.contentView = pill
        applyScheme()
    }

    private func applyScheme() {
        pill.fill = pillFill
        pill.stroke = pillStroke
        pill.needsDisplay = true
        iconView.contentTintColor = fg
        waveform.barColor = waveColor
        hintLabel.textColor = hintColor
        if !textLabel.isHidden { textLabel.textColor = fg }
    }

    /// Builds a static preview pill (recording state) for `render-overlay`.
    static func buildContent(dark: Bool = false) -> NSView {
        let panel = OverlayPanel()
        panel.scheme = dark ? .dark : .light
        panel.waveform.setSamples((0..<90).map { i in
            let env: Double = 0.45 + 0.4 * sin(Double(i) / 6) * cos(Double(i) / 3.5)
            return CGFloat(min(max(0.12, abs(env)), 1))
        })
        panel.setMode(waveform: true)
        panel.hintLabel.stringValue = "release to stop"
        return panel.pill
    }

    private func setMode(waveform showWave: Bool) {
        waveform.isHidden = !showWave
        hintLabel.isHidden = !showWave
        textLabel.isHidden = showWave
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let f = screen.visibleFrame
        let w = Self.width, h = Self.height, m: CGFloat = 28
        let x: CGFloat, y: CGFloat
        switch anchor {
        case .bottomCenter: x = f.midX - w / 2; y = f.minY + m
        case .bottomLeft:   x = f.minX + m;      y = f.minY + m
        case .bottomRight:  x = f.maxX - w - m;  y = f.minY + m
        case .center:       x = f.midX - w / 2;  y = f.midY - h / 2
        case .topCenter:    x = f.midX - w / 2;  y = f.maxY - h - m
        case .topLeft:      x = f.minX + m;      y = f.maxY - h - m
        case .topRight:     x = f.maxX - w - m;  y = f.maxY - h - m
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func showRecording() {
        hideTimer?.invalidate()
        applyScheme()
        waveform.idle()
        hintLabel.stringValue = "release to stop"
        setMode(waveform: true)
        position()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    /// The clean HUD shows only the waveform while you speak (no inline transcript).
    func showPartial(_ text: String) {}

    func setLevels(_ levels: [Float]) {
        for l in levels { waveform.push(CGFloat(l)) }
    }

    func showProcessing() {
        hintLabel.stringValue = "…"
        setMode(waveform: true)
    }

    func showResult(_ text: String) {
        setMode(waveform: false)
        textLabel.textColor = fg
        textLabel.stringValue = text
        hideAfter(1.4)
    }

    func showError(_ message: String) {
        setMode(waveform: false)
        textLabel.textColor = NSColor(srgbRed: 0.85, green: 0.35, blue: 0.15, alpha: 1)
        textLabel.stringValue = message
        position()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        hideAfter(2.6)
    }

    func hide() {
        hideTimer?.invalidate()
        panel.orderOut(nil)
    }

    private func hideAfter(_ seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.panel.orderOut(nil)
        }
    }
}
