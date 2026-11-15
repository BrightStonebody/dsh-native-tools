import Foundation

/// 系统监控的持久化设置。用属性列表 + Codable 落盘到自己的支持目录，
/// 与另外三个 feature 一样支持用环境变量把目录整体搬走（自测用）。
struct MonitorSettings: Codable, Equatable {
    /// 采样间隔，秒。菜单栏文本与面板都按它刷新。
    var refreshSeconds: Int = 2
    /// 面板里显示的进程条数。
    var topCount: Int = 8
    /// 三个菜单栏图标各自是否显示。
    var showNetwork: Bool = true
    var showCPU: Bool = true
    var showMemory: Bool = true
    /// 网络图标是否把上行也写出来（`↓1.2M ↑300K` 对比只写 `↓1.2M`）。
    var networkDetailed: Bool = true

    static let supportDirectoryName = "DSHMonitor"
    static let homeEnvironmentKey = "DSHS_MONITOR_HOME"
    static let socketEnvironmentKey = "DSHS_MONITOR_SOCKET"

    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment[homeEnvironmentKey],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    static var configURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    static var defaultControlSocket: String {
        if let override = ProcessInfo.processInfo.environment[socketEnvironmentKey],
           !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("control.sock").path
    }

    /// 把越界值夹回可用范围，避免坏配置把定时器打到 0 或负值。
    func normalized() -> MonitorSettings {
        var copy = self
        copy.refreshSeconds = min(max(refreshSeconds, 1), 60)
        copy.topCount = min(max(topCount, 3), 30)
        return copy
    }

    static func load() -> MonitorSettings {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(MonitorSettings.self, from: data)
        else {
            return MonitorSettings()
        }
        return decoded.normalized()
    }

    func save() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(normalized()) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }

    /// 用控制通道传来的字段做增量更新（只认已知键，未知键忽略）。
    func merging(_ request: [String: Any]) -> MonitorSettings {
        var copy = self
        if let value = JSONValue.int(request["refreshSeconds"]) { copy.refreshSeconds = value }
        if let value = JSONValue.int(request["topCount"]) { copy.topCount = value }
        if let value = JSONValue.bool(request["showNetwork"]) { copy.showNetwork = value }
        if let value = JSONValue.bool(request["showCPU"]) { copy.showCPU = value }
        if let value = JSONValue.bool(request["showMemory"]) { copy.showMemory = value }
        if let value = JSONValue.bool(request["networkDetailed"]) { copy.networkDetailed = value }
        return copy.normalized()
    }

    var summary: [String: Any] {
        [
            "refreshSeconds": refreshSeconds,
            "topCount": topCount,
            "showNetwork": showNetwork,
            "showCPU": showCPU,
            "showMemory": showMemory,
            "networkDetailed": networkDetailed,
        ]
    }
}
