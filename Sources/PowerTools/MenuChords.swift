import Cocoa

/// One row of chord mode (hold + Space): a code the user can type and what
/// it runs. Built by ChordCatalog from config.json chords plus the front
/// app's menu bar.
struct ChordEntry {
    enum Source { case app, global, menu }
    enum Action { case shortcut(String), menu([String]), shell(String) }
    let code: String
    let name: String
    /// Dim right-hand text: the shortcut as glyphs, "shell", or a submenu.
    let detail: String
    /// The top menu a menu chord lives under (its section header); "" otherwise.
    let group: String
    let source: Source
    let action: Action
    /// Menu items the app reports greyed out. They keep their code — codes
    /// must not shift because nothing happens to be selected — and show
    /// dimmed, but still fire (the report can lag; a failed press says so).
    let enabled: Bool
}

/// Auto menu chords: walk the front app's menu bar through Accessibility and
/// give every item a code built from its title's initials. Same grant as the
/// hotkey tap — no extra prompt.
enum MenuChords {
    struct Item {
        /// Top menu first, item title last ("View", "Show Sidebar").
        let path: [String]
        let enabled: Bool
    }
    struct Walk {
        let items: [Item]
        let ms: Int
        let truncated: Bool
    }

    static let maxItems = 400
    /// A warm walk of a big menu bar (Chrome, Outlook) takes ~130 ms; the
    /// first one after an app launches can take 300+ ms while the app builds
    /// its menus. The panel shows the user's own chords meanwhile.
    static let budget: CFAbsoluteTime = 0.8
    /// Top menu ▸ item ▸ submenu item — deeper is rare and rarely wanted.
    static let maxDepth = 3
    /// Submenus that are the system's or change on every use; their items
    /// would only shift everyone else's codes.
    static let skippedSubmenus: Set<String> = ["Services", "Open Recent", "Recent Items"]
    /// Items per top menu. A browser's Bookmarks or History can hold
    /// hundreds of user entries; without a per-menu cap one of them would
    /// spend the whole budget and leave Window and Help without codes.
    static let perMenuCap = 60

    /// Off the main thread only — every attribute read is a round trip to the app.
    static func walk(pid: pid_t, budget: CFAbsoluteTime = MenuChords.budget, maxItems: Int = MenuChords.maxItems) -> Walk {
        let start = CFAbsoluteTimeGetCurrent()
        let app = AXUIElementCreateApplication(pid)
        // A hung app must not hold chord mode hostage for the 6 s default.
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let bar = menuBar(app) else { return Walk(items: [], ms: 0, truncated: false) }
        var items: [Item] = []
        var truncated = false
        var inThisMenu = 0

        func visit(menu: AXUIElement, path: [String]) {
            // Hidden alternates (Finder's three Ejects, ⌥'s "Empty Trash"
            // beside "Empty Trash…") share a title; the menu press finds the
            // first by title anyway, so only the first gets a code.
            var seen: Set<String> = []
            for el in Inserter.axChildren(of: menu) {
                if items.count >= maxItems || CFAbsoluteTimeGetCurrent() - start > budget {
                    truncated = true
                    return
                }
                if inThisMenu >= perMenuCap { return }
                let (title, enabled, children) = attributes(el)
                guard let title, !title.isEmpty else { continue }   // separators have no title
                guard seen.insert(title.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")).lowercased()).inserted else { continue }
                let itemPath = path + [title]
                if let submenu = children.first {
                    if itemPath.count < maxDepth, !skippedSubmenus.contains(title) {
                        visit(menu: submenu, path: itemPath)
                        if truncated { return }
                    }
                } else {
                    items.append(Item(path: itemPath, enabled: enabled))
                    inThisMenu += 1
                }
            }
        }

        // The first bar item is the Apple menu — the system's, not the app's.
        for top in Inserter.axChildren(of: bar).dropFirst() {
            guard let title = Inserter.axTitle(top), !title.isEmpty,
                  let menu = Inserter.axChildren(of: top).first else { continue }
            inThisMenu = 0
            visit(menu: menu, path: [title])
            if truncated { break }
        }
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return Walk(items: items, ms: ms, truncated: truncated)
    }

    private static func menuBar(_ app: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)   // type checked above
    }

    /// Title, enabled and children in ONE round trip — a menu walk is a few
    /// hundred of these, and three separate reads each tripled its time.
    private static func attributes(_ el: AXUIElement) -> (String?, Bool, [AXUIElement]) {
        let names = [kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, names, [], &values) == .success,
              let list = values as? [Any], list.count == 3 else { return (nil, false, []) }
        // A missing attribute comes back as an AXValue error in its slot, so
        // each cast simply fails rather than throwing.
        return (list[0] as? String, list[1] as? Bool ?? true, list[2] as? [AXUIElement] ?? [])
    }

    /// A Finder-shaped menu bar for the CLI test and preview — with the
    /// clashes the collision ladder exists for (Show Sidebar / Show
    /// Snapshots, Save As… / Select All, New Folder against the user's nf).
    static let previewItems: [Item] = [
        ["Finder", "About Finder"], ["Finder", "Settings…"], ["Finder", "Empty Trash…"], ["Finder", "Hide Finder"],
        ["File", "New Finder Window"], ["File", "New Folder"], ["File", "New Folder with Selection"],
        ["File", "New Tab"], ["File", "Open"], ["File", "Save As…"], ["File", "Close Window"],
        ["Edit", "Undo"], ["Edit", "Cut"], ["Edit", "Copy"], ["Edit", "Paste"], ["Edit", "Select All"],
        ["View", "Show Sidebar"], ["View", "Show Status Bar"], ["View", "Show Tab Bar"],
        ["View", "Sort By", "Name"], ["View", "Sort By", "Date Modified"],
        ["Go", "Back"], ["Go", "Forward"], ["Go", "Enclosing Folder"], ["Go", "Recents"],
        ["Window", "Minimize"], ["Window", "Zoom"], ["Window", "Show Snapshots"],
    ].map { Item(path: $0, enabled: $0.last != "Paste") }

    // MARK: Codes

    static let fillerWords: Set<String> = ["a", "an", "the", "to", "of", "in", "for", "and", "on", "with", "as", "by", "at", "or", "from"]

    /// Lowercase ASCII words of a menu title, filler dropped ("Show All
    /// Tabs…" → show, all, tabs). If only filler remains, it stays. Quoted
    /// parts are dropped.
    static func words(_ title: String) -> [String] {
        // A quoted part is the selection ("Compress “Report.xlsx”") — the
        // code must not change every time something else is selected.
        let unquoted = title.replacingOccurrences(of: #"[“"][^”"]*[”"]"#, with: " ", options: .regularExpression)
        let folded = unquoted
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        let parts = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        let kept = parts.filter { !fillerWords.contains($0) }
        return kept.isEmpty ? parts : kept
    }

    /// Initials of up to four words; a one-word title takes its first two
    /// letters ("Copy" → co, "Show Sidebar" → ss). nil when the title has no
    /// typable letters at all.
    static func baseCode(_ title: String) -> String? {
        let w = words(title)
        guard let first = w.first else { return nil }
        if w.count == 1 { return String(first.prefix(2)) }
        return String(w.prefix(4).compactMap(\.first))
    }

    /// One code per item, in reading order (left to right, top to bottom).
    /// The first item to want a code keeps it; later ones add the next letter
    /// of their last word, then the top menu's initial in front, then a
    /// digit. `taken` holds codes already spoken for (the user's own chords
    /// for this app), so those always win and the menu item moves over.
    /// Deterministic: the same menus always give the same codes.
    static func assignCodes(_ items: [Item], taken reserved: Set<String>) -> [String?] {
        var taken = reserved
        return items.map { item in
            guard let title = item.path.last, let base = baseCode(title) else { return nil }
            let w = words(title)
            var candidates = [base]
            if let last = w.last {
                let rest = w.count == 1 ? last.dropFirst(2) : last.dropFirst(1)
                candidates += rest.map { base + String($0) }
            }
            if let top = item.path.first, let initial = words(top).first?.first {
                candidates.append(String(initial) + base)
            }
            candidates += (2...9).map { base + String($0) }
            guard let code = candidates.first(where: { !taken.contains($0) }) else { return nil }
            taken.insert(code)
            return code
        }
    }
}

/// Turns config + menu walk into the rows chord mode shows and fires.
enum ChordCatalog {
    static func entries(config: Config.ChordConfig, bundleID: String?, menu: [MenuChords.Item]) -> [ChordEntry] {
        var out: [ChordEntry] = []
        let appChords = bundleID.flatMap { id in
            config.apps.first { $0.key.caseInsensitiveCompare(id) == .orderedSame }?.value
        } ?? [:]
        for (code, a) in appChords.sorted(by: { $0.key < $1.key }) {
            if let e = entry(code: code, action: a, source: .app) { out.append(e) }
        }
        for (code, a) in config.global.sorted(by: { $0.key < $1.key }) {
            if let e = entry(code: code, action: a, source: .global) { out.append(e) }
        }
        let reserved = Set(out.map(\.code))
        for (item, code) in zip(menu, MenuChords.assignCodes(menu, taken: reserved)) {
            guard let code else { continue }
            let middle = item.path.count > 2 ? item.path[1..<(item.path.count - 1)].joined(separator: " ▸ ") : ""
            out.append(ChordEntry(code: code, name: item.path.last ?? "", detail: middle,
                                  group: item.path.first ?? "", source: .menu,
                                  action: .menu(item.path), enabled: item.enabled))
        }
        return out
    }

    /// A user-written chord; nil when its code isn't typable or it sets no action.
    private static func entry(code raw: String, action a: Config.ChordAction, source: ChordEntry.Source) -> ChordEntry? {
        let code = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, code.allSatisfy({ typable.contains($0) }) else { return nil }
        let name = a.name.isEmpty ? code : a.name
        if !a.shortcut.isEmpty {
            return ChordEntry(code: code, name: name, detail: glyphs(a.shortcut), group: "",
                              source: source, action: .shortcut(a.shortcut), enabled: true)
        }
        if !a.menu.isEmpty {
            let path = a.menu.split(whereSeparator: { $0 == "," || $0 == "▸" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !path.isEmpty else { return nil }
            return ChordEntry(code: code, name: name, detail: "menu", group: "",
                              source: source, action: .menu(path), enabled: true)
        }
        if !a.shell.isEmpty {
            return ChordEntry(code: code, name: name, detail: "shell", group: "",
                              source: source, action: .shell(a.shell), enabled: true)
        }
        return nil
    }

    /// The characters HotkeyMonitor's chord buffer can hold.
    static let typable = Set("abcdefghijklmnopqrstuvwxyz0123456789/.,;'[]-=")

    /// The chord that runs for `code` — the user's app chords, then global,
    /// then menu (app codes are reserved before menu codes are handed out,
    /// so the order only matters for a hand-written duplicate).
    static func exact(_ code: String, in entries: [ChordEntry]) -> ChordEntry? {
        entries.first { $0.code == code }
    }

    /// "opt+cmd+l" → "⌥⌘L", modifiers in the order macOS menus print them.
    static func glyphs(_ shortcut: String) -> String {
        let parts = shortcut.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last else { return shortcut }
        let mods = Set(parts.dropLast())
        var s = ""
        if mods.contains("ctrl") || mods.contains("control") || mods.contains("⌃") { s += "⌃" }
        if mods.contains("opt") || mods.contains("option") || mods.contains("alt") || mods.contains("⌥") { s += "⌥" }
        if mods.contains("shift") || mods.contains("⇧") { s += "⇧" }
        if mods.contains("cmd") || mods.contains("command") || mods.contains("⌘") { s += "⌘" }
        let named: [String: String] = ["up": "↑", "down": "↓", "left": "←", "right": "→", "return": "↩",
                                       "enter": "⌅", "tab": "⇥", "space": "Space", "esc": "⎋", "escape": "⎋",
                                       "delete": "⌫"]
        return s + (named[key] ?? key.uppercased())
    }
}
