import AppKit
import Foundation

/// 系统监控的自测：不依赖状态栏的真实点击，把格式化、解析、排名、
/// 采集与面板渲染逐项跑一遍。
enum MonitorSelfTest {
    private static var checks: [[String: Any]] = []
    private static var artifacts: [String] = []

    static func run() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(
            fileURLWithPath: environment["DSHS_SELFTEST_DIR"] ?? "/tmp/dsh-monitor-selftest",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // MARK: 格式化

        record("rate-zero", MonitorFormat.rate(0) == "0 B/s", MonitorFormat.rate(0))
        record("rate-kilobyte", MonitorFormat.rate(1536) == "1.5 KB/s", MonitorFormat.rate(1536))
        record(
            "rate-megabyte",
            MonitorFormat.rate(1_258_291) == "1.2 MB/s",
            MonitorFormat.rate(1_258_291)
        )
        record("percent-small", MonitorFormat.percent(0.42) == "0.4%", MonitorFormat.percent(0.42))
        record("percent-round", MonitorFormat.percent(23.6) == "24%", MonitorFormat.percent(23.6))
        record(
            "bytes-megabyte",
            MonitorFormat.bytes(1_572_864) == "1.5 MB",
            MonitorFormat.bytes(1_572_864)
        )
        record(
            "bytes-gigabyte",
            MonitorFormat.bytes(8_589_934_592) == "8.0 GB",
            MonitorFormat.bytes(8_589_934_592)
        )

        // MARK: 菜单栏文本

        record(
            "title-network-detailed",
            MonitorFormat.networkTitle(down: 1536, up: 512, detailed: true) == "↓1.5 KB/s ↑512 B/s",
            MonitorFormat.networkTitle(down: 1536, up: 512, detailed: true)
        )
        record(
            "title-network-compact",
            MonitorFormat.networkTitle(down: 1536, up: 512, detailed: false) == "↓1.5 KB/s",
            MonitorFormat.networkTitle(down: 1536, up: 512, detailed: false)
        )
        record(
            "compact-rate",
            MonitorFormat.compactRate(1536) == "1.5K"
                && MonitorFormat.compactRate(512) == "512B"
                && MonitorFormat.compactRate(12_582_912) == "12M"
                && MonitorFormat.compactRate(0.4) == "0B",
            "\(MonitorFormat.compactRate(1536)) / \(MonitorFormat.compactRate(512)) / \(MonitorFormat.compactRate(12_582_912))"
        )
        // 菜单栏两行：上一行标签 / 箭头，下一行数字。
        var lineTotals = MonitorTotals()
        lineTotals.cpuPercent = 26.2
        lineTotals.memoryUsed = 6_710_886_579
        lineTotals.memoryTotal = 8_589_934_592
        lineTotals.downPerSecond = 1536
        lineTotals.upPerSecond = 1024
        let cpuLines = MonitorFormat.menuLines(metric: .cpu, totals: lineTotals, detailed: true)
        record(
            "menu-lines-cpu",
            cpuLines.top == "CPU" && cpuLines.bottom == "26%",
            "\(cpuLines.top) / \(cpuLines.bottom)"
        )
        let memoryLines = MonitorFormat.menuLines(metric: .memory, totals: lineTotals, detailed: true)
        record(
            "menu-lines-memory",
            memoryLines.top == "MEM" && memoryLines.bottom == "78%",
            "\(memoryLines.top) / \(memoryLines.bottom)"
        )
        let networkLines = MonitorFormat.menuLines(metric: .network, totals: lineTotals, detailed: true)
        record(
            "menu-lines-network",
            networkLines.top == "↑1.0K" && networkLines.bottom == "↓1.5K",
            "\(networkLines.top) / \(networkLines.bottom)"
        )
        let networkDownOnly = MonitorFormat.menuLines(metric: .network, totals: lineTotals, detailed: false)
        record(
            "menu-lines-network-down-only",
            networkDownOnly.top.isEmpty && networkDownOnly.bottom == "↓1.5K",
            "top '\(networkDownOnly.top)' bottom '\(networkDownOnly.bottom)'"
        )
        let widthSample = MonitorFormat.menuWidthSample(metric: .cpu, detailed: true)
        record(
            "menu-width-sample",
            widthSample.top == "CPU" && widthSample.bottom == "100%",
            "\(widthSample.top) / \(widthSample.bottom)"
        )
        // 网速在 0B / 512B / 9.5K / 999M 之间跳，画布宽度必须不变（否则菜单栏一直抖）。
        var sampleTotals = MonitorTotals()
        let rates: [Double] = [0, 512, 1023, 1024, 9728, 1022976, 1048576, 1047527424, 1610612736]
        let widths = rates.map { value -> CGFloat in
            sampleTotals.downPerSecond = value
            sampleTotals.upPerSecond = value
            let lines = MonitorFormat.menuLines(metric: .network, totals: sampleTotals, detailed: true)
            return MonitorMenuBar.imageWidthForTesting(top: lines.top, bottom: lines.bottom)
        }
        let bandWidth = MonitorMenuBar.reservedWidthForTesting(metric: .network, detailed: true)
        record(
            "menu-width-reserved",
            widths.allSatisfy { $0 <= bandWidth + 0.5 } && bandWidth > 0,
            "reserved \(Int(bandWidth)) / 最宽样本 \(Int(widths.max() ?? 0))"
        )
        record(
            "title-cpu",
            MonitorFormat.cpuTitle(23.6) == "24%",
            MonitorFormat.cpuTitle(23.6)
        )
        var totals = MonitorTotals()
        totals.memoryUsed = 4_294_967_296
        totals.memoryTotal = 8_589_934_592
        record(
            "title-memory",
            MonitorFormat.memoryTitle(totals) == "50%",
            MonitorFormat.memoryTitle(totals)
        )

        // MARK: ps 解析

        let psFixture = """
             1   0.0  20480 /sbin/launchd
           165  43.8  53232 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
         13016  50.7 453792 /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness

        """
        let psRows = MonitorSampler.parsePs(psFixture)
        record("ps-parse-count", psRows.count == 3, "\(psRows.count) rows")
        record(
            "ps-parse-windowserver",
            psRows[165]?.name == "WindowServer" && psRows[165]?.cpu == 43.8,
            "\(psRows[165]?.name ?? "nil") cpu \(psRows[165]?.cpu ?? -1)"
        )
        record(
            "ps-parse-rss",
            psRows[13016]?.rss == 453_792 * 1024,
            "\(psRows[13016]?.rss ?? 0) bytes"
        )
        record(
            "ps-parse-spaces-in-path",
            psRows[13016]?.name == "DeepSeek Harness",
            psRows[13016]?.name ?? "nil"
        )

        // MARK: nettop 解析

        let nettopFixture = """
        ,bytes_in,bytes_out,
        com.apple.WebKit.Networking.900,1000,2000,
        DeepSeek Harnes.13016,5000,1000,
        ,bytes_in,bytes_out,
        com.apple.WebKit.Networking.900,3000,2000,
        DeepSeek Harnes.13016,5000,5000,

        """
        let samples = MonitorSampler.parseNettop(nettopFixture)
        record("nettop-sample-count", samples.count == 2, "\(samples.count) samples")
        let webkitKey = MonitorSampler.NettopKey(pid: 900, name: "com.apple.WebKit.Networking")
        record(
            "nettop-parse-key",
            samples.last?[webkitKey] != nil,
            "keys \(samples.last?.keys.map(\.name) ?? [])"
        )
        record(
            "nettop-parse-values",
            samples.last?[webkitKey]?.in == 3000 && samples.last?[webkitKey]?.out == 2000,
            "in \(samples.last?[webkitKey]?.in ?? -1) out \(samples.last?[webkitKey]?.out ?? -1)"
        )
        let nettopKey = MonitorSampler.NettopKey(pid: 13016, name: "DeepSeek Harnes")
        record(
            "nettop-name-with-space",
            samples.last?[nettopKey]?.out == 5000,
            "out \(samples.last?[nettopKey]?.out ?? -1)"
        )
        record(
            "nettop-parse-key-pid",
            MonitorSampler.parseNettopKey("com.apple.WebKit.Networking.900")
                == MonitorSampler.NettopKey(pid: 900, name: "com.apple.WebKit.Networking"),
            MonitorSampler.parseNettopKey("com.apple.WebKit.Networking.900").name
        )

        // MARK: 排名

        var cpuHeavy = MonitorRow(pid: 1, name: "heavy")
        cpuHeavy.cpuPercent = 88
        var memoryHeavy = MonitorRow(pid: 2, name: "memoryhog")
        memoryHeavy.memoryBytes = 2_147_483_648
        var networkHeavy = MonitorRow(pid: 3, name: "download")
        networkHeavy.downPerSecond = 9_000_000
        var idle = MonitorRow(pid: 4, name: "idle")
        idle.cpuPercent = 0
        let fixtureRows = [idle, memoryHeavy, cpuHeavy, networkHeavy]

        record(
            "rank-cpu",
            MonitorSampler.rank(fixtureRows, metric: .cpu, limit: 2).map(\.name) == ["heavy"],
            "\(MonitorSampler.rank(fixtureRows, metric: .cpu, limit: 2).map(\.name))"
        )
        record(
            "rank-memory",
            MonitorSampler.rank(fixtureRows, metric: .memory, limit: 1).map(\.name) == ["memoryhog"],
            "\(MonitorSampler.rank(fixtureRows, metric: .memory, limit: 1).map(\.name))"
        )
        record(
            "rank-network",
            MonitorSampler.rank(fixtureRows, metric: .network, limit: 1).map(\.name) == ["download"],
            "\(MonitorSampler.rank(fixtureRows, metric: .network, limit: 1).map(\.name))"
        )
        record(
            "rank-zero-filtered",
            MonitorSampler.rank([idle], metric: .cpu, limit: 5).isEmpty,
            "\(MonitorSampler.rank([idle], metric: .cpu, limit: 5).count)"
        )
        record(
            "rank-limit",
            MonitorSampler.rank(fixtureRows, metric: .memory, limit: 1).count == 1,
            "\(MonitorSampler.rank(fixtureRows, metric: .memory, limit: 1).count)"
        )

        // MARK: 设置

        var settings = MonitorSettings()
        settings.refreshSeconds = 0
        settings.topCount = 99
        let clamped = settings.normalized()
        record(
            "settings-clamp",
            clamped.refreshSeconds == 1 && clamped.topCount == 30,
            "refresh \(clamped.refreshSeconds) top \(clamped.topCount)"
        )
        let merged = MonitorSettings().merging(["topCount": 5, "showCPU": false, "nonsense": 1])
        record(
            "settings-merge",
            merged.topCount == 5 && merged.showCPU == false && merged.showNetwork == true,
            "top \(merged.topCount) cpu \(merged.showCPU) network \(merged.showNetwork)"
        )
        record(
            "settings-roundtrip",
            MonitorSettings.load().normalized() == MonitorSettings.load(),
            "load normalizes"
        )

        // MARK: 真实采样

        let sampler = MonitorSampler()
        let first = sampler.totals()
        record(
            "memory-total",
            first.memoryTotal > 0 && first.coreCount > 0,
            "total \(MonitorFormat.bytes(first.memoryTotal)) cores \(first.coreCount)"
        )
        Thread.sleep(forTimeInterval: 0.4)
        let second = sampler.totals()
        record(
            "cpu-percent-range",
            second.cpuPercent >= 0 && second.cpuPercent <= 100,
            String(format: "%.1f%%", second.cpuPercent)
        )
        record(
            "memory-used-range",
            second.memoryUsed > 0 && second.memoryUsed <= second.memoryTotal,
            "used \(MonitorFormat.bytes(second.memoryUsed)) / \(MonitorFormat.bytes(second.memoryTotal))"
        )
        record(
            "network-rates",
            second.upPerSecond >= 0 && second.downPerSecond >= 0,
            "↓\(MonitorFormat.rate(second.downPerSecond)) ↑\(MonitorFormat.rate(second.upPerSecond))"
        )

        let processRows = sampler.processRows(metric: .cpu, limit: 8)
        record(
            "process-rows-nonempty",
            !processRows.isEmpty,
            "\(processRows.count) rows, top \(processRows.first?.name ?? "nil")"
        )
        let descending = zip(processRows, processRows.dropFirst()).allSatisfy {
            $0.load(for: .cpu) >= $1.load(for: .cpu)
        }
        record("process-rows-sorted", descending, "\(processRows.map { MonitorFormat.percent($0.cpuPercent) })")
        record(
            "process-rows-limit",
            processRows.count <= 8,
            "\(processRows.count) of 8"
        )
        let memoryRows = sampler.processRows(metric: .memory, limit: 5)
        record(
            "process-rows-memory",
            !memoryRows.isEmpty && memoryRows[0].memoryBytes >= memoryRows[memoryRows.count - 1].memoryBytes,
            "top \(memoryRows.first?.name ?? "nil") \(MonitorFormat.bytes(memoryRows.first?.memoryBytes ?? 0))"
        )

        var networkRows: [MonitorRow] = []
        var networkDetail = "nettop unavailable"
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop") {
            networkRows = sampler.networkRows(limit: 5)
            networkDetail = "\(networkRows.count) rows"
                + (networkRows.first.map { " top \($0.name) ↓\(MonitorFormat.rate($0.downPerSecond))" } ?? "")
        }
        record(
            "network-rows",
            networkRows.isEmpty || networkRows.allSatisfy { $0.load(for: .network) > 0 },
            networkDetail
        )

        // MARK: App 图标

        // 自测进程自己：跑在 .app 里就有图标（规则②），跑在临时目录的命令行二进制就没有。
        // 这条按「规则」断言，而不是按「在哪跑」断言 —— 打包后的 helper 就在 .app 里面。
        let ownPath = MonitorAppIcon.shared.executablePathForTesting(pid: getpid()) ?? ""
        let ownIcon = MonitorAppIcon.shared.icon(for: getpid())
        let ownExpected = ownPath.contains(".app/Contents/")
        record(
            "app-icon-own-rule",
            (ownIcon != nil) == ownExpected,
            "path \(ownPath) → \(ownIcon == nil ? "no icon" : "icon") (expected \(ownExpected ? "icon" : "no icon"))"
        )
        // launchd 同样没有归属 App。
        let launchdIcon = MonitorAppIcon.shared.icon(for: 1)
        record(
            "app-icon-none-for-daemon",
            launchdIcon == nil,
            launchdIcon == nil ? "no icon for launchd" : "unexpected icon"
        )
        // 「pid → 可执行文件路径 → 所在 .app → 图标」这条兜底链要通：Finder 在 .app 里，必须拿到图标。
        let finderPid = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?
            .processIdentifier
        let finderBundleIcon = finderPid.flatMap { MonitorAppIcon.shared.bundleIconForTesting(pid: $0) }
        record(
            "app-icon-bundle-fallback",
            finderBundleIcon != nil && (finderBundleIcon?.size.width ?? 0) > 0,
            finderBundleIcon.map { "icon \(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil (finder pid \(finderPid.map(String.init) ?? "?"))"
        )
        // 反过来：不在任何 .app 里的可执行文件（launchd 在 /sbin）→ 兜底链必须返回 nil，
        // 否则面板上就是那个「空白方块」。
        let launchdBundleIcon = MonitorAppIcon.shared.bundleIconForTesting(pid: 1)
        record(
            "app-icon-no-bundle-fallback",
            launchdBundleIcon == nil,
            MonitorAppIcon.shared.executablePathForTesting(pid: 1).map { "path \($0)" } ?? "no path"
        )
        // 真 App（有 bundle 的进程，比如 Finder / DSH 自己）必须拿到图标，并且是缓存同一个实例。
        let bundledApp = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier != nil && $0.processIdentifier > 0 && $0.icon != nil
        }
        let appIcon = bundledApp.flatMap { MonitorAppIcon.shared.icon(for: $0.processIdentifier) }
        record(
            "app-icon-bundled",
            appIcon != nil,
            appIcon.map { "\(bundledApp?.localizedName ?? "?") icon \(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"
        )
        record(
            "app-icon-cached",
            bundledApp != nil && MonitorAppIcon.shared.icon(for: bundledApp!.processIdentifier) === appIcon,
            "same instance on second lookup"
        )
        let decorated = processRows.map { row -> MonitorRow in
            var copy = row
            copy.icon = MonitorAppIcon.shared.icon(for: row.pid)
            return copy
        }
        record(
            "app-icon-rows",
            decorated.contains { $0.icon != nil },
            "\(decorated.filter { $0.icon != nil }.count)/\(decorated.count) rows have icon"
        )

        // MARK: 面板排版

        let layout = MonitorPanelView()
        layout.slotCount = 8
        layout.rows = Array(processRows.prefix(1))
        let heightWithOneRow = layout.contentHeight
        layout.rows = Array(processRows.prefix(8))
        let heightWithEightRows = layout.contentHeight
        record(
            "panel-fixed-height",
            heightWithOneRow == heightWithEightRows && heightWithOneRow > 200,
            "\(heightWithOneRow) vs \(heightWithEightRows)"
        )

        // MARK: 菜单栏渲染图（文档用）

        if let strip = MonitorMenuBar.stripImage(totals: lineTotals, settings: MonitorSettings()) {
            let path = directory.appendingPathComponent("monitor-menubar.png")
            let png = strip.tiffRepresentation
                .flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])
            if let data = png {
                try? data.write(to: path)
                artifacts.append(path.path)
            }
            record(
                "menubar-strip",
                strip.size.width > 60 && strip.size.height > 15,
                "\(Int(strip.size.width))x\(Int(strip.size.height)) at \(path.lastPathComponent)"
            )
        } else {
            record("menubar-strip", false, "no image")
        }

        // MARK: 面板渲染

        let panel = MonitorPanelController()
        if let image = panel.snapshotImage(
            metric: .cpu,
            rows: processRows,
            subtitle: "自测渲染"
        ) {
            let path = directory.appendingPathComponent("monitor-panel.png")
            if let data = image.representation(using: .png, properties: [:]) {
                try? data.write(to: path)
                artifacts.append(path.path)
                record(
                    "panel-snapshot",
                    image.pixelsWide > 300 && image.pixelsHigh > 100 && FileManager.default.fileExists(atPath: path.path),
                    "\(image.pixelsWide)x\(image.pixelsHigh) at \(path.lastPathComponent)"
                )
            } else {
                record("panel-snapshot", false, "png encode failed")
            }
        } else {
            record("panel-snapshot", false, "no bitmap")
        }

        // MARK: 控制命令载荷

        let feature = MonitorFeature(context: FeatureContext(
            slug: MonitorFeature.slug,
            socketPath: directory.appendingPathComponent("control.sock").path,
            supportDirectory: directory,
            hotKeys: HotKeyCenter(),
            parentPID: getpid(),
            generation: "selftest",
            dryRun: true,
            activateOnLaunch: false,
            launchHotkey: nil,
            launchSaveDirectory: nil,
            hostSocket: nil,
            launchSettings: [:]
        ))
        let status = feature.status()
        record(
            "feature-status",
            status["topCount"] != nil && status["totals"] != nil,
            "keys \(status.keys.sorted())"
        )
        if let totalsReply = feature.handle("totals", [:]) {
            record("command-totals", totalsReply["ok"] as? Bool == true, "ok")
        } else {
            record("command-totals", false, "no reply")
        }
        if let rowsReply = feature.handle("rows", ["metric": "memory", "limit": 3]),
           let payload = rowsReply["rows"] as? [[String: Any]] {
            record(
                "command-rows",
                rowsReply["ok"] as? Bool == true && payload.count <= 3,
                "\(payload.count) rows"
            )
        } else {
            record("command-rows", false, "no reply")
        }
        record(
            "command-unknown",
            feature.handle("nonsense", [:]) == nil,
            "returns nil so NativeHost can answer"
        )

        return finish()
    }

    // MARK: - 记录

    private static func record(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(["check": name, "passed": passed, "detail": detail])
        Log.info("\(passed ? "PASS" : "FAIL") \(name) — \(detail)")
    }

    private static func finish() -> Int32 {
        let failed = checks.filter { ($0["passed"] as? Bool) != true }
        let payload: [String: Any] = [
            "event": "self-test",
            "passed": failed.isEmpty,
            "failures": failed.count,
            "checks": checks,
            "artifacts": artifacts,
        ]
        printJSON(payload)
        return failed.isEmpty ? 0 : 1
    }
}
