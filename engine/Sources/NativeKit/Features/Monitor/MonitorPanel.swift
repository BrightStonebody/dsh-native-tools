import AppKit

/// 点击菜单栏图标弹出的进程排名面板。自己绘制行（不做选择，不需要
/// NSTableView 的那套 delegate），这样 8 行以内完全够用且不会闪烁。
final class MonitorPanelView: NSView {
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 20
    static let padding: CGFloat = 14
    static let width: CGFloat = 400

    var metric: MonitorMetric = .cpu {
        didSet { needsDisplay = true }
    }
    var rows: [MonitorRow] = [] {
        didSet { needsDisplay = true }
    }
    var subtitle: String = "" {
        didSet { needsDisplay = true }
    }
    /// 固定留这么多行的高度：面板高度不随「这拍有几个进程」变化，
    /// 否则 NSPopover 每拍都重设 contentSize，视觉上就像面板在往左下漂。
    var slotCount: Int = 8 {
        didSet { needsDisplay = true }
    }

    var contentHeight: CGFloat {
        Self.headerHeight + CGFloat(max(slotCount, 1)) * Self.rowHeight + Self.footerHeight
    }

    override var isFlipped: Bool { true }

    static func valueText(for row: MonitorRow, metric: MonitorMetric) -> String {
        switch metric {
        case .cpu:
            return MonitorFormat.percent(row.cpuPercent)
        case .memory:
            return MonitorFormat.bytes(row.memoryBytes)
        case .network:
            return "↓\(MonitorFormat.compactRate(row.downPerSecond)) ↑\(MonitorFormat.compactRate(row.upPerSecond))"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let width = bounds.width
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        (metric.panelTitle as NSString).draw(
            at: NSPoint(x: Self.padding, y: 12),
            withAttributes: titleAttributes
        )
        if !subtitle.isEmpty {
            (subtitle as NSString).draw(
                at: NSPoint(x: Self.padding, y: 31),
                withAttributes: subtitleAttributes
            )
        }

        if rows.isEmpty {
            ("正在采样…" as NSString).draw(
                at: NSPoint(x: Self.padding, y: Self.headerHeight + 6),
                withAttributes: subtitleAttributes
            )
            return
        }

        let rankLeft = Self.padding
        let iconSide: CGFloat = 16
        let iconLeft = rankLeft + 12
        let nameLeft = iconLeft + iconSide + 6
        let nameWidth: CGFloat = 150
        let barLeft = nameLeft + nameWidth + 8
        let valueWidth: CGFloat = metric == .network ? 96 : 92

        // 同名进程（Chrome 的多个 helper）只显示名字会分不清，重复的补上 pid。
        var nameCounts: [String: Int] = [:]
        for row in rows { nameCounts[row.name, default: 0] += 1 }
        let barWidth = max(40, width - barLeft - valueWidth - Self.padding)
        let maximum = max(rows.map { $0.load(for: metric) }.max() ?? 1, 0.0001)

        var y = Self.headerHeight
        for (index, row) in rows.enumerated() {
            if index % 2 == 1 {
                NSColor.labelColor.withAlphaComponent(0.035).setFill()
                NSRect(x: 6, y: y, width: width - 12, height: Self.rowHeight).fill()
            }

            let rank = "\(index + 1)"
            (rank as NSString).draw(
                at: NSPoint(x: rankLeft, y: y + 6),
                withAttributes: captionAttributes
            )

            // 进程归属的 App 图标；拿不到就留白，名字列位置保持不变。
            if let icon = row.icon {
                icon.draw(
                    in: NSRect(x: iconLeft, y: y + (Self.rowHeight - iconSide) / 2, width: iconSide, height: iconSide),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }

            let nameParagraph = NSMutableParagraphStyle()
            // 中间截断：`DeepSeek Harness Helper (Renderer)` 这类名字要留住尾巴才有区分度。
            nameParagraph.lineBreakMode = .byTruncatingMiddle
            let nameAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: nameParagraph,
            ]
            let displayName = (nameCounts[row.name] ?? 0) > 1
                ? "\(row.name) ·\(row.pid)"
                : row.name
            (displayName as NSString).draw(
                in: NSRect(x: nameLeft, y: y + 4, width: nameWidth, height: 16),
                withAttributes: nameAttributes
            )

            // 相对最高值画一条比例条，排序一眼能看出来。
            let fraction = min(1, max(0, row.load(for: metric) / maximum))
            let trackHeight: CGFloat = 6
            let trackY = y + (Self.rowHeight - trackHeight) / 2
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: barLeft, y: trackY, width: barWidth, height: trackHeight),
                xRadius: trackHeight / 2,
                yRadius: trackHeight / 2
            ).fill()
            if fraction > 0 {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: barLeft, y: trackY, width: max(trackHeight, barWidth * fraction), height: trackHeight),
                    xRadius: trackHeight / 2,
                    yRadius: trackHeight / 2
                ).fill()
            }

            let valueParagraph = NSMutableParagraphStyle()
            valueParagraph.alignment = .right
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: valueParagraph,
            ]
            (Self.valueText(for: row, metric: metric) as NSString).draw(
                in: NSRect(x: width - Self.padding - valueWidth, y: y + 5, width: valueWidth, height: 16),
                withAttributes: valueAttributes
            )

            y += Self.rowHeight
        }

        ("即时值 · 每秒刷新 · CPU 100% = 一个核心" as NSString).draw(
            at: NSPoint(x: Self.padding, y: y + 2),
            withAttributes: captionAttributes
        )
    }
}

/// 持有 popover，负责显示/隐藏与内容刷新。
final class MonitorPanelController {
    private let popover = NSPopover()
    private let view = MonitorPanelView()
    private(set) var visibleMetric: MonitorMetric?

    /// 面板的锚点：一个看不见的 1×1 无边框窗口，显示时钉在按钮**当时的屏幕位置**。
    ///
    /// 为什么不用按钮本身当锚点：菜单栏按钮的宽度会跟着数字位数变（`9%` → `100%`），
    /// 相邻项变宽也会把它挤动，popover 锚在按钮上就会跟着一起挪 —— 用户看到的
    /// 「面板过一会儿往左下漂」就是这个。锚点窗口自己不动，按钮怎么变面板都不动。
    private let anchorWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        return window
    }()
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

    init() {
        let controller = NSViewController()
        controller.view = view
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        anchorWindow.contentView = anchorView
    }

    var isVisible: Bool { popover.isShown }

    /// 面板窗口在屏幕上的位置（自测用：盯「会不会自己往左下漂」）。
    func frame() -> [String: Double] {
        guard let window = view.window else { return [:] }
        let frame = window.frame
        return [
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "width": Double(frame.size.width),
            "height": Double(frame.size.height),
        ]
    }

    /// 面板高度按「最多显示多少行」定死，行数变化不再改变面板尺寸。
    func setSlotCount(_ count: Int) {
        view.slotCount = max(1, count)
    }

    func show(metric: MonitorMetric, from button: NSStatusBarButton, rows: [MonitorRow], subtitle: String) {
        visibleMetric = metric
        view.metric = metric
        view.rows = rows
        view.subtitle = subtitle
        resize()
        if let screen = Self.screenRect(of: button) {
            anchorWindow.setFrame(
                NSRect(x: screen.midX - 0.5, y: screen.minY, width: 1, height: 1),
                display: false
            )
            anchorWindow.orderFront(nil)
        }
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    /// 按钮在屏幕坐标系里的矩形（用它算锚点位置，之后按钮再动也不影响）。
    private static func screenRect(of button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func apply(rows: [MonitorRow], subtitle: String) {
        guard popover.isShown else { return }
        view.rows = rows
        view.subtitle = subtitle
        resize()
    }

    func hide() {
        guard popover.isShown else { return }
        popover.performClose(nil)
        anchorWindow.orderOut(nil)
        visibleMetric = nil
    }

    func toggle(metric: MonitorMetric, from button: NSStatusBarButton, rows: [MonitorRow], subtitle: String) {
        if popover.isShown, visibleMetric == metric {
            hide()
            return
        }
        if popover.isShown { popover.performClose(nil) }
        show(metric: metric, from: button, rows: rows, subtitle: subtitle)
    }

    /// NSPopover 的箭头区会占掉一条边（`preferredEdge: .minY` 时在顶部），
    /// 内容会被整体往下推这么多，底部就会吃掉最后一行页脚，所以补一段等高的余量。
    private static let popoverSlack: CGFloat = 22

    private func resize() {
        let size = NSSize(
            width: MonitorPanelView.width,
            height: view.contentHeight + Self.popoverSlack
        )
        guard popover.contentSize != size else { return }
        view.frame = NSRect(origin: .zero, size: size)
        popover.contentSize = size
    }

    /// 自测/文档用：按给定指标与行渲染一张位图（不弹窗）。popover 本身是毛玻璃，
    /// 所以借一个离屏窗口当不透明底，再缓存视图。
    func snapshotImage(
        metric: MonitorMetric,
        rows: [MonitorRow],
        subtitle: String,
        size: NSSize? = nil
    ) -> NSBitmapImageRep? {
        visibleMetric = metric
        view.metric = metric
        view.rows = rows
        view.subtitle = subtitle
        let resolved = size ?? NSSize(width: MonitorPanelView.width, height: view.contentHeight)
        view.frame = NSRect(origin: .zero, size: resolved)

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        defer {
            window.contentView = nil
            window.close()
        }
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }
}
