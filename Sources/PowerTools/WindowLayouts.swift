import Cocoa
import ApplicationServices

/// Saved layouts: snapshot every on-screen window's position, restore later —
/// "meeting mode" / "deep work mode" in one keystroke from the snap palette.
/// Restore only repositions windows of RUNNING apps (no app launching);
/// windows are matched by app bundle id, then by title, then first-unused.
enum WindowLayouts {
    struct Item: Codable {
        let bundleID: String
        let title: String
        let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat  // CG global (top-left origin)
    }

    /// Capture all normal on-screen windows (excluding our own overlays/palettes).
    static func snapshot() -> [Item] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        var items: [Item] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"],
                  width >= 120, height >= 90,
                  let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  bundleID != "com.grc.whisper" else { continue }
            let title = (w[kCGWindowName as String] as? String) ?? ""
            items.append(Item(bundleID: bundleID, title: title,
                              x: b["X"] ?? 0, y: b["Y"] ?? 0, w: width, h: height))
        }
        return items
    }

    /// Apply a snapshot. Returns (restored, total).
    @discardableResult
    static func restore(_ items: [Item]) -> (restored: Int, total: Int) {
        var restored = 0
        // Group by app so each app's window list is fetched once and windows
        // aren't double-assigned.
        let byApp = Dictionary(grouping: items, by: { $0.bundleID })
        for (bundleID, wants) in byApp {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
                  var windows = ref as? [AXUIElement], !windows.isEmpty else { continue }

            func title(of win: AXUIElement) -> String {
                var t: CFTypeRef?
                guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t) == .success else { return "" }
                return (t as? String) ?? ""
            }

            for want in wants {
                // Best match: exact title, then any window left.
                let idx = windows.firstIndex(where: { !want.title.isEmpty && title(of: $0) == want.title })
                       ?? (windows.isEmpty ? nil : 0)
                guard let idx else { continue }
                let win = windows.remove(at: idx)
                setFrameCG(win, x: want.x, y: want.y, w: want.w, h: want.h)
                restored += 1
            }
        }
        return (restored, items.count)
    }

    /// AX set using CG (top-left global) coordinates directly — no Cocoa flip
    /// needed since both use top-left origin. Size→pos→size like WindowManager.
    private static func setFrameCG(_ win: AXUIElement, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        var pos = CGPoint(x: x, y: y)
        var size = CGSize(width: w, height: h)
        if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv) }
    }

    static func encode(_ items: [Item]) -> String {
        guard let data = try? JSONEncoder().encode(items) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func decode(_ json: String) -> [Item] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }
}
