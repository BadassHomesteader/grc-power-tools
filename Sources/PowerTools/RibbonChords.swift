import Cocoa

/// Microsoft Office's ribbon (Excel, Word, PowerPoint, Outlook) for chord
/// mode, Windows-Alt style. Accessibility only exposes the SELECTED tab's
/// commands, so a tab is opened (pressed) to read it — the way Alt+W opens
/// View before its key tips appear — and what each tab held is remembered
/// in RibbonCache, so later a name search finds Gridlines from anywhere.
/// Every call here is a round trip to the app: off the main thread only.
enum RibbonChords {
    struct Command: Codable, Equatable {
        let title: String
        let role: String
    }
    /// What chord mode sees of the ribbon when it opens.
    struct Snapshot {
        let tabs: [String]
        let selected: String?
        /// The selected tab's commands, read live.
        let live: [Command]
        /// Live commands the app shows greyed out.
        let disabled: Set<String>
    }

    static let commandRoles: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton"]
    /// Pressing one of these opens a dropdown; switching tabs back would close it.
    static let opensDropdown: Set<String> = ["AXMenuButton", "AXPopUpButton"]

    private static func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private static func string(_ e: AXUIElement, _ a: String) -> String { (attr(e, a) as? String) ?? "" }
    private static func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    /// Title, else the description (Office labels most controls by description).
    /// A two-line label ("Draw with⏎Trackpad") becomes one line.
    private static func label(_ e: AXUIElement) -> String {
        let t = string(e, kAXTitleAttribute)
        return (t.isEmpty ? string(e, kAXDescriptionAttribute) : t)
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The ribbon of the app's front window, if it has one.
    static func ribbon(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var window: AXUIElement?
        if let w = attr(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            window = (w as! AXUIElement)   // type checked above
        } else {
            window = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        }
        guard let window else { return nil }
        func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            if label(e).caseInsensitiveCompare("ribbon") == .orderedSame { return e }
            guard depth < 8 else { return nil }
            for c in children(e) { if let f = find(c, depth + 1) { return f } }
            return nil
        }
        return find(window, 0)
    }

    private static func tabElements(_ ribbon: AXUIElement) -> [AXUIElement] {
        children(ribbon).filter { string($0, kAXRoleAttribute) == "AXRadioButton" && !label($0).isEmpty }
    }
    private static func selected(_ tabs: [AXUIElement]) -> String? {
        tabs.first { (attr($0, kAXValueAttribute) as? Int) == 1 }.map(label)
    }

    /// The selected tab's commands, first of each title (a tab can repeat one).
    private static func commandElements(_ ribbon: AXUIElement) -> [(command: Command, element: AXUIElement, enabled: Bool)] {
        var out: [(Command, AXUIElement, Bool)] = []
        var seen: Set<String> = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            let role = string(e, kAXRoleAttribute)
            if commandRoles.contains(role) {
                let l = label(e)
                if !l.isEmpty, seen.insert(l).inserted {
                    out.append((Command(title: l, role: role), e, (attr(e, kAXEnabledAttribute) as? Bool) ?? true))
                }
            }
            guard depth < 12 else { return }
            for c in children(e) { walk(c, depth + 1) }
        }
        for c in children(ribbon) where string(c, kAXRoleAttribute) != "AXRadioButton" { walk(c, 0) }
        return out
    }

    static func snapshot(pid: pid_t) -> Snapshot? {
        guard let r = ribbon(pid: pid) else { return nil }
        let tabs = tabElements(r)
        guard !tabs.isEmpty else { return nil }
        let live = commandElements(r)
        return Snapshot(tabs: tabs.map(label), selected: selected(tabs), live: live.map(\.command),
                        disabled: Set(live.filter { !$0.enabled }.map(\.command.title)))
    }

    /// Select `tab` and wait for its commands to appear: the tab must read
    /// as selected and the command count must hold still for one poll.
    @discardableResult
    static func openTab(pid: pid_t, tab: String, timeout: TimeInterval = 1.0) -> [Command]? {
        guard let r = ribbon(pid: pid), let t = tabElements(r).first(where: { label($0) == tab }) else { return nil }
        if selected(tabElements(r)) != tab {
            guard AXUIElementPerformAction(t, kAXPressAction as CFString) == .success else { return nil }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        while Date() < deadline {
            usleep(50_000)
            guard selected(tabElements(r)) == tab else { continue }
            let cmds = commandElements(r).map(\.command)
            if !cmds.isEmpty, cmds.count == last { return cmds }
            last = cmds.count
        }
        let cmds = commandElements(r).map(\.command)
        return cmds.isEmpty ? nil : cmds
    }

    enum PressResult { case pressed, noRibbon, noTab, noControl }

    /// Press `title` on `tab`, opening the tab first if needed. Afterwards the
    /// ribbon goes back to `restoreTo` — unless the control opened a dropdown,
    /// which switching tabs would close.
    static func press(pid: pid_t, tab: String, title: String, restoreTo: String?) -> PressResult {
        guard let r = ribbon(pid: pid) else { return .noRibbon }
        if selected(tabElements(r)) != tab {
            guard openTab(pid: pid, tab: tab) != nil else { return .noTab }
        }
        guard let hit = commandElements(r).first(where: { $0.command.title == title }) else { return .noControl }
        AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
        if let restoreTo, restoreTo != tab, !opensDropdown.contains(hit.command.role) {
            usleep(150_000)
            openTab(pid: pid, tab: restoreTo, timeout: 0.6)
        }
        return .pressed
    }

    /// The one-time sweep: open every tab, remember its commands, go back
    /// to the tab that was selected. ~0.3 s a tab; the ribbon visibly flicks.
    static func learnAll(pid: pid_t, restoreTo: String? = nil) -> [String: [Command]] {
        guard let snap = snapshot(pid: pid) else { return [:] }
        var out: [String: [Command]] = [:]
        for tab in snap.tabs {
            if let cmds = openTab(pid: pid, tab: tab) { out[tab] = cmds }
        }
        if let back = restoreTo ?? snap.selected { openTab(pid: pid, tab: back, timeout: 0.6) }
        return out
    }
}

/// What each Office app's ribbon tabs held when last seen — ribbon-cache.json
/// beside config.json. Grows as tabs are opened in chord mode (or all at once
/// with the `..` sweep). Read and written from background tasks: locked.
final class RibbonCache: @unchecked Sendable {
    static let shared = RibbonCache()
    private let lock = NSLock()
    private var data: [String: [String: [RibbonChords.Command]]]
    private let url = Config.appSupportDir.appendingPathComponent("ribbon-cache.json")

    private init() {
        data = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([String: [String: [RibbonChords.Command]]].self, from: $0)
        } ?? [:]
    }

    func tabs(bundleID: String) -> [String: [RibbonChords.Command]] {
        lock.lock(); defer { lock.unlock() }
        return data[bundleID] ?? [:]
    }

    func update(bundleID: String, _ tabs: [String: [RibbonChords.Command]]) {
        lock.lock()
        var app = data[bundleID] ?? [:]
        var changed = false
        for (tab, cmds) in tabs where !cmds.isEmpty && app[tab] != cmds {
            app[tab] = cmds
            changed = true
        }
        if changed { data[bundleID] = app }
        let snapshot = data
        lock.unlock()
        guard changed else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(snapshot) { try? d.write(to: url, options: .atomic) }
    }
}
