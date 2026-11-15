import AppKit
import Foundation
import UniformTypeIdentifiers

/// 截图 feature：全局快捷键、框选覆盖层、红框标注、OCR 卡片。
///
/// 这个类就是原来独立 helper 里的 `AppController`：进程级的看门狗、控制通道和
/// 快捷键注册搬到了 `NativeHost` / `HotKeyCenter`，剩下的都留在这里。
final class ScreenshotFeature: NSObject, NativeFeature, OverlayControllerDelegate {
    static let slug = "screenshot"
    static let displayName = "截图"
    static let supportDirectoryName = "DSHScreenshot"
    static let socketEnvironmentKey = "DSHS_SCREENSHOT_SOCKET"

    private let context: FeatureContext
    private var settings: ScreenshotSettings
    private let overlay = OverlayController()
    private var hotKeyError: String?
    private var hotKeyLabel = ""
    private var capturing = false
    private var permissionTimer: Timer?

    private static let channel = "screenshot.capture"

    init(context: FeatureContext) {
        self.context = context
        self.settings = ScreenshotSettings.load()
        super.init()
        // 启动参数只是兜底：用户攒在 config.json 里的选择更权威（插件可能把
        // 加载那一刻的旧值当参数传进来）。
        if ScreenshotSettings.storedHotkey == nil,
           let hotkey = context.launchHotkey, !hotkey.isEmpty {
            settings.hotkey = hotkey
        }
        if let directory = context.launchSaveDirectory, !directory.isEmpty,
           settings.saveDirectory.isEmpty || settings.saveDirectory == ScreenshotSettings.defaultSaveDirectory() {
            settings.saveDirectory = directory
        }
        if settings.saveDirectory.isEmpty {
            settings.saveDirectory = ScreenshotSettings.defaultSaveDirectory()
        }
    }

    // MARK: - Lifecycle

    func start() {
        overlay.delegate = self
        applyHotKey()
        // Vision 第一次调用要 ~19s 加载模型，趁启动在后台捂热。
        TextRecognition.warmUp()
        if context.activateOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.beginCapture()
            }
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        context.hotKeys.unregister(channel: ScreenshotFeature.channel)
        overlay.dismiss()
    }

    func status() -> [String: Any] {
        [
            "hotkey": settings.hotkey,
            "hotkeyLabel": hotKeyLabel,
            "permission": ScreenCapture.hasPermission,
            "saveDirectory": settings.saveDirectory,
            "capturing": capturing || overlay.isPresented,
            "ocrLanguages": settings.ocrLanguages,
            "ocrKeepLineBreaks": settings.ocrKeepLineBreaks,
        ]
    }

    // MARK: - Settings

    func applySettings(_ request: [String: Any]) -> [String: Any] {
        var changed = false
        if let hotkey = request["hotkey"] as? String, !hotkey.isEmpty, hotkey != settings.hotkey {
            settings.hotkey = hotkey
            changed = true
            applyHotKey()
        }
        if let directory = request["saveDirectory"] as? String, !directory.isEmpty,
           directory != settings.saveDirectory {
            settings.saveDirectory = directory
            changed = true
        }
        if let languages = request["ocrLanguages"] as? String, !languages.isEmpty,
           languages != settings.ocrLanguages {
            settings.ocrLanguages = languages
            changed = true
        }
        if let keep = JSONValue.bool(request["ocrKeepLineBreaks"]), keep != settings.ocrKeepLineBreaks {
            settings.ocrKeepLineBreaks = keep
            changed = true
        }
        if changed {
            settings.save()
            applyOCRSettingsToOverlay()
        }
        var reply = status()
        reply["ok"] = hotKeyError == nil
        reply["label"] = hotKeyLabel
        if let hotKeyError {
            reply["error"] = hotKeyError
        }
        return reply
    }

    /// Keeps the live overlay in sync with the settings the plugin pushes.
    private func applyOCRSettingsToOverlay() {
        for view in overlay.views {
            view.settingsOCRLanguages = settings.ocrLanguages
            view.settingsKeepLineBreaks = settings.ocrKeepLineBreaks
        }
    }

    // MARK: - Shortcut

    private func applyHotKey() {
        context.hotKeys.unregister(channel: ScreenshotFeature.channel)
        hotKeyError = nil
        guard let spec = KeySpecParser.parse(settings.hotkey) else {
            hotKeyLabel = settings.hotkey
            hotKeyError = "无法解析快捷键 \(settings.hotkey)"
            Log.error(hotKeyError ?? "")
            HUD.show(hotKeyError ?? "快捷键不可用", symbol: "exclamationmark.triangle.fill", success: false, duration: 3)
            return
        }
        hotKeyLabel = spec.label
        hotKeyError = context.hotKeys.register(spec, channel: ScreenshotFeature.channel) { [weak self] in
            self?.beginCapture()
        }
        if let hotKeyError {
            Log.error(hotKeyError)
            HUD.show(hotKeyError, symbol: "exclamationmark.triangle.fill", success: false, duration: 3)
        } else {
            Log.info("hotkey \(spec.label) registered")
        }
    }

    // MARK: - Permission

    /// macOS 有时要等一小会儿才把新授权交给进程，授权后自己把提示收掉。
    private func watchPermission() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard !ScreenCapture.hasPermission else { return }
        let deadline = Date().addingTimeInterval(180)
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if ScreenCapture.hasPermission {
                timer.invalidate()
                self.permissionTimer = nil
                HUD.show("屏幕录制权限已生效 — 再按一次快捷键即可截图", symbol: "checkmark.shield.fill", duration: 3)
            } else if Date() > deadline {
                timer.invalidate()
                self.permissionTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// macOS 把屏幕录制算成独立权限，第一次截图前必须让系统把本 app 登记进
    /// TCC 列表。这里不放模态弹窗：截图热键是随时按的，模态框会把进程卡住。
    private func requestScreenRecording() {
        _ = ScreenCapture.requestPermission()
        HUD.show("需要屏幕录制权限：在系统设置里勾选 DeepSeek Harness", symbol: "lock.shield", success: false, duration: 4)
        Log.info("permission required: grant Screen Recording to DeepSeek Harness")
        printJSON(["event": "permission-required", "feature": ScreenshotFeature.slug])
        watchPermission()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.openScreenRecordingSettings()
        }
    }

    // MARK: - Capture

    func beginCapture() {
        guard !capturing, !overlay.isPresented else { return }
        if context.dryRun {
            captureSynthetic()
            return
        }
        do {
            let shots = try ScreenCapture.captureAllScreens()
            capturing = true
            overlay.present(shots)
            applyOCRSettingsToOverlay()
        } catch CaptureError.permissionDenied {
            requestScreenRecording()
        } catch {
            Log.error("capture failed: \(error.localizedDescription)")
            HUD.show("截图失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", success: false)
        }
    }

    private func captureSynthetic() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        capturing = true
        overlay.present([ScreenCapture.syntheticShot(for: screen)])
        applyOCRSettingsToOverlay()
    }

    // MARK: - Overlay results

    func overlayController(_ controller: OverlayController, didConfirm view: SelectionView) {
        capturing = false
        guard let image = view.composedImage() else {
            controller.dismiss()
            HUD.show("无法生成截图", symbol: "xmark.circle.fill", success: false)
            return
        }
        let scale = view.shot.scale
        controller.dismiss()
        guard ImageOutput.copyToPasteboard(image, scale: scale) else {
            HUD.show("复制到剪贴板失败", symbol: "exclamationmark.triangle.fill", success: false)
            return
        }
        Log.info("copied \(image.width)x\(image.height) to pasteboard")
        printJSON(["event": "copied", "feature": ScreenshotFeature.slug, "width": image.width, "height": image.height])
        // 同一批像素的第二份表示：偏好文本的应用拿字，图像应用仍拿图。
        let languages = TextRecognition.languages(for: settings.ocrLanguages)
        let keepLineBreaks = settings.ocrKeepLineBreaks
        TextRecognition.recognize(image: image, keepLineBreaks: keepLineBreaks, languages: languages) { text in
            guard let text, !text.isEmpty else { return }
            guard ImageOutput.appendTextToPasteboard(text.text) else { return }
            Log.info("pasteboard text: \(text.characterCount) chars in \(text.milliseconds) ms")
            printJSON([
                "event": "text",
                "feature": ScreenshotFeature.slug,
                "characters": text.characterCount,
                "milliseconds": text.milliseconds,
            ])
        }
    }

    /// ⌥⏎ or the card's copy button: text only.
    func overlayController(_ controller: OverlayController, didCopyText text: String) {
        capturing = false
        controller.dismiss()
        if ImageOutput.copyTextToPasteboard(text) {
            Log.info("copied \(text.count) characters to pasteboard")
            printJSON(["event": "text-copied", "feature": ScreenshotFeature.slug, "characters": text.count])
        } else {
            HUD.show("复制文字失败", symbol: "exclamationmark.triangle.fill", success: false)
        }
    }

    func overlayController(_ controller: OverlayController, didRequestSave view: SelectionView) {
        guard let image = view.composedImage() else {
            capturing = false
            controller.dismiss()
            HUD.show("无法生成截图", symbol: "xmark.circle.fill", success: false)
            return
        }
        let scale = view.shot.scale
        controller.hideForModal()

        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.prompt = "保存"
        panel.message = "选择截图保存位置"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ImageOutput.timestampedFileName()
        panel.directoryURL = URL(fileURLWithPath: settings.saveDirectory, isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else {
            controller.restoreAfterModal()
            return
        }
        do {
            let saved = try ImageOutput.write(image, scale: scale, to: url)
            settings.saveDirectory = saved.deletingLastPathComponent().path
            settings.save()
            capturing = false
            controller.dismiss()
            Log.info("saved \(saved.path)")
            printJSON(["event": "saved", "feature": ScreenshotFeature.slug, "path": saved.path])
        } catch {
            capturing = false
            controller.dismiss()
            Log.error("save failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    func overlayControllerDidCancel(_ controller: OverlayController) {
        controller.dismiss()
        capturing = false
    }

    // MARK: - Control commands

    func handle(_ command: String, _ request: [String: Any]) -> [String: Any]? {
        switch command {
        case "capture":
            DispatchQueue.main.async { [weak self] in self?.beginCapture() }
            return ["ok": true]
        case "dry-run":
            DispatchQueue.main.async { [weak self] in self?.captureSynthetic() }
            return ["ok": true]
        case "snapshot":
            let directory = request["path"] as? String ?? ""
            return ["ok": true, "files": overlay.debugSnapshot(to: directory)]
        case "confirm":
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.overlay.views.first else { return }
                self.overlayController(self.overlay, didConfirm: view)
            }
            return ["ok": true]
        case "save-to":
            // Same pipeline as the save button, minus the interactive panel.
            let path = request["path"] as? String ?? ""
            guard !path.isEmpty else { return ["ok": false, "error": "missing path"] }
            guard let view = overlay.views.first, let image = view.composedImage() else {
                return ["ok": false, "error": "nothing selected"]
            }
            do {
                let url = try ImageOutput.write(image, scale: view.shot.scale, to: URL(fileURLWithPath: path))
                overlay.dismiss()
                capturing = false
                return ["ok": true, "path": url.path]
            } catch {
                return ["ok": false, "error": error.localizedDescription]
            }
        case "select":
            // Test hook: paint a selection without a real mouse drag.
            guard let frame = JSONValue.rect(request["rect"]) else {
                return ["ok": false, "error": "rect must be [x, y, w, h]"]
            }
            DispatchQueue.main.async { [weak self] in
                self?.overlay.views.first?.testSelect(frame)
            }
            return ["ok": true]
        case "ocr-settings":
            var changed = false
            if let languages = request["languages"] as? String, !languages.isEmpty {
                settings.ocrLanguages = languages
                changed = true
            }
            if let keep = JSONValue.bool(request["keepLineBreaks"]) {
                settings.ocrKeepLineBreaks = keep
                changed = true
            }
            if changed {
                settings.save()
                applyOCRSettingsToOverlay()
            }
            return [
                "ok": true,
                "ocrLanguages": settings.ocrLanguages,
                "ocrKeepLineBreaks": settings.ocrKeepLineBreaks,
            ]
        case "ocr-panel":
            // Test hook: open the transcription card for the current selection.
            DispatchQueue.main.async { [weak self] in
                self?.overlay.views.first?.showOCRPanel()
            }
            return ["ok": true]
        case "copy-text":
            // Test hook: what the card's「复制文字」button and ⌥⏎ do.
            DispatchQueue.main.async { [weak self] in
                self?.overlay.views.first?.copyRecognizedText()
            }
            return ["ok": true]
        case "ocr":
            // Test hook: recognise the current selection synchronously.
            guard let view = overlay.views.first, let image = view.plainImageForTesting else {
                return ["ok": false, "error": "nothing selected"]
            }
            let result = TextRecognition.recognizeSync(
                image: image,
                keepLineBreaks: settings.ocrKeepLineBreaks,
                languages: TextRecognition.languages(for: settings.ocrLanguages)
            )
            guard let result else { return ["ok": false, "error": "recognition failed"] }
            return [
                "ok": true,
                "text": result.text,
                "lines": result.lineCount,
                "characters": result.characterCount,
                "milliseconds": result.milliseconds,
            ]
        default:
            return nil
        }
    }

    static func runSelfTest() -> Int32 {
        ScreenshotSelfTest.run()
    }
}
