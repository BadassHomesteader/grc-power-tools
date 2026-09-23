import Cocoa
import IOKit

/// Volumes and their live throughput, for the notch's Disk module.
///
/// PULL-BASED, no timer: `snapshot` hands back the last reading and kicks a
/// background refresh if it has gone stale. Nothing samples unless a module is
/// on screen asking, so a closed notch costs exactly nothing — there is no
/// ticker to remember to stop.
///
/// The IO counters are per PHYSICAL DEVICE, not per volume: every APFS volume
/// in a container shares one `IOBlockStorageDriver`, so "how fast is Macintosh
/// HD writing" is not a question the system can answer. Throughput is therefore
/// reported once per device and volumes carry capacity only. An external
/// enclosure has its own driver node, so an external's throughput IS separable.
@MainActor final class DiskReader {
    static let shared = DiskReader()

    struct Volume: Equatable {
        let name: String
        let format: String          // "APFS", "ExFAT" — volumeLocalizedFormatDescription
        let total: Int64
        let used: Int64
        let free: Int64
        let ejectable: Bool
        let isInternal: Bool
        let url: URL
        let device: String          // whole-disk BSD name ("disk0"), "" when unknown
    }

    struct Device: Equatable {
        let bsd: String
        let name: String            // "APPLE SSD AP1024Z"
        let isInternal: Bool
        let readBps: Double?        // nil while warming — never a fabricated zero
        let writeBps: Double?
        let totalRead: UInt64       // cumulative since boot
        let totalWritten: UInt64
    }

    struct Snapshot {
        var volumes: [Volume] = []
        var devices: [Device] = []
        /// True until two counter samples exist; the view draws — rather than 0.
        var warming = true
        var at = Date.distantPast
    }

    /// Cumulative byte counters from the previous sample, keyed by device.
    struct Raw {
        var bytes: [String: (read: UInt64, write: UInt64)] = [:]
        var at = Date()
    }

    private var cached = Snapshot()
    private var raw: Raw?
    private var refreshing = false
    private var seeded = false
    /// Capacity is re-read every 10s, not every tick: the purgeable-inclusive
    /// "available for important usage" figure is a real computation, and free
    /// space does not move at 2 Hz. Counters are read every tick.
    private var volumesAt = Date.distantPast

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesAt = .distantPast }
            }
        }
    }

    /// Preview/test hook: plant a reading without touching the hardware.
    func seed(_ s: Snapshot) {
        var s = s
        s.at = Date()
        cached = s
        seeded = true
    }

    var snapshot: Snapshot {
        refreshIfStale()
        return cached
    }

    private func refreshIfStale() {
        guard !seeded, !refreshing, Date().timeIntervalSince(cached.at) > 1.5 else { return }
        refreshing = true
        let previous = raw
        let reuse = Date().timeIntervalSince(volumesAt) < 10 ? cached.volumes : nil
        DispatchQueue.global(qos: .utility).async {
            let (snap, raw) = Self.sample(previous: previous, reuseVolumes: reuse)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.cached = snap
                    self.raw = raw
                    if reuse == nil { self.volumesAt = Date() }
                    self.refreshing = false
                }
            }
        }
    }

    /// Eject a removable volume. Throws so the row can show the real reason.
    func eject(_ v: Volume) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
        volumesAt = .distantPast
    }

    // MARK: - Sampling (off the main thread)

    nonisolated static func sample(previous: Raw?, reuseVolumes: [Volume]?) -> (Snapshot, Raw) {
        let now = Date()
        var raw = Raw(at: now)
        var devices: [Device] = []
        let elapsed = previous.map { now.timeIntervalSince($0.at) } ?? 0

        for d in blockDevices() {
            raw.bytes[d.bsd] = (d.read, d.write)
            var readBps: Double?
            var writeBps: Double?
            // A counter can only be differenced against a previous reading of
            // the SAME counter, and only over a sane interval — a machine that
            // slept for an hour would otherwise report a fantasy average.
            if let p = previous?.bytes[d.bsd], elapsed > 0.2, elapsed < 30 {
                readBps = Double(d.read &- min(p.read, d.read)) / elapsed
                writeBps = Double(d.write &- min(p.write, d.write)) / elapsed
            }
            devices.append(Device(bsd: d.bsd, name: d.name, isInternal: d.isInternal,
                                  readBps: readBps, writeBps: writeBps,
                                  totalRead: d.read, totalWritten: d.write))
        }

        var snap = Snapshot()
        snap.devices = devices.sorted { ($0.isInternal ? 0 : 1, $0.bsd) < ($1.isInternal ? 0 : 1, $1.bsd) }
        snap.volumes = reuseVolumes ?? volumes()
        snap.warming = devices.allSatisfy { $0.readBps == nil }
        snap.at = now
        return (snap, raw)
    }

    private nonisolated static func volumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeIsInternalKey, .volumeIsBrowsableKey,
                                      .volumeLocalizedFormatDescriptionKey]
        // .skipHiddenVolumes drops the /System/Volumes/* mounts that clutter
        // `df` — on this machine it leaves exactly the volumes Finder shows.
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var out: [Volume] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { continue }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 0 else { continue }
            let free = v.volumeAvailableCapacityForImportantUsage ?? 0
            let bsd = bsdName(of: url) ?? ""
            out.append(Volume(name: v.volumeName ?? url.lastPathComponent,
                              format: v.volumeLocalizedFormatDescription ?? "",
                              total: total,
                              // Available can exceed the naive figure (it counts
                              // purgeable space), so used is clamped at zero.
                              used: max(0, total - free),
                              free: max(0, free),
                              ejectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false),
                              isInternal: v.volumeIsInternal ?? false,
                              url: url,
                              device: bsd.isEmpty ? "" : (wholeDisk(forBSD: bsd) ?? "")))
        }
        return out.sorted { ($0.isInternal ? 0 : 1, $0.name) < ($1.isInternal ? 0 : 1, $1.name) }
    }

    // MARK: - IOKit

    private nonisolated static func prop(_ svc: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// The BSD name hangs on the driver's child IOMedia, not the driver itself.
    private nonisolated static func childBSDName(_ svc: io_object_t) -> String? {
        var child: io_object_t = 0
        guard IORegistryEntryGetChildEntry(svc, "IOService", &child) == KERN_SUCCESS, child != 0 else { return nil }
        defer { IOObjectRelease(child) }
        return prop(child, "BSD Name") as? String
    }

    private nonisolated static func blockDevices()
        -> [(bsd: String, name: String, isInternal: Bool, read: UInt64, write: UInt64)] {
        var out: [(bsd: String, name: String, isInternal: Bool, read: UInt64, write: UInt64)] = []
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let bsd = childBSDName(svc) else { continue }
            let stats = prop(svc, "Statistics") as? [String: Any] ?? [:]
            let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            var name = bsd
            var isInternal = true
            var parent: io_object_t = 0
            if IORegistryEntryGetParentEntry(svc, "IOService", &parent) == KERN_SUCCESS, parent != 0 {
                if let dc = prop(parent, "Device Characteristics") as? [String: Any],
                   let p = dc["Product Name"] as? String {
                    name = p.trimmingCharacters(in: .whitespaces)
                }
                if let pc = prop(parent, "Protocol Characteristics") as? [String: Any],
                   let loc = pc["Physical Interconnect Location"] as? String {
                    isInternal = (loc == "Internal")
                }
                IOObjectRelease(parent)
            }
            out.append((bsd, name, isInternal, r, w))
        }
        return out
    }

    /// Walk a volume's IOMedia up to the IOBlockStorageDriver that carries the
    /// counters. An APFS volume (disk3s1s1) is several nodes above the physical
    /// device (disk0), so this cannot be done by string-trimming the BSD name.
    private nonisolated static func wholeDisk(forBSD bsd: String) -> String? {
        var node = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard node != 0 else { return nil }
        for _ in 0..<24 {
            if IOObjectConformsTo(node, "IOBlockStorageDriver") != 0 {
                let name = childBSDName(node)
                IOObjectRelease(node)
                return name
            }
            var parent: io_object_t = 0
            let ok = IORegistryEntryGetParentEntry(node, "IOService", &parent) == KERN_SUCCESS
            IOObjectRelease(node)
            guard ok, parent != 0 else { return nil }
            node = parent
        }
        IOObjectRelease(node)
        return nil
    }

    private nonisolated static func bsdName(of url: URL) -> String? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        let from = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard from.hasPrefix("/dev/") else { return nil }
        return String(from.dropFirst(5))
    }

    // MARK: - Formatting (shared with the module view)

    /// Capacities read as whole numbers once they are big enough not to need
    /// the precision: "744 GB of 995 GB", never ByteCountFormatter's
    /// "743.9 GB of 994.66 GB" with its decimals landing differently in each
    /// half of the same sentence.
    static func bytes(_ n: Int64) -> String {
        let v = Double(max(0, n))
        for (scale, unit) in [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")] {
            guard v >= scale else { continue }
            let x = v / scale
            if x >= 10 { return String(format: "%.0f %@", x, unit) }
            // Under ten the tenth matters ("1.2 TB"), but a bare "2 TB" should
            // not be dressed up as "2.0 TB".
            return String(format: "%.1f %@", x, unit).replacingOccurrences(of: ".0 ", with: " ")
        }
        return "\(max(0, n)) B"
    }

    /// Throughput reads as MB/s once it matters and KB/s when it does not, so
    /// an idle disk shows "0 KB/s" rather than a row of zeroes after a decimal.
    static func rate(_ bps: Double?) -> String {
        guard let bps else { return "—" }
        if bps >= 1e6 { return String(format: "%.0f MB/s", bps / 1e6) }
        if bps >= 1e5 { return String(format: "%.1f MB/s", bps / 1e6) }
        return String(format: "%.0f KB/s", max(0, bps) / 1e3)
    }
}
