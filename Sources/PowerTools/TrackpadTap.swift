import Foundation
import AppKit

/// Multi-finger taps on the trackpad, seen from a background app.
///
/// No public API delivers raw trackpad contacts to a process that isn't the
/// key app, so this rides Apple's PRIVATE MultitouchSupport.framework — the
/// same road MiddleClick / MiddleDrag ship on. It is loaded with dlopen at
/// runtime (no link-time dependency): if the framework or a symbol is missing
/// the detector reports `available == false` and the gesture is simply off.
///
/// Struct discipline: the per-record layout we rely on is the classic MTTouch
/// head — frame Int32 @0, timestamp Double @8, identifier Int32 @16, state
/// Int32 @20, normalized position Float @32/36, normalized velocity Float
/// @40/44. macOS 26 changed the STRIDE between records, so `touches[i]` for
/// i ≥ 1 is garbage under the classic 96-byte stride. Rather than assume a
/// stride, it is DETECTED: every record carries its frame's timestamp, so on a
/// frame with two or more records the candidate stride whose second record
/// repeats the callback's timestamp (and holds a legal state) is the real one.
/// Until a stride is confirmed — or if none ever is — only record 0 is read and
/// it speaks for the whole frame (the original behaviour).
///
/// Tap = the touching count reaches an accepted value and all contacts lift
/// within the window for that finger count. Callbacks arrive on a framework-
/// owned thread; `onTap` / `onContactChange` fire on that thread — the caller
/// hops. Every gesture that reached the smallest accepted count is logged with
/// its outcome and, when dropped, the reason — that line is the first thing to
/// read when "the tap didn't work".
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
            log("trackpad: MultitouchSupport not loadable — finger taps off")
            return nil
        }
        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
        guard let create = sym("MTDeviceCreateList"),
              let reg = sym("MTRegisterContactFrameCallback"),
              let unreg = sym("MTUnregisterContactFrameCallback"),
              let start = sym("MTDeviceStart"),
              let stop = sym("MTDeviceStop") else {
            log("trackpad: MultitouchSupport symbols missing — finger taps off")
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

    /// What a completed tap looked like. `fingers` is the PEAK touching count
    /// (four fingers land through three, so the high-water mark is the
    /// gesture); `travel` is how far any contact moved from where it landed,
    /// in normalized pad units (1 = the pad's width/height) — a tap stays near
    /// zero, a swipe or a spread does not; `peakSpeed` is the fastest
    /// normalized velocity seen, reported for the log only.
    struct Gesture {
        let fingers: Int
        let duration: Double
        let travel: Float
        let peakSpeed: Float
    }

    /// Fired on the multitouch thread when a tap completes. The detector
    /// reports, it does not judge: a HELD gesture is already qualified by its
    /// hotkey; only the bare gesture has to earn it, and that threshold lives
    /// with the caller.
    var onTap: ((Gesture) -> Void)?
    /// Fired on the multitouch thread on every touching-count transition;
    /// diagnostics only (the CLI probe).
    var onContactChange: ((Int) -> Void)?
    /// Every frame the framework delivers, BEFORE any filtering: raw
    /// `numTouches` and the first record's `state` (-1 when the frame carried
    /// no records). Diagnostics only — it is how we tell "the framework never
    /// reported five contacts" apart from "we filtered them out".
    var onRawFrame: ((Int32, Int32) -> Void)?

    /// First accepted-count frame → lift must land within this window to be a
    /// tap, for three fingers. Each finger beyond three adds `windowPerFinger`:
    /// more fingers land and lift more staggered, so the same hand takes
    /// longer to make the same tap.
    var tapWindow: Double = 0.35
    var windowPerFinger: Double = 0.1
    /// Two taps closer than this collapse into one (finger-bounce guard).
    var cooldown: Double = 0.4
    func window(forFingers n: Int32) -> Double { tapWindow + windowPerFinger * Double(max(0, Int(n) - 3)) }

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
    private var tapActive = false
    private var tooMany = false
    private var tapSince: Double = 0
    private var lastFire: Double = -1
    private var lastCount: Int32 = -1
    /// Which finger counts count as a tap. More than one is the point: a
    /// three-finger tap and a four-finger tap are separate gestures.
    /// Set from the main thread, read on the MT thread — both under `lock`.
    private var tapCounts: Set<Int32> = [3]
    /// The most fingers seen during the current tap; a four-finger tap passes
    /// through three on the way down, so the PEAK is what identifies it.
    private var tapPeak: Int32 = 0
    /// The most contacts the frame ever reported this gesture, accepted or
    /// not — so a dropped gesture can say "6 contacts" in the log.
    private var gesturePeak: Int32 = 0
    /// Fastest the contacts moved during the current gesture.
    private var tapPeakSpeed: Float = 0
    /// Farthest any contact strayed from where it landed this gesture.
    private var tapTravel: Float = 0
    /// Where each contact (by identifier) first touched this gesture.
    private var landing: [Int32: (Float, Float)] = [:]
    func setTapFingers(_ n: Int) { setTapCounts([n]) }
    func setTapCounts(_ counts: Set<Int>) {
        lock.lock()
        tapCounts = Set(counts.map { Int32(max(2, min(5, $0))) })
        if tapCounts.isEmpty { tapCounts = [3] }
        lock.unlock()
    }

    // MARK: Record stride (MT thread only)

    /// Bytes between consecutive contact records once known; 0 = unknown.
    private(set) var stride = 0
    private var strideGuess = 0
    private var strideFramesTried = 0
    private var strideGaveUp = false
    /// Classic MTTouch is 96 bytes; the rest cover a field added or dropped.
    private static let strideCandidates = [72, 80, 88, 96, 100, 104, 108, 112, 116, 120, 124, 128, 136, 144, 152, 160]
    /// How many multi-record frames to try before settling for record 0 only.
    private static let strideAttempts = 300

    private static func looksLikeRecord(_ base: UnsafeMutableRawPointer, at off: Int, timestamp: Double) -> Bool {
        let t = base.loadUnaligned(fromByteOffset: off + 8, as: Double.self)
        let s = base.loadUnaligned(fromByteOffset: off + 20, as: Int32.self)
        return t == timestamp && (0...7).contains(s)
    }

    private func resolveStride(_ base: UnsafeMutableRawPointer, numTouches: Int32, timestamp: Double) -> Int {
        if stride > 0 {
            // Keep the lock honest: if the second record ever stops carrying
            // the frame's timestamp, the stride is wrong — forget it.
            if numTouches >= 2, !Self.looksLikeRecord(base, at: stride, timestamp: timestamp) {
                log("trackpad: record stride \(stride) stopped validating — back to first-record-only reads")
                stride = 0; strideGuess = 0; strideFramesTried = 0
                return 0
            }
            return stride
        }
        guard !strideGaveUp, numTouches >= 2 else { return 0 }
        strideFramesTried += 1
        // Record 0 must itself carry the frame's timestamp, or the layout
        // assumption behind every offset here is already wrong.
        var found = 0
        if Self.looksLikeRecord(base, at: 0, timestamp: timestamp) {
            // Stay inside the smallest buffer this many records could occupy.
            let limit = Int(numTouches) * Self.strideCandidates[0] - 24
            for s in Self.strideCandidates where s <= limit {
                if Self.looksLikeRecord(base, at: s, timestamp: timestamp) { found = s; break }
            }
        }
        if found > 0 {
            if found == strideGuess {
                stride = found
                let layout = found == 96 ? "classic layout" : "not the classic 96"
                log("trackpad: contact record stride detected: \(found) bytes (\(layout)) — counting every touching contact")
            } else {
                strideGuess = found   // confirm on a second frame before trusting it
            }
        } else if strideFramesTried >= Self.strideAttempts {
            strideGaveUp = true
            log("trackpad: record stride not detected in \(strideFramesTried) multi-contact frames — first-record-only reads")
        }
        return stride
    }

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
        tapActive = false; tooMany = false; lastCount = -1; lastFire = -1
        tapPeak = 0; gesturePeak = 0; tapPeakSpeed = 0; tapTravel = 0
        landing.removeAll()
        stride = 0; strideGuess = 0; strideFramesTried = 0; strideGaveUp = false
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

    private struct Contact {
        let id: Int32
        let state: Int32
        let x: Float, y: Float
        let vx: Float, vy: Float
        var touching: Bool { (3...5).contains(state) }   // MakeTouch / Touching / BreakTouch
    }

    private static func read(_ base: UnsafeMutableRawPointer, at off: Int) -> Contact {
        Contact(id: base.loadUnaligned(fromByteOffset: off + 16, as: Int32.self),
                state: base.loadUnaligned(fromByteOffset: off + 20, as: Int32.self),
                x: base.loadUnaligned(fromByteOffset: off + 32, as: Float.self),
                y: base.loadUnaligned(fromByteOffset: off + 36, as: Float.self),
                vx: base.loadUnaligned(fromByteOffset: off + 40, as: Float.self),
                vy: base.loadUnaligned(fromByteOffset: off + 44, as: Float.self))
    }

    fileprivate func frame(touches: UnsafeMutableRawPointer?, numTouches: Int32, timestamp: Double) {
        var contacts: [Contact] = []
        var rawState: Int32 = -1
        var strideNow = 0
        // One lock for the whole frame: it serialises with the config push
        // (setTapCounts) and the device restart (startLocked resets every
        // field read or written below) — both rare, both on other threads.
        // The callbacks fire after it is released.
        lock.lock()
        // Only ever dereference the buffer when the framework says it holds
        // at least one record.
        if numTouches > 0, let touches {
            strideNow = resolveStride(touches, numTouches: numTouches, timestamp: timestamp)
            // With the stride known every record is read; without it only the
            // first — the only one whose offsets are certain.
            let n = strideNow > 0 ? Int(numTouches) : 1
            contacts.reserveCapacity(n)
            for i in 0..<n { contacts.append(Self.read(touches, at: i * strideNow)) }
            rawState = contacts[0].state
        }

        // The touching count. Per record when the stride is known; otherwise
        // record 0 speaks for the frame (hover frames — Magic Trackpad
        // proximity, a thumb in range — read as nothing touching).
        let touching = contacts.filter { $0.touching }
        let count: Int32 = strideNow > 0 ? Int32(touching.count) : (touching.isEmpty ? 0 : numTouches)
        // Motion. Velocity only in the settled Touching state — MakeTouch and
        // BreakTouch frames carry a landing spike that is not motion across
        // the pad. Travel is measured from where each contact landed, which a
        // spike cannot fake.
        var speed: Float = 0
        var moved: Float = 0
        for c in touching {
            if c.state == 4 { speed = max(speed, (c.vx * c.vx + c.vy * c.vy).squareRoot()) }
            if let origin = landing[c.id] {
                let dx = c.x - origin.0, dy = c.y - origin.1
                moved = max(moved, (dx * dx + dy * dy).squareRoot())
            } else {
                landing[c.id] = (c.x, c.y)
            }
        }

        var fire = false
        var gesture: Gesture?
        var report: String?
        let accepted = tapCounts
        let ceiling = accepted.max() ?? 3
        let minCount = accepted.min() ?? 3
        let changed = count != lastCount
        lastCount = count
        if count > gesturePeak { gesturePeak = count }
        if speed > tapPeakSpeed { tapPeakSpeed = speed }
        if moved > tapTravel { tapTravel = moved }
        if count > ceiling {
            tooMany = true
        } else if accepted.contains(count) {
            if !tapActive, !tooMany {
                tapActive = true
                tapSince = timestamp
            }
            // Four fingers land through three: keep the high-water mark, since
            // that is what says which gesture this was.
            if count > tapPeak { tapPeak = count }
        } else if count == 0 {
            if gesturePeak >= minCount {
                // The gesture is over — decide, and say what happened.
                let dur = tapActive ? timestamp - tapSince : 0
                let window = window(forFingers: tapPeak)
                let shape = String(format: "%.2fs travel %.3f speed %.2f", dur, tapTravel, tapPeakSpeed)
                if tooMany {
                    report = "trackpad: \(gesturePeak)-contact gesture \(shape) — dropped: more than \(ceiling) contacts"
                } else if !tapActive || tapPeak == 0 {
                    report = "trackpad: \(gesturePeak)-contact gesture \(shape) — dropped: never settled on an accepted count"
                } else if dur > window {
                    report = "trackpad: \(tapPeak)-finger gesture \(shape) — dropped: longer than the \(String(format: "%.2fs", window)) tap window"
                } else if lastFire >= 0, timestamp - lastFire < cooldown {
                    report = "trackpad: \(tapPeak)-finger tap \(shape) — dropped: \(String(format: "%.2fs", timestamp - lastFire)) after the last tap (cooldown \(cooldown)s)"
                } else {
                    lastFire = timestamp
                    fire = true
                    gesture = Gesture(fingers: Int(tapPeak), duration: dur, travel: tapTravel, peakSpeed: tapPeakSpeed)
                    report = "trackpad: \(tapPeak)-finger tap \(shape) → TAP"
                }
            }
            tapActive = false
            tooMany = false
            tapPeak = 0
            gesturePeak = 0
            tapPeakSpeed = 0
            tapTravel = 0
            landing.removeAll()
        }
        lock.unlock()

        onRawFrame?(numTouches, rawState)
        if let report { log(report) }
        if changed { onContactChange?(Int(count)) }
        if fire, let gesture { onTap?(gesture) }
    }
}

/// The C callback can't capture, so the live detector is reached through a
/// file-level pointer (set before the devices start, cleared after they stop).
nonisolated(unsafe) private var gDetector: TrackpadTapDetector?

private let mtContactCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void = {
    _, touches, numTouches, timestamp, _ in
    gDetector?.frame(touches: touches, numTouches: numTouches, timestamp: timestamp)
}
