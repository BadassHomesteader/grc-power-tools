import AppKit
import ServiceManagement

/// The app's real window: permission status, dictation options, personal
/// dictionary, and general settings. Built programmatically (no xib).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
    private let store: Store
    private let onConfigChange: (Config) -> Void
    private var config: Config

    private static let claudeModels = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-4-8", "claude-fable-5"]
    private static let openaiModels = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]

    private let statusStack = NSStackView()
    private let hotkeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cleanupPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
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

    init(store: Store, config: Config, onConfigChange: @escaping (Config) -> Void) {
        self.store = store
        self.config = config
        self.onConfigChange = onConfigChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
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

        // Two columns so everything fits on screen without scrolling.
        let leftCol = NSStackView()
        leftCol.orientation = .vertical; leftCol.alignment = .leading; leftCol.spacing = 16
        let rightCol = NSStackView()
        rightCol.orientation = .vertical; rightCol.alignment = .leading; rightCol.spacing = 16

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

        // How-to section (top of the left column for discoverability).
        helpLabel.font = .systemFont(ofSize: 12)
        helpLabel.textColor = .labelColor
        helpLabel.preferredMaxLayoutWidth = 400
        leftCol.addArrangedSubview(section("How to use it", [helpLabel]))

        leftCol.addArrangedSubview(section("Permissions", [statusStack, statusButtons]))

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
        hotkeyNote.font = .systemFont(ofSize: 11)
        hotkeyNote.textColor = .secondaryLabelColor
        hotkeyNote.stringValue = " "

        rightCol.addArrangedSubview(section("Dictation", [
            formRow("Hotkey", hotkeyPopup),
            hotkeyNote,
            formRow("Cleanup", cleanupPopup),
            formRow("Bar position", positionPopup),
        ]))

        // Cloud cleanup section (optional — used only when Cleanup is Claude/OpenAI)
        let cloudNote = NSTextField(labelWithString: "Only used when Cleanup is set to Claude or OpenAI. Keys are saved in a private, owner-only file in the app's data folder, and only the transcribed text is sent — never your audio.")
        cloudNote.font = .systemFont(ofSize: 11)
        cloudNote.textColor = .secondaryLabelColor
        cloudNote.lineBreakMode = .byWordWrapping
        cloudNote.preferredMaxLayoutWidth = 400
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

        rightCol.addArrangedSubview(section("Cloud cleanup (optional)", [
            cloudNote,
            formRow("Claude key", claudeKeyRow),
            formRow("Claude model", claudeModelField),
            formRow("OpenAI key", openaiKeyRow),
            formRow("OpenAI model", openaiModelField),
        ]))

        // Dictionary section
        let col1 = NSTableColumn(identifier: .init("term"))
        col1.title = "Term"
        col1.width = 180
        let col2 = NSTableColumn(identifier: .init("misheard"))
        col2.title = "Sounds like (comma-separated)"
        col2.width = 300
        dictTable.addTableColumn(col1)
        dictTable.addTableColumn(col2)
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
        scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true

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
        leftCol.addArrangedSubview(section("Personal dictionary", [scroll, dictControls]))

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
        let generalButtons = NSStackView(views: [dataBtn, quitBtn])
        generalButtons.spacing = 8
        rightCol.addArrangedSubview(section("General", [launchLoginCheck, generalButtons, version]))

        let columns = NSStackView(views: [leftCol, rightCol])
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

    private func section(_ title: String, _ views: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title.uppercased())
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let content = NSStackView(views: [heading] + views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.cornerRadius = 10
        box.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.widthAnchor.constraint(equalToConstant: 440),
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

        •  T   copy text off the screen (OCR) — drag a box, the text lands on your clipboard
        •  S   copy a screenshot to the clipboard — drag a box to grab it
        •  G   screenshot, then open Google Lens so you can search the image
        •  A   send to AI — rewrites highlighted text, or gives a smarter cleanup

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
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.layer?.backgroundColor = (c.ok ? NSColor.systemGreen : NSColor.systemOrange).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 10).isActive = true

            let name = NSTextField(labelWithString: c.name)
            name.font = .systemFont(ofSize: 12, weight: .medium)
            name.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let detail = NSTextField(labelWithString: c.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byWordWrapping
            detail.preferredMaxLayoutWidth = 330
            detail.cell?.wraps = true

            let row = NSStackView(views: [dot, name, detail])
            row.spacing = 8
            row.alignment = .top
            statusStack.addArrangedSubview(row)
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
