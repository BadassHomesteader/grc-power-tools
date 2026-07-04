import AppKit

/// A live audio waveform: scrolling rounded bars driven by mic level samples.
final class WaveformView: NSView {
    private var samples: [CGFloat]
    var barColor: NSColor = NSColor(srgbRed: 0.36, green: 0.42, blue: 0.92, alpha: 1)

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

    func setSamples(_ values: [CGFloat]) {
        samples = values
        needsDisplay = true
    }

    func idle() {
        samples = Array(repeating: 0.06, count: samples.count)
        needsDisplay = true
    }

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

/// The white rounded-rect pill background, drawn (not layer-only) so it also
/// renders into an offscreen bitmap for previews.
final class PillView: NSView {
    var cornerRadius: CGFloat = 22
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1).setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Bottom-center recording card, Wispr-style: light rounded box with the text on
/// top and a full-width live waveform along the bottom. Non-activating so it
/// never takes focus from the app you're dictating into.
final class OverlayPanel {
    static let width: CGFloat = 460
    static let height: CGFloat = 90

    private let panel: NSPanel
    private let waveform = WaveformView(bars: 64)
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    private static let padX: CGFloat = 20
    private static let bottomMargin: CGFloat = 16
    private static let waveH: CGFloat = 30
    private static let gap: CGFloat = 12
    private static let textH: CGFloat = 22

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .aqua) // keep it light even in dark mode

        let content = PillView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        waveform.frame = Self.waveFrame
        content.addSubview(waveform)
        label.frame = Self.textFrame
        Self.styleLabel(label)
        content.addSubview(label)
        panel.contentView = content
    }

    private static var waveFrame: NSRect {
        NSRect(x: padX, y: bottomMargin, width: width - 2 * padX, height: waveH)
    }
    private static var textFrame: NSRect {
        NSRect(x: padX, y: bottomMargin + waveH + gap, width: width - 2 * padX, height: textH)
    }
    private static func styleLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(white: 0.1, alpha: 1)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
    }

    /// Builds the card + waveform + label at the fixed size. Used by the live
    /// panel and by the `render-overlay` preview command.
    static func buildContent() -> (PillView, WaveformView, NSTextField) {
        let content = PillView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let wave = WaveformView(bars: 64)
        wave.frame = waveFrame
        content.addSubview(wave)
        let text = NSTextField(labelWithString: "")
        text.frame = textFrame
        styleLabel(text)
        content.addSubview(text)
        return (content, wave, text)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - Self.width / 2, y: f.minY + 28))
    }

    func showRecording() {
        hideTimer?.invalidate()
        waveform.idle()
        waveform.barColor = NSColor(srgbRed: 0.36, green: 0.42, blue: 0.92, alpha: 1)
        label.textColor = NSColor(white: 0.55, alpha: 1)
        label.stringValue = "Listening…"
        position()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func showPartial(_ text: String) {
        guard !text.isEmpty else { return }
        label.textColor = NSColor(white: 0.1, alpha: 1)
        label.stringValue = text
    }

    func setLevels(_ levels: [Float]) {
        for l in levels { waveform.push(CGFloat(l)) }
    }

    func showProcessing() {
        waveform.idle()
        waveform.barColor = NSColor(white: 0.7, alpha: 1)
        if label.stringValue.isEmpty || label.stringValue == "Listening…" {
            label.textColor = NSColor(white: 0.55, alpha: 1)
            label.stringValue = "Transcribing…"
        }
    }

    func showResult(_ text: String) {
        waveform.barColor = NSColor(srgbRed: 0.2, green: 0.72, blue: 0.4, alpha: 1)
        label.textColor = NSColor(white: 0.1, alpha: 1)
        label.stringValue = text
        hideAfter(1.2)
    }

    func showError(_ message: String) {
        waveform.idle()
        waveform.barColor = NSColor(srgbRed: 0.9, green: 0.5, blue: 0.1, alpha: 1)
        label.textColor = NSColor(srgbRed: 0.75, green: 0.35, blue: 0.05, alpha: 1)
        label.stringValue = message
        position()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        hideAfter(2.5)
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
