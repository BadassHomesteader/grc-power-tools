import Cocoa
import IOKit
import IOKit.ps

/// What the machine is doing right now, for the notch's System module.
///
/// PULL-BASED, no timer — same contract as DiskReader: `snapshot` returns the
/// last reading and kicks a background sample when it has gone stale, so
/// nothing is measured unless a module is on screen asking for it.
///
/// EVERY field is Optional and every nil draws an em dash. A system monitor
/// that invents a zero is worse than one that admits it cannot see: see
/// `dieTemperatureC` and `fanRPM`, which are nil on purpose.
@MainActor final class SystemStatsReader {
    static let shared = SystemStatsReader()

    struct Snapshot {
        // Static facts about the machine.
        var chip: String?
        var pCores = 0
        var eCores = 0
        var logicalCores = 0
        var gpuCores: Int?
        var memTotal: UInt64 = 0

        // CPU / GPU / memory, as fractions of 100.
        var cpuBusy: Double?
        var cpuP: Double?
        var cpuE: Double?
        var gpuBusy: Double?
        var memUsed: UInt64?
        var memWired: UInt64?
        var memCompressed: UInt64?
        var pressure: Int?          // 1 normal · 2 warning · 4 critical
        var swapUsed: UInt64?
        var swapTotal: UInt64?

        var load1: Double?
        var processes: Int?
        var uptime: TimeInterval?

        // Power.
        var batteryPercent: Int?
        var charging: Bool?
        var onAC: Bool?
        var minutesRemaining: Int?
        var healthPercent: Double?
        var cycles: Int?
        var designCycles: Int?
        var batteryTempC: Double?
        var watts: Double?

        /// CPU/GPU DIE temperature. Always nil today, and deliberately so: the
        /// sensor nodes (AppleARMPMUTempSensor and friends) publish HID
        /// plumbing with no value property, so the only routes are an AppleSMC
        /// user client with undocumented four-char keys that differ per chip
        /// generation, or the private IOHIDEventSystemClient temperature event.
        /// Neither is public API, so the module draws — and says why, rather
        /// than labelling the battery's temperature as the CPU's.
        var dieTemperatureC: Double?
        /// Fan speed. Also nil: this Mac publishes no fan node at all, and the
        /// only route is the same private SMC path. `powermetrics` needs root
        /// and is not an option.
        var fanRPM: [Int]?

        /// True until two CPU samples exist — busy % is a DELTA and cannot be
        /// computed from one reading. The view draws — rather than a false 0%.
        var warming = true
        var at = Date.distantPast
    }

    struct Ticks {
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        var busy: UInt64 { user &+ system &+ nice }
        var total: UInt64 { busy &+ idle }
    }
    struct Raw {
        var all = Ticks()
        var per: [Ticks] = []
        var at = Date()
    }

    private var cached = Snapshot()
    private var raw: Raw?
    private var refreshing = false
    private var seeded = false

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
        DispatchQueue.global(qos: .utility).async {
            let (snap, raw) = Self.sample(previous: previous)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.cached = snap
                    self.raw = raw
                    self.refreshing = false
                }
            }
        }
    }

    // MARK: - Sampling (off the main thread)

    nonisolated static func sample(previous: Raw?) -> (Snapshot, Raw) {
        var s = Snapshot()
        let now = Date()

        // Machine facts.
        s.chip = sysctlString("machdep.cpu.brand_string")
        s.pCores = Int(sysctlInt("hw.perflevel0.logicalcpu") ?? 0)
        s.eCores = Int(sysctlInt("hw.perflevel1.logicalcpu") ?? 0)
        s.memTotal = ProcessInfo.processInfo.physicalMemory

        // CPU: ticks are counters, so busy is a delta over the interval.
        let ticks = cpuTicks()
        s.logicalCores = ticks.per.count
        let raw = Raw(all: ticks.all, per: ticks.per, at: now)
        if let p = previous, !p.per.isEmpty, p.per.count == ticks.per.count {
            let elapsed = now.timeIntervalSince(p.at)
            // A machine that slept would otherwise report the average across
            // the nap; bound the window the way DiskReader bounds its counters.
            if elapsed > 0.2, elapsed < 30 {
                s.cpuBusy = busyPercent(ticks.all, p.all)
                if s.pCores > 0 {
                    s.cpuP = busyPercent(sum(ticks.per, 0..<s.pCores), sum(p.per, 0..<s.pCores))
                }
                if s.eCores > 0, s.pCores + s.eCores <= ticks.per.count {
                    let r = s.pCores..<(s.pCores + s.eCores)
                    s.cpuE = busyPercent(sum(ticks.per, r), sum(p.per, r))
                }
                s.warming = false
            }
        }

        // Memory: Activity Monitor's "used" — everything that is not free or
        // purgeable, plus what the compressor is holding.
        var vmstat = vm_statistics64()
        var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmstat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vmstat.internal_page_count)
            let purgeable = UInt64(vmstat.purgeable_count)
            s.memUsed = (internalPages - min(purgeable, internalPages)
                         + UInt64(vmstat.wire_count) + UInt64(vmstat.compressor_page_count)) * page
            s.memWired = UInt64(vmstat.wire_count) * page
            s.memCompressed = UInt64(vmstat.compressor_page_count) * page
        }
        s.pressure = sysctlInt("kern.memorystatus_vm_pressure_level").map(Int.init)
        var swap = xsw_usage()
        var swsz = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swsz, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
            s.swapTotal = swap.xsu_total
        }

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) > 0 { s.load1 = loads[0] }
        s.processes = processCount()
        s.uptime = uptimeSeconds()

        (s.gpuBusy, s.gpuCores) = gpu()
        applyPower(&s)

        s.at = now
        return (s, raw)
    }

    // MARK: CPU

    private nonisolated static func busyPercent(_ a: Ticks, _ b: Ticks) -> Double? {
        let total = Double(a.total &- b.total)
        guard total > 0 else { return nil }
        return min(100, max(0, Double(a.busy &- b.busy) / total * 100))
    }

    private nonisolated static func sum(_ t: [Ticks], _ r: Range<Int>) -> Ticks {
        var out = Ticks()
        for i in r where i >= 0 && i < t.count {
            out.user &+= t[i].user; out.system &+= t[i].system
            out.idle &+= t[i].idle; out.nice &+= t[i].nice
        }
        return out
    }

    private nonisolated static func cpuTicks() -> (all: Ticks, per: [Ticks]) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpus, &info, &count) == KERN_SUCCESS, let info else {
            return (Ticks(), [])
        }
        // Without this every sample leaks a VM region.
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var all = Ticks()
        var per: [Ticks] = []
        for i in 0..<Int(cpus) {
            let base = i * Int(CPU_STATE_MAX)
            var t = Ticks()
            t.user = UInt64(info[base + Int(CPU_STATE_USER)])
            t.system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            t.idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            t.nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            per.append(t)
            all.user &+= t.user; all.system &+= t.system
            all.idle &+= t.idle; all.nice &+= t.nice
        }
        return (all, per)
    }

    // MARK: sysctl

    private nonisolated static func sysctlInt(_ name: String) -> Int64? {
        var v: Int64 = 0
        var sz = MemoryLayout<Int64>.size
        if sysctlbyname(name, &v, &sz, nil, 0) == 0, sz == MemoryLayout<Int64>.size { return v }
        var v32: Int32 = 0
        var sz32 = MemoryLayout<Int32>.size
        if sysctlbyname(name, &v32, &sz32, nil, 0) == 0 { return Int64(v32) }
        return nil
    }

    private nonisolated static func sysctlString(_ name: String) -> String? {
        var sz = 0
        guard sysctlbyname(name, nil, &sz, nil, 0) == 0, sz > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: sz)
        guard sysctlbyname(name, &buf, &sz, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private nonisolated static func processCount() -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        return size / MemoryLayout<kinfo_proc>.stride
    }

    private nonisolated static func uptimeSeconds() -> TimeInterval? {
        var bt = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bt, &size, nil, 0) == 0, bt.tv_sec > 0 else { return nil }
        return Date().timeIntervalSince1970 - Double(bt.tv_sec)
    }

    // MARK: IOKit

    private nonisolated static func prop(_ svc: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// GPU busy % from the accelerator's PerformanceStatistics. Undocumented,
    /// so every read is optional — a nil here costs one dash, not a crash.
    private nonisolated static func gpu() -> (Double?, Int?) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iter) }
        var busy: Double?
        var cores: Int?
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            if let stats = prop(svc, "PerformanceStatistics") as? [String: Any],
               let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                busy = max(busy ?? 0, min(100, util))
            }
            if let c = (prop(svc, "gpu-core-count") as? NSNumber)?.intValue { cores = c }
        }
        return (busy, cores)
    }

    private nonisolated static func applyPower(_ s: inout Snapshot) {
        // Charge and time remaining come from the one fully documented power
        // API; health and wattage are registry properties with no public
        // equivalent, so they are read separately and may each be missing.
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any]
                else { continue }
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    s.batteryPercent = Int((Double(cur) / Double(max) * 100).rounded())
                }
                s.charging = d[kIOPSIsChargingKey] as? Bool
                s.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                let toEmpty = d[kIOPSTimeToEmptyKey] as? Int ?? -1
                let toFull = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
                // Both read -1 while the estimate is still settling.
                let mins = (s.onAC == true) ? toFull : toEmpty
                s.minutesRemaining = mins > 0 ? mins : nil
                break
            }
        }

        let batt = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard batt != 0 else { return }
        defer { IOObjectRelease(batt) }
        let design = (prop(batt, "DesignCapacity") as? NSNumber)?.doubleValue ?? 0
        // NominalChargeCapacity is what System Information calls "Maximum
        // Capacity"; AppleRawMaxCapacity is the older fallback.
        let nominal = (prop(batt, "NominalChargeCapacity") as? NSNumber)?.doubleValue
            ?? (prop(batt, "AppleRawMaxCapacity") as? NSNumber)?.doubleValue
        if let nominal, design > 0 { s.healthPercent = nominal / design * 100 }
        s.cycles = (prop(batt, "CycleCount") as? NSNumber)?.intValue
        s.designCycles = (prop(batt, "DesignCycleCount9C") as? NSNumber)?.intValue
        if let t = (prop(batt, "Temperature") as? NSNumber)?.doubleValue { s.batteryTempC = t / 100 }

        // Volts × amps is the real draw while on battery; the sign says which
        // way the charge is flowing, and the magnitude is what we show.
        let mV = (prop(batt, "Voltage") as? NSNumber)?.doubleValue ?? 0
        let mA = Double(Int64(bitPattern: (prop(batt, "InstantAmperage") as? NSNumber)?.uint64Value ?? 0))
        let fromCell = abs(mV / 1000 * mA / 1000)
        // On AC with a full battery no current flows through the cell, so that
        // figure is not system power — the telemetry channel still is.
        let telemetry = (prop(batt, "PowerTelemetryData") as? [String: Any])
        let sysLoad = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue
        if let sysLoad, sysLoad > 0 { s.watts = sysLoad / 1000 } else if fromCell > 0.05 { s.watts = fromCell }
    }

    // MARK: - Formatting

    /// Memory is quoted in GiB because that is what the Mac is sold with and
    /// what Activity Monitor shows — 48 GB, not the 52 GB a decimal divide
    /// gives. Disks are decimal (see DiskReader); the two conventions are
    /// macOS's, not ours.
    static func gib(_ n: UInt64?) -> String {
        guard let n else { return "—" }
        let v = Double(n) / 1_073_741_824
        if v >= 100 { return String(format: "%.0f GB", v) }
        // "48 GB", not "48.0 GB" — the tenth is noise on a round figure.
        return String(format: "%.1f GB", v).replacingOccurrences(of: ".0 ", with: " ")
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))%"
    }

    static func uptimeText(_ t: TimeInterval?) -> String {
        guard let t, t > 0 else { return "—" }
        let d = Int(t) / 86400, h = (Int(t) % 86400) / 3600, m = (Int(t) % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func pressureText(_ level: Int?) -> String {
        switch level {
        case 1: return "Normal"
        case 2: return "Warning"
        case 4: return "Critical"
        default: return "—"
        }
    }
}
