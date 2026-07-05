import AppKit
import ServiceManagement

/// The app's real window: permission status, dictation options, personal
/// dictionary, and general settings. Built programmatically (no xib).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
    private let store: Store
    private let onConfigChange: (Config) -> Void
    private let onOpenChat: () -> Void
    private var config: Config

    private static let claudeModels = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-4-8", "claude-fable-5"]
    private static let openaiModels = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]

    private let statusStack = NSStackView()
    private let hotkeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cleanupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appearancePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aiModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let launchLoginCheck = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let hotkeyNote = NSTextField(labelWithString: "")
    private let helpLabel = NSTextField(wrappingLabelWithString: "")

    private let dictTable = NSTableView()
    private var dictEntries: [DictEntry] = []
    private let termField = NSTextField()
    private let misheardField = NSTextField()

    private let claudeKeyField = NSSecureTextField()
    private let openaiKeyField = NSSecureTextField()
    private let claudeModelField = NSComboBox()
    private let openaiModelField = NSComboBox()

    init(store: Store, config: Config, onConfigChange: @escaping (Config) -> Void, onOpenChat: @escaping () -> Void = {}) {
        self.store = store
        self.config = config
        self.onConfigChange = onConfigChange
        self.onOpenChat = onOpenChat

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "GRC Whisper"
        window.center()
        window.setFrameAutosaveName("GRCWhisperSettings")
        super.init(window: window)
        window.delegate = self
        buildUI()
        reloadDictionary()
        Task { await refreshStatus() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await refreshStatus() }
        loadConfigIntoControls()
    }

    // MARK: Build

    private func buildUI() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let title = NSTextField(labelWithString: "GRC Whisper")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Hold your hotkey, speak, release — text lands where your cursor is. Everything runs on this Mac.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.preferredMaxLayoutWidth = 520
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        root.addArrangedSubview(header)

        // Three columns so everything fits on screen without scrolling:
        //  1) how-to + dictation   2) permissions + dictionary   3) AI keys + general
        let col1 = NSStackView()
        col1.orientation = .vertical; col1.alignment = .leading; col1.spacing = 16
        let col2 = NSStackView()
        col2.orientation = .vertical; col2.alignment = .leading; col2.spacing = 16
        let col3 = NSStackView()
        col3.orientation = .vertical; col3.alignment = .leading; col3.spacing = 16

        // Status section
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 6
        let recheck = NSButton(title: "Re-check", target: self, action: #selector(recheck))
        recheck.bezelStyle = .rounded
        let openAX = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibility))
        openAX.bezelStyle = .rounded
        let statusButtons = NSStackView(views: [recheck, openAX])
        statusButtons.spacing = 8

        // Column 1 · How-to (top for discoverability).
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .labelColor
        helpLabel.preferredMaxLayoutWidth = 300
        col1.addArrangedSubview(section("How to use it", [helpLabel], width: 340))

        // Column 2 · Permissions ("the green lights").
        col2.addArrangedSubview(section("Permissions", [statusStack, statusButtons], width: 360))

        // Dictation section
        for mode in Config.PolishMode.allCases { cleanupPopup.addItem(withTitle: mode.displayName) }
        cleanupPopup.target = self
        cleanupPopup.action = #selector(cleanupChanged)
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
        hotkeyNote.font = .systemFont(ofSize: 11)
        hotkeyNote.textColor = .secondaryLabelColor
        hotkeyNote.stringValue = " "

        col1.addArrangedSubview(section("Dictation", [
            formRow("Hotkey", hotkeyPopup),
            hotkeyNote,
            formRow("Cleanup", cleanupPopup),
            formRow("Bar position", positionPopup),
            formRow("Theme", appearancePopup),
            formRow("AI (+A)", aiModePopup),
        ], width: 340))

        // Cloud cleanup section (optional — used only when Cleanup is Claude/OpenAI)
        let cloudNote = NSTextField(labelWithString: "Used when Cleanup is Claude or OpenAI, and for the AI chat (hold your hotkey + A). Keys are saved in a private, owner-only file in the app's data folder — they persist across reinstalls — and only text is ever sent, never your audio.")
        cloudNote.font = .systemFont(ofSize: 11)
        cloudNote.textColor = .secondaryLabelColor
        cloudNote.lineBreakMode = .byWordWrapping
        cloudNote.preferredMaxLayoutWidth = 360
        for f in [claudeKeyField, openaiKeyField, claudeModelField, openaiModelField] {
            f.widthAnchor.constraint(equalToConstant: 200).isActive = true
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

        // Column 3 · AI API keys.
        col3.addArrangedSubview(section("AI · cloud cleanup & chat", [
            cloudNote,
            formRow("Claude key", claudeKeyRow),
            formRow("Claude model", claudeModelField),
            formRow("OpenAI key", openaiKeyRow),
            formRow("OpenAI model", openaiModelField),
        ], width: 400))

        // Dictionary section
        let termCol = NSTableColumn(identifier: .init("term"))
        termCol.title = "Term"
        termCol.width = 110
        let misheardCol = NSTableColumn(identifier: .init("misheard"))
        misheardCol.title = "Sounds like (comma-separated)"
        misheardCol.width = 180
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
        scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 320).isActive = true

        termField.placeholderString = "KYAW"
        termField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        misheardField.placeholderString = "K Y A W, kayak"
        misheardField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let addBtn = NSButton(title: "Add", target: self, action: #selector(addDictEntry))
        addBtn.bezelStyle = .rounded
        let removeBtn = NSButton(title: "Remove", target: self, action: #selector(removeDictEntry))
        removeBtn.bezelStyle = .rounded
        let dictFields = NSStackView(views: [termField, misheardField]); dictFields.spacing = 8
        let dictButtons = NSStackView(views: [addBtn, removeBtn]); dictButtons.spacing = 8
        let dictControls = NSStackView(views: [dictFields, dictButtons])
        dictControls.orientation = .vertical; dictControls.alignment = .leading; dictControls.spacing = 8
        col2.addArrangedSubview(section("Personal dictionary", [scroll, dictControls], width: 360))

        // General section
        launchLoginCheck.target = self
        launchLoginCheck.action = #selector(toggleLaunchLogin)
        let dataBtn = NSButton(title: "Open Data Folder", target: self, action: #selector(openDataFolder))
        dataBtn.bezelStyle = .rounded
        let quitBtn = NSButton(title: "Quit GRC Whisper", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitBtn.bezelStyle = .rounded
        let version = NSTextField(labelWithString: "Local-only · no network · v1.0.0")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        let chatBtn = NSButton(title: "Open AI Chat", target: self, action: #selector(openChat))
        chatBtn.bezelStyle = .rounded
        let generalButtons = NSStackView(views: [dataBtn, quitBtn])
        generalButtons.spacing = 8
        col3.addArrangedSubview(section("General", [chatBtn, launchLoginCheck, generalButtons, version], width: 400))

        let columns = NSStackView(views: [col1, col2, col3])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 18
        root.addArrangedSubview(columns)

        // Scroll container
        let outerScroll = NSScrollView()
        outerScroll.hasVerticalScroller = true
        outerScroll.drawsBackground = false
        outerScroll.translatesAutoresizingMaskIntoConstraints = false
        let flip = FlippedClipView()
        outerScroll.contentView = flip
        outerScroll.documentView = root
        window?.contentView = outerScroll
        if let cv = window?.contentView {
            NSLayoutConstraint.activate([
                outerScroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                outerScroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                outerScroll.topAnchor.constraint(equalTo: cv.topAnchor),
                outerScroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
                root.topAnchor.constraint(equalTo: flip.topAnchor),
                root.leadingAnchor.constraint(equalTo: flip.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: flip.trailingAnchor),
            ])
        }
        loadConfigIntoControls()
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
        hotkeyPopup.selectItem(withTitle: config.hotkey.displayName)
        cleanupPopup.selectItem(withTitle: config.polish.displayName)
        positionPopup.selectItem(withTitle: config.overlayPosition.displayName)
        appearancePopup.selectItem(withTitle: config.appearance.displayName)
        aiModePopup.selectItem(withTitle: config.aiChatMode.displayName)
        applyWindowAppearance()
        launchLoginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        claudeModelField.stringValue = config.claudeModel
        openaiModelField.stringValue = config.openaiModel
        claudeKeyField.placeholderString = Keychain.has("claude") ? "•••••• saved — paste to replace" : "sk-ant-…"
        openaiKeyField.placeholderString = Keychain.has("openai") ? "•••••• saved — paste to replace" : "sk-…"
        helpLabel.stringValue = helpText(for: config.hotkey)
    }

    /// Plain-language cheat sheet, kept in sync with the current hotkey choice.
    private func helpText(for hotkey: Config.Hotkey) -> String {
        let key = hotkey.displayName
        return """
        Hold \(key) and speak, then release — your words are cleaned up and typed in wherever your cursor is.

        While still holding \(key), tap a letter before you release:

        •  A   open an AI chat — say your question, Claude answers
        •  T   copy text off the screen (OCR) — drag a box, it lands on your clipboard
        •  S   copy a screenshot — drag a box to grab it
        •  G   screenshot, then open Google Lens to search it
        •  C   copy the selected file(s) in Finder
        •  X   cut file(s) — then V moves them
        •  V   paste — moves cut files, or pastes copied ones

        Just release without a letter to dictate normally.
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

    @objc private func hotkeyChanged() {
        guard let hk = Config.Hotkey.allCases.first(where: { $0.displayName == hotkeyPopup.titleOfSelectedItem }) else { return }
        let changed = config.hotkey != hk
        config.hotkey = hk
        config.save()
        onConfigChange(config)
        helpLabel.stringValue = helpText(for: hk)
        hotkeyNote.stringValue = changed ? "Quit and reopen GRC Whisper to apply the new hotkey." : " "
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
            label.preferredMaxLayoutWidth = 320
            label.cell?.wraps = true
            statusStack.addArrangedSubview(label)
        }
    }

    // MARK: Dictionary table

    private func reloadDictionary() {
        dictEntries = store.dictionary()
        dictTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { dictEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = dictEntries[row]
        let text = tableColumn?.identifier.rawValue == "term" ? entry.term : entry.misheard
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    @objc private func addDictEntry() {
        let term = termField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        store.addDictTerm(term, misheard: misheardField.stringValue.trimmingCharacters(in: .whitespaces))
        termField.stringValue = ""
        misheardField.stringValue = ""
        reloadDictionary()
    }

    @objc private func removeDictEntry() {
        let row = dictTable.selectedRow
        guard row >= 0, row < dictEntries.count else { return }
        store.removeDictTerm(dictEntries[row].term)
        reloadDictionary()
    }
}

/// Flipped clip view so the scroll document pins to the top, not the bottom.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
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
