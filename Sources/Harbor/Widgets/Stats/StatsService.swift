import AppKit
import Darwin
import IOKit

struct ProcessSample: Identifiable, Hashable {
    var pid: pid_t
    var name: String
    var cpu: Double      // percent of one core
    var memory: UInt64   // bytes (physical footprint)
    var id: pid_t { pid }
}

struct LargeFile: Identifiable, Hashable {
    var url: URL
    var size: Int64
    var id: URL { url }
}

/// Live CPU, memory, disk, GPU, disk I/O and network counters, read locally.
@MainActor
final class StatsService: ObservableObject {
    static let shared = StatsService()
    static let historyLength = 120

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuUser: Double = 0
    @Published private(set) var cpuSystem: Double = 0
    @Published private(set) var cpuIdle: Double = 1
    @Published private(set) var cpuHistory: [Double] = []
    let cores = ProcessInfo.processInfo.activeProcessorCount

    @Published private(set) var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var memUsed: UInt64 = 0
    @Published private(set) var memCached: UInt64 = 0
    @Published private(set) var memFree: UInt64 = 0
    @Published private(set) var memPressure: Int = 1
    @Published private(set) var memHistory: [Double] = []

    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var diskUsed: Int64 = 0
    @Published private(set) var diskHistory: [Double] = []

    @Published private(set) var gpu: Double?
    @Published private(set) var gpuHistory: [Double] = []

    @Published private(set) var diskRead: Double = 0
    @Published private(set) var diskWrite: Double = 0
    @Published private(set) var diskReadOps: Double = 0
    @Published private(set) var diskWriteOps: Double = 0
    @Published private(set) var readHistory: [Double] = []
    @Published private(set) var writeHistory: [Double] = []

    @Published private(set) var netIn: Double = 0
    @Published private(set) var netOut: Double = 0
    @Published private(set) var netInHistory: [Double] = []
    @Published private(set) var netOutHistory: [Double] = []

    @Published private(set) var processes: [ProcessSample] = []
    @Published private(set) var largeFiles: [LargeFile] = []
    @Published private(set) var scanningLargeFiles = false

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var diskFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }

    private let sampler = SystemSampler()
    private let queue = DispatchQueue(label: "stats.sampler", qos: .utility)
    private var timer: Timer?
    private var tick = 0

    private init() {}

    func setActive(_ active: Bool) {
        if active, timer == nil {
            sample()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sample() }
            }
        } else if !active {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Process lists are only sampled while the stats drawer is open.
    private var processesWanted: Bool { DrawerController.shared.openKind == .stats }

    func sampleNow() { sample() }

    func kill(_ p: ProcessSample) {
        if let app = NSRunningApplication(processIdentifier: p.pid) {
            app.terminate()
        } else {
            Darwin.kill(p.pid, SIGTERM)
        }
        processes.removeAll { $0.pid == p.pid }
    }

    func scanLargeFiles() {
        guard !scanningLargeFiles else { return }
        scanningLargeFiles = true
        DispatchQueue.global(qos: .utility).async {
            let files = SystemSampler.findLargeFiles()
            Task { @MainActor in
                self.largeFiles = files
                self.scanningLargeFiles = false
            }
        }
    }

    private func sample() {
        tick += 1
        let wantsProcs = processesWanted && (tick % 2 == 0 || processes.isEmpty)
        queue.async { [sampler] in
            let s = sampler.sample(includeProcesses: wantsProcs)
            Task { @MainActor in self.apply(s, processes: wantsProcs) }
        }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
    }

    private func apply(_ s: SystemSampler.Snapshot, processes procs: Bool) {
        cpu = s.cpu
        cpuUser = s.cpuUser
        cpuSystem = s.cpuSystem
        cpuIdle = s.cpuIdle
        push(&cpuHistory, s.cpu)

        memUsed = s.memUsed
        memCached = s.memCached
        memFree = s.memFree
        memPressure = s.memPressure
        push(&memHistory, Double(s.memUsed))

        diskTotal = s.diskTotal
        diskUsed = s.diskUsed
        push(&diskHistory, Double(s.diskUsed))

        gpu = s.gpu
        push(&gpuHistory, s.gpu ?? 0)

        diskRead = s.diskRead
        diskWrite = s.diskWrite
        diskReadOps = s.diskReadOps
        diskWriteOps = s.diskWriteOps
        push(&readHistory, s.diskRead)
        push(&writeHistory, s.diskWrite)

        netIn = s.netIn
        netOut = s.netOut
        push(&netInHistory, s.netIn)
        push(&netOutHistory, s.netOut)

        if procs, let list = s.processes {
            let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                                  uniquingKeysWith: { a, _ in a })
            processes = list.map { p in
                var p = p
                if let name = apps[p.pid]?.localizedName { p.name = name }
                return p
            }
        }
    }
}

/// Does the actual syscalls. Only touched from StatsService's serial queue.
final class SystemSampler: @unchecked Sendable {
    struct Snapshot {
        var cpu = 0.0, cpuUser = 0.0, cpuSystem = 0.0, cpuIdle = 1.0
        var memUsed: UInt64 = 0, memCached: UInt64 = 0, memFree: UInt64 = 0, memPressure = 1
        var diskTotal: Int64 = 0, diskUsed: Int64 = 0
        var gpu: Double?
        var diskRead = 0.0, diskWrite = 0.0, diskReadOps = 0.0, diskWriteOps = 0.0
        var netIn = 0.0, netOut = 0.0
        var processes: [ProcessSample]?
    }

    private var lastCPU: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastIO: (r: UInt64, w: UInt64, ro: UInt64, wo: UInt64, t: TimeInterval)?
    private var lastNet: (i: UInt64, o: UInt64, t: TimeInterval)?
    private var lastProc: [pid_t: UInt64] = [:]
    private var lastProcTime: TimeInterval = 0
    private var diskCache: (Int64, Int64, TimeInterval)?
    private lazy var timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    func sample(includeProcesses: Bool) -> Snapshot {
        var s = Snapshot()
        let now = ProcessInfo.processInfo.systemUptime

        // CPU
        if let t = cpuTicks() {
            if let l = lastCPU {
                let u = Double(t.user &- l.user) + Double(t.nice &- l.nice)
                let sy = Double(t.system &- l.system)
                let id = Double(t.idle &- l.idle)
                let total = max(u + sy + id, 1)
                s.cpuUser = u / total
                s.cpuSystem = sy / total
                s.cpuIdle = id / total
                s.cpu = (u + sy) / total
            }
            lastCPU = t
        }

        // Memory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            let page = UInt64(pageSize)
            let total = ProcessInfo.processInfo.physicalMemory
            let app = UInt64(vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0) * page
            let wired = UInt64(vm.wire_count) * page
            let compressed = UInt64(vm.compressor_page_count) * page
            s.memUsed = min(total, app + wired + compressed)
            s.memCached = UInt64(vm.external_page_count + vm.purgeable_count) * page
            s.memFree = total > s.memUsed + s.memCached ? total - s.memUsed - s.memCached : 0
        }
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { s.memPressure = Int(level) }

        // Disk capacity (cheap, but no need every second)
        if let c = diskCache, now - c.2 < 15 {
            s.diskTotal = c.0
            s.diskUsed = c.1
        } else if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
                  let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacityForImportantUsage {
            s.diskTotal = Int64(total)
            s.diskUsed = Int64(total) - avail
            diskCache = (s.diskTotal, s.diskUsed, now)
        }

        s.gpu = gpuUtilization()

        // Disk I/O
        if let io = blockStorageStats() {
            if let l = lastIO {
                let dt = max(now - l.t, 0.001)
                s.diskRead = Double(io.r &- l.r) / dt
                s.diskWrite = Double(io.w &- l.w) / dt
                s.diskReadOps = Double(io.ro &- l.ro) / dt
                s.diskWriteOps = Double(io.wo &- l.wo) / dt
            }
            lastIO = (io.r, io.w, io.ro, io.wo, now)
        }

        // Network
        let net = networkBytes()
        if let l = lastNet {
            let dt = max(now - l.t, 0.001)
            s.netIn = net.i >= l.i ? Double(net.i - l.i) / dt : 0
            s.netOut = net.o >= l.o ? Double(net.o - l.o) / dt : 0
        }
        lastNet = (net.i, net.o, now)

        if includeProcesses { s.processes = processes(now: now) }
        return s
    }

    private func cpuTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (UInt64(load.cpu_ticks.0), UInt64(load.cpu_ticks.1), UInt64(load.cpu_ticks.2), UInt64(load.cpu_ticks.3))
    }

    private func registryProperties(_ service: io_object_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    private func forEachService(_ className: String, _ body: ([String: Any]) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let props = registryProperties(service) { body(props) }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func gpuUtilization() -> Double? {
        var best: Double?
        forEachService("IOAccelerator") { props in
            guard let perf = props["PerformanceStatistics"] as? [String: Any] else { return }
            let keys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %", "GPU Core Utilization"]
            for k in keys {
                if let n = perf[k] as? NSNumber {
                    var v = n.doubleValue
                    if k == "GPU Core Utilization" { v /= 10_000_000 }
                    best = max(best ?? 0, min(v / 100, 1))
                    break
                }
            }
        }
        return best
    }

    private func blockStorageStats() -> (r: UInt64, w: UInt64, ro: UInt64, wo: UInt64)? {
        var r: UInt64 = 0, w: UInt64 = 0, ro: UInt64 = 0, wo: UInt64 = 0
        var found = false
        forEachService("IOBlockStorageDriver") { props in
            guard let stats = props["Statistics"] as? [String: Any] else { return }
            found = true
            r += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            ro += (stats["Operations (Read)"] as? NSNumber)?.uint64Value ?? 0
            wo += (stats["Operations (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? (r, w, ro, wo) : nil
    }

    private func networkBytes() -> (i: UInt64, o: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var ib: UInt64 = 0, ob: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2,
                   off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if h2.ifm_flags & IFF_LOOPBACK == 0 {
                        ib &+= h2.ifm_data.ifi_ibytes
                        ob &+= h2.ifm_data.ifi_obytes
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return (ib, ob)
    }

    private func processes(now: TimeInterval) -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        let dt = lastProcTime > 0 ? max(now - lastProcTime, 0.001) : 0
        var next: [pid_t: UInt64] = [:]
        var result: [ProcessSample] = []
        result.reserveCapacity(n)
        let tb = timebase
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            var usage = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard rc == 0 else { continue }
            let ticks = usage.ri_user_time + usage.ri_system_time
            let ns = ticks * UInt64(tb.numer) / UInt64(max(tb.denom, 1))
            next[pid] = ns
            var cpu = 0.0
            if dt > 0, let prev = lastProc[pid], ns >= prev {
                cpu = Double(ns - prev) / (dt * 1_000_000_000) * 100
            }
            result.append(ProcessSample(pid: pid, name: Self.processName(pid), cpu: cpu, memory: usage.ri_phys_footprint))
        }
        lastProc = next
        lastProcTime = now
        return result
    }

    static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            // Prefer the .app name for helpers inside bundles.
            let comps = path.split(separator: "/")
            if let appIdx = comps.firstIndex(where: { $0.hasSuffix(".app") }), appIdx == comps.count - 4 {
                return String(comps[appIdx].dropLast(4))
            }
            return (path as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return String(cString: name)
    }

    static func findLargeFiles(threshold: Int64 = 100 * 1024 * 1024, limit: Int = 12) -> [LargeFile] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"].map { home.appendingPathComponent($0) }
        var found: [LargeFile] = []
        var visited = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isPackageKey]
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                visited += 1
                if visited > 60_000 { break }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let size = v.fileSize, Int64(size) >= threshold else { continue }
                found.append(LargeFile(url: url, size: Int64(size)))
            }
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}

enum ByteFormat {
    static func gb(_ bytes: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", bytes / 1_073_741_824)
    }

    /// "8.66 GB", "612 MB", "Zero KB"
    static func memory(_ bytes: UInt64) -> String {
        if bytes == 0 { return "Zero KB" }
        let b = Double(bytes)
        if b >= 1_073_741_824 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.0f MB", b / 1_048_576) }
        return String(format: "%.0f KB", b / 1024)
    }

    static func storage(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB, .useTB]
        return f.string(fromByteCount: bytes)
    }

    /// Value and unit split, for "18.9 MB/s" style labels.
    static func rate(_ bytesPerSec: Double) -> (String, String) {
        let b = max(0, bytesPerSec)
        if b >= 1_000_000_000 { return (String(format: "%.1f", b / 1_000_000_000), "GB/s") }
        if b >= 1_000_000 { return (String(format: "%.1f", b / 1_000_000), "MB/s") }
        if b >= 1_000 { return (String(format: "%.0f", b / 1_000), "KB/s") }
        return (String(format: "%.0f", b), "B/s")
    }
}
