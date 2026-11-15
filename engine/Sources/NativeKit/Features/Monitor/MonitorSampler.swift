import Darwin
import Foundation

/// 菜单栏三个图标分别代表的指标。
enum MonitorMetric: String, CaseIterable {
    case network
    case cpu
    case memory

    var title: String {
        switch self {
        case .network: return "网络"
        case .cpu: return "CPU"
        case .memory: return "内存"
        }
    }

    /// 面板标题。
    var panelTitle: String {
        switch self {
        case .network: return "网络流量最高的进程"
        case .cpu: return "CPU 占用最高的进程"
        case .memory: return "内存占用最高的进程"
        }
    }

    /// 状态栏图标用的 SF Symbol。
    var symbolName: String {
        switch self {
        case .network: return "network"
        case .cpu: return "cpu"
        case .memory: return "memorychip.fill"
        }
    }
}

/// 系统级（不是某个进程）的即时读数。
struct MonitorTotals {
    var downPerSecond: Double = 0
    var upPerSecond: Double = 0
    var cpuPercent: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var coreCount: Int = 0

    var memoryPercent: Double {
        guard memoryTotal > 0 else { return 0 }
        return min(100, Double(memoryUsed) / Double(memoryTotal) * 100)
    }
}

/// 单个进程的一行读数。CPU 用 top 的口径（100% = 一个核心满载）。
struct MonitorRow {
    var pid: pid_t
    var name: String
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var downPerSecond: Double = 0
    var upPerSecond: Double = 0

    func load(for metric: MonitorMetric) -> Double {
        switch metric {
        case .network: return downPerSecond + upPerSecond
        case .cpu: return cpuPercent
        case .memory: return Double(memoryBytes)
        }
    }
}

enum MonitorFormat {
    /// 字节速率：`0 B/s` / `1.5 KB/s` / `12 MB/s`。
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1 { return "0 B/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var scaled = value
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        let digits = scaled >= 100 ? 0 : 1
        return String(format: "%.\(digits)f %@", scaled, units[index])
    }

    /// 容量：`512 KB` / `1.5 MB` / `8.1 GB`（小于 10 MB/GB 时留一位小数）。
    static func bytes(_ value: UInt64) -> String {
        let double = Double(value)
        if double < 1024 * 1024 { return String(format: "%.0f KB", double / 1024) }
        if double < 1024 * 1024 * 1024 {
            let megabytes = double / (1024 * 1024)
            return String(format: megabytes < 10 ? "%.1f MB" : "%.0f MB", megabytes)
        }
        return String(format: "%.1f GB", double / (1024 * 1024 * 1024))
    }

    /// 百分比：小于 10% 时留一位小数，其余取整。
    static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 999)
        if clamped < 10 { return String(format: "%.1f%%", clamped) }
        return String(format: "%.0f%%", clamped)
    }

    /// 菜单栏文本：网络方向箭头 + 速率。
    static func networkTitle(down: Double, up: Double, detailed: Bool) -> String {
        let downText = "↓" + rate(down)
        guard detailed else { return downText }
        return downText + " ↑" + rate(up)
    }

    /// 菜单栏用的紧凑速率：`512B` / `3.0K` / `1.2M`（不带 `/s`，短到能塞进状态栏一行）。
    static func compactRate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1 { return "0B" }
        if value < 1024 { return String(format: "%.0fB", value) }
        let kilobytes = value / 1024
        if kilobytes < 1000 {
            return String(format: kilobytes < 10 ? "%.1fK" : "%.0fK", kilobytes)
        }
        let megabytes = kilobytes / 1024
        if megabytes < 1000 {
            return String(format: megabytes < 10 ? "%.1fM" : "%.0fM", megabytes)
        }
        return String(format: "%.1fG", megabytes / 1024)
    }

    /// 菜单栏网络标题：`↓3.0K ↑1.2K`；关掉「同时显示上行」时只留下行。
    static func menuNetworkTitle(down: Double, up: Double, detailed: Bool) -> String {
        // 不加空格：`↓10K↑6.0K` 比 `↓10K ↑6.0K` 省几个点，正好够塞下第三个图标。
        let text = "↓" + compactRate(down)
        guard detailed else { return text }
        return text + "↑" + compactRate(up)
    }

    static func cpuTitle(_ value: Double) -> String {
        percent(value)
    }

    static func memoryTitle(_ totals: MonitorTotals) -> String {
        percent(totals.memoryPercent)
    }
}

/// 采集器：持有上一次的计数器用于做差分。所有方法都在主线程之外使用也安全
/// （内部只有值类型状态，调用方自己保证串行）。
final class MonitorSampler {
    private var lastNetwork: (up: UInt64, down: UInt64, at: Date)?
    private var lastCPUTicks: (total: UInt64, busy: UInt64, at: Date)?
    private var lastProcessCPUSeconds: [pid_t: Double] = [:]
    private var lastProcessSample: Date?
    private var processCache: (rows: [MonitorRow], at: Date)?
    private var nettopCache: (rows: [MonitorRow], at: Date)?

    // MARK: - 系统总量

    func totals() -> MonitorTotals {
        var totals = MonitorTotals()
        totals.coreCount = ProcessInfo.processInfo.processorCount

        let counters = Self.interfaceCounters()
        let now = Date()
        if let previous = lastNetwork {
            let elapsed = max(now.timeIntervalSince(previous.at), 0.2)
            totals.upPerSecond = Double(counters.up &- previous.up) / elapsed
            totals.downPerSecond = Double(counters.down &- previous.down) / elapsed
        }
        lastNetwork = (counters.up, counters.down, now)

        if let ticks = Self.cpuTicks() {
            if let previous = lastCPUTicks {
                let totalDelta = Double(ticks.total &- previous.total)
                let busyDelta = Double(ticks.busy &- previous.busy)
                if totalDelta > 0 {
                    totals.cpuPercent = min(100, max(0, busyDelta / totalDelta * 100))
                }
            }
            lastCPUTicks = (ticks.total, ticks.busy, now)
        }

        let memory = Self.memory()
        totals.memoryUsed = memory.used
        totals.memoryTotal = memory.total
        return totals
    }

    // MARK: - 进程排名

    /// CPU / 内存排名。优先用 `proc_pid_rusage` 的差分（瞬时、精确），
    /// 取不到的 root 进程用 `ps` 的衰减平均补位。
    func processRows(metric: MonitorMetric, limit: Int) -> [MonitorRow] {
        // 同一拍里可能被 CPU 与内存两个面板各问一次（还有 tick 和点击），
        // 0.25 秒内复用同一份采样，避免差分被瞬时分母打乱。
        if let cached = processCache, Date().timeIntervalSince(cached.at) < 0.25 {
            return Self.rank(cached.rows, metric: metric, limit: limit)
        }
        let rows = sampleProcesses()
        processCache = (rows, Date())
        return Self.rank(rows, metric: metric, limit: limit)
    }

    static func rank(_ rows: [MonitorRow], metric: MonitorMetric, limit: Int) -> [MonitorRow] {
        let sorted = rows
            .filter { $0.load(for: metric) > 0 }
            .sorted { $0.load(for: metric) > $1.load(for: metric) }
        return Array(sorted.prefix(max(1, limit)))
    }

    private func sampleProcesses() -> [MonitorRow] {
        var rows: [pid_t: MonitorRow] = [:]

        let now = Date()
        let hasPrevious = lastProcessSample != nil
        let elapsed = lastProcessSample.map { max(now.timeIntervalSince($0), 0.2) } ?? 1
        let rusage = Self.rusageSamples()
        for (pid, sample) in rusage {
            // proc_name 偶尔给空串（内核线程、刚退出的进程），别让面板出现无名行。
            var row = MonitorRow(pid: pid, name: sample.name.isEmpty ? "pid \(pid)" : sample.name)
            row.memoryBytes = sample.footprint
            if let previous = lastProcessCPUSeconds[pid] {
                row.cpuPercent = max(0, (sample.cpuSeconds - previous) / elapsed * 100)
            }
            rows[pid] = row
        }
        lastProcessCPUSeconds = rusage.mapValues { $0.cpuSeconds }
        lastProcessSample = now

        // ps 兜底：root 进程（WindowServer 等）拿不到 rusage；第一次采样没有
        // 上一次的 CPU 时间可减，也全靠它。
        for (pid, sample) in Self.psSamples() {
            if var row = rows[pid] {
                if !hasPrevious || row.cpuPercent <= 0 {
                    row.cpuPercent = sample.cpu
                }
                if row.memoryBytes == 0 { row.memoryBytes = sample.rss }
                // proc_name 只有 32 字节，ps 的 comm 更完整（带回 (Renderer) 这类后缀）。
                if sample.name.count > row.name.count { row.name = sample.name }
                rows[pid] = row
            } else {
                var row = MonitorRow(pid: pid, name: sample.name)
                row.cpuPercent = sample.cpu
                row.memoryBytes = sample.rss
                rows[pid] = row
            }
        }

        return Array(rows.values)
    }

    /// nettop 报的进程名会被截到 15 个字符，用 ps 的全名补回去（同一个 pid）。
    func resolveNames(_ rows: [MonitorRow]) -> [MonitorRow] {
        guard !rows.isEmpty else { return rows }
        let names = Self.psSamples().mapValues(\.name)
        return rows.map { row in
            guard let full = names[row.pid], full.count > row.name.count else { return row }
            var copy = row
            copy.name = full
            return copy
        }
    }

    /// 网络排名。只能靠 `nettop` 的两次采样做差分；首次调用约需 1 秒，
    /// 结果缓存 1 秒避免面板刷新时反复起子进程。
    func networkRows(limit: Int, delay: Int = 1) -> [MonitorRow] {
        if let cache = nettopCache, Date().timeIntervalSince(cache.at) < 1 {
            return Array(cache.rows.prefix(max(1, limit)))
        }
        let samples = Self.nettopSamples(delay: delay)
        guard let previous = samples.dropLast().last, let current = samples.last else {
            return nettopCache.map { Array($0.rows.prefix(max(1, limit))) } ?? []
        }
        let interval = Double(max(delay, 1))
        var rows: [MonitorRow] = []
        for (key, value) in current {
            let before = previous[key] ?? (0, 0)
            let down = max(0, value.in - before.0) / interval
            let up = max(0, value.out - before.1) / interval
            guard down + up > 0 else { continue }
            rows.append(MonitorRow(pid: key.pid, name: key.name, downPerSecond: down, upPerSecond: up))
        }
        rows.sort { $0.load(for: .network) > $1.load(for: .network) }
        nettopCache = (rows, Date())
        return Array(rows.prefix(max(1, limit)))
    }

    // MARK: - 底层采样

    private static func interfaceCounters() -> (up: UInt64, down: UInt64) {
        var up: UInt64 = 0
        var down: UInt64 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let flags = Int32(entry.pointee.ifa_flags)
            let family = entry.pointee.ifa_addr?.pointee.sa_family
            if family == UInt8(AF_LINK), let raw = entry.pointee.ifa_data {
                let interfaceName = String(cString: entry.pointee.ifa_name)
                if interfaceName != "lo0", flags & IFF_UP != 0 {
                    let stats = raw.assumingMemoryBound(to: if_data.self).pointee
                    up &+= UInt64(stats.ifi_obytes)
                    down &+= UInt64(stats.ifi_ibytes)
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return (up, down)
    }

    private static func cpuTicks() -> (total: UInt64, busy: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        let user = UInt64(ticks.0)
        let system = UInt64(ticks.1)
        let idle = UInt64(ticks.2)
        let nice = UInt64(ticks.3)
        return (user + system + idle + nice, user + system + nice)
    }

    private static func memory() -> (used: UInt64, total: UInt64) {
        var total: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &length, nil, 0)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return (active + wired + compressed, total)
    }

    private struct RusageSample {
        var name: String
        var cpuSeconds: Double
        var footprint: UInt64
    }

    private static func rusageSamples() -> [pid_t: RusageSample] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [:] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        var samples: [pid_t: RusageSample] = [:]
        samples.reserveCapacity(count)
        var nameBuffer = [CChar](repeating: 0, count: 256)
        for index in 0..<min(count, pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
                }
            }
            guard result == 0 else { continue }
            nameBuffer.withUnsafeMutableBufferPointer { buffer in
                _ = proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            let name = String(cString: nameBuffer)
            samples[pid] = RusageSample(
                name: name.isEmpty ? "pid \(pid)" : name,
                cpuSeconds: Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000,
                footprint: info.ri_phys_footprint
            )
        }
        return samples
    }

    struct PsSample {
        var name: String
        var cpu: Double
        var rss: UInt64
    }

    private static func psSamples() -> [pid_t: PsSample] {
        guard let output = runProcess(
            "/bin/ps",
            ["-A", "-o", "pid=,pcpu=,rss=,comm="],
            timeout: 3
        ) else { return [:] }
        return parsePs(output)
    }

    /// `ps -A -o pid=,pcpu=,rss=,comm=` 的解析（rss 从 KB 换成字节）。
    static func parsePs(_ output: String) -> [pid_t: PsSample] {
        var samples: [pid_t: PsSample] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]),
                  let rss = UInt64(parts[2])
            else { continue }
            let command = String(parts[3])
            let name = (command as NSString).lastPathComponent
            samples[pid] = PsSample(
                name: name.isEmpty ? command : name,
                cpu: cpu,
                rss: rss * 1024
            )
        }
        return samples
    }

    struct NettopKey: Hashable {
        var pid: pid_t
        var name: String
    }

    /// 解析 nettop 的 CSV 输出（`-L` 模式）：每个样本以 `,bytes_in,bytes_out,` 开头，
    /// 行形如 `name.pid,in,out,`。返回按样本切好的累计值数组。
    static func nettopSamples(delay: Int) -> [[NettopKey: (in: Double, out: Double)]] {
        guard let output = runProcess(
            "/usr/bin/nettop",
            ["-P", "-l", "2", "-s", "\(max(1, delay))", "-x", "-L", "2", "-J", "bytes_in,bytes_out"],
            timeout: Double(max(1, delay)) + 4
        ) else { return [] }
        return parseNettop(output)
    }

    static func parseNettop(_ output: String) -> [[NettopKey: (in: Double, out: Double)]] {
        var samples: [[NettopKey: (in: Double, out: Double)]] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix(",") {
                samples.append([:])
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let key = parseNettopKey(String(fields[0]))
            guard let bytesIn = Double(fields[1]), let bytesOut = Double(fields[2]) else { continue }
            if samples.isEmpty { samples.append([:]) }
            samples[samples.count - 1][key] = (bytesIn, bytesOut)
        }
        return samples
    }

    static func parseNettopKey(_ raw: String) -> NettopKey {
        // `name.pid`：名字里可能自带点（com.apple.foo），只截最后一个点后的数字。
        guard let dot = raw.lastIndex(of: ".") else { return NettopKey(pid: 0, name: raw) }
        let name = String(raw[raw.startIndex..<dot])
        let suffix = String(raw[raw.index(after: dot)...])
        if let pid = pid_t(suffix) { return NettopKey(pid: pid, name: name) }
        return NettopKey(pid: 0, name: raw)
    }

    /// 跑一个短命子进程并收 stdout（读到底，超时则放弃）。
    /// 读管道放在后台队列上，主线程只转 RunLoop，避免 `availableData` 把线程钉住。
    static func runProcess(_ path: String, _ arguments: [String], timeout: Double) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let collected = NSMutableData()
        let lock = NSLock()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { source in
            let chunk = source.availableData
            if chunk.isEmpty {
                source.readabilityHandler = nil
                return
            }
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        handle.readabilityHandler = nil

        let rest = handle.readDataToEndOfFile()
        lock.lock()
        if !rest.isEmpty { collected.append(rest) }
        let data = collected as Data
        lock.unlock()
        return String(data: data, encoding: .utf8)
    }
}
