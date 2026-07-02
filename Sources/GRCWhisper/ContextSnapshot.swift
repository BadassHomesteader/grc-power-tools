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

        var secure = IsSecureEventInputEnabled()
        if !secure {
            // Also check the focused AX element for a secure text field.
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
        }
        return ContextSnapshot(appName: appName, bundleID: bundleID, isSecureField: secure)
    }
}
