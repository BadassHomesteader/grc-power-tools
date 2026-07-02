import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import Speech
import FoundationModels
import Carbon.HIToolbox

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
                ? "running as GRC Whisper.app (TCC grants will stick)"
                : "running as a bare binary — permissions attach to the parent app; build and use GRC Whisper.app for real use"
        ))

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        checks.append(Check(
            name: "Microphone",
            ok: micStatus == .authorized,
            detail: "status: \(micStatus.label)" + (micStatus == .notDetermined ? " (will prompt on first use)" : "")
        ))

        let ax = AXIsProcessTrusted()
        checks.append(Check(
            name: "Accessibility",
            ok: ax,
            detail: ax ? "granted" : "needed for the hotkey tap + paste — System Settings ▸ Privacy & Security ▸ Accessibility (if it already shows enabled after a rebuild, toggle it off and on — ad-hoc signatures invalidate the grant)"
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

        let secure = IsSecureEventInputEnabled()
        checks.append(Check(
            name: "Secure input",
            ok: !secure,
            detail: secure
                ? "another app holds secure keyboard input (password field / Terminal secure entry) — dictation is blocked while it does"
                : "inactive"
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

    static func report() async -> String {
        let checks = await run()
        var lines = ["GRC Whisper doctor:"]
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
