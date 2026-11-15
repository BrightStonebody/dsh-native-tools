import Foundation

/// Persistent helper settings.
///
/// The DSH Host plugin passes the authoritative values on the command line and
/// through the control channel. This file is the offline fallback so the helper
/// still behaves sensibly when started by hand (`--status`, debugging).
struct ClipboardSettings: Codable {
    var hotkey: String = ClipboardSettings.defaultHotkey
    var maxItems: Int = 200
    var retentionDays: Int = 30

    static let defaultHotkey = "cmd+shift+v"
    static let appSupportDirectoryName = "DSHClipboard"
    static let maxItemsRange = 20...2_000
    static let retentionDaysRange = 0...3_650

    /// `DSHS_CLIPBOARD_HOME` redirects every file the helper owns; the self test
    /// uses it so a test run never touches the real history.
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DSHS_CLIPBOARD_HOME"],
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

    static var historyURL: URL {
        supportDirectory.appendingPathComponent("history.json", isDirectory: false)
    }

    static var imagesDirectory: URL {
        supportDirectory.appendingPathComponent("images", isDirectory: true)
    }

    /// `DSHS_CLIPBOARD_SOCKET` lets the self test (and manual runs) use a
    /// throwaway socket while the real helper is running.
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["DSHS_CLIPBOARD_SOCKET"],
           !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("control.sock", isDirectory: false).path
    }

    static func clamp(maxItems: Int) -> Int {
        min(max(maxItems, maxItemsRange.lowerBound), maxItemsRange.upperBound)
    }

    static func clamp(retentionDays: Int) -> Int {
        min(max(retentionDays, retentionDaysRange.lowerBound), retentionDaysRange.upperBound)
    }

    static func load() -> ClipboardSettings {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(ClipboardSettings.self, from: data)
        else {
            return ClipboardSettings()
        }
        var settings = decoded
        if settings.hotkey.isEmpty {
            settings.hotkey = defaultHotkey
        }
        settings.maxItems = clamp(maxItems: settings.maxItems)
        settings.retentionDays = clamp(retentionDays: settings.retentionDays)
        return settings
    }

    func save() {
        let url = ClipboardSettings.configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error("cannot write settings: \(error.localizedDescription)")
        }
    }
}
