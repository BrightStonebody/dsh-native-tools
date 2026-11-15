import AppKit

/// 状态栏上的三个独立图标：网络（上下行）、CPU、内存。各自点击弹自己的面板。
final class MonitorMenuBar: NSObject {
    private struct Entry {
        var metric: MonitorMetric
        var item: NSStatusItem
    }

    private var entries: [Entry] = []
    private var settings: MonitorSettings
    var onSelect: ((MonitorMetric, NSStatusBarButton) -> Void)?

    init(settings: MonitorSettings) {
        self.settings = settings
        super.init()
        build()
    }

    deinit {
        removeAll()
    }

    func removeAll() {
        for entry in entries {
            NSStatusBar.system.removeStatusItem(entry.item)
        }
        entries = []
    }

    private func build() {
        removeAll()
        for metric in MonitorMetric.allCases {
            // variableLength：按钮按「图标 + 标题」自己量宽，固定长度会把长标题折成两行。
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                // 小一号的符号：菜单栏寸土寸金，三个图标都想露出来。
                let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                button.image = NSImage(
                    systemSymbolName: metric.symbolName,
                    accessibilityDescription: metric.title
                )?.withSymbolConfiguration(configuration)
                button.imagePosition = .imageLeading
                // 菜单栏空间紧张：10 号等宽数字比 11 号窄一截，三个图标更容易全露出来。
                button.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                button.target = self
                button.action = #selector(handleClick(_:))
                button.toolTip = "DSH 原生助手 · \(metric.title)"
            }
            item.isVisible = isEnabled(metric)
            entries.append(Entry(metric: metric, item: item))
        }
    }

    private func isEnabled(_ metric: MonitorMetric) -> Bool {
        switch metric {
        case .network: return settings.showNetwork
        case .cpu: return settings.showCPU
        case .memory: return settings.showMemory
        }
    }

    func apply(settings next: MonitorSettings) {
        let rebuild = settings.networkDetailed != next.networkDetailed
        settings = next
        if rebuild {
            build()
            return
        }
        for entry in entries {
            entry.item.isVisible = isEnabled(entry.metric)
        }
    }

    func update(totals: MonitorTotals) {
        setTitle(
            MonitorFormat.menuNetworkTitle(
                down: totals.downPerSecond,
                up: totals.upPerSecond,
                detailed: settings.networkDetailed
            ),
            for: .network
        )
        setTitle(MonitorFormat.cpuTitle(totals.cpuPercent), for: .cpu)
        setTitle(MonitorFormat.memoryTitle(totals), for: .memory)
    }

    private func setTitle(_ text: String, for metric: MonitorMetric) {
        guard let entry = entries.first(where: { $0.metric == metric }) else { return }
        entry.item.button?.title = " " + text
    }

    /// 每个图标的屏幕位置（自测用来确认「三个都在屏幕内、且没被标题撑成两行」）。
    func frames() -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for entry in entries {
            guard let window = entry.item.button?.window else { continue }
            let frame = window.frame
            result[entry.metric.rawValue] = [
                "x": Double(frame.origin.x),
                "y": Double(frame.origin.y),
                "width": Double(frame.size.width),
                "height": Double(frame.size.height),
                "visible": entry.item.isVisible ? 1 : 0,
            ]
        }
        return result
    }

    func button(for metric: MonitorMetric) -> NSStatusBarButton? {
        entries.first { $0.metric == metric }?.item.button
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let metric = entries.first(where: { $0.item.button === sender })?.metric else { return }
        onSelect?(metric, sender)
    }
}
