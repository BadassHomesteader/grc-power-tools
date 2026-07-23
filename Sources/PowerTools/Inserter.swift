import Foundation
import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Inserts text into whatever app has focus via clipboard-swap paste.
///
/// Recipe (VoiceInk CursorPaster lineage):
/// 1. snapshot ALL pasteboard items/types (text-only snapshots destroy image/file clipboards)
/// 2. write the transcript tagged with a session-UUID type + ConcealedType
///    (clipboard managers like Maccy skip concealed items)
/// 3. verify changeCount advanced before pasting (stale-clipboard-paste guard)
/// 4. synthesize Cmd+V with virtual key 9 (physical V — keyboard-layout-proof)
/// 5. restore the snapshot later ONLY if the pasteboard still holds our UUID
///    (never clobber something the user copied mid-cycle)
enum Inserter {
    private static let sessionType = NSPasteboard.PasteboardType("com.grc.whisper.session")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    /// Snapshot belonging to a paste whose restore hasn't fired yet. A second
    /// insert() inside that window must carry THIS forward instead of snapshotting
    /// the pasteboard — which still holds our own transcript, not the user's data.
    private static var pendingSnapshot: Snapshot?

    enum InsertError: Error, LocalizedError {
        case secureInput
        case pasteboardWriteFailed

        var errorDescription: String? {
            switch self {
            case .secureInput: return "A secure input field is active — can't dictate here"
            case .pasteboardWriteFailed: return "Couldn't write to the clipboard"
            }
        }
    }

    static func insert(_ text: String, restoreDelayMs: Int) throws {
        // Secure-field refusal happens up front at key-down (ContextSnapshot); we
        // don't re-check the global secure-input flag here — it's held session-wide
        // by loginwindow and would wrongly block every paste.
        let pb = NSPasteboard.general

        // 1. Full-fidelity snapshot. Order matters: item.types is richest-first and
        // consumers walk it in order, so store an ordered array, not a dictionary.
        // Never snapshot our own not-yet-restored transcript (session-tagged):
        // rapid back-to-back pastes would later "restore" transcript A over the
        // user's real clipboard. If our item is still on the pasteboard, the
        // user's clipboard is whatever we saved when this window opened.
        let items = pb.pasteboardItems ?? []
        let snapshot: Snapshot
        if items.contains(where: { $0.string(forType: sessionType) != nil }), let pending = pendingSnapshot {
            snapshot = pending
        } else {
            snapshot = items.filter { $0.string(forType: sessionType) == nil }.map { item in
                item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            }
        }

        // 2. Write transcript, marked as ours + concealed.
        let sessionID = UUID().uuidString
        let before = pb.changeCount
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(sessionID, forType: sessionType)
        item.setString("", forType: concealedType)
        guard pb.writeObjects([item]), pb.changeCount != before else {
            // The clipboard was already cleared — put the user's content back
            // before throwing so a failed paste doesn't eat their clipboard.
            restore(snapshot, to: pb)
            pendingSnapshot = nil
            throw InsertError.pasteboardWriteFailed
        }
        pendingSnapshot = snapshot

        // 3./4. Give the pasteboard a beat to settle, then synthetic Cmd+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            postCmdV()
        }

        // 5. Conditional restore.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100 + max(restoreDelayMs, 250))) {
            guard pb.pasteboardItems?.contains(where: {
                $0.string(forType: sessionType) == sessionID
            }) == true else { return } // user copied something meanwhile — leave it alone
            restore(snapshot, to: pb)
            pendingSnapshot = nil
        }
    }

    private static func restore(_ snapshot: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        let restored = snapshot.compactMap { entry -> NSPasteboardItem? in
            guard !entry.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }

    private static func postCmdV() { postCmd(key: CGKeyCode(kVK_ANSI_V)) }

    /// Paste `text` and LEAVE it on the clipboard (clipboard-history pick: the
    /// chosen clip becomes the current clipboard, like Windows Win+V). No session
    /// or concealed markers — this is a deliberate user copy, other clipboard
    /// tools should see it.
    static func pasteLeavingOnClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            postCmdV()
        }
    }

    /// Image variant: PNG + TIFF go on the clipboard (max app compatibility),
    /// then ⌘V. The image stays on the clipboard afterwards.
    static func pasteImageLeavingOnClipboard(_ png: Data) {
        let pb = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.clearContents()
        pb.writeObjects([item])
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            postCmdV()
        }
    }

    /// Type literal text into the focused app as unicode keyboard events — no
    /// clipboard involvement, so it's safe for live-filter search fields (the
    /// Outlook Move dialog) and never disturbs what the user copied. Char by
    /// char with a small gap so filtering UIs keep up.
    static func typeText(_ text: String) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        for ch in text {
            let units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMagic)
            up.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMagic)
            down.post(tap: .cghidEventTap)
            usleep(8_000)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    /// Copy the current selection to a temporary pasteboard, read it, and restore
    /// the user's clipboard. Used by AI command mode to read the selected text.
    /// Returns nil if nothing was copied (no selection).
    static func copySelection() async -> String? {
        guard !IsSecureEventInputEnabled() else { return nil }
        let pb = NSPasteboard.general
        let snapshot: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let before = pb.changeCount
        postCmd(key: CGKeyCode(kVK_ANSI_C))
        try? await Task.sleep(nanoseconds: 150_000_000)
        let copied: String? = (pb.changeCount != before) ? pb.string(forType: .string) : nil

        pb.clearContents()
        let restored = snapshot.compactMap { entry -> NSPasteboardItem? in
            guard !entry.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
        return copied
    }

    private static func postCmd(key vKey: CGKeyCode) { postKey(vKey, flags: .maskCommand) }

    /// Synthesize a modified keystroke into the focused app, tagged so our own tap
    /// passes it through. The physical hotkey modifiers must already be released.
    static func postKey(_ vKey: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMagic)
        up.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMagic)
        down.post(tap: .cghidEventTap)
        usleep(10_000) // 10ms between down and up
        up.post(tap: .cghidEventTap)
    }

    /// Press a menu item by title path (e.g. ["Message", "Move"]) via the
    /// Accessibility API — for actions whose keyboard shortcut an app has
    /// dropped (New Outlook's Move has none anymore) so a chord can't reach
    /// them. `pid` must already be frontmost; same Accessibility grant Power
    /// Tools already holds for the hotkey tap covers this, no extra prompt.
    static func clickMenuItem(pid: pid_t, path: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue else { return false }
        var pool = axChildren(of: (menuBar as! AXUIElement))   // AX attributes are untyped CF; this one's always the menu bar element
        var target: AXUIElement?
        for (i, name) in path.enumerated() {
            guard let match = pool.first(where: { axTitle($0) == name }) else { return false }
            if i == path.count - 1 { target = match; break }
            // Descend past the wrapping AXMenu: a menu bar item's (or menu
            // item's) one child is the menu holding the next level of items.
            guard let submenu = axChildren(of: match).first else { return false }
            pool = axChildren(of: submenu)
        }
        guard let target else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    enum MenuMatchResult {
        case matched         // clicked a submenu item matching the name directly — action is complete
        case openedPicker    // no direct match; clicked a "Choose Folder…"-style escape hatch instead
        case notFound        // path itself didn't resolve, or neither a match nor an escape hatch exists
    }

    /// Click through `path`, then within the LAST item's OWN submenu, click
    /// whichever child's title starts with `name` (case-insensitive) — Outlook
    /// lists real folder names inline there, so this is a direct, reliable
    /// pick. Typing into an open menu is NOT a substitute: macOS treats
    /// keystrokes there as type-ahead item-jump, not text filtering, which is
    /// how typing "APS" once landed on an unrelated "Pin" item instead.
    /// Falls back to a "Choose Folder…" item (opens a real dialog) when the
    /// target isn't in the quick list, so the caller can type into that.
    static func clickMenuItemMatching(pid: pid_t, path: [String], name: String) -> MenuMatchResult {
        guard !path.isEmpty else { return .notFound }
        let app = AXUIElementCreateApplication(pid)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue else { return .notFound }
        var pool = axChildren(of: (menuBar as! AXUIElement))
        for step in path {
            guard let match = pool.first(where: { axTitle($0) == step }),
                  let submenu = axChildren(of: match).first else { return .notFound }
            pool = axChildren(of: submenu)
        }
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let direct = pool.first(where: { (axTitle($0) ?? "").lowercased().hasPrefix(needle) }) {
            return AXUIElementPerformAction(direct, kAXPressAction as CFString) == .success ? .matched : .notFound
        }
        if let picker = pool.first(where: { (axTitle($0) ?? "").localizedCaseInsensitiveContains("choose folder") }) {
            return AXUIElementPerformAction(picker, kAXPressAction as CFString) == .success ? .openedPicker : .notFound
        }
        return .notFound
    }

    private static func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func axTitle(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// File copy = ⌘C (copies selected Finder items to the clipboard).
    static func fileCopy() { postKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand) }

    /// File paste. move=false → ⌘V (copy here); move=true → ⌥⌘V ("Move Item Here"),
    /// which is macOS's real cut-paste for files.
    static func filePaste(move: Bool) {
        postKey(CGKeyCode(kVK_ANSI_V), flags: move ? [.maskCommand, .maskAlternate] : .maskCommand)
    }
}
