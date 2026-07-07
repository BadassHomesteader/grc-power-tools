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
    enum Command { case dictate, ai }
    enum Callback {
        case down
        case up(Command)
        case cancel
        case ocr
        case screenshot
        case search
        case fileCopy
        case fileCut
        case filePaste
        case window(WindowManager.Move)  // fires immediately, repeatable while held
        case windowEnd                    // hotkey released after window moves
        case grid                         // draw-a-grid window placement
        case windowPalette                // Moom-style snap palette
        case advancedPaste                // paste-as palette
        case clipboardHistory             // recent-copies palette (Win+V)
        case findMouse                    // spotlight the cursor
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
    /// keyCodes whose paired keyUp must also be swallowed (keys we consumed
    /// mid-hold), so apps never see an orphan keyUp — a set so simultaneously-held
    /// keys (e.g. two arrows) are each tracked, not just the last one.
    private var swallowedKeyUps: Set<Int64> = []
    /// Leader action armed by tapping a letter while the hotkey is held.
    private enum Pending { case none, ocr, ai, screenshot, search, fileCopy, fileCut, filePaste, advancedPaste, clipboardHistory, findMouse }
    private var pending: Pending = .none
    /// Set once an arrow/Return moves a window this hold, so release ends the
    /// window session instead of dispatching a dictation.
    private var windowMode = false

    private static let kVK_Function: Int64 = 63
    private static let kVK_RightOption: Int64 = 61
    private static let kVK_RightCommand: Int64 = 54
    private static let kVK_Escape: Int64 = 53
    private static let kVK_ANSI_T: Int64 = 17
    private static let kVK_ANSI_A: Int64 = 0
    private static let kVK_ANSI_S: Int64 = 1
    private static let kVK_ANSI_G: Int64 = 5
    private static let kVK_ANSI_C: Int64 = 8
    private static let kVK_ANSI_X: Int64 = 7
    private static let kVK_ANSI_V: Int64 = 9
    private static let kVK_ANSI_P: Int64 = 35
    private static let kVK_ANSI_M: Int64 = 46
    private static let kVK_ANSI_W: Int64 = 13
    private static let kVK_ANSI_H: Int64 = 4
    private static let kVK_ANSI_3: Int64 = 20
    private static let kVK_Return: Int64 = 36
    private static let kVK_LeftArrow: Int64 = 123
    private static let kVK_RightArrow: Int64 = 124
    private static let kVK_DownArrow: Int64 = 125
    private static let kVK_UpArrow: Int64 = 126

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
                self.windowMode = false
                self.pending = .none
                self.swallowedKeyUps.removeAll()
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
        case .shiftCommand:
            if type == .flagsChanged {
                let both = flags.contains(.maskShift) && flags.contains(.maskCommand)
                if both != held {
                    return handleHotkeyFlag(isDown: both, event: event, suppress: false)
                }
            }
        case .optionShift:
            if type == .flagsChanged {
                let both = flags.contains(.maskShift) && flags.contains(.maskAlternate)
                if both != held {
                    return handleHotkeyFlag(isDown: both, event: event, suppress: false)
                }
            }
        }

        // Leader chords: while the hotkey is held, a tapped letter selects a mode
        // instead of dictating. T = capture text from screen; A = AI (command mode
        // if text is selected, else route this dictation through the cloud AI).
        // Esc cancels; any other key means an unrelated combo (e.g. Fn+arrow).
        if held && type == .keyDown {
            switch keyCode {
            case Self.kVK_Escape:
                interrupted = true; swallowedKeyUps.insert(keyCode)
                dispatch(.cancel)
                return nil // swallow so it doesn't close the user's dialogs
            case Self.kVK_ANSI_T:
                log("hotkey: +T leader armed (OCR)")
                pending = .ocr; swallowedKeyUps.insert(keyCode)
                return nil // OCR fires on release; recording continues harmlessly until then
            case Self.kVK_ANSI_A:
                log("hotkey: +A leader armed (AI)")
                pending = .ai; swallowedKeyUps.insert(keyCode)
                return nil // keep recording — the user is about to speak the instruction
            case Self.kVK_ANSI_S:
                log("hotkey: +S leader armed (screenshot)")
                pending = .screenshot; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_G:
                log("hotkey: +G leader armed (Google search)")
                pending = .search; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_C:
                log("hotkey: +C leader armed (file copy)")
                pending = .fileCopy; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_X:
                log("hotkey: +X leader armed (file cut)")
                pending = .fileCut; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_V:
                log("hotkey: +V leader armed (file paste)")
                pending = .filePaste; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_P:
                log("hotkey: +P leader armed (advanced paste)")
                pending = .advancedPaste; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_H:
                log("hotkey: +H leader armed (clipboard history)")
                pending = .clipboardHistory; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_M:
                log("hotkey: +M leader armed (find mouse)")
                pending = .findMouse; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_3:
                // Grid draw mode. Enter windowMode so release ends the session (no
                // dictation); the grid overlay itself takes over via the mouse.
                windowMode = true
                swallowedKeyUps.insert(keyCode)
                dispatch(.grid)
                return nil
            case Self.kVK_ANSI_W:
                // Snap palette. Like the grid: release just ends the session; the
                // palette (a keyable panel) takes over from here.
                windowMode = true
                swallowedKeyUps.insert(keyCode)
                dispatch(.windowPalette)
                return nil
            case Self.kVK_LeftArrow, Self.kVK_RightArrow, Self.kVK_UpArrow, Self.kVK_DownArrow, Self.kVK_Return:
                // Window moves fire immediately and can repeat while held (tap ←←
                // to shrink). Release then just ends the session (no dictation).
                let move: WindowManager.Move
                switch keyCode {
                case Self.kVK_LeftArrow: move = .left
                case Self.kVK_RightArrow: move = .right
                case Self.kVK_UpArrow: move = .up
                case Self.kVK_DownArrow: move = .down
                default: move = .maximize
                }
                windowMode = true
                swallowedKeyUps.insert(keyCode)
                dispatch(.window(move))
                return nil
            default:
                // During a window session (grid/palette open) other keys pass
                // through untouched — digits reach the palette's local monitor —
                // and must NOT dispatch a cancel that would race the palette.
                if windowMode { return Unmanaged.passUnretained(event) }
                interrupted = true
                dispatch(.cancel)
                return Unmanaged.passUnretained(event)
            }
        }

        // Swallow the paired keyUp of any key we consumed mid-hold — tracked in a
        // set, and not gated on `held`, so a key still down when the hotkey is
        // released still has its keyUp swallowed (no orphan reaches the app).
        if type == .keyUp && swallowedKeyUps.contains(keyCode) {
            swallowedKeyUps.remove(keyCode)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleHotkeyFlag(isDown: Bool, event: CGEvent, suppress: Bool) -> Unmanaged<CGEvent>? {
        if isDown && !held {
            held = true
            heldSince = Date()
            interrupted = false
            pending = .none
            windowMode = false
            dispatch(.down)
        } else if !isDown && held {
            held = false
            heldSince = nil
            let p = pending
            pending = .none
            let wasWindow = windowMode
            windowMode = false
            if wasWindow {
                dispatch(.windowEnd)  // window moves already fired on keydown
            } else if !interrupted {
                switch p {
                case .none: dispatch(.up(.dictate))
                case .ai: dispatch(.up(.ai))
                case .ocr: dispatch(.ocr)
                case .screenshot: dispatch(.screenshot)
                case .search: dispatch(.search)
                case .fileCopy: dispatch(.fileCopy)
                case .fileCut: dispatch(.fileCut)
                case .filePaste: dispatch(.filePaste)
                case .advancedPaste: dispatch(.advancedPaste)
                case .clipboardHistory: dispatch(.clipboardHistory)
                case .findMouse: dispatch(.findMouse)
                }
            }
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
