import AppKit
import Foundation

/// Exercises the whole pipeline without screen-recording trust: it feeds a
/// synthetic frame through the selection view, snapshots every stage, composes
/// the crop, and checks pasteboard, file output and the control channel.
enum ScreenshotSelfTest {
    private static var checks: [[String: Any]] = []
    private static var artifacts: [String] = []

    static func run() -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(
            fileURLWithPath: environment["DSHS_SELFTEST_DIR"] ?? "/tmp/dsh-screenshot-selftest",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            record("screen-available", false, "no display attached")
            return finish()
        }
        let shot = ScreenCapture.syntheticShot(for: screen)
        let scale = shot.scale

        record(
            "synthetic-shot",
            shot.imageSize == CGSize(
                width: screen.frame.width * scale,
                height: screen.frame.height * scale
            ),
            "image \(Int(shot.imageSize.width))x\(Int(shot.imageSize.height)) scale \(scale)"
        )

        // MARK: shortcut plumbing

        let parsed = KeySpecParser.parse(ScreenshotSettings.defaultHotkey)
        record(
            "parse-default-hotkey",
            parsed?.label == "⇧⌘A",
            "label \(parsed?.label ?? "nil")"
        )
        let oddSpec = KeySpecParser.parse("ctrl+alt+shift+f12")
        record("parse-modifier-order", oddSpec?.label == "⌃⌥⇧F12", "label \(oddSpec?.label ?? "nil")")

        let center = HotKeyCenter()
        let registrationError = oddSpec.map { center.register($0, channel: "selftest") {} } ?? "no spec"
        record("register-hotkey", registrationError == nil, registrationError ?? "registered")
        center.unregister(channel: "selftest")

        // MARK: overlay stages

        let view = SelectionView(shot: shot)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        view.testSetMouse(CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        if let representation = snapshot(view) {
            artifacts.append(try! save(representation, as: "stage1-idle.png", in: directory))
        }

        // A wide selection in the middle of the screen: the bar belongs below it.
        let selection = CGRect(
            x: 180,
            y: 410,
            width: 640,
            height: 360
        )
        view.testSelect(selection)
        view.layoutSubtreeIfNeeded()
        if let representation = snapshot(view) {
            artifacts.append(try! save(representation, as: "stage2-selection.png", in: directory))
        }

        if let toolbar = view.toolbarView {
            let placed = toolbar.frame
            record(
                "toolbar-below-selection",
                placed.maxY < selection.minY && placed.midX == selection.midX
                    && placed.minX >= view.bounds.minX && placed.maxX <= view.bounds.maxX,
                "bar \(shortRect(placed)) selection \(shortRect(selection))"
            )
            record(
                "toolbar-height",
                abs(placed.height - ToolbarView.Metrics.height) < 0.5,
                "height \(placed.height)"
            )
            // 版面约定：主操作「复制」压在最右端，取消紧挨在它左侧。
            let order = toolbar.actionOrder
            record(
                "toolbar-button-order",
                order.last == .copy && order.dropLast().last == .cancel,
                order.map { name(of: $0) }.joined(separator: " ")
            )
        } else {
            record("toolbar-below-selection", false, "toolbar was not attached")
        }

        // 遮罩窗口不能有淡入动画：整屏灰层淡入看起来就是"闪一下"。
        if let screen = NSScreen.main {
            let window = OverlayWindow(screen: screen)
            record(
                "overlay-no-fade",
                window.animationBehavior == .none,
                "animationBehavior \(window.animationBehavior.rawValue)"
            )
        }

        // Near the bottom edge the bar has to flip above the selection.
        let bottomSelection = CGRect(x: 200, y: 6, width: 420, height: 200)
        view.testSelect(bottomSelection)
        if let toolbar = view.toolbarView {
            let placed = toolbar.frame(forSelection: bottomSelection, in: view.bounds)
            record(
                "toolbar-flips-above",
                placed.minY > bottomSelection.maxY && placed.maxY <= view.bounds.maxY,
                "bar \(shortRect(placed)) selection \(shortRect(bottomSelection))"
            )
        }

        // Back to the centred selection and stamp a red rectangle inside it.
        view.testSelect(selection)
        let localAnnotation = CGRect(x: 40, y: 40, width: 240, height: 140)
        let annotation = CGRect(
            x: selection.minX + localAnnotation.minX,
            y: selection.minY + localAnnotation.minY,
            width: localAnnotation.width,
            height: localAnnotation.height
        )
        view.testAddAnnotation(annotation)
        view.testActivateAnnotationMode()
        view.layoutSubtreeIfNeeded()
        if let representation = snapshot(view) {
            artifacts.append(try! save(representation, as: "stage3-annotated.png", in: directory))
        }
        record("annotation-mode-active", view.annotating, "bar reflects annotate state")
        record("undo-annotation", {
            view.undoAnnotation()
            let empty = view.annotations.isEmpty
            view.testAddAnnotation(annotation)
            return empty
        }(), "annotation removed and restored")

        // MARK: compose

        guard let composed = view.composedImage() else {
            record("compose", false, "composedImage returned nil")
            return finish()
        }
        let expectedWidth = Int((selection.width * scale).rounded())
        let expectedHeight = Int((selection.height * scale).rounded())
        record(
            "compose-size",
            abs(composed.width - expectedWidth) <= 1 && abs(composed.height - expectedHeight) <= 1,
            "\(composed.width)x\(composed.height) expected \(expectedWidth)x\(expectedHeight)"
        )

        // The stroke is measured from the raw bitmap instead of assumed, which
        // is what catches a flipped or offset composition.
        let expected = CGRect(
            x: localAnnotation.minX * scale,
            y: CGFloat(composed.height) - localAnnotation.maxY * scale,
            width: localAnnotation.width * scale,
            height: localAnnotation.height * scale
        )
        if let box = Self.redBoundingBox(composed) {
            let tolerance: CGFloat = 4
            let aligned = abs(box.minX - expected.minX) <= tolerance
                && abs(box.minY - expected.minY) <= tolerance
                && abs(box.maxX - expected.maxX) <= tolerance
                && abs(box.maxY - expected.maxY) <= tolerance
            record(
                "compose-annotation-box",
                aligned,
                "stroke \(shortRect(box)) expected \(shortRect(expected))"
            )
            let inner = box.insetBy(dx: 12, dy: 12)
            let hollow = Self.redPixelCount(composed, in: inner) == 0
            record(
                "compose-annotation-hollow",
                hollow,
                "inside \(shortRect(inner)) stays clean"
            )
        } else {
            record("compose-annotation-box", false, "no red pixels in composed image")
        }

        if let png = ImageOutput.pngData(composed, scale: scale) {
            let url = directory.appendingPathComponent("crop-annotated.png")
            do {
                try png.write(to: url, options: .atomic)
                artifacts.append(url.path)
            } catch {
                record("write-crop", false, error.localizedDescription)
            }
        }

        // MARK: pasteboard

        let copied = ImageOutput.copyToPasteboard(composed, scale: scale)
        let pasteboard = NSPasteboard.general
        let pngOnBoard = pasteboard.data(forType: .png) != nil
        let tiffOnBoard = pasteboard.data(forType: .tiff) != nil
        record("pasteboard-png", copied && pngOnBoard, "png \(pngOnBoard) tiff \(tiffOnBoard)")

        // MARK: text recognition

        // The synthetic frame carries "DSH 截图助手 · 测试画面" in the middle, so
        // the whole frame is a stable OCR target.
        if let fullFrame = Self.syntheticFrameImage() {
            let cold = Date()
            let first = TextRecognition.recognizeSync(image: fullFrame, keepLineBreaks: true, languages: [])
            let coldMilliseconds = Int(Date().timeIntervalSince(cold) * 1000)
            let warmStart = Date()
            let second = TextRecognition.recognizeSync(image: fullFrame, keepLineBreaks: true, languages: [])
            let warmMilliseconds = Int(Date().timeIntervalSince(warmStart) * 1000)
            let text = second?.text ?? first?.text ?? ""
            let normalised = text.replacingOccurrences(of: " ", with: "")
            let found = normalised.contains("DSH") || normalised.contains("截图")
            record(
                "ocr-synthetic",
                found,
                "cold \(coldMilliseconds)ms warm \(warmMilliseconds)ms lines \(second?.lineCount ?? 0) text「\(String(text.prefix(24)))」"
            )
            record(
                "ocr-warm-latency",
                warmMilliseconds < 4000,
                "warm call \(warmMilliseconds)ms"
            )
            if let text = second?.text, !text.isEmpty {
                let appended = ImageOutput.appendTextToPasteboard(text)
                let onBoard = NSPasteboard.general.string(forType: .string)
                record(
                    "pasteboard-text",
                    appended && onBoard == text && NSPasteboard.general.data(forType: .png) != nil,
                    "text \(onBoard?.count ?? 0) chars, png kept \(NSPasteboard.general.data(forType: .png) != nil)"
                )
            } else {
                record("pasteboard-text", false, "no text to append")
            }
        } else {
            record("ocr-synthetic", false, "synthetic frame unavailable")
        }

        // MARK: file output

        let fileURL = directory.appendingPathComponent(ImageOutput.timestampedFileName())
        do {
            _ = try ImageOutput.write(composed, scale: scale, to: fileURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let decoded = NSImage(contentsOf: fileURL)
            record(
                "write-png",
                size > 1000 && decoded != nil,
                "\(size) bytes, decodable \(decoded != nil)"
            )
            artifacts.append(fileURL.path)
        } catch {
            record("write-png", false, error.localizedDescription)
        }

        // MARK: control channel

        let socketPath = NSTemporaryDirectory() + "dsh-screenshot-selftest-\(getpid()).sock"
        let server = ControlServer(socketPath: socketPath)
        server.handler = { request in
            ["ok": true, "echo": request["command"] as? String ?? "", "pid": getpid()]
        }
        do {
            setenv("DSHS_SCREENSHOT_SOCKET", socketPath, 1)
            try server.start()
            var reply: [String: Any]?
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                reply = ControlClient.send(["command": "status"], to: socketPath)
                finished.signal()
            }
            // The control server accepts on the main queue, so pump it until the
            // background client has its answer.
            let deadline = Date().addingTimeInterval(5)
            while finished.wait(timeout: .now()) == .timedOut, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            record(
                "control-roundtrip",
                reply?["ok"] as? Bool == true && reply?["echo"] as? String == "status",
                "reply \(reply ?? [:])"
            )
            server.stop()
        } catch {
            record("control-roundtrip", false, error.localizedDescription)
        }

        // MARK: clipboard restore

        if let previous = environment["DSHS_SELFTEST_KEEP_CLIPBOARD"], previous == "1" {
            // keep the screenshot on the pasteboard so a human can paste it
        } else {
            pasteboard.clearContents()
        }

        return finish()
    }

    // MARK: - Helpers

    private static func record(_ name: String, _ passed: Bool, _ detail: String) {
        checks.append(["check": name, "passed": passed, "detail": detail])
        Log.info("\(passed ? "PASS" : "FAIL") \(name) — \(detail)")
    }

    private static func finish() -> Int32 {
        let failed = checks.filter { ($0["passed"] as? Bool) != true }
        let payload: [String: Any] = [
            "event": "self-test",
            "passed": failed.isEmpty,
            "failures": failed.count,
            "checks": checks,
            "artifacts": artifacts,
        ]
        printJSON(payload)
        return failed.isEmpty ? 0 : 1
    }

    private static func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        view.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }

    private static func save(
        _ representation: NSBitmapImageRep,
        as name: String,
        in directory: URL
    ) throws -> String {
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url.path
    }

    /// Walks the raw bitmap rows (row 0 is the top of the image) so the result
    /// does not depend on AppKit's sampling orientation.
    private static func redBoundingBox(_ image: CGImage) -> CGRect? {
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        forEachRedPixel(image) { x, y in
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func redPixelCount(_ image: CGImage, in rect: CGRect) -> Int {
        var count = 0
        forEachRedPixel(image) { x, y in
            if rect.contains(CGPoint(x: x, y: y)) { count += 1 }
        }
        return count
    }

    private static func forEachRedPixel(
        _ image: CGImage,
        body: (_ x: Int, _ y: Int) -> Void
    ) {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return
        }
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        for y in 0..<image.height {
            let row = bytes + y * image.bytesPerRow
            for x in 0..<image.width {
                let pixel = row + x * bytesPerPixel
                let red = Int(pixel[0])
                let green = Int(pixel[1])
                let blue = Int(pixel[2])
                if red > 170, green < 140, blue < 130 {
                    body(x, y)
                }
            }
        }
    }

    private static func syntheticFrameImage() -> CGImage? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return ScreenCapture.syntheticShot(for: screen).image
    }

    private static func shortRect(_ rect: CGRect) -> String {
        String(
            format: "(%.0f,%.0f %.0fx%.0f)",
            rect.origin.x,
            rect.origin.y,
            rect.width,
            rect.height
        )
    }

    /// 按钮自测里打印用的短名字。
    private static func name(of action: ToolbarView.Action) -> String {
        switch action {
        case .annotate: return "annotate"
        case .text: return "text"
        case .save: return "save"
        case .copy: return "copy"
        case .cancel: return "cancel"
        }
    }

}
