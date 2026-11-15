import AppKit
import Foundation

/// 输入框：回车提交，Shift+回车换行，Esc 关闭。
///
/// 输入法正在组字时（hasMarkedText）必须把按键交回去，否则中文用户敲拼音、
/// 按回车选词会被当成「提交翻译」。
final class TranslateInputView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 { // Return / 小键盘 Enter
            if flags.contains(.shift) {
                insertText("\n", replacementRange: selectedRange())
                return
            }
            onSubmit?()
            return
        }
        if event.keyCode == 53 { // Esc
            onCancel?()
            return
        }
        // macOS 的粘贴/复制是 ⌘V/⌘C，但习惯 Windows/Linux 的人会按 ⌃V，这里一并接住。
        // ⌘ 组合走主菜单的 key equivalent（见 main.swift 的 installMainMenu）。
        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "v":
                paste(nil)
                return
            case "c":
                copy(nil)
                return
            case "x":
                cut(nil)
                return
            case "a":
                selectAll(nil)
                return
            case "z":
                undoManager?.undo()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

/// 译文区：只读可选，回车等于「复制并关窗」。
final class TranslateOutputView: NSTextView {
    var onEnter: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onEnter?()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option),
           let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                copy(nil)
                return
            case "a":
                selectAll(nil)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

/// 无边框浮窗本体：可以成为 key window（要能打字），但不进 Dock、不进 Mission Control。
final class TranslatePanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 浮窗底板：圆角 + 不透明白底。
///
/// 两个坑踩过：NSVisualEffectView(.behindWindow) 的材质是窗口服务器画在窗口**背后**的，
/// 不认 contentView 的 cornerRadius，四角会露方块；而纯 layer-backed 视图只设
/// layer.backgroundColor 又不一定被 AppKit 调用（窗口透明，直接透出桌面）。
/// 所以这里老老实实自己画：一条圆角路径，填充 + 描边，形状和底色都由它决定。
final class PanelBackgroundView: NSView {
    var cornerRadius: CGFloat = 14

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 翻译浮窗：上面输入，下面译文，底部一行提示与状态。
final class TranslatePanelController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private let window: TranslatePanelWindow
    private let root = PanelBackgroundView()
    private let modeLabel = NSTextField(labelWithString: "中英自动互译")
    private let inputScroll = NSScrollView()
    private let inputView = TranslateInputView()
    private let inputPlaceholder = NSTextField(labelWithString: "输入或粘贴要翻译的内容…")
    private let separator = NSBox()
    private let outputScroll = NSScrollView()
    private let outputView = TranslateOutputView()
    private let outputPlaceholder = NSTextField(labelWithString: "回车翻译，译文显示在这里")
    private let hintLabel = NSTextField(labelWithString: "回车翻译 · ⇧回车换行 · Esc 关闭")
    private let statusLabel = NSTextField(labelWithString: "")

    private enum State {
        case idle
        case translating
        case done(text: String)
        case failed
    }

    private var state: State = .idle
    private var hostSocket: String = TranslateSettings.defaultHostSocket
    private var previousApp: NSRunningApplication?
    private var hotkeyLabel = ""

    private static let panelSize = NSSize(width: 560, height: 320)

    override init() {
        window = TranslatePanelWindow(
            contentRect: NSRect(origin: .zero, size: TranslatePanelController.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        window.delegate = self
        buildContent()
    }

    // MARK: - 界面搭建

    private func buildContent() {
        window.contentView = root

        modeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        modeLabel.textColor = .secondaryLabelColor

        inputPlaceholder.font = .systemFont(ofSize: 15)
        inputPlaceholder.textColor = .tertiaryLabelColor

        outputPlaceholder.font = .systemFont(ofSize: 13)
        outputPlaceholder.textColor = .tertiaryLabelColor

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right

        separator.boxType = .separator

        configure(inputView, editable: true)
        configure(outputView, editable: false)
        inputView.onSubmit = { [weak self] in self?.handleEnter() }
        inputView.onCancel = { [weak self] in self?.dismiss(restorePrevious: true) }
        inputView.delegate = self
        outputView.onEnter = { [weak self] in self?.handleEnter() }

        configureScroll(inputScroll, document: inputView)
        configureScroll(outputScroll, document: outputView)

        for view in [modeLabel, inputScroll, inputPlaceholder, separator, outputScroll,
                     outputPlaceholder, hintLabel, statusLabel] as [NSView] {
            root.addSubview(view)
        }
        layoutContent()
    }

    private func configure(_ textView: NSTextView, editable: Bool) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: editable ? 15 : 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.allowsUndo = editable
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: TranslatePanelController.panelSize.width,
            height: .greatestFiniteMagnitude
        )
    }

    private func configureScroll(_ scroll: NSScrollView, document: NSTextView) {
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
    }

    private func layoutContent() {
        let bounds = NSRect(origin: .zero, size: TranslatePanelController.panelSize)
        let inset: CGFloat = 14
        let modeHeight: CGFloat = 16
        let footerHeight: CGFloat = 16
        let inputHeight: CGFloat = 88

        modeLabel.frame = NSRect(
            x: inset, y: bounds.height - modeHeight - 10,
            width: bounds.width - inset * 2 - 70, height: modeHeight
        )
        hintLabel.frame = NSRect(x: inset, y: 10, width: 320, height: footerHeight)
        statusLabel.frame = NSRect(
            x: bounds.width - inset - 200, y: 10, width: 200, height: footerHeight
        )

        let contentTop = modeLabel.frame.minY - 8
        inputScroll.frame = NSRect(
            x: inset, y: contentTop - inputHeight,
            width: bounds.width - inset * 2, height: inputHeight
        )
        inputPlaceholder.frame = NSRect(
            x: inputScroll.frame.minX + 14,
            y: inputScroll.frame.maxY - 26,
            width: inputScroll.frame.width - 28, height: 20
        )
        separator.frame = NSRect(
            x: inset, y: inputScroll.frame.minY - 10,
            width: bounds.width - inset * 2, height: 1
        )
        let outputTop = separator.frame.minY - 8
        outputScroll.frame = NSRect(
            x: inset, y: footerHeight + 14,
            width: bounds.width - inset * 2, height: outputTop - footerHeight - 14
        )
        outputPlaceholder.frame = NSRect(
            x: outputScroll.frame.minX + 14,
            y: outputScroll.frame.maxY - 28,
            width: outputScroll.frame.width - 28, height: 20
        )
    }

    // MARK: - 显示与关闭

    var isVisible: Bool { window.isVisible }

    /// 打开浮窗：记住前台 App、激活自己、清空上一次的内容。
    func present(hostSocket: String, hotkeyLabel: String) {
        self.hostSocket = hostSocket.isEmpty ? TranslateSettings.defaultHostSocket : hostSocket
        self.hotkeyLabel = hotkeyLabel
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == getpid() ? nil : frontmost
        reset()
        positionNearPointer()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(inputView)
        // 圆角是在运行时画上去的，窗口要重新算一次轮廓，阴影才会跟着变成圆角。
        window.invalidateShadow()
    }

    func dismiss(restorePrevious: Bool) {
        guard window.isVisible else { return }
        window.orderOut(nil)
        state = .idle
        if restorePrevious, let previousApp, !previousApp.isTerminated {
            previousApp.activate(options: [])
        }
        self.previousApp = nil
    }

    /// 自测/文档用：把浮窗内容渲染成 PNG（走 cacheDisplay，不需要真的显示在屏幕上）。
    func snapshot(to directoryPath: String, name: String = "panel.png") -> [String] {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let view = window.contentView, view.bounds.width > 0,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return []
        }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return [] }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try data.write(to: url, options: [.atomic])
            return [url.path]
        } catch {
            Log.error("snapshot failed: \(error.localizedDescription)")
            return []
        }
    }

    func updateHotkeyLabel(_ label: String) {
        hotkeyLabel = label
        refreshMode()
    }

    /// Host 换了翻译通道地址：下一次提交就用新的。
    func updateHostSocket(_ socket: String) {
        hostSocket = socket.isEmpty ? TranslateSettings.defaultHostSocket : socket
    }

    private func reset() {
        state = .idle
        inputView.string = ""
        outputView.string = ""
        inputPlaceholder.isHidden = false
        outputPlaceholder.isHidden = false
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        refreshMode()
    }

    private func refreshMode() {
        switch state {
        case let .done(text):
            _ = text
            modeLabel.stringValue = "已译 · \(hotkeyLabel)"
        case .translating:
            modeLabel.stringValue = "翻译中…"
        case .failed:
            modeLabel.stringValue = "翻译失败 · \(hotkeyLabel)"
        case .idle:
            modeLabel.stringValue = "中英自动互译 · \(hotkeyLabel)"
        }
    }

    private func positionNearPointer() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let size = TranslatePanelController.panelSize
        var origin = NSPoint(
            x: pointer.x - size.width / 2,
            y: pointer.y - size.height - 24
        )
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - 交互

    /// 回车：没译过就开始译；已经译完就复制并关窗；失败则重试。
    private func handleEnter() {
        switch state {
        case .translating:
            return
        case let .done(text):
            guard !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            dismiss(restorePrevious: true)
        case .failed, .idle:
            submit()
        }
    }

    /// 开始翻译当前输入。
    func submit(text override: String? = nil) {
        let text = override ?? inputView.string
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "先输入要翻译的内容"
            window.makeFirstResponder(inputView)
            return
        }
        if let override {
            inputView.string = override
            inputPlaceholder.isHidden = true
        }
        state = .translating
        outputView.string = ""
        outputPlaceholder.isHidden = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "翻译中…"
        refreshMode()

        TranslateClient.translate(
            text: text,
            hostSocket: hostSocket,
            onProgress: { [weak self] index, total in
                guard let self, case .translating = self.state else { return }
                self.statusLabel.stringValue = "翻译中… \(index)/\(total)"
            },
            completion: { [weak self] outcome in
                self?.apply(outcome)
            }
        )
    }

    private func apply(_ outcome: TranslateClient.Outcome) {
        guard case .translating = state else { return }
        if outcome.ok {
            state = .done(text: outcome.text)
            outputView.string = outcome.text
            outputPlaceholder.isHidden = true
            let provider = "匿名通道"
            _ = provider
            let timing = outcome.elapsedMs > 0 ? " · \(outcome.elapsedMs)ms" : ""
            let pieces = outcome.chunks > 1 ? " · \(outcome.chunks) 段" : ""
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "回车复制并关闭\(timing)\(pieces)"
            refreshMode()
            let direction = (outcome.target ?? "").hasPrefix("zh") ? "→ 中文" : "→ English"
            modeLabel.stringValue = "\(direction) · \(hotkeyLabel)"
            window.makeFirstResponder(outputView)
            return
        }

        state = .failed
        let message = outcome.error ?? "翻译失败"
        outputView.string = message + (outcome.detail.map { "\n\n\($0)" } ?? "")
        outputPlaceholder.isHidden = true
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = "按回车重试 · Esc 关闭"
        refreshMode()
        window.makeFirstResponder(inputView)
    }

    // MARK: - 代理

    func textDidChange(_ notification: Notification) {
        inputPlaceholder.isHidden = !inputView.string.isEmpty
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss(restorePrevious: true)
    }

    /// 自测/调试：直接灌一段文本并立刻翻译。
    func fillAndSubmit(text: String) {
        if !window.isVisible {
            present(hostSocket: hostSocket, hotkeyLabel: hotkeyLabel)
        }
        inputView.string = text
        inputPlaceholder.isHidden = true
        submit()
    }
}
