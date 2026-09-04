import Cocoa

/// The panels the notch hosts. Each is a plain NSView sized to the notch's
/// content box (≈660 x ≤274); the strip supplies the shell, the clipping and
/// the placement, so a module only has to draw itself.
///
/// They are dark by construction — the notch is the housing's black in every
/// appearance, so there is no theme to follow here.
enum NotchTheme {
    static let fg = NSColor.white
    static let dim = NSColor.white.withAlphaComponent(0.55)
    static let faint = NSColor.white.withAlphaComponent(0.10)
    static func title(_ size: CGFloat = 12) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: fg]
    }
    static func body(_ size: CGFloat = 11) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size), .foregroundColor: fg.withAlphaComponent(0.85)]
    }
    static func small(_ size: CGFloat = 9) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size), .foregroundColor: dim]
    }
}

/// Shared base: flipped, dark, and repainting on a timer when asked.
class NotchModuleView: NSView {
    private var ticker: Timer?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func tick(every seconds: TimeInterval) {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }
    deinit { ticker?.invalidate() }
}

// MARK: - AI usage

/// The quota numbers, which until now were reachable only by opening the Agent
/// Pad and clicking its ◔. Same snapshot, no extra fetch — a read shells out
/// for ~45s, so this shows what is already known and says how old it is.
final class UsageModuleView: NotchModuleView {
    override func draw(_ dirtyRect: NSRect) {
        let providers = UsageReader.shared.providers
        var y: CGFloat = 12
        ("AI usage" as NSString).draw(at: NSPoint(x: 16, y: y), withAttributes: NotchTheme.title())
        let age = UsageReader.shared.ageDescription
        if !age.isEmpty {
            let a = age as NSString
            a.draw(at: NSPoint(x: bounds.width - 16 - a.size(withAttributes: NotchTheme.small()).width, y: y + 2),
                   withAttributes: NotchTheme.small())
        }
        y += 24
        guard !providers.isEmpty else {
            (UsageReader.isAvailable ? "No reading yet." : "Install codexbar to see quota."
                as NSString).draw(at: NSPoint(x: 16, y: y), withAttributes: NotchTheme.small())
            return
        }
        for p in providers {
            for w in p.windows {
                guard y < bounds.height - 26 else { return }
                ("\(p.name) · \(w.label)" as NSString).draw(
                    at: NSPoint(x: 16, y: y), withAttributes: NotchTheme.body())
                let pct = "\(w.usedPercent)%" as NSString
                let pw = pct.size(withAttributes: NotchTheme.title(11)).width
                pct.draw(at: NSPoint(x: bounds.width - 16 - pw, y: y),
                         withAttributes: NotchTheme.title(11))
                // The bar is the point: a number needs reading, a bar does not.
                let track = NSRect(x: 16, y: y + 18, width: bounds.width - 32, height: 5)
                NotchTheme.faint.setFill()
                NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
                let frac = CGFloat(min(max(w.usedPercent, 0), 100)) / 100
                let tint = w.usedPercent >= 90 ? NSColor(srgbRed: 0.95, green: 0.3, blue: 0.3, alpha: 1)
                         : w.usedPercent >= 75 ? NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
                         : NSColor(srgbRed: 0.35, green: 0.75, blue: 0.45, alpha: 1)
                tint.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                 width: max(track.width * frac, 3), height: track.height),
                             xRadius: 2.5, yRadius: 2.5).fill()
                let reset = w.resetDescription as NSString
                if !w.resetDescription.isEmpty {
                    reset.draw(at: NSPoint(x: bounds.width - 16 - reset.size(withAttributes: NotchTheme.small()).width,
                                           y: y + 26), withAttributes: NotchTheme.small())
                }
                y += 44
            }
        }
    }
}

// MARK: - World clock

/// Times the user actually cares about, in the one place always on screen.
final class ClockModuleView: NotchModuleView {
    private let zones: [String]
    init(zones: [String]) {
        self.zones = zones
        super.init(frame: .zero)
        tick(every: 1)   // a clock that does not move is not a clock
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = 12
        ("World clock" as NSString).draw(at: NSPoint(x: 16, y: y), withAttributes: NotchTheme.title())
        y += 26
        let live = zones.compactMap { id -> (String, TimeZone)? in
            TimeZone(identifier: id).map { (id, $0) }
        }
        guard !live.isEmpty else {
            ("Add time zones in Settings ▸ Notch." as NSString)
                .draw(at: NSPoint(x: 16, y: y), withAttributes: NotchTheme.small())
            return
        }
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        let day = DateFormatter(); day.dateFormat = "EEE d"
        let now = Date()
        for (id, tz) in live {
            guard y < bounds.height - 18 else { return }
            time.timeZone = tz; day.timeZone = tz
            let city = id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
            (city as NSString).draw(at: NSPoint(x: 16, y: y), withAttributes: NotchTheme.body())
            // Offset from here, because "what time is it there" is really
            // "how far ahead of me are they".
            let delta = (tz.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
            let off = (delta == 0 ? "same" : (delta > 0 ? "+\(delta)h" : "\(delta)h")) as NSString
            off.draw(at: NSPoint(x: 150, y: y + 1), withAttributes: NotchTheme.small())
            let t = time.string(from: now) as NSString
            let tw = t.size(withAttributes: NotchTheme.title(15)).width
            t.draw(at: NSPoint(x: bounds.width - 16 - tw, y: y - 2), withAttributes: NotchTheme.title(15))
            let d = day.string(from: now) as NSString
            d.draw(at: NSPoint(x: bounds.width - 16 - tw - 8 - d.size(withAttributes: NotchTheme.small()).width,
                               y: y + 3), withAttributes: NotchTheme.small())
            y += 30
        }
    }
}

// MARK: - Hotkeys

/// The cheat sheet, in the one surface that is always visible. Power Tools is
/// a hotkey-driven app whose hotkeys were discoverable only BY a hotkey — that
/// is a chicken-and-egg the notch happens to solve.
final class HotkeysModuleView: NotchModuleView {
    private let sections: [(title: String, rows: [(key: String, title: String)])]
    private let hotkeyName: String
    private var page = 0

    init(hotkeyName: String, connections: [(key: String, name: String)]) {
        self.sections = HotkeyCheatSheetView.buildSections(connections)
        self.hotkeyName = hotkeyName
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Two columns of sections per page — the sheet is far taller than the
    /// notch may ever be, so it pages rather than scrolls.
    private var pages: [[(title: String, rows: [(key: String, title: String)])]] {
        stride(from: 0, to: sections.count, by: 4).map {
            Array(sections[$0..<Swift.min($0 + 4, sections.count)])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let all = pages
        guard !all.isEmpty else { return }
        page = Swift.min(page, all.count - 1)
        ("Hold \(hotkeyName), then…" as NSString)
            .draw(at: NSPoint(x: 16, y: 10), withAttributes: NotchTheme.title())
        if all.count > 1 {
            let p = "\(page + 1)/\(all.count)  ›" as NSString
            p.draw(at: NSPoint(x: bounds.width - 16 - p.size(withAttributes: NotchTheme.small()).width, y: 12),
                   withAttributes: NotchTheme.small())
        }
        let colW = (bounds.width - 32) / 2
        for (i, section) in all[page].enumerated() {
            let x = 16 + CGFloat(i % 2) * colW
            var y: CGFloat = 34 + CGFloat(i / 2) * 140
            (section.title as NSString).draw(at: NSPoint(x: x, y: y),
                                             withAttributes: NotchTheme.small(9))
            y += 15
            for row in section.rows.prefix(6) {
                guard y < bounds.height - 14 else { break }
                let key = row.key as NSString
                let kw = Swift.max(key.size(withAttributes: NotchTheme.title(10)).width + 10, 24)
                let box = NSRect(x: x, y: y, width: kw, height: 15)
                NotchTheme.faint.setFill()
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                key.draw(at: NSPoint(x: box.midX - key.size(withAttributes: NotchTheme.title(10)).width / 2,
                                     y: y + 1), withAttributes: NotchTheme.title(10))
                let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
                var attrs = NotchTheme.small(10); attrs[.paragraphStyle] = p
                (row.title as NSString).draw(
                    in: NSRect(x: x + kw + 6, y: y + 1, width: colW - kw - 14, height: 14),
                    withAttributes: attrs)
                y += 18
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        page = (page + 1) % Swift.max(pages.count, 1)
        needsDisplay = true
    }
}

// MARK: - Window snapper

/// Layout tiles, drawn as little window diagrams, applied to the frontmost
/// window. Reuses WindowManager and the palette's normalized-rect convention
/// rather than inventing a second snapping path.
final class SnapModuleView: NotchModuleView {
    /// Normalized, top-left origin — the same convention WindowPalette uses.
    private static let tiles: [(String, NSRect)] = [
        ("Full",    NSRect(x: 0,     y: 0,   width: 1,     height: 1)),
        ("Left ½",  NSRect(x: 0,     y: 0,   width: 0.5,   height: 1)),
        ("Right ½", NSRect(x: 0.5,   y: 0,   width: 0.5,   height: 1)),
        ("Top ½",   NSRect(x: 0,     y: 0,   width: 1,     height: 0.5)),
        ("Btm ½",   NSRect(x: 0,     y: 0.5, width: 1,     height: 0.5)),
        ("Left ⅓",  NSRect(x: 0,     y: 0,   width: 1.0/3, height: 1)),
        ("Mid ⅓",   NSRect(x: 1.0/3, y: 0,   width: 1.0/3, height: 1)),
        ("Right ⅓", NSRect(x: 2.0/3, y: 0,   width: 1.0/3, height: 1)),
        ("Left ⅔",  NSRect(x: 0,     y: 0,   width: 2.0/3, height: 1)),
        ("Right ⅔", NSRect(x: 1.0/3, y: 0,   width: 2.0/3, height: 1)),
        ("◱",       NSRect(x: 0,     y: 0,   width: 0.5,   height: 0.5)),
        ("◲",       NSRect(x: 0.5,   y: 0,   width: 0.5,   height: 0.5)),
        ("◰",       NSRect(x: 0,     y: 0.5, width: 0.5,   height: 0.5)),
        ("◳",       NSRect(x: 0.5,   y: 0.5, width: 0.5,   height: 0.5)),
    ]
    private var hovered: Int?
    private static let cols = 5

    private func cell(_ i: Int) -> NSRect {
        let w = (bounds.width - 32) / CGFloat(Self.cols)
        return NSRect(x: 16 + CGFloat(i % Self.cols) * w, y: 34 + CGFloat(i / Self.cols) * 58,
                      width: w - 6, height: 52)
    }

    override func draw(_ dirtyRect: NSRect) {
        ("Snap the front window" as NSString)
            .draw(at: NSPoint(x: 16, y: 10), withAttributes: NotchTheme.title())
        for (i, tile) in Self.tiles.enumerated() {
            let c = cell(i)
            guard c.maxY < bounds.height else { break }
            // A tiny screen with the target region filled in — the same
            // language as the snap palette, so they teach each other.
            let frame = NSRect(x: c.minX, y: c.minY, width: c.width, height: c.height - 14)
            NotchTheme.faint.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).fill()
            let r = tile.1
            let fill = NSRect(x: frame.minX + r.minX * frame.width,
                              y: frame.minY + r.minY * frame.height,
                              width: r.width * frame.width, height: r.height * frame.height)
            (hovered == i ? NSColor(srgbRed: 0.4, green: 0.45, blue: 1, alpha: 1)
                          : NSColor.white.withAlphaComponent(0.5)).setFill()
            NSBezierPath(roundedRect: fill.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
            NotchTheme.fg.withAlphaComponent(0.25).setStroke()
            let outline = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1; outline.stroke()
            let t = tile.0 as NSString
            t.draw(at: NSPoint(x: c.midX - t.size(withAttributes: NotchTheme.small(9)).width / 2,
                               y: frame.maxY + 2), withAttributes: NotchTheme.small(9))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = Self.tiles.indices.first { cell($0).contains(p) }
        if h != hovered { hovered = h; needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = Self.tiles.indices.first(where: { cell($0).contains(p) }),
              let win = WindowManager.frontmostWindow(),
              let screen = WindowManager.screen(of: win) ?? NSScreen.main else { return }
        WindowManager.setWindow(win, cocoaFrame: WindowPalette.cocoaRect(Self.tiles[i].1, on: screen))
    }
}

// MARK: - Weather

/// Conditions from Open-Meteo — no API key, no account, and no CoreLocation
/// prompt: the place is a lat/lon in config, set by typing a city in Settings.
/// One fetch on open, cached for 15 minutes; a notch module has no business
/// polling a network service on a timer. It keeps what MacNotch's weather
/// panel shows: the reading, feels-like, humidity, wind, UV, rain chance,
/// pressure, sunrise/sunset and the next hours.
@MainActor
final class WeatherReader {
    static let shared = WeatherReader()
    struct Hour {
        var date: Date
        var tempC: Double
        var code: Int
        var isDay: Bool
    }
    struct Now {
        var tempC = 0.0, feelsC = 0.0, windKph = 0.0
        var code = 0
        var isDay = true
        var highC = 0.0, lowC = 0.0
        var humidity = 0            // %
        var uv = 0.0
        var rainChance = 0          // %, this hour
        var pressureHPa = 0.0
        var sunrise: Date?
        var sunset: Date?
        /// From the current hour onward, a day at most.
        var hours: [Hour] = []
        var timeZone = TimeZone.current
        var fetched = Date.distantPast
    }
    /// Keyed by location so several cities can be shown at once — each place
    /// caches and refreshes on its own 15-minute clock.
    private var byKey: [String: Now] = [:]
    private var inFlight: Set<String> = []
    var onUpdate: (() -> Void)?

    static func key(lat: Double, lon: Double) -> String {
        String(format: "%.3f,%.3f", lat, lon)
    }
    /// This location's last reading, or nil if never fetched.
    func now(lat: Double, lon: Double) -> Now? { byKey[Self.key(lat: lat, lon: lon)] }
    /// Preview/test hook: plant a reading without the network.
    func seed(lat: Double, lon: Double, _ reading: Now) { byKey[Self.key(lat: lat, lon: lon)] = reading }

    func refreshIfStale(lat: Double, lon: Double) {
        let k = Self.key(lat: lat, lon: lon)
        guard !inFlight.contains(k), abs(lat) + abs(lon) > 0 else { return }
        if let n = byKey[k], Date().timeIntervalSince(n.fetched) < 900 { return }
        inFlight.insert(k)
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,"
            + "wind_speed_10m,pressure_msl,is_day"
            + "&hourly=temperature_2m,weather_code,precipitation_probability,uv_index,is_day"
            + "&daily=temperature_2m_max,temperature_2m_min,sunrise,sunset"
            + "&forecast_days=2&timezone=auto")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            Task { @MainActor in
                self.inFlight.remove(k)
                guard let data,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let cur = root["current"] as? [String: Any] else { return }
                func num(_ d: [String: Any], _ key: String) -> Double? { (d[key] as? NSNumber)?.doubleValue }
                func at(_ a: [Any], _ i: Int) -> Double {
                    i < a.count ? ((a[i] as? NSNumber)?.doubleValue ?? 0) : 0
                }
                var n = Now()
                let tz = (root["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
                n.timeZone = tz
                n.tempC = num(cur, "temperature_2m") ?? 0
                n.feelsC = num(cur, "apparent_temperature") ?? n.tempC
                n.windKph = num(cur, "wind_speed_10m") ?? 0
                n.code = Int(num(cur, "weather_code") ?? 0)
                n.isDay = (num(cur, "is_day") ?? 1) != 0
                n.humidity = Int((num(cur, "relative_humidity_2m") ?? 0).rounded())
                n.pressureHPa = num(cur, "pressure_msl") ?? 0   // sea-level, the barometer figure people know
                // Open-Meteo's times are the place's LOCAL wall clock, no zone.
                let local = DateFormatter()
                local.dateFormat = "yyyy-MM-dd'T'HH:mm"
                local.timeZone = tz
                if let daily = root["daily"] as? [String: Any] {
                    n.highC = at(daily["temperature_2m_max"] as? [Any] ?? [], 0)
                    n.lowC = at(daily["temperature_2m_min"] as? [Any] ?? [], 0)
                    n.sunrise = ((daily["sunrise"] as? [Any])?.first as? String).flatMap(local.date(from:))
                    n.sunset = ((daily["sunset"] as? [Any])?.first as? String).flatMap(local.date(from:))
                }
                if let hourly = root["hourly"] as? [String: Any], let times = hourly["time"] as? [String] {
                    let temps = hourly["temperature_2m"] as? [Any] ?? []
                    let codes = hourly["weather_code"] as? [Any] ?? []
                    let rain = hourly["precipitation_probability"] as? [Any] ?? []
                    let uv = hourly["uv_index"] as? [Any] ?? []
                    let day = hourly["is_day"] as? [Any] ?? []
                    let dates = times.map { local.date(from: $0) ?? .distantPast }
                    // The slot that contains now — hour labels are hour STARTS.
                    let start = dates.firstIndex { $0 > Date().addingTimeInterval(-3600) } ?? 0
                    n.rainChance = Int(at(rain, start).rounded())
                    n.uv = at(uv, start)
                    n.hours = (start..<min(start + 24, dates.count)).map {
                        Hour(date: dates[$0], tempC: at(temps, $0), code: Int(at(codes, $0)), isDay: at(day, $0) != 0)
                    }
                }
                n.fetched = Date()
                self.byKey[k] = n
                self.onUpdate?()
            }
        }.resume()
    }

    /// Turn a typed city into a lat/lon, once, in Settings. Open-Meteo's
    /// geocoder needs no key either, which is what keeps the whole module free
    /// of accounts and of a location permission prompt.
    static func geocode(_ place: String, then done: @escaping (String, Double, Double) -> Void) {
        let q = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !q.isEmpty,
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1")
        else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let hit = (root["results"] as? [[String: Any]])?.first,
                  let lat = (hit["latitude"] as? NSNumber)?.doubleValue,
                  let lon = (hit["longitude"] as? NSNumber)?.doubleValue else { return }
            let name = [hit["name"] as? String, hit["admin1"] as? String, hit["country_code"] as? String]
                .compactMap { $0 }.joined(separator: ", ")
            DispatchQueue.main.async { done(name.isEmpty ? place : name, lat, lon) }
        }.resume()
    }

    /// WMO codes, collapsed to the handful worth distinguishing at a glance.
    /// A clear night gets a moon.
    static func describe(_ code: Int, isDay: Bool = true) -> (String, String) {
        switch code {
        case 0: return (isDay ? "☀︎" : "☾", isDay ? "Clear sky" : "Clear night")
        case 1: return (isDay ? "☀︎" : "☾", "Mostly clear")
        case 2: return ("⛅︎", "Partly cloudy")
        case 3: return ("☁︎", "Overcast")
        case 45, 48: return ("≈", "Fog")
        case 51...57: return ("☂", "Drizzle")
        case 61...67, 80...82: return ("☂", "Rain")
        case 71...77, 85, 86: return ("❄", "Snow")
        case 95...99: return ("⚡︎", "Thunderstorm")
        default: return ("·", "—")
        }
    }
}

/// Housing-black backdrop for offscreen module previews: modules paint no
/// background of their own because the strip's shell is behind them.
final class NotchPreviewPlate: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.04, alpha: 1).setFill()
        bounds.fill()
    }
}

/// MacNotch's weather panel, in the notch's black: the reading large, the
/// day's range, feels-like, a row of the numbers that decide what to wear, and
/// the next hours. Several cities become a row of chips under the title; click
/// one to switch. Everything drawn is the reader's cached snapshot — nothing
/// here fetches.
final class WeatherModuleView: NotchModuleView {
    private let places: [Config.WeatherPlace]
    private let fahrenheit: Bool
    private var selected = 0
    private var chipRects: [(index: Int, rect: NSRect)] = []

    init(places: [Config.WeatherPlace], fahrenheit: Bool) {
        self.places = places; self.fahrenheit = fahrenheit
        super.init(frame: .zero)
        WeatherReader.shared.onUpdate = { [weak self] in self?.needsDisplay = true }
        for p in places { WeatherReader.shared.refreshIfStale(lat: p.lat, lon: p.lon) }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func t(_ c: Double) -> String {
        fahrenheit ? "\(Int((c * 9 / 5 + 32).rounded()))°" : "\(Int(c.rounded()))°"
    }
    private func wind(_ kph: Double) -> String {
        fahrenheit ? "\(Int((kph * 0.621371).rounded())) mph" : "\(Int(kph.rounded())) km/h"
    }
    private func clock(_ d: Date?, tz: TimeZone) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.timeZone = tz; f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: d)
    }
    private func hourLabel(_ d: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = tz
        f.setLocalizedDateFormatFromTemplate("j")
        return f.string(from: d).replacingOccurrences(of: " ", with: "")
    }
    private func city(_ p: Config.WeatherPlace) -> String {
        p.name.split(separator: ",").first.map(String.init) ?? p.name
    }

    override func draw(_ dirtyRect: NSRect) {
        chipRects = []
        let left: CGFloat = 16, right = bounds.width - 16
        ("Weather" as NSString).draw(at: NSPoint(x: left, y: 8), withAttributes: NotchTheme.title())
        guard !places.isEmpty else {
            ("Add cities in Settings ▸ Notch." as NSString)
                .draw(at: NSPoint(x: left, y: 32), withAttributes: NotchTheme.small(11))
            return
        }
        let sel = min(selected, places.count - 1)
        // Cities under the title: one reads as a subtitle, several as a switcher.
        var cx = left
        for (i, p) in places.enumerated() {
            let name = city(p) as NSString
            let attrs: [NSAttributedString.Key: Any] = i == sel
                ? [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                   .foregroundColor: NotchTheme.fg.withAlphaComponent(0.95)]
                : [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NotchTheme.dim]
            let r = NSRect(x: cx, y: 26, width: name.size(withAttributes: attrs).width + 10, height: 15)
            if i == sel, places.count > 1 {
                NotchTheme.faint.setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            }
            name.draw(at: NSPoint(x: r.minX + 5, y: r.minY + 1), withAttributes: attrs)
            chipRects.append((i, r))
            cx = r.maxX + 6
        }
        let p = places[sel]
        guard let n = WeatherReader.shared.now(lat: p.lat, lon: p.lon) else {
            ("Fetching…" as NSString).draw(at: NSPoint(x: left, y: 60), withAttributes: NotchTheme.small(11))
            return
        }
        // Sunrise · sunset, top right, in the place's own clock.
        let sun = "☀︎↑ \(clock(n.sunrise, tz: n.timeZone))    ☀︎↓ \(clock(n.sunset, tz: n.timeZone))" as NSString
        sun.draw(at: NSPoint(x: right - sun.size(withAttributes: NotchTheme.small(10)).width, y: 12),
                 withAttributes: NotchTheme.small(10))

        // The reading: glyph, big temperature, condition, range; feels-like right.
        let (glyph, text) = WeatherReader.describe(n.code, isDay: n.isDay)
        (glyph as NSString).draw(at: NSPoint(x: left, y: 52),
                                 withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NotchTheme.fg])
        (t(n.tempC) as NSString).draw(at: NSPoint(x: left + 66, y: 44),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .semibold),
                                                       .foregroundColor: NotchTheme.fg])
        (text as NSString).draw(at: NSPoint(x: left + 68, y: 95), withAttributes: NotchTheme.body(13))
        ("H: \(t(n.highC))   L: \(t(n.lowC))" as NSString)
            .draw(at: NSPoint(x: left + 68, y: 114), withAttributes: NotchTheme.small(11))
        let feels = "Feels like" as NSString
        feels.draw(at: NSPoint(x: right - feels.size(withAttributes: NotchTheme.small(11)).width, y: 60),
                   withAttributes: NotchTheme.small(11))
        let fv = t(n.feelsC) as NSString
        fv.draw(at: NSPoint(x: right - fv.size(withAttributes: NotchTheme.title(22)).width, y: 76),
                withAttributes: NotchTheme.title(22))

        // The numbers row: five columns with hairlines between.
        let cols: [(String, String, String)] = [
            ("◍", "Humidity", "\(n.humidity)%"),
            ("≋", "Wind", wind(n.windKph)),
            ("☀︎", "UV", "\(Int(n.uv.rounded()))"),
            ("☂", "Rain chance", "\(n.rainChance)%"),
            ("◎", "Pressure", "\(Int(n.pressureHPa.rounded())) hPa"),
        ]
        let rowY: CGFloat = 140
        let colW = (right - left) / CGFloat(cols.count)
        for (i, c) in cols.enumerated() {
            let x = left + CGFloat(i) * colW
            if i > 0 {
                NotchTheme.faint.setFill()
                NSRect(x: x - 10, y: rowY + 2, width: 1, height: 34).fill()
            }
            (c.0 as NSString).draw(at: NSPoint(x: x, y: rowY + 7),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NotchTheme.dim])
            (c.1 as NSString).draw(at: NSPoint(x: x + 24, y: rowY), withAttributes: NotchTheme.small(10))
            (c.2 as NSString).draw(at: NSPoint(x: x + 24, y: rowY + 15), withAttributes: NotchTheme.title(13))
        }

        // The next hours.
        ("Hourly" as NSString).draw(at: NSPoint(x: left, y: 190),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                     .foregroundColor: NotchTheme.dim])
        let hours = Array(n.hours.prefix(13))
        guard !hours.isEmpty else { return }
        let hw = (right - left) / CGFloat(hours.count)
        for (i, h) in hours.enumerated() {
            let mid = left + CGFloat(i) * hw + hw / 2
            func centered(_ s: String, y: CGFloat, _ attrs: [NSAttributedString.Key: Any]) {
                let ns = s as NSString
                ns.draw(at: NSPoint(x: mid - ns.size(withAttributes: attrs).width / 2, y: y), withAttributes: attrs)
            }
            centered(i == 0 ? "Now" : hourLabel(h.date, tz: n.timeZone), y: 208, NotchTheme.small(10))
            centered(WeatherReader.describe(h.code, isDay: h.isDay).0, y: 222,
                     [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NotchTheme.fg])
            centered(t(h.tempC), y: 246, NotchTheme.title(11))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = chipRects.first(where: { $0.rect.insetBy(dx: -4, dy: -3).contains(p) }) {
            selected = hit.index
            needsDisplay = true
        }
    }
}

// MARK: - AI chat

/// A quick ask, not a conversation. The full chat window is 380x360 at its
/// MINIMUM — taller than the notch is allowed to be — so this takes one
/// question, shows one answer, and hands off to the real window for anything
/// that wants scrollback.
final class ChatModuleView: NotchModuleView, NotchKeyboardModule {
    func firstResponderView() -> NSView? { field }
    /// Dictation drops its transcript into the field, appending to anything
    /// already typed, cursor at the end — the user presses ⏎ to ask.
    func insertTranscript(_ text: String) {
        let existing = field.stringValue
        let sep = (existing.isEmpty || existing.hasSuffix(" ")) ? "" : " "
        field.stringValue = existing + sep + text
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        needsDisplay = true
    }
    private let field = NSTextField()
    private var answer = ""
    private var asking = false
    private let model: String
    /// Handing off to the real chat window is the controller's job — the module
    /// has no business owning that window's lifecycle.
    private let openFull: (String) -> Void

    init(model: String, openFull: @escaping (String) -> Void) {
        self.model = model
        self.openFull = openFull
        super.init(frame: .zero)
        field.placeholderString = "Ask Claude…"
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(submit)
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 18, y: 36, width: bounds.width - 36, height: 22)
    }

    @objc private func submit() {
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        guard let key = Keychain.get("claude"), !key.isEmpty else {
            answer = "No Claude API key — add one in Settings ▸ AI."
            needsDisplay = true
            return
        }
        asking = true
        answer = "Thinking…"
        field.stringValue = ""
        needsDisplay = true
        Task { @MainActor in
            do {
                let reply = try await CloudPolish.claude(
                    instructions: "Answer in at most three short sentences. No preamble.",
                    prompt: q, model: model, apiKey: key)
                answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                answer = "Failed: \(error.localizedDescription)"
            }
            asking = false
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ("Ask Claude" as NSString).draw(at: NSPoint(x: 16, y: 10), withAttributes: NotchTheme.title())
        let hint = "⏎ to ask · click to open full chat" as NSString
        hint.draw(at: NSPoint(x: bounds.width - 16 - hint.size(withAttributes: NotchTheme.small(9)).width, y: 12),
                  withAttributes: NotchTheme.small(9))
        NotchTheme.faint.setFill()
        NSBezierPath(roundedRect: NSRect(x: 12, y: 32, width: bounds.width - 24, height: 30),
                     xRadius: 7, yRadius: 7).fill()
        guard !answer.isEmpty else { return }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        var attrs = NotchTheme.body(11); attrs[.paragraphStyle] = p
        (answer as NSString).draw(in: NSRect(x: 16, y: 74, width: bounds.width - 32,
                                             height: bounds.height - 84), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        // Anything that wants scrollback belongs in the real window.
        let p = convert(event.locationInWindow, from: nil)
        guard p.y > 70 || p.y < 30 else { return }
        openFull(answer)
    }
}
