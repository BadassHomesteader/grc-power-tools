import Foundation
import AppKit
import Vision

/// Screenshot → text. Uses the system `screencapture -i` selector (so the app
/// needs no Screen Recording grant of its own — the system tool captures and
/// writes a file, which we then OCR with the on-device Vision framework).
/// Fully local: no network, no cloud.
enum ScreenTextCapture {
    /// Returns the recognized text, "" if the selection had none, or nil if the
    /// user cancelled the selection (Esc).
    static func capture() async -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grc-ocr-\(UUID().uuidString).png")
        let captured = await runScreencapture(to: tmp)
        guard captured, FileManager.default.fileExists(atPath: tmp.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return ocr(url: tmp)
    }

    private static func runScreencapture(to url: URL) async -> Bool {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-i", "-x", url.path] // interactive region, no sound
            proc.terminationHandler = { p in cont.resume(returning: p.terminationStatus == 0) }
            do { try proc.run() } catch {
                log("ocr: screencapture launch failed: \(error)")
                cont.resume(returning: false)
            }
        }
    }

    private static func ocr(url: URL) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log("ocr: recognition failed: \(error)")
            return ""
        }
        let lines = (request.results ?? []).compactMap {
            ($0 as? VNRecognizedTextObservation)?.topCandidates(1).first?.string
        }
        return lines.joined(separator: "\n")
    }
}
