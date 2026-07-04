import AppKit

/// A live audio waveform: scrolling rounded bars driven by mic level samples.
final class WaveformView: NSView {
    private var samples: [CGFloat]
    var barColor: NSColor = NSColor(srgbRed: 0.36, green: 0.42, blue: 0.92, alpha: 1)

    init(bars: Int = 42) {
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

/// The white rounded pill background, drawn (not layer-only) so it also renders
/// into an offscreen bitmap for previews.
final class PillView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1).setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.08).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Bottom-center recording lozenge, Wispr-style: light pill + live waveform +
/// text. Non-activating so it never takes focus from the app you're dictating into.
final class OverlayPanel {
    static let width: CGFloat = 480
    static let height: CGFloat = 46

    private let panel: NSPanel
    private let waveform = WaveformView()
    private let label = NSTextField(labelWithString: "")
    private var hideTimer: Timer?

    private static let padding: CGFloat = 18
    private static let waveWidth: CGFloat = 96

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
        waveform.frame = NSRect(x: Self.padding, y: (Self.height - 22) / 2, width: Self.waveWidth, height: 22)
        content.addSubview(waveform)
        label.frame = NSRect(x: Self.padding + Self.waveWidth + 12, y: (Self.height - 20) / 2,
                             width: Self.width - (Self.padding * 2) - Self.waveWidth - 12, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(white: 0.1, alpha: 1)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        content.addSubview(label)
        panel.contentView = content
    }

    /// Builds the pill + waveform + label at the fixed size. Used by the live
    /// panel and by the `render-overlay` preview command.
    static func buildContent() -> (PillView, WaveformView, NSTextField) {
        let content = PillView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let wave = WaveformView()
        wave.frame = NSRect(x: padding, y: (height - 22) / 2, width: waveWidth, height: 22)
        content.addSubview(wave)
        let text = NSTextField(labelWithString: "")
        text.frame = NSRect(x: padding + waveWidth + 12, y: (height - 20) / 2,
                            width: width - (padding * 2) - waveWidth - 12, height: 20)
        text.font = .systemFont(ofSize: 14, weight: .medium)
        text.textColor = NSColor(white: 0.1, alpha: 1)
        text.lineBreakMode = .byTruncatingHead
        text.maximumNumberOfLines = 1
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

    func setLevel(_ level: Float) {
        waveform.push(CGFloat(level))
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
