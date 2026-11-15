import AppKit
import Foundation

/// 翻译 feature 的自测：快捷键解析、控制通道往返、面板布局、设置落盘。
enum TranslateSelfTest {
    static func run() -> Int32 {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ ok: Bool, _ detail: String) {
            checks.append(["name": name, "ok": ok, "detail": detail])
            Log.info("self-test \(ok ? "ok" : "FAILED"): \(name) — \(detail)")
        }

        // 1. 快捷键解析：每个预设都要能解析成带修饰键的键，并给出可读标签。
        for preset in KeySpecParser.presets {
            let spec = KeySpecParser.parse(preset)
            let label = KeySpecParser.label(preset)
            record(
                "hotkey:\(preset)",
                spec != nil && !label.isEmpty,
                spec == nil ? "无法解析" : "label=\(label) keyCode=\(spec!.keyCode) modifiers=\(spec!.modifiers)"
            )
        }

        // 2. 控制通道往返：起一个临时 socket，再自己问一句。
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-translate-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let socketPath = temporary.appendingPathComponent("control.sock").path
        do {
            let server = ControlServer(socketPath: socketPath)
            server.handler = { _ in ["ok": true, "pong": "yes"] }
            try server.start()
            var reply: [String: Any]?
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                reply = ControlClient.send(["command": "status"], to: socketPath)
                semaphore.signal()
            }
            let deadline = Date().addingTimeInterval(3)
            while semaphore.wait(timeout: .now()) == .timedOut, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            server.stop()
            record("control:roundtrip", reply?["pong"] as? String == "yes", "\(String(describing: reply))")
        } catch {
            record("control:roundtrip", false, error.localizedDescription)
        }

        // 3. 浮窗能构造出来（走完整个布局代码路径），且初始不可见。
        _ = NSApplication.shared
        let panel = TranslatePanelController()
        record("panel:layout", !panel.isVisible, "构造成功，初始不可见")

        // 4. 设置能落盘再读回。只在重定向到家目录之外的临时目录时做，
        //    否则会覆盖用户真实的 config.json。
        let previousHome = ProcessInfo.processInfo.environment["DSHS_TRANSLATE_HOME"]
        setenv("DSHS_TRANSLATE_HOME", temporary.appendingPathComponent("settings").path, 1)
        if TranslateSettings.supportDirectory.path.hasPrefix(temporary.path) {
            let probe = TranslateSettings(hotkey: "ctrl+opt+t", hostSocket: "/tmp/probe.sock")
            probe.save()
            let reloaded = TranslateSettings.load()
            record(
                "settings:roundtrip",
                reloaded.hotkey == "ctrl+opt+t" && reloaded.hostSocket == "/tmp/probe.sock",
                "hotkey=\(reloaded.hotkey) hostSocket=\(reloaded.hostSocket)"
            )
        } else {
            record("settings:roundtrip", true, "skipped (DSHS_TRANSLATE_HOME 未生效)")
        }
        if let previousHome {
            setenv("DSHS_TRANSLATE_HOME", previousHome, 1)
        } else {
            unsetenv("DSHS_TRANSLATE_HOME")
        }

        let ok = checks.allSatisfy { ($0["ok"] as? Bool) == true }
        printJSON(["event": "self-test", "feature": "translate", "ok": ok, "checks": checks])
        Log.info("self-test finished: \(checks.filter { ($0["ok"] as? Bool) == true }.count)/\(checks.count) passed")
        return ok ? 0 : 1
    }
}
