import AppKit

/// A live audio waveform: scrolling rounded bars driven by mic level samples.
final class WaveformView: NSView {
    private var samples: [CGFloat]
    var barColor: NSColor = NSColor(srgbRed: 0.55, green: 0.6, blue: 1, alpha: 1)

    init(bars: Int = 64) {
        samples = Array(repeating: 0.06, count: bars)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func push(_ level: CGFloat) {
        samples.removeFirst()
        samples.append(min(max(level, 0.06), 1))
        needsDisplay = true
    }
    func setSamples(_ values: [CGFloat]) { samples = values; needsDisplay = true }
    func idle() { samples = Array(repeating: 0.06, count: samples.count); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let n = samples.count
        guard n > 0, bounds.width > 0 else { return }
        let slot = bounds.width / CGFloat(n)
        let barW = max(2, slot * 0.55)
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

/// Draws the "menu" of actions with the leader keys as keycap chips.
final class KeycapHintView: NSView {
    var segments: [(key: String?, label: String)] = []
    var dark = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let labelFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let keyFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let base = dark ? NSColor.white : NSColor.black
        let labelColor = base.withAlphaComponent(dark ? 0.62 : 0.68)
        let sep = base.withAlphaComponent(0.28)
        let chipBG = dark ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.82)
        let chipText = dark ? NSColor.black : NSColor.white
        var x: CGFloat = 0
        let midY = bounds.midY
        func text(_ s: String, _ f: NSFont, _ c: NSColor) {
            let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
            a.draw(at: NSPoint(x: x, y: midY - a.size().height / 2))
            x += a.size().width
        }
        for (i, seg) in segments.enumerated() {
            if i > 0 { x += 6; text("·", labelFont, sep); x += 6 }
            if let key = seg.key {
                let a = NSAttributedString(string: key, attributes: [.font: keyFont, .foregroundColor: chipText])
                let kw = a.size().width, chipW = kw + 11, chipH: CGFloat = 17
                let chip = NSRect(x: x, y: midY - chipH / 2, width: chipW, height: chipH)
                chipBG.setFill()
                NSBezierPath(roundedRect: chip, xRadius: 4.5, yRadius: 4.5).fill()
                a.draw(at: NSPoint(x: x + (chipW - kw) / 2, y: midY - a.size().height / 2))
                x += chipW + 5
            }
            text(seg.label, labelFont, labelColor)
        }
    }
}

/// Solid dark rounded pill — used only for the offscreen `render-overlay` preview
/// (the live panel uses a real frosted NSVisualEffectView which can't render offscreen).
final class PillView: NSView {
    var fill = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 20, yRadius: 20)
        fill.setFill()
        path.fill()
    }
}

/// Bottom-center (or wherever you place it) recording HUD: frosted dark pill with
/// a mic icon, a keycap "menu" while you hold, then live waveform + text.
final class OverlayPanel {
    static let width: CGFloat = 520
    static let height: CGFloat = 86
    private static let iconSize: CGFloat = 38
    private static var contentX: CGFloat { 18 + iconSize + 14 }
    private static var contentW: CGFloat { width - contentX - 20 }
    private static var iconFrame: NSRect { NSRect(x: 18, y: (height - iconSize) / 2, width: iconSize, height: iconSize) }
    private static var topFrame: NSRect { NSRect(x: contentX, y: 45, width: contentW, height: 24) }
    private static var waveFrame: NSRect { NSRect(x: contentX, y: 14, width: contentW, height: 26) }

    /// Where the pill appears on screen.
    var anchor: Config.OverlayPosition = .bottomCenter
    /// Light or dark frosted look.
    var scheme: Config.Appearance = .dark { didSet { applyScheme() } }

    private let panel: NSPanel
    private let vibrant = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: OverlayPanel.width, height: OverlayPanel.height))
    private let iconView = NSImageView()
    private let waveform = WaveformView(bars: 64)
    private let label = NSTextField(labelWithString: "")
    private let hint = KeycapHintView()
    private var hideTimer: Timer?

    private var textColor: NSColor {
        scheme.isDark ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.9)
    }
    private var dimColor: NSColor {
        scheme.isDark ? NSColor.white.withAlphaComponent(0.6) : NSColor.black.withAlphaComponent(0.5)
    }

    private static let menuSegments: [(key: String?, label: String)] = [
        (nil, "Speak"), ("T", "text"), ("S", "screenshot"), ("G", "search"), ("A", "AI"),
    ]

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

        vibrant.blendingMode = .behindWindow
        vibrant.state = .active
        vibrant.wantsLayer = true
        vibrant.layer?.cornerRadius = 20
        vibrant.layer?.masksToBounds = true

        iconView.frame = Self.iconFrame
        iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "GRC Whisper")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        iconView.contentTintColor = NSColor(srgbRed: 0.62, green: 0.66, blue: 1, alpha: 1)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        vibrant.addSubview(iconView)

        waveform.frame = Self.waveFrame
        vibrant.addSubview(waveform)

        label.frame = Self.topFrame
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.isHidden = true
        vibrant.addSubview(label)

        hint.frame = Self.topFrame
        hint.segments = Self.menuSegments
        vibrant.addSubview(hint)

        panel.contentView = vibrant
        applyScheme()
    }

    private func applyScheme() {
        vibrant.material = scheme.isDark ? .hudWindow : .popover
        vibrant.appearance = NSAppearance(named: scheme.isDark ? .darkAqua : .aqua)
        hint.dark = scheme.isDark
        label.textColor = textColor
    }

    /// Builds a solid-pill preview (recording/menu state) for `render-overlay`.
    static func buildContent(dark: Bool = true) -> NSView {
        let pill = PillView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        pill.fill = dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
                         : NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)
        let icon = NSImageView(frame: iconFrame)
        icon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        icon.contentTintColor = NSColor(srgbRed: 0.62, green: 0.66, blue: 1, alpha: 1)
        pill.addSubview(icon)
        let wave = WaveformView(bars: 64)
        wave.frame = waveFrame
        let samples: [CGFloat] = (0..<64).map { i in
            let env: Double = 0.5 + 0.45 * sin(Double(i) / 7) * cos(Double(i) / 3)
            let clamped = min(max(0.08, abs(env)), 1)
            return CGFloat(clamped)
        }
        wave.setSamples(samples)
        pill.addSubview(wave)
        let hint = KeycapHintView(frame: topFrame)
        hint.segments = menuSegments
        hint.dark = dark
        pill.addSubview(hint)
        return pill
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
        waveform.idle()
        waveform.barColor = NSColor(srgbRed: 0.55, green: 0.6, blue: 1, alpha: 1)
        hint.isHidden = false
        label.isHidden = true
        position()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func showPartial(_ text: String) {
        guard !text.isEmpty else { return }
        hint.isHidden = true
        label.isHidden = false
        label.textColor = textColor
        label.stringValue = text
    }

    func setLevels(_ levels: [Float]) {
        for l in levels { waveform.push(CGFloat(l)) }
    }

    func showProcessing() {
        waveform.idle()
        waveform.barColor = NSColor.white.withAlphaComponent(0.5)
        if label.isHidden {
            hint.isHidden = true
            label.isHidden = false
            label.textColor = dimColor
            label.stringValue = "…"
        }
    }

    func showResult(_ text: String) {
        hint.isHidden = true
        label.isHidden = false
        waveform.barColor = NSColor(srgbRed: 0.3, green: 0.85, blue: 0.5, alpha: 1)
        label.textColor = textColor
        label.stringValue = text
        hideAfter(1.4)
    }

    func showError(_ message: String) {
        hint.isHidden = true
        label.isHidden = false
        waveform.idle()
        waveform.barColor = NSColor(srgbRed: 0.95, green: 0.6, blue: 0.2, alpha: 1)
        label.textColor = NSColor(srgbRed: 1, green: 0.75, blue: 0.4, alpha: 1)
        label.stringValue = message
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
