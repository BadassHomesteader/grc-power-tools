import Foundation
import AppKit
import CoreGraphics

/// Glue for the dictation state machine: idle -> recording -> processing -> idle.
///
/// Every async continuation is guarded by a generation counter (`cycle`): stale
/// completions from a previous dictation cycle must never mutate the current one.
@MainActor
final class AppController {
    enum State { case idle, recording, processing }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    var lastTranscript: String = ""
    /// Live-mutable: the menu updates polish mode without a relaunch.
    var config: Config {
        didSet {
            overlay.anchor = config.overlayPosition
            overlay.scheme = config.appearance
            chat?.updateConfig(config)
            clipboardWatcher.enabled = config.clipboardHistory
            hotkey?.lastWindowSwitch = config.lastWindowSwitch
            hotkey?.finderEnterOpens = config.finderEnterOpens
            hotkey?.keyHomeEnd = config.keyHomeEnd
            hotkey?.finderBackspaceUp = config.finderBackspaceUp
            hotkey?.finderDeleteTrash = config.finderDeleteTrash
            hotkey?.taskManagerShortcut = config.taskManagerShortcut
            hotkey?.setConnectionLeaders(Self.leaderMap(config.connections))
            windowSwitcher.dark = config.appearance.isDark
            grabAndMove.update(enabled: config.grabAndMove, modifiers: config.grabMoveModifiers.flags)
            macroPad.update(enabled: config.macroPad, profiles: config.macroPadProfiles,
                            dark: config.appearance.isDark)
            hotkey?.powerRingEnabled = config.powerRing
            hotkey?.macroPadSummonEnabled = config.macroPad && config.macroPadThreeFingerTap
            trackpadTap.setTapFingers(config.macroPadSummonFingers)
            trackpadTap.update(enabled: config.macroPad && config.macroPadThreeFingerTap)
            if !config.agentPadCodex { claudeRegistry.setExternal(kind: "codex", []) }
            if !config.agentPadCursor { claudeRegistry.setExternal(kind: "cursor", []) }
            if !config.agentPadGrok { claudeRegistry.setExternal(kind: "grok", []) }
            applyNotchConfig()
            CaptureVisibility.set(config.showInCaptures)
        }
    }

    let store: Store
    private let audio: AudioCapture
    private let polisher: Polisher
    private let overlay = OverlayPanel()
    private let gridOverlay = GridOverlay()
    private let snapAssist = SnapAssist()
    private let advancedPaste = AdvancedPaste()
    private let quickCapture = QuickCapture()
    private let findMouse = FindMouse()
    private let colorPalette = ColorFormatPalette()
    private let ducker = AudioDucker()
    private let windowPalette = WindowPalette()
    private let clipboardPalette = ClipboardPalette()
    private let windowSwitcher = WindowSwitcher()
    private let readAloud = ReadAloud()
    private let grabAndMove = GrabAndMove()
    private let macroPad = MacroPad()
    private let trackpadTap = TrackpadTapDetector()
    private let cheatSheet = HotkeyCheatSheet()
    private let powerRing = PowerRing()
    private let whiteboard = Whiteboard()
    private let agentPad = AgentPad()
    private let notchStrip = NotchStrip()
    /// NSMenu does not retain item targets; without this the handler is gone
    /// before the user picks anything.
    private var notchMenuTarget: NotchMenuTarget?
    private let claudeRegistry = ClaudeSessionRegistry()
    private let hookServer = ClaudeHookServer()
    private lazy var clipboardWatcher = ClipboardHistory(store: store, enabled: config.clipboardHistory)
    private var hotkey: HotkeyMonitor?
    private var chat: ChatWindowController?

    private var cycle = 0
    /// File "cut" is Copy now + Move-on-next-paste (macOS has no real file cut).
    private var fileCutPending = false
    /// Window-organizer cycle state: repeated same-direction taps shrink the window.
    private var winLastMove: WindowManager.Move?
    private var winStep = 0
    private static let winFractions: [CGFloat] = [0.5, 1.0 / 3.0, 2.0 / 3.0]
    /// Chained-snap state within one leader hold: the horizontal and vertical
    /// constraints applied so far, so ← then ↑ lands the top-left corner
    /// (Moom-style chaining) instead of the second press replacing the first.
    private var chainH: (edge: WindowManager.Edge, f: CGFloat, label: String)?
    private var chainV: (edge: WindowManager.Edge, f: CGFloat, label: String)?
    /// After an edge snap, the empty region to offer Snap Assist for (on release).
    private var snapAssistRegion: CGRect?
    private var snapAssistExcludeWID: CGWindowID?
    private var utterance: (any TranscriptionEngine)?
    private var startTask: Task<Void, Error>?
    private var context: ContextSnapshot?
    private var recordingStarted: Date?
    /// Diagnostic: loudest level seen this utterance (waveform swaps at 0.22).
    private var utterancePeak: Float = 0
    private var maxUtteranceTimer: Timer?
    /// True when this dictation cycle should fill the open Quick Capture panel
    /// instead of pasting into another app.
    private var dictatingIntoCapture = false
    /// True when this cycle should drop the transcript into the open notch Ask
    /// field. The notch is non-activating, so the frontmost app is NOT us — the
    /// only reliable signal is the strip's own state, checked before the
    /// app-based routing below.
    private var dictatingIntoNotchAsk = false

    init(config: Config, store: Store) {
        self.config = config
        self.store = store
        self.audio = AudioCapture(preRollSeconds: config.preRollSeconds)
        self.polisher = Polisher(store: store)
    }

    private var engineType: any TranscriptionEngine.Type { resolveEngineType(config.asrEngine) }

    func start() async throws {
        overlay.anchor = config.overlayPosition
        overlay.scheme = config.appearance
        guard await AudioCapture.requestMicPermission() else {
            throw NSError(domain: "GRCWhisper", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }
        // Parakeet's vocab boosting reads the dictionary per utterance, so
        // Settings ▸ Dictionary edits apply to the very next dictation.
        ParakeetEngine.vocabTermsProvider = { [store] in store.dictionary() }
        try await engineType.ensureAssets(locale: Locale(identifier: config.localeIdentifier))
        try audio.start()
        audio.onLevels = { [weak self] levels in
            let peak = levels.max() ?? 0
            Task { @MainActor in
                guard let self else { return }
                if peak > self.utterancePeak { self.utterancePeak = peak }
                self.overlay.setLevels(levels)
            }
        }

        let monitor = HotkeyMonitor(hotkey: config.hotkey)
        monitor.lastWindowSwitch = config.lastWindowSwitch
        monitor.setConnectionLeaders(Self.leaderMap(config.connections))
        monitor.handler = { [weak self] event in
            guard let self else { return }
            switch event {
            case .down: self.keyDown()
            case .up(let cmd): self.keyUp(ai: cmd == .ai)
            case .cancel: self.cancel()
            case .ocr:
                self.interruptDictation()
                self.captureScreenText()
            case .readAloud:
                self.interruptDictation()
                self.readScreenText()
            case .screenshot:
                self.interruptDictation()
                self.captureScreenshot(search: false)
            case .search:
                self.interruptDictation()
                self.captureScreenshot(search: true)
            case .fileCopy:
                self.interruptDictation()
                self.fileClipboard(.copy)
            case .fileCut:
                self.interruptDictation()
                self.fileClipboard(.cut)
            case .filePaste:
                self.interruptDictation()
                self.fileClipboard(.paste)
            case .window(let move):
                // While the leader is held the tap swallows arrows/Return, so the
                // palette (if open) gets them forwarded here instead of snapping.
                if self.windowPalette.isVisible { self.windowPalette.leaderKey(move) }
                else { self.handleWindow(move) }
            case .windowEnd:
                self.overlay.hide()
                self.maybeSnapAssist()
            case .grid:
                // "3" is the grid chord — but with the palette open it's the
                // palette's Right ½ digit, not a second overlay.
                if self.windowPalette.isVisible { self.windowPalette.applyDigit("3") }
                else { self.openGrid() }
            case .windowPalette:
                self.openWindowPalette()
            case .advancedPaste:
                self.openAdvancedPaste()
            case .quickCapture(let connId):
                self.openQuickCapture(connectionId: connId)
            case .clipboardHistory:
                self.openClipboardHistory()
            case .cycleWindow(let back):
                self.windowSwitcher.cycle(back: back)
            case .cycleEnd:
                self.windowSwitcher.endCycle()
            case .cycleCancel:
                self.windowSwitcher.cancelCycle()
            case .cycleArrow(let dx, let dy):
                self.windowSwitcher.cycleArrow(dx: dx, dy: dy)
            case .finderOpen:
                // ⌘O = Finder's own Open — works for files and folders alike.
                Inserter.postKey(CGKeyCode(31 /* kVK_ANSI_O */), flags: .maskCommand)
            case .synthKey(let key, let flags):
                Inserter.postKey(key, flags: flags)
            case .activityMonitor:
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            case .findMouse:
                self.interruptDictation()
                self.findMouse.flash()
            case .colorPicker:
                self.interruptDictation()
                self.pickColor()
            case .newDoc:
                self.interruptDictation()
                self.openNewDocMenu()
            case .macroPad:
                self.toggleMacroPad()
            case .macroPadDigit(let idx):
                self.fireMacroPadDigit(idx)
            case .macroPadSummon:
                self.summonMacroPad()
            case .macroPadSummonClose:
                self.macroPad.endSummon()
            case .agentPad:
                self.toggleAgentPad()
            case .cheatSheet:
                self.toggleCheatSheet()
            case .cheatSheetClose:
                self.cheatSheet.dismiss()
            case .powerRingClose:
                self.powerRing.dismiss()
            case .powerRing:
                self.togglePowerRing()
            case .whiteboard:
                self.interruptDictation()
                self.openWhiteboard()
            case .whiteboardClose:
                self.whiteboard.handleEscape()
            }
        }
        guard monitor.start() else {
            throw NSError(domain: "GRCWhisper", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't install the global hotkey — grant Accessibility permission and relaunch"])
        }
        hotkey = monitor
        // Keep the tap's Finder-frontmost flag current (read on the tap thread
        // for the ⏎-opens interception; never query NSWorkspace from the tap).
        monitor.finderEnterOpens = config.finderEnterOpens
        monitor.keyHomeEnd = config.keyHomeEnd
        monitor.finderBackspaceUp = config.finderBackspaceUp
        monitor.finderDeleteTrash = config.finderDeleteTrash
        monitor.taskManagerShortcut = config.taskManagerShortcut
        monitor.powerRingEnabled = config.powerRing
        monitor.macroPadSummonEnabled = config.macroPad && config.macroPadThreeFingerTap
        monitor.finderFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        // The tap only intercepts leader-digits while the pad is shown, and
        // only for digits that map to a real button of the current profile.
        macroPad.onStateChanged = { [weak self] visible, buttonCount in
            self?.hotkey?.macroPadVisible = visible
            self?.hotkey?.macroPadButtonCount = buttonCount
        }
        // The tap mirrors sheet/ring visibility so a plain Esc can close them.
        cheatSheet.onVisibility = { [weak self] visible in
            self?.hotkey?.cheatSheetVisible = visible
        }
        powerRing.onVisibility = { [weak self] visible in
            self?.hotkey?.powerRingVisible = visible
        }
        whiteboard.onVisibility = { [weak self] visible in
            self?.hotkey?.whiteboardVisible = visible
        }
        macroPad.onSummonChanged = { [weak self] summoned in
            self?.hotkey?.macroPadSummoned = summoned
        }
        macroPad.onSearchEditingChanged = { [weak self] editing in
            self?.hotkey?.macroPadSearchEditing = editing
        }
        // The three-finger tap lands on the multitouch thread; the monitor's
        // entry point is built for that (reads `held`, dispatches to main
        // itself) — no actor hop, so the monitor is captured directly.
        trackpadTap.setTapFingers(config.macroPadSummonFingers)
        trackpadTap.onTap = { monitor.trackpadThreeFingerTap() }
        trackpadTap.update(enabled: config.macroPad && config.macroPadThreeFingerTap)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isFinder = app?.bundleIdentifier == "com.apple.finder"
            let bundleID = app?.bundleIdentifier
            let appName = app?.localizedName
            Task { @MainActor in
                self?.hotkey?.finderFrontmost = isFinder
                self?.macroPad.frontmostChanged(bundleID: bundleID, name: appName)
            }
        }
        clipboardWatcher.start()
        windowSwitcher.dark = config.appearance.isDark
        windowSwitcher.start()
        // Grab & Move rides the same Accessibility grant as the hotkey tap;
        // a failure here is non-fatal (everything else still works).
        grabAndMove.update(enabled: config.grabAndMove, modifiers: config.grabMoveModifiers.flags)
        if !grabAndMove.start() { log("controller: Grab & Move tap unavailable") }
        // Agent Pad plumbing: the hook server runs whenever the feature is on
        // (session states accrue even while the panel is closed). Port changes
        // apply on relaunch; a failed bind is non-fatal.
        if config.agentPad {
            hookServer.onEvent = { [weak self] obj in
                Task { @MainActor in self?.claudeRegistry.ingest(obj) }
            }
            hookServer.sessionsJSON = { [weak self] in
                self?.claudeRegistry.pruneDead()  // a crashed claude never sent SessionEnd
                let list: [[String: Any]] = (self?.claudeRegistry.ordered ?? []).map { s in
                    ["id": s.id, "title": s.displayTitle, "project": s.projectName, "cwd": s.cwd,
                     "tty": s.tty, "state": s.state.label, "detail": s.detail, "host": s.hostBundleID]
                }
                return (try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])) ?? Data("[]".utf8)
            }
            if !hookServer.start(port: config.agentPadPort) {
                log("controller: Agent Pad server couldn't bind 127.0.0.1:\(config.agentPadPort)")
            }
            claudeRegistry.loadPersisted()      // survive our own restarts
            claudeRegistry.refreshDiscovered()  // find sessions that predate us
            // A pad the user closed stays closed across our own restarts. Set
            // this BEFORE onChange goes live (and only when a placement record
            // exists — a fresh install has never been closed), so boot itself
            // can't trip the auto-reveal.
            if let saved = PadPlacement.load("agent") { padClosedByUser = (saved.open != true) }
            claudeRegistry.onChange = { [weak self] sessions in
                guard let self else { return }
                self.agentPad.updateSessions(sessions, hooksInstalled: ClaudeHooksInstaller.isInstalled())
                self.notchStrip.refresh()
                self.revealAgentPadIfWaiting(sessions)
            }
            agentPad.onRefresh = { [weak self] in
                guard let self else { return }
                self.claudeRegistry.refreshDiscovered()
                self.refreshWatchers()
            }
            // Closing the pad is a decision, not a glitch — honor it until the
            // user opens the pad again themselves.
            agentPad.onDismiss = { [weak self] in self?.padClosedByUser = true }
        }
        startNotchStrip()
        // Surfaces are built lazily all over the app, so catch new ones as they
        // appear rather than making every call site remember to ask.
        CaptureVisibility.set(config.showInCaptures)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CaptureVisibility.applyIfWindowsChanged() }
            }
        // Pads that were open when the app last quit (updates included) come
        // back in their persisted dock/mini state.
        if config.restorePads {
            if config.macroPad, PadPlacement.load("macro")?.open == true, !macroPad.isVisible {
                toggleMacroPad()
            }
            if config.agentPad, PadPlacement.load("agent")?.open == true, !agentPad.isVisible {
                toggleAgentPad()
            }
        }
        log("controller: ready (hotkey \(config.hotkey.displayName), polish \(config.polish.rawValue))")
    }

    // MARK: Key events

    private func keyDown() {
        guard state == .idle else { return }
        winLastMove = nil; winStep = 0   // fresh window-cycle each hold
        chainH = nil; chainV = nil       // fresh chain each hold
        utterancePeak = 0
        snapAssistRegion = nil; snapAssistExcludeWID = nil
        let ctx = ContextSnapshot.capture()
        if ctx.isSecureField {
            overlay.showError("Secure input field — can't dictate here")
            return
        }
        // The notch Ask field is the target whenever it holds focus — checked
        // first, because the non-activating notch never shows as the frontmost
        // app, so `ctx.bundleID` would point at whatever is behind it.
        if notchStrip.acceptsDictation {
            dictatingIntoNotchAsk = true
            dictatingIntoCapture = false
        } else if ctx.bundleID == "com.grc.whisper" {
            // Exception: dictate INTO the Quick Capture panel when it's open,
            // rather than refusing (normal dictation pastes into another app).
            guard quickCapture.isVisible else {
                overlay.showError("Click into another app first, then hold to dictate")
                return
            }
            dictatingIntoCapture = true
            dictatingIntoNotchAsk = false
        } else {
            dictatingIntoCapture = false
            dictatingIntoNotchAsk = false
        }
        cycle += 1
        let gen = cycle
        context = ctx
        state = .recording
        onStateChange?(.recording)
        recordingStarted = Date()
        overlay.showRecording()
        // On a call (or with music playing), the speakers feed straight back
        // into the mic — mute output for exactly the duration of the hold.
        if config.muteWhileDictating { ducker.duck() }
        if config.polish == .apple { polisher.prewarm() }

        guard let format = audio.currentFormat, format.sampleRate > 0 else {
            fail("No audio input device")
            return
        }

        // From this instant, nothing captured may be dropped — the analyzer may
        // still be starting when the user finishes a short utterance.
        audio.beginHold()

        let utt = engineType.init(locale: Locale(identifier: config.localeIdentifier))
        utt.onPartial = { [weak self] text in
            Task { @MainActor in
                guard let self, self.cycle == gen, self.state == .recording else { return }
                self.overlay.showPartial(text)
            }
        }
        utterance = utt

        let st = Task.detached { try await utt.start() }
        startTask = st

        maxUtteranceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.maxUtteranceSeconds),
                                                 repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.cycle == gen, self.state == .recording else { return }
                log("controller: max utterance reached, finishing")
                self.keyUp(ai: false)
            }
        }

        let analyzerStarted = Date()
        Task { @MainActor in
            do {
                try await st.value
                guard self.cycle == gen, self.state == .recording else { return } // keyUp path takes over
                // Diagnostic: until streaming begins, the overlay can't show the
                // waveform (levels only flow while streaming) — a slow analyzer
                // start looks like "hints never swap" to the user.
                log("controller: analyzer ready in \(Int(Date().timeIntervalSince(analyzerStarted) * 1000))ms, streaming begins")
                self.audio.beginRecording { buffer in utt.feed(buffer) }
            } catch {
                guard self.cycle == gen else { return }
                self.fail("Speech engine failed: \(error.localizedDescription)")
            }
        }
    }

    private func keyUp(ai: Bool = false) {
        guard state == .recording, let utt = utterance else { return }
        ducker.restore()  // speakers back the instant the key lifts
        log(String(format: "controller: utterance peak level %.2f (waveform swap threshold 0.22)", utterancePeak))
        maxUtteranceTimer?.invalidate()
        let gen = cycle
        let heldMs = Int((Date().timeIntervalSince(recordingStarted ?? Date())) * 1000)
        let st = startTask

        if heldMs < config.minHoldMs {
            // Accidental tap.
            audio.endRecording()
            utterance = nil
            overlay.hide()
            finishCycle()
            Task.detached { try? await st?.value; await utt.cancel() }
            return
        }

        // Stop live feed only if streaming already began; in the raced case the
        // whole utterance still sits in the held ring and is flushed below.
        if audio.isStreaming { audio.endRecording() }

        state = .processing
        onStateChange?(.processing)
        overlay.showProcessing()
        let ctx = context
        let cfg = config

        Task { @MainActor in
            do {
                if let st { try await st.value }
            } catch {
                guard self.cycle == gen else { return }
                self.audio.endRecording()
                self.utterance = nil
                self.fail("Speech engine failed: \(error.localizedDescription)")
                return
            }
            guard self.cycle == gen else { return }

            // Race window: the key was released before the analyzer finished
            // starting, so beginRecording never ran. Flush the ring now and give
            // the audio queue a beat to drain into the analyzer.
            if !self.audio.isStreaming {
                self.audio.beginRecording { buffer in utt.feed(buffer) }
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.audio.endRecording()
            }
            guard self.cycle == gen else { return }

            do {
                let raw = try await utt.finish()
                guard self.cycle == gen else { return }
                self.utterance = nil
                guard !raw.isEmpty else {
                    self.overlay.showError("Didn't catch that")
                    self.finishCycle()
                    return
                }
                let appName = ctx?.appName ?? "unknown"
                if ai {
                    // AI leader opens Claude with what you said (never pastes a cleanup).
                    guard self.cycle == gen else { return }
                    self.overlay.hide()
                    if self.config.aiChatMode == .browser {
                        ClaudeWeb.open(raw)
                    } else {
                        self.openChat(with: raw)
                    }
                    self.finishCycle()
                    return
                }
                let final = await self.polisher.polish(raw, config: cfg, appName: appName)
                guard self.cycle == gen else { return }
                self.deliver(raw: raw, polished: final, durationMs: heldMs, ctx: ctx)
            } catch {
                guard self.cycle == gen else { return }
                self.utterance = nil
                self.fail("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func deliver(raw: String, polished: String, durationMs: Int, ctx: ContextSnapshot?) {
        lastTranscript = polished
        store.addHistory(app: ctx?.bundleID ?? "", raw: raw, polished: polished, durationMs: durationMs)
        if dictatingIntoNotchAsk {
            if notchStrip.acceptsDictation {
                notchStrip.insertDictation(polished)
                overlay.hide()   // the text is now in the Ask field; no paste toast
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(polished, forType: .string)
                overlay.showError("Ask closed — dictation copied to clipboard")
            }
            finishCycle()
            return
        }
        if dictatingIntoCapture {
            if quickCapture.isVisible {
                quickCapture.insertTranscript(polished)
                overlay.hide()   // the text is now visible in the panel; no paste toast
            } else {
                // Panel closed mid-dictation — don't paste into a random app; keep the text.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(polished, forType: .string)
                overlay.showError("Quick Capture closed — dictation copied to clipboard")
            }
            finishCycle()
            return
        }
        do {
            try Inserter.insert(polished, restoreDelayMs: config.clipboardRestoreDelayMs)
            overlay.showResult(polished)
        } catch {
            // Leave the text on the clipboard as a consolation so nothing is lost.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(polished, forType: .string)
            overlay.showError("\(error.localizedDescription) — copied to clipboard instead")
        }
        finishCycle()
    }

    /// Drop any in-flight dictation before a non-dictation leader action, so its
    /// transcript never lands: cancel a live recording, OR invalidate a cycle that's
    /// already .processing (finishCycle bumps `cycle`, so the pending deliver's
    /// `guard cycle == gen` fails and nothing is pasted).
    private func interruptDictation() {
        if state == .recording { cancel() }
        else if state == .processing { finishCycle() }
    }

    /// Cancel only interrupts an active recording (Esc / foreign keypress / stale
    /// hold). A cycle already in .processing is protected by the finish watchdog.
    private func cancel() {
        guard state == .recording else { return }
        ducker.restore()
        log(String(format: "controller: utterance peak level %.2f (canceled; waveform swap threshold 0.22)", utterancePeak))
        maxUtteranceTimer?.invalidate()
        audio.endRecording()
        let utt = utterance
        let st = startTask
        utterance = nil
        overlay.hide()
        finishCycle()
        if let utt {
            Task.detached { try? await st?.value; await utt.cancel() }
        }
    }

    private func fail(_ message: String) {
        log("controller: \(message)")
        ducker.restore()
        maxUtteranceTimer?.invalidate()
        audio.endRecording()
        utterance = nil
        overlay.showError(message)
        finishCycle()
    }

    /// OCR flow: let the user select a screen region, recognize text on-device,
    /// and paste it at the cursor (reuses the dictation paste + overlay).
    /// Screen recording is required for all screen grabs (the app is the
    /// responsible process even though the system tool captures). Prompt + open
    /// the pane if missing; the grant needs a quit & reopen to take effect.
    private func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        overlay.showError("Turn on Screen Recording for Power Tools, then quit & reopen the app")
        return false
    }

    private static func putImageOnClipboard(_ png: Data) {
        let pb = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// hold + T: OCR a screen region to the clipboard (tab-separated if it's a table).
    func captureScreenText() {
        guard state == .idle, ensureScreenRecording() else { return }
        state = .processing
        onStateChange?(.processing)
        Task {
            let png = await ScreenCapture.grabRegionPNG()
            await MainActor.run {
                defer { self.finishCycle() }
                guard let png else { return } // cancelled
                let text = ScreenCapture.ocr(png).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { self.overlay.showError("No text found in the selection"); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let preview = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                let short = preview.count > 60 ? String(preview.prefix(57)) + "…" : preview
                self.overlay.showResult("Copied to clipboard · \(short)")
                self.store.addHistory(app: "screen-ocr", raw: text, polished: text, durationMs: 0)
            }
        }
    }

    /// hold + R: read a screen region aloud — same grab + OCR as hold + T, but
    /// the text goes to the system voice instead of the clipboard. A second
    /// hold + R while it's talking stops it (Esc can't — by then the app is idle).
    func readScreenText() {
        if readAloud.isSpeaking {
            readAloud.stop()
            overlay.showResult("Stopped reading")
            return
        }
        guard state == .idle, ensureScreenRecording() else { return }
        state = .processing
        onStateChange?(.processing)
        Task {
            let png = await ScreenCapture.grabRegionPNG()
            await MainActor.run {
                defer { self.finishCycle() }
                guard let png else { return } // cancelled
                let text = ScreenCapture.ocr(png).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { self.overlay.showError("No text found in the selection"); return }
                self.readAloud.speak(ReadAloud.applyPronunciations(text, self.config.pronunciations))
                let preview = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                let short = preview.count > 60 ? String(preview.prefix(57)) + "…" : preview
                self.overlay.showResult("Reading aloud · \(short)")
                self.store.addHistory(app: "screen-read", raw: text, polished: text, durationMs: 0)
            }
        }
    }

    /// hold + S: copy a screen region as an image. hold + G: same, then open
    /// Google Lens for you to paste (⌘V) — we don't upload the image ourselves,
    /// so it only leaves your Mac when you choose to paste it into Google.
    func captureScreenshot(search: Bool) {
        guard state == .idle, ensureScreenRecording() else { return }
        state = .processing
        onStateChange?(.processing)
        overlay.showProcessing()
        Task {
            guard let png = await ScreenCapture.grabRegionPNG() else {
                await MainActor.run { self.finishCycle() }
                return
            }
            await MainActor.run {
                defer { self.finishCycle() }
                AppController.putImageOnClipboard(png)
                if search {
                    if let url = URL(string: "https://lens.google.com/") {
                        NSWorkspace.shared.open(url)
                    }
                    self.overlay.showResult("Image copied — press ⌘V in Google Lens to search")
                } else {
                    self.overlay.showResult("Screenshot copied to clipboard")
                }
            }
        }
    }

    /// hold + E: annotate. A clipboard image (e.g. the hold + S shot just taken)
    /// opens straight into the whiteboard; an empty clipboard falls back to a
    /// fresh region grab, so hold + E alone = shoot-then-annotate.
    func openWhiteboard() {
        overlay.hide()
        if whiteboard.isVisible { whiteboard.handleEscape(); return }  // toggle = Esc semantics
        guard config.whiteboard else {
            overlay.showError("Whiteboard is off — enable it in Settings ▸ General")
            return
        }
        if let png = ClipboardHistory.pngFromPasteboard(NSPasteboard.general) {
            presentWhiteboard(png: png)
            return
        }
        guard state == .idle, ensureScreenRecording() else { return }
        state = .processing
        onStateChange?(.processing)
        Task {
            let png = await ScreenCapture.grabRegionPNG()
            await MainActor.run {
                self.finishCycle()
                guard let png else { return } // selection cancelled
                self.presentWhiteboard(png: png)
            }
        }
    }

    private func presentWhiteboard(png: Data) {
        let priorApp = NSWorkspace.shared.frontmostApplication  // refocus target on close
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { return }
        whiteboard.present(
            png: png, dark: config.appearance.isDark, screen: screen,
            onSave: { [weak self] out in
                AppController.putImageOnClipboard(out)  // clip history records it, same as hold + S
                self?.overlay.showResult("Annotated screenshot copied to clipboard")
                priorApp?.activate()
            },
            onCancel: { priorApp?.activate() })
    }

    /// hold + K: screen color picker. Show the system loupe; when a color comes
    /// back, offer a palette of formats (HEX/RGB/HSL/HSV/CMYK…) and copy the one
    /// picked to the clipboard, logging it to history. Cancelling is silent.
    private func pickColor() {
        guard state == .idle else { return }
        overlay.hide()
        ColorPicker.pick { [weak self] color in
            guard let self, let color else { return }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            guard let screen else { return }
            self.colorPalette.present(
                color: color, dark: self.config.appearance.isDark, screen: screen,
                onPick: { fmt in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fmt.value, forType: .string)
                    self.overlay.showResult("Copied \(fmt.value)")
                    self.store.addHistory(app: "color-picker", raw: fmt.value, polished: fmt.value, durationMs: 0)
                },
                onCancel: { }
            )
        }
    }

    /// hold + P: transform the clipboard text before pasting. Capture the clipboard
    /// + target app NOW (before the palette steals focus), then paste into the app.
    private func openAdvancedPaste() {
        interruptDictation()
        overlay.hide()
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clip.isEmpty else { overlay.showError("Copy some text first, then hold + P"); return }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.grc.whisper" else {
            overlay.showError("Click into a text field first, then hold + P"); return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        advancedPaste.present(
            clipboard: clip, dark: config.appearance.isDark, screen: screen,
            onPick: { t in self.applyAdvancedPaste(t, clip: clip, app: app) },
            onCancel: { app.activate() }
        )
    }

    private func applyAdvancedPaste(_ t: AdvancedPaste.Transform, clip: String, app: NSRunningApplication) {
        func paste(_ text: String) {
            app.activate()
            // let focus land in the target field before the synthetic ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) {
                try? Inserter.insert(text, restoreDelayMs: self.config.clipboardRestoreDelayMs)
            }
        }
        guard t.ai, let instruction = t.instruction else { paste(t.localTransform?(clip) ?? clip); return }  // plain text / case
        guard let key = Keychain.get("claude"), !key.isEmpty else {
            overlay.showError("Add a Claude key in Settings ▸ AI to use AI paste"); app.activate(); return
        }
        overlay.showProcessing()
        let model = config.claudeModel
        Task {
            do {
                let out = try await CloudPolish.claude(instructions: instruction, prompt: clip, model: model, apiKey: key)
                await MainActor.run { self.overlay.hide(); paste(out) }
            } catch {
                await MainActor.run { self.overlay.showError("Paste transform failed"); app.activate() }
            }
        }
    }

    /// hold + B (or menu bar): toggle the floating per-app macro pad. The pad
    /// is a persistent non-activating panel — clicking its buttons leaves the
    /// frontmost app focused, so the macro keystrokes land there.
    func toggleMacroPad() {
        interruptDictation()
        if macroPad.isVisible { macroPad.dismiss(); return }
        presentMacroPad(at: nil)
    }

    /// hold + three-finger tap on the trackpad: the pad beside the cursor for
    /// ONE macro. Hidden → opens there; docked → moves there; already summoned
    /// → the summon ends (back to its berth, or away if it was closed).
    func summonMacroPad() {
        interruptDictation()
        if macroPad.isVisible {
            if macroPad.isSummoned { macroPad.endSummon(); return }
            overlay.hide()
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main else { return }
            macroPad.summon(to: mouse, on: screen)
            return
        }
        presentMacroPad(at: NSEvent.mouseLocation)
    }

    /// Shared open path: `cursor` nil = the pad's berth, non-nil = summoned there.
    private func presentMacroPad(at cursor: NSPoint?) {
        guard config.macroPad else {
            overlay.showError("Macro Pad is off — enable it in Settings ▸ Macro Pad")
            return
        }
        overlay.hide()
        let app = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        macroPad.present(
            profiles: config.macroPadProfiles, dark: config.appearance.isDark, screen: screen,
            hotkeyName: config.hotkey.displayName, frontApp: app, at: cursor,
            onAction: { [weak self] button, bundleID in self?.runMacroButton(button, targetBundleID: bundleID) }
        )
        // Keyword suggestions ride on SCK window capture — without the Screen
        // Recording grant they'd silently never light up. Ask + explain once.
        let hasKeywords = config.macroPadProfiles.contains { profile in
            profile.buttons.contains { !$0.keywords.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        if hasKeywords, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            overlay.showError("Keyword suggestions need Screen Recording — grant it in Privacy & Security, then quit & reopen")
        }
    }

    /// hold + J (or menu bar): toggle the Agent Pad — the floating Claude Code
    /// session panel. Non-activating like the macro pad, so clicking a row's
    /// buttons leaves the user's app focused unless the action itself focuses
    /// a terminal.
    /// hold + Q: toggle the hotkey cheat sheet.
    func toggleCheatSheet() {
        interruptDictation()
        overlay.hide()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let conns = config.connections
            .filter { !$0.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (key: $0.leaderKey, name: $0.name) }
        cheatSheet.toggle(dark: config.appearance.isDark, screen: screen,
                          hotkeyName: config.hotkey.displayName, connections: conns)
    }

    /// hold + right-click: the Power Ring at the cursor, slots from config
    /// (Settings ▸ Power Ring designs them).
    func togglePowerRing() {
        interruptDictation()
        overlay.hide()
        guard config.powerRing else { return }
        if powerRing.isVisible { powerRing.dismiss(); return }
        let actions = config.powerRingSlots.compactMap { id -> PowerRing.Action? in
            guard let entry = PowerRingCatalog.entry(id), let run = ringRun(id) else { return nil }
            return .init(glyph: entry.glyph, title: entry.title, run: run)
        }
        powerRing.present(at: NSEvent.mouseLocation, dark: config.appearance.isDark, actions: actions)
    }

    /// Catalog id → the action it fires. Additions here need a PowerRingCatalog
    /// entry (and vice versa) or the slot silently drops out of the ring.
    private func ringRun(_ id: String) -> (() -> Void)? {
        switch id {
        case "screenText": return { [weak self] in self?.captureScreenText() }
        case "screenshot": return { [weak self] in self?.captureScreenshot(search: false) }
        case "search": return { [weak self] in self?.captureScreenshot(search: true) }
        case "whiteboard": return { [weak self] in self?.openWhiteboard() }
        case "clipboard": return { [weak self] in self?.openClipboardHistory() }
        case "pasteAs": return { [weak self] in self?.openAdvancedPaste() }
        case "readAloud": return { [weak self] in self?.readScreenText() }
        case "color": return { [weak self] in self?.pickColor() }
        case "findMouse": return { [weak self] in self?.findMouse.flash() }
        case "newDoc": return { [weak self] in self?.openNewDocMenu() }
        case "grid": return { [weak self] in self?.openGrid() }
        case "palette": return { [weak self] in self?.openWindowPalette() }
        case "macroPad": return { [weak self] in self?.toggleMacroPad() }
        case "agentPad": return { [weak self] in self?.toggleAgentPad() }
        case "cheatSheet": return { [weak self] in self?.toggleCheatSheet() }
        default: return nil
        }
    }

    /// The user closed the pad. Closing is final: nothing reopens it — not a
    /// pending permission, not a new one, not a restart — until the user opens
    /// it again from the hotkey, the menu bar, or the Power Ring. (The mini
    /// traffic-light strip is a separate thing: an open-but-collapsed pad
    /// still maxes itself for a permission.) Persisted via the pad's own
    /// placement record, so it survives quits.
    private var padClosedByUser = false

    /// Reveal the Agent Pad when a session needs the user's approval — this
    /// maxes the one pad surface instead of spawning a separate popup for
    /// permissions. Only ever fires on a pad the user hasn't closed.
    ///
    /// Gated when the notch strip is carrying agents: the strip already banners
    /// the ask with ✓/✕ on it, and flinging the whole pad open as well is two
    /// notifications for one event.
    private func revealAgentPadIfWaiting(_ sessions: [ClaudeSession]) {
        guard !stripShowsAgents else { return }
        guard config.agentPad, !padClosedByUser, !agentPad.isVisible,
              sessions.contains(where: { $0.state == .needsPermission }) else { return }
        openAgentPad(on: NSScreen.main)
    }

    private var stripShowsAgents: Bool { config.notchStrip && config.notchAgents }

    // MARK: Notch strip

    /// The sessions the strip publishes — same visibility, triage AND
    /// enrichment the pad uses, so a dot and its row are never a different set.
    /// The enrichment step was missing here once, and every notch row drew its
    /// model chip, branch and spend as empty.
    private var stripSessions: [ClaudeSession] {
        AgentPad.triageSorted(AgentPad.visible(claudeRegistry.ordered)).map(AgentPad.enriched)
    }

    /// Line 3 of a notch row: what a running session is doing right now, the
    /// ask or the error while it waits — and nothing at all when it is idle.
    static func activityLine(for s: ClaudeSession) -> String {
        switch s.state {
        case .busy:
            return s.activity ?? ""
        case .needsPermission, .needsInput, .error:
            return s.detail.isEmpty ? "" : s.detail.replacingOccurrences(of: "\n", with: " ")
        case .idle, .unseen:
            return ""
        }
    }

    /// "28 msgs · 50.4k tok", with a + on both when the transcript was folded
    /// from its tail and the counts are lower bounds.
    static func metricsLine(for s: ClaudeSession) -> String {
        guard s.msgs > 0 else { return "" }
        let plus = s.statsPartial == true ? "+" : ""
        return "\(s.msgs)\(plus) msgs · \(compactTokens(s.tokens))\(plus) tok"
    }

    /// The watch-only fleets (Codex, Cursor, Grok Bot) re-derive their rows
    /// from disk on request. Until now only the OPEN Agent Pad asked them to,
    /// so with the pad closed the notch showed a stale or empty fleet.
    private func refreshWatchers() {
        if config.agentPadCodex { CodexWatcher.refresh(into: claudeRegistry) }
        if config.agentPadCursor { CursorWatcher.refresh(into: claudeRegistry) }
        if config.agentPadGrok { GrokBotWatcher.refresh(into: claudeRegistry) }
    }
    private var watcherTimer: Timer?

    private func startNotchStrip() {
        // Pads that were parked in the notch move to an ordinary anchor — the
        // strip is the only citizen of the housing now. What was in the notch
        // stays in the notch, as a published mark.
        if !config.notchStripMigrated {
            let moved = PadPlacement.migrateNotchAnchors()
            if moved.contains("agent") { config.notchAgents = true; config.notchStrip = true }
            config.notchStripMigrated = true
            config.save()
            if !moved.isEmpty { log("notch: migrated \(moved.sorted().joined(separator: ", ")) off the berths") }
        }

        notchStrip.onLog = { msg in log(msg) }
        notchStrip.register(NotchStrip.Source(
            id: "agents", priority: 0, maxMarks: 5,
            marks: { [weak self] in
                (self?.stripSessions ?? []).map { s in
                    NotchStrip.Mark(
                        color: AgentPadView.stateColor(s.state),
                        // The colour already says needs-you (terracotta / red);
                        // a white ring on top read as a second, different
                        // signal. The ring is a quota-only cue now.
                        ring: false,
                        dim: s.state == .idle && s.stateChanged.timeIntervalSinceNow < -3600,
                        tooltip: "\(s.projectName) · \(s.state.label)")
                }
            },
            card: { [weak self] i in
                guard let self, i < self.stripSessions.count else { return nil }
                let s = self.stripSessions[i]
                var card = NotchStrip.Card(
                    title: s.label,
                    subtitle: Self.activityLine(for: s),
                    accent: AgentPadView.stateColor(s.state),
                    repo: s.projectName,
                    state: s.state.chip,
                    model: s.model,
                    branch: s.branch,
                    metrics: Self.metricsLine(for: s))
                card.icon = AgentPad.agentIcon(for: s)
                card.kind = s.kindChip
                // A session idle past the pad's threshold folds under Recent
                // too, though its process is still alive — and like a finished
                // one it reads "how long ago", not "how long running".
                card.isRecent = AgentPad.isRecent(s)
                card.elapsed = card.isRecent
                    ? Elapsed.format(Date().timeIntervalSince(s.stateChanged)) + " ago"
                    : Elapsed.format(Date().timeIntervalSince(s.startedAt ?? s.started))
                // The whole reason Mid exists: answer the ask without opening
                // anything. Only a permission gets buttons.
                // The same controls the pad's rows carry, so the notch is not a
                // read-only copy of it. Watch-only agents (Codex, Cursor) have
                // no injection channel, so they get none — as in the pad.
                if !s.isWatchOnly {
                    if s.state == .needsPermission {
                        card.actionsAlways = true
                        card.actions = [
                            ("✓", NSColor(srgbRed: 0.35, green: 0.75, blue: 0.45, alpha: 1),
                             { [weak self] in self?.handleAgentPadAction(s, .accept) }),
                            ("✕", NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1),
                             { [weak self] in self?.handleAgentPadAction(s, .deny) }),
                        ]
                    } else {
                        card.actions = [
                            ("✱", nil, { [weak self] in self?.popNotchRowMenu(for: s) }),
                            ("✎", nil, { [weak self] in self?.handleAgentPadAction(s, .prompt) }),
                            ("⇆", nil, { [weak self] in self?.handleAgentPadAction(s, .cycleMode) }),
                            ("■", nil, { [weak self] in self?.handleAgentPadAction(s, .interrupt) }),
                        ]
                    }
                }
                return card
            },
            // Row click = focus that session's terminal, the same thing the
            // pad's own row click does. The notch does not launch the pad.
            activate: { [weak self] i in
                guard let self, i >= 0, i < self.stripSessions.count else { return }
                self.handleAgentPadAction(self.stripSessions[i], .focus)
            },
            // The band header: how many rows want attention or are working.
            header: { [weak self] in
                let live = self?.stripSessions ?? []
                let active = live.filter {
                    $0.state == .busy || $0.state == .needsPermission || $0.state == .needsInput
                }.count
                return (title: "Agents", active: active)
            },
            // Finished sessions, under the Recent divider: what just wrapped up.
            recent: { [weak self] in
                (self?.claudeRegistry.recentEnded ?? []).map { s in
                    var card = NotchStrip.Card(
                        title: s.label, subtitle: "", accent: NSColor(white: 0.55, alpha: 1),
                        repo: s.projectName, state: "", model: s.model, branch: s.branch,
                        metrics: Self.metricsLine(for: s))
                    card.icon = AgentPad.agentIcon(for: s)
                    card.kind = s.kindChip
                    card.elapsed = s.endedAt.map { Elapsed.format(Date().timeIntervalSince($0)) + " ago" } ?? ""
                    return card
                }
            },
            // The ↻ in the band: drop dead rows, catch sessions the hooks missed.
            refresh: { [weak self] in
                self?.claudeRegistry.pruneDead()
                self?.claudeRegistry.refreshDiscovered()
                self?.refreshWatchers()
            }))

        notchStrip.register(NotchStrip.Source(
            id: "quota", priority: 10, maxMarks: 1,
            marks: { [weak self] in
                guard let self, let worst = Self.worstQuota() else { return [] }
                // Silent until it is news: a dot parked in the menu bar
                // permanently is exactly the flourish this app avoids.
                guard worst >= self.config.notchQuotaAt else { return [] }
                let color = worst >= 90 ? NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1)
                                        : NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
                let stale = (UsageReader.shared.fetchedAt.map { Date().timeIntervalSince($0) > 7200 }) ?? true
                return [NotchStrip.Mark(color: color, ring: worst >= 90, dim: stale,
                                        tooltip: "quota \(worst)% used")]
            },
            card: { _ in
                guard let worst = Self.worstQuota() else { return nil }
                let window = UsageReader.shared.providers
                    .flatMap { p in p.windows.map { (p.name, $0) } }
                    .max { $0.1.usedPercent < $1.1.usedPercent }
                return NotchStrip.Card(
                    title: "",
                    subtitle: window?.1.resetDescription ?? "",
                    accent: worst >= 90 ? NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1)
                                        : NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                    repo: "Quota",
                    state: "\(worst)%",
                    metrics: [window?.0, window?.1.label].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " · "))
            },
            // Quota's detail already lives on its row; a click just closes.
            activate: { _ in }))

        registerNotchModules()

        // ONE owner for the reader's single update closure, fanned out here.
        UsageReader.shared.onUpdate = { [weak self] in
            self?.agentPad.usageDidUpdate()
            self?.notchStrip.refresh()
        }
        applyNotchConfig()
        notchStrip.start()
        // The notch shows the fleet without the pad, so the watchers need a
        // heartbeat of their own — 10s like the pad's tick, only while the
        // notch's agents source is on.
        watcherTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.config.notchStrip, self.config.notchAgents else { return }
                self.refreshWatchers()
            }
        }
        refreshWatchers()
    }

    /// Panels the notch hosts. Order here is the order in the module row.
    private func registerNotchModules() {
        let all: [(String, NotchStrip.Module)] = [
            ("usage", .init(id: "usage", glyph: "◔", title: "Usage", height: 230) {
                UsageModuleView()
            }),
            ("hotkeys", .init(id: "hotkeys", glyph: "⌨", title: "Hotkeys", height: 300) { [weak self] in
                // Same shape toggleCheatSheet builds, so the module and the
                // hold+Q sheet can never drift apart.
                let conns = (self?.config.connections ?? [])
                    .filter { !$0.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { (key: $0.leaderKey, name: $0.name) }
                return HotkeysModuleView(hotkeyName: self?.config.hotkey.displayName ?? "hotkey",
                                         connections: conns)
            }),
            ("snap", .init(id: "snap", glyph: "▦", title: "Snap", height: 210) {
                SnapModuleView()
            }),
            ("clock", .init(id: "clock", glyph: "◷", title: "Clock", height: 150) { [weak self] in
                ClockModuleView(zones: self?.config.notchClockZones ?? [])
            }),
            ("calendar", .init(id: "calendar", glyph: "▤", title: "Calendar", height: 216) {
                CalendarModuleView(frame: .zero)
            }),
            ("weather", .init(id: "weather", glyph: "☀", title: "Weather", height: 270) { [weak self] in
                WeatherModuleView(places: self?.config.weatherPlaces ?? [],
                                  fahrenheit: self?.config.weatherFahrenheit ?? true)
            }),
            ("chat", .init(id: "chat", glyph: "✦", title: "Ask", height: 200, make: { [weak self] in
                ChatModuleView(model: self?.config.claudeModel ?? "claude-haiku-4-5",
                               openFull: { [weak self] text in self?.openChat(with: text) })
            }, wantsKeyboard: true)),
        ]
        for (id, module) in all where config.notchModules.contains(id) {
            notchStrip.registerModule(module)
        }
        // Agent Pad is a LIST tile: hovering it shows the agent list right in
        // the notch (the same view a session dot opens); only when the agents
        // source is switched off does it fall back to toggling the floating
        // pad. Macro Pad is an ACTION tile: a floating panel with its own dock,
        // so the tile toggles it and folds the notch, as hold+B does. Neither
        // is gated: a notch on screen should always be able to reach them.
        notchStrip.registerModule(NotchStrip.Module(
            id: "agentpad", glyph: "◫", title: "Agent Pad", height: 0,
            make: { NSView() },
            open: { [weak self] in self?.toggleAgentPad() },
            list: "agents"))
        notchStrip.registerModule(NotchStrip.Module(
            id: "macropad", glyph: "⊞", title: "Macro Pad", height: 0,
            make: { NSView() },
            open: { [weak self] in self?.toggleMacroPad() }))
        // Settings rides LAST and is not gated — a notch that is on screen at
        // all should always offer a way into its own settings. An action tile,
        // not a hosted module: it opens the real 860pt window and folds the
        // notch away. Routed through the responder chain to AppDelegate, the
        // same path the menu-bar "Settings…" item takes.
        notchStrip.registerModule(NotchStrip.Module(
            id: "settings", glyph: "⚙", title: "Settings", height: 0,
            make: { NSView() },
            open: { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }))
    }

    /// The ✱ menu for a notch row. Built here rather than borrowed from the
    /// pad: the pad's version pops inside its own view and routes through an
    /// `onAction` closure that only exists while the pad is presented, so a
    /// notch-only user would get a menu whose items did nothing.
    private func popNotchRowMenu(for session: ClaudeSession) {
        let menu = NSMenu()
        let header = NSMenuItem(title: session.displayTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        if !session.isWatchOnly {
            for (title, alias) in [("Switch to Opus 4.8", "opus"),
                                   ("Switch to Sonnet 5", "sonnet"),
                                   ("Switch to Haiku 4.5", "haiku")] {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = alias
                item.target = nil
                menu.addItem(item)
                item.isEnabled = true
                item.action = #selector(NotchMenuTarget.fire(_:))
            }
            menu.addItem(.separator())
            let picker = NSMenuItem(title: "Model & Effort Picker…", action: #selector(NotchMenuTarget.fire(_:)), keyEquivalent: "")
            picker.representedObject = "picker"
            menu.addItem(picker)
            menu.addItem(.separator())
        }
        let close = NSMenuItem(title: "Close Chat", action: #selector(NotchMenuTarget.fire(_:)), keyEquivalent: "")
        close.representedObject = "close"
        menu.addItem(close)

        let target = NotchMenuTarget { [weak self] key in
            guard let self else { return }
            switch key {
            case "picker": self.handleAgentPadAction(session, .modelPicker)
            case "close": self.handleAgentPadAction(session, .closeChat)
            default: self.handleAgentPadAction(session, .setModel(key))
            }
        }
        notchMenuTarget = target   // menus don't retain their target
        for item in menu.items where item.action != nil { item.target = target }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// 50421 → "50.4k" — same shortening the pad's rows use.
    private static func compactTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private static func worstQuota() -> Int? {
        UsageReader.shared.providers.flatMap(\.windows).map(\.usedPercent).max()
    }

    func applyNotchConfig() {
        var on: Set<String> = []
        if config.notchAgents { on.insert("agents") }
        if config.notchQuota { on.insert("quota") }
        notchStrip.apply(master: config.notchStrip, enabled: on)
    }


    func toggleAgentPad() {
        interruptDictation()
        if agentPad.isVisible {
            agentPad.dismiss()   // onDismiss snapshots what was waiting — it stays closed
            return
        }
        guard config.agentPad else {
            overlay.showError("Agent Pad is off — enable it in Settings ▸ Agent Pad")
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        openAgentPad(on: screen)
    }

    /// Build and show the Agent Pad panel. Shared by the manual hotkey/menu
    /// toggle and the automatic reveal when a permission needs the user.
    private func openAgentPad(on screen: NSScreen?) {
        overlay.hide()
        padClosedByUser = false   // pad is up again — auto-reveal is back in play
        claudeRegistry.pruneDead()
        claudeRegistry.refreshDiscovered()  // catch silent sessions on every open
        refreshWatchers()
        guard let screen else { return }
        agentPad.present(
            sessions: claudeRegistry.ordered, dark: config.appearance.isDark, screen: screen,
            hotkeyName: config.hotkey.displayName, hooksInstalled: ClaudeHooksInstaller.isInstalled(),
            onAction: { [weak self] session, action in self?.handleAgentPadAction(session, action) }
        )
    }

    private func handleAgentPadAction(_ session: ClaudeSession, _ action: AgentPad.Action) {
        // Watch-only rows (Codex, Cursor): focus and close are the whole
        // surface — there is no injection channel into an Electron app.
        if session.isWatchOnly {
            switch action {
            case .focus:
                log("agentpad: row click → focus \(session.kind ?? "?") \(session.displayTitle)")
                if session.isGrok { GrokBotWatcher.focus() } else if session.isCursor { CursorWatcher.focus() } else { CodexWatcher.focus() }
                overlay.showResult("→ \(session.displayTitle)")
            case .closeChat:
                claudeRegistry.dismissSession(session.id)
                overlay.showResult("Closed · \(session.displayTitle)")
            default:
                break
            }
            return
        }
        switch action {
        case .focus:
            log("agentpad: row click → focus \(session.projectName) [\(session.id.prefix(8))]")
            ClaudeInjector.focus(session)
            overlay.showResult("→ \(session.projectName)")
        case .accept:
            ClaudeInjector.sendControl(session, .acceptYes) { [weak self] err in
                if let err { self?.overlay.showError("Approve failed — \(err)") }
                else { self?.overlay.showSuccess("Approved · \(session.projectName)") }
            }
        case .deny:
            ClaudeInjector.sendControl(session, .denyEscape) { [weak self] err in
                if let err { self?.overlay.showError("Deny failed — \(err)") }
                else { self?.overlay.showResult("Denied · \(session.projectName)") }
            }
        case .cycleMode:
            ClaudeInjector.sendControl(session, .cycleMode) { [weak self] err in
                if let err { self?.overlay.showError("Mode switch failed — \(err)") }
            }
        case .interrupt:
            ClaudeInjector.sendControl(session, .interrupt) { [weak self] err in
                if let err { self?.overlay.showError("Interrupt failed — \(err)") }
                else { self?.overlay.showResult("Interrupted · \(session.projectName)") }
            }
        case .prompt:
            openAgentPrompt(session)
        case .closeChat:
            claudeRegistry.dismissSession(session.id)
            overlay.showResult("Closed · \(session.projectName)")
        case .setModel(let alias):
            ClaudeInjector.send(session, text: "/model \(alias)") { [weak self] err in
                if let err { self?.overlay.showError("Model switch failed — \(err)") }
                else { self?.overlay.showSuccess("/model \(alias) → \(session.projectName)") }
            }
        case .modelPicker:
            // The /model dialog carries the effort selector; put the session in
            // front so the arrow keys land in it.
            ClaudeInjector.focus(session)
            ClaudeInjector.send(session, text: "/model") { [weak self] err in
                if let err { self?.overlay.showError("Couldn't open the picker — \(err)") }
            }
        case .modelMenu:
            break   // consumed in the view — the ✱ button pops the menu itself
        }
    }

    /// The prompt box for a session — the Quick Capture panel, so typing AND
    /// hold-to-dictate both already work. Submit types the text into the
    /// session's terminal and presses Return.
    private func openAgentPrompt(_ session: ClaudeSession) {
        interruptDictation()
        overlay.hide()
        let priorApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        quickCapture.present(
            dark: config.appearance.isDark, screen: screen, title: "→ \(session.projectName)",
            onSubmit: { [weak self] text in
                ClaudeInjector.send(session, text: text) { err in
                    if let err {
                        self?.overlay.showError("Send failed — \(err)")
                    } else {
                        self?.overlay.showSuccess("Sent → \(session.projectName)")
                        priorApp?.activate()
                    }
                }
            },
            onCancel: { priorApp?.activate() }
        )
    }

    /// Menu action: merge the Agent Pad hooks into ~/.claude/settings.json.
    func installClaudeHooks() {
        do {
            let summary = try ClaudeHooksInstaller.install(port: config.agentPadPort)
            overlay.showSuccess("Claude Code hooks installed")
            log("controller: \(summary)")
        } catch {
            overlay.showError("Hook install failed: \(error.localizedDescription)")
        }
    }

    /// hold + digit while the pad is open: fire that button without clicking.
    private func fireMacroPadDigit(_ index: Int) {
        // The leader-down already started a recording — drop it, or release
        // would leave the state machine wedged in .recording (windowMode
        // release dispatches .windowEnd, never .up/.cancel).
        interruptDictation()
        // Same funnel as a click: key handoff → onAction (runMacroButton) →
        // fire-once for a summoned pad.
        macroPad.fireButton(index)
    }

    /// Runs are chained so rapid leader-digit fires queue and execute in order
    /// — two macros must never interleave their synthesized keystrokes.
    private var macroChain: Task<Void, Never>?

    /// Run one macro button: an "open" step — chord, or a `menuPath` clicked
    /// via Accessibility when the app has no shortcut for the action — then
    /// (delay) → typed text → (delay) → Return. Focus can drift between
    /// render and click, so the profile's app is re-activated first if
    /// something else slipped in front.
    private func runMacroButton(_ button: Config.MacroButton, targetBundleID: String) {
        let stepMs = max(config.macroPadStepDelayMs, 100)
        let menuPath = button.menuPath.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // A hand-edited profile with a typo'd chord must abort — skipping just
        // the chord would type the folder name + Return straight into the email.
        let chord = MacroPad.parseChord(button.chord)
        if !button.chord.isEmpty, chord == nil {
            overlay.showError("Macro “\(button.title)” has an unrecognized chord — fix it in config.json")
            return
        }
        let prev = macroChain
        macroChain = Task { @MainActor in
            await prev?.value
            // The trigger may still be physically held (a leader digit, or a
            // habit-held ⌥⇧ after a click) — synthesized keystrokes must not
            // inherit it. Abort loudly rather than post a polluted chord.
            guard await self.modifiersCleared(timeout: 8) else {
                self.overlay.showError("“\(button.title)” skipped — a modifier key never released")
                return
            }
            guard let target = NSRunningApplication
                .runningApplications(withBundleIdentifier: targetBundleID).first else {
                self.overlay.showError("\(targetBundleID) isn't running")
                return
            }
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != targetBundleID {
                target.activate()
                try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
            }
            let pid = target.processIdentifier
            // Off the main actor (awaited, so the chain stays serial):
            // typeText/postKey pace themselves with usleep, which must not
            // stall the app's UI mid-macro.
            await Task.detached(priority: .userInitiated) { [weak self] in
                if !menuPath.isEmpty, !button.text.isEmpty {
                    // A menu with a folder name to hit (Outlook's Move): click
                    // the matching submenu item directly rather than typing —
                    // an open menu treats keystrokes as item-jump, not a
                    // filter, so typing here can land on the wrong command.
                    switch Inserter.clickMenuItemMatching(pid: pid, path: menuPath, name: button.text) {
                    case .matched:
                        return   // the click alone completed the move
                    case .openedPicker:
                        break    // a real dialog is open now — type into it below
                    case .notFound:
                        if let self {
                            await MainActor.run {
                                self.overlay.showError("“\(button.title)” — couldn't find “\(button.text)” under \(menuPath.joined(separator: " ▸ "))")
                            }
                        }
                        return
                    }
                } else if !menuPath.isEmpty {
                    guard Inserter.clickMenuItem(pid: pid, path: menuPath) else {
                        if let self {
                            await MainActor.run {
                                self.overlay.showError("“\(button.title)” — couldn't find \(menuPath.joined(separator: " ▸ ")) in the menu bar")
                            }
                        }
                        return
                    }
                } else if let chord {
                    Inserter.postKey(chord.key, flags: chord.flags)
                }
                if !button.text.isEmpty {
                    try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
                    Inserter.typeText(button.text)
                }
                if button.pressReturn {
                    try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
                    Inserter.postKey(CGKeyCode(36 /* kVK_Return */), flags: [])
                }
            }.value
        }
    }

    /// True once no physical modifier (Fn included) remains down. While the
    /// leader hotkey itself is still held this waits INDEFINITELY — queued
    /// leader-digit macros must flush whenever the user finally lets go, no
    /// matter how long they kept filing. The timeout only counts once the
    /// leader is up (a stuck-flags guard, not a patience limit).
    private func modifiersCleared(timeout: TimeInterval) async -> Bool {
        var deadline = Date().addingTimeInterval(timeout)
        while true {
            let f = CGEventSource.flagsState(.combinedSessionState)
            let down = f.contains(.maskShift) || f.contains(.maskCommand)
                    || f.contains(.maskControl) || f.contains(.maskAlternate)
                    || f.contains(.maskSecondaryFn)
            if !down { return true }
            if hotkey?.held == true { deadline = Date().addingTimeInterval(timeout) }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Build the tap's keyCode→connectionId leader map from the configured
    /// connections (skipping any with an unusable leader letter).
    static func leaderMap(_ conns: [Config.Connection]) -> [Int64: String] {
        var m: [Int64: String] = [:]
        for c in conns where !c.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let kc = HotkeyMonitor.keyCode(forLetter: c.leaderKey) { m[kc] = c.id }
        }
        return m
    }

    /// hold + D: a small menu of document types at the cursor. The chosen blank
    /// doc is created in the frontmost Finder window's folder, then revealed and
    /// selected so it can be renamed. Reading the Finder folder uses Apple Events
    /// (an Automation prompt the first time).
    private func openNewDocMenu() {
        let folder = NewDocTemplates.currentFinderFolder()
        guard let folder else {
            overlay.showError("Open a Finder window first (or allow Automation for Finder)")
            return
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "New Document in \(folder.lastPathComponent)", action: nil, keyEquivalent: "")
            .isEnabled = false
        menu.addItem(.separator())
        for (i, type) in NewDocTemplates.DocType.allCases.enumerated() {
            let item = NSMenuItem(title: type.menuTitle, action: #selector(createNewDoc(_:)),
                                  keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.representedObject = ["type": type.rawValue, "folder": folder.path]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func createNewDoc(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let raw = info["type"], let type = NewDocTemplates.DocType(rawValue: raw),
              let path = info["folder"] else { return }
        do {
            let url = try NewDocTemplates.create(type, in: URL(fileURLWithPath: path, isDirectory: true))
            NSWorkspace.shared.activateFileViewerSelecting([url])   // reveal + select in Finder
            overlay.showSuccess("Created \(url.lastPathComponent)")
        } catch {
            overlay.showError("Couldn't create the document: \(error.localizedDescription)")
        }
    }

    /// hold + <leader>: Quick Capture for a specific connection. Open a small input
    /// panel; the typed/dictated line is POSTed to that connection's endpoint. The
    /// frontmost app is remembered so focus returns to it.
    private func openQuickCapture(connectionId: String) {
        interruptDictation()
        overlay.hide()
        guard let conn = config.connections.first(where: { $0.id == connectionId }),
              !conn.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlay.showError("Set up this connection in Settings ▸ Connections")
            return
        }
        let priorApp = NSWorkspace.shared.frontmostApplication
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        quickCapture.present(
            dark: config.appearance.isDark, screen: screen, title: conn.name,
            onSubmit: { text in self.sendCapture(text, connection: conn, restore: priorApp) },
            onCancel: { priorApp?.activate() }
        )
    }

    /// POST the captured text to a connection. On success, a green toast and focus
    /// returns to the app you were in. On failure, re-open the panel pre-filled so
    /// the text isn't lost — no automatic retry (the endpoint has no idempotency key).
    private func sendCapture(_ text: String, connection conn: Config.Connection, restore: NSRunningApplication?) {
        let header = conn.authHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = Keychain.get(conn.tokenAccount) ?? ""
        // Inline fields: "call Rhett tomorrow p1 @calls" → title/priority/due/context.
        let parsed = CaptureParse.parse(text)
        overlay.showProcessing()
        Task {
            do {
                try await CloudPolish.postCapture(text: parsed.title, endpoint: conn.endpoint, header: header,
                                                  token: token, bodyTemplate: conn.bodyTemplate,
                                                  priority: parsed.priority, due: parsed.due,
                                                  dueTS: parsed.dueTS, context: parsed.context)
                await MainActor.run {
                    let extras = CaptureParse.summary(parsed)
                    self.overlay.showSuccess("Captured  \(parsed.title)\(extras.isEmpty ? "" : "  ·  \(extras)")")
                    restore?.activate()
                }
            } catch {
                await MainActor.run {
                    self.overlay.showError("\(conn.name) capture failed — check Settings ▸ Connections")
                    let mouse = NSEvent.mouseLocation
                    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
                    if let screen {
                        self.quickCapture.present(
                            dark: self.config.appearance.isDark, screen: screen, title: conn.name, prefill: text,
                            onSubmit: { t in self.sendCapture(t, connection: conn, restore: restore) },
                            onCancel: { restore?.activate() }
                        )
                    }
                }
            }
        }
    }

    /// hold + H: clipboard history palette. Capture the target app NOW (before the
    /// palette steals focus); the picked clip pastes there and stays on the
    /// clipboard (Win+V semantics).
    private func openClipboardHistory() {
        interruptDictation()
        overlay.hide()
        guard config.clipboardHistory else {
            overlay.showError("Clipboard history is off — enable it in Settings ▸ General")
            return
        }
        let clips = store.recentClips(9)
        guard !clips.isEmpty else {
            overlay.showError("No clipboard history yet — copy something first")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.grc.whisper" else {
            overlay.showError("Click into a text field first, then hold + H")
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        clipboardPalette.present(
            clips: clips, dark: config.appearance.isDark, screen: screen,
            onPick: { clip in
                app.activate()
                // let focus land back in the target field before the synthetic ⌘V
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) {
                    if let png = clip.image {
                        Inserter.pasteImageLeavingOnClipboard(png)
                        self.store.addImageClip(png, label: clip.content)  // moves to the top
                    } else {
                        Inserter.pasteLeavingOnClipboard(clip.content)
                        self.store.addClip(clip.content)
                    }
                }
            },
            onCancel: { app.activate() }
        )
    }

    enum FileOp { case copy, cut, paste }

    /// hold + C / X / V: copy, cut (copy + mark for move), or paste files. Paste is a
    /// Finder "Move Item Here" (⌥⌘V) if the last action was a cut, else a plain ⌘V.
    /// A short delay lets the physical hotkey modifiers lift before we synthesize.
    /// hotkey + 3: capture the front window NOW (before the grid steals focus),
    /// then show a full-screen grid to draw where it goes.
    private func openGrid() {
        interruptDictation()
        overlay.hide()
        snapAssistRegion = nil; snapAssistExcludeWID = nil  // the grid replaces snap-assist for this hold
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.grc.whisper",
              let window = WindowManager.frontmostWindow() else {
            overlay.showError("Click into a window first, then hold + 3")
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        gridOverlay.present(
            screen: screen, cols: config.gridSize.cols, rows: config.gridSize.rows,
            dark: config.appearance.isDark,
            snap: { rect in WindowManager.setWindow(window, cocoaFrame: rect) },
            done: { app.activate() }
        )
    }

    /// hold + W: Moom-style snap palette — Fill/halves (⌥ quarters), thirds, and a
    /// mini-grid. Capture the front window NOW, before the palette steals focus.
    private func openWindowPalette() {
        interruptDictation()
        overlay.hide()
        snapAssistRegion = nil; snapAssistExcludeWID = nil  // the palette replaces snap-assist for this hold
        guard config.windowPalette else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != "com.grc.whisper",
              let target = WindowManager.frontmostWindow() else {
            overlay.showError("Click into a window first, then hold + W")
            return
        }
        guard let screen = WindowManager.screen(of: target) ?? NSScreen.main else { return }
        let chips = store.layouts(3).map { entry -> (entry: LayoutEntry, label: String) in
            let count = WindowLayouts.decode(entry.json).count
            return (entry, "\(entry.name) · \(count)w")
        }
        windowPalette.present(
            dark: config.appearance.isDark,
            gridCols: config.gridSize.cols, gridRows: config.gridSize.rows,
            target: target, screen: screen,
            layouts: chips,
            onSaveLayout: { [weak self] in
                guard let self else { return }
                let items = WindowLayouts.snapshot()
                guard !items.isEmpty else { self.overlay.showError("No windows to save"); return }
                let f = DateFormatter()
                f.dateFormat = "MMM d · h:mm a"
                self.store.addLayout(name: f.string(from: Date()), json: WindowLayouts.encode(items))
                self.overlay.showResult("Layout saved · \(items.count) windows")
                app.activate()
            },
            onRestoreLayout: { [weak self] entry in
                let r = WindowLayouts.restore(WindowLayouts.decode(entry.json))
                self?.overlay.showResult("Restored \(r.restored) of \(r.total) windows")
            },
            done: { app.activate() }
        )
    }

    /// Arrow/Return in window mode. Fires on each keydown; repeating the same
    /// direction cycles the size (½ → ⅓ → ⅔) so "tap ← ←" shrinks the left snap.
    private func handleWindow(_ move: WindowManager.Move) {
        interruptDictation()
        if move == .maximize {
            winLastMove = nil; winStep = 0; snapAssistRegion = nil  // no empty space to fill
            chainH = nil; chainV = nil
            if WindowManager.maximize() {
                overlay.showWindow(region: CGRect(x: 0, y: 0, width: 1, height: 1), label: "Maximize")
            } else { overlay.showError("No window to move") }
            return
        }
        let steps = config.snapSizes.steps
        if move == winLastMove {
            let next = (winStep + 1) % steps.count
            // Chained-corner unwind: cycling the same arrow past its last size
            // clears that axis and returns to the other axis's plain snap
            // (← ↑↑↑… goes ¼ → ⅓ → ⅔ → … → full-height Left ½ → ¼ …), so a
            // chain always cycles back out instead of trapping the window.
            let isVertical = (move == .up || move == .down)
            if next == 0, isVertical, chainV != nil, let h = chainH {
                chainV = nil
                winLastMove = nil
                applyEdgeSnap(edge: h.edge, f: h.f, fracLabel: h.label)
                return
            }
            if next == 0, !isVertical, chainH != nil, let v = chainV {
                chainH = nil
                winLastMove = nil
                applyEdgeSnap(edge: v.edge, f: v.f, fracLabel: v.label)
                return
            }
            winStep = next
        } else { winStep = 0; winLastMove = move }
        let (f, fracLabel) = steps[winStep]

        // Chain bookkeeping: remember this axis's constraint. If the OTHER axis
        // was already snapped this hold, the two combine into a corner (Moom's
        // "← then ↑ = top-left"). Same-axis repeats keep cycling sizes as before.
        switch move {
        case .left:     chainH = (.left, f, fracLabel)
        case .right:    chainH = (.right, f, fracLabel)
        case .up:       chainV = (.top, f, fracLabel)
        case .down:     chainV = (.bottom, f, fracLabel)
        case .maximize: return
        }
        if let h = chainH, let v = chainV {
            guard WindowManager.snapCorner(hEdge: h.edge, hFraction: h.f,
                                           vEdge: v.edge, vFraction: v.f) != nil else {
                overlay.showError("No window to move"); return
            }
            // The empty complement of a corner is L-shaped — Snap Assist sits out.
            snapAssistRegion = nil; snapAssistExcludeWID = nil
            let region = CGRect(x: h.edge == .left ? 0 : 1 - h.f,
                                y: v.edge == .top ? 0 : 1 - v.f,
                                width: h.f, height: v.f)
            let corner = "\(v.edge == .top ? "Top" : "Bottom") \(h.edge == .left ? "Left" : "Right")"
            let label = (h.f == 0.5 && v.f == 0.5) ? "\(corner) ¼" : "\(corner) \(h.label) × \(v.label)"
            overlay.showWindow(region: region, label: label)
            return
        }

        let edge: WindowManager.Edge
        switch move {
        case .left:  edge = .left
        case .right: edge = .right
        case .up:    edge = .top
        case .down:  edge = .bottom
        case .maximize: return
        }
        applyEdgeSnap(edge: edge, f: f, fracLabel: fracLabel)
    }

    /// Plain single-edge snap + Snap Assist bookkeeping + HUD (shared by the
    /// normal arrow path and the chained-corner unwind).
    private func applyEdgeSnap(edge: WindowManager.Edge, f: CGFloat, fracLabel: String) {
        let region: CGRect
        let name: String
        switch edge {
        case .left:   region = CGRect(x: 0, y: 0, width: f, height: 1);     name = "Left"
        case .right:  region = CGRect(x: 1 - f, y: 0, width: f, height: 1); name = "Right"
        case .top:    region = CGRect(x: 0, y: 0, width: 1, height: f);     name = "Top"
        case .bottom: region = CGRect(x: 0, y: 1 - f, width: 1, height: f); name = "Bottom"
        }
        guard let result = WindowManager.snap(edge: edge, fraction: f) else {
            overlay.showError("No window to move"); return
        }
        // Stash the empty (complement) region so Snap Assist can offer it on release.
        let vf = result.screen.visibleFrame
        let comp: CGRect
        switch edge {
        case .left:   comp = CGRect(x: vf.minX + vf.width * f, y: vf.minY, width: vf.width * (1 - f), height: vf.height)
        case .right:  comp = CGRect(x: vf.minX, y: vf.minY, width: vf.width * (1 - f), height: vf.height)
        case .top:    comp = CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: vf.height * (1 - f))
        case .bottom: comp = CGRect(x: vf.minX, y: vf.maxY - vf.height * (1 - f), width: vf.width, height: vf.height * (1 - f))
        }
        // Only offer Snap Assist if we reliably know the snapped window's ID (else
        // we couldn't exclude it and it'd appear in — and get re-snapped by — its
        // own picker).
        if let wid = result.windowID {
            snapAssistRegion = comp
            snapAssistExcludeWID = wid
        } else {
            snapAssistRegion = nil
            snapAssistExcludeWID = nil
        }
        overlay.showWindow(region: region, label: "\(name) \(fracLabel)")
    }

    /// After the hotkey is released post-snap: offer the other on-screen windows to
    /// fill the empty side (Windows-style). Off if disabled or the gap is tiny.
    private func maybeSnapAssist() {
        guard config.snapAssist, let region = snapAssistRegion, let exclude = snapAssistExcludeWID else {
            snapAssistRegion = nil; snapAssistExcludeWID = nil; return
        }
        snapAssistRegion = nil; snapAssistExcludeWID = nil
        guard region.width > 120, region.height > 100 else { return }
        // The app whose window we just snapped — restore focus to it on cancel so
        // Power Tools (a .regular Dock app) isn't left wedged frontmost.
        let prevApp = NSWorkspace.shared.frontmostApplication
        snapAssist.present(
            in: region, excluding: exclude, dark: config.appearance.isDark,
            onPick: { cand in
                guard let ax = WindowManager.axWindow(pid: cand.pid, windowID: cand.windowID) else {
                    self.overlay.showError("Couldn't move that window")
                    prevApp?.activate()
                    return
                }
                NSRunningApplication(processIdentifier: cand.pid)?.activate()
                WindowManager.setWindow(ax, cocoaFrame: region)
                WindowManager.raise(ax)
            },
            onCancel: { prevApp?.activate() }
        )
    }

    private func fileClipboard(_ op: FileOp) {
        // File ops don't touch the dictation state machine; the caller already
        // cancels an active recording, so don't drop the op while .processing.
        let move = (op == .paste) && fileCutPending
        let label: String
        switch op {
        case .copy:  fileCutPending = false; label = "Copied"
        case .cut:   fileCutPending = true;  label = "Cut — hold + V to move it"
        case .paste: fileCutPending = false; label = move ? "Moved" : "Pasted"
        }
        overlay.showResult(label)
        // Wait until the physical hotkey modifiers are released before synthesizing,
        // or a still-held Shift/Ctrl leaks in (Shift+⌘C = Finder "Go to Computer", etc.).
        afterModifiersClear {
            switch op {
            case .copy, .cut: Inserter.fileCopy()
            case .paste: Inserter.filePaste(move: move)
            }
        }
    }

    /// Run `action` once no physical Shift/Command/Control/Option remains held (or
    /// after a timeout), so a synthesized keystroke isn't polluted by the hotkey.
    private func afterModifiersClear(timeout: TimeInterval = 0.8, _ action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            while true {
                let f = CGEventSource.flagsState(.combinedSessionState)
                let held = f.contains(.maskShift) || f.contains(.maskCommand)
                        || f.contains(.maskControl) || f.contains(.maskAlternate)
                if !held || Date() >= deadline { action(); return }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    /// Open (or focus) the AI chat window. Optionally seed it with a message and send.
    func openChat(with text: String = "") {
        if chat == nil { chat = ChatWindowController(config: config) }
        chat?.updateConfig(config)
        chat?.present()
        if !text.isEmpty { chat?.send(text) }
    }

    private func finishCycle() {
        cycle += 1 // invalidate any straggler continuations from this cycle
        state = .idle
        context = nil
        recordingStarted = nil
        startTask = nil
        dictatingIntoCapture = false
        dictatingIntoNotchAsk = false
        onStateChange?(.idle)
    }
}
