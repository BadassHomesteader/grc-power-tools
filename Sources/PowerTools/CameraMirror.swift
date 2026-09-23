import Cocoa
import AVFoundation

/// The camera mirror: check your face before the call, without opening
/// Photo Booth or joining early to look at yourself.
///
/// The session runs ONLY while the module is on screen. The notch builds a
/// module's view when it opens and destroys it when it folds, so that lifetime
/// is exactly the green LED's lifetime — which is why this tile is `clickOnly`
/// in the module row: hovering across the launcher must never light the camera.
final class CameraSurfaceView: NSView {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.grc.whisper.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private(set) var running = false

    var mirrored: Bool {
        didSet { applyMirror() }
    }

    init(mirrored: Bool) {
        self.mirrored = mirrored
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    /// NOT flipped, unlike every other notch view: the module's superview is
    /// flipped and layer-backed, and a preview layer dropped into that
    /// inherits upside-down geometry.
    override var isFlipped: Bool { false }

    /// Clicks belong to the module view's hit rects, not to the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // CALayers do not autoresize, and they animate every frame change
        // unless told not to.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview?.frame = bounds
        CATransaction.commit()
    }

    /// Every camera the Mac can offer, including an iPhone over Continuity.
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
    }

    static var authorization: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Mirrors AudioCapture.requestMicPermission — asking is safe here only
    /// because the tile demands a deliberate click.
    static func requestPermission() async -> Bool {
        switch authorization {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start(deviceID: String) {
        guard !running else { return }
        let device = Self.devices().first { $0.uniqueID == deviceID } ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return }
        running = true

        let layer = AVCaptureVideoPreviewLayer(session: session)
        // Aspect, never aspect-fill: the content box is far wider than 16:9, so
        // filling would crop the top and bottom off — forehead and chin, in a
        // mirror whose whole job is "how do I look". The pillars either side
        // are the notch's own black, so letterboxing is invisible.
        layer.videoGravity = .resizeAspect
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        preview = layer
        applyMirror()

        // startRunning blocks for 200-500ms powering the camera up; on the main
        // thread that is a visible stall in the notch's open animation.
        queue.async { [session] in
            session.beginConfiguration()
            session.sessionPreset = .medium   // 480p is plenty for a 660pt-wide mirror
            for existing in session.inputs { session.removeInput(existing) }
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        queue.async { [session] in
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
        }
        preview?.removeFromSuperlayer()
        preview = nil
    }

    private func applyMirror() {
        guard let connection = preview?.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    deinit {
        // removeFromSuperview → viewDidMoveToWindow(nil) already stops it; this
        // is the belt to that braces, and stop() is idempotent.
        let s = session
        if s.isRunning { DispatchQueue.global(qos: .utility).async { s.stopRunning() } }
    }
}

/// The notch module around that surface: the picture, plus one strip of chrome
/// naming the camera and offering the mirror toggle.
final class CameraModuleView: NotchModuleView {
    enum State { case live, denied, noDevice, asking }

    private let surface: CameraSurfaceView
    private var deviceID: String
    private var mirrored: Bool
    private let remember: (String, Bool) -> Void
    private var state: State = .asking {
        // The surface is an opaque layer-backed subview, so the module's own
        // drawing is hidden behind it — it has to stand aside when there is no
        // picture to put there.
        didSet { surface.isHidden = (state != .live) }
    }
    private var previewOnly = false
    private var deviceName: String?
    private var deviceCount = 0
    private var mirrorRect = NSRect.zero
    private var nextRect = NSRect.zero
    private var actionRect = NSRect.zero

    /// The chrome sits UNDER the picture rather than over it: the surface is a
    /// layer-hosting view, so anything drawn in this view would be behind it.
    private static let chrome: CGFloat = 28

    init(deviceID: String, mirrored: Bool, remember: @escaping (String, Bool) -> Void) {
        self.deviceID = deviceID
        self.mirrored = mirrored
        self.remember = remember
        self.surface = CameraSurfaceView(mirrored: mirrored)
        super.init(frame: .zero)
        surface.isHidden = true      // until a feed actually exists
        addSubview(surface)
        // No ticker: the preview layer draws itself at the capture frame rate,
        // and nothing else on this panel changes on a clock.
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Test hook: is the camera actually powered right now? This is the LED's
    /// state, and the thing the module's lifetime contract is about.
    var isCapturing: Bool { surface.running }

    /// Preview/test hook: render a state's chrome with no camera at all.
    func previewState(_ s: State, deviceName: String?, deviceCount: Int = 1) {
        previewOnly = true
        state = s
        self.deviceName = deviceName
        self.deviceCount = deviceCount
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        surface.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.chrome)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !previewOnly else { return }
        if window == nil { surface.stop(); return }
        begin()
    }

    private func begin() {
        let devices = CameraSurfaceView.devices()
        deviceCount = devices.count
        guard !devices.isEmpty else { state = .noDevice; needsDisplay = true; return }
        deviceName = (devices.first { $0.uniqueID == deviceID } ?? devices.first)?.localizedName

        switch CameraSurfaceView.authorization {
        case .authorized:
            state = .live
            surface.start(deviceID: deviceID)
        case .notDetermined:
            state = .asking
            Task { @MainActor in
                let ok = await CameraSurfaceView.requestPermission()
                guard self.window != nil else { return }   // folded while we asked
                self.state = ok ? .live : .denied
                if ok { self.surface.start(deviceID: self.deviceID) }
                self.needsDisplay = true
            }
        default:
            state = .denied
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let left: CGFloat = 16
        let right = bounds.width - 16
        mirrorRect = .zero; nextRect = .zero; actionRect = .zero

        // The picture's own area, for the states where there is no picture.
        let box = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.chrome)
        func centred(_ text: String, _ attrs: [NSAttributedString.Key: Any], dy: CGFloat) -> NSRect {
            let ns = text as NSString
            let size = ns.size(withAttributes: attrs)
            let r = NSRect(x: box.midX - size.width / 2, y: box.midY + dy, width: size.width, height: size.height)
            ns.draw(at: r.origin, withAttributes: attrs)
            return r
        }

        switch state {
        case .live:
            break   // the layer is the content
        case .asking:
            _ = centred("Asking for camera access…", NotchTheme.body(13), dy: -8)
        case .noDevice:
            _ = centred("No camera found.", NotchTheme.body(13), dy: -8)
            _ = centred("Plug one in, or bring an iPhone near this Mac.", NotchTheme.small(11), dy: 14)
        case .denied:
            _ = centred("Camera access is off for Power Tools.", NotchTheme.body(13), dy: -8)
            actionRect = centred("Open Privacy & Security ▸ Camera — no relaunch needed.",
                                 NotchTheme.small(11), dy: 14).insetBy(dx: -8, dy: -4)
        }

        // Chrome: what you are looking through, and which way round it is.
        let y = bounds.height - Self.chrome + 6
        NotchTheme.faint.setFill()
        NSRect(x: left, y: bounds.height - Self.chrome, width: right - left, height: 1).fill()
        let name = (state == .live ? (deviceName ?? "Camera") : "Camera") as NSString
        name.draw(at: NSPoint(x: left, y: y + 2), withAttributes: NotchTheme.small(11))

        guard state == .live else { return }
        let mirrorText = (mirrored ? "⇄ Mirrored" : "⇄ Not mirrored") as NSString
        let mw = mirrorText.size(withAttributes: NotchTheme.small(11)).width
        mirrorRect = NSRect(x: right - mw, y: y, width: mw, height: 16)
        mirrorText.draw(at: NSPoint(x: mirrorRect.minX, y: y + 2), withAttributes: NotchTheme.small(11))
        if deviceCount > 1 {
            let next = "Next camera ▸" as NSString
            let nw = next.size(withAttributes: NotchTheme.small(11)).width
            nextRect = NSRect(x: mirrorRect.minX - 18 - nw, y: y, width: nw, height: 16)
            next.draw(at: NSPoint(x: nextRect.minX, y: y + 2), withAttributes: NotchTheme.small(11))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !mirrorRect.isEmpty, mirrorRect.insetBy(dx: -6, dy: -4).contains(p) {
            mirrored.toggle()
            surface.mirrored = mirrored
            remember(deviceID, mirrored)
            needsDisplay = true
            return
        }
        if !nextRect.isEmpty, nextRect.insetBy(dx: -6, dy: -4).contains(p) {
            // Click to cycle, the way the Weather panel switches cities — a
            // popup menu inside a non-activating panel is a fight not worth
            // having for a list of two.
            let devices = CameraSurfaceView.devices()
            guard devices.count > 1 else { return }
            let i = devices.firstIndex { $0.uniqueID == deviceID } ?? 0
            let next = devices[(i + 1) % devices.count]
            deviceID = next.uniqueID
            deviceName = next.localizedName
            remember(deviceID, mirrored)
            surface.stop()
            surface.start(deviceID: deviceID)
            needsDisplay = true
            return
        }
        if !actionRect.isEmpty, actionRect.contains(p),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}
