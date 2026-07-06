import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import Speech
import FoundationModels
import Carbon.HIToolbox
import CoreGraphics

/// Permission / environment diagnostics. Used by the `doctor` CLI subcommand
/// and the menu-bar "Permission Doctor" item.
enum Doctor {
    struct Check {
        let name: String
        let ok: Bool
        let detail: String
    }

    static func run() async -> [Check] {
        var checks: [Check] = []

        let bundled = Bundle.main.bundleIdentifier == "com.grc.whisper"
        checks.append(Check(
            name: "App bundle",
            ok: bundled,
            detail: bundled
                ? "running as Power Tools.app (TCC grants will stick)"
                : "running as a bare binary — permissions attach to the parent app; build and use Power Tools.app for real use"
        ))

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        checks.append(Check(
            name: "Microphone",
            ok: micStatus == .authorized,
            detail: "status: \(micStatus.label)" + (micStatus == .notDetermined ? " (will prompt on first use)" : "")
        ))

        // AXIsProcessTrusted() can report a STALE "granted" after a rebuild while the
        // event tap still can't be created — so test the real thing: try to make a
        // tap that can alter events (same requirement the hotkey needs).
        let axTrusted = AXIsProcessTrusted()
        let tapWorks = Doctor.canCreateEventTap()
        checks.append(Check(
            name: "Accessibility",
            ok: tapWorks,
            detail: tapWorks
                ? "granted (event tap verified)"
                : (axTrusted
                    ? "shows enabled but the event tap CANNOT be created — a rebuild invalidated the grant. In System Settings ▸ Privacy & Security ▸ Accessibility, select Power Tools, click −, then relaunch and re-enable it."
                    : "not granted — add Power Tools in System Settings ▸ Privacy & Security ▸ Accessibility")
        ))

        let listen = CGPreflightListenEventAccess()
        checks.append(Check(
            name: "Input Monitoring",
            ok: listen,
            detail: listen ? "granted" : "may be requested for the keyboard listener — System Settings ▸ Privacy & Security ▸ Input Monitoring"
        ))

        let globe = globeKeyAction()
        checks.append(Check(
            name: "Globe key setting",
            ok: globe == 0,
            detail: globe == 0
                ? "'Press 🌐 key' is set to Do Nothing"
                : "System Settings ▸ Keyboard ▸ 'Press 🌐 key' should be 'Do Nothing' or macOS will fight the Fn hotkey (current mode: \(globe))"
        ))

        let screen = CGPreflightScreenCaptureAccess()
        checks.append(Check(
            name: "Screen Recording (OCR)",
            ok: screen,
            detail: screen ? "granted" : "needed for screenshot→text (⌥⌘T) — System Settings ▸ Privacy & Security ▸ Screen Recording"
        ))

        let secure = IsSecureEventInputEnabled()
        checks.append(Check(
            name: "Secure input",
            ok: true, // informational: this flag no longer blocks dictation
            detail: secure
                ? "system secure-input flag is set (usually held by loginwindow) — harmless; dictation only pauses when you focus an actual password field"
                : "clear"
        ))

        let locale = Locale(identifier: Config.load().localeIdentifier)
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        let haveLocale = installed.contains(locale.identifier(.bcp47))
        checks.append(Check(
            name: "Speech model (\(locale.identifier))",
            ok: haveLocale,
            detail: haveLocale ? "installed" : "will download on first run (system-managed asset)"
        ))

        let lm = SystemLanguageModel.default.availability == .available
        checks.append(Check(
            name: "Apple Intelligence LLM",
            ok: lm,
            detail: lm ? "available for AI polish" : "unavailable — polish falls back to basic cleanup (enable Apple Intelligence in System Settings)"
        ))

        return checks
    }

    /// True if a tap that can alter events can be created — the actual capability
    /// the hotkey needs, which AXIsProcessTrusted() does not reliably reflect.
    static func canCreateEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return false }
        CFMachPortInvalidate(tap)
        return true
    }

    static func report() async -> String {
        let checks = await run()
        var lines = ["Power Tools doctor:"]
        for c in checks {
            lines.append("  [\(c.ok ? "OK" : "!!")] \(c.name): \(c.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

extension AVAuthorizationStatus {
    var label: String {
        switch self {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}
