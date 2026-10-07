import Foundation
import AppKit
import ApplicationServices

/// New Outlook, read through Accessibility — for the Macro Pad.
///
/// New Outlook has no AppleScript (the roadmap item to restore it has slipped
/// since 2025), but its window is honest AX: the reading pane's header is an
/// AXGroup "Message header" holding the subject, a "From: name, address, …"
/// group and a "Recipients: …" group whose buttons each read "name, address,
/// availability"; the body is an AXWebArea "Reading Pane" of static texts;
/// the folder sidebar is an AXOutline whose rows carry a disclosure level
/// (0 = Favorites / accounts / Groups, deeper = folders) and a cell text of
/// "Name; N unread messages". All read-only — no Screen Recording, no OCR.
///
/// Every call is synchronous Mach IPC answered by Outlook's main thread, so
/// readers run off the main thread, prune the two big subtrees (sidebar,
/// message list) and the Search box's nest of text fields, and cap the walk.
enum OutlookReader {
    static let bundleID = "com.microsoft.Outlook"

    struct Message: Equatable {
        var subject = ""
        var fromName = ""
        var fromAddress = ""
        var recipients: [String] = []
        var body = ""
        /// Sender + subject: enough to know "same message as last time".
        var identity: String { "\(fromAddress)|\(subject)" }
        var isEmpty: Bool { subject.isEmpty && fromAddress.isEmpty && body.isEmpty }
        /// What keywords are matched against, lowercased: header + body.
        var searchText: String {
            ([fromName, fromAddress, subject] + recipients + [body]).joined(separator: "\n").lowercased()
        }
        var fromDomain: String { fromAddress.split(separator: "@").last.map(String.init) ?? "" }
    }

    // MARK: AX plumbing

    private static func app() -> AXUIElement? {
        guard let ol = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let ax = AXUIElementCreateApplication(ol.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        return ax
    }
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v
    }
    static func str(_ e: AXUIElement, _ name: String) -> String? {
        guard let v = attr(e, name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)   // AX attributes are untyped CF; the type id check above makes this safe
    }
    static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    static func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute) ?? "" }
    /// Title, description and value — whichever an element carries.
    static func text(_ e: AXUIElement) -> String {
        [str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXValueAttribute)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
    }
    private static func frontWindow(_ app: AXUIElement) -> AXUIElement? {
        element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
            ?? (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
    }
    /// Subtrees a message read never needs — and the two that cost the most.
    private static func prunes(_ e: AXUIElement, role r: String) -> Bool {
        switch r {
        case "AXOutline", "AXTable", "AXToolbar", "AXMenuBar", "AXScrollBar": return true
        case "AXTextField": return text(e) == "Search"   // the search box is 28 nested fields
        default: return false
        }
    }

    // MARK: The message in front

    /// The message in the reading pane of Outlook's front window, or nil when
    /// Outlook isn't running or nothing is open. ~100 nodes walked.
    static func currentMessage() -> Message? {
        guard let app = app(), let win = frontWindow(app) else { return nil }
        var msg = Message()
        var nodes = 0
        var bodyParts: [String] = []
        var bodyLen = 0
        var headerFound = false
        var selectedRow: AXUIElement?
        func walk(_ e: AXUIElement, _ depth: Int) {
            if nodes >= 1500 || depth > 40 { return }
            nodes += 1
            let r = role(e)
            if r == "AXTable", selectedRow == nil {
                // The message list: its selected row is the fallback when no
                // reading pane is open (sender, subject and preview in one cell).
                selectedRow = (attr(e, kAXSelectedRowsAttribute) as? [AXUIElement])?.first
            }
            if prunes(e, role: r) { return }
            // The labels ride whichever of title / description Outlook chose
            // for that element — match on all of them.
            if r == "AXGroup" || r == "AXWebArea" {
                let label = text(e)
                if r == "AXGroup", label.hasPrefix("Message header") {
                    headerFound = true
                    parseHeader(e, into: &msg)
                    return
                }
                if r == "AXWebArea", label.localizedCaseInsensitiveContains("reading") {
                    collectText(e, into: &bodyParts, len: &bodyLen)
                    return
                }
            }
            for c in children(e) { walk(c, depth + 1) }
        }
        walk(win, 0)
        msg.body = bodyParts.joined(separator: "\n")
        if !headerFound, let row = selectedRow, let cell = children(row).first ?? Optional(row) {
            msg.subject = text(cell)
        }
        return msg.isEmpty ? nil : msg
    }

    /// Inside "Message header": the first static text is the subject; the
    /// "From:" group names the sender; the "Recipients:" group holds one
    /// button per address. Matched by text, never by position.
    private static func parseHeader(_ header: AXUIElement, into msg: inout Message) {
        var nodes = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            if nodes > 300 || depth > 12 { return }
            nodes += 1
            let r = role(e)
            let t = text(e)
            if r == "AXGroup", t.hasPrefix("From:") {
                let (name, addr) = nameAndAddress(String(t.dropFirst("From:".count)))
                msg.fromName = name
                msg.fromAddress = addr
                return   // its button repeats the same text
            }
            if r == "AXGroup", t.hasPrefix("Recipients:") {
                var found = 0
                func buttons(_ x: AXUIElement, _ d: Int) {
                    if found > 60 || d > 8 { return }
                    if role(x) == "AXButton" {
                        found += 1
                        let (_, addr) = nameAndAddress(text(x))
                        if !addr.isEmpty, !msg.recipients.contains(addr) { msg.recipients.append(addr) }
                        return
                    }
                    for c in children(x) { buttons(c, d + 1) }
                }
                buttons(e, 0)
                return
            }
            if r == "AXStaticText", msg.subject.isEmpty, !t.isEmpty,
               !t.hasPrefix("To:"), !t.hasPrefix("From:"), !t.hasPrefix("Cc:") {
                msg.subject = t
            }
            for c in children(e) { walk(c, depth + 1) }
        }
        walk(header, 0)
    }

    /// "Name, address, availability" → (name, address). Either may be missing.
    static func nameAndAddress(_ s: String) -> (String, String) {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let addr = parts.first { $0.contains("@") && !$0.contains(" ") } ?? ""
        let name = parts.first { !$0.contains("@") } ?? ""
        return (name, addr.lowercased())
    }

    /// Static texts, headings and links of a web area, in order, capped.
    private static func collectText(_ area: AXUIElement, into parts: inout [String], len: inout Int) {
        var nodes = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            if nodes > 800 || depth > 30 || len > 6000 { return }
            nodes += 1
            let r = role(e)
            if r == "AXStaticText" || r == "AXHeading" || r == "AXLink" {
                let v = str(e, kAXValueAttribute) ?? str(e, kAXTitleAttribute) ?? str(e, kAXDescriptionAttribute) ?? ""
                if !v.isEmpty { parts.append(v); len += v.count }
                if r == "AXStaticText" { return }
            }
            for c in children(e) { walk(c, depth + 1) }
        }
        walk(area, 0)
    }

    // MARK: Folders

    /// Every folder name in the sidebar, in sidebar order — section and
    /// account rows (disclosure level 0) skipped, duplicates (a Favorite is
    /// also listed under its account) dropped.
    static func folders() -> [String] {
        guard let app = app(), let win = frontWindow(app) else { return [] }
        var outline: AXUIElement?
        var nodes = 0
        func find(_ e: AXUIElement, _ depth: Int) {
            if outline != nil || nodes > 800 || depth > 30 { return }
            nodes += 1
            let r = role(e)
            if r == "AXOutline" { outline = e; return }
            if r == "AXTable" || r == "AXWebArea" || prunes(e, role: r) { return }
            for c in children(e) { find(c, depth + 1) }
        }
        find(win, 0)
        guard let outline else { return [] }
        let rows = (attr(outline, kAXRowsAttribute) as? [AXUIElement]) ?? []
        var out: [String] = []
        var seen = Set<String>()
        for r in rows.prefix(400) {
            let level = Int(str(r, kAXDisclosureLevelAttribute) ?? "0") ?? 0
            guard level >= 1 else { continue }
            var name = text(children(r).first ?? r)
            if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("@"), !seen.contains(name.lowercased()) else { continue }
            seen.insert(name.lowercased())
            out.append(name)
        }
        return out
    }

    /// The folder a typed fragment means: the exact name, else the shortest
    /// name starting with it, else the shortest containing it; nil when
    /// nothing matches (the caller then sends the fragment as typed).
    static func resolve(_ fragment: String, in folders: [String]) -> String? {
        let f = fragment.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty, !folders.isEmpty else { return nil }
        if let exact = folders.first(where: { $0.lowercased() == f }) { return exact }
        if let p = folders.filter({ $0.lowercased().hasPrefix(f) }).min(by: { $0.count < $1.count }) { return p }
        return folders.filter { $0.lowercased().contains(f) }.min { $0.count < $1.count }
    }
}
