import Cocoa

/// Quick Capture (hold hotkey + N): a small centered input panel. Type or dictate
/// a line, press ⏎ to POST it to your configured connection (e.g. a todo app),
/// Esc to cancel. Nothing app-specific lives here — the endpoint / header / token
/// / body template are all user config (Config.capture*, CloudPolish.postCapture).
/// Mirrors the AdvancedPaste palette: a KeyableWindow plus a local key monitor so
/// Esc always works even when a borderless window's focus is flaky.
@MainActor
final class QuickCapture {
    private var window: NSWindow?
    private var keyMonitor: Any?

    func present(dark: Bool, screen: NSScreen, prefill: String = "",
                 onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        let view = QuickCaptureView(dark: dark, prefill: prefill)
        let size = view.fittingSize
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        let win = KeyableWindow(contentRect: NSRect(origin: origin, size: size),
                                styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view.frame = NSRect(origin: .zero, size: size)
        view.onSubmit = { [weak self] text in self?.dismiss(); onSubmit(text) }
        view.onCancel = { [weak self] in self?.dismiss(); onCancel() }
        win.contentView = view
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view.field)

        // Esc typed into the field's editor doesn't reliably bubble to us; a local
        // monitor guarantees Esc cancels (same safeguard as AdvancedPaste).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
            guard let self, self.window != nil, let view else { return event }
            if event.keyCode == 53 { view.onCancel?(); return nil }  // esc
            return event
        }
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
    }
}

final class QuickCaptureView: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let dark: Bool

    private static let width: CGFloat = 460
    private static let height: CGFloat = 118

    init(dark: Bool, prefill: String) {
        self.dark = dark
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        setup(prefill: prefill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }

    private func setup(prefill: String) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = "Add a task…"
        field.stringValue = prefill
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.target = self
        field.action = #selector(submit)  // NSTextField fires its action on Return
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            field.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).setClip()
        bg.setFill(); bounds.fill()
        ("Quick Capture" as NSString).draw(at: NSPoint(x: 20, y: 15),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: fg])
        ("↵ to send  ·  esc to cancel" as NSString).draw(at: NSPoint(x: 20, y: Self.height - 25),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim])
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { onCancel?(); return }
        onSubmit?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }  // esc
        return false
    }
}
