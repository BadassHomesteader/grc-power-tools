import Foundation
import AppKit

/// Three-finger tap on the trackpad, seen from a background app.
///
/// No public API delivers raw trackpad contacts to a process that isn't the
/// key app, so this rides Apple's PRIVATE MultitouchSupport.framework — the
/// same road MiddleClick / MiddleDrag ship on. It is loaded with dlopen at
/// runtime (no link-time dependency): if the framework or a symbol is missing
/// the detector reports `available == false` and the gesture is simply off.
///
/// Struct discipline: macOS 26 changed the stride of the per-touch record, so
/// `touches[i]` for i ≥ 1 is garbage under the classic layout. We never
/// declare the struct — only `numTouches` (framework-computed) and the FIRST
/// touch's `state` (Int32 at byte offset 20: frame@0, timestamp@8,
/// identifier@16, state@20) are read, the latter to drop hover frames.
///
/// Tap = contacts go 0 → 3 (never more) → 0 within `tapWindow`. Callbacks
/// arrive on a framework-owned thread; `onTap` / `onContactChange` fire on
/// that thread — the caller hops.
final class TrackpadTapDetector {
    typealias MTDeviceRef = UnsafeMutableRawPointer
    private typealias ContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias RegisterFn = @convention(c) (MTDeviceRef, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (MTDeviceRef, Int32) -> Void
    private typealias StopFn = @convention(c) (MTDeviceRef) -> Void
    private typealias IsRunningFn = @convention(c) (MTDeviceRef) -> Bool

    private struct Fns {
        let createList: CreateListFn
        let register: RegisterFn
        let unregister: RegisterFn
        let start: StartFn
        let stop: StopFn
        let isRunning: IsRunningFn?
    }

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// Resolved once per process; nil when the framework or a symbol is gone.
    private static let fns: Fns? = {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            log("trackpad: MultitouchSupport not loadable — three-finger tap off")
            return nil
        }
        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
        guard let create = sym("MTDeviceCreateList"),
              let reg = sym("MTRegisterContactFrameCallback"),
              let unreg = sym("MTUnregisterContactFrameCallback"),
              let start = sym("MTDeviceStart"),
              let stop = sym("MTDeviceStop") else {
            log("trackpad: MultitouchSupport symbols missing — three-finger tap off")
            return nil
        }
        let running = sym("MTDeviceIsRunning")
        return Fns(createList: unsafeBitCast(create, to: CreateListFn.self),
                   register: unsafeBitCast(reg, to: RegisterFn.self),
                   unregister: unsafeBitCast(unreg, to: RegisterFn.self),
                   start: unsafeBitCast(start, to: StartFn.self),
                   stop: unsafeBitCast(stop, to: StopFn.self),
                   isRunning: running.map { unsafeBitCast($0, to: IsRunningFn.self) })
    }()

    /// True when the private framework resolved (not whether a trackpad exists).
    var available: Bool { Self.fns != nil }

    /// Fired on the multitouch thread when a three-finger tap completes.
    var onTap: (() -> Void)?
    /// Fired on the multitouch thread on every contact-count transition
    /// (0/1/2/3/4+); diagnostics only (the CLI probe).
    var onContactChange: ((Int) -> Void)?

    /// First 3-contact frame → lift must land within this window to be a tap.
    var tapWindow: Double = 0.35
    /// Two taps closer than this collapse into one (finger-bounce guard).
    var cooldown: Double = 0.4

    private let queue = DispatchQueue(label: "grc-whisper.trackpadtap", qos: .userInteractive)
    /// The MTDevice objects (CF-bridged) — retained here for as long as they
    /// are started, released only after unregister + stop.
    private var devices: [AnyObject] = []
    private var running = false
    private var enabled = false
    private var wakeObserver: Any?
    private(set) var deviceCount = 0

    // Contact state machine — MT thread only, under `lock`. Nothing on the
    // event-tap thread ever takes this lock.
    private let lock = NSLock()
    private var threeActive = false
    private var tooMany = false
    private var threeSince: Double = 0
    private var lastFire: Double = -1
    private var lastCount: Int32 = -1

    /// Framework present + device count, without starting anything (Doctor / CLI).
    static func probe() -> (available: Bool, devices: Int) {
        guard let fns else { return (false, 0) }
        guard let arr = fns.createList()?.takeRetainedValue() else { return (true, 0) }
        return (true, CFArrayGetCount(arr))
    }

    /// Live config push (main thread). Start/stop are serialized on `queue` —
    /// MTDeviceStart/Stop must never run concurrently (they crash).
    func update(enabled: Bool) {
        queue.async { [self] in
            self.enabled = enabled
            if enabled, !running { startLocked() }
            if !enabled, running { stopLocked() }
        }
        if enabled, wakeObserver == nil {
            // A sleep/wake (or a re-paired Magic Trackpad) invalidates the
            // device list; rebuild it from scratch.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.running else { return }
                    self.stopLocked()
                    self.startLocked()
                }
            }
        }
    }

    // MARK: Device lifecycle (queue only)

    private func startLocked() {
        guard let fns = Self.fns else { return }
        guard let arr = fns.createList()?.takeRetainedValue() else {
            log("trackpad: MTDeviceCreateList returned nil — no multitouch devices")
            return
        }
        let list = (arr as NSArray) as [AnyObject]
        lock.lock()
        threeActive = false; tooMany = false; lastCount = -1
        lock.unlock()
        gDetector = self
        for obj in list {
            let ref = Unmanaged.passUnretained(obj).toOpaque()
            fns.register(ref, mtContactCallback)
            fns.start(ref, 0)
        }
        devices = list
        deviceCount = list.count
        running = true
        log("trackpad: listening on \(list.count) multitouch device(s)")
    }

    private func stopLocked() {
        guard let fns = Self.fns else { return }
        for obj in devices {
            let ref = Unmanaged.passUnretained(obj).toOpaque()
            fns.unregister(ref, mtContactCallback)
            // A device that vanished mid-session (sleep, unpair) must not be
            // stopped twice — guard on IsRunning when the symbol exists.
            if fns.isRunning?(ref) ?? true { fns.stop(ref) }
        }
        if gDetector === self { gDetector = nil }
        devices = []
        deviceCount = 0
        running = false
        log("trackpad: stopped")
    }

    // MARK: Contact frames (multitouch thread)

    fileprivate func frame(touches: UnsafeMutableRawPointer?, numTouches: Int32, timestamp: Double) {
        var count: Int32 = 0
        // Only ever dereference the buffer when the framework says it holds
        // at least one record; the first record's state filters hover frames
        // (Magic Trackpad proximity reports contacts that aren't touching).
        if numTouches > 0, let touches {
            let state = touches.loadUnaligned(fromByteOffset: 20, as: Int32.self)
            let touching = (3...5).contains(state)   // MakeTouch / Touching / BreakTouch
            count = touching ? numTouches : 0
        }

        var fire = false
        lock.lock()
        let changed = count != lastCount
        lastCount = count
        if count > 3 {
            tooMany = true
        } else if count == 3 {
            if !threeActive, !tooMany {
                threeActive = true
                threeSince = timestamp
            }
        } else if count == 0 {
            if threeActive, !tooMany,
               timestamp - threeSince <= tapWindow,
               lastFire < 0 || timestamp - lastFire >= cooldown {
                lastFire = timestamp
                fire = true
            }
            threeActive = false
            tooMany = false
        }
        lock.unlock()

        if changed { onContactChange?(Int(count)) }
        if fire { onTap?() }
    }
}

/// The C callback can't capture, so the live detector is reached through a
/// file-level pointer (set before the devices start, cleared after they stop).
nonisolated(unsafe) private var gDetector: TrackpadTapDetector?

private let mtContactCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void = {
    _, touches, numTouches, timestamp, _ in
    gDetector?.frame(touches: touches, numTouches: numTouches, timestamp: timestamp)
}
