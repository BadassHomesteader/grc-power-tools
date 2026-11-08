import AppKit
import AuthenticationServices
import CryptoKit

// OneNote export for Meeting Notes, through Microsoft Graph.
//
// Sign-in is OAuth 2 authorization-code + PKCE against the "common" authority,
// so a personal Microsoft account and a work/school account both work. The app
// registration ("Power Tools Meeting Notes", appId below) lives in the
// GeeksAreCool Entra tenant: public client, multi-tenant + personal accounts,
// redirect msauth.com.grc.whisper://auth, delegated Notes.ReadWrite only.
// The refresh token is kept in the app's owner-only keys file (Keychain.swift);
// the chosen section and the account label are per-Mac UserDefaults.

enum OneNote {
    static let clientID = "984b757c-50c4-4376-ba43-bf4aa99722f3"
    static let redirectScheme = "msauth.com.grc.whisper"
    static let redirectURI = "msauth.com.grc.whisper://auth"
    static let scopes = "openid profile offline_access Notes.ReadWrite"
    static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0"
    static let graph = "https://graph.microsoft.com/v1.0"

    private static let refreshKey = "onenote.refresh"
    private static let d = UserDefaults.standard

    static var account: String? { d.string(forKey: "onenote.account") }
    static var isSignedIn: Bool { Keychain.has(refreshKey) }
    static var sectionID: String? { d.string(forKey: "onenote.section.id") }
    static var sectionName: String? { d.string(forKey: "onenote.section.name") }
    static var autoSend: Bool {
        get { d.bool(forKey: "onenote.auto") }
        set { d.set(newValue, forKey: "onenote.auto") }
    }

    static func setSection(id: String, name: String) {
        d.set(id, forKey: "onenote.section.id")
        d.set(name, forKey: "onenote.section.name")
    }

    static func signOut() {
        Keychain.set("", account: refreshKey)
        for k in ["onenote.account", "onenote.section.id", "onenote.section.name"] { d.removeObject(forKey: k) }
        cachedToken = nil
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Sign-in

    private static var activeSession: ASWebAuthenticationSession?
    private static let anchor = AnchorProvider()

    private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        var window: NSWindow?
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            window ?? NSApp.keyWindow ?? NSWindow()
        }
    }

    static func authorizeURL(challenge: String, state: String) -> URL {
        var c = URLComponents(string: authority + "/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_mode", value: "query"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]
        return c.url!
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Opens Microsoft's sign-in page; on success stores the refresh token.
    @MainActor
    static func signIn(from window: NSWindow?) async throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64url(Data(bytes))
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        let url = authorizeURL(challenge: challenge, state: state)

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: redirectScheme) { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? Failure(message: "Sign-in was cancelled.")) }
            }
            anchor.window = window
            session.presentationContextProvider = anchor
            activeSession = session
            if !session.start() { cont.resume(throwing: Failure(message: "Couldn't open the Microsoft sign-in page.")) }
        }
        activeSession = nil
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ k: String) -> String? { items.first { $0.name == k }?.value }
        if let err = item("error") {
            throw Failure(message: item("error_description")?.components(separatedBy: "\r\n").first ?? err)
        }
        guard item("state") == state, let code = item("code") else {
            throw Failure(message: "Microsoft's sign-in reply didn't match — try again.")
        }
        try await redeem(["grant_type": "authorization_code", "code": code,
                          "redirect_uri": redirectURI, "code_verifier": verifier])
    }

    // MARK: Tokens

    private static var cachedToken: (value: String, expires: Date)?

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)!
    }

    /// Token endpoint call (code redemption or refresh). Stores the new refresh
    /// token and caches the access token.
    @discardableResult
    private static func redeem(_ grant: [String: String]) async throws -> String {
        var req = URLRequest(url: URL(string: authority + "/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(grant.merging(["client_id": clientID, "scope": scopes]) { a, _ in a })
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = json["access_token"] as? String else {
            let desc = (json["error_description"] as? String)?.components(separatedBy: "\r\n").first
            if (json["error"] as? String) == "invalid_grant" { signOut() }
            throw Failure(message: desc ?? "Microsoft sign-in failed.")
        }
        if let refresh = json["refresh_token"] as? String { Keychain.set(refresh, account: refreshKey) }
        let expiresIn = (json["expires_in"] as? Double) ?? Double((json["expires_in"] as? String) ?? "") ?? 3600
        cachedToken = (access, Date().addingTimeInterval(expiresIn - 120))
        if let idToken = json["id_token"] as? String, let who = accountLabel(fromIDToken: idToken) {
            d.set(who, forKey: "onenote.account")
        }
        return access
    }

    private static func accountLabel(fromIDToken jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (claims["preferred_username"] as? String) ?? (claims["email"] as? String) ?? (claims["name"] as? String)
    }

    static func accessToken() async throws -> String {
        if let t = cachedToken, t.expires > Date() { return t.value }
        guard let refresh = Keychain.get(refreshKey), !refresh.isEmpty else {
            throw Failure(message: "Not signed in to OneNote.")
        }
        return try await redeem(["grant_type": "refresh_token", "refresh_token": refresh])
    }

    // MARK: Graph

    private static func call(_ method: String, _ path: String, body: Data? = nil,
                             contentType: String? = nil) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: path.hasPrefix("http") ? path : graph + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status >= 400, status != 404 {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw Failure(message: "OneNote: \(msg)")
        }
        return (status, json)
    }

    struct Section { let id: String; let name: String }

    /// Every section the account can write to, as "Notebook ▸ Section", A→Z.
    static func sections() async throws -> [Section] {
        var out: [Section] = []
        var next: String? = "/me/onenote/sections?$select=id,displayName&$expand=parentNotebook($select=displayName)&$top=100"
        while let path = next {
            let (_, json) = try await call("GET", path)
            for s in json["value"] as? [[String: Any]] ?? [] {
                guard let id = s["id"] as? String else { continue }
                let nb = (s["parentNotebook"] as? [String: Any])?["displayName"] as? String
                let name = s["displayName"] as? String ?? "Untitled section"
                out.append(Section(id: id, name: nb.map { "\($0) ▸ \(name)" } ?? name))
            }
            next = json["@odata.nextLink"] as? String
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct Page { let id: String; let url: String? }

    /// Creates the meeting's page in the chosen section. When the meeting was
    /// sent before, that page is deleted first, so a re-send replaces it.
    static func send(_ m: Meeting) async throws -> Page {
        guard let sectionID else { throw Failure(message: "Choose a OneNote section first.") }
        if let old = m.oneNotePageID { _ = try? await call("DELETE", "/me/onenote/pages/\(old)") }
        let (html, parts) = OneNotePageBuilder.build(m)
        let boundary = "PowerTools-" + UUID().uuidString
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"Presentation\"\r\nContent-Type: text/html\r\n\r\n")
        add(html)
        add("\r\n")
        for p in parts {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(p.name)\"\r\nContent-Type: \(p.type)\r\n\r\n")
            body.append(p.data)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")
        let (status, json) = try await call("POST", "/me/onenote/sections/\(sectionID)/pages", body: body,
                                            contentType: "multipart/form-data; boundary=\(boundary)")
        guard status == 201 || status == 200, let id = json["id"] as? String else {
            if status == 404 { throw Failure(message: "That OneNote section no longer exists — choose another.") }
            throw Failure(message: "OneNote didn't accept the page (HTTP \(status)).")
        }
        let links = json["links"] as? [String: Any]
        let client = (links?["oneNoteClientUrl"] as? [String: Any])?["href"] as? String
        let web = (links?["oneNoteWebUrl"] as? [String: Any])?["href"] as? String
        return Page(id: id, url: client ?? web)
    }
}

// MARK: - Page HTML

enum OneNotePageBuilder {
    struct Part { let name: String; let type: String; let data: Data }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// **bold** after escaping.
    private static func inline(_ s: String) -> String {
        let e = esc(s)
        return e.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
    }

    /// The small Markdown subset the enhancer writes (and people type): headings,
    /// bullets, numbered lists, to-do checkboxes (→ OneNote to-do tags), bold,
    /// and picture lines.
    static func html(fromMarkdown md: String, meetingID: String, parts: inout [Part]) -> String {
        var out: [String] = []
        var list: String?  // "ul" / "ol" while inside one
        func close() { if let l = list { out.append("</\(l)>"); list = nil } }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { close(); continue }
            if let name = MeetingImages.references(in: line).first,
               let data = try? Data(contentsOf: MeetingImages.url(meetingID, name)) {
                close()
                let part = "img\(parts.count)"
                let type = name.hasSuffix(".png") ? "image/png" : "image/jpeg"
                parts.append(Part(name: part, type: type, data: data))
                var width = 640
                if let rep = NSBitmapImageRep(data: data) { width = min(640, rep.pixelsWide) }
                out.append("<p><img src=\"name:\(part)\" width=\"\(width)\" /></p>")
                continue
            }
            var hashes = 0
            while hashes < line.count, line[line.index(line.startIndex, offsetBy: hashes)] == "#" { hashes += 1 }
            if (1...4).contains(hashes), line.dropFirst(hashes).first == " " {
                close()
                let level = min(max(hashes, 2), 4)  // the page title is the only h1
                out.append("<h\(level)>\(inline(String(line.dropFirst(hashes + 1))))</h\(level)>")
                continue
            }
            if let m = line.range(of: #"^[-*] \[( |x|X)\] "#, options: .regularExpression) {
                close()
                let done = line[m].lowercased().contains("x")
                out.append("<p data-tag=\"\(done ? "to-do:completed" : "to-do")\">\(inline(String(line[m.upperBound...])))</p>")
                continue
            }
            if let m = line.range(of: #"^[-*•] "#, options: .regularExpression) {
                if list != "ul" { close(); out.append("<ul>"); list = "ul" }
                out.append("<li>\(inline(String(line[m.upperBound...])))</li>")
                continue
            }
            if let m = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                if list != "ol" { close(); out.append("<ol>"); list = "ol" }
                out.append("<li>\(inline(String(line[m.upperBound...])))</li>")
                continue
            }
            close()
            out.append("<p>\(inline(line))</p>")
        }
        close()
        return out.joined(separator: "\n")
    }

    static func build(_ m: Meeting) -> (html: String, parts: [Part]) {
        var parts: [Part] = []
        var meta = [DateFormatter.localizedString(from: m.created, dateStyle: .full, timeStyle: .short)]
        if m.recordedSeconds >= 60 { meta.append("\(Int(m.recordedSeconds / 60)) min") }
        if let c = m.context, !c.isEmpty { meta.append(c) }
        var body = ["<p style=\"color:#767676\">\(esc(meta.joined(separator: " · ")))</p>"]
        if !m.enhanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.append(html(fromMarkdown: m.enhanced, meetingID: m.id, parts: &parts))
        }
        if !m.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body.append("<h2>My notes</h2>")
            body.append(html(fromMarkdown: m.notes, meetingID: m.id, parts: &parts))
        }
        let turns = MeetingText.turns(m.segments)
        if !turns.isEmpty {
            body.append("<h2>Transcript</h2>")
            for t in turns {
                body.append("<p><span style=\"color:#999999\">\(MeetingText.clock(t.start))</span> "
                            + "<b>\(esc(MeetingText.label(t.speaker, names: m.speakerNames)))</b> \(esc(t.text))</p>")
            }
        }
        let created = ISO8601DateFormatter().string(from: m.created)
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <title>\(esc(m.displayTitle))</title>
        <meta name="created" content="\(created)" />
        </head>
        <body>
        \(body.joined(separator: "\n"))
        </body>
        </html>
        """
        return (html, parts)
    }
}
