import Foundation
import AVFoundation

/// Speaks text through the system voice — the voice side of hold + R (screen
/// region → OCR → speech). Fully on-device via AVSpeechSynthesizer; needs no
/// permission. Enhanced/Premium voices the user downloads in System Settings ▸
/// Accessibility ▸ Spoken Content are picked up automatically.
@MainActor
final class ReadAloud {
    private let synth = AVSpeechSynthesizer()

    var isSpeaking: Bool { synth.isSpeaking }

    /// Start speaking, replacing whatever was already being spoken.
    func speak(_ text: String) {
        stop()
        synth.speak(AVSpeechUtterance(string: text))
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
