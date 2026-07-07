import Cocoa

/// Menu-bar calendar — the "click the Windows taskbar clock" gap. A second
/// status item showing today's date; clicking it opens a month-grid popover
/// (Itsycal-style, display-only: no Calendar permission needed).
@MainActor
final class MenuCalendar: NSObject {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var midnightTimer: Timer?

    override init() {
        super.init()
        let vc = NSViewController()
        let grid = MonthGridView(frame: NSRect(x: 0, y: 0, width: 264, height: 268))
        vc.view = grid
        popover.contentViewController = vc
        popover.behavior = .transient
    }

    func setVisible(_ on: Bool) {
        if on && item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            it.button?.title = Self.title()
            it.button?.font = .systemFont(ofSize: 12, weight: .medium)
            it.button?.target = self
            it.button?.action = #selector(toggle(_:))
            item = it
            // Refresh the title as the date rolls over (hourly check is plenty).
            midnightTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.item?.button?.title = Self.title() }
            }
            log("calendar: status item installed")
        } else if !on, let it = item {
            popover.performClose(nil)
            midnightTimer?.invalidate()
            midnightTimer = nil
            NSStatusBar.system.removeStatusItem(it)
            item = nil
            log("calendar: status item removed")
        }
    }

    private static func title() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f.string(from: Date())
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            (popover.contentViewController?.view as? MonthGridView)?.goToday()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

/// A month grid: header with ◀ month ▶, weekday initials, day cells, today
/// filled in accent. Display-only; ◀ ▶ browse months, ⌾ returns to today.
final class MonthGridView: NSView {
    private var shownMonth: Date = Date()
    private let cal = Calendar.current

    override init(frame: NSRect) {
        super.init(frame: frame)
        let prev = NSButton(title: "◀", target: self, action: #selector(prevMonth))
        let next = NSButton(title: "▶", target: self, action: #selector(nextMonth))
        let today = NSButton(title: "Today", target: self, action: #selector(todayTapped))
        // Flipped view: y=8 is the TOP row, beside the month title.
        let widths: [CGFloat] = [30, 54, 30]
        var x = frame.width - 14 - widths.reduce(0, +) - 12
        for (i, b) in [prev, today, next].enumerated() {
            b.bezelStyle = .accessoryBarAction
            b.font = .systemFont(ofSize: 11, weight: .medium)
            b.frame = NSRect(x: x, y: 8, width: widths[i], height: 22)
            b.autoresizingMask = [.minXMargin]
            addSubview(b)
            x += widths[i] + 6
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func goToday() { shownMonth = Date(); needsDisplay = true }
    @objc private func prevMonth() { shownMonth = cal.date(byAdding: .month, value: -1, to: shownMonth) ?? shownMonth; needsDisplay = true }
    @objc private func nextMonth() { shownMonth = cal.date(byAdding: .month, value: 1, to: shownMonth) ?? shownMonth; needsDisplay = true }
    @objc private func todayTapped() { goToday() }

    override func draw(_ dirtyRect: NSRect) {
        // Solid backing so the grid reads in the popover and in offscreen previews.
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let pad: CGFloat = 14
        let headerY: CGFloat = 10

        // Month title.
        let mf = DateFormatter()
        mf.dateFormat = "MMMM yyyy"
        (mf.string(from: shownMonth) as NSString).draw(at: NSPoint(x: pad, y: headerY),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor])

        // Weekday initials, honoring the user's first-weekday setting.
        let symbols = cal.veryShortWeekdaySymbols  // S M T W T F S (Sunday-first)
        let first = cal.firstWeekday - 1
        let ordered = (0..<7).map { symbols[($0 + first) % 7] }
        let gridTop: CGFloat = 44
        let cellW = (bounds.width - pad * 2) / 7
        let cellH: CGFloat = 28
        for (i, s) in ordered.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                        .foregroundColor: NSColor.secondaryLabelColor]
            let size = (s as NSString).size(withAttributes: attrs)
            (s as NSString).draw(at: NSPoint(x: pad + CGFloat(i) * cellW + (cellW - size.width) / 2, y: gridTop),
                                 withAttributes: attrs)
        }

        // Day cells.
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: shownMonth)),
              let dayRange = cal.range(of: .day, in: .month, for: monthStart) else { return }
        let startWeekday = cal.component(.weekday, from: monthStart) - 1  // 0-based, Sunday=0
        let leadBlanks = (startWeekday - first + 7) % 7
        let today = cal.startOfDay(for: Date())

        for day in dayRange {
            let slot = leadBlanks + day - 1
            let col = slot % 7, row = slot / 7
            let x = pad + CGFloat(col) * cellW
            let y = gridTop + 20 + CGFloat(row) * cellH
            let date = cal.date(byAdding: .day, value: day - 1, to: monthStart)!
            let isToday = cal.isDate(date, inSameDayAs: today)
            let isWeekend = cal.isDateInWeekend(date)

            if isToday {
                NSColor.controlAccentColor.setFill()
                let d: CGFloat = 24
                NSBezierPath(ovalIn: NSRect(x: x + (cellW - d) / 2, y: y - 3, width: d, height: d)).fill()
            }
            let color: NSColor = isToday ? .white : (isWeekend ? .secondaryLabelColor : .labelColor)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: isToday ? .bold : .regular),
                .foregroundColor: color,
            ]
            let str = "\(day)" as NSString
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: x + (cellW - size.width) / 2, y: y), withAttributes: attrs)
        }
    }
}
