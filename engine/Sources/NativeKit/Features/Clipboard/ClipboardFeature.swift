import AppKit
import Foundation

/// 剪贴板历史 feature：常驻的剪贴板监视器 + 浮动面板。
///
/// 原来独立 helper 里的 `AppController` 去掉进程级职责后就是这里：看门狗、控制通道
/// 和快捷键注册在 `NativeHost` / `HotKeyCenter`，剩下的都归这个 feature。
final class ClipboardFeature: NSObject, NativeFeature {
    static let slug = "clipboard"
    static let displayName = "剪贴板"
    static let supportDirectoryName = "DSHClipboard"
    static let socketEnvironmentKey = "DSHS_CLIPBOARD_SOCKET"

    private static let channel = "clipboard.toggle"

    private let context: FeatureContext
    private var settings: ClipboardSettings
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private let panel: ClipboardPanelController
    private var hotKeyLabel = ""
    private var hotKeyError: String?
    /// The combination currently registered with Carbon; kept so a failed change
    /// can restore it instead of leaving the panel with no way to open.
    private var activeSpec: KeySpec?

    init(context: FeatureContext) {
        self.context = context
        var settings = ClipboardSettings.load()
        if let hotkey = context.launchHotkey, !hotkey.isEmpty {
            settings.hotkey = hotkey
        }
        if let maxItems = JSONValue.int(context.launchSettings["maxItems"]) {
            settings.maxItems = ClipboardSettings.clamp(maxItems: maxItems)
        }
        if let retentionDays = JSONValue.int(context.launchSettings["retentionDays"]) {
            settings.retentionDays = ClipboardSettings.clamp(retentionDays: retentionDays)
        }
        self.settings = settings

        let store = ClipboardStore(directory: ClipboardSettings.supportDirectory)
        self.store = store
        self.panel = ClipboardPanelController(store: store)
        self.monitor = ClipboardMonitor()
        super.init()

        store.setLimits(maxItems: settings.maxItems, retentionDays: settings.retentionDays)
        store.prune()
        panel.onChoose = { [weak self] item, paste in
            self?.deliver(item, paste: paste, previousApp: self?.panel.previousApp)
        }
        monitor.onCapture = { [weak self] captured in
            self?.capture(captured)
        }
    }

    // MARK: - Lifecycle

    func start() {
        applyHotKey()
        monitor.ignoreCurrentChange()
        monitor.start()
        Log.info(
            "ready items=\(store.items.count) hotkey=\(settings.hotkey) "
                + "max=\(settings.maxItems) retention=\(settings.retentionDays) "
                + "accessibility=\(PasteService.isAccessibilityTrusted)"
        )
        printJSON([
            "event": "ready",
            "feature": ClipboardFeature.slug,
            "hotkey": settings.hotkey,
            "hotkeyLabel": hotKeyLabel,
            "maxItems": settings.maxItems,
            "retentionDays": settings.retentionDays,
            "items": store.items.count,
            "accessibility": PasteService.isAccessibilityTrusted,
        ])
    }

    func stop() {
        monitor.stop()
        context.hotKeys.unregister(channel: ClipboardFeature.channel)
        panel.hide()
    }

    func status() -> [String: Any] {
        [
            "hotkey": settings.hotkey,
            "hotkeyLabel": hotKeyLabel,
            "maxItems": settings.maxItems,
            "retentionDays": settings.retentionDays,
            "items": store.items.count,
            "visible": panel.isVisible,
            "accessibility": PasteService.isAccessibilityTrusted,
            "dataDirectory": ClipboardSettings.supportDirectory.path,
        ]
    }

    // MARK: - Settings

    func applySettings(_ request: [String: Any]) -> [String: Any] {
        let changed = configure(request)["changed"] as? Bool ?? false
        var payload = status()
        payload["ok"] = hotKeyError == nil
        payload["label"] = hotKeyLabel
        payload["changed"] = changed
        if let hotKeyError {
            payload["error"] = hotKeyError
        }
        return payload
    }

    /// 设置热键 / 保留条数 / 保留天数；返回 `changed` 供 `configure` 与 adopt 复用。
    @discardableResult
    private func configure(_ request: [String: Any]) -> [String: Any] {
        var changed = false
        if let hotkey = request["hotkey"] as? String, !hotkey.isEmpty, hotkey != settings.hotkey {
            let previous = settings.hotkey
            settings.hotkey = hotkey
            if applyHotKey() {
                changed = true
            } else {
                settings.hotkey = previous
            }
        }
        if let maxItems = JSONValue.int(request["maxItems"]) {
            let clamped = ClipboardSettings.clamp(maxItems: maxItems)
            if clamped != settings.maxItems {
                settings.maxItems = clamped
                changed = true
            }
        }
        if let retentionDays = JSONValue.int(request["retentionDays"]) {
            let clamped = ClipboardSettings.clamp(retentionDays: retentionDays)
            if clamped != settings.retentionDays {
                settings.retentionDays = clamped
                changed = true
            }
        }
        if changed {
            settings.save()
            store.setLimits(maxItems: settings.maxItems, retentionDays: settings.retentionDays)
            store.prune()
            if panel.isVisible { panel.reload() }
        }
        return ["changed": changed]
    }

    // MARK: - Capture

    private func capture(_ captured: CapturedClipboard) {
        switch captured.payload {
        case let .text(text):
            store.addText(text, source: captured.source)
        case let .image(pngData, thumbData, _, _):
            store.addImage(pngData: pngData, thumbData: thumbData, source: captured.source)
        }
        if panel.isVisible {
            panel.reload()
        }
        Log.info("captured \(store.items.count) item(s) total")
    }

    // MARK: - Shortcut and panel

    @discardableResult
    private func applyHotKey() -> Bool {
        let previousSpec = activeSpec
        let previousLabel = hotKeyLabel
        hotKeyError = nil
        guard let spec = KeySpecParser.parse(settings.hotkey) else {
            hotKeyError = "无法解析快捷键 \(settings.hotkey)"
            Log.error(hotKeyError ?? "")
            HUD.show(
                hotKeyError ?? "快捷键不可用",
                symbol: "exclamationmark.triangle.fill",
                success: false,
                duration: 3
            )
            return false
        }
        context.hotKeys.unregister(channel: ClipboardFeature.channel)
        if let failure = context.hotKeys.register(spec, channel: ClipboardFeature.channel, onFire: { [weak self] in
            self?.togglePanel()
        }) {
            hotKeyError = failure
            // 这个 feature 没有菜单栏图标：旧快捷键是用户唯一的入口，注册失败就装回去。
            if let previousSpec {
                _ = context.hotKeys.register(previousSpec, channel: ClipboardFeature.channel, onFire: { [weak self] in
                    self?.togglePanel()
                })
                hotKeyLabel = previousLabel
                panel.updateHotkeyLabel(previousLabel)
            } else {
                // 第一次注册就失败（组合被别的 App 占了）：面板会彻底打不开，
                // 于是退到几个常见的默认组合上。
                for raw in ["cmd+shift+v", "ctrl+opt+v", "ctrl+opt+shift+v", "f8"] {
                    guard let fallback = KeySpecParser.parse(raw),
                          fallback.keyCode != spec.keyCode,
                          context.hotKeys.register(fallback, channel: ClipboardFeature.channel, onFire: { [weak self] in
                              self?.togglePanel()
                          }) == nil
                    else { continue }
                    activeSpec = fallback
                    settings.hotkey = raw
                    hotKeyLabel = fallback.label
                    panel.updateHotkeyLabel(fallback.label)
                    HUD.show(
                        "快捷键被占用，已临时改用 \(fallback.label)",
                        symbol: "exclamationmark.triangle.fill",
                        success: false,
                        duration: 4
                    )
                    Log.error("\(failure); fallback \(fallback.label) registered")
                    return false
                }
            }
            Log.error(failure)
            HUD.show(failure, symbol: "exclamationmark.triangle.fill", success: false, duration: 3)
            return false
        }
        activeSpec = spec
        hotKeyLabel = spec.label
        panel.updateHotkeyLabel(hotKeyLabel)
        Log.info("hotkey \(spec.label) registered")
        return true
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.dismiss(restorePrevious: true)
            return
        }
        showPanel()
    }

    private func showPanel() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let previous = frontmost?.processIdentifier == getpid() ? nil : frontmost
        panel.show(previousApp: previous)
    }

    /// Writes the entry, promotes it, closes the panel, and optionally synthesizes
    /// ⌘V in the app the user came from.
    private func deliver(_ item: ClipboardItem, paste: Bool, previousApp: NSRunningApplication?) {
        guard PasteService.writeToPasteboard(item, store: store) else {
            HUD.show("无法复制到剪贴板", symbol: "xmark.circle.fill", success: false)
            return
        }
        monitor.ignoreCurrentChange()
        store.touch(item.id)
        panel.hide()

        if paste && !PasteService.isAccessibilityTrusted {
            PasteService.activate(previousApp)
            PasteService.promptForAccessibility()
            HUD.show(
                "已复制。允许辅助功能后，回车可直接粘贴",
                symbol: "lock.shield.fill",
                success: false,
                duration: 3.2
            )
            Log.info("paste needs Accessibility permission; item copied only")
            return
        }

        PasteService.activate(previousApp)
        if paste {
            // 粘贴成功路径不弹 HUD：目标 App 里已经出现内容，气泡反而挡视线。
            PasteService.pasteCommandV()
            Log.info("pasted \(item.kind.rawValue) item \(item.id)")
        } else {
            HUD.show("已复制", symbol: "doc.on.doc.fill", success: true)
        }
    }

    // MARK: - Control commands

    func handle(_ command: String, _ request: [String: Any]) -> [String: Any]? {
        switch command {
        case "show":
            if !panel.isVisible { showPanel() }
            return status()
        case "hide":
            panel.hide()
            return ["ok": true, "visible": false]
        case "toggle":
            togglePanel()
            return ["ok": true, "visible": panel.isVisible]
        case "configure":
            let result = configure(request)
            var payload = status()
            payload["ok"] = hotKeyError == nil
            payload["error"] = hotKeyError ?? ""
            payload["changed"] = result["changed"] ?? false
            return payload
        case "clear":
            store.clear()
            if panel.isVisible { panel.reload() }
            return ["ok": true, "items": 0]
        case "delete":
            guard let id = request["id"] as? String, !id.isEmpty else {
                return ["ok": false, "error": "missing id"]
            }
            let existed = store.item(id: id) != nil
            store.delete(id: id)
            if panel.isVisible { panel.reload() }
            return ["ok": true, "deleted": existed, "items": store.items.count]
        case "copy":
            guard let id = request["id"] as? String, let item = store.item(id: id) else {
                return ["ok": false, "error": "unknown item"]
            }
            let paste = JSONValue.bool(request["paste"]) ?? false
            let previous = panel.isVisible
                ? panel.previousApp
                : NSWorkspace.shared.frontmostApplication
            deliver(item, paste: paste, previousApp: previous)
            return ["ok": true, "id": id, "paste": paste]
        case "snapshot":
            let path = request["path"] as? String ?? ""
            guard !path.isEmpty else { return ["ok": false, "error": "missing path"] }
            let wasVisible = panel.isVisible
            if !wasVisible { panel.show(previousApp: nil) }
            if let id = request["selectID"] as? String {
                panel.select(id: id)
            }
            NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            let files = panel.snapshot(to: path)
            if !wasVisible { panel.hide() }
            return ["ok": !files.isEmpty, "files": files]
        case "select":
            guard let id = request["id"] as? String else {
                return ["ok": false, "error": "missing id"]
            }
            guard panel.isVisible else { return ["ok": false, "error": "panel is not visible"] }
            return ["ok": panel.select(id: id)]
        default:
            return nil
        }
    }

    static func runSelfTest() -> Int32 {
        ClipboardSelfTest.run()
    }
}
