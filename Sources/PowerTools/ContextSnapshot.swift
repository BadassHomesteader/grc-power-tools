import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What we know about where the text is about to land, captured at key-down.
struct ContextSnapshot {
    let appName: String
    let bundleID: String
    let isSecureField: Bool

    static func capture() -> ContextSnapshot {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName ?? "unknown"
        let bundleID = front?.bundleIdentifier ?? ""

        // Only refuse when the FOCUSED field is itself a secure text field.
        // The system-wide IsSecureEventInputEnabled() is NOT a reliable blocker:
        // loginwindow and other background processes hold that flag for the whole
        // login session, which would (and did) block all dictation everywhere.
        var secure = false
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() {
            let axElement = unsafeDowncast(element, to: AXUIElement.self)
            var subrole: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subrole) == .success,
               let s = subrole as? String, s == kAXSecureTextFieldSubrole as String {
                secure = true
            }
        }
        return ContextSnapshot(appName: appName, bundleID: bundleID, isSecureField: secure)
    }

    /// True when the system-wide focused element is a text-editing control —
    /// a rename field, search box, combo box, or any secure field. Used by key
    /// interceptions (Finder ⏎-opens) that must NEVER eat a keystroke meant
    /// for text. Fail-safe: AX errors/timeouts report `true` (treat as text →
    /// pass the key through untouched). Bounded so a busy app can't stall the
    /// event tap: worst case ~50ms, typical well under 5ms.
    static func focusIsTextEditing() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return true }
        let ax = unsafeDowncast(element, to: AXUIElement.self)
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return true }
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String {
            return true
        }
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let sub = subroleRef as? String,
           sub == kAXSecureTextFieldSubrole as String || sub == "AXSearchField" {
            return true
        }
        return false
    }
}
