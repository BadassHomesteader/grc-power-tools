import Foundation
import CoreGraphics
import AppKit

/// Marks CGEvents we synthesize (the paste Cmd+V) so our own tap ignores them.
let kSyntheticEventMagic: Int64 = 0x4752_4357 // 'GRCW'

/// Global push-to-talk hotkey via CGEventTap.
///
/// Hardening (all lessons from shipped dictation apps):
/// - suppress ONLY exact hotkey events, never anything else
/// - re-enable the tap on kCGEventTapDisabledByTimeout/ByUserInput
/// - stale-hold expiry so a missed key-up can never wedge the state machine
/// - periodic health check that re-enables a silently-dead tap (VoiceInk #735)
/// - a non-hotkey keypress during a hold cancels dictation (user was doing Fn+arrow)
final class HotkeyMonitor {
    enum Callback {
        case down, up, cancel
    }

    var handler: ((Callback) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var healthTimer: Timer?

    private let hotkey: Config.Hotkey
    private(set) var held = false
    private var heldSince: Date?
    /// Set when a foreign key interrupts the hold; ignore events until hotkey release.
    private var interrupted = false

    private static let kVK_Function: Int64 = 63
    private static let kVK_RightOption: Int64 = 61
    private static let kVK_RightCommand: Int64 = 54
    private static let kVK_Escape: Int64 = 53

    init(hotkey: Config.Hotkey) {
        self.hotkey = hotkey
    }

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("hotkey: tap creation FAILED (missing Accessibility permission?)")
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        let thread = Thread { [weak self] in
            guard let self, let source = self.runLoopSource else { return }
            self.threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "grc-whisper.hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread

        // Health check: taps die silently on some macOS 26 builds; stale holds
        // (missed key-up) must expire or the state machine wedges.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                log("hotkey: tap found disabled by health check, re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            if self.held, let since = self.heldSince, Date().timeIntervalSince(since) > 150 {
                log("hotkey: stale hold (>150s), forcing cancel")
                self.held = false
                self.heldSince = nil
                self.interrupted = false
                self.dispatch(.cancel)
            }
        }
        log("hotkey: listening for \(hotkey.displayName)")
        return true
    }

    func stop() {
        healthTimer?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop = threadRunLoop { CFRunLoopStop(runLoop) }
    }

    private func dispatch(_ cb: Callback) {
        DispatchQueue.main.async { [weak self] in self?.handler?(cb) }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Tap re-enable events arrive through the callback itself.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("hotkey: tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        // Pass through events we synthesized (paste Cmd+V).
        if event.getIntegerValueField(.eventSourceUserData) == kSyntheticEventMagic {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch hotkey {
        case .fn:
            if type == .flagsChanged && keyCode == Self.kVK_Function {
                return handleHotkeyFlag(isDown: flags.contains(.maskSecondaryFn), event: event, suppress: true)
            }
        case .rightOption:
            if type == .flagsChanged && keyCode == Self.kVK_RightOption {
                return handleHotkeyFlag(isDown: flags.contains(.maskAlternate), event: event, suppress: true)
            }
        case .rightCommand:
            if type == .flagsChanged && keyCode == Self.kVK_RightCommand {
                return handleHotkeyFlag(isDown: flags.contains(.maskCommand), event: event, suppress: true)
            }
        case .ctrlOption:
            if type == .flagsChanged {
                let both = flags.contains(.maskControl) && flags.contains(.maskAlternate)
                if both != held {
                    // Don't suppress: plain modifiers must keep working for normal chords.
                    return handleHotkeyFlag(isDown: both, event: event, suppress: false)
                }
            }
        }

        // While holding: Esc cancels; any other real keypress means the user is
        // doing a key combo (e.g. Fn+arrow) — cancel and let the event through.
        if held && type == .keyDown {
            if keyCode == Self.kVK_Escape {
                interrupted = true
                dispatch(.cancel)
                return nil // swallow the Esc so it doesn't close the user's dialogs
            }
            interrupted = true
            dispatch(.cancel)
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleHotkeyFlag(isDown: Bool, event: CGEvent, suppress: Bool) -> Unmanaged<CGEvent>? {
        if isDown && !held {
            held = true
            heldSince = Date()
            interrupted = false
            dispatch(.down)
        } else if !isDown && held {
            held = false
            heldSince = nil
            if !interrupted { dispatch(.up) }
            interrupted = false
        }
        return suppress ? nil : Unmanaged.passUnretained(event)
    }
}

/// Reads the system "Press 🌐 key to..." setting; anything but "Do Nothing" (0)
/// fights a Fn-hold hotkey (emoji picker / dictation / input-source switch).
func globeKeyAction() -> Int {
    let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
    return defaults?.object(forKey: "AppleFnUsageType") as? Int ?? 1
}
