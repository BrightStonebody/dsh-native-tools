import Foundation

/// 截图 feature 的持久化设置（沿用原来的 config.json，迁移时零改动）。
///
/// The plugin may pass `--config <path>`; otherwise the helper keeps its settings in
/// `~/Library/Application Support/DSHScreenshot/config.json`.
struct ScreenshotSettings: Codable {
    var hotkey: String = ScreenshotSettings.defaultHotkey
    var saveDirectory: String = ""
    /// `auto` / `zh` / `en` — handed to Vision as a language hint.
    var ocrLanguages: String = "auto"
    /// Keep the on-screen line breaks, or flow the text into paragraphs.
    var ocrKeepLineBreaks: Bool = true

    /// Older config files predate the OCR keys, so every field is optional on
    /// the way in and falls back to its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey) ?? ScreenshotSettings.defaultHotkey
        saveDirectory = try container.decodeIfPresent(String.self, forKey: .saveDirectory) ?? ""
        ocrLanguages = try container.decodeIfPresent(String.self, forKey: .ocrLanguages) ?? "auto"
        ocrKeepLineBreaks = try container.decodeIfPresent(Bool.self, forKey: .ocrKeepLineBreaks) ?? true
    }

    init(
        hotkey: String = ScreenshotSettings.defaultHotkey,
        saveDirectory: String = "",
        ocrLanguages: String = "auto",
        ocrKeepLineBreaks: Bool = true
    ) {
        self.hotkey = hotkey
        self.saveDirectory = saveDirectory
        self.ocrLanguages = ocrLanguages
        self.ocrKeepLineBreaks = ocrKeepLineBreaks
    }

    static let defaultHotkey = "cmd+shift+a"
    static let appSupportDirectoryName = "DSHScreenshot"

    static var configURL: URL = {
        // 测试用的逃生门：调试实例别去改用户真正在用的那份配置
        // （否则 `--no-adopt` 跑一遍就把人家的快捷键写回出厂值）。
        if let override = ProcessInfo.processInfo.environment["DSHS_SCREENSHOT_CONFIG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("config.json", isDirectory: false)
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
        return base.appendingPathComponent("config.json", isDirectory: false)
    }()

    /// 上次跑起来用过的快捷键（写在自己的 config.json 里）。
    ///
    /// 它比启动参数 `--hotkey` 更权威：插件进程可能把「加载那一刻」的配置缓存住，
    /// 重启 helper 时又把旧值当参数传进来；用户自己攒下的选择不该被这种回放覆盖。
    /// 想改快捷键就走控制通道（插件页 / `hotkey` 命令），那条路是实时的。
    static var storedHotkey: String? {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(ScreenshotSettings.self, from: data),
              !decoded.hotkey.isEmpty
        else {
            return nil
        }
        return decoded.hotkey
    }

    static func load() -> ScreenshotSettings {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(ScreenshotSettings.self, from: data)
        else {
            return ScreenshotSettings(saveDirectory: defaultSaveDirectory())
        }
        var settings = decoded
        if settings.saveDirectory.isEmpty {
            settings.saveDirectory = defaultSaveDirectory()
        }
        if settings.hotkey.isEmpty {
            settings.hotkey = defaultHotkey
        }
        return settings
    }

    func save() {
        let url = ScreenshotSettings.configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            Log.error("cannot write settings: \(error.localizedDescription)")
        }
    }

    /// `~/Desktop` when it exists, else the home directory.
    static func defaultSaveDirectory() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: desktop.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return desktop.path
        }
        return home.path
    }
}
