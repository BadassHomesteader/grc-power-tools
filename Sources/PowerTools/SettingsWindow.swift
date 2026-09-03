import AppKit
import ServiceManagement

/// The app's real window: permission status, dictation options, personal
/// dictionary, and general settings. Built programmatically (no xib).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate, NSMenuDelegate {
    private let store: Store
    private let onConfigChange: (Config) -> Void
    private let onOpenChat: () -> Void
    private var config: Config

    private static let claudeModels = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-4-8", "claude-fable-5"]
    private static let openaiModels = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]

    private let statusStack = NSStackView()
    private let hotkeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cleanupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let asrPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aiModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let snapSizesPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gridSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchLoginCheck = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let restorePadsCheck = NSButton(checkboxWithTitle: "Reopen pads at launch — Macro/Agent Pads that were open come back", target: nil, action: nil)
    private let snapAssistCheck = NSButton(checkboxWithTitle: "Snap Assist — offer other windows to fill the gap after a snap", target: nil, action: nil)
    private let windowPaletteCheck = NSButton(checkboxWithTitle: "Snap palette (hold hotkey + W)", target: nil, action: nil)
    private let clipboardHistoryCheck = NSButton(checkboxWithTitle: "Clipboard history — hold hotkey + H to paste a recent copy or image", target: nil, action: nil)
    private let whiteboardCheck = NSButton(checkboxWithTitle: "Whiteboard — hold hotkey + E to draw on the last screenshot", target: nil, action: nil)
    private let lastWindowCheck = NSButton(checkboxWithTitle: "⌘⇥ works like Windows Alt-Tab — last window first, per window not app", target: nil, action: nil)
    private let grabMoveCheck = NSButton(checkboxWithTitle: "Grab & Move — hold the modifier and drag anywhere on a window to move it", target: nil, action: nil)
    private let grabModsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let muteDictationCheck = NSButton(checkboxWithTitle: "Mute speakers while dictating — keeps calls & music out of the transcript", target: nil, action: nil)
    private let finderEnterCheck = NSButton(checkboxWithTitle: "Return (⏎) opens the selected file or folder — rename via right-click", target: nil, action: nil)
    private let homeEndCheck = NSButton(checkboxWithTitle: "Home / End jump to line start / end in text fields", target: nil, action: nil)
    private let backspaceUpCheck = NSButton(checkboxWithTitle: "Backspace (Delete ⌫) goes up to the enclosing folder", target: nil, action: nil)
    private let deleteTrashCheck = NSButton(checkboxWithTitle: "Forward Delete (⌦) moves the selection to Trash", target: nil, action: nil)
    private let taskMgrCheck = NSButton(checkboxWithTitle: "Control + Shift + Escape (⌃⇧⎋) opens Activity Monitor (Task Manager)", target: nil, action: nil)
    private var sidebarRows: [SidebarRow] = []
    private var sectionViews: [NSView] = []
    private var contentHost: NSView?
    private let hotkeyNote = NSTextField(labelWithString: "")
    private let helpLabel = NSTextField(wrappingLabelWithString: "")

    private let dictTable = NSTableView()
    private let layoutsTable = NSTableView()
    private var layoutEntries: [LayoutEntry] = []
    private let layoutNameField = NSTextField()
    private let layoutStatus = NSTextField(labelWithString: " ")
    private var dictEntries: [DictEntry] = []
    private let termField = NSTextField()
    private let misheardField = NSTextField()
    private let pronTable = NSTableView()
    private var pronEntries: [(word: String, spoken: String)] = []
    private let pronWordField = NSTextField()
    private let pronSpokenField = NSTextField()
    /// Original key of the row loaded by Edit — a differing key on Save means
    /// a rename, so the old entry is removed instead of left behind.
    private var editingDictTerm: String?
    private var editingPronWord: String?
    private let dictAddBtn = NSButton(title: "Add", target: nil, action: nil)
    private let pronAddBtn = NSButton(title: "Add", target: nil, action: nil)

    private let claudeKeyField = NSSecureTextField()
    private let openaiKeyField = NSSecureTextField()
    private let claudeModelField = NSComboBox()
    private let openaiModelField = NSComboBox()

    // Quick Capture connections: a table + an editor for the selected/new one.
    private let connTable = NSTableView()
    private var connEntries: [Config.Connection] = []
    private var editingConnId: String?   // id being edited (new one gets a fresh UUID)
    private let connNameField = NSTextField()
    private let connLeaderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let captureEndpointField = NSTextField()
    private let captureHeaderField = NSTextField()
    private let captureTokenField = NSSecureTextField()
    private let captureBodyField = NSTextField()
    // Leader letters offered for connections — excludes ones already used by other
    // tools (A T S G C X V P M W H D B) and non-letters (3, arrows, ⏎, ⇥). An
    // existing saved B still works (grandfathered in HotkeyMonitor).
    private static let connLeaderLetters = ["N","E","F","I","J","L","O","Q","R","U","Y","Z"]

    // Macro Pad: enable toggle + the Outlook folder-button editor.
    private let macroPadCheck = NSButton(checkboxWithTitle: "Macro Pad — floating per-app buttons (hold hotkey + B, or menu bar ▸ Macro Pad)", target: nil, action: nil)
    private let macroSummonCheck = NSButton(checkboxWithTitle: "Summon to the cursor — hold hotkey + three-finger tap on the trackpad", target: nil, action: nil)
    private let macroFoldersView = NSTextView()
    private let macroPadStatus = NSTextField(labelWithString: " ")

    // Agent Pad
    private let agentPadCheck = NSButton(checkboxWithTitle: "Agent Pad — floating agent-session panel (hold hotkey + J, or menu bar)", target: nil, action: nil)
    private let agentCodexCheck = NSButton(checkboxWithTitle: "Watch Codex — ChatGPT/Codex threads as rows (watch-only, click to focus)", target: nil, action: nil)
    private let agentCursorCheck = NSButton(checkboxWithTitle: "Watch Cursor — cloud agents + Agents Window sessions (watch-only)", target: nil, action: nil)
    private let hooksStatus = NSTextField(labelWithString: " ")

    // Power Ring: one popup per slot, tag = slot index (clockwise from top).
    private let powerRingCheck = NSButton(checkboxWithTitle: "Power Ring — hold hotkey + right-click for a radial menu at the cursor", target: nil, action: nil)
    private var ringSlotPopups: [NSPopUpButton] = []

    // Macro Pad: general per-app profile & button editor (any app, any chord).
    private var macroProfiles: [Config.MacroProfile] = []
    private let macroProfilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let macroAppPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let macroButtonsTable = NSTableView()
    private let macroBtnTitleField = NSTextField()
    private let macroBtnChordField = NSTextField()
    private let macroBtnTextField = NSTextField()
    private let macroBtnReturnCheck = NSButton(checkboxWithTitle: "press Return at the end", target: nil, action: nil)
    private let macroBtnKeywordsField = NSTextField()
    private let macroEditorStatus = NSTextField(labelWithString: " ")

    init(store: Store, config: Config, onConfigChange: @escaping (Config) -> Void, onOpenChat: @escaping () -> Void = {}) {
        self.store = store
        self.config = config
        self.onConfigChange = onConfigChange
        self.onOpenChat = onOpenChat

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Power Tools"
        window.minSize = NSSize(width: 780, height: 480)
        window.center()
        window.setFrameAutosaveName("GRCWhisperSettingsRail")
        super.init(window: window)
        window.delegate = self
        buildUI()
        connEntries = config.connections   // so the table has rows before show() runs (also used by previews)
        reloadDictionary()
        reloadLayouts()
        Task { await refreshStatus() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await refreshStatus() }
        loadConfigIntoControls()
        reloadLayouts()
    }

    // MARK: Build

    /// Left-rail layout: a sidebar of sections (General · Dictation · Windows ·
    /// AI · Connections · Dictionary · Permissions) with the selected section's
    /// scrollable content on the right.
    private func buildUI() {
        // Control wiring (shared by whichever tab hosts the control).
        for mode in Config.PolishMode.allCases { cleanupPopup.addItem(withTitle: mode.displayName) }
        cleanupPopup.target = self
        cleanupPopup.action = #selector(cleanupChanged)
        for engine in Config.ASREngine.allCases { asrPopup.addItem(withTitle: engine.displayName) }
        asrPopup.target = self
        asrPopup.action = #selector(asrEngineChanged)
        for hk in Config.Hotkey.allCases { hotkeyPopup.addItem(withTitle: hk.displayName) }
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged)
        for p in Config.OverlayPosition.allCases { positionPopup.addItem(withTitle: p.displayName) }
        positionPopup.target = self
        positionPopup.action = #selector(positionChanged)
        for a in Config.Appearance.allCases { appearancePopup.addItem(withTitle: a.displayName) }
        appearancePopup.target = self
        appearancePopup.action = #selector(appearanceChanged)
        for m in Config.AIChatMode.allCases { aiModePopup.addItem(withTitle: m.displayName) }
        aiModePopup.target = self
        aiModePopup.action = #selector(aiModeChanged)
        for s in Config.SnapSizes.allCases { snapSizesPopup.addItem(withTitle: s.displayName) }
        snapSizesPopup.target = self
        snapSizesPopup.action = #selector(snapSizesChanged)
        for g in Config.GridSize.allCases { gridSizePopup.addItem(withTitle: g.displayName) }
        gridSizePopup.target = self
        gridSizePopup.action = #selector(gridSizeChanged)
        for m in Config.GrabModifiers.allCases { grabModsPopup.addItem(withTitle: m.displayName) }
        grabModsPopup.target = self
        grabModsPopup.action = #selector(grabModsChanged)
        hotkeyNote.font = .systemFont(ofSize: 11)
        hotkeyNote.textColor = .secondaryLabelColor
        hotkeyNote.stringValue = " "
        launchLoginCheck.target = self
        launchLoginCheck.action = #selector(toggleLaunchLogin)
        restorePadsCheck.target = self
        restorePadsCheck.action = #selector(restorePadsToggled)
        snapAssistCheck.target = self
        snapAssistCheck.action = #selector(snapAssistToggled)
        powerRingCheck.target = self
        powerRingCheck.action = #selector(powerRingToggled)
        agentPadCheck.target = self
        agentPadCheck.action = #selector(agentPadToggled)
        agentCodexCheck.target = self
        agentCodexCheck.action = #selector(agentCodexToggled)
        agentCursorCheck.target = self
        agentCursorCheck.action = #selector(agentCursorToggled)
        for i in 0..<8 {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for entry in PowerRingCatalog.all { popup.addItem(withTitle: entry.title) }
            popup.tag = i
            popup.target = self
            popup.action = #selector(ringSlotChanged(_:))
            ringSlotPopups.append(popup)
        }
        windowPaletteCheck.target = self
        windowPaletteCheck.action = #selector(windowPaletteToggled)
        clipboardHistoryCheck.target = self
        clipboardHistoryCheck.action = #selector(clipboardHistoryToggled)
        whiteboardCheck.target = self
        whiteboardCheck.action = #selector(whiteboardToggled)
        lastWindowCheck.target = self
        lastWindowCheck.action = #selector(lastWindowToggled)
        grabMoveCheck.target = self
        grabMoveCheck.action = #selector(grabMoveToggled)
        muteDictationCheck.target = self
        muteDictationCheck.action = #selector(muteDictationToggled)
        finderEnterCheck.target = self
        finderEnterCheck.action = #selector(finderEnterToggled)
        for (box, sel) in [(homeEndCheck, #selector(homeEndToggled)),
                           (backspaceUpCheck, #selector(backspaceUpToggled)),
                           (deleteTrashCheck, #selector(deleteTrashToggled)),
                           (taskMgrCheck, #selector(taskMgrToggled))] {
            box.target = self
            box.action = sel
        }

        // Left-rail layout (Wispr-Flow style): a sidebar of sections on the left,
        // the selected section's scrollable content on the right.
        // Ordered for the GENERAL user, not any one power user: universal
        // zero-setup tools first (the ring is the app's best first
        // impression), then the dictation stack, then window/key utilities,
        // then the tools that need configuration or a coding-agent workflow
        // (Connections, the pads), setup last.
        let sections: [(String, String, () -> NSView)] = [
            ("General", "gearshape", generalTab),
            ("Power Ring", "circle.grid.3x3", powerRingTab),
            ("Windows", "macwindow", windowsTab),
            ("Dictation", "mic", dictationTab),
            ("Dictionary", "character.book.closed", dictionaryTab),
            ("AI", "sparkles", aiTab),
            ("Keys", "keyboard", keysTab),
            ("Macro Pad", "square.grid.2x2", macroPadTab),
            ("Agent Pad", "terminal", agentPadTab),
            ("Connections", "link", connectionsTab),
            ("Permissions", "checkmark.shield", permissionsTab),
        ]

        // Sidebar header: app mark + name.
        let mark = NSImageView()
        mark.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        mark.contentTintColor = .labelColor
        let name = NSTextField(labelWithString: "Power Tools")
        name.font = .systemFont(ofSize: 15, weight: .bold)
        let header = NSStackView(views: [mark, name])
        header.spacing = 9
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 8, right: 10)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false
        for (i, s) in sections.enumerated() {
            let row = SidebarRow(icon: s.1, title: s.0) { [weak self] in self?.showSection(i) }
            sidebarRows.append(row)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let sidebar = NSStackView(views: [header, rows])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 10
        sidebar.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 16, right: 12)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        rows.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -24).isActive = true

        // Prebuild each section's scrollable view once (they hold shared controls,
        // so each lives in exactly one place — we show/hide rather than rebuild).
        for s in sections { sectionViews.append(scrollWrap(s.2())) }

        let contentHost = NSView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        self.contentHost = contentHost
        let divider = NSBox(); divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        window?.contentView = root
        let sidebarBG = SidebarBackground()
        sidebarBG.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarBG)
        root.addSubview(sidebar)
        root.addSubview(divider)
        root.addSubview(contentHost)
        NSLayoutConstraint.activate([
            sidebarBG.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarBG.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarBG.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarBG.widthAnchor.constraint(equalToConstant: 196),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 196),
            divider.leadingAnchor.constraint(equalTo: sidebarBG.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            contentHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        loadConfigIntoControls()
        showSection(0)
    }

    /// Show a section by index (also used by the settings-preview CLI).
    func showSection(_ index: Int) {
        guard index >= 0, index < sectionViews.count, let host = contentHost else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        let v = sectionViews[index]
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            v.topAnchor.constraint(equalTo: host.topAnchor),
            v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        for (i, row) in sidebarRows.enumerated() { row.isSelected = (i == index) }
    }

    /// Backward-compatible alias for the preview CLI.
    func selectTab(_ index: Int) { showSection(index) }

    /// Wrap a section's content in a top-pinned scroll view.
    private func scrollWrap(_ content: NSView) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let flip = FlippedClipView()
        scroll.contentView = flip
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: flip.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: flip.leadingAnchor, constant: 22),
            content.trailingAnchor.constraint(lessThanOrEqualTo: flip.trailingAnchor, constant: -18),
        ])
        return scroll
    }

    private func vstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 14
        return s
    }

    private func generalTab() -> NSView {
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .labelColor
        helpLabel.preferredMaxLayoutWidth = 540
        let chatBtn = NSButton(title: "Open AI Chat", target: self, action: #selector(openChat))
        chatBtn.bezelStyle = .rounded
        let dataBtn = NSButton(title: "Open Data Folder", target: self, action: #selector(openDataFolder))
        dataBtn.bezelStyle = .rounded
        let quitBtn = NSButton(title: "Quit Power Tools", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitBtn.bezelStyle = .rounded
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let version = NSTextField(labelWithString: "Local-only · no network · v\(appVersion)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        let buttons = NSStackView(views: [chatBtn, dataBtn, quitBtn])
        buttons.spacing = 8

        return vstack([
            section("How to use it", [helpLabel], width: 590),
            section("General", [clipboardHistoryCheck, whiteboardCheck, launchLoginCheck, restorePadsCheck, buttons, version], width: 590),
        ])
    }

    private func keysTab() -> NSView {
        let note = NSTextField(labelWithString: "Make Finder and text editing behave like Windows. Each key still does its normal job in rename / search fields.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 540
        for c in [finderEnterCheck, homeEndCheck, backspaceUpCheck, deleteTrashCheck, taskMgrCheck] {
            c.lineBreakMode = .byTruncatingTail
        }
        return vstack([
            section("Windows-style keys", [note, finderEnterCheck, homeEndCheck, backspaceUpCheck, deleteTrashCheck, taskMgrCheck], width: 590),
        ])
    }

    @objc private func homeEndToggled() { config.keyHomeEnd = (homeEndCheck.state == .on); config.save(); onConfigChange(config) }
    @objc private func backspaceUpToggled() { config.finderBackspaceUp = (backspaceUpCheck.state == .on); config.save(); onConfigChange(config) }
    @objc private func deleteTrashToggled() { config.finderDeleteTrash = (deleteTrashCheck.state == .on); config.save(); onConfigChange(config) }
    @objc private func taskMgrToggled() { config.taskManagerShortcut = (taskMgrCheck.state == .on); config.save(); onConfigChange(config) }

    private func dictationTab() -> NSView {
        vstack([
            section("Dictation", [
                formRow("Hotkey", hotkeyPopup),
                hotkeyNote,
                formRow("Speech engine", asrPopup),
                formRow("Cleanup", cleanupPopup),
                formRow("Bar position", positionPopup),
                formRow("Theme", appearancePopup),
                formRow("AI (+A)", aiModePopup),
                muteDictationCheck,
            ], width: 480),
        ])
    }

    private func windowsTab() -> NSView {
        // Saved layouts manager (the palette's S/A/B/C chips are the fast path;
        // this is where you see, rename, restore, and delete them).
        let note = NSTextField(labelWithString: "Snapshots of every window's position (hold hotkey + W, then S). Restore repositions windows of running apps.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 500
        let nameCol = NSTableColumn(identifier: .init("layName"))
        nameCol.title = "Layout"
        nameCol.width = 220
        let infoCol = NSTableColumn(identifier: .init("layInfo"))
        infoCol.title = "Windows · saved"
        infoCol.width = 240
        layoutsTable.addTableColumn(nameCol)
        layoutsTable.addTableColumn(infoCol)
        layoutsTable.dataSource = self
        layoutsTable.delegate = self
        layoutsTable.usesAlternatingRowBackgroundColors = true
        layoutsTable.rowHeight = 22
        let scroll = NSScrollView()
        scroll.documentView = layoutsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        layoutNameField.placeholderString = "name — used by Save Current & Rename"
        layoutNameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let renameBtn = NSButton(title: "Rename", target: self, action: #selector(renameLayoutTapped))
        let saveBtn = NSButton(title: "Save Current", target: self, action: #selector(saveLayoutTapped))
        let updateBtn = NSButton(title: "Update from Current", target: self, action: #selector(updateLayoutTapped))
        let restoreBtn = NSButton(title: "Restore", target: self, action: #selector(restoreLayoutTapped))
        let deleteBtn = NSButton(title: "Delete", target: self, action: #selector(deleteLayoutTapped))
        for b in [renameBtn, saveBtn, updateBtn, restoreBtn, deleteBtn] { b.bezelStyle = .rounded }
        let row1 = NSStackView(views: [layoutNameField, renameBtn]); row1.spacing = 8
        let row2 = NSStackView(views: [saveBtn, updateBtn, restoreBtn, deleteBtn]); row2.spacing = 8
        layoutStatus.font = .systemFont(ofSize: 11)
        layoutStatus.textColor = .secondaryLabelColor

        return vstack([
            section("Window snapping", [
                formRow("Snap sizes", snapSizesPopup),
                formRow("Grid (+3)", gridSizePopup),
                snapAssistCheck,
                windowPaletteCheck,
                lastWindowCheck,
                grabMoveCheck,
                formRow("Grab & Move", grabModsPopup),
            ], width: 540),
            section("Saved layouts", [note, scroll, row1, row2, layoutStatus], width: 540),
        ])
    }

    private func reloadLayouts() {
        layoutEntries = store.layouts()
        layoutsTable.reloadData()
    }

    @objc private func saveLayoutTapped() {
        let items = WindowLayouts.snapshot()
        guard !items.isEmpty else { layoutStatus.stringValue = "No windows to save"; return }
        var name = layoutNameField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "MMM d · h:mm a"
            name = f.string(from: Date())
        }
        store.addLayout(name: name, json: WindowLayouts.encode(items))
        layoutNameField.stringValue = ""
        reloadLayouts()
        layoutStatus.stringValue = "Saved “\(name)” · \(items.count) windows"
    }

    @objc private func updateLayoutTapped() {
        let row = layoutsTable.selectedRow
        guard row >= 0, row < layoutEntries.count else { layoutStatus.stringValue = "Select a layout first"; return }
        let items = WindowLayouts.snapshot()
        guard !items.isEmpty else { layoutStatus.stringValue = "No windows to capture"; return }
        store.updateLayoutJSON(id: layoutEntries[row].id, json: WindowLayouts.encode(items))
        reloadLayouts()
        layoutStatus.stringValue = "Updated “\(layoutEntries[row].name)” · \(items.count) windows"
    }

    @objc private func restoreLayoutTapped() {
        let row = layoutsTable.selectedRow
        guard row >= 0, row < layoutEntries.count else { layoutStatus.stringValue = "Select a layout first"; return }
        let r = WindowLayouts.restore(WindowLayouts.decode(layoutEntries[row].json))
        layoutStatus.stringValue = "Restored \(r.restored) of \(r.total) windows"
    }

    @objc private func deleteLayoutTapped() {
        let row = layoutsTable.selectedRow
        guard row >= 0, row < layoutEntries.count else { layoutStatus.stringValue = "Select a layout first"; return }
        store.removeLayout(id: layoutEntries[row].id)
        reloadLayouts()
        layoutStatus.stringValue = "Deleted"
    }

    @objc private func renameLayoutTapped() {
        let row = layoutsTable.selectedRow
        let name = layoutNameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard row >= 0, row < layoutEntries.count else { layoutStatus.stringValue = "Select a layout first"; return }
        guard !name.isEmpty else { layoutStatus.stringValue = "Type a new name first"; return }
        store.renameLayout(id: layoutEntries[row].id, name: name)
        layoutNameField.stringValue = ""
        reloadLayouts()
        layoutStatus.stringValue = "Renamed"
    }

    private func aiTab() -> NSView {
        let cloudNote = NSTextField(labelWithString: "Used when Cleanup is Claude or OpenAI, and for the AI chat (hold your hotkey + A). Keys are saved in a private, owner-only file in the app's data folder — they persist across reinstalls — and only text is ever sent, never your audio.")
        cloudNote.font = .systemFont(ofSize: 11)
        cloudNote.textColor = .secondaryLabelColor
        cloudNote.lineBreakMode = .byWordWrapping
        cloudNote.preferredMaxLayoutWidth = 500
        for f in [claudeKeyField, openaiKeyField, claudeModelField, openaiModelField] {
            f.widthAnchor.constraint(equalToConstant: 220).isActive = true
            f.target = self
        }
        claudeModelField.addItems(withObjectValues: Self.claudeModels)
        openaiModelField.addItems(withObjectValues: Self.openaiModels)
        claudeModelField.completes = true
        openaiModelField.completes = true
        claudeModelField.delegate = self
        openaiModelField.delegate = self
        claudeModelField.action = #selector(modelsChanged)
        openaiModelField.action = #selector(modelsChanged)
        claudeKeyField.action = #selector(saveClaudeKey)
        openaiKeyField.action = #selector(saveOpenaiKey)
        let saveClaude = NSButton(title: "Save", target: self, action: #selector(saveClaudeKey))
        saveClaude.bezelStyle = .rounded
        let saveOpenai = NSButton(title: "Save", target: self, action: #selector(saveOpenaiKey))
        saveOpenai.bezelStyle = .rounded
        let claudeKeyRow = NSStackView(views: [claudeKeyField, saveClaude]); claudeKeyRow.spacing = 8
        let openaiKeyRow = NSStackView(views: [openaiKeyField, saveOpenai]); openaiKeyRow.spacing = 8
        return vstack([
            section("AI · cloud cleanup & chat", [
                cloudNote,
                formRow("Claude key", claudeKeyRow),
                formRow("Claude model", claudeModelField),
                formRow("OpenAI key", openaiKeyRow),
                formRow("OpenAI model", openaiModelField),
            ], width: 560),
        ])
    }

    private func connectionsTab() -> NSView {
        let note = NSTextField(labelWithString: "Quick Capture: hold your hotkey + a connection's letter to pop up an input box, then type or dictate a line and it's POSTed to that connection — a todo app, an n8n webhook, anything. Add as many as you like, each on its own key. %TEXT% in the body becomes what you typed (JSON-escaped); %TODAY% becomes today's date. Inline fields are parsed and stripped from the text — p0–p3 → %PRIORITY%, a natural date (“tomorrow”, “friday”) → %DUE% (yyyy-mm-dd), @word → %CONTEXT%. Tokens are stored in a private, owner-only file like your AI keys; leave the header blank for no auth.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 520

        let nameCol = NSTableColumn(identifier: .init("connName")); nameCol.title = "Name"; nameCol.width = 120
        let keyCol = NSTableColumn(identifier: .init("connKey")); keyCol.title = "Key"; keyCol.width = 40
        let epCol = NSTableColumn(identifier: .init("connEndpoint")); epCol.title = "Endpoint"; epCol.width = 320
        connTable.addTableColumn(nameCol); connTable.addTableColumn(keyCol); connTable.addTableColumn(epCol)
        connTable.dataSource = self
        connTable.delegate = self
        connTable.usesAlternatingRowBackgroundColors = true
        connTable.rowHeight = 22
        let scroll = NSScrollView()
        scroll.documentView = connTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true

        let newBtn = NSButton(title: "New", target: self, action: #selector(newConnection)); newBtn.bezelStyle = .rounded
        let removeBtn = NSButton(title: "Remove", target: self, action: #selector(removeConnection)); removeBtn.bezelStyle = .rounded
        let listButtons = NSStackView(views: [newBtn, removeBtn]); listButtons.spacing = 8

        for l in Self.connLeaderLetters { connLeaderPopup.addItem(withTitle: l) }
        connNameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        connNameField.placeholderString = "Todo"
        for f in [captureEndpointField, captureHeaderField, captureBodyField] {
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        captureTokenField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        captureTokenField.target = self
        captureTokenField.action = #selector(saveCaptureToken)
        captureEndpointField.placeholderString = "https://your-app.example.com/api/tasks"
        captureHeaderField.placeholderString = "X-Api-Key"
        captureBodyField.placeholderString = "{\"title\":\"%TEXT%\"}"
        let saveToken = NSButton(title: "Save token", target: self, action: #selector(saveCaptureToken)); saveToken.bezelStyle = .rounded
        let tokenRow = NSStackView(views: [captureTokenField, saveToken]); tokenRow.spacing = 8
        let saveConnBtn = NSButton(title: "Save connection", target: self, action: #selector(saveConnection)); saveConnBtn.bezelStyle = .rounded

        return vstack([
            section("Connections", [note, scroll, listButtons], width: 560),
            section("Edit connection", [
                formRow("Name", connNameField),
                formRow("Hotkey", connLeaderPopup),
                formRow("Endpoint", captureEndpointField),
                formRow("Auth header", captureHeaderField),
                formRow("Token", tokenRow),
                formRow("Body", captureBodyField),
                saveConnBtn,
            ], width: 560),
        ])
    }

    private func macroPadTab() -> NSView {
        let note = NSTextField(labelWithString: "A floating button pad (like an on-screen Stream Deck) that swaps with the app in front. Clicking a button never steals focus. First profile: Outlook filing — each folder below becomes a button that moves the selected email there (Message ▸ Move, clicked directly since New Outlook dropped its keyboard shortcut → folder name → ⏎). Add keywords after a | and the pad highlights the buttons whose keywords appear in the open email (screenshot + on-device OCR of the reading pane — nothing leaves your Mac). Drag the pad anywhere; ✕ closes it. While the pad is open, hold your hotkey and tap the button's digit (1…9, 0 = tenth) to fire it without clicking — tap several to file several emails in one hold. Buttons aren't limited to moves — any keystroke works (Delete, Archive, Reply…): add them to the Outlook profile in config.json and this editor leaves them alone. Profiles for other apps: also config.json.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 520
        macroPadCheck.target = self
        macroPadCheck.action = #selector(macroPadToggled)
        macroSummonCheck.target = self
        macroSummonCheck.action = #selector(macroSummonToggled)

        let example = NSTextField(labelWithString: "One folder per line, optional keywords:   Projects | acme, quarterly")
        example.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        example.textColor = .secondaryLabelColor

        macroFoldersView.isRichText = false
        macroFoldersView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        macroFoldersView.textContainerInset = NSSize(width: 4, height: 6)
        macroFoldersView.minSize = NSSize(width: 0, height: 0)
        macroFoldersView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        macroFoldersView.isVerticallyResizable = true
        macroFoldersView.isHorizontallyResizable = false
        macroFoldersView.autoresizingMask = [.width]
        macroFoldersView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = macroFoldersView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        macroFoldersView.frame = NSRect(x: 0, y: 0, width: 380, height: 160)

        let saveBtn = NSButton(title: "Save folders", target: self, action: #selector(saveMacroFolders))
        saveBtn.bezelStyle = .rounded
        macroPadStatus.font = .systemFont(ofSize: 11)
        macroPadStatus.textColor = .secondaryLabelColor

        // General editor: any app, any buttons. The Outlook folders box above is
        // the fast path for filing; this is the full control panel.
        let editorNote = NSTextField(labelWithString: "Buttons for any app. Pick a profile (or add one from a running app), then edit its buttons: a keystroke chord (e.g. cmd+shift+m, delete, cmd+r), optional text typed after it, an optional Return, and optional suggestion keywords. Button order = digit order (1…9, 0). Changes apply to the pad immediately.")
        editorNote.font = .systemFont(ofSize: 11)
        editorNote.textColor = .secondaryLabelColor
        editorNote.lineBreakMode = .byWordWrapping
        editorNote.preferredMaxLayoutWidth = 520

        macroProfilePopup.target = self
        macroProfilePopup.action = #selector(macroProfileChanged)
        macroAppPopup.menu?.delegate = self   // repopulate running apps on open
        reloadMacroAppPopup()
        let addProfileBtn = NSButton(title: "Add profile", target: self, action: #selector(addMacroProfile))
        let removeProfileBtn = NSButton(title: "Remove profile", target: self, action: #selector(removeMacroProfile))
        for b in [addProfileBtn, removeProfileBtn] { b.bezelStyle = .rounded }
        let appRow = NSStackView(views: [macroAppPopup, addProfileBtn, removeProfileBtn]); appRow.spacing = 8

        let titleCol = NSTableColumn(identifier: .init("mbTitle")); titleCol.title = "Button"; titleCol.width = 110
        let chordCol = NSTableColumn(identifier: .init("mbChord")); chordCol.title = "Chord"; chordCol.width = 100
        let textCol = NSTableColumn(identifier: .init("mbText")); textCol.title = "Types"; textCol.width = 110
        let retCol = NSTableColumn(identifier: .init("mbRet")); retCol.title = "⏎"; retCol.width = 24
        let kwCol = NSTableColumn(identifier: .init("mbKw")); kwCol.title = "Keywords"; kwCol.width = 120
        for c in [titleCol, chordCol, textCol, retCol, kwCol] { macroButtonsTable.addTableColumn(c) }
        macroButtonsTable.dataSource = self
        macroButtonsTable.delegate = self
        macroButtonsTable.usesAlternatingRowBackgroundColors = true
        macroButtonsTable.rowHeight = 22
        let btnScroll = NSScrollView()
        btnScroll.documentView = macroButtonsTable
        btnScroll.hasVerticalScroller = true
        btnScroll.borderType = .bezelBorder
        btnScroll.translatesAutoresizingMaskIntoConstraints = false
        btnScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        btnScroll.widthAnchor.constraint(equalToConstant: 520).isActive = true

        for f in [macroBtnTitleField, macroBtnChordField, macroBtnTextField, macroBtnKeywordsField] {
            f.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        macroBtnTitleField.placeholderString = "Archive"
        macroBtnChordField.placeholderString = "ctrl+e — blank = just type text"
        macroBtnTextField.placeholderString = "typed after the chord (blank = nothing)"
        macroBtnKeywordsField.placeholderString = "comma separated — lights the button up"
        let addBtn = NSButton(title: "Add button", target: self, action: #selector(addMacroButton))
        let updateBtn = NSButton(title: "Update selected", target: self, action: #selector(updateMacroButton))
        let removeBtn = NSButton(title: "Remove", target: self, action: #selector(removeMacroButton))
        let upBtn = NSButton(title: "↑", target: self, action: #selector(macroButtonUp))
        let downBtn = NSButton(title: "↓", target: self, action: #selector(macroButtonDown))
        for b in [addBtn, updateBtn, removeBtn, upBtn, downBtn] { b.bezelStyle = .rounded }
        let btnRow = NSStackView(views: [addBtn, updateBtn, removeBtn, upBtn, downBtn]); btnRow.spacing = 8
        macroEditorStatus.font = .systemFont(ofSize: 11)
        macroEditorStatus.textColor = .secondaryLabelColor

        return vstack([
            section("Macro Pad", [note, macroPadCheck, macroSummonCheck], width: 560),
            section("Outlook folders", [example, scroll, saveBtn, macroPadStatus], width: 560),
            section("All profiles & buttons", [
                editorNote,
                formRow("Profile", macroProfilePopup),
                formRow("Running app", appRow),
                btnScroll,
                formRow("Title", macroBtnTitleField),
                formRow("Chord", macroBtnChordField),
                formRow("Types", macroBtnTextField),
                formRow("", macroBtnReturnCheck),
                formRow("Keywords", macroBtnKeywordsField),
                btnRow,
                macroEditorStatus,
            ], width: 560),
        ])
    }

    // MARK: Macro Pad general editor

    private var selectedMacroProfileIndex: Int? {
        let i = macroProfilePopup.indexOfSelectedItem
        return (i >= 0 && i < macroProfiles.count) ? i : nil
    }

    /// The bundle id of the profile the popup currently shows (derived from
    /// the item title, never from an index into a possibly-mutated array).
    private var selectedMacroBundleID: String? {
        macroProfilePopup.selectedItem?.title.components(separatedBy: "  —  ").last
    }

    /// Rebuild the profile popup from `macroProfiles`, preserving selection.
    private func reloadMacroProfilesUI(select bundleID: String? = nil, keepEditor: Bool = false) {
        let keep = bundleID ?? selectedMacroBundleID
        macroProfilePopup.removeAllItems()
        for p in macroProfiles {
            macroProfilePopup.addItem(withTitle: "\(p.name)  —  \(p.bundleID)")
        }
        if let keep, let idx = macroProfiles.firstIndex(where: { $0.bundleID == keep }) {
            macroProfilePopup.selectItem(at: idx)
        }
        macroButtonsTable.deselectAll(nil)
        macroButtonsTable.reloadData()
        if !keepEditor { clearMacroButtonEditor() }
    }

    private func reloadMacroAppPopup() {
        // Preserve the picked app across reopens (the menu repopulates every
        // open) so "Add profile" targets what the user chose, not item 0.
        let keep = macroAppPopup.selectedItem?.representedObject as? String
        macroAppPopup.removeAllItems()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != "com.grc.whisper" }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            guard let bid = app.bundleIdentifier else { continue }
            let item = NSMenuItem(title: app.localizedName ?? bid, action: nil, keyEquivalent: "")
            item.representedObject = bid
            macroAppPopup.menu?.addItem(item)
        }
        if let keep, let item = macroAppPopup.menu?.items.first(where: { ($0.representedObject as? String) == keep }) {
            macroAppPopup.select(item)
        }
    }

    private func clearMacroButtonEditor() {
        macroBtnTitleField.stringValue = ""
        macroBtnChordField.stringValue = ""
        macroBtnTextField.stringValue = ""
        macroBtnReturnCheck.state = .off
        macroBtnKeywordsField.stringValue = ""
    }

    /// Persist the working copy and push it live (pad re-renders via didSet).
    /// `touched` = the profile the mutation hit; the Outlook folders quick-box
    /// is only re-derived when Outlook itself changed, so an edit to another
    /// app can never stomp unsaved text typed in that box.
    private func persistMacroProfiles(_ status: String, touched: String?) {
        config.macroPadProfiles = macroProfiles
        config.save()
        onConfigChange(config)
        macroButtonsTable.reloadData()
        macroEditorStatus.stringValue = status
        if let touched, touched.caseInsensitiveCompare("com.microsoft.Outlook") == .orderedSame {
            let outlook = macroProfiles.first { $0.bundleID.caseInsensitiveCompare(touched) == .orderedSame }
            macroFoldersView.string = (outlook?.buttons ?? [])
                .filter { $0.menuPath == Self.macroMoveMenuPath }
                .map { $0.keywords.isEmpty ? $0.title : "\($0.title) | \($0.keywords)" }
                .joined(separator: "\n")
        }
    }

    @objc private func macroProfileChanged() {
        // Deselect BEFORE reload: reloadData preserves a still-valid row index,
        // which would leave Remove/Update aimed at the new profile's row while
        // the editor fields show nothing (same guard as the connections table).
        macroButtonsTable.deselectAll(nil)
        macroButtonsTable.reloadData()
        clearMacroButtonEditor()
    }

    @objc private func addMacroProfile() {
        guard let item = macroAppPopup.selectedItem, let bid = item.representedObject as? String else {
            macroEditorStatus.stringValue = "Pick a running app first"
            return
        }
        if macroProfiles.contains(where: { $0.bundleID.caseInsensitiveCompare(bid) == .orderedSame }) {
            reloadMacroProfilesUI(select: bid)
            macroEditorStatus.stringValue = "Profile already exists — selected it"
            return
        }
        macroProfiles.append(Config.MacroProfile(bundleID: bid, name: item.title, buttons: []))
        reloadMacroProfilesUI(select: bid)
        persistMacroProfiles("Added \(item.title) — now add its buttons below", touched: bid)
    }

    @objc private func removeMacroProfile() {
        guard let idx = selectedMacroProfileIndex else { return }
        let removed = macroProfiles.remove(at: idx)
        reloadMacroProfilesUI(select: macroProfiles.first?.bundleID)
        persistMacroProfiles("Removed \(removed.name)", touched: removed.bundleID)
    }

    /// Editor fields → a MacroButton (nil + alert on a bad chord). This editor
    /// has no Menu Path field of its own (the Outlook folders box above owns
    /// that), so `preserving` carries an existing button's menuPath through an
    /// update instead of the field silently erasing it.
    private func macroButtonFromFields(preserving existing: Config.MacroButton? = nil) -> Config.MacroButton? {
        let title = macroBtnTitleField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { macroEditorStatus.stringValue = "Give the button a title"; return nil }
        let chord = macroBtnChordField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if !chord.isEmpty, MacroPad.parseChord(chord) == nil {
            appAlert("“\(chord)” isn't a valid chord. Use modifiers cmd/shift/ctrl/opt + a letter, digit, or return/tab/space/esc/delete — e.g. cmd+shift+m.")
            return nil
        }
        return Config.MacroButton(
            title: title, chord: chord,
            text: macroBtnTextField.stringValue,
            pressReturn: macroBtnReturnCheck.state == .on,
            keywords: macroBtnKeywordsField.stringValue.trimmingCharacters(in: .whitespaces),
            menuPath: existing?.menuPath ?? "")
    }

    @objc private func addMacroButton() {
        guard let idx = selectedMacroProfileIndex else { macroEditorStatus.stringValue = "Add or pick a profile first"; return }
        guard let button = macroButtonFromFields() else { return }
        macroProfiles[idx].buttons.append(button)
        persistMacroProfiles("Added “\(button.title)” to \(macroProfiles[idx].name)", touched: macroProfiles[idx].bundleID)
    }

    @objc private func updateMacroButton() {
        guard let idx = selectedMacroProfileIndex else { return }
        let row = macroButtonsTable.selectedRow
        guard row >= 0, row < macroProfiles[idx].buttons.count else {
            macroEditorStatus.stringValue = "Select a button row first"
            return
        }
        guard let button = macroButtonFromFields(preserving: macroProfiles[idx].buttons[row]) else { return }
        macroProfiles[idx].buttons[row] = button
        persistMacroProfiles("Updated “\(button.title)”", touched: macroProfiles[idx].bundleID)
        macroButtonsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func removeMacroButton() {
        guard let idx = selectedMacroProfileIndex else { return }
        let row = macroButtonsTable.selectedRow
        guard row >= 0, row < macroProfiles[idx].buttons.count else { return }
        let removed = macroProfiles[idx].buttons.remove(at: row)
        persistMacroProfiles("Removed “\(removed.title)”", touched: macroProfiles[idx].bundleID)
        clearMacroButtonEditor()
    }

    private func moveMacroButton(by delta: Int) {
        guard let idx = selectedMacroProfileIndex else { return }
        let row = macroButtonsTable.selectedRow
        let dest = row + delta
        guard row >= 0, row < macroProfiles[idx].buttons.count,
              dest >= 0, dest < macroProfiles[idx].buttons.count else { return }
        macroProfiles[idx].buttons.swapAt(row, dest)
        persistMacroProfiles("Moved — digits follow the order", touched: macroProfiles[idx].bundleID)
        macroButtonsTable.selectRowIndexes(IndexSet(integer: dest), byExtendingSelection: false)
    }

    @objc private func macroButtonUp() { moveMacroButton(by: -1) }
    @objc private func macroButtonDown() { moveMacroButton(by: 1) }

    /// The menu path the folders editor manages (Message ▸ Move — New Outlook
    /// dropped its ⌘⇧M shortcut, see Config's migration); buttons with any
    /// OTHER menuPath are custom (Delete, Archive, …) and must survive a
    /// folder-list save.
    private static let macroMoveMenuPath = "Message,Move"

    /// Rebuild the Outlook profile's folder-move buttons from the list
    /// ("Name | kw1, kw2" per line). Custom buttons and other apps' profiles
    /// (hand-edited in config.json) are preserved untouched.
    @objc private func saveMacroFolders() {
        let buttons: [Config.MacroButton] = macroFoldersView.string
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line -> Config.MacroButton? in
                // split omits empty subsequences — a line of just "|" yields [].
                let parts = line.split(separator: "|", maxSplits: 1)
                guard let folder = parts.first?.trimmingCharacters(in: .whitespaces), !folder.isEmpty else { return nil }
                let keywords = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                return Config.MacroButton(title: folder, text: folder,
                                          pressReturn: true, keywords: keywords, menuPath: Self.macroMoveMenuPath)
            }
        let outlookID = "com.microsoft.Outlook"
        // Case-insensitive to match MacroPad's runtime lookup — a hand-edited
        // lowercase bundle id must not spawn a duplicate profile.
        if let idx = config.macroPadProfiles.firstIndex(where: { $0.bundleID.caseInsensitiveCompare(outlookID) == .orderedSame }) {
            let existing = config.macroPadProfiles[idx].buttons
            // No-op save must not touch anything: rebuilding would front-load
            // the folder buttons and silently reshuffle custom buttons' digits.
            let unchanged = existing.filter { $0.menuPath == Self.macroMoveMenuPath }
                .map { "\($0.title)|\($0.keywords)" } == buttons.map { "\($0.title)|\($0.keywords)" }
            if unchanged {
                macroPadStatus.stringValue = "No folder changes"
                return
            }
            let custom = existing.filter { $0.menuPath != Self.macroMoveMenuPath }
            let merged = buttons + custom   // folder buttons keep the low digits
            if merged.isEmpty { config.macroPadProfiles.remove(at: idx) }
            else { config.macroPadProfiles[idx].buttons = merged }
        } else if !buttons.isEmpty {
            config.macroPadProfiles.append(Config.MacroProfile(bundleID: outlookID, name: "Outlook", buttons: buttons))
        } else {
            macroPadStatus.stringValue = "No folder changes"
            return
        }
        config.save()
        onConfigChange(config)
        macroPadStatus.stringValue = buttons.isEmpty
            ? "Outlook folder buttons removed"
            : "Saved \(buttons.count) folder button\(buttons.count == 1 ? "" : "s")"
        // Sync the general editor's working copy WITHOUT stealing its selection
        // or wiping fields mid-edit.
        macroProfiles = config.macroPadProfiles
        reloadMacroProfilesUI(select: selectedMacroBundleID, keepEditor: true)
    }

    @objc private func macroPadToggled() {
        config.macroPad = (macroPadCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func macroSummonToggled() {
        config.macroPadThreeFingerTap = (macroSummonCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    private func dictionaryTab() -> NSView {
        let note = NSTextField(labelWithString: "Words dictation should always get right — project names, people, jargon. Add the term plus what the recognizer mishears it as.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 500
        let termCol = NSTableColumn(identifier: .init("term"))
        termCol.title = "Term"
        termCol.width = 140
        let misheardCol = NSTableColumn(identifier: .init("misheard"))
        misheardCol.title = "Sounds like (comma-separated)"
        misheardCol.width = 300
        dictTable.addTableColumn(termCol)
        dictTable.addTableColumn(misheardCol)
        dictTable.dataSource = self
        dictTable.delegate = self
        dictTable.usesAlternatingRowBackgroundColors = true
        dictTable.rowHeight = 22
        let scroll = NSScrollView()
        scroll.documentView = dictTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        termField.placeholderString = "KYAW"
        termField.widthAnchor.constraint(equalToConstant: 115).isActive = true
        misheardField.placeholderString = "K Y A W, kayak"
        misheardField.widthAnchor.constraint(equalToConstant: 185).isActive = true
        dictAddBtn.target = self
        dictAddBtn.action = #selector(addDictEntry)
        dictAddBtn.bezelStyle = .rounded
        let editBtn = NSButton(title: "Edit", target: self, action: #selector(editDictEntry))
        editBtn.bezelStyle = .rounded
        let removeBtn = NSButton(title: "Remove", target: self, action: #selector(removeDictEntry))
        removeBtn.bezelStyle = .rounded
        dictTable.target = self
        dictTable.doubleAction = #selector(editDictEntry)
        let controls = NSStackView(views: [termField, misheardField, dictAddBtn, editBtn, removeBtn])
        controls.spacing = 8

        // Read Aloud pronunciations — the reverse direction: how hold + R SAYS
        // a word, while the personal dictionary above fixes what dictation WRITES.
        let pronNote = NSTextField(labelWithString: "How Read Aloud (hold + R) says a word — names, acronyms, jargon. Write it the way it should sound; only the audio changes, the copied text stays exact. Adding a word again replaces it.")
        pronNote.font = .systemFont(ofSize: 11)
        pronNote.textColor = .secondaryLabelColor
        pronNote.lineBreakMode = .byWordWrapping
        pronNote.preferredMaxLayoutWidth = 500
        let pronWordCol = NSTableColumn(identifier: .init("pronWord"))
        pronWordCol.title = "Word"
        pronWordCol.width = 140
        let pronSpokenCol = NSTableColumn(identifier: .init("pronSpoken"))
        pronSpokenCol.title = "Say it as"
        pronSpokenCol.width = 300
        pronTable.addTableColumn(pronWordCol)
        pronTable.addTableColumn(pronSpokenCol)
        pronTable.dataSource = self
        pronTable.delegate = self
        pronTable.usesAlternatingRowBackgroundColors = true
        pronTable.rowHeight = 22
        let pronScroll = NSScrollView()
        pronScroll.documentView = pronTable
        pronScroll.hasVerticalScroller = true
        pronScroll.borderType = .bezelBorder
        pronScroll.translatesAutoresizingMaskIntoConstraints = false
        pronScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        pronScroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        pronWordField.placeholderString = "KYAW"
        pronWordField.widthAnchor.constraint(equalToConstant: 115).isActive = true
        pronSpokenField.placeholderString = "K Y A W"
        pronSpokenField.widthAnchor.constraint(equalToConstant: 185).isActive = true
        pronAddBtn.target = self
        pronAddBtn.action = #selector(addPronEntry)
        pronAddBtn.bezelStyle = .rounded
        let pronEditBtn = NSButton(title: "Edit", target: self, action: #selector(editPronEntry))
        pronEditBtn.bezelStyle = .rounded
        let pronRemoveBtn = NSButton(title: "Remove", target: self, action: #selector(removePronEntry))
        pronRemoveBtn.bezelStyle = .rounded
        pronTable.target = self
        pronTable.doubleAction = #selector(editPronEntry)
        let pronControls = NSStackView(views: [pronWordField, pronSpokenField, pronAddBtn, pronEditBtn, pronRemoveBtn])
        pronControls.spacing = 8

        return vstack([
            section("Personal dictionary", [note, scroll, controls], width: 560),
            section("Read Aloud pronunciations", [pronNote, pronScroll, pronControls], width: 560),
        ])
    }

    private func agentPadTab() -> NSView {
        let note = NSTextField(labelWithString: "Every live agent session as a row — working / idle / needs you. Click a row to focus it; ✓ ✕ answer Claude Code permission prompts; – collapses to a strip of status lights. Claude Code state arrives via hooks — install them once per machine.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 500
        let installBtn = NSButton(title: "Install Hooks", target: self, action: #selector(installHooksTapped))
        let removeBtn = NSButton(title: "Remove Hooks", target: self, action: #selector(removeHooksTapped))
        for b in [installBtn, removeBtn] { b.bezelStyle = .rounded }
        let hooksRow = NSStackView(views: [installBtn, removeBtn])
        hooksRow.spacing = 8
        hooksStatus.font = .systemFont(ofSize: 11)
        hooksStatus.textColor = .secondaryLabelColor
        hooksStatus.lineBreakMode = .byWordWrapping
        hooksStatus.preferredMaxLayoutWidth = 500
        return vstack([
            section("Agent Pad", [agentPadCheck, note, agentCodexCheck, agentCursorCheck], width: 540),
            section("Claude Code hooks", [hooksRow, hooksStatus], width: 540),
        ])
    }

    private func refreshHooksStatus() {
        hooksStatus.stringValue = ClaudeHooksInstaller.isInstalled()
            ? "Hooks installed ✓ — sessions report live on port \(config.agentPadPort)."
            : "Hooks not installed — Claude Code sessions won't appear on the pad until they are."
    }

    @objc private func agentPadToggled() {
        config.agentPad = (agentPadCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func agentCodexToggled() {
        config.agentPadCodex = (agentCodexCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func restorePadsToggled() {
        config.restorePads = (restorePadsCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func agentCursorToggled() {
        config.agentPadCursor = (agentCursorCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func installHooksTapped() {
        do { hooksStatus.stringValue = try ClaudeHooksInstaller.install(port: config.agentPadPort) }
        catch { hooksStatus.stringValue = "Install failed — \(error.localizedDescription)" }
    }

    @objc private func removeHooksTapped() {
        do { hooksStatus.stringValue = try ClaudeHooksInstaller.remove() }
        catch { hooksStatus.stringValue = "Remove failed — \(error.localizedDescription)" }
    }

    private func powerRingTab() -> NSView {
        let note = NSTextField(labelWithString: "Design the ring: eight slots, clockwise from the top. Hold the hotkey and right-click anywhere to open it — labels are always visible, click a circle (or anywhere in its slice) to fire.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 500
        let slotNames = ["Top", "Top right", "Right", "Bottom right",
                         "Bottom", "Bottom left", "Left", "Top left"]
        let rows = zip(slotNames, ringSlotPopups).map { formRow($0.0, $0.1) }
        return vstack([
            section("Power Ring", [powerRingCheck, note] + rows, width: 540),
        ])
    }

    @objc private func powerRingToggled() {
        config.powerRing = (powerRingCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func ringSlotChanged(_ sender: NSPopUpButton) {
        let i = sender.tag
        let sel = sender.indexOfSelectedItem
        guard i >= 0, i < 8, sel >= 0, sel < PowerRingCatalog.all.count else { return }
        var slots = config.powerRingSlots
        while slots.count < 8 { slots.append(PowerRingCatalog.defaultSlots[slots.count % PowerRingCatalog.defaultSlots.count]) }
        slots[i] = PowerRingCatalog.all[sel].id
        config.powerRingSlots = slots
        config.save()
        onConfigChange(config)
    }

    private func permissionsTab() -> NSView {
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 6
        let recheck = NSButton(title: "Re-check", target: self, action: #selector(recheck))
        recheck.bezelStyle = .rounded
        let openAX = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibility))
        openAX.bezelStyle = .rounded
        let statusButtons = NSStackView(views: [recheck, openAX])
        statusButtons.spacing = 8
        return vstack([
            section("Permissions", [statusStack, statusButtons], width: 590),
        ])
    }

    private func section(_ title: String, _ views: [NSView], width: CGFloat = 340) -> NSView {
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let content = NSStackView(views: [heading] + views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        let box = SectionBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.widthAnchor.constraint(equalToConstant: width),
        ])
        return box
    }

    private func formRow(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [l, control])
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    // MARK: Config

    private func loadConfigIntoControls() {
        config = Config.load()
        reloadPronunciations()
        hotkeyPopup.selectItem(withTitle: config.hotkey.displayName)
        cleanupPopup.selectItem(withTitle: config.polish.displayName)
        asrPopup.selectItem(withTitle: config.asrEngine.displayName)
        positionPopup.selectItem(withTitle: config.overlayPosition.displayName)
        appearancePopup.selectItem(withTitle: config.appearance.displayName)
        aiModePopup.selectItem(withTitle: config.aiChatMode.displayName)
        snapSizesPopup.selectItem(withTitle: config.snapSizes.displayName)
        gridSizePopup.selectItem(withTitle: config.gridSize.displayName)
        snapAssistCheck.state = config.snapAssist ? .on : .off
        windowPaletteCheck.state = config.windowPalette ? .on : .off
        clipboardHistoryCheck.state = config.clipboardHistory ? .on : .off
        whiteboardCheck.state = config.whiteboard ? .on : .off
        lastWindowCheck.state = config.lastWindowSwitch ? .on : .off
        grabMoveCheck.state = config.grabAndMove ? .on : .off
        grabModsPopup.selectItem(withTitle: config.grabMoveModifiers.displayName)
        muteDictationCheck.state = config.muteWhileDictating ? .on : .off
        finderEnterCheck.state = config.finderEnterOpens ? .on : .off
        homeEndCheck.state = config.keyHomeEnd ? .on : .off
        backspaceUpCheck.state = config.finderBackspaceUp ? .on : .off
        deleteTrashCheck.state = config.finderDeleteTrash ? .on : .off
        taskMgrCheck.state = config.taskManagerShortcut ? .on : .off
        applyWindowAppearance()
        launchLoginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        restorePadsCheck.state = config.restorePads ? .on : .off
        claudeModelField.stringValue = config.claudeModel
        openaiModelField.stringValue = config.openaiModel
        claudeKeyField.placeholderString = Keychain.has("claude") ? "•••••• saved — paste to replace" : "sk-ant-…"
        openaiKeyField.placeholderString = Keychain.has("openai") ? "•••••• saved — paste to replace" : "sk-…"
        macroPadCheck.state = config.macroPad ? .on : .off
        macroSummonCheck.state = config.macroPadThreeFingerTap ? .on : .off
        agentPadCheck.state = config.agentPad ? .on : .off
        agentCodexCheck.state = config.agentPadCodex ? .on : .off
        agentCursorCheck.state = config.agentPadCursor ? .on : .off
        refreshHooksStatus()
        powerRingCheck.state = config.powerRing ? .on : .off
        for (i, popup) in ringSlotPopups.enumerated() {
            let id = i < config.powerRingSlots.count ? config.powerRingSlots[i]
                                                     : PowerRingCatalog.defaultSlots[i]
            if let idx = PowerRingCatalog.all.firstIndex(where: { $0.id == id }) {
                popup.selectItem(at: idx)
            }
        }
        let outlook = config.macroPadProfiles.first { $0.bundleID.caseInsensitiveCompare("com.microsoft.Outlook") == .orderedSame }
        // Only the folder-move buttons belong in the editor — a custom button
        // listed here would be converted into a bogus folder on save.
        macroFoldersView.string = (outlook?.buttons ?? [])
            .filter { $0.menuPath == Self.macroMoveMenuPath }
            .map { $0.keywords.isEmpty ? $0.title : "\($0.title) | \($0.keywords)" }
            .joined(separator: "\n")
        macroProfiles = config.macroPadProfiles
        reloadMacroProfilesUI()
        connEntries = config.connections
        connTable.reloadData()
        if connEntries.isEmpty {
            newConnection()
        } else {
            connTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)  // loads editor via delegate
        }
        helpLabel.stringValue = helpText(for: config.hotkey)
    }

    /// Plain-language cheat sheet, kept in sync with the current hotkey choice.
    private func helpText(for hotkey: Config.Hotkey) -> String {
        let key = hotkey.displayName
        return """
        Hold \(key) and speak, then release — your words land at the cursor.

        While holding \(key), tap a key before you release:

        •  A   AI chat — speak your question
        •  T   copy text off the screen (OCR)
        •  R   read text off the screen aloud — hold + R again to stop
        •  S   copy a screenshot
        •  G   screenshot → Google Lens
        •  K   color picker — sample a pixel, copy HEX · RGB · HSL · HSV · CMYK
        •  C / X / V   copy · cut · paste files (Finder)
        •  P   Advanced Paste — plain, or AI: summarize / rewrite / translate
        •  H   clipboard history — paste something you copied earlier
        •  D   new document — Word / Excel / … in the current Finder folder
        •  N   quick capture — send a line to your connection (todo app, webhook)
        •  M   find my mouse — spotlight the cursor
        •  B   macro pad — floating per-app buttons (Outlook folder filing); while it's open, hold + 1…9 fires that button; hold + three-finger tap summons it to the cursor
        •  W   snap palette — halves · quarters · thirds · mini-grid
        •  ← → ↑ ↓   snap window (repeat = resize · chain ← ↑ = corner)
        •  ⏎   maximize   ·   3   draw-a-grid placement

        Release with no key to dictate normally.

        Anytime: ⌘⇥ = last WINDOW first (Alt-Tab style) — walk with ⇥ or arrows, ⇧⌘⇥ backwards. Hold \(config.grabMoveModifiers.glyphs) and drag anywhere on a window to move it. In Finder: ⏎ opens · ⌫ up a folder · ⌦ to Trash. Home/End = line start/end.
        """
    }

    @objc private func saveClaudeKey() {
        let v = claudeKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        Keychain.set(v, account: "claude")
        claudeKeyField.stringValue = ""
        claudeKeyField.placeholderString = "•••••• saved — paste to replace"
    }

    @objc private func saveOpenaiKey() {
        let v = openaiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        Keychain.set(v, account: "openai")
        openaiKeyField.stringValue = ""
        openaiKeyField.placeholderString = "•••••• saved — paste to replace"
    }

    /// Clear the editor for a brand-new connection (fresh id so a token can be
    /// saved before the connection itself is).
    @objc private func newConnection() {
        editingConnId = UUID().uuidString
        connNameField.stringValue = ""
        connLeaderPopup.selectItem(at: 0)
        captureEndpointField.stringValue = ""
        captureHeaderField.stringValue = "X-Api-Key"
        captureBodyField.stringValue = "{\"title\":\"%TEXT%\"}"
        captureTokenField.stringValue = ""
        captureTokenField.placeholderString = "your API key / token"
        connTable.deselectAll(nil)
    }

    /// Upsert the edited connection into the list and persist.
    @objc private func saveConnection() {
        guard let id = editingConnId else { newConnection(); return }
        let endpoint = captureEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            appAlert("Add an endpoint URL before saving this connection.")
            return
        }
        let leader = connLeaderPopup.titleOfSelectedItem ?? "N"
        // Reject a leader already claimed by a different connection.
        if connEntries.contains(where: { $0.id != id && $0.leaderKey.uppercased() == leader.uppercased() }) {
            appAlert("The \(leader) key is already used by another connection. Pick a different letter.")
            return
        }
        let name = connNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = captureHeaderField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = captureBodyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let conn = Config.Connection(id: id, name: name.isEmpty ? "Connection" : name, leaderKey: leader,
                                     endpoint: endpoint, authHeader: header,
                                     bodyTemplate: body.isEmpty ? "{\"title\":\"%TEXT%\"}" : body)
        if let idx = connEntries.firstIndex(where: { $0.id == id }) { connEntries[idx] = conn }
        else { connEntries.append(conn) }
        config.connections = connEntries
        config.save()
        onConfigChange(config)
        connTable.reloadData()
        if let row = connEntries.firstIndex(where: { $0.id == id }) {
            connTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @objc private func removeConnection() {
        let row = connTable.selectedRow
        guard row >= 0, row < connEntries.count else { return }
        let removed = connEntries.remove(at: row)
        Keychain.set("", account: removed.tokenAccount)   // drop its token too
        config.connections = connEntries
        config.save()
        onConfigChange(config)
        connTable.reloadData()
        newConnection()
    }

    @objc private func saveCaptureToken() {
        guard let id = editingConnId else { return }
        let v = captureTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        Keychain.set(v, account: "capture:\(id)")
        captureTokenField.stringValue = ""
        captureTokenField.placeholderString = "•••••• saved — paste to replace"
    }

    private func appAlert(_ message: String) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window ?? NSWindow(), completionHandler: nil)
    }

    @objc private func modelsChanged() {
        let c = claudeModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = openaiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.claudeModel = c.isEmpty ? "claude-haiku-4-5" : c
        config.openaiModel = o.isEmpty ? "gpt-4o-mini" : o
        config.save()
        onConfigChange(config)
    }

    @objc private func cleanupChanged() {
        guard let mode = Config.PolishMode.allCases.first(where: { $0.displayName == cleanupPopup.titleOfSelectedItem }) else { return }
        config.polish = mode
        config.save()
        onConfigChange(config)
    }

    @objc private func asrEngineChanged() {
        guard let engine = Config.ASREngine.allCases.first(where: { $0.displayName == asrPopup.titleOfSelectedItem }) else { return }
        config.asrEngine = engine
        config.save()
        onConfigChange(config)
    }

    @objc private func hotkeyChanged() {
        guard let hk = Config.Hotkey.allCases.first(where: { $0.displayName == hotkeyPopup.titleOfSelectedItem }) else { return }
        let changed = config.hotkey != hk
        config.hotkey = hk
        config.save()
        onConfigChange(config)
        helpLabel.stringValue = helpText(for: hk)
        hotkeyNote.stringValue = changed ? "Quit and reopen Power Tools to apply the new hotkey." : " "
    }

    @objc private func positionChanged() {
        guard let p = Config.OverlayPosition.allCases.first(where: { $0.displayName == positionPopup.titleOfSelectedItem }) else { return }
        config.overlayPosition = p
        config.save()
        onConfigChange(config)
    }

    @objc private func appearanceChanged() {
        guard let a = Config.Appearance.allCases.first(where: { $0.displayName == appearancePopup.titleOfSelectedItem }) else { return }
        config.appearance = a
        config.save()
        applyWindowAppearance()
        onConfigChange(config)
    }

    @objc private func aiModeChanged() {
        guard let m = Config.AIChatMode.allCases.first(where: { $0.displayName == aiModePopup.titleOfSelectedItem }) else { return }
        config.aiChatMode = m
        config.save()
        onConfigChange(config)
    }

    @objc private func snapSizesChanged() {
        guard let s = Config.SnapSizes.allCases.first(where: { $0.displayName == snapSizesPopup.titleOfSelectedItem }) else { return }
        config.snapSizes = s
        config.save()
        onConfigChange(config)
    }

    @objc private func gridSizeChanged() {
        guard let g = Config.GridSize.allCases.first(where: { $0.displayName == gridSizePopup.titleOfSelectedItem }) else { return }
        config.gridSize = g
        config.save()
        onConfigChange(config)
    }

    @objc private func openChat() { onOpenChat() }

    private func applyWindowAppearance() {
        window?.appearance = NSAppearance(named: config.appearance.isDark ? .darkAqua : .aqua)
    }

    /// NSComboBox fires its action on Return/end-editing; also catch list picks.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let box = notification.object as? NSComboBox else { return }
        DispatchQueue.main.async {
            if let value = box.objectValueOfSelectedItem as? String { box.stringValue = value }
            self.modelsChanged()
        }
    }

    @objc private func snapAssistToggled() {
        config.snapAssist = (snapAssistCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func windowPaletteToggled() {
        config.windowPalette = (windowPaletteCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func clipboardHistoryToggled() {
        config.clipboardHistory = (clipboardHistoryCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func whiteboardToggled() {
        config.whiteboard = (whiteboardCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func finderEnterToggled() {
        config.finderEnterOpens = (finderEnterCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func muteDictationToggled() {
        config.muteWhileDictating = (muteDictationCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func lastWindowToggled() {
        config.lastWindowSwitch = (lastWindowCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func grabMoveToggled() {
        config.grabAndMove = (grabMoveCheck.state == .on)
        config.save()
        onConfigChange(config)
    }

    @objc private func grabModsChanged() {
        let idx = grabModsPopup.indexOfSelectedItem
        guard idx >= 0, idx < Config.GrabModifiers.allCases.count else { return }
        config.grabMoveModifiers = Config.GrabModifiers.allCases[idx]
        config.save()
        onConfigChange(config)
        helpLabel.stringValue = helpText(for: config.hotkey)
    }

    @objc private func toggleLaunchLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { log("launch-at-login toggle failed: \(error)") }
        launchLoginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openDataFolder() { NSWorkspace.shared.open(Config.appSupportDir) }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheck() { Task { await refreshStatus() } }

    // MARK: Status

    private func refreshStatus() async {
        let checks = await Doctor.run()
        statusStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for c in checks {
            // Compact: colored bullet + bold name + detail all flow in one wrapping
            // line, so the whole list stays short enough to avoid a scrollbar.
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "●  ", attributes: [
                .foregroundColor: c.ok ? NSColor.systemGreen : NSColor.systemOrange,
                .font: NSFont.systemFont(ofSize: 12),
            ]))
            s.append(NSAttributedString(string: c.name, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ]))
            s.append(NSAttributedString(string: "  \(c.detail)", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11),
            ]))
            let label = NSTextField(labelWithAttributedString: s)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.preferredMaxLayoutWidth = 540
            label.cell?.wraps = true
            statusStack.addArrangedSubview(label)
        }
    }

    // MARK: Dictionary table

    private func reloadDictionary() {
        dictEntries = store.dictionary()
        dictTable.reloadData()
    }

    /// Running-apps popup repopulates every time it opens (apps come and go).
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === macroAppPopup.menu { reloadMacroAppPopup() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === connTable { return connEntries.count }
        if tableView === layoutsTable { return layoutEntries.count }
        if tableView === pronTable { return pronEntries.count }
        if tableView === macroButtonsTable {
            guard let idx = selectedMacroProfileIndex else { return 0 }
            return macroProfiles[idx].buttons.count
        }
        return dictEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === connTable {
            guard row < connEntries.count else { return nil }
            let c = connEntries[row]
            switch tableColumn?.identifier.rawValue {
            case "connName": text = c.name
            case "connKey": text = c.leaderKey
            default: text = c.endpoint
            }
        } else if tableView === macroButtonsTable {
            guard let idx = selectedMacroProfileIndex, row < macroProfiles[idx].buttons.count else { return nil }
            let b = macroProfiles[idx].buttons[row]
            switch tableColumn?.identifier.rawValue {
            case "mbTitle": text = b.title
            case "mbChord": text = b.chord.isEmpty && !b.menuPath.isEmpty
                ? "▸" + b.menuPath.replacingOccurrences(of: ",", with: "▸") : b.chord
            case "mbText": text = b.text
            case "mbRet": text = b.pressReturn ? "⏎" : ""
            default: text = b.keywords
            }
        } else if tableView === layoutsTable {
            guard row < layoutEntries.count else { return nil }
            let l = layoutEntries[row]
            if tableColumn?.identifier.rawValue == "layName" {
                text = l.name
            } else {
                let count = WindowLayouts.decode(l.json).count
                let when = String(l.timestamp.prefix(16)).replacingOccurrences(of: "T", with: " ")
                text = "\(count) windows · \(when)"
            }
        } else if tableView === pronTable {
            guard row < pronEntries.count else { return nil }
            let e = pronEntries[row]
            text = tableColumn?.identifier.rawValue == "pronWord" ? e.word : e.spoken
        } else {
            let entry = dictEntries[row]
            text = tableColumn?.identifier.rawValue == "term" ? entry.term : entry.misheard
        }
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === macroButtonsTable {
            guard let idx = selectedMacroProfileIndex else { return }
            let row = macroButtonsTable.selectedRow
            guard row >= 0, row < macroProfiles[idx].buttons.count else { return }
            let b = macroProfiles[idx].buttons[row]
            macroBtnTitleField.stringValue = b.title
            macroBtnChordField.stringValue = b.chord
            macroBtnTextField.stringValue = b.text
            macroBtnReturnCheck.state = b.pressReturn ? .on : .off
            macroBtnKeywordsField.stringValue = b.keywords
            return
        }
        guard (notification.object as? NSTableView) === connTable else { return }
        let row = connTable.selectedRow
        guard row >= 0, row < connEntries.count else { return }
        let c = connEntries[row]
        editingConnId = c.id
        connNameField.stringValue = c.name
        if let idx = Self.connLeaderLetters.firstIndex(of: c.leaderKey) {
            connLeaderPopup.selectItem(at: idx)
        } else {
            connLeaderPopup.addItem(withTitle: c.leaderKey)   // preserve an unusual saved letter
            connLeaderPopup.selectItem(withTitle: c.leaderKey)
        }
        captureEndpointField.stringValue = c.endpoint
        captureHeaderField.stringValue = c.authHeader
        captureBodyField.stringValue = c.bodyTemplate
        captureTokenField.stringValue = ""
        captureTokenField.placeholderString = Keychain.has(c.tokenAccount) ? "•••••• saved — paste to replace" : "your API key / token"
    }

    @objc private func addDictEntry() {
        let term = termField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        if let old = editingDictTerm, old != term { store.removeDictTerm(old) }  // renamed while editing
        editingDictTerm = nil
        dictAddBtn.title = "Add"
        store.addDictTerm(term, misheard: misheardField.stringValue.trimmingCharacters(in: .whitespaces))
        termField.stringValue = ""
        misheardField.stringValue = ""
        reloadDictionary()
    }

    @objc private func editDictEntry() {
        let row = dictTable.selectedRow
        guard row >= 0, row < dictEntries.count else { return }
        let e = dictEntries[row]
        termField.stringValue = e.term
        misheardField.stringValue = e.misheard
        editingDictTerm = e.term
        dictAddBtn.title = "Save"
        window?.makeFirstResponder(termField)
    }

    @objc private func removeDictEntry() {
        let row = dictTable.selectedRow
        guard row >= 0, row < dictEntries.count else { return }
        store.removeDictTerm(dictEntries[row].term)
        editingDictTerm = nil
        dictAddBtn.title = "Add"
        reloadDictionary()
    }

    // MARK: Read Aloud pronunciations table

    private func reloadPronunciations() {
        pronEntries = config.pronunciations
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (word: $0.key, spoken: $0.value) }
        pronTable.reloadData()
    }

    @objc private func addPronEntry() {
        let word = pronWordField.stringValue.trimmingCharacters(in: .whitespaces)
        let spoken = pronSpokenField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !spoken.isEmpty else { return }
        if let old = editingPronWord, old != word { config.pronunciations.removeValue(forKey: old) }
        editingPronWord = nil
        pronAddBtn.title = "Add"
        config.pronunciations[word] = spoken
        config.save()
        onConfigChange(config)
        pronWordField.stringValue = ""
        pronSpokenField.stringValue = ""
        reloadPronunciations()
    }

    @objc private func editPronEntry() {
        let row = pronTable.selectedRow
        guard row >= 0, row < pronEntries.count else { return }
        let e = pronEntries[row]
        pronWordField.stringValue = e.word
        pronSpokenField.stringValue = e.spoken
        editingPronWord = e.word
        pronAddBtn.title = "Save"
        window?.makeFirstResponder(pronWordField)
    }

    @objc private func removePronEntry() {
        let row = pronTable.selectedRow
        guard row >= 0, row < pronEntries.count else { return }
        config.pronunciations.removeValue(forKey: pronEntries[row].word)
        editingPronWord = nil
        pronAddBtn.title = "Add"
        config.save()
        onConfigChange(config)
        reloadPronunciations()
    }
}

/// Flipped clip view so the scroll document pins to the top, not the bottom.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A left-rail nav row: SF-symbol icon + label, with a rounded accent highlight
/// when selected. Click runs `onClick`.
final class SidebarRow: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let onClick: () -> Void
    var isSelected = false { didSet { needsDisplay = true; applyColors() } }

    init(icon: String, title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView); addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        iconView.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onClick() }
}

/// The sidebar's tinted background panel, re-resolving on theme change.
final class SidebarBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.blended(withFraction: 0.5, of: .controlBackgroundColor)?.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Rounded section card whose fill re-resolves on light/dark theme changes.
/// (A plain `layer.backgroundColor = .cgColor` is a static snapshot and would
/// keep its original shade when the window appearance flips.)
final class SectionBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Runs in this view's effective-appearance context, so the semantic
        // color resolves correctly for the current theme.
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
