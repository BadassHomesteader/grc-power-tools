import Cocoa

/// Find My Mouse: hold hotkey + M → EVERY screen dims (so the eye leaves the
/// monitor it was on), and a bright ring sweeps in from nearly the edge of the
/// mouse's screen, easing onto the cursor. Slow enough to follow on an
/// ultrawide or across a multi-monitor spread. Purely visual — it never steals
/// focus or blocks the mouse.
@MainActor
final class FindMouse {
    private var windows: [NSPanel] = []
    private var views: [FindMouseView] = []
    private var spotlight: FindMouseView?
    private var timer: Timer?
    private var start = Date()

    private let total = 2.3, fadeIn = 0.18, fadeOut = 0.45, convergeDur = 1.25

    func flash() {
        dismiss()
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let mouseScreen else { return }

        // One dim panel per screen; only the mouse's screen gets the spotlight.
        for screen in NSScreen.screens {
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
            v.hasSpotlight = (screen == mouseScreen)
            if v.hasSpotlight {
                // Sweep in from almost the screen edge — unmistakable even on
                // an ultrawide, and it points AT the cursor the whole way.
                v.startRadius = hypot(screen.frame.width, screen.frame.height) * 0.45
                spotlight = v
            }
            win.contentView = v
            windows.append(win)
            views.append(v)
            win.orderFrontRegardless()
        }

        start = Date()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let e = Date().timeIntervalSince(start)
        if e >= total { dismiss(); return }
        var a: CGFloat = 1
        if e < fadeIn { a = CGFloat(e / fadeIn) }
        else if e > total - fadeOut { a = CGFloat(max(0, (total - e) / fadeOut)) }

        // Ease-out converge: fast approach from the edge, gentle landing.
        let t = min(1, e / convergeDur)
        let eased = 1 - pow(1 - t, 3)

        for v in views {
            v.alpha = a
            if v.hasSpotlight {
                v.point = NSPoint(x: NSEvent.mouseLocation.x - v.screenOrigin.x,
                                  y: NSEvent.mouseLocation.y - v.screenOrigin.y)
                v.converge = CGFloat(eased)
            }
            v.needsDisplay = true
        }
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        spotlight = nil
    }
}

final class FindMouseView: NSView {
    var point: NSPoint = .zero
    var alpha: CGFloat = 1
    var converge: CGFloat = 1        // 0 = ring at startRadius, 1 = ring at the cursor
    var startRadius: CGFloat = 400
    var screenOrigin: NSPoint = .zero
    var hasSpotlight = true

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cs = CGColorSpaceCreateDeviceRGB()
        let dimA = 0.42 * alpha

        // Screens without the cursor just dim — the undimmed spotlight is the
        // only bright thing anywhere, which is what pulls the eye over.
        guard hasSpotlight else {
            ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, dimA])!)
            ctx.fill(bounds)
            return
        }

        let spotClear: CGFloat = 55, spotOuter: CGFloat = 150, ringR: CGFloat = 66

        // Spotlight: transparent at the cursor, dim outside.
        let colors = [CGColor(colorSpace: cs, components: [0, 0, 0, 0])!,
                      CGColor(colorSpace: cs, components: [0, 0, 0, 0])!,
                      CGColor(colorSpace: cs, components: [0, 0, 0, dimA])!] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, spotClear / spotOuter, 1]) {
            ctx.drawRadialGradient(grad, startCenter: point, startRadius: 0,
                                   endCenter: point, endRadius: spotOuter, options: [.drawsAfterEndLocation])
        }

        // Converging rings (main + a fainter trail behind it) sweeping in from
        // the screen edge while `converge` runs 0→1.
        if converge < 1 {
            let sweep = (1 - converge) * startRadius
            ctx.setStrokeColor(CGColor(colorSpace: cs, components: [1, 1, 1, (1 - converge) * 0.9 * alpha])!)
            ctx.setLineWidth(3)
            let cr = ringR + sweep
            ctx.strokeEllipse(in: CGRect(x: point.x - cr, y: point.y - cr, width: 2 * cr, height: 2 * cr))
            if converge < 0.85 {
                let tr = ringR + sweep * 1.35
                ctx.setStrokeColor(CGColor(colorSpace: cs, components: [1, 1, 1, (1 - converge) * 0.35 * alpha])!)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: point.x - tr, y: point.y - tr, width: 2 * tr, height: 2 * tr))
            }
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
