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

    /// Apply the user's pronunciation fixes (config `pronunciations`): each key
    /// is replaced by its respelling, case-insensitively, only at word
    /// boundaries ("SQL" never fires inside "MySQLdb"). Longest keys win first
    /// so "New York City" beats "New York". Lookarounds instead of \b so keys
    /// ending in symbols ("C#") still bound correctly.
    nonisolated static func applyPronunciations(_ text: String, _ map: [String: String]) -> String {
        guard !map.isEmpty else { return text }
        var out = text
        for (word, spoken) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let pattern = "(?<![A-Za-z0-9])\(NSRegularExpression.escapedPattern(for: trimmed))(?![A-Za-z0-9])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: NSRegularExpression.escapedTemplate(for: spoken))
        }
        return out
    }
}
