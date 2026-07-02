import AppKit

/// Bottom-center recording lozenge (the "Flow Bar" equivalent).
///
/// A non-activating borderless NSPanel: it must NEVER take key/main status or the
/// focused text field — the paste target — loses focus and the dictation is lost.
final class OverlayPanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let levelBar = NSView()
    private let levelTrack = NSView()
    private var hideTimer: Timer?

    private static let width: CGFloat = 420
    private static let height: CGFloat = 44

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.92).cgColor
        content.layer?.cornerRadius = Self.height / 2

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        dot.frame = NSRect(x: 18, y: (Self.height - 12) / 2, width: 12, height: 12)
        content.addSubview(dot)

        label.frame = NSRect(x: 42, y: (Self.height - 20) / 2, width: Self.width - 60, height: 20)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        content.addSubview(label)

        levelTrack.wantsLayer = true
        levelTrack.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.15).cgColor
        levelTrack.layer?.cornerRadius = 1.5
        levelTrack.frame = NSRect(x: 42, y: 7, width: Self.width - 60, height: 3)
        content.addSubview(levelTrack)

        levelBar.wantsLayer = true
        levelBar.layer?.backgroundColor = NSColor.systemGreen.cgColor
        levelBar.layer?.cornerRadius = 1.5
        levelBar.frame = NSRect(x: 0, y: 0, width: 0, height: 3)
        levelTrack.addSubview(levelBar)

        panel.contentView = content
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - Self.width / 2, y: f.minY + 24))
    }

    func showRecording() {
        hideTimer?.invalidate()
        label.stringValue = "Listening…"
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        setLevel(0)
        position()
        panel.orderFrontRegardless()
    }

    func showPartial(_ text: String) {
        label.stringValue = text
    }

    func setLevel(_ level: Float) {
        let w = CGFloat(min(max(level, 0), 1)) * levelTrack.frame.width
        levelBar.frame.size.width = w
    }

    func showProcessing() {
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        if label.stringValue.isEmpty { label.stringValue = "Transcribing…" }
        setLevel(0)
    }

    func showResult(_ text: String) {
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        label.stringValue = text
        hideAfter(1.2)
    }

    func showError(_ message: String) {
        dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
        label.stringValue = message
        position()
        panel.orderFrontRegardless()
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
