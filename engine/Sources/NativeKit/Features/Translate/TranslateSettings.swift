import AppKit
import Foundation

/// helper 自己的一份设置。
///
/// DSH 的 Host 半边会把权威值放在命令行和 control 通道里传进来；这个文件只是
/// 离线兜底，让 helper 手动启动（`--status`、调试）时也有像样的默认值。
struct TranslateSettings: Codable {
    var hotkey: String = TranslateSettings.defaultHotkey
    /// Host 那一侧的翻译套接字：helper 把待翻译文本送过去。
    var hostSocket: String = ""

    static let defaultHotkey = "cmd+shift+t"
    static let appSupportDirectoryName = "DSHTranslate"

    /// `DSHS_TRANSLATE_HOME` 重定向 helper 拥有的所有文件，自测用。
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DSHS_TRANSLATE_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    /// helper 监听的控制套接字：Host 用它下发 adopt / configure / release。
    static var defaultControlSocket: String {
        supportDirectory.appendingPathComponent("control.sock", isDirectory: false).path
    }

    /// Host 监听的翻译套接字。
    static var defaultHostSocket: String {
        supportDirectory.appendingPathComponent("host.sock", isDirectory: false).path
    }

    static func load() -> TranslateSettings {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(TranslateSettings.self, from: data)
        else {
            return TranslateSettings()
        }
        return decoded
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: TranslateSettings.supportDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: TranslateSettings.configURL, options: .atomic)
        } catch {
            Log.error("cannot write settings: \(error.localizedDescription)")
        }
    }
}
