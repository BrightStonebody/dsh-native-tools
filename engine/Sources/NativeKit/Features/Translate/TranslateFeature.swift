import AppKit
import Foundation

/// 翻译 feature：一个浮动输入框，把文本送给 Host 侧的翻译服务。
///
/// 原来独立 helper 里的生命周期（单实例锁、看门狗、控制通道）由 `NativeHost`
/// 负责；这里只剩窗口、快捷键和翻译链路。
final class TranslateFeature: NSObject, NativeFeature {
    static let slug = "translate"
    static let displayName = "翻译"
    static let supportDirectoryName = "DSHTranslate"
    static let socketEnvironmentKey = "DSHS_TRANSLATE_SOCKET"

    private static let channel = "translate.toggle"

    private let context: FeatureContext
    private var settings: TranslateSettings
    private let panel = TranslatePanelController()
    private var hotKeyLabel = ""
    private var hotKeyError: String?

    init(context: FeatureContext) {
        self.context = context
        var settings = TranslateSettings.load()
        if let hotkey = context.launchHotkey, !hotkey.isEmpty {
            settings.hotkey = hotkey
        }
        if let hostSocket = context.hostSocket, !hostSocket.isEmpty {
            settings.hostSocket = hostSocket
        }
        self.settings = settings
        super.init()
        panel.updateHotkeyLabel(hotKeyLabel)
        panel.updateHostSocket(settings.hostSocket)
    }

    // MARK: - Lifecycle

    func start() {
        installMainMenu()
        applyHotKey()
        panel.updateHostSocket(settings.hostSocket)
        Log.info("ready hotkey=\(settings.hotkey) label=\(hotKeyLabel) hostSocket=\(settings.hostSocket)")
        printJSON([
            "event": "ready",
            "feature": TranslateFeature.slug,
            "hotkey": settings.hotkey,
            "hotkeyLabel": hotKeyLabel,
            "hotkeyError": hotKeyError ?? "",
            "hostSocket": settings.hostSocket,
        ])
    }

    func stop() {
        context.hotKeys.unregister(channel: TranslateFeature.channel)
        panel.dismiss(restorePrevious: false)
    }

    func status() -> [String: Any] {
        [
            "hotkey": settings.hotkey,
            "hotkeyLabel": hotKeyLabel,
            "hotKeyError": hotKeyError ?? "",
            "hostSocket": settings.hostSocket,
            "visible": panel.isVisible,
        ]
    }

    // MARK: - 菜单

    /// LSUIElement 应用没有菜单栏，但 ⌘C/⌘V/⌘A 这类键位是主菜单里的 key equivalent
    /// 沿 responder chain 找 target 才生效的；一条菜单都不装，文本框里按 ⌘V 就毫无反应。
    /// 菜单本身不会显示（激活策略是 accessory），只为了拿到这些标准动作。
    private func installMainMenu() {
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - 快捷键

    private func applyHotKey() {
        context.hotKeys.unregister(channel: TranslateFeature.channel)
        hotKeyLabel = KeySpecParser.label(settings.hotkey)
        guard let spec = KeySpecParser.parse(settings.hotkey) else {
            hotKeyError = "无法识别的快捷键写法：\(settings.hotkey)"
            return
        }
        hotKeyError = context.hotKeys.register(spec, channel: TranslateFeature.channel, onFire: { [weak self] in
            self?.togglePanel(force: false)
        })
        if let hotKeyError {
            Log.error("register \(settings.hotkey) failed: \(hotKeyError)")
        }
        panel.updateHotkeyLabel(hotKeyLabel)
    }

    private func togglePanel(force: Bool) {
        if force, panel.isVisible {
            panel.dismiss(restorePrevious: false)
        }
        if !force, panel.isVisible {
            panel.dismiss(restorePrevious: true)
            return
        }
        panel.updateHotkeyLabel(hotKeyLabel)
        panel.present(hostSocket: settings.hostSocket, hotkeyLabel: hotKeyLabel)
    }

    // MARK: - 设置

    func applySettings(_ request: [String: Any]) -> [String: Any] {
        if let hotkey = request["hotkey"] as? String, !hotkey.isEmpty {
            settings.hotkey = hotkey
        }
        if let hostSocket = request["hostSocket"] as? String, !hostSocket.isEmpty {
            settings.hostSocket = hostSocket
            panel.updateHostSocket(hostSocket)
        }
        applyHotKey()
        settings.save()
        if panel.isVisible {
            panel.updateHotkeyLabel(hotKeyLabel)
            panel.dismiss(restorePrevious: false)
        }
        var reply = status()
        reply["ok"] = hotKeyError == nil
        reply["label"] = hotKeyLabel
        if let hotKeyError { reply["error"] = hotKeyError }
        return reply
    }

    // MARK: - 控制命令

    func handle(_ command: String, _ request: [String: Any]) -> [String: Any]? {
        switch command {
        case "configure":
            if let hotkey = request["hotkey"] as? String, !hotkey.isEmpty {
                settings.hotkey = hotkey
            }
            if let hostSocket = request["hostSocket"] as? String, !hostSocket.isEmpty {
                settings.hostSocket = hostSocket
                panel.updateHostSocket(hostSocket)
            }
            applyHotKey()
            settings.save()
            if panel.isVisible {
                panel.updateHotkeyLabel(hotKeyLabel)
                panel.dismiss(restorePrevious: false)
            }
            var reply = status()
            reply["ok"] = hotKeyError == nil
            if let hotKeyError { reply["error"] = hotKeyError }
            return reply
        case "show":
            togglePanel(force: true)
            return status()
        case "translate":
            // 调试/自测入口：直接灌一段文本走完整链路（弹窗 → 翻译 → 显示）。
            let text = (request["text"] as? String) ?? ""
            panel.updateHotkeyLabel(hotKeyLabel)
            panel.updateHostSocket(settings.hostSocket)
            panel.fillAndSubmit(text: text)
            return status()
        case "hide":
            panel.dismiss(restorePrevious: false)
            return status()
        case "snapshot":
            // 自测/文档用：把浮窗渲染成 PNG，不用真的弹在用户面前。
            let path = request["path"] as? String ?? ""
            guard !path.isEmpty else { return ["ok": false, "error": "missing path"] }
            let wasVisible = panel.isVisible
            if !wasVisible {
                panel.updateHotkeyLabel(hotKeyLabel)
                panel.updateHostSocket(settings.hostSocket)
                panel.present(hostSocket: settings.hostSocket, hotkeyLabel: hotKeyLabel)
            }
            let files = panel.snapshot(to: path)
            if !wasVisible { panel.dismiss(restorePrevious: false) }
            return ["ok": !files.isEmpty, "files": files]
        default:
            return nil
        }
    }

    static func runSelfTest() -> Int32 {
        TranslateSelfTest.run()
    }
}
