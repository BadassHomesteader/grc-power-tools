import Cocoa

/// hold + K → the screen color picker (eyedropper). Presents macOS's own
/// magnifier loupe; on pick we show a small palette (like Advanced Paste) of the
/// sampled color in every common format — HEX, RGB, HSL, HSV, CMYK — and the one
/// you choose is copied to the clipboard. Built on `NSColorSampler`, so the loupe,
/// multi-display handling, and pixel sampling come from the system — no
/// screen-recording grant of our own is required.
@MainActor
enum ColorPicker {
    /// Show the loupe. `completion` fires with the sampled color, or nil if the
    /// user cancelled (Esc / click away). Called on the main thread.
    static func pick(_ completion: @escaping (ColorValue?) -> Void) {
        NSColorSampler().show { color in
            // sRGB conversion is what makes the values match what design tools
            // show; a raw device/display-P3 color would read a few points off.
            guard let color, let srgb = color.usingColorSpace(.sRGB) else {
                completion(nil); return
            }
            let r = Int((srgb.redComponent * 255).rounded())
            let g = Int((srgb.greenComponent * 255).rounded())
            let b = Int((srgb.blueComponent * 255).rounded())
            completion(ColorValue(r: r, g: g, b: b))
        }
    }
}

/// One row in the format palette: a label and the copyable string.
struct ColorFormat {
    let name: String    // "HEX", "RGB", …
    let value: String   // "#3366CC", "rgb(51, 102, 204)", …
}

/// An 8-bit sRGB color and its representations in the formats designers/devs use.
struct ColorValue {
    let r: Int, g: Int, b: Int   // 0–255

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// The palette rows, in order (HEX first — the most-used default).
    var formats: [ColorFormat] {
        let (h, s, l) = hsl
        let (_, sv, v) = hsv
        let (c, m, y, k) = cmyk
        return [
            ColorFormat(name: "HEX",        value: hex),
            ColorFormat(name: "RGB",        value: "rgb(\(r), \(g), \(b))"),
            ColorFormat(name: "HSL",        value: "hsl(\(h), \(s)%, \(l)%)"),
            ColorFormat(name: "HSV",        value: "hsv(\(h), \(sv)%, \(v)%)"),
            ColorFormat(name: "CMYK",       value: "cmyk(\(c)%, \(m)%, \(y)%, \(k)%)"),
            ColorFormat(name: "HEX (bare)", value: String(format: "%02X%02X%02X", r, g, b)),
            ColorFormat(name: "Values",     value: "\(r), \(g), \(b)"),
            ColorFormat(name: "Float",      value: floatTriple),
        ]
    }

    // MARK: conversions (all from normalized 0–1 channels)

    private var norm: (Double, Double, Double) { (Double(r) / 255, Double(g) / 255, Double(b) / 255) }

    /// 0–360 hue, 0–100 saturation, 0–100 lightness (rounded ints).
    private var hsl: (Int, Int, Int) {
        let (rf, gf, bf) = norm
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf), d = mx - mn
        let l = (mx + mn) / 2
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        return (hue(rf, gf, bf, mx, d), Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    /// 0–360 hue, 0–100 saturation, 0–100 value (rounded ints).
    private var hsv: (Int, Int, Int) {
        let (rf, gf, bf) = norm
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf), d = mx - mn
        let s = mx == 0 ? 0 : d / mx
        return (hue(rf, gf, bf, mx, d), Int((s * 100).rounded()), Int((mx * 100).rounded()))
    }

    /// 0–100 cyan, magenta, yellow, key (rounded ints).
    private var cmyk: (Int, Int, Int, Int) {
        let (rf, gf, bf) = norm
        let k = 1 - max(rf, gf, bf)
        guard k < 1 else { return (0, 0, 0, 100) }   // pure black — avoid /0
        let c = (1 - rf - k) / (1 - k)
        let m = (1 - gf - k) / (1 - k)
        let y = (1 - bf - k) / (1 - k)
        return (Int((c * 100).rounded()), Int((m * 100).rounded()), Int((y * 100).rounded()), Int((k * 100).rounded()))
    }

    /// "0.200, 0.400, 0.800" — 0–1 channels for shader/SwiftUI code.
    private var floatTriple: String {
        let (rf, gf, bf) = norm
        return String(format: "%.3f, %.3f, %.3f", rf, gf, bf)
    }

    private func hue(_ rf: Double, _ gf: Double, _ bf: Double, _ mx: Double, _ d: Double) -> Int {
        guard d != 0 else { return 0 }
        var h: Double
        if mx == rf { h = ((gf - bf) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == gf { h = (bf - rf) / d + 2 }
        else { h = (rf - gf) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return Int(h.rounded())
    }
}

/// The pick-a-format palette shown after the loupe returns a color. Mirrors the
/// Advanced Paste palette: digits / arrows+Return / click choose; Esc cancels.
@MainActor
final class ColorFormatPalette {
    private var window: NSWindow?
    private var keyMonitor: Any?

    func present(color: ColorValue, dark: Bool, screen: NSScreen,
                 onPick: @escaping (ColorFormat) -> Void, onCancel: @escaping () -> Void) {
        dismiss()
        let view = ColorFormatPaletteView(color: color, dark: dark)
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
        view.onPick = { [weak self] f in self?.dismiss(); onPick(f) }
        view.onCancel = { [weak self] in self?.dismiss(); onCancel() }
        win.contentView = view
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        win.makeFirstResponder(view)

        // A borderless window doesn't always hold key focus, so a local monitor
        // catches Esc / digits / arrows regardless.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
            guard let self, self.window != nil, let view else { return event }
            return view.handleKey(event) ? nil : event
        }
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
    }
}

final class ColorFormatPaletteView: NSView {
    private let color: ColorValue
    private let dark: Bool
    var onPick: ((ColorFormat) -> Void)?
    var onCancel: (() -> Void)?

    private var highlighted = 0
    private let rows: [ColorFormat]
    private static let width: CGFloat = 380
    private static let rowH: CGFloat = 44
    private static let headerH: CGFloat = 64
    private static let footerH: CGFloat = 30

    init(color: ColorValue, dark: Bool) {
        self.color = color
        self.dark = dark
        self.rows = color.formats
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: Self.headerH + CGFloat(rows.count) * Self.rowH + Self.footerH)
    }

    private var bg: NSColor { dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.99, green: 0.99, blue: 1, alpha: 1) }
    private var fg: NSColor { dark ? .white : .black }
    private var dim: NSColor { (dark ? NSColor.white : .black).withAlphaComponent(0.5) }
    private var accent: NSColor { NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1) }
    private var monoFont: NSFont { NSFont.monospacedSystemFont(ofSize: 13, weight: .medium) }

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 8, y: Self.headerH + CGFloat(i) * Self.rowH, width: bounds.width - 16, height: Self.rowH - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).setClip()
        bg.setFill(); bounds.fill()

        // Header: a swatch of the picked color + title + its hex.
        let swatch = NSRect(x: 20, y: 16, width: 34, height: 34)
        color.nsColor.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 8, yRadius: 8).fill()
        (dark ? NSColor.white : .black).withAlphaComponent(0.18).setStroke()
        let ring = NSBezierPath(roundedRect: swatch, xRadius: 8, yRadius: 8); ring.lineWidth = 1; ring.stroke()
        ("Copy color as…" as NSString).draw(at: NSPoint(x: 66, y: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: fg])
        (color.hex as NSString).draw(at: NSPoint(x: 66, y: 38),
            withAttributes: [.font: monoFont, .foregroundColor: dim])

        for (i, f) in rows.enumerated() {
            let r = rowRect(i)
            let onAccent = (i == highlighted)
            if onAccent {
                accent.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
            }
            let nameColor = onAccent ? NSColor.white : dim
            let valueColor = onAccent ? NSColor.white : fg
            // digit badge
            let badge = NSRect(x: r.minX + 10, y: r.midY - 11, width: 22, height: 22)
            (onAccent ? NSColor.white.withAlphaComponent(0.25) : (dark ? NSColor.white : .black).withAlphaComponent(0.1)).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            ("\(i + 1)" as NSString).draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 3),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: onAccent ? NSColor.white : fg])
            // format name (small) + the copyable value (monospaced, prominent)
            (f.name as NSString).draw(at: NSPoint(x: r.minX + 44, y: r.minY + 5),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: nameColor])
            (f.value as NSString).draw(at: NSPoint(x: r.minX + 44, y: r.minY + 19),
                withAttributes: [.font: monoFont, .foregroundColor: valueColor])
        }

        let footer = "1–\(rows.count) or click  ·  ↑↓ ↵  ·  esc" as NSString
        footer.draw(at: NSPoint(x: 20, y: bounds.height - 22),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim])
    }

    override func mouseMoved(with event: NSEvent) { updateHighlight(convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rows.indices.first(where: { rowRect($0).contains(p) }) { onPick?(rows[i]) }
        else { onCancel?() }
    }
    private func updateHighlight(_ p: NSPoint) {
        if let i = rows.indices.first(where: { rowRect($0).contains(p) }), i != highlighted { highlighted = i; needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) { if !handleKey(event) { super.keyDown(with: event) } }

    /// Returns true if the key was consumed. Called from keyDown AND the local
    /// event monitor (so Esc works even if this view isn't first responder).
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: onCancel?(); return true                                       // esc
        case 36, 76: onPick?(rows[highlighted]); return true                    // return / enter
        case 125: highlighted = min(highlighted + 1, rows.count - 1); needsDisplay = true; return true  // down
        case 126: highlighted = max(highlighted - 1, 0); needsDisplay = true; return true               // up
        default:
            if let ch = event.charactersIgnoringModifiers, let n = Int(ch), n >= 1, n <= rows.count {
                onPick?(rows[n - 1]); return true
            }
            return false
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}
