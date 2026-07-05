import Foundation

/// Optional cloud cleanup backends. Only ever called when the user explicitly
/// selects the Claude or OpenAI engine and provides their own API key. Only the
/// transcript TEXT is sent — never audio. Transcription always stays on-device.
enum CloudPolish {
    enum CloudError: Error, LocalizedError {
        case http(Int, String)
        case refused
        case badResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, _): return "HTTP \(code)"
            case .refused: return "model refused"
            case .badResponse: return "unexpected response"
            }
        }
    }

    /// Anthropic Messages API (raw HTTPS — Swift has no official SDK).
    /// Sampling params and `thinking` are omitted so any model (Haiku…Opus/Fable) is accepted.
    static func claude(instructions: String, prompt: String, model: String, apiKey: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": instructions,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
        guard http.statusCode == 200 else {
            throw CloudError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.badResponse
        }
        if (json["stop_reason"] as? String) == "refusal" { throw CloudError.refused }
        guard let content = json["content"] as? [[String: Any]] else { throw CloudError.badResponse }
        let text = content.compactMap { block -> String? in
            (block["type"] as? String) == "text" ? block["text"] as? String : nil
        }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudError.badResponse }
        return trimmed
    }

    /// Streaming multi-turn chat against the Anthropic Messages API. `messages` is
    /// the full conversation ([{role, content}] alternating user/assistant). The
    /// running assistant text is delivered to `onUpdate` as tokens arrive; the full
    /// final text is returned. Only text is ever sent — this is the AI-chat backend.
    static func claudeChatStream(
        messages: [[String: String]], system: String, model: String, apiKey: String,
        onUpdate: @escaping (String) -> Void
    ) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "stream": true,
            "system": system,
            "messages": messages,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            throw CloudError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        var acc = ""
        var completed = false   // saw a terminal event, so `acc` is the whole reply
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any], let t = delta["text"] as? String {
                    acc += t
                    onUpdate(acc)
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], let stop = delta["stop_reason"] as? String {
                    if stop == "refusal" { throw CloudError.refused }
                    completed = true   // end_turn / max_tokens / stop_sequence
                }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                throw CloudError.http(0, msg)
            case "message_stop":
                completed = true
            default:
                continue
            }
            if type == "message_stop" { break }
        }
        // If the stream ended without a terminal event, the body was cut off
        // (proxy idle-timeout, truncation) — don't pass a partial answer off as final.
        guard completed else { throw CloudError.http(0, "stream ended before completion") }
        let trimmed = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudError.badResponse }
        return trimmed
    }

    /// OpenAI Chat Completions.
    static func openai(instructions: String, prompt: String, model: String, apiKey: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
        guard http.statusCode == 200 else {
            throw CloudError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw CloudError.badResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudError.badResponse }
        return trimmed
    }
}
