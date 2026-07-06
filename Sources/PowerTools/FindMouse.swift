import Cocoa

/// Find My Mouse: hold hotkey + M → a spotlight dims the screen and a bright ring
/// converges on the cursor, then fades. Faster and more deliberate than the native
/// shake-to-locate. Purely visual — it never steals focus or blocks the mouse.
@MainActor
final class FindMouse {
    private var window: NSPanel?
    private var view: FindMouseView?
    private var timer: Timer?
    private var start = Date()

    private let total = 1.1, fadeIn = 0.14, fadeOut = 0.32

    func flash() {
        dismiss()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }

        let win = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false
        win.ignoresMouseEvents = true       // never blocks clicks
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let v = FindMouseView()
        v.frame = NSRect(origin: .zero, size: screen.frame.size)
        v.screenOrigin = screen.frame.origin
        win.contentView = v
        window = win
        view = v
        win.orderFrontRegardless()

        start = Date()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard let view else { return }
        let e = Date().timeIntervalSince(start)
        if e >= total { dismiss(); return }
        var a: CGFloat = 1
        if e < fadeIn { a = CGFloat(e / fadeIn) }
        else if e > total - fadeOut { a = CGFloat(max(0, (total - e) / fadeOut)) }
        view.point = NSPoint(x: NSEvent.mouseLocation.x - view.screenOrigin.x,
                             y: NSEvent.mouseLocation.y - view.screenOrigin.y)
        view.alpha = a
        view.converge = CGFloat(min(1, e / fadeIn))   // 0→1 during fade-in
        view.needsDisplay = true
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window = nil; view = nil
    }
}

final class FindMouseView: NSView {
    var point: NSPoint = .zero
    var alpha: CGFloat = 1
    var converge: CGFloat = 1        // 0 = ring far out, 1 = ring at the cursor
    var screenOrigin: NSPoint = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let spotClear: CGFloat = 55, spotOuter: CGFloat = 150, ringR: CGFloat = 66
        let cs = CGColorSpaceCreateDeviceRGB()

        // Spotlight: transparent at the cursor, dim outside.
        let dimA = 0.42 * alpha
        let colors = [CGColor(colorSpace: cs, components: [0, 0, 0, 0])!,
                      CGColor(colorSpace: cs, components: [0, 0, 0, 0])!,
                      CGColor(colorSpace: cs, components: [0, 0, 0, dimA])!] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, spotClear / spotOuter, 1]) {
            ctx.drawRadialGradient(grad, startCenter: point, startRadius: 0,
                                   endCenter: point, endRadius: spotOuter, options: [.drawsAfterEndLocation])
        }

        // Converging ring during fade-in (starts ~120px out, lands on the cursor).
        if converge < 1 {
            let cr = ringR + (1 - converge) * 130
            ctx.setStrokeColor(CGColor(colorSpace: cs, components: [1, 1, 1, (1 - converge) * alpha])!)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: point.x - cr, y: point.y - cr, width: 2 * cr, height: 2 * cr))
        }

        // Bright ring at the cursor + indigo halo.
        ctx.setStrokeColor(CGColor(colorSpace: cs, components: [1, 1, 1, 0.95 * alpha])!)
        ctx.setLineWidth(3.5)
        ctx.strokeEllipse(in: CGRect(x: point.x - ringR, y: point.y - ringR, width: 2 * ringR, height: 2 * ringR))
        ctx.setStrokeColor(CGColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 0.85 * alpha))
        ctx.setLineWidth(2)
        let r2 = ringR + 9
        ctx.strokeEllipse(in: CGRect(x: point.x - r2, y: point.y - r2, width: 2 * r2, height: 2 * r2))
    }
}
