import Foundation
import AppKit
import Carbon.HIToolbox

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
        let snapshot: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
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
            throw InsertError.pasteboardWriteFailed
        }

        // 3./4. Give the pasteboard a beat to settle, then synthetic Cmd+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            postCmdV()
        }

        // 5. Conditional restore.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100 + max(restoreDelayMs, 250))) {
            guard pb.pasteboardItems?.contains(where: {
                $0.string(forType: sessionType) == sessionID
            }) == true else { return } // user copied something meanwhile — leave it alone
            pb.clearContents()
            let restored = snapshot.compactMap { entry -> NSPasteboardItem? in
                guard !entry.isEmpty else { return nil }
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pb.writeObjects(restored) }
        }
    }

    private static func postCmdV() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V) // virtual key 9: physical V, layout-proof
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMagic)
        up.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMagic)
        down.post(tap: .cghidEventTap)
        usleep(10_000) // 10ms between down and up
        up.post(tap: .cghidEventTap)
    }
}
