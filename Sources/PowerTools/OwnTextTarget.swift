import AppKit

/// Dictating into Power Tools' OWN text boxes (Meeting Notes, Agenda, the Live
/// Ask field, Settings fields…). Normal dictation pastes into another app with a
/// synthetic ⌘V; for our own windows we insert straight into the focused text
/// view instead, so the text goes through undo and the box's change handlers.
@MainActor
enum OwnTextTarget {
    /// The editable text view holding the cursor in one of our key windows, or
    /// nil. A focused NSTextField counts too — its field editor is an NSTextView.
    /// `frontmostIsSelf` gates ordinary windows; a non-activating panel (the
    /// floating Live panel) can be key while another app stays frontmost.
    static func current(frontmostIsSelf: Bool) -> NSTextView? {
        // Key window first; while we're frontmost but have no key window for a
        // beat (activation still settling), fall back to our frontmost window.
        let fallback = frontmostIsSelf
            ? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) }
            : nil
        guard let win = NSApp.keyWindow ?? fallback, win.isVisible else { return nil }
        let nonActivating = (win as? NSPanel)?.styleMask.contains(.nonactivatingPanel) ?? false
        guard frontmostIsSelf || nonActivating else { return nil }
        guard let tv = win.firstResponder as? NSTextView, tv.isEditable else { return nil }
        return tv
    }

    /// Insert at the cursor (replacing any selection), with a space before it
    /// when it would otherwise run into the previous word. False if the box is
    /// gone or no longer editable.
    @discardableResult
    static func insert(_ text: String, into tv: NSTextView?) -> Bool {
        guard let tv, tv.window?.isVisible == true, tv.isEditable else { return false }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        var out = text
        if sel.location > 0, sel.location <= ns.length,
           let prev = ns.substring(with: NSRange(location: sel.location - 1, length: 1)).unicodeScalars.first,
           !CharacterSet.whitespacesAndNewlines.contains(prev),
           !(text.first.map { $0.isWhitespace || ".,;:!?".contains($0) } ?? true) {
            out = " " + text
        }
        tv.breakUndoCoalescing()   // each dictation is its own undo step
        tv.insertText(out, replacementRange: sel)
        tv.breakUndoCoalescing()
        return true
    }
}
