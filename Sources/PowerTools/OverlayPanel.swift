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

/// A tiny screen with the snap target highlighted — shown while organizing windows.
final class WindowDiagramView: NSView {
    var region = CGRect(x: 0, y: 0, width: 0.5, height: 1)  // normalized, top-left origin
    var stroke: NSColor = .black
    var fill = NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 2, dy: 2)
        let outline = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        stroke.withAlphaComponent(0.45).setStroke()
        outline.lineWidth = 1.5
        outline.stroke()
        let r = NSRect(x: box.minX + region.minX * box.width,
                       y: box.minY + region.minY * box.height,
                       width: region.width * box.width,
                       height: region.height * box.height).insetBy(dx: 1.5, dy: 1.5)
        fill.setFill()
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
    }
}

/// The dictation HUD: a flat white/black pill (Claude-Desktop style) with a mic on
/// the left, a live waveform in the middle, and "release to stop" on the right.
/// Result/error text replaces the waveform briefly; window-organizer mode swaps in
/// a mini screen diagram. Then it hides.
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
    private static var diagramFrame: NSRect { NSRect(x: 18, y: (height - 30) / 2, width: 46, height: 30) }
    private static var winLabelFrame: NSRect {
        let x: CGFloat = 18 + 46 + 14
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
    private let windowDiagram = WindowDiagramView()
    private let windowLabel = NSTextField(labelWithString: "")
    private let hintStrip = NSTextField(wrappingLabelWithString: "")
    private var hideTimer: Timer?
    /// While recording, we show the leader-key hints until the user actually speaks,
    /// then swap in the waveform.
    private var awaitingSpeech = false
    private static let speechThreshold: Float = 0.22
    private static let hintsText = "A ai · T text · S shot · G lens · K color · H clips · D doc\nC X V files · P paste · W ← → ↑ ↓ windows"

    private enum Mode { case waveform, text, window }

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
        iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Power Tools")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        pill.addSubview(iconView)

        waveform.frame = Self.waveFrame
        pill.addSubview(waveform)

        // Sits where the waveform is; shown while holding, before you speak.
        hintStrip.frame = NSRect(x: Self.waveFrame.minX, y: (Self.height - 34) / 2, width: Self.waveFrame.width, height: 34)
        hintStrip.font = .systemFont(ofSize: 11.5, weight: .medium)
        hintStrip.alignment = .left
        hintStrip.maximumNumberOfLines = 2
        hintStrip.lineBreakMode = .byWordWrapping
        hintStrip.stringValue = Self.hintsText
        hintStrip.isHidden = true
        pill.addSubview(hintStrip)

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

        windowDiagram.frame = Self.diagramFrame
        windowDiagram.isHidden = true
        pill.addSubview(windowDiagram)

        windowLabel.frame = Self.winLabelFrame
        windowLabel.font = .systemFont(ofSize: 14, weight: .medium)
        windowLabel.isHidden = true
        pill.addSubview(windowLabel)

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
        hintStrip.textColor = hintColor
        windowDiagram.stroke = fg
        windowDiagram.needsDisplay = true
        if !textLabel.isHidden { textLabel.textColor = fg }
        if !windowLabel.isHidden { windowLabel.textColor = fg }
    }

    /// Builds a static preview pill for `render-overlay`. `speaking:false` shows the
    /// armed hint state; `speaking:true` shows the live waveform.
    static func buildContent(dark: Bool = false, speaking: Bool = false) -> NSView {
        let panel = OverlayPanel()
        panel.scheme = dark ? .dark : .light
        panel.waveform.setSamples((0..<90).map { i in
            let env: Double = 0.45 + 0.4 * sin(Double(i) / 6) * cos(Double(i) / 3.5)
            return CGFloat(min(max(0.12, abs(env)), 1))
        })
        panel.setMode(.waveform)
        panel.hintLabel.stringValue = "release to stop"
        if !speaking {
            panel.waveform.isHidden = true
            panel.hintStrip.isHidden = false
        }
        return panel.pill
    }

    /// Static preview of the green Quick Capture success toast for design checks.
    static func buildSuccessContent(dark: Bool, text: String) -> NSView {
        let panel = OverlayPanel()
        panel.scheme = dark ? .dark : .light
        panel.setMode(.text)
        panel.pill.fill = NSColor(srgbRed: 0.18, green: 0.64, blue: 0.33, alpha: 1)
        panel.pill.stroke = nil
        panel.iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Captured")
        panel.iconView.contentTintColor = .white
        panel.textLabel.textColor = .white
        panel.textLabel.stringValue = text
        return panel.pill
    }

    /// Static preview of the window-organizer state for `render-window`.
    static func buildWindowContent(dark: Bool, region: CGRect, label: String) -> NSView {
        let panel = OverlayPanel()
        panel.scheme = dark ? .dark : .light
        panel.windowDiagram.region = region
        panel.windowLabel.stringValue = label
        panel.windowLabel.textColor = panel.fg
        panel.setMode(.window)
        return panel.pill
    }

    private func setMode(_ mode: Mode) {
        restoreDefaultChrome()   // clear any prior green success chrome
        iconView.isHidden = (mode == .window)
        waveform.isHidden = (mode != .waveform)
        hintLabel.isHidden = (mode != .waveform)
        textLabel.isHidden = (mode != .text)
        windowDiagram.isHidden = (mode != .window)
        windowLabel.isHidden = (mode != .window)
        hintStrip.isHidden = true          // shown explicitly by showRecording()
        awaitingSpeech = false
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
        setMode(.waveform)
        // Start with the hints; the first real speech swaps in the waveform.
        waveform.isHidden = true
        hintStrip.isHidden = false
        awaitingSpeech = true
        present()
    }

    /// The clean HUD shows only the waveform while you speak (no inline transcript).
    func showPartial(_ text: String) {}

    func setLevels(_ levels: [Float]) {
        for l in levels { waveform.push(CGFloat(l)) }
        if awaitingSpeech && levels.contains(where: { $0 > Self.speechThreshold }) {
            awaitingSpeech = false
            hintStrip.isHidden = true
            waveform.isHidden = false
        }
    }

    func showProcessing() {
        hintLabel.stringValue = "…"
        setMode(.waveform)
        present()
    }

    func showResult(_ text: String) {
        hideTimer?.invalidate()
        setMode(.text)
        textLabel.textColor = fg
        textLabel.stringValue = text
        present()
        hideAfter(1.4)
    }

    /// Bright-green confirmation so a successful Quick Capture is unmistakable:
    /// green pill, white checkmark, white text. setMode() restored the default
    /// chrome first, so the next (non-success) toast returns to the themed look.
    func showSuccess(_ text: String) {
        hideTimer?.invalidate()
        setMode(.text)
        pill.fill = NSColor(srgbRed: 0.18, green: 0.64, blue: 0.33, alpha: 1)
        pill.stroke = nil
        pill.needsDisplay = true
        iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Captured")
        iconView.contentTintColor = .white
        textLabel.textColor = .white
        textLabel.stringValue = text
        present()
        hideAfter(1.8)
    }

    /// Reset the pill to the themed default (undoes showSuccess's green). Called at
    /// the top of setMode so every subsequent toast starts from a clean look.
    private func restoreDefaultChrome() {
        pill.fill = pillFill
        pill.stroke = pillStroke
        pill.needsDisplay = true
        iconView.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Power Tools")
        iconView.contentTintColor = fg
    }

    /// Window-organizer state: a mini screen diagram + label (e.g. "Left ⅓"). Stays
    /// up while you hold (a long fallback hides it if the release event is missed).
    func showWindow(region: CGRect, label: String) {
        hideTimer?.invalidate()
        windowDiagram.region = region
        windowDiagram.needsDisplay = true
        windowLabel.textColor = fg
        windowLabel.stringValue = label
        setMode(.window)
        present()
        hideAfter(2.5)
    }

    /// Place and order the panel front (result/processing can be shown without a
    /// preceding showRecording(), e.g. file-op and OCR toasts).
    private func present() {
        position()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func showError(_ message: String) {
        setMode(.text)
        textLabel.textColor = NSColor(srgbRed: 0.85, green: 0.35, blue: 0.15, alpha: 1)
        textLabel.stringValue = message
        present()
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
