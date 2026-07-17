import Foundation
import AppKit
import Vision

/// Screen-region capture and everything we do with a grab: OCR (with table
/// reconstruction), plain screenshot, and Google Lens search. Uses the system
/// `screencapture -i` selector; OCR runs on-device via Vision.
enum ScreenCapture {
    /// Interactive region selection → PNG data (nil if the user cancelled).
    /// Requires the app to hold Screen Recording permission.
    static func grabRegionPNG() async -> Data? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grc-shot-\(UUID().uuidString).png")
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", tmp.path] // interactive region, no sound
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus == 0) }
            do { try p.run() } catch {
                log("capture: screencapture launch failed: \(error)")
                cont.resume(returning: false)
            }
        }
        guard ok, FileManager.default.fileExists(atPath: tmp.path),
              let data = try? Data(contentsOf: tmp), !data.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: tmp)
        return data
    }

    // MARK: OCR

    /// On-device OCR. If the layout looks tabular, returns tab-separated rows
    /// (pastes into Excel/Sheets/Numbers as a grid); otherwise plain lines.
    static func ocr(_ png: Data) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(data: png, options: [:]).perform([request])
        } catch {
            log("ocr: recognition failed: \(error)")
            return ""
        }
        return reconstruct(request.results ?? [])
    }

    private struct Fragment { let text: String; let x: CGFloat; let y: CGFloat; let h: CGFloat }

    private static func reconstruct(_ obs: [VNRecognizedTextObservation]) -> String {
        let frags: [Fragment] = obs.compactMap {
            guard let s = $0.topCandidates(1).first?.string else { return nil }
            let b = $0.boundingBox // normalized, origin bottom-left
            return Fragment(text: s, x: b.minX, y: b.midY, h: b.height)
        }
        guard !frags.isEmpty else { return "" }

        // Group into rows by vertical position (top to bottom).
        let sorted = frags.sorted { $0.y > $1.y }
        var rows: [[Fragment]] = []
        for f in sorted {
            if let ref = rows.last?.first, abs(ref.y - f.y) < max(ref.h, f.h) * 0.6 {
                rows[rows.count - 1].append(f)
            } else {
                rows.append([f])
            }
        }
        let ordered = rows.map { $0.sorted { $0.x < $1.x } }

        // Tabular if several rows have multiple columns → tab-separated.
        let multiCol = ordered.filter { $0.count >= 2 }.count
        if multiCol >= 2 {
            return ordered.map { row in row.map(\.text).joined(separator: "\t") }.joined(separator: "\n")
        }
        return ordered.map { row in row.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    // MARK: Google Lens

    /// Upload the image to Google and return the Lens results page URL.
    static func googleLensURL(_ png: Data) async -> URL? {
        var req = URLRequest(url: URL(string: "https://www.google.com/searchbyimage/upload")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        let boundary = "grcw\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ s: String) { body.append(s.data(using: .utf8)!) }
        field("--\(boundary)\r\n")
        field("Content-Disposition: form-data; name=\"encoded_image\"; filename=\"image.png\"\r\n")
        field("Content-Type: image/png\r\n\r\n")
        body.append(png)
        field("\r\n--\(boundary)\r\n")
        field("Content-Disposition: form-data; name=\"image_content\"\r\n\r\n\r\n")
        field("--\(boundary)--\r\n")
        req.httpBody = body

        // Read the 30x Location without following it.
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse,
               let loc = http.value(forHTTPHeaderField: "Location"), let url = URL(string: loc) {
                return url
            }
            return resp.url
        } catch {
            log("lens: upload failed: \(error)")
            return nil
        }
    }
}

/// Captures the redirect target instead of following it.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
