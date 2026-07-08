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

    /// Escape a string for embedding inside a JSON string literal (the chars JSON
    /// requires: quote, backslash, control chars). Used so arbitrary capture text
    /// can be spliced into a `%TEXT%` placeholder without breaking the JSON body.
    static func jsonEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// Unix seconds for a "due today" date as grc-todo / Toodledo expect it: UTC
    /// midnight of the *local* calendar day. The app formats a task's date with
    /// toISOString() (UTC) and compares it to the local today string, so a task is
    /// "today" only when its timestamp is UTC-midnight of the local Y/M/D.
    static func todayDueDate() -> Int {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let ymd = local.dateComponents([.year, .month, .day], from: Date())
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnightUTC = utc.date(from: ymd) ?? Date()
        return Int(midnightUTC.timeIntervalSince1970)
    }

    /// Generic authenticated POST for the Quick Capture "connection" — POST a line
    /// of text to any endpoint the user configures. The request body is built from
    /// `bodyTemplate` by replacing `%TEXT%` with the JSON-escaped text (so quotes /
    /// newlines survive) and `%TODAY%` with today's due-date timestamp. `header`
    /// empty → no auth header sent. Any 2xx is success; the built body is validated
    /// as JSON first so a bad template fails clearly.
    static func postCapture(text: String, endpoint: String, header: String, token: String, bodyTemplate: String,
                            priority: String = "", due: String = "", dueTS: Int = 0, context: String = "") async throws {
        guard let url = URL(string: endpoint), url.scheme != nil else { throw CloudError.badResponse }
        var bodyString = bodyTemplate.replacingOccurrences(of: "%TEXT%", with: jsonEscape(text))
        bodyString = bodyString.replacingOccurrences(of: "%TODAY%", with: String(todayDueDate()))
        // Parsed-field placeholders (all optional in templates). %PRIORITY%
        // defaults to "0" so numeric JSON fields stay valid without a token;
        // %DUE% / %CONTEXT% become empty strings when absent.
        bodyString = bodyString.replacingOccurrences(of: "%PRIORITY%", with: priority.isEmpty ? "0" : jsonEscape(priority))
        bodyString = bodyString.replacingOccurrences(of: "%DUE%", with: jsonEscape(due))
        // Numeric due (Toodledo/grc-todo convention): the parsed day's timestamp,
        // or today's when no date was said — same default as %TODAY%.
        bodyString = bodyString.replacingOccurrences(of: "%DUE_TS%", with: String(dueTS > 0 ? dueTS : todayDueDate()))
        bodyString = bodyString.replacingOccurrences(of: "%CONTEXT%", with: jsonEscape(context))
        let bodyData = Data(bodyString.utf8)
        // Fail fast on a malformed template rather than sending garbage the server
        // would reject with an opaque 400.
        guard (try? JSONSerialization.jsonObject(with: bodyData)) != nil else { throw CloudError.badResponse }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !header.isEmpty, !token.isEmpty { req.setValue(token, forHTTPHeaderField: header) }
        req.httpBody = bodyData

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
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
