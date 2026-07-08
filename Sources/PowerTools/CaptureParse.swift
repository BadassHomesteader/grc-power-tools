import Foundation

/// Inline field parsing for Quick Capture (Todoist-style, dictation-friendly):
///   "follow up with Rhett tomorrow p1 @calls"
///     → title "follow up with Rhett", priority "1", due "2026-07-09", context "calls"
///
/// Tokens are stripped from the title; anything not recognized stays put.
/// - priority: p0–p3 as a standalone word (case-insensitive)
/// - context:  @word (first one wins)
/// - due date: natural language via NSDataDetector ("tomorrow", "friday",
///             "july 12", "in 3 days"), emitted as yyyy-MM-dd
enum CaptureParse {
    struct Parsed {
        var title: String
        var priority: String   // "" when absent
        var due: String        // yyyy-MM-dd or ""
        var dueTS: Int         // midnight-UTC-of-local-day seconds (grc-todo/Toodledo format), 0 when absent
        var context: String    // "" when absent
    }

    static func parse(_ text: String) -> Parsed {
        var working = text

        // Priority: standalone p0–p3.
        var priority = ""
        if let m = firstMatch("(?i)(?<=^|\\s)p([0-3])(?=\\s|$)", in: working) {
            priority = String(working[m].dropFirst()).trimmingCharacters(in: .whitespaces)
            working.removeSubrange(m)
        }

        // Context: first @word.
        var context = ""
        if let m = firstMatch("(?<=^|\\s)@([A-Za-z0-9_-]+)", in: working) {
            context = String(working[m].dropFirst())
            working.removeSubrange(m)
        }

        // Due date: NSDataDetector over what's left. Only accept matches at a
        // word boundary and only strip the matched phrase (plus an immediately
        // preceding "due"/"by"/"on" connector, which reads as part of it).
        var due = ""
        var dueTS = 0
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = working as NSString
            if let match = detector.firstMatch(in: working, range: NSRange(location: 0, length: ns.length)),
               let date = match.date {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                due = f.string(from: date)
                dueTS = timestamp(for: date)
                var strip = match.range
                let before = ns.substring(to: strip.location)
                for connector in ["due ", "by ", "on "] {
                    if before.lowercased().hasSuffix(connector) {
                        strip = NSRange(location: strip.location - connector.count,
                                        length: strip.length + connector.count)
                        break
                    }
                }
                if let r = Range(strip, in: working) { working.removeSubrange(r) }
            }
        }

        let title = working
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(title: title.isEmpty ? text : title, priority: priority, due: due, dueTS: dueTS, context: context)
    }

    /// Same convention as CloudPolish.todayDueDate(): midnight UTC of the LOCAL
    /// calendar day, in seconds — the Toodledo/grc-todo due-date format.
    private static func timestamp(for date: Date) -> Int {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let ymd = local.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return Int((utc.date(from: ymd) ?? date).timeIntervalSince1970)
    }

    /// One-line human summary for the capture panel's hint ("" when nothing parsed).
    static func summary(_ p: Parsed) -> String {
        var bits: [String] = []
        if !p.priority.isEmpty { bits.append("P\(p.priority)") }
        if !p.due.isEmpty { bits.append("due \(p.due)") }
        if !p.context.isEmpty { bits.append("@\(p.context)") }
        return bits.joined(separator: " · ")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Range<String.Index>? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Range(m.range, in: text)
    }
}
