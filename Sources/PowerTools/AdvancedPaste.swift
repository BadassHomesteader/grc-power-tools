import Cocoa

/// What was on the clipboard when hold + P was pressed — read once, before the
/// drawer opens, so nothing that happens later can change what gets pasted.
struct PasteInput {
    let text: String       // plain-text flavor, trimmed; "" when only an image was copied
    let html: String?
    let rtf: Data?
    let image: Data?       // PNG or TIFF straight off the pasteboard (Vision reads both)

    var hasRich: Bool { (html?.isEmpty == false) || rtf != nil }
    var isEmpty: Bool { text.isEmpty && image == nil }

    static func read(_ pb: NSPasteboard = .general) -> PasteInput {
        PasteInput(
            text: pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            html: pb.string(forType: .html),
            rtf: pb.data(forType: .rtf),
            image: pb.data(forType: .png) ?? pb.data(forType: .tiff))
    }
}

/// What a transform produces.
enum PasteResult {
    case text(String)
    case rich(text: String, flavors: [(NSPasteboard.PasteboardType, Data)])
    case failure(String)   // nothing to paste — the message says why
}

/// Advanced Paste: hold hotkey + P → a drawer of ways to reshape the clipboard
/// before it lands (plain, formatted without dark-theme colors, Markdown →
/// formatted, table → Excel cells, lists, extracts, case, AI…). hold + P then a
/// letter pastes one of them with no drawer at all.
enum AdvancedPaste {
    enum Group: String, CaseIterable { case format = "Format", text = "Text", data = "Data", ai = "AI" }
    /// What a transform needs on the clipboard; rows that can't run are hidden.
    enum Needs { case text, rich, image }
    enum Kind {
        case local((PasteInput) -> String?)   // instant, offline; nil = nothing found → failure(emptyMessage)
        case uncolor(emailFont: Bool)         // formatted paste minus theme colors (and fonts)
        case markdown                         // Markdown text → real formatting
        case ocr                              // text out of a copied image
        case ai(String)                       // Claude system prompt
    }

    struct Transform {
        let id: String
        let title: String
        let subtitle: String
        let icon: String          // SF Symbol
        let group: Group
        let key: Character?       // hold + P, then this letter → paste it, no drawer
        let keywords: String      // more words the drawer's filter matches
        let needs: Needs
        let kind: Kind
        var emptyMessage = "Nothing to change on the clipboard"

        var isAI: Bool { if case .ai = kind { return true }; return false }
        var isRich: Bool {
            switch kind { case .uncolor, .markdown: return true; default: return false }
        }
    }

    private static func t(_ f: @escaping (String) -> String) -> Kind { .local { f($0.text) } }
    private static func tOpt(_ f: @escaping (String) -> String?) -> Kind { .local { f($0.text) } }

    static let transforms: [Transform] = [
        // Format
        Transform(id: "plain", title: "Plain text", subtitle: "strip all formatting", icon: "textformat",
                  group: .format, key: "P", keywords: "unformatted values", needs: .text, kind: t { $0 }),
        Transform(id: "uncolor", title: "Formatted, no colors", subtitle: "keep bold, tables, lists · drop dark-theme colors",
                  icon: "paintbrush", group: .format, key: "F", keywords: "rich dark black background antigravity vscode",
                  needs: .rich, kind: .uncolor(emailFont: false)),
        Transform(id: "emailfont", title: "Formatted, email font", subtitle: "as above, and take the email's own font and size",
                  icon: "envelope", group: .format, key: "E", keywords: "outlook word rich font size",
                  needs: .rich, kind: .uncolor(emailFont: true)),
        Transform(id: "markdown", title: "Markdown → formatted", subtitle: "**bold**, - bullets, | tables | become real formatting",
                  icon: "doc.richtext", group: .format, key: "M", keywords: "md render claude chat rich",
                  needs: .text, kind: .markdown),
        Transform(id: "ocr", title: "Text from image", subtitle: "read the text in a copied screenshot",
                  icon: "text.viewfinder", group: .format, key: "I", keywords: "ocr picture screenshot",
                  needs: .image, kind: .ocr, emptyMessage: "No text found in the image"),
        // Text
        Transform(id: "clean", title: "Clean text", subtitle: "trim, collapse spaces, straighten quotes", icon: "eraser",
                  group: .text, key: "C", keywords: "quotes spaces tidy", needs: .text, kind: t(TextOps.clean)),
        Transform(id: "unwrap", title: "Unwrap lines", subtitle: "rejoin sentences a PDF or email broke · keep paragraphs",
                  icon: "text.justify.left", group: .text, key: "U", keywords: "pdf line breaks reflow paragraphs",
                  needs: .text, kind: t(DataOps.unwrap)),
        Transform(id: "singleline", title: "Single line", subtitle: "flatten every line break into one line",
                  icon: "arrow.right.to.line", group: .text, key: "S", keywords: "flatten join", needs: .text, kind: t(TextOps.singleLine)),
        Transform(id: "proper", title: "Proper Case", subtitle: "hello world → Hello World", icon: "textformat.size",
                  group: .text, key: "T", keywords: "title capitalize", needs: .text, kind: t { $0.capitalized }),
        Transform(id: "sentence", title: "Sentence case", subtitle: "SHOUTY NOTE. → Shouty note.", icon: "text.cursor",
                  group: .text, key: nil, keywords: "capitalize", needs: .text, kind: t(TextOps.sentenceCase)),
        Transform(id: "lower", title: "lowercase", subtitle: "Hello World → hello world", icon: "textformat.size.smaller",
                  group: .text, key: nil, keywords: "case", needs: .text, kind: t { $0.lowercased() }),
        Transform(id: "upper", title: "UPPERCASE", subtitle: "hello world → HELLO WORLD", icon: "textformat.size.larger",
                  group: .text, key: nil, keywords: "caps case", needs: .text, kind: t { $0.uppercased() }),
        // Data
        Transform(id: "tsv", title: "Table → Excel cells", subtitle: "each value lands in its own cell", icon: "tablecells",
                  group: .data, key: "X", keywords: "spreadsheet tsv sheets grid columns",
                  needs: .text, kind: .local { DataOps.tableToTSV(html: $0.html, text: $0.text) },
                  emptyMessage: "No table on the clipboard"),
        Transform(id: "numbers", title: "Numbers only", subtitle: "$1,234.50 → 1234.50 · paste as values", icon: "number",
                  group: .data, key: "N", keywords: "currency percent values excel", needs: .text, kind: t(TextOps.numbersOnly)),
        Transform(id: "joinlist", title: "Column → list", subtitle: "one per line → a, b, c", icon: "text.append",
                  group: .data, key: "J", keywords: "comma join csv ids filter", needs: .text, kind: t(DataOps.joinList)),
        Transform(id: "quotedlist", title: "Column → quoted list", subtitle: "one per line → 'a', 'b', 'c' (SQL IN)",
                  icon: "quote.opening", group: .data, key: "Q", keywords: "sql in query quotes", needs: .text, kind: t(DataOps.quotedList)),
        Transform(id: "splitlist", title: "List → column", subtitle: "a, b; c → one per line", icon: "list.bullet",
                  group: .data, key: "O", keywords: "split comma semicolon lines", needs: .text, kind: t(DataOps.splitList)),
        Transform(id: "sortunique", title: "Sort, remove duplicates", subtitle: "one per line, A→Z, each once",
                  icon: "arrow.up.arrow.down", group: .data, key: "D", keywords: "dedupe unique sort lines", needs: .text,
                  kind: t(DataOps.sortUnique)),
        Transform(id: "contacts", title: "Contacts, one per line", subtitle: "Name <email>; … → name, email, blank line",
                  icon: "person.crop.circle", group: .data, key: "R", keywords: "recipients outlook gmail addresses",
                  needs: .text, kind: t(TextOps.contactList)),
        Transform(id: "links", title: "Clean links", subtitle: "strip utm_, fbclid, si… from every URL", icon: "link",
                  group: .data, key: "L", keywords: "url tracking utm", needs: .text, kind: t(TextOps.cleanLinks)),
        Transform(id: "emails", title: "Email addresses only", subtitle: "every address, each once, one per line", icon: "at",
                  group: .data, key: "A", keywords: "extract emails", needs: .text, kind: tOpt(DataOps.emailsOnly),
                  emptyMessage: "No email addresses on the clipboard"),
        Transform(id: "phones", title: "Phone numbers only", subtitle: "every number as (502) 555-1234, each once",
                  icon: "phone", group: .data, key: nil, keywords: "extract phones", needs: .text, kind: tOpt(DataOps.phonesOnly),
                  emptyMessage: "No phone numbers on the clipboard"),
        Transform(id: "formatphones", title: "Format phone numbers", subtitle: "502.555.1234 → (502) 555-1234, text kept",
                  icon: "phone.connection", group: .data, key: nil, keywords: "phones normalize", needs: .text,
                  kind: t(DataOps.formatPhones)),
        Transform(id: "linksonly", title: "Links only", subtitle: "every URL, each once, one per line", icon: "link.badge.plus",
                  group: .data, key: nil, keywords: "extract urls", needs: .text, kind: tOpt(DataOps.linksOnly),
                  emptyMessage: "No links on the clipboard"),
        Transform(id: "json", title: "Pretty JSON", subtitle: "indent JSON, key order kept", icon: "curlybraces",
                  group: .data, key: nil, keywords: "format indent", needs: .text, kind: tOpt(DataOps.prettyJSON),
                  emptyMessage: "The clipboard isn't valid JSON"),
        // AI
        Transform(id: "summarize", title: "Summarize", subtitle: "AI · the key points", icon: "text.quote",
                  group: .ai, key: nil, keywords: "claude short", needs: .text,
                  kind: .ai("Summarize the following text concisely. Output only the summary.")),
        Transform(id: "rewrite", title: "Rewrite", subtitle: "AI · fix grammar, tighten", icon: "pencil.line",
                  group: .ai, key: nil, keywords: "claude grammar", needs: .text,
                  kind: .ai("Rewrite the following to fix grammar and make it clear and concise, keeping the meaning and tone. Output only the rewrite.")),
        Transform(id: "bullets", title: "Bullet points", subtitle: "AI · as a list", icon: "list.dash",
                  group: .ai, key: nil, keywords: "claude list", needs: .text,
                  kind: .ai("Rewrite the following as a concise bulleted list using '- '. Output only the list.")),
        Transform(id: "aimarkdown", title: "Markdown", subtitle: "AI · clean markdown", icon: "doc.text",
                  group: .ai, key: nil, keywords: "claude md", needs: .text,
                  kind: .ai("Reformat the following as clean, well-structured Markdown. Output only the Markdown.")),
        Transform(id: "translate", title: "Translate → English", subtitle: "AI", icon: "character.bubble",
                  group: .ai, key: nil, keywords: "claude language", needs: .text,
                  kind: .ai("Translate the following into natural English. If it's already English, correct it lightly. Output only the translation.")),
    ]

    static func transform(forKey letter: String) -> Transform? {
        transforms.first { $0.key.map { String($0) } == letter.uppercased() }
    }

    static func canRun(_ t: Transform, on input: PasteInput) -> Bool {
        switch t.needs {
        case .text: return !input.text.isEmpty
        case .rich: return input.hasRich
        case .image: return input.image != nil
        }
    }

    static func available(for input: PasteInput) -> [Transform] { transforms.filter { canRun($0, on: input) } }

    static func matches(_ t: Transform, filter: String) -> Bool {
        let words = filter.lowercased().split(separator: " ")
        let hay = "\(t.title) \(t.subtitle) \(t.group.rawValue) \(t.keywords)".lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    /// Up to three rows that fit what is on the clipboard, best first. They are
    /// shown again at the top of the drawer; the groups below never move.
    static func suggestions(for input: PasteInput) -> [Transform] {
        var ids: [String] = []
        let text = input.text
        if input.image != nil, text.isEmpty { ids.append("ocr") }
        if let h = input.html {
            if RichText.hasThemeColors(h) { ids.append("uncolor") }
            if h.range(of: "<table", options: .caseInsensitive) != nil { ids.append("tsv") }
        }
        if !text.isEmpty {
            if input.html == nil, Detect.looksLikeMarkdown(text) { ids.append("markdown") }
            if Detect.hasMarkdownTable(text), !ids.contains("tsv") { ids.append("tsv") }
            if TextOps.cleanLinks(text) != text { ids.append("links") }
            let recipients = Detect.isRecipientLine(text)
            if recipients { ids.append("contacts") }
            if Detect.isJSON(text) { ids.append("json") }
            if Detect.isColumn(text) { ids += ["joinlist", "quotedlist"] }
            else if !recipients, Detect.isInlineList(text) { ids.append("splitlist") }
            if Detect.isHardWrapped(text) { ids.append("unwrap") }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
            .compactMap { id in transforms.first { $0.id == id } }
            .filter { canRun($0, on: input) }
            .prefix(3).map { $0 }
    }

    /// Run a local transform (not AI, not OCR — those are async in the controller).
    @MainActor static func run(_ t: Transform, on input: PasteInput) -> PasteResult {
        switch t.kind {
        case .local(let f):
            guard let out = f(input) else { return .failure(t.emptyMessage) }
            return .text(out)
        case .uncolor(let emailFont):
            guard let flavors = RichText.uncoloredPayload(html: input.html, rtf: input.rtf, emailFont: emailFont) else {
                return .text(input.text)
            }
            return .rich(text: input.text, flavors: flavors)
        case .markdown:
            return .rich(text: input.text, flavors: Markdown.payload(input.text))
        case .ocr, .ai:
            return .failure("This one runs in the background")
        }
    }
}

/// "Formatted, no colors": dark-theme apps (Antigravity / VS Code chat, Chrome
/// in dark mode) copy HTML with inline `color: rgb(204,204,204)` and
/// `background-color: rgb(31,31,31)` on every element, so a formatted paste
/// lands as white-on-black blocks. Drop ONLY the color rules — bold, tables,
/// borders, lists and links survive — and let the target app's own text and
/// page colors show through.
enum RichText {
    /// CSS properties that carry a theme's text or background color. Matched
    /// as whole property names, so `border-color` and `border-radius` stay.
    private static let colorDecl = try! NSRegularExpression(
        pattern: "(?<![-\\w])(?:color|background|background-color|background-image|-webkit-text-fill-color|text-decoration-color|caret-color)\\s*:[^;\"'}]*;?",
        options: [.caseInsensitive])
    /// style="…" / style='…' attributes and <style>…</style> blocks — the only
    /// places a declaration is CSS (body text saying "color: blue" is left alone).
    private static let styleAttrDouble = try! NSRegularExpression(pattern: "(\\sstyle\\s*=\\s*\")([^\"]*)(\")", options: [.caseInsensitive])
    private static let styleAttrSingle = try! NSRegularExpression(pattern: "(\\sstyle\\s*=\\s*')([^']*)(')", options: [.caseInsensitive])
    private static let styleBlock = try! NSRegularExpression(pattern: "(<style[^>]*>)(.*?)(</style>)", options: [.caseInsensitive, .dotMatchesLineSeparators])
    /// Legacy attributes: <td bgcolor=…>, <font color=…>, <body text=…>.
    private static let colorAttr = try! NSRegularExpression(
        pattern: "\\s(?:bgcolor|color|text)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.caseInsensitive])

    /// "Formatted, email font" also drops these, so the email's own font and
    /// size apply. Bold and italics are font-weight/font-style and stay.
    private static let fontDecl = try! NSRegularExpression(
        pattern: "(?<![-\\w])(?:font-family|font-size|line-height|letter-spacing|word-spacing)\\s*:[^;\"'}]*;?",
        options: [.caseInsensitive])
    private static let fontAttr = try! NSRegularExpression(
        pattern: "\\s(?:face|size)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.caseInsensitive])

    static func uncolorHTML(_ html: String, dropFonts: Bool = false) -> String {
        var s = html
        for re in [styleAttrDouble, styleAttrSingle, styleBlock] {
            s = replaceGroup2(re, in: s) { css in
                var out = colorDecl.stringByReplacingMatches(in: css, range: NSRange(location: 0, length: (css as NSString).length), withTemplate: "")
                if dropFonts {
                    out = fontDecl.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
                }
                return out
            }
        }
        // Legacy color attributes only inside tags, never in text.
        s = replaceTags(in: s) { tag in
            var out = colorAttr.stringByReplacingMatches(in: tag, range: NSRange(location: 0, length: (tag as NSString).length), withTemplate: "")
            if dropFonts, tag.lowercased().hasPrefix("<font") {
                out = fontAttr.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
            }
            return out
        }
        return s
    }

    /// Does this HTML carry a dark theme — a dark background or light text?
    /// Drives the "Suggested" row; a normal web page (dark text on white) doesn't.
    private static let themeDecl = try! NSRegularExpression(
        pattern: "(?<![-\\w])(background-color|background|color)\\s*:\\s*([^;\"'}]+)", options: [.caseInsensitive])
    static func hasThemeColors(_ html: String) -> Bool {
        let ns = html as NSString
        for m in themeDecl.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 200_000))) {
            guard let lum = luminance(ns.substring(with: m.range(at: 2))) else { continue }
            let isBackground = ns.substring(with: m.range(at: 1)).lowercased().hasPrefix("background")
            if isBackground ? lum < 0.35 : lum > 0.75 { return true }
        }
        return false
    }

    /// 0 (black) … 1 (white) for rgb()/rgba()/#rgb/#rrggbb/white/black; nil otherwise
    /// (and for transparent rgba, which shows whatever is behind it).
    static func luminance(_ value: String) -> Double? {
        let v = value.lowercased()
        var rgb: [Double] = []
        if let r = v.range(of: "rgba?\\(([^)]*)\\)", options: .regularExpression) {
            let parts = v[r].dropFirst(v[r].hasPrefix("rgba") ? 5 : 4).dropLast()
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0) }
            if parts.count >= 4, parts[3] < 0.5 { return nil }
            rgb = Array(parts.prefix(3))
        } else if let r = v.range(of: "#[0-9a-f]{3,6}\\b", options: .regularExpression) {
            var hex = String(v[r].dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let n = Int(hex, radix: 16) else { return nil }
            rgb = [Double(n >> 16 & 255), Double(n >> 8 & 255), Double(n & 255)]
        } else if v.contains("white") { return 1 } else if v.contains("black") { return 0 }
        guard rgb.count == 3 else { return nil }
        return (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255
    }

    /// RTF for apps that read it (TextEdit, Pages, Notes). `defaultFont` gives
    /// font-less HTML the system's font — the importer would pick Times.
    @MainActor static func rtf(fromHTML html: String, defaultFont: Bool = false) -> Data? {
        let source = (defaultFont ? "<style>body{font-family:'Helvetica Neue',Helvetica,sans-serif;font-size:13px}</style>" : "") + html
        guard let a = NSAttributedString(html: Data(source.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                         documentAttributes: nil) else { return nil }
        return try? uncolor(a).data(from: NSRange(location: 0, length: a.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// RTF-only sources (Terminal, Xcode, Notes in dark mode): drop text and
    /// background colors, table-cell shading included.
    static func uncolor(_ attr: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attr)
        let all = NSRange(location: 0, length: m.length)
        m.removeAttribute(.foregroundColor, range: all)
        m.removeAttribute(.backgroundColor, range: all)
        m.enumerateAttribute(.paragraphStyle, in: all) { value, range, _ in
            guard let ps = value as? NSParagraphStyle, !ps.textBlocks.isEmpty else { return }
            let copy = ps.mutableCopy() as! NSMutableParagraphStyle
            copy.textBlocks = ps.textBlocks.map { block in
                let b = block.copy() as! NSTextBlock
                b.backgroundColor = nil
                return b
            }
            m.addAttribute(.paragraphStyle, value: copy, range: range)
        }
        return m
    }

    /// Clipboard payload for the colorless paste: HTML (Outlook, Word, Gmail,
    /// web editors) + RTF (TextEdit, Pages, Notes). Nil when the clipboard had
    /// no formatting — the caller pastes plain text then.
    ///
    /// `emailFont` also drops fonts and sends HTML only: Outlook and Word apply
    /// their own font to font-less HTML, but RTF needs a font, and theirs is
    /// not one we can know.
    @MainActor static func uncoloredPayload(html: String?, rtf: Data?, emailFont: Bool = false) -> [(NSPasteboard.PasteboardType, Data)]? {
        if let html, !html.isEmpty {
            let clean = uncolorHTML(html, dropFonts: emailFont)
            var out: [(NSPasteboard.PasteboardType, Data)] = [(.html, Data(clean.utf8))]
            if !emailFont, let r = self.rtf(fromHTML: clean) { out.append((.rtf, r)) }
            return out
        }
        if let rtf, let a = NSAttributedString(rtf: rtf, documentAttributes: nil),
           let r = try? uncolor(a).data(from: NSRange(location: 0, length: a.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            return [(.rtf, r)]
        }
        return nil
    }

    private static func replaceGroup2(_ re: NSRegularExpression, in s: String, _ f: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += ns.substring(with: m.range(at: 1)) + f(ns.substring(with: m.range(at: 2))) + ns.substring(with: m.range(at: 3))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    private static let tag = try! NSRegularExpression(pattern: "<[a-zA-Z][^>]*>")
    private static func replaceTags(in s: String, _ f: (String) -> String) -> String {
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in tag.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + f(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// Instant, offline text transforms for the Advanced Paste palette. No network,
/// no AI — pure string work applied to whatever's on the clipboard.
enum TextOps {
    /// "Paste values" for text: straighten smart quotes/dashes, collapse runs of
    /// spaces/tabs within each line, trim each line, and drop blank lines.
    static func clean(_ s: String) -> String {
        let straightened = s
            .replacingOccurrences(of: "\u{201C}", with: "\"")   // “
            .replacingOccurrences(of: "\u{201D}", with: "\"")   // ”
            .replacingOccurrences(of: "\u{2018}", with: "'")    // ‘
            .replacingOccurrences(of: "\u{2019}", with: "'")    // ’
            .replacingOccurrences(of: "\u{2013}", with: "-")    // en dash
            .replacingOccurrences(of: "\u{2014}", with: "-")    // em dash
        return straightened
            .components(separatedBy: .newlines)
            .map { (line: String) in line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Strip the tracking junk out of every URL in the text, leaving the link
    /// itself alone. The pasted link is the one you meant to send, not the one
    /// that says which post you clicked it from.
    ///
    /// Conservative on purpose: a fixed list of known trackers, so a query
    /// parameter the destination actually needs is never dropped.
    static let trackingParams: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id",
        "utm_name", "utm_reader", "utm_brand", "utm_social", "utm_social-type",
        "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "fbclid", "msclkid", "twclid",
        "ttclid", "igshid", "igsh", "yclid", "vero_id", "vero_conv", "mc_cid", "mc_eid",
        "_hsenc", "_hsmi", "hsctatracking", "oly_anon_id", "oly_enc_id", "s_kwcid",
        "ref_src", "ref_url", "si", "spm", "sca_esv", "at_medium", "at_campaign",
        "icid", "ICID", "cmpid", "trk", "trkcampaign",
    ]

    static func cleanLinks(_ s: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return s
        }
        let ns = s as NSString
        let matches = detector.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = s
        // Replace from the END so earlier ranges stay valid.
        for m in matches.reversed() {
            guard let url = m.url,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let items = parts.queryItems, !items.isEmpty else { continue }
            let kept = items.filter { !trackingParams.contains($0.name) }
            guard kept.count != items.count else { continue }
            parts.queryItems = kept.isEmpty ? nil : kept
            guard let cleaned = parts.url?.absoluteString else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: cleaned)
        }
        return out
    }

    /// Flatten every line break into a single line — for search boxes, URL bars,
    /// spreadsheet cells. Trims each line and drops empties so it reads clean.
    static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Spreadsheet "paste values" for figures: strip currency symbols, thousands
    /// commas, and % per line so numbers land as numbers, not text. Keeps tabs,
    /// so a copied cell range stays a range.
    static func numbersOnly(_ s: String) -> String {
        let strip = CharacterSet(charactersIn: "$€£¥,%")
        return s.components(separatedBy: .newlines).map { line in
            String(line.unicodeScalars.filter { !strip.contains($0) })
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// Lowercase everything, then capitalize the first letter of the text and of
    /// each sentence (after . ! ?). Fixes ALL-CAPS or shouty notes.
    static func sentenceCase(_ s: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in s.lowercased() {
            if capitalizeNext, ch.isLetter {
                result += ch.uppercased()
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." || ch == "!" || ch == "?" { capitalizeNext = true }
            }
        }
        return result
    }

    /// An Outlook/Gmail recipient line — `Doug Lepping <dlepping@x.com>; Willie
    /// Meredith <wmeredith@x.com>` — becomes one contact per block:
    ///
    ///     Doug Lepping
    ///     dlepping@x.com
    ///
    ///     Willie Meredith
    ///     wmeredith@x.com
    ///
    /// Entries split on `;` (Outlook) and newlines, or on `,` (Gmail) when the
    /// text has no `;` — never inside quotes or angle brackets, so
    /// `"Lepping, Doug" <…>` stays one contact. Quotes around the name and the
    /// angle brackets around the address are dropped; a bare address with no
    /// name emits just the address. Text with no contacts in it passes through
    /// unchanged.
    static func contactList(_ s: String) -> String {
        let commaSplits = !s.contains(";")
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if !inQuotes, ch == "<" { inAngle = true }
            if !inQuotes, ch == ">" { inAngle = false }
            let splits = !inQuotes && !inAngle && (ch == ";" || ch.isNewline || (commaSplits && ch == ","))
            if splits { entries.append(current); current = "" } else { current.append(ch) }
        }
        entries.append(current)

        var sawEmail = false
        let blocks: [String] = entries.compactMap { raw in
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { return nil }
            var name = entry
            var email = ""
            if let open = entry.lastIndex(of: "<"), let close = entry[open...].firstIndex(of: ">") {
                email = String(entry[entry.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                name = String(entry[..<open])
            } else if entry.contains("@"), !entry.contains(" ") {
                email = entry   // bare address, no display name
                name = ""
            }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespaces))
            if email.isEmpty { return name }
            sawEmail = true
            return name.isEmpty ? email : name + "\n" + email
        }
        return sawEmail ? blocks.joined(separator: "\n\n") : s
    }
}

/// List, table and extract transforms for the Data group. Offline string work.
enum DataOps {
    /// Rejoin lines a PDF or an email client broke mid-sentence. Blank lines
    /// stay paragraph breaks; list items, headings and table rows keep their
    /// own lines.
    static func unwrap(_ s: String) -> String {
        let paragraphs = s.components(separatedBy: "\n").split(omittingEmptySubsequences: true, whereSeparator: {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        })
        return paragraphs.map { lines -> String in
            var out: [String] = []
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // Join onto the line above unless this one starts its own line
                // (bullet, heading…) or the one above is a heading or table row.
                if let last = out.last, !Detect.startsOwnLine(line), !last.hasPrefix("#"), !last.hasPrefix("|") {
                    if last.hasSuffix("-"), let f = line.first, f.isLowercase,
                       let p = last.dropLast().last, p.isLetter {
                        out[out.count - 1] = String(last.dropLast()) + line   // "exam-" + "ple"
                    } else {
                        out[out.count - 1] = last + " " + line
                    }
                } else {
                    out.append(line)
                }
            }
            return out.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The values of a column (or a copied row of cells), one per item.
    private static func items(_ s: String, splitOn seps: CharacterSet) -> [String] {
        s.components(separatedBy: seps)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func joinList(_ s: String) -> String {
        items(s, splitOn: CharacterSet(charactersIn: "\n\t\r")).joined(separator: ", ")
    }

    static func quotedList(_ s: String) -> String {
        items(s, splitOn: CharacterSet(charactersIn: "\n\t\r"))
            .map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
            .joined(separator: ", ")
    }

    static func splitList(_ s: String) -> String {
        items(s, splitOn: CharacterSet(charactersIn: ",;\n\t\r")).joined(separator: "\n")
    }

    static func sortUnique(_ s: String) -> String {
        var seen = Set<String>()
        return items(s, splitOn: CharacterSet(charactersIn: "\n\r"))
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: "\n")
    }

    private static let emailRE = try! NSRegularExpression(
        pattern: "[A-Z0-9._%+'-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive])

    static func emailsOnly(_ s: String) -> String? {
        var seen = Set<String>()
        let found = matches(emailRE, in: s).filter { seen.insert($0.lowercased()).inserted }
        return found.isEmpty ? nil : found.joined(separator: "\n")
    }

    /// North American numbers: 5025551234, 502-555-1234, (502) 555.1234, +1 502 555 1234.
    private static let phoneRE = try! NSRegularExpression(
        pattern: "(?<![\\d-])(?:\\+?1[\\s.-]?)?\\(?([2-9]\\d{2})\\)?[\\s.-]?(\\d{3})[\\s.-]?(\\d{4})(?![\\d-])")

    static func phonesOnly(_ s: String) -> String? {
        let ns = s as NSString
        var seen = Set<String>()
        let found = phoneRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m -> String? in
            let a = ns.substring(with: m.range(at: 1)), b = ns.substring(with: m.range(at: 2)), c = ns.substring(with: m.range(at: 3))
            return seen.insert(a + b + c).inserted ? "(\(a)) \(b)-\(c)" : nil
        }
        return found.isEmpty ? nil : found.joined(separator: "\n")
    }

    static func formatPhones(_ s: String) -> String {
        phoneRE.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                         withTemplate: "($1) $2-$3")
    }

    static func linksOnly(_ s: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        var seen = Set<String>()
        let found = detector.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            .compactMap { $0.url?.absoluteString }
            .filter { !$0.hasPrefix("mailto:") && seen.insert($0).inserted }
        return found.isEmpty ? nil : found.joined(separator: "\n")
    }

    /// Re-indent JSON with two spaces. Walks the text itself rather than
    /// round-tripping through JSONSerialization, which would reorder the keys.
    static func prettyJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else { return nil }
        var out = ""
        var depth = 0
        var inString = false, escaped = false
        let chars = Array(s)
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                i += 1; continue
            }
            switch ch {
            case "\"": inString = true; out.append(ch)
            case "{", "[":
                // An empty object or array stays on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (ch == "{" ? "}" : "]") {
                    out += String(ch) + String(chars[j]); i = j + 1; continue
                }
                out.append(ch); depth += 1; newline()
            case "}", "]": depth -= 1; newline(); out.append(ch)
            case ",": out.append(ch); newline()
            case ":": out += ": "
            default: if !ch.isWhitespace { out.append(ch) }
            }
            i += 1
        }
        return out
    }

    /// An HTML table (a web page, a dark-theme chat) or a Markdown table →
    /// tab-separated rows, so each value lands in its own spreadsheet cell.
    static func tableToTSV(html: String?, text: String) -> String? {
        if let html, let rows = htmlTableRows(html), !rows.isEmpty {
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }
        if let rows = markdownTableRows(text), !rows.isEmpty {
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }
        return nil
    }

    private static let rowRE = try! NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let cellRE = try! NSRegularExpression(pattern: "<t[hd][^>]*>(.*?)</t[hd]>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let tagRE = try! NSRegularExpression(pattern: "<[^>]+>")

    static func htmlTableRows(_ html: String) -> [[String]]? {
        let rows = matches(rowRE, in: html, group: 1).map { row in
            matches(cellRE, in: row, group: 1).map { cell -> String in
                let stripped = tagRE.stringByReplacingMatches(in: cell, range: NSRange(location: 0, length: (cell as NSString).length), withTemplate: " ")
                return decodeEntities(stripped).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }
        }.filter { !$0.isEmpty }
        return rows.isEmpty ? nil : rows
    }

    static func markdownTableRows(_ s: String) -> [[String]]? {
        let lines = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let rows = lines.filter { $0.hasPrefix("|") && $0.dropFirst().contains("|") }
            .filter { !Detect.isTableSeparator($0) }
            .map { Markdown.cells($0).map(Markdown.stripInline) }
        return rows.count >= 2 ? rows : nil
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let num = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in num.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let code = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(code) {
                result.unicodeScalars.append(u)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func matches(_ re: NSRegularExpression, in s: String, group: Int = 0) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: group)) }
    }
}

/// Clipboard shape checks behind the drawer's "Suggested" rows.
enum Detect {
    /// Lines that keep their own line when unwrapping: bullets, numbered items,
    /// headings, quotes, table rows.
    static func startsOwnLine(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.isEmpty { return true }
        if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") || l.hasPrefix("#") || l.hasPrefix(">") || l.hasPrefix("|") { return true }
        return l.range(of: "^\\d{1,3}[.)] ", options: .regularExpression) != nil
    }

    static func isTableSeparator(_ line: String) -> Bool {
        line.range(of: "^\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?$", options: .regularExpression) != nil
    }

    static func hasMarkdownTable(_ s: String) -> Bool {
        s.components(separatedBy: .newlines).contains { isTableSeparator($0.trimmingCharacters(in: .whitespaces)) && $0.contains("|") }
    }

    static func looksLikeMarkdown(_ s: String) -> Bool {
        var signals = 0
        for line in s.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.range(of: "^#{1,6} ", options: .regularExpression) != nil { signals += 2 }
            if l.hasPrefix("- ") || l.hasPrefix("* ") || l.range(of: "^\\d{1,3}\\. ", options: .regularExpression) != nil { signals += 1 }
            if l.range(of: "\\*\\*[^*]+\\*\\*", options: .regularExpression) != nil { signals += 1 }
            if l.hasPrefix("```") || isTableSeparator(l) { signals += 2 }
            if l.range(of: "\\[[^\\]]+\\]\\([^)]+\\)", options: .regularExpression) != nil { signals += 1 }
            if signals >= 3 { return true }
        }
        return false
    }

    static func isRecipientLine(_ s: String) -> Bool {
        s.contains("@") && s.contains("<") && TextOps.contactList(s) != s
    }

    static func isJSON(_ s: String) -> Bool {
        guard let f = s.first, f == "{" || f == "[", let d = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) != nil
    }

    /// A copied column: two or more short lines, each a value, not a sentence.
    static func isColumn(_ s: String) -> Bool {
        let lines = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2, lines.count <= 5000, !s.contains("\t") else { return false }
        return lines.allSatisfy { l in
            l.count <= 40 && l.split(separator: " ").count <= 3 && !l.contains(", ")
                && !(l.last.map { ".!?:".contains($0) } ?? false) && !startsOwnLine(l)
        }
    }

    /// One line of values: "a, b, c" or "a; b; c".
    static func isInlineList(_ s: String) -> Bool {
        guard !s.contains("\n") else { return false }
        let parts = s.components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty && $0.count <= 40 && $0.split(separator: " ").count <= 4 }
    }

    /// Prose broken mid-sentence: a line runs on into the next, which starts lowercase.
    static func isHardWrapped(_ s: String) -> Bool {
        let lines = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3 else { return false }
        var joints = 0
        for i in 0..<(lines.count - 1) {
            let a = lines[i], b = lines[i + 1]
            guard a.count >= 25, let last = a.last, !".!?:;".contains(last), let first = b.first, first.isLowercase,
                  !startsOwnLine(a), !startsOwnLine(b) else { continue }
            joints += 1
        }
        return joints >= 2
    }
}

/// Markdown → HTML for "Markdown → formatted": the shapes Claude and chat apps
/// produce — headings, bold/italic, code, links, bullets, numbered lists,
/// quotes, rules and tables. Styles are inline because Outlook drops <style>.
enum Markdown {
    static let cellStyle = "border:1px solid #bfbfbf;padding:3px 8px;text-align:left;vertical-align:top"
    static let codeStyle = "font-family:Menlo,Consolas,monospace;font-size:0.92em"

    static func cells(_ row: String) -> [String] {
        var r = row.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func html(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        var out = ""
        var para: [String] = []
        var listStack: [String] = []   // "ul"/"ol" per open level
        var i = 0

        func flushPara() {
            if !para.isEmpty { out += "<p>" + inline(para.joined(separator: " ")) + "</p>\n"; para = [] }
        }
        func closeLists(to level: Int = 0) {
            while listStack.count > level { out += "</\(listStack.removeLast())>\n" }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushPara(); closeLists()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                out += "<pre style=\"\(codeStyle)\">" + escape(code.joined(separator: "\n")) + "</pre>\n"
                i += 1; continue
            }
            if line.isEmpty { flushPara(); closeLists(); i += 1; continue }
            if let m = line.range(of: "^#{1,6} ", options: .regularExpression) {
                flushPara(); closeLists()
                let n = line[m].filter { $0 == "#" }.count
                out += "<h\(n)>" + inline(String(line[m.upperBound...])) + "</h\(n)>\n"
                i += 1; continue
            }
            if line.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
                flushPara(); closeLists(); out += "<hr>\n"; i += 1; continue
            }
            if line.hasPrefix("|"), i + 1 < lines.count, Detect.isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushPara(); closeLists()
                out += "<table style=\"border-collapse:collapse\">\n<tr>"
                    + cells(line).map { "<th style=\"\(cellStyle)\">\(inline($0))</th>" }.joined() + "</tr>\n"
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    out += "<tr>" + cells(lines[i]).map { "<td style=\"\(cellStyle)\">\(inline($0))</td>" }.joined() + "</tr>\n"
                    i += 1
                }
                out += "</table>\n"; continue
            }
            if line.hasPrefix(">") {
                flushPara(); closeLists()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out += "<blockquote style=\"border-left:3px solid #bfbfbf;margin:0 0 0 4px;padding-left:10px\">"
                    + inline(quote.joined(separator: " ")) + "</blockquote>\n"
                continue
            }
            let bullet = line.range(of: "^[-*+•] ", options: .regularExpression)
            let number = line.range(of: "^\\d{1,3}[.)] ", options: .regularExpression)
            if let marker = bullet ?? number {
                flushPara()
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let level = min(indent / 2, 4) + 1
                let tag = bullet != nil ? "ul" : "ol"
                if listStack.count > level { closeLists(to: level) }
                if listStack.count == level, listStack.last != tag { closeLists(to: level - 1) }
                while listStack.count < level { out += "<\(tag)>\n"; listStack.append(tag) }
                out += "<li>" + inline(String(line[marker.upperBound...])) + "</li>\n"
                i += 1; continue
            }
            if !listStack.isEmpty, raw.first == " " {
                // A wrapped continuation of the last list item.
                if out.hasSuffix("</li>\n") { out.removeLast("</li>\n".count); out += " " + inline(line) + "</li>\n" }
                i += 1; continue
            }
            closeLists()
            para.append(line)
            i += 1
        }
        flushPara(); closeLists()
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let codeRE = try! NSRegularExpression(pattern: "`([^`]+)`")
    private static let linkRE = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
    private static let boldRE = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicRE = try! NSRegularExpression(pattern: "(?<![\\w*])([*_])(?=\\S)(.+?)(?<=\\S)\\1(?![\\w*])")
    private static let strikeRE = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")

    /// Inline spans. Code spans are cut out first so `**` inside them stays literal.
    static func inline(_ s: String) -> String {
        var codes: [String] = []
        let ns = escape(s) as NSString
        var text = ""
        var last = 0
        for m in codeRE.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            text += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            text += "\u{1}\(codes.count)\u{1}"
            codes.append("<code style=\"\(codeStyle)\">" + ns.substring(with: m.range(at: 1)) + "</code>")
            last = m.range.location + m.range.length
        }
        text += ns.substring(from: last)
        func sub(_ re: NSRegularExpression, _ tmpl: String) {
            text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: tmpl)
        }
        sub(linkRE, "<a href=\"$2\">$1</a>")
        sub(boldRE, "<b>$2</b>")
        sub(italicRE, "<i>$2</i>")
        sub(strikeRE, "<s>$1</s>")
        for (n, c) in codes.enumerated() { text = text.replacingOccurrences(of: "\u{1}\(n)\u{1}", with: c) }
        return text
    }

    /// A cell's text without its Markdown marks: **82.1%** → 82.1%, [x](u) → x.
    static func stripInline(_ s: String) -> String {
        var out = linkRE.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1")
        for mark in ["**", "__", "~~", "`"] { out = out.replacingOccurrences(of: mark, with: "") }
        return out
    }

    /// HTML for the paste (no font, so the email's own font applies) + RTF for
    /// apps that read RTF (which needs one, so it gets the system's).
    @MainActor static func payload(_ md: String) -> [(NSPasteboard.PasteboardType, Data)] {
        let body = html(md)
        var out: [(NSPasteboard.PasteboardType, Data)] = [(.html, Data(("<meta charset='utf-8'>" + body).utf8))]
        if let rtf = RichText.rtf(fromHTML: body, defaultFont: true) { out.append((.rtf, rtf)) }
        return out
    }
}
