import AppKit

// Export one, many, or a whole day of meetings as one Markdown block — made to
// paste into Claude (or any chat bot) or save as a .md file.

struct MeetingExportOptions: Equatable {
    var enhanced = true
    var agenda = true
    var notes = true
    var live = false
    var transcript = true

    private static let key = "meetings.export.include"
    static func load() -> MeetingExportOptions {
        guard let s = UserDefaults.standard.string(forKey: key) else { return MeetingExportOptions() }
        var o = MeetingExportOptions()
        o.enhanced = s.contains("e"); o.agenda = s.contains("a"); o.notes = s.contains("n")
        o.live = s.contains("l"); o.transcript = s.contains("t")
        return o
    }
    func save() {
        let s = (enhanced ? "e" : "") + (agenda ? "a" : "") + (notes ? "n" : "") + (live ? "l" : "") + (transcript ? "t" : "")
        UserDefaults.standard.set(s.isEmpty ? "-" : s, forKey: Self.key)
    }
}

enum MeetingExport {
    /// The selected meetings, oldest first, separated by rules. Pictures become
    /// "[picture]" (a bot can't open file paths on this Mac); the enhanced notes'
    /// and live list's own headings drop one level so each meeting stays one `#`.
    static func text(_ meetings: [Meeting], _ o: MeetingExportOptions) -> String {
        let sorted = meetings.sorted { $0.created < $1.created }
        let blocks = sorted.map { block($0, o) }
        guard sorted.count > 1 else { return blocks.first ?? "" }
        return "\(sorted.count) meetings exported from Power Tools Meeting Notes (oldest first).\n\n"
            + blocks.joined(separator: "\n\n---\n\n")
    }

    static func block(_ m: Meeting, _ o: MeetingExportOptions) -> String {
        var meta = [DateFormatter.localizedString(from: m.created, dateStyle: .full, timeStyle: .short)]
        if m.recordedSeconds >= 60 { meta.append("\(Int(m.recordedSeconds / 60)) min") }
        if let c = m.context, !c.isEmpty { meta.append(c) }
        var parts = ["# \(m.displayTitle)", meta.joined(separator: " · ")]
        func add(_ heading: String, _ body: String?) {
            let b = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !b.isEmpty else { return }
            parts.append("## \(heading)\n\n" + demote(pictures(b)))
        }
        if o.agenda { add("Agenda", m.agenda) }
        if o.enhanced { add("Enhanced notes", m.enhanced) }
        if o.notes { add("My notes", m.notes) }
        if o.live { add("Live list", m.live) }
        if o.transcript, !m.segments.isEmpty { add("Transcript (Me = me, Speaker N = others in the room, Them N = people on the call)", MeetingText.plain(m)) }
        return parts.joined(separator: "\n\n")
    }

    static func pictures(_ s: String) -> String { MeetingImages.rewrite(s) { _ in "[picture]" } }

    /// `# x` → `### x`, `## x` → `### x`: nested under the meeting's `##` sections.
    static func demote(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            guard line.hasPrefix("#") else { return line }
            let hashes = line.prefix { $0 == "#" }.count
            return String(repeating: "#", count: max(3, hashes + 1)) + line.dropFirst(hashes)
        }.joined(separator: "\n")
    }

    static func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// "Today", "Yesterday", else "Tue, Nov 3".
    static func dayLabel(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(d, equalTo: now, toGranularity: .year) ? "EEEMMMd" : "EEEMMMdyyyy")
        return f.string(from: d)
    }

    /// Power_Tools_Meetings_2026.11.05.md (newest selected day).
    static func fileName(_ meetings: [Meeting]) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        let d = meetings.map(\.created).max() ?? Date()
        return "Power_Tools_Meetings_\(f.string(from: d)).md"
    }
}

/// The Export sheet: a day-grouped checklist (tick a day = all its meetings),
/// what to include, a running size, and Copy / Save.
@MainActor
final class MeetingExportSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row { case day(String, [String]); case meeting(Meeting) }

    let window: NSWindow
    private let meetings: [Meeting]
    private var rows: [Row] = []
    private(set) var selected: Set<String>
    private var options = MeetingExportOptions.load()
    private let table = NSTableView()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save…", target: nil, action: nil)
    private var includeBoxes: [NSButton] = []
    /// Copied/saved summary for the caller's status line; nil = cancelled.
    var onDone: ((String?) -> Void)?

    init(meetings: [Meeting], preselect: Set<String>) {
        self.meetings = meetings.sorted { $0.created > $1.created }
        self.selected = preselect.intersection(meetings.map(\.id))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 380)
        super.init()
        buildRows()
        buildUI()
        refresh()
    }

    var exportText: String {
        MeetingExport.text(meetings.filter { selected.contains($0.id) }, options)
    }

    private func buildRows() {
        var byDay: [(String, [Meeting])] = []
        for m in meetings {
            let label = MeetingExport.dayLabel(m.created)
            if let i = byDay.firstIndex(where: { $0.0 == label }) { byDay[i].1.append(m) } else { byDay.append((label, [m])) }
        }
        rows = byDay.flatMap { day, ms in [Row.day(day, ms.map(\.id))] + ms.map(Row.meeting) }
    }

    private func buildUI() {
        guard let content = window.contentView else { return }
        // Paint our own ground so the sheet reads the same everywhere (and in
        // offscreen previews), following Lite/Dark through the appearance.
        let ground = NSBox()
        ground.boxType = .custom
        ground.borderWidth = 0
        ground.fillColor = .windowBackgroundColor
        ground.frame = content.bounds
        ground.autoresizingMask = [.width, .height]
        content.addSubview(ground)
        let title = NSTextField(labelWithString: "Export Meetings")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: "Tick meetings — or a whole day — then Copy and paste into Claude or any chat bot.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r"))
        table.addTableColumn(col)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let all = NSButton(title: "All", target: self, action: #selector(selectAll))
        let none = NSButton(title: "None", target: self, action: #selector(selectNone))
        for b in [all, none] { b.bezelStyle = .rounded; b.controlSize = .small }

        let includeLabel = NSTextField(labelWithString: "Include:")
        includeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let items: [(String, KeyPath<MeetingExportOptions, Bool>)] = [
            ("Agenda", \.agenda), ("Enhanced notes", \.enhanced), ("My notes", \.notes),
            ("Live list", \.live), ("Transcript", \.transcript)]
        includeBoxes = items.enumerated().map { i, item in
            let b = NSButton(checkboxWithTitle: item.0, target: self, action: #selector(includeChanged(_:)))
            b.tag = i
            b.state = options[keyPath: item.1] ? .on : .off
            b.controlSize = .small
            b.font = .systemFont(ofSize: 12)
            return b
        }
        let includeRow = NSStackView(views: [includeLabel] + includeBoxes)
        includeRow.spacing = 12

        sizeLabel.font = .systemFont(ofSize: 12)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self; saveButton.action = #selector(saveClicked)
        copyButton.target = self; copyButton.action = #selector(copyClicked)
        copyButton.keyEquivalent = "\r"
        for b in [cancel, saveButton, copyButton] { b.bezelStyle = .rounded }

        let views: [NSView] = [title, sub, scroll, all, none, includeRow, sizeLabel, cancel, saveButton, copyButton]
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        let p: CGFloat = 20
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: p),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            none.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            none.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            all.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            all.trailingAnchor.constraint(equalTo: none.leadingAnchor, constant: -6),

            scroll.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            scroll.bottomAnchor.constraint(equalTo: includeRow.topAnchor, constant: -12),

            includeRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            includeRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -p),
            includeRow.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -14),

            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -p),
            copyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            saveButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            cancel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            sizeLabel.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            sizeLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sizeLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancel.leadingAnchor, constant: -10),
        ])
        col.width = 500
        table.sizeLastColumnToFit()
    }

    private func refresh() {
        table.reloadData()
        let n = selected.count
        if n == 0 {
            sizeLabel.stringValue = "Nothing selected"
        } else {
            let words = MeetingExport.wordCount(exportText)
            sizeLabel.stringValue = "\(n) meeting\(n == 1 ? "" : "s") · ~\(words.formatted()) words"
        }
        copyButton.isEnabled = n > 0
        saveButton.isEnabled = n > 0
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .day = rows[row] { return 28 }
        return 40
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSView()
        let box: NSButton
        switch rows[row] {
        case .day(let label, let ids):
            box = NSButton(checkboxWithTitle: "\(label)  (\(ids.count))", target: self, action: #selector(dayToggled(_:)))
            box.font = .systemFont(ofSize: 13, weight: .semibold)
            box.allowsMixedState = true
            let n = ids.filter(selected.contains).count
            box.state = n == 0 ? .off : (n == ids.count ? .on : .mixed)
            box.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                box.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                box.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
            ])
        case .meeting(let m):
            box = NSButton(checkboxWithTitle: m.displayTitle, target: self, action: #selector(meetingToggled(_:)))
            box.font = .systemFont(ofSize: 13)
            box.state = selected.contains(m.id) ? .on : .off
            box.lineBreakMode = .byTruncatingTail
            var bits = [DateFormatter.localizedString(from: m.created, dateStyle: .none, timeStyle: .short)]
            if m.recordedSeconds >= 60 { bits.append("\(Int(m.recordedSeconds / 60)) min") }
            if let c = m.context, !c.isEmpty { bits.append(c) }
            bits.append(m.enhanced.isEmpty ? "not enhanced" : "enhanced")
            let detail = NSTextField(labelWithString: bits.joined(separator: " · "))
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            for v in [box, detail] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
            box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 26),
                box.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                box.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
                detail.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                detail.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 1),
            ])
        }
        box.tag = row
        return cell
    }

    // MARK: Actions

    @objc private func dayToggled(_ sender: NSButton) {
        guard case .day(_, let ids) = rows[sender.tag] else { return }
        // Any unticked → tick the whole day; all ticked → clear it.
        if ids.allSatisfy(selected.contains) { selected.subtract(ids) } else { selected.formUnion(ids) }
        refresh()
    }

    @objc private func meetingToggled(_ sender: NSButton) {
        guard case .meeting(let m) = rows[sender.tag] else { return }
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
        refresh()
    }

    @objc private func selectAll() { selected = Set(meetings.map(\.id)); refresh() }
    @objc private func selectNone() { selected = []; refresh() }

    @objc private func includeChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.tag {
        case 0: options.agenda = on
        case 1: options.enhanced = on
        case 2: options.notes = on
        case 3: options.live = on
        default: options.transcript = on
        }
        options.save()
        refresh()
    }

    private func summary(_ verb: String) -> String {
        let n = selected.count
        return "\(verb) \(n) meeting\(n == 1 ? "" : "s") (~\(MeetingExport.wordCount(exportText).formatted()) words)"
    }

    @objc private func copyClicked() {
        let text = exportText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        close(summary("Copied") + " — paste into your bot.")
    }

    @objc private func saveClicked() {
        let text = exportText
        let chosen = meetings.filter { selected.contains($0.id) }
        let msg = summary("Saved")
        let parent = window.sheetParent
        close(nil, notify: false)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = MeetingExport.fileName(chosen)
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { self?.onDone?(nil); return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self?.onDone?(msg + " to \(url.lastPathComponent).")
            } catch {
                self?.onDone?("Couldn't save: \(error.localizedDescription)")
            }
        }
        if let parent { panel.beginSheetModal(for: parent, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    @objc private func cancelClicked() { close(nil) }

    private func close(_ message: String?, notify: Bool = true) {
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
        if notify { onDone?(message) }
    }

    // MARK: Test hooks
    func testToggleDay(_ row: Int) { let b = NSButton(); b.tag = row; dayToggled(b) }
    func testSetOptions(_ o: MeetingExportOptions) { options = o; refresh() }
    var testSizeText: String { sizeLabel.stringValue }
}
