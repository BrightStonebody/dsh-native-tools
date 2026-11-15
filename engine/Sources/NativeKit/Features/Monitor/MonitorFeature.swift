import AppKit
import Foundation

/// 系统监控 feature：状态栏三个独立图标（网络上下行 / CPU / 内存），
/// 点哪个就弹出哪个指标的进程排名。
final class MonitorFeature: NSObject, NativeFeature {
    static let slug = "monitor"
    static let displayName = "系统监控"
    static let supportDirectoryName = MonitorSettings.supportDirectoryName
    static let socketEnvironmentKey = MonitorSettings.socketEnvironmentKey

    private let context: FeatureContext
    private var settings: MonitorSettings
    /// 主线程采样器（总量 + 进程 CPU/内存）。
    private let sampler = MonitorSampler()
    /// 网络排名单独一个采集器，只在后台队列上用，避免和主线程抢差分状态。
    private let networkSampler = MonitorSampler()
    private let panel = MonitorPanelController()
    private var menuBar: MonitorMenuBar?
    private var timer: Timer?
    private var totals = MonitorTotals()
    private var networkRefreshInFlight = false

    init(context: FeatureContext) {
        self.context = context
        var settings = MonitorSettings.load()
        settings = settings.merging(context.launchSettings)
        self.settings = settings
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        let bar = MonitorMenuBar(settings: settings)
        bar.onSelect = { [weak self] metric, button in
            self?.togglePanel(metric: metric, button: button)
        }
        menuBar = bar
        panel.setSlotCount(settings.topCount)
        scheduleTimer()
        tick()
        Log.info("ready refresh=\(settings.refreshSeconds)s top=\(settings.topCount) "
            + "show=\(enabledMetrics().map(\.rawValue).joined(separator: ","))")
        printJSON([
            "event": "ready",
            "feature": MonitorFeature.slug,
            "refreshSeconds": settings.refreshSeconds,
            "topCount": settings.topCount,
            "metrics": enabledMetrics().map(\.rawValue),
        ])
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel.hide()
        menuBar?.removeAll()
        menuBar = nil
    }

    func status() -> [String: Any] {
        var payload: [String: Any] = settings.summary
        payload["totals"] = totalsPayload(totals)
        payload["visible"] = panel.isVisible
        payload["visibleMetric"] = panel.visibleMetric?.rawValue ?? ""
        payload["metrics"] = enabledMetrics().map(\.rawValue)
        payload["itemFrames"] = menuBar?.frames() ?? [:]
        payload["itemLines"] = menuBar?.lines() ?? [:]
        payload["panelFrame"] = panel.frame()
        payload["itemMetrics"] = menuBar?.metrics() ?? [:]
        return payload
    }

    private func enabledMetrics() -> [MonitorMetric] {
        MonitorMetric.allCases.filter { metric in
            switch metric {
            case .network: return settings.showNetwork
            case .cpu: return settings.showCPU
            case .memory: return settings.showMemory
            }
        }
    }

    // MARK: - 采样循环

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = Double(settings.refreshSeconds)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common：面板/菜单打开时（tracking loop）也继续刷新。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        totals = sampler.totals()
        menuBar?.update(totals: totals)
        guard panel.isVisible, let metric = panel.visibleMetric else { return }
        refreshPanel(metric: metric)
    }

    /// 给每行补上「所属 App 的图标」。只在主线程做（NSRunningApplication 与
    /// NSWorkspace 的图标读取都会碰 AppKit 缓存），采样本身仍然可以在后台。
    private func decorated(_ rows: [MonitorRow]) -> [MonitorRow] {
        guard !rows.isEmpty else { return rows }
        var result = rows
        for index in result.indices {
            result[index].icon = MonitorAppIcon.shared.icon(for: result[index].pid)
        }
        return result
    }

    private func refreshPanel(metric: MonitorMetric) {
        switch metric {
        case .cpu, .memory:
            let rows = sampler.processRows(metric: metric, limit: settings.topCount)
            panel.apply(rows: decorated(rows), subtitle: subtitle(for: metric))
        case .network:
            guard !networkRefreshInFlight else { return }
            networkRefreshInFlight = true
            let limit = settings.topCount
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let rows = self.networkSampler.resolveNames(self.networkSampler.networkRows(limit: limit))
                DispatchQueue.main.async {
                    self.networkRefreshInFlight = false
                    guard self.panel.isVisible, self.panel.visibleMetric == .network else { return }
                    self.panel.apply(rows: self.decorated(rows), subtitle: self.subtitle(for: .network))
                }
            }
        }
    }

    private func subtitle(for metric: MonitorMetric) -> String {
        switch metric {
        case .network:
            return "合计 ↓\(MonitorFormat.rate(totals.downPerSecond))  ↑\(MonitorFormat.rate(totals.upPerSecond))"
        case .cpu:
            return "\(totals.coreCount) 核 · 当前 \(MonitorFormat.percent(totals.cpuPercent))"
        case .memory:
            return "已用 \(MonitorFormat.bytes(totals.memoryUsed)) / \(MonitorFormat.bytes(totals.memoryTotal))"
                + " · \(MonitorFormat.percent(totals.memoryPercent))"
        }
    }

    // MARK: - 面板

    private func togglePanel(metric: MonitorMetric, button: NSStatusBarButton) {
        if panel.isVisible, panel.visibleMetric == metric {
            panel.hide()
            return
        }
        let rows: [MonitorRow]
        switch metric {
        case .cpu, .memory:
            rows = sampler.processRows(metric: metric, limit: settings.topCount)
        case .network:
            rows = []
        }
        panel.show(metric: metric, from: button, rows: decorated(rows), subtitle: subtitle(for: metric))
        if metric == .network {
            refreshPanel(metric: .network)
        }
    }

    // MARK: - 设置

    func applySettings(_ request: [String: Any]) -> [String: Any] {
        settings = settings.merging(request)
        settings.save()
        menuBar?.apply(settings: settings)
        panel.setSlotCount(settings.topCount)
        scheduleTimer()
        tick()
        var reply = status()
        reply["ok"] = true
        return reply
    }

    // MARK: - 控制命令

    func handle(_ command: String, _ request: [String: Any]) -> [String: Any]? {
        switch command {
        case "configure":
            settings = settings.merging(request)
            settings.save()
            menuBar?.apply(settings: settings)
            panel.setSlotCount(settings.topCount)
            scheduleTimer()
            tick()
            var reply = status()
            reply["ok"] = true
            return reply
        case "totals":
            totals = sampler.totals()
            return ["ok": true, "totals": totalsPayload(totals)]
        case "rows":
            let metric = MonitorMetric(rawValue: request["metric"] as? String ?? "") ?? .cpu
            let limit = JSONValue.int(request["limit"]) ?? settings.topCount
            let rows: [MonitorRow]
            if metric == .network {
                rows = networkSampler.resolveNames(networkSampler.networkRows(limit: limit))
            } else {
                rows = sampler.processRows(metric: metric, limit: limit)
            }
            return [
                "ok": true,
                "metric": metric.rawValue,
                "rows": rowsPayload(rows, metric: metric),
                "icons": decorated(rows).map { $0.icon != nil },
            ]
        case "show":
            let metric = MonitorMetric(rawValue: request["metric"] as? String ?? "") ?? .cpu
            guard let button = menuBar?.button(for: metric) else {
                return ["ok": false, "error": "feature is not running"]
            }
            togglePanel(metric: metric, button: button)
            return status()
        case "hide":
            panel.hide()
            return status()
        case "snapshot":
            let path = request["path"] as? String ?? ""
            guard !path.isEmpty else { return ["ok": false, "error": "missing path"] }
            let metric = MonitorMetric(rawValue: request["metric"] as? String ?? "") ?? .cpu
            let rows = metric == .network
                ? networkSampler.resolveNames(networkSampler.networkRows(limit: settings.topCount))
                : sampler.processRows(metric: metric, limit: settings.topCount)
            guard let image = panel.snapshotImage(
                metric: metric,
                rows: decorated(rows),
                subtitle: subtitle(for: metric)
            ) else {
                return ["ok": false, "error": "snapshot failed"]
            }
            guard let data = image.representation(using: .png, properties: [:]) else {
                return ["ok": false, "error": "png encode failed"]
            }
            do {
                try data.write(to: URL(fileURLWithPath: path))
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
            return ["ok": true, "files": [path]]
        default:
            return nil
        }
    }

    // MARK: - 序列化

    private func totalsPayload(_ totals: MonitorTotals) -> [String: Any] {
        [
            "downPerSecond": totals.downPerSecond,
            "upPerSecond": totals.upPerSecond,
            "cpuPercent": totals.cpuPercent,
            "memoryUsed": Int(totals.memoryUsed),
            "memoryTotal": Int(totals.memoryTotal),
            "memoryPercent": totals.memoryPercent,
            "coreCount": totals.coreCount,
        ]
    }

    private func rowsPayload(_ rows: [MonitorRow], metric: MonitorMetric) -> [[String: Any]] {
        rows.map { row in
            [
                "pid": Int(row.pid),
                "name": row.name,
                "cpuPercent": row.cpuPercent,
                "memoryBytes": Int(row.memoryBytes),
                "downPerSecond": row.downPerSecond,
                "upPerSecond": row.upPerSecond,
                "load": row.load(for: metric),
            ]
        }
    }

    static func runSelfTest() -> Int32 {
        MonitorSelfTest.run()
    }
}
