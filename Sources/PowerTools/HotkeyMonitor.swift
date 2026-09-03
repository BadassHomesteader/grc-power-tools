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
        case readAloud                    // hold + R — OCR a region and speak it
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
        case quickCapture(connectionId: String)  // send a line to a configured connection
        case findMouse                    // spotlight the cursor
        case colorPicker                  // hold + K — screen eyedropper, copy hex
        case newDoc                       // hold + D — new document in current Finder folder
        case cycleWindow(back: Bool)      // ⌘Tab / ⇧⌘Tab — Alt-Tab-style window MRU
        case cycleEnd                     // ⌘ released — raise + commit the selection
        case cycleCancel                  // Esc while cycling — close, switch nothing
        case cycleArrow(dx: Int, dy: Int) // arrows while cycling — move the highlight
        case finderOpen                   // plain ⏎ in Finder — open, don't rename
        case synthKey(CGKeyCode, CGEventFlags) // remap: synthesize this keystroke
        case activityMonitor              // ⌃⇧⎋ — open Activity Monitor (Task Manager)
        case macroPad                     // hold + B — toggle the per-app macro pad
        case macroPadDigit(Int)           // hold + 1…9/0 while the pad is open — fire that button
        case macroPadSummon               // hold + three-finger tap — the pad beside the cursor
        case macroPadSummonClose          // leader-held Esc while a summoned pad is up — dismiss it
        case agentPad                     // hold + J — toggle the Claude Code session pad
        case cheatSheet                   // hold + Q — toggle the hotkey cheat sheet
        case cheatSheetClose              // Esc while the sheet is up — close it
        case powerRing                    // hold + right-click — radial menu at the cursor
        case powerRingClose               // Esc while the ring is up — close it
        case whiteboard                   // hold + E — annotate the last screenshot
        case whiteboardClose              // Esc while the whiteboard is up — cancel text entry / close
    }

    var handler: ((Callback) -> Void)?
    /// Windows-style key remaps, each independently toggleable.
    var keyHomeEnd = true          // Home/End line nav in text fields
    var finderBackspaceUp = true   // Finder Backspace = up a folder
    var finderDeleteTrash = true   // Finder Delete (⌦) = Move to Trash
    var taskManagerShortcut = true // ⌃⇧⎋ = Activity Monitor
    /// Live-toggleable: when true, ⌘Tab / ⇧⌘Tab are intercepted for the
    /// Alt-Tab-style window switcher (replacing the macOS app switcher).
    /// Plain Bool (same discipline as `held` — set on main, read on the tap
    /// thread; a torn read is impossible for a Bool here).
    var lastWindowSwitch = true
    /// When true and Finder is frontmost, plain ⏎ opens the selection instead
    /// of renaming (Windows-style). Both flags set from main, read on the tap
    /// thread (same discipline as `held`).
    var finderEnterOpens = true
    var finderFrontmost = false
    /// True while the macro pad panel is shown (set from main, read on the tap
    /// thread — same plain-Bool discipline as `held`). While true, leader-held
    /// digits WITH a mapped button fire it instead of their usual chords
    /// (3 stays the grid unless the pad actually has a third button).
    var macroPadVisible = false
    /// True while the hold+Q cheat sheet is up (same discipline) — a plain
    /// Esc then closes it instead of reaching the frontmost app.
    var cheatSheetVisible = false
    /// Power Ring feature flag (same discipline) — when off, a leader-held
    /// right-click passes through untouched.
    var powerRingEnabled = true
    /// True while the ring is up (same discipline) — plain Esc closes it.
    var powerRingVisible = false
    /// True while the annotation whiteboard is up (same discipline) — plain Esc
    /// must reach it even when its text tool's field editor is first responder.
    var whiteboardVisible = false
    /// Buttons in the pad's current profile — digits ≥ this pass through.
    var macroPadButtonCount = 0
    /// Three-finger-tap summon: feature flag + "a summoned pad is up" mirror
    /// (same discipline). Both written from main; the tap itself arrives from
    /// the multitouch thread via `trackpadThreeFingerTap()`.
    var macroPadSummonEnabled = true
    var macroPadSummoned = false
    /// True while the pad's Move search box has the caret (same discipline):
    /// plain Esc must reach the field (clear it) rather than close the pad.
    var macroPadSearchEditing = false

    /// keyCode → pad button index for the digit row (1…9 then 0 = tenth).
    private static let macroDigitIndex: [Int64: Int] = [
        18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8, 29: 9,
    ]

    /// Quick Capture leaders: keyCode → connection id, user-assigned per connection.
    /// A dictionary isn't safe to read on the tap thread while main writes it, so it
    /// is guarded by a lock (leader edits are rare; the read is one lookup per tap).
    private var _connectionLeaders: [Int64: String] = [:]
    private let leadersLock = NSLock()
    func setConnectionLeaders(_ map: [Int64: String]) {
        leadersLock.lock(); _connectionLeaders = map; leadersLock.unlock()
    }
    private func connectionLeader(for keyCode: Int64) -> String? {
        leadersLock.lock(); defer { leadersLock.unlock() }; return _connectionLeaders[keyCode]
    }

    /// Virtual keycode for an A–Z letter (nil for anything else). Used to translate
    /// a connection's user-chosen leader letter into the tap's keycode space.
    static func keyCode(forLetter letter: String) -> Int64? {
        guard let ch = letter.uppercased().first else { return nil }
        let map: [Character: Int64] = [
            "A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4, "I": 34,
            "J": 38, "K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35, "Q": 12,
            "R": 15, "S": 1, "T": 17, "U": 32, "V": 9, "W": 13, "X": 7, "Y": 16, "Z": 6]
        return map[ch]
    }
    /// True between the first intercepted ⌘Tab and the ⌘ release.
    private var cycling = false

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
    private enum Pending { case none, ocr, readAloud, ai, screenshot, search, fileCopy, fileCut, filePaste, advancedPaste, clipboardHistory, findMouse, colorPicker, newDoc, quickCapture(String) }
    private var pending: Pending = .none
    /// Set once an arrow/Return moves a window this hold, so release ends the
    /// window session instead of dispatching a dictation.
    private var windowMode = false
    /// A leader right-click was swallowed for the Power Ring — its paired
    /// rightMouseUp must be swallowed too (apps must never see an orphan up).
    private var ringSwallowUp = false
    /// When that swallow was armed — a paired up that never arrives (tap died
    /// mid-click) must not leave the NEXT right-click's up eaten.
    private var ringSwallowArmedAt: CFAbsoluteTime = 0

    /// Hold + three-finger tap (TrackpadTapDetector, on the multitouch
    /// thread): summon the macro pad beside the cursor. `windowMode` is
    /// written off the tap thread here — the health timer already does the
    /// same — so the leader release ends quietly instead of dictating. If the
    /// release beats this write, the controller's summon path calls
    /// interruptDictation() and the stray recording is dropped; nothing wedges.
    func trackpadThreeFingerTap() {
        guard held, macroPadSummonEnabled, !interrupted else { return }
        windowMode = true
        dispatch(.macroPadSummon)
    }

    private static let kVK_Function: Int64 = 63
    private static let kVK_RightOption: Int64 = 61
    private static let kVK_RightCommand: Int64 = 54
    private static let kVK_Escape: Int64 = 53
    private static let kVK_ANSI_T: Int64 = 17
    private static let kVK_ANSI_R: Int64 = 15
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
    private static let kVK_ANSI_K: Int64 = 40
    private static let kVK_ANSI_D: Int64 = 2
    private static let kVK_ANSI_B: Int64 = 11
    private static let kVK_ANSI_J: Int64 = 38
    private static let kVK_ANSI_3: Int64 = 20
    private static let kVK_ANSI_Q: Int64 = 12
    private static let kVK_ANSI_E: Int64 = 14
    private static let kVK_Tab: Int64 = 48
    private static let kVK_Return: Int64 = 36
    private static let kVK_LeftArrow: Int64 = 123
    private static let kVK_RightArrow: Int64 = 124
    private static let kVK_DownArrow: Int64 = 125
    private static let kVK_UpArrow: Int64 = 126
    private static let kVK_Home: Int64 = 115
    private static let kVK_End: Int64 = 119
    private static let kVK_ForwardDelete: Int64 = 117
    private static let kVK_Backspace: Int64 = 51
    private static let kVK_LeftBracket: Int64 = 33   // [ — for ⌘[ (Finder Back)

    init(hotkey: Config.Hotkey) {
        self.hotkey = hotkey
    }

    func start() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |   // leader + right-click = Power Ring
            (1 << CGEventType.rightMouseUp.rawValue)

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
                self.ringSwallowUp = false
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

        // Leader + right-click = Power Ring (radial menu at the cursor). The
        // down is swallowed so no context menu opens underneath, and so is its
        // paired up; windowMode makes the leader release end quietly.
        if type == .rightMouseDown {
            guard held, powerRingEnabled else { return Unmanaged.passUnretained(event) }
            windowMode = true
            ringSwallowUp = true
            ringSwallowArmedAt = CFAbsoluteTimeGetCurrent()
            dispatch(.powerRing)
            return nil
        }
        if type == .rightMouseUp {
            if ringSwallowUp {
                ringSwallowUp = false
                // Stale arm (its own up got lost) → this is a fresh click's up.
                if CFAbsoluteTimeGetCurrent() - ringSwallowArmedAt < 0.5 { return nil }
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // ⌘Tab / ⇧⌘Tab → Alt-Tab-style window switcher (when enabled). This
        // suppresses the macOS app switcher. ⌃/⌥ combos pass through untouched.
        // Auto-repeat swallowed but not dispatched (tap Tab to step).
        if lastWindowSwitch, keyCode == Self.kVK_Tab, type == .keyDown {
            let mods = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            if mods == .maskCommand || mods == [.maskCommand, .maskShift] {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    cycling = true
                    swallowedKeyUps.insert(keyCode)
                    dispatch(.cycleWindow(back: mods.contains(.maskShift)))
                }
                return nil
            }
        }
        // Plain ⏎ in Finder → open the selection (Windows-style) instead of
        // renaming. Exact-match: any modifier passes through; leader-held Return
        // stays the maximize chord. The AX focus check keeps Return working in
        // rename fields / search boxes (text focus → pass through untouched) —
        // it must run BEFORE swallowing, synchronously (~ms, 50ms cap).
        if finderEnterOpens, finderFrontmost, !held, type == .keyDown, keyCode == Self.kVK_Return,
           flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty {
            if ContextSnapshot.focusIsTextEditing() {
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                swallowedKeyUps.insert(keyCode)
                dispatch(.finderOpen)
            }
            return nil
        }

        // Windows-style key remaps — each independently toggleable. Exact-match,
        // guarded so text editing and modified variants pass through. Never
        // touches the leader (!held).
        if !held, type == .keyDown {
            let mods = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])

            // ⌃⇧⎋ → Activity Monitor (macOS's Task Manager). Global.
            if taskManagerShortcut, keyCode == Self.kVK_Escape, mods == [.maskControl, .maskShift] {
                swallowedKeyUps.insert(keyCode)
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { dispatch(.activityMonitor) }
                return nil
            }

            // Home / End → line start/end (⌘←/⌘→); with ⌃ → document top/bottom
            // (⌘↑/⌘↓); ⇧ preserved for selection. Only while editing text — in a
            // Finder list / desktop, native Home/End (select-first/last) is left
            // alone. AX check is bounded (~ms, 50ms cap) and fails safe to "text".
            if keyHomeEnd, keyCode == Self.kVK_Home || keyCode == Self.kVK_End {
                let extra = mods.subtracting([.maskControl, .maskShift])
                if extra.isEmpty, ContextSnapshot.focusIsTextEditing() {
                    let isHome = keyCode == Self.kVK_Home
                    let ctrl = mods.contains(.maskControl)
                    var out: CGEventFlags = .maskCommand
                    if mods.contains(.maskShift) { out.insert(.maskShift) }
                    let target: CGKeyCode = ctrl
                        ? CGKeyCode(isHome ? Self.kVK_UpArrow : Self.kVK_DownArrow)
                        : CGKeyCode(isHome ? Self.kVK_LeftArrow : Self.kVK_RightArrow)
                    swallowedKeyUps.insert(keyCode)
                    dispatch(.synthKey(target, out))
                    return nil
                }
            }

            // Finder file list: plain Backspace → Up to enclosing folder (⌘↑,
            // like Windows Explorer); plain Delete → Move to Trash (⌘⌫). Skipped
            // in rename/search text so those keys still edit text. Finder-
            // frontmost + no modifiers only. AX check runs only for these two
            // keys (never on ordinary typing).
            let isBack = finderBackspaceUp && keyCode == Self.kVK_Backspace
            let isDel = finderDeleteTrash && keyCode == Self.kVK_ForwardDelete
            if finderFrontmost, mods.isEmpty, isBack || isDel,
               !ContextSnapshot.focusIsTextEditing() {
                swallowedKeyUps.insert(keyCode)
                dispatch(.synthKey(CGKeyCode(isBack ? Self.kVK_UpArrow : Self.kVK_Backspace), .maskCommand))
                return nil
            }
        }

        // ⌘ released while a cycle session is open → commit it. Not consumed.
        if cycling, type == .flagsChanged, !flags.contains(.maskCommand) {
            cycling = false
            dispatch(.cycleEnd)
        }
        // Esc while cycling → cancel (swallowed so the frontmost app never sees it).
        if cycling, type == .keyDown, keyCode == Self.kVK_Escape {
            cycling = false
            swallowedKeyUps.insert(keyCode)
            dispatch(.cycleCancel)
            return nil
        }
        // Plain Esc while the cheat sheet, Power Ring, whiteboard, or a
        // SUMMONED macro pad is up → close them (swallowed so the frontmost
        // app's dialogs don't also close). The summoned pad qualifies because
        // it is fire-once — it leaves after one macro or the next click
        // elsewhere, so it can never sit there eating Esc. Leader-held Esc
        // keeps its cancel meaning — they close there too (leader block below).
        let padEsc = macroPadSummoned && !macroPadSearchEditing   // Esc in the search box clears the box
        if cheatSheetVisible || powerRingVisible || whiteboardVisible || padEsc,
           !held, type == .keyDown, keyCode == Self.kVK_Escape,
           flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]).isEmpty {
            swallowedKeyUps.insert(keyCode)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                if cheatSheetVisible { dispatch(.cheatSheetClose) }
                if powerRingVisible { dispatch(.powerRingClose) }
                if whiteboardVisible { dispatch(.whiteboardClose) }
                if padEsc { dispatch(.macroPadSummonClose) }
            }
            return nil
        }
        // Arrows while cycling move the strip highlight (Windows Alt-Tab style):
        // ←/→ step, ↑/↓ jump rows. Only inside a session — a plain ⌘←/⌘→ keeps
        // its stock line-start/line-end meaning. Auto-repeat allowed (scrubbing).
        if cycling, type == .keyDown,
           keyCode == Self.kVK_LeftArrow || keyCode == Self.kVK_RightArrow
            || keyCode == Self.kVK_UpArrow || keyCode == Self.kVK_DownArrow {
            swallowedKeyUps.insert(keyCode)
            let dx = keyCode == Self.kVK_LeftArrow ? -1 : (keyCode == Self.kVK_RightArrow ? 1 : 0)
            let dy = keyCode == Self.kVK_UpArrow ? -1 : (keyCode == Self.kVK_DownArrow ? 1 : 0)
            dispatch(.cycleArrow(dx: dx, dy: dy))
            return nil
        }

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
            // Macro pad digits: while the pad is shown, a digit that maps to a
            // real button fires it (shadowing 3 = grid only when a third button
            // exists); unmapped digits keep their normal meaning. Fires on
            // keydown so several emails can be filed in one hold — the runs
            // queue and flush when the leader lifts. Auto-repeat swallowed.
            if macroPadVisible, let idx = Self.macroDigitIndex[keyCode], idx < macroPadButtonCount {
                windowMode = true
                swallowedKeyUps.insert(keyCode)
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    dispatch(.macroPadDigit(idx))
                }
                return nil
            }
            switch keyCode {
            case Self.kVK_Escape:
                interrupted = true; swallowedKeyUps.insert(keyCode)
                if cheatSheetVisible { dispatch(.cheatSheetClose) }
                if powerRingVisible { dispatch(.powerRingClose) }
                if whiteboardVisible { dispatch(.whiteboardClose) }
                if macroPadSummoned { dispatch(.macroPadSummonClose) }
                dispatch(.cancel)
                return nil // swallow so it doesn't close the user's dialogs
            case Self.kVK_ANSI_T:
                log("hotkey: +T leader armed (OCR)")
                pending = .ocr; swallowedKeyUps.insert(keyCode)
                return nil // OCR fires on release; recording continues harmlessly until then
            case Self.kVK_ANSI_R:
                // A user-assigned Quick Capture connection on R wins (same rule as B).
                if let connId = connectionLeader(for: keyCode) {
                    log("hotkey: connection leader armed (\(connId))")
                    pending = .quickCapture(connId); swallowedKeyUps.insert(keyCode)
                    return nil
                }
                log("hotkey: +R leader armed (read aloud)")
                pending = .readAloud; swallowedKeyUps.insert(keyCode)
                return nil
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
            case Self.kVK_ANSI_K:
                log("hotkey: +K leader armed (color picker)")
                pending = .colorPicker; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_D:
                log("hotkey: +D leader armed (new document)")
                pending = .newDoc; swallowedKeyUps.insert(keyCode)
                return nil
            case Self.kVK_ANSI_B:
                // Grandfathered: if the user already assigned B to a Quick Capture
                // connection, that assignment wins over the macro pad.
                if let connId = connectionLeader(for: keyCode) {
                    log("hotkey: connection leader armed (\(connId))")
                    pending = .quickCapture(connId); swallowedKeyUps.insert(keyCode)
                    return nil
                }
                // Toggle fires immediately (like the grid/palette); release just
                // ends the session — the pad is a persistent panel, not a hold UI.
                // Auto-repeat swallowed but not dispatched: a held B must not
                // re-toggle the pad every repeat (final state = repeat parity).
                windowMode = true
                swallowedKeyUps.insert(keyCode)
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { dispatch(.macroPad) }
                return nil
            case Self.kVK_ANSI_J:
                // Agent Pad toggle — same rules as B: a user-assigned Quick
                // Capture connection on J wins, and auto-repeat must not
                // re-toggle the panel.
                if let connId = connectionLeader(for: keyCode) {
                    log("hotkey: connection leader armed (\(connId))")
                    pending = .quickCapture(connId); swallowedKeyUps.insert(keyCode)
                    return nil
                }
                windowMode = true
                swallowedKeyUps.insert(keyCode)
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { dispatch(.agentPad) }
                return nil
            case Self.kVK_ANSI_Q:
                // Hotkey cheat sheet — same rules as B/J: a user-assigned Quick
                // Capture connection on Q wins, auto-repeat must not re-toggle.
                if let connId = connectionLeader(for: keyCode) {
                    log("hotkey: connection leader armed (\(connId))")
                    pending = .quickCapture(connId); swallowedKeyUps.insert(keyCode)
                    return nil
                }
                windowMode = true
                swallowedKeyUps.insert(keyCode)
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { dispatch(.cheatSheet) }
                return nil
            case Self.kVK_ANSI_E:
                // Annotation whiteboard — same rules as B/J/Q: a user-assigned
                // Quick Capture connection on E wins, auto-repeat must not
                // re-toggle. The whiteboard (a keyable window) takes over from
                // here; release just ends the session.
                if let connId = connectionLeader(for: keyCode) {
                    log("hotkey: connection leader armed (\(connId))")
                    pending = .quickCapture(connId); swallowedKeyUps.insert(keyCode)
                    return nil
                }
                windowMode = true
                swallowedKeyUps.insert(keyCode)
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { dispatch(.whiteboard) }
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
                // A user-assigned Quick Capture connection leader (e.g. +N, +E).
                // Armed here, opens on release like the other pending leaders.
                if let connId = connectionLeader(for: keyCode) {
                    log("hotkey: connection leader armed (\(connId))")
                    pending = .quickCapture(connId); swallowedKeyUps.insert(keyCode)
                    return nil
                }
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
                case .readAloud: dispatch(.readAloud)
                case .screenshot: dispatch(.screenshot)
                case .search: dispatch(.search)
                case .fileCopy: dispatch(.fileCopy)
                case .fileCut: dispatch(.fileCut)
                case .filePaste: dispatch(.filePaste)
                case .advancedPaste: dispatch(.advancedPaste)
                case .clipboardHistory: dispatch(.clipboardHistory)
                case .findMouse: dispatch(.findMouse)
                case .colorPicker: dispatch(.colorPicker)
                case .newDoc: dispatch(.newDoc)
                case .quickCapture(let id): dispatch(.quickCapture(connectionId: id))
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
