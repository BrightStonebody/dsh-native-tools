import AppKit

final class ClipboardPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Alfred-style clipboard panel: history on the left, preview on the right.
final class ClipboardPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate, NSWindowDelegate {
    static let panelSize = NSSize(width: 860, height: 560)
    static let cornerRadius: CGFloat = 14

    private(set) var store: ClipboardStore
    private(set) var previousApp: NSRunningApplication?
    private(set) var hotkeyLabel = "⇧⌘V"

    var onChoose: ((ClipboardItem, Bool) -> Void)?

    private let panel: ClipboardPanelWindow
    private let root = ClipboardRootView()
    /// 底板：真正的毛玻璃（窗口服务器画在窗口背后）。自测会检查它没有被图层裁剪掉。
    private let effect = NSVisualEffectView()
    private var filtered: [ClipboardItem] = []
    private var eventMonitor: Any?

    var isVisible: Bool {
        panel.isVisible
    }

    var selectedItem: ClipboardItem? {
        let row = root.tableView.selectedRow
        guard row >= 0, row < filtered.count else { return nil }
        return filtered[row]
    }

    init(store: ClipboardStore) {
        self.store = store
        panel = ClipboardPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildWindow()
        installKeyMonitor()
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    // MARK: - Construction

    private func buildWindow() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.delegate = self

        let effect = self.effect
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        // 圆角只能交给 maskImage：在 .behindWindow 的毛玻璃上设 layer.cornerRadius +
        // masksToBounds 会把窗口服务器那张模糊底图裁掉，底板退化成一块不透明白色，
        // 四角也照样是方块。maskImage 是窗口服务器认的形状，圆角和模糊都保住。
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        panel.contentView = effect

        root.autoresizingMask = [.width, .height]
        root.frame = NSRect(origin: .zero, size: Self.panelSize)
        effect.addSubview(root)

        let table = root.tableView
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(handleDoubleClick)
        root.searchField.delegate = self

        updateHotkeyLabel(hotkeyLabel)
        updateCount()
    }

    /// 9 宫格拉伸的圆角蒙版：四角保留圆角，中间拉伸。
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// 自测用：底板视图本身，用来确认它还是毛玻璃、没被图层裁剪。
    var effectView: NSVisualEffectView { effect }

    private func installKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else {
                return event
            }
            return self.handleKeyDown(event)
        }
    }

    // MARK: - Presentation

    func show(previousApp: NSRunningApplication?) {
        self.previousApp = previousApp
        root.searchField.stringValue = ""
        store.prune()
        reload(selecting: nil, resetSelection: true)
        updateHotkeyLabel(hotkeyLabel)

        if !root.searchField.isHidden {
            panel.makeFirstResponder(root.searchField)
        }
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(root.searchField)
        root.needsLayout = true
        root.needsDisplay = true
        Log.info("panel shown, \(store.items.count) item(s)")
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        Log.info("panel hidden")
    }

    func dismiss(restorePrevious: Bool) {
        let app = previousApp
        hide()
        if restorePrevious {
            PasteService.activate(app)
        }
    }

    private func positionOnActiveScreen() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = Self.panelSize
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + 30
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    func updateHotkeyLabel(_ label: String) {
        hotkeyLabel = label
        root.hotkeyLabel.stringValue = "\(label) 打开"
        root.needsLayout = true
    }

    // MARK: - Data

    /// 重新加载列表。
    ///
    /// `resetSelection` 为真时忽略上一次的选中行，直接选中第一条 —— 面板每次打开都走这条路：
    /// 用户按热键是想看「最近复制的几条」，所以永远从第一条开始，而不是回到上次停留的那一行
    /// （2026-11-21 反馈：条数多的时候一打开就停在底部并选中最后一条）。
    func reload(selecting id: String? = nil, resetSelection: Bool = false) {
        let previousID = resetSelection ? id : (id ?? selectedItem?.id)
        filtered = store.search(root.searchField.stringValue)
        root.tableView.reloadData()

        if let previousID, let index = filtered.firstIndex(where: { $0.id == previousID }) {
            select(row: index)
        } else if !filtered.isEmpty {
            select(row: 0)
        } else {
            root.tableView.deselectAll(nil)
        }
        if resetSelection {
            scrollToTop()
        }
        updateCount()
        updateEmptyState()
        updateDetail()
    }

    private func applyFilter() {
        let previousID = selectedItem?.id
        filtered = store.search(root.searchField.stringValue)
        root.tableView.reloadData()
        if let previousID, let index = filtered.firstIndex(where: { $0.id == previousID }) {
            select(row: index)
        } else if !filtered.isEmpty {
            select(row: 0)
        } else {
            root.tableView.deselectAll(nil)
        }
        updateCount()
        updateEmptyState()
        updateDetail()
    }

    private func select(row: Int) {
        guard row >= 0, row < filtered.count else { return }
        root.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        root.tableView.scrollRowToVisible(row)
    }

    /// 把列表滚回顶部。`scrollRowToVisible(0)` 在窗口还没上屏时可能算不出行矩形，
    /// 这里再直接把 clip view 的原点归零并通知滚动视图。
    private func scrollToTop() {
        let clip = root.listScroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 0))
        root.listScroll.reflectScrolledClipView(clip)
    }

    private func updateCount() {
        let total = store.items.count
        if root.searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            root.countLabel.stringValue = total == 0 ? "暂无记录" : "\(total) 条记录"
        } else {
            root.countLabel.stringValue = "\(filtered.count) / \(total) 条"
        }
        root.needsLayout = true
    }

    private func updateEmptyState() {
        if !filtered.isEmpty {
            root.emptyLabel.isHidden = true
            return
        }
        root.emptyLabel.isHidden = false
        if store.items.isEmpty {
            root.emptyLabel.stringValue = "还没有剪贴板记录\n复制文字或图片后会出现在这里"
        } else {
            root.emptyLabel.stringValue = "没有匹配的记录\n换个关键词试试"
        }
    }

    private func updateDetail() {
        root.detailView.configure(item: selectedItem, store: store)
    }

    /// Used by the control channel to inspect a specific entry.
    @discardableResult
    func select(id: String) -> Bool {
        guard let row = filtered.firstIndex(where: { $0.id == id }) else { return false }
        select(row: row)
        updateDetail()
        return true
    }

    func debugSelect(row: Int) {
        select(row: row)
        updateDetail()
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
    }

    // MARK: - Keyboard

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let plain = flags.isEmpty || flags == .function

        if command {
            switch event.keyCode {
            case 8: // C
                // Selected text in the detail pane or the search field keeps the
                // normal copy behavior; ⌘C only copies the entry when there is
                // no text selection.
                if let textView = panel.firstResponder as? NSTextView,
                   textView.selectedRange().length > 0 {
                    textView.copy(nil)
                    return nil
                }
                choose(paste: false)
                return nil
            case 51: // Delete
                // ⌘⌫ in a non-empty search field means “delete to line start”,
                // not “destroy the selected history entry”.
                if let textView = panel.firstResponder as? NSTextView,
                   !textView.string.isEmpty {
                    return event
                }
                deleteSelected()
                return nil
            case 3: // F
                panel.makeFirstResponder(root.searchField)
                return nil
            default:
                return event
            }
        }

        switch event.keyCode {
        case 125: // Down
            moveSelection(by: 1)
            return nil
        case 126: // Up
            moveSelection(by: -1)
            return nil
        case 36, 76: // Return / keypad Enter
            if plain {
                choose(paste: true)
                return nil
            }
        case 53: // Escape
            dismiss(restorePrevious: true)
            return nil
        case 51: // Delete (no command) while the table has focus
            if !(panel.firstResponder is NSText) {
                deleteSelected()
                return nil
            }
        default:
            break
        }
        return event
    }

    /// 自测用：当前选中行与滚动位置，用来验证「打开时应该停在顶部并选中第一条」。
    func debugState() -> [String: Any] {
        let table = root.tableView
        let clip = root.listScroll.contentView
        return [
            "rows": filtered.count,
            "selectedRow": table.selectedRow,
            "selectedID": selectedItem?.id ?? "",
            "firstID": filtered.first?.id ?? "",
            "scrollY": Double(clip.bounds.origin.y),
            "docHeight": Double(table.frame.height),
            "visibleHeight": Double(clip.bounds.height),
            "tableFlipped": table.isFlipped,
            "clipFlipped": clip.isFlipped,
        ]
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = root.tableView.selectedRow
        let next: Int
        if current < 0 {
            next = delta > 0 ? 0 : filtered.count - 1
        } else {
            next = min(max(current + delta, 0), filtered.count - 1)
        }
        select(row: next)
    }

    private func choose(paste: Bool) {
        guard let item = selectedItem else {
            NSSound.beep()
            return
        }
        onChoose?(item, paste)
    }

    private func deleteSelected() {
        guard let item = selectedItem else { return }
        let row = root.tableView.selectedRow
        store.delete(id: item.id)
        HUD.show("已删除", symbol: "trash.fill", success: false, duration: 1.0)
        let remaining = store.search(root.searchField.stringValue)
        filtered = remaining
        let target = remaining.isEmpty ? nil : remaining[min(max(row, 0), remaining.count - 1)].id
        reload(selecting: target)
    }

    @objc private func handleDoubleClick() {
        let row = root.tableView.clickedRow
        guard row >= 0, row < filtered.count else { return }
        select(row: row)
        choose(paste: true)
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        58
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipboardRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ClipboardCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ClipboardCellView
            ?? ClipboardCellView(identifier: identifier)
        cell.configure(with: filtered[row], store: store)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === root.searchField else { return }
        applyFilter()
    }

    // MARK: - Window delegate

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        hide()
    }

    // MARK: - Debug snapshots

    @discardableResult
    func snapshot(to directoryPath: String, name: String = "panel.png") -> [String] {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        guard let view = panel.contentView,
              view.bounds.width > 0,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return [] }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return []
        }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try data.write(to: url, options: [.atomic])
            return [url.path]
        } catch {
            Log.error("snapshot failed: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - Root view

private final class ClipboardRootView: NSView {
    let titleLabel = NSTextField(labelWithString: "剪贴板历史")
    let countLabel = NSTextField(labelWithString: "")
    let searchField = NSSearchField()
    let listScroll = NSScrollView()
    let tableView = NSTableView()
    let emptyLabel = NSTextField(wrappingLabelWithString: "")
    let footerLabel = NSTextField(labelWithString: "↑↓ 选择    ⏎ 粘贴    ⌘C 复制    ⌘⌫ 删除    ⎋ 关闭")
    let hotkeyLabel = NSTextField(labelWithString: "")
    let detailView = ClipboardDetailView()

    private let headerBottom: CGFloat = 92
    private let footerTop: CGFloat = 516
    private let leftWidth: CGFloat = 340

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 11.5)
        countLabel.textColor = .secondaryLabelColor

        searchField.placeholderString = "搜索剪贴板历史"
        searchField.font = .systemFont(ofSize: 13)
        searchField.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 328
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.style = .plain
        tableView.focusRingType = .none

        listScroll.documentView = tableView
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.scrollerStyle = .overlay
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.isHidden = true

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        hotkeyLabel.font = .systemFont(ofSize: 11)
        hotkeyLabel.textColor = .tertiaryLabelColor
        hotkeyLabel.alignment = .right

        for view in [titleLabel, countLabel, searchField, listScroll, emptyLabel, footerLabel, hotkeyLabel, detailView] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = bounds.width


        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: 20, y: 13, width: 200, height: 22)
        countLabel.sizeToFit()
        countLabel.frame = NSRect(
            x: titleLabel.frame.maxX + 10,
            y: 19,
            width: max(40, countLabel.frame.width),
            height: 15
        )
        searchField.frame = NSRect(x: 20, y: 46, width: width - 40, height: 30)

        listScroll.frame = NSRect(x: 8, y: 100, width: leftWidth - 12, height: footerTop - 108)
        emptyLabel.frame = NSRect(x: 24, y: 230, width: leftWidth - 48, height: 56)

        detailView.frame = NSRect(
            x: leftWidth + 1,
            y: headerBottom + 1,
            width: width - leftWidth - 1,
            height: footerTop - headerBottom - 1
        )

        footerLabel.frame = NSRect(x: 20, y: footerTop + 12, width: 520, height: 16)
        hotkeyLabel.sizeToFit()
        hotkeyLabel.frame = NSRect(
            x: width - 20 - hotkeyLabel.frame.width,
            y: footerTop + 12,
            width: hotkeyLabel.frame.width,
            height: 16
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: headerBottom, width: bounds.width, height: 1).fill()
        NSRect(x: leftWidth, y: headerBottom, width: 1, height: footerTop - headerBottom).fill()
        NSRect(x: 0, y: footerTop, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Row

private final class ClipboardRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.26).setFill()
        path.fill()
    }
}

private final class ClipboardCellView: NSTableCellView {
    /// Flipped so the title sits above the secondary line, matching every
    /// macOS list and Alfred's clipboard history.
    override var isFlipped: Bool { true }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let thumbView = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 7
        iconView.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true

        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 5
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.35).cgColor

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(metaLabel)
        addSubview(thumbView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 12, y: 13, width: 32, height: 32)
        let textWidth: CGFloat = thumbView.isHidden ? 272 : 204
        titleLabel.frame = NSRect(x: 52, y: 10, width: textWidth, height: 17)
        metaLabel.frame = NSRect(x: 52, y: 29, width: textWidth, height: 14)
        thumbView.frame = NSRect(x: 264, y: 11, width: 50, height: 36)
    }

    func configure(with item: ClipboardItem, store: ClipboardStore) {
        titleLabel.stringValue = item.title
        metaLabel.stringValue = item.metaText()

        if let bundleID = item.sourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            iconView.image = icon
            iconView.contentTintColor = nil
        } else {
            let symbol = item.kind == .image ? "photo" : "doc.text"
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            iconView.contentTintColor = .secondaryLabelColor
        }

        if item.kind == .image,
           let url = store.thumbURL(for: item),
           let thumb = NSImage(contentsOf: url) {
            thumbView.image = thumb
            thumbView.isHidden = false
        } else {
            thumbView.image = nil
            thumbView.isHidden = true
        }
        needsLayout = true
    }
}

// MARK: - Detail

private final class ClipboardDetailView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let textScroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "选择左侧的条目查看详情")

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 8
        iconView.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        metaLabel.font = .systemFont(ofSize: 11.5)
        metaLabel.textColor = .secondaryLabelColor
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.scrollerStyle = .overlay
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.wantsLayer = true
        textScroll.layer?.cornerRadius = 10
        textScroll.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.65).cgColor
        textScroll.layer?.borderWidth = 1
        textScroll.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.50).cgColor
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor

        for view in [iconView, titleLabel, metaLabel, sizeLabel, textScroll, imageView, emptyLabel] {
            addSubview(view)
        }
        showEmpty()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height

        iconView.frame = NSRect(x: 18, y: 18, width: 36, height: 36)
        titleLabel.frame = NSRect(x: 66, y: 16, width: 240, height: 20)
        metaLabel.frame = NSRect(x: 66, y: 38, width: 280, height: 15)
        sizeLabel.frame = NSRect(x: width - 218, y: 20, width: 200, height: 15)

        let body = NSRect(x: 18, y: 74, width: width - 36, height: height - 92)
        textScroll.frame = body
        imageView.frame = body
        emptyLabel.frame = NSRect(x: 24, y: body.midY - 20, width: width - 48, height: 20)

        if textView.frame.width != body.width {
            textView.frame = NSRect(x: 0, y: 0, width: body.width, height: body.height)
        }
    }

    func configure(item: ClipboardItem?, store: ClipboardStore) {
        guard let item else {
            showEmpty()
            return
        }

        iconView.isHidden = false
        titleLabel.isHidden = false
        metaLabel.isHidden = false
        sizeLabel.isHidden = false
        emptyLabel.isHidden = true

        titleLabel.stringValue = item.kind == .text ? "纯文本" : "图片"
        var meta: [String] = []
        if let source = item.sourceName, !source.isEmpty {
            meta.append("来自 \(source)")
        }
        meta.append(ClipboardStore.relativeTime(item.copiedDate))
        metaLabel.stringValue = meta.joined(separator: " · ")
        sizeLabel.stringValue = item.sizeText

        if let bundleID = item.sourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 36, height: 36)
            iconView.image = icon
            iconView.contentTintColor = nil
        } else {
            let symbol = item.kind == .image ? "photo" : "doc.text"
            let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            iconView.contentTintColor = .secondaryLabelColor
        }

        if item.kind == .text {
            textScroll.isHidden = false
            imageView.isHidden = true
            imageView.image = nil
            textView.string = item.text ?? ""
            textView.enclosingScrollView?.contentView.scroll(to: .zero)
            if let clip = textView.enclosingScrollView?.contentView {
                textView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        } else {
            textScroll.isHidden = true
            imageView.isHidden = false
            if let url = store.imageURL(for: item) {
                imageView.image = NSImage(contentsOf: url)
            } else {
                imageView.image = nil
            }
        }
        needsLayout = true
    }

    private func showEmpty() {
        iconView.isHidden = true
        titleLabel.isHidden = true
        metaLabel.isHidden = true
        sizeLabel.isHidden = true
        textScroll.isHidden = true
        imageView.isHidden = true
        emptyLabel.isHidden = false
    }
}
