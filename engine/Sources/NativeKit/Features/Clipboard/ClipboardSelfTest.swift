import AppKit
import Foundation

/// Headless-ish verification of the store, monitor and panel. Run with
/// `--self-test`; it never touches the real history directory unless
/// `DSHS_SELFTEST_DIR` points somewhere specific.
enum ClipboardSelfTest {
    private static var checks: [[String: Any]] = []
    private static var artifacts: [String] = []

    static func run() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(
            fileURLWithPath: environment["DSHS_SELFTEST_DIR"] ?? "/tmp/dsh-clipboard-selftest",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        testHotkey()
        testTextStore(in: directory)
        testImageStore(in: directory)
        testSearch(in: directory)
        testPruning(in: directory)
        testPersistence(in: directory)
        testPasteboard(in: directory)
        testMonitorDecoding()
        testPanel(in: directory)
        testPanelInitialSelection(in: directory)
        return finish()
    }

    /// 面板打开时应该停在顶部、选中第一条 —— 条数多的时候尤其明显。
    /// 曾经的问题是：选中行跨 hide/show 保留，用户上次停在最后一条，下次打开就直接跳到
    /// 底部并选中最后一条（2026-11-21 反馈）。
    private static func testPanelInitialSelection(in directory: URL) {
        let store = ClipboardStore(directory: directory.appendingPathComponent("panel-scroll-store"))
        store.setLimits(maxItems: 500, retentionDays: 0)
        let base = Date()
        for i in 0..<60 {
            store.addText("样本文本 \(i)", source: ClipboardSource(name: "Notes"), at: base.addingTimeInterval(Double(i)))
        }
        let panel = ClipboardPanelController(store: store)
        let firstID = store.items.first?.id ?? ""

        panel.show(previousApp: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let opened = panel.debugState()
        record(
            "panel-initial-selection",
            (opened["selectedRow"] as? Int) == 0 && (opened["selectedID"] as? String) == firstID,
            "row \(opened["selectedRow"] ?? "nil") id \(opened["selectedID"] ?? "nil")"
        )
        record(
            "panel-initial-scroll-top",
            (opened["scrollY"] as? Double) == 0,
            "scrollY \(opened["scrollY"] ?? "nil") doc \(opened["docHeight"] ?? "nil")"
        )

        // 把选中行挪到最末尾，模拟用户上次停在最后一条，再关掉重开。
        if let last = store.items.last {
            _ = panel.select(id: last.id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let parked = panel.debugState()
        record(
            "panel-sticky-before-hide",
            (parked["selectedRow"] as? Int) == (parked["rows"] as? Int).map { $0 - 1 },
            "row \(parked["selectedRow"] ?? "nil") scrollY \(parked["scrollY"] ?? "nil")"
        )
        panel.hide()
        panel.show(previousApp: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let reopened = panel.debugState()
        record(
            "panel-reopen-resets-to-top",
            (reopened["selectedRow"] as? Int) == 0 && (reopened["scrollY"] as? Double) == 0,
            "row \(reopened["selectedRow"] ?? "nil") scrollY \(reopened["scrollY"] ?? "nil")"
        )
        panel.hide()
    }

    // MARK: - Suites

    private static func testHotkey() {
        let parsed = KeySpecParser.parse("cmd+shift+v")
        record(
            "parse-default-hotkey",
            parsed != nil && parsed?.keyCode == 9 && parsed?.label == "⇧⌘V",
            "label \(parsed?.label ?? "nil")"
        )
        record("reject-bare-key", KeySpecParser.parse("v") == nil, "bare key accepted")
        record("reject-modifier-only", KeySpecParser.parse("cmd+shift") == nil, "modifier-only accepted")
        let allPresets = KeySpecParser.presets.allSatisfy { KeySpecParser.parse($0) != nil }
        record("all-presets-parse", allPresets, "presets \(KeySpecParser.presets)")
    }

    private static func testTextStore(in directory: URL) {
        let store = ClipboardStore(directory: directory.appendingPathComponent("text-store"))
        store.setLimits(maxItems: 200, retentionDays: 0)
        let base = Date()
        let first = store.addText("alpha", source: ClipboardSource(name: "Safari", bundleID: "com.apple.Safari"), at: base)
        let second = store.addText("beta\ngamma", source: .unknown, at: base.addingTimeInterval(1))
        let third = store.addText("delta", source: .unknown, at: base.addingTimeInterval(2))

        record("text-insert-order", store.items.map(\.title) == ["delta", "beta", "alpha"], "order \(store.items.map(\.title))")
        record("text-ids-unique", Set(store.items.map(\.id)).count == 3, "ids \(store.items.map(\.id))")

        let b = second?.id ?? ""
        let touched = store.addText("beta\ngamma", source: ClipboardSource(name: "Notes", bundleID: nil), at: base.addingTimeInterval(3))
        record(
            "text-dedupe-moves-top",
            store.items.count == 3 && touched?.id == b && store.items.first?.id == b,
            "count \(store.items.count) top \(store.items.first?.title ?? "nil")"
        )
        record("text-dedupe-id-stable", touched?.id == first?.id ? false : touched?.id == b, "id changed")
        record("text-dedupe-source-updated", touched?.sourceName == "Notes", "source \(touched?.sourceName ?? "nil")")
        record("text-multiline-title", second?.title == "beta", "title \(second?.title ?? "nil")")
        record("text-size-count", third?.sizeText.contains("字符") == true, "size \(third?.sizeText ?? "nil")")

        let whitespace = store.addText("   \n\t ", source: .unknown)
        record("text-whitespace-rejected", whitespace == nil, "whitespace stored")

        let huge = String(repeating: "x", count: ClipboardStore.maxTextBytes + 1)
        record("text-limit-rejected", store.addText(huge, source: .unknown) == nil, "huge text stored")

        let touchID = store.items.last?.id ?? ""
        let touchedAgain = store.touch(touchID, at: base.addingTimeInterval(10))
        record(
            "touch-promotes",
            touchedAgain?.id == touchID && store.items.first?.id == touchID,
            "top \(store.items.first?.title ?? "nil")"
        )
        record("invalid-touch", store.touch("missing") == nil, "missing id touched")
    }

    private static func testImageStore(in directory: URL) {
        let store = ClipboardStore(directory: directory.appendingPathComponent("image-store"))
        store.setLimits(maxItems: 200, retentionDays: 0)
        let png = makeTestImage()
        record("test-image-nonempty", png.count > 1_000, "bytes \(png.count)")

        let item = store.addImage(pngData: png, thumbData: nil, source: ClipboardSource(name: "Preview", bundleID: nil))
        record("image-inserted", item != nil && store.items.count == 1, "count \(store.items.count)")
        if let item {
            record("image-dimensions", item.width == 640 && item.height == 400, "\(item.width ?? 0)x\(item.height ?? 0)")
            record("image-kind-title", item.title.contains("640"), "title \(item.title)")
            let fileURL = store.imageURL(for: item)
            record("image-file-exists", fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "missing file")
            let thumbURL = store.thumbURL(for: item)
            record(
                "image-thumb-exists",
                thumbURL.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                "missing thumb"
            )
            if let thumbURL, let thumb = NSImage(contentsOf: thumbURL) {
                let thumbSize = thumb.representations.first.map { ($0.pixelsWide, $0.pixelsHigh) } ?? (0, 0)
                record("image-thumb-bounded", thumbSize.0 <= 160 && thumbSize.1 <= 160, "thumb \(thumbSize)")
            } else {
                record("image-thumb-bounded", false, "thumb unreadable")
            }
        }

        let duplicate = store.addImage(pngData: png, thumbData: nil, source: ClipboardSource(name: "Finder", bundleID: nil))
        record(
            "image-dedupe",
            store.items.count == 1 && duplicate?.id == item?.id && duplicate?.sourceName == "Finder",
            "count \(store.items.count)"
        )

        let small = makeTestImage(width: 320, height: 200)
        let second = store.addImage(pngData: small, thumbData: nil, source: .unknown)
        record(
            "image-order",
            store.items.count == 2 && store.items.first?.id == second?.id,
            "top \(store.items.first?.title ?? "nil")"
        )

        if let item {
            store.delete(id: item.id)
            record("image-delete-files", store.items.count == 1, "count \(store.items.count)")
            if let fileURL = store.imageURL(for: item) {
                record(
                    "image-delete-removes-file",
                    !FileManager.default.fileExists(atPath: fileURL.path),
                    "file survived"
                )
            }
        }
    }

    private static func testSearch(in directory: URL) {
        let store = ClipboardStore(directory: directory.appendingPathComponent("search-store"))
        store.setLimits(maxItems: 200, retentionDays: 0)
        let base = Date()
        store.addText("Hello World", source: ClipboardSource(name: "Safari", bundleID: nil), at: base)
        store.addText("你好，世界", source: ClipboardSource(name: "Notes", bundleID: nil), at: base.addingTimeInterval(1))
        let png = makeTestImage()
        store.addImage(pngData: png, thumbData: nil, source: ClipboardSource(name: "Preview", bundleID: nil), at: base.addingTimeInterval(2))

        record("search-case-insensitive", store.search("hello").count == 1, "count \(store.search("hello").count)")
        record("search-chinese", store.search("世界").count == 1, "count \(store.search("世界").count)")
        record("search-image-label", store.search("图片").count == 1, "count \(store.search("图片").count)")
        record("search-source", store.search("Safari").count == 1, "count \(store.search("Safari").count)")
        record("search-empty-returns-all", store.search("   ").count == 3, "count \(store.search("   ").count)")
        record("search-no-match", store.search("zzz").isEmpty, "unexpected match")
    }

    private static func testPruning(in directory: URL) {
        let store = ClipboardStore(directory: directory.appendingPathComponent("prune-store"))
        store.setLimits(maxItems: 200, retentionDays: 0)
        let base = Date()
        for index in 0..<25 {
            store.addText("item-\(index)", source: .unknown, at: base.addingTimeInterval(Double(index)))
        }
        store.setLimits(maxItems: 20, retentionDays: 0)
        record("prune-max-items", store.items.count == 20, "count \(store.items.count)")
        record("prune-keeps-newest", store.items.first?.text == "item-24", "top \(store.items.first?.text ?? "nil")")

        let older = ClipboardStore(directory: directory.appendingPathComponent("retention-store"))
        older.setLimits(maxItems: 200, retentionDays: 1)
        older.addText("three days old", source: .unknown, at: base.addingTimeInterval(-3 * 86_400))
        older.addText("fresh", source: .unknown, at: base)
        older.prune(now: base)
        record(
            "prune-retention",
            older.items.count == 1 && older.items.first?.text == "fresh",
            "count \(older.items.count)"
        )

        let forever = ClipboardStore(directory: directory.appendingPathComponent("forever-store"))
        forever.setLimits(maxItems: 200, retentionDays: 0)
        forever.addText("ancient", source: .unknown, at: base.addingTimeInterval(-400 * 86_400))
        forever.prune(now: base)
        record("retention-zero-forever", forever.items.count == 1, "count \(forever.items.count)")

        let clamped = ClipboardStore(directory: directory.appendingPathComponent("clamp-store"))
        clamped.setLimits(maxItems: 10_000, retentionDays: 9_999)
        record("limits-clamped", clamped.maxItems == 2_000 && clamped.retentionDays == 3_650, "\(clamped.maxItems)/\(clamped.retentionDays)")
    }

    private static func testPersistence(in directory: URL) {
        let url = directory.appendingPathComponent("persist-store")
        let store = ClipboardStore(directory: url)
        store.setLimits(maxItems: 200, retentionDays: 0)
        let base = Date()
        store.addText("first", source: .unknown, at: base)
        store.addText("second", source: .unknown, at: base.addingTimeInterval(1))
        let ids = store.items.map(\.id)

        let reloaded = ClipboardStore(directory: url)
        record("persist-count", reloaded.items.count == 2, "count \(reloaded.items.count)")
        record("persist-order", reloaded.items.map(\.id) == ids, "ids \(reloaded.items.map(\.id))")

        let broken = url.appendingPathComponent("history.json")
        try? Data("not json".utf8).write(to: broken)
        let recovered = ClipboardStore(directory: url)
        record("corrupt-history-recovers", recovered.items.isEmpty, "loaded \(recovered.items.count) items")
    }

    private static func testPasteboard(in directory: URL) {
        let store = ClipboardStore(directory: directory.appendingPathComponent("paste-store"))
        store.setLimits(maxItems: 200, retentionDays: 0)
        let textItem = store.addText("pasteboard roundtrip ✓", source: .unknown)
        let imageData = makeTestImage(width: 120, height: 80)
        let imageItem = store.addImage(pngData: imageData, thumbData: nil, source: .unknown)

        let pasteboard = NSPasteboard.general
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }

        if let textItem {
            let wrote = PasteService.writeToPasteboard(textItem, store: store)
            record("pasteboard-write-text", wrote && pasteboard.string(forType: .string) == textItem.text, "write failed")
        }
        if let imageItem {
            let wrote = PasteService.writeToPasteboard(imageItem, store: store)
            let data = pasteboard.data(forType: .png)
            record(
                "pasteboard-write-image",
                wrote && data != nil && NSBitmapImageRep(data: data ?? Data()) != nil,
                "write failed"
            )
        }
    }

    private static func testMonitorDecoding() {
        record("image-wins-url", ClipboardMonitor.imageWinsOverText("https://example.com/a.jpg"), "URL rejected")
        record("image-wins-path", ClipboardMonitor.imageWinsOverText("/Users/me/Desktop/a.png"), "path rejected")
        record("text-wins-caption", !ClipboardMonitor.imageWinsOverText("hello there"), "caption promoted image")
        record("text-wins-multiline", !ClipboardMonitor.imageWinsOverText("line one\nline two"), "multiline promoted image")

        let unique = NSPasteboard.withUniqueName()
        unique.clearContents()
        unique.setString("unique text", forType: .string)
        let textCapture = ClipboardMonitor.capture(from: unique, source: .unknown)
        if case let .text(value)? = textCapture?.payload {
            record("monitor-captures-text", value == "unique text", "value \(value)")
        } else {
            record("monitor-captures-text", false, "no text capture")
        }

        unique.clearContents()
        let png = makeTestImage(width: 200, height: 120)
        unique.setData(png, forType: .png)
        unique.setString("https://example.com/image.png", forType: .string)
        let imageCapture = ClipboardMonitor.capture(from: unique, source: .unknown)
        if case let .image(data, _, width, height)? = imageCapture?.payload {
            record("monitor-captures-image", data.count == png.count && width == 200 && height == 120, "\(width)x\(height)")
        } else {
            record("monitor-captures-image", false, "no image capture")
        }
        unique.clearContents()
        unique.releaseGlobally()
    }

    private static func testPanel(in directory: URL) {
        let store = ClipboardStore(directory: directory.appendingPathComponent("panel-store"))
        store.setLimits(maxItems: 200, retentionDays: 0)
        let base = Date()
        store.addText("短文本：今天下午三点和设计团队评审剪贴板面板。", source: ClipboardSource(name: "Notes"), at: base.addingTimeInterval(5))
        store.addText(
            "这是一段更长的示例文本，用来检查右侧详情里的自动换行和滚动。\n\n"
                + "Alfred 的剪贴板历史把列表放在左侧、预览放在右侧；这个面板保持同样的结构，"
                + "并额外提供搜索、删除与保留策略。中文和 English 混排也应该正常显示。\n\n"
                + "https://example.com/clipboard-history",
            source: ClipboardSource(name: "Safari"),
            at: base.addingTimeInterval(4)
        )
        store.addText(
            "func greet(name: String) -> String {\n    \"Hello, \\(name)!\"\n}",
            source: ClipboardSource(name: "Xcode"),
            at: base.addingTimeInterval(3)
        )
        let png = makeTestImage()
        store.addImage(pngData: png, thumbData: nil, source: ClipboardSource(name: "Preview"), at: base.addingTimeInterval(2))
        store.addText("https://deepseek.com", source: ClipboardSource(name: "Safari"), at: base.addingTimeInterval(1))

        let panel = ClipboardPanelController(store: store)
        panel.updateHotkeyLabel("⇧⌘V")
        panel.show(previousApp: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        record("panel-visible", panel.isVisible, "panel not visible")

        // 底板必须是真毛玻璃：blendingMode = .behindWindow + maskImage 圆角。
        // 一旦有人把它改回 layer.cornerRadius + masksToBounds，模糊底图会被裁掉，
        // 面板就变成一块不透明白色（2026-11-15 用户报过这个）。
        let effect = panel.effectView
        record(
            "panel-material",
            effect.blendingMode == .behindWindow && effect.material == .popover,
            "blending \(effect.blendingMode.rawValue) material \(effect.material.rawValue)"
        )
        record("panel-mask-image", effect.maskImage != nil, "maskImage missing")
        record(
            "panel-no-layer-clip",
            effect.layer?.cornerRadius ?? 0 == 0 && effect.layer?.masksToBounds != true,
            "layer cornerRadius \(effect.layer?.cornerRadius ?? 0) masksToBounds \(effect.layer?.masksToBounds ?? false)"
        )

        panel.debugSelect(row: 1)
        artifacts.append(contentsOf: panel.snapshot(to: directory.path, name: "panel-image.png"))

        panel.debugSelect(row: 3)
        artifacts.append(contentsOf: panel.snapshot(to: directory.path, name: "panel-text.png"))

        panel.hide()
        record("panel-hidden", !panel.isVisible, "panel still visible")

        for artifact in artifacts {
            let size = (try? FileManager.default.attributesOfItem(atPath: artifact)[.size] as? Int) ?? 0
            record("artifact-\(URL(fileURLWithPath: artifact).lastPathComponent)", size > 10_000, "bytes \(size)")
        }
    }

    // MARK: - Helpers

    private static func makeTestImage(width: Int = 640, height: Int = 400) -> Data {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            return Data()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.16, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let colors: [NSColor] = [.systemIndigo, .systemPink, .systemOrange]
        for (index, color) in colors.enumerated() {
            color.withAlphaComponent(0.9).setFill()
            let diameter = CGFloat(min(width, height)) * 0.55
            let x = CGFloat(index) * CGFloat(width) / 5 + 20
            let y = CGFloat(height) / 2 - diameter / 2
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return representation.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func savePasteboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            var hasData = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    hasData = true
                }
            }
            return hasData ? copy : nil
        }
    }

    private static func restorePasteboard(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func record(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(["name": name, "passed": passed, "detail": detail])
        if passed {
            Log.info("self-test ok: \(name)")
        } else {
            Log.error("self-test FAIL: \(name) — \(detail)")
        }
    }

    private static func finish() -> Int32 {
        let failures = checks.filter { ($0["passed"] as? Bool) != true }
        let payload: [String: Any] = [
            "event": "self-test",
            "ok": failures.isEmpty,
            "checks": checks.count,
            "failures": failures,
            "snapshots": artifacts,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
        Log.info("self-test finished: \(checks.count - failures.count)/\(checks.count) passed")
        return failures.isEmpty ? 0 : 1
    }
}
