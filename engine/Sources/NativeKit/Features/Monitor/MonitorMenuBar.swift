import AppKit

/// 状态栏上的三个独立控件：网络（上行在上、下行在下）、CPU、内存。
///
/// 每一项都是**两行文字**：上一行标签（`CPU` / `MEM`）或方向箭头（`↑` / `↓`），
/// 下一行数字。菜单栏的按钮高度只有 24pt 左右，两行字必须自己画成一张
/// template 图（`attributedTitle` 换行在 NSStatusItem 上会被压成一行或直接裁掉），
/// 而且宽度固定，避免数字位数变化时按钮跟着变宽、把 popover 的锚点带得来回漂。
final class MonitorMenuBar: NSObject {
    private struct Entry {
        var metric: MonitorMetric
        var item: NSStatusItem
        var top: String
        var bottom: String
    }

    /// 上一行（标签 / 箭头）：字号小一点。
    private static let topFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    /// 下一行（数字）：比之前的单行 10 号更大，读起来不费劲。
    private static let bottomFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
    /// 画布高度：菜单栏厚度约 24pt，留 1pt 余量给按下态。
    private static let imageHeight: CGFloat = 23

    private var entries: [Entry] = []
    /// 图片宽度**跟着文字走**（`variableLength` 下系统按自己的规则加左右内边距，
    /// 三个控件与别的菜单栏图标间距一致）。数字位数变化会让按钮轻微变宽变窄，
    /// 面板不再跟着漂 —— 那是 `MonitorPanelController` 的固定锚点负责的。
    private var settings: MonitorSettings
    var onSelect: ((MonitorMetric, NSStatusBarButton) -> Void)?

    init(settings: MonitorSettings) {
        self.settings = settings
        super.init()
        build()
    }

    deinit {
        removeAll()
    }

    func removeAll() {
        for entry in entries {
            NSStatusBar.system.removeStatusItem(entry.item)
        }
        entries = []
    }

    private func build() {
        removeAll()
        for metric in MonitorMetric.allCases {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
                button.target = self
                button.action = #selector(handleClick(_:))
                button.toolTip = "DSH 原生助手 · \(metric.title)"
            }
            // 长度交给系统（`variableLength`）→ 左右内边距和别的菜单栏图标一模一样；
            // 长度交给系统；数字变化带来的宽度抖动由面板的固定锚点吸收。
            item.isVisible = isEnabled(metric)
            entries.append(
                Entry(metric: metric, item: item, top: "", bottom: "")
            )
        }
    }

    private func isEnabled(_ metric: MonitorMetric) -> Bool {
        switch metric {
        case .network: return settings.showNetwork
        case .cpu: return settings.showCPU
        case .memory: return settings.showMemory
        }
    }

    func apply(settings next: MonitorSettings) {
        // 网络那一项在不显示上行时更窄，结构变了要重建。
        let rebuild = settings.networkDetailed != next.networkDetailed
        settings = next
        if rebuild {
            build()
            return
        }
        for entry in entries {
            entry.item.isVisible = isEnabled(entry.metric)
        }
    }

    func update(totals: MonitorTotals) {
        for index in entries.indices {
            let metric = entries[index].metric
            let lines = MonitorFormat.menuLines(
                metric: metric,
                totals: totals,
                detailed: settings.networkDetailed
            )
            if entries[index].top == lines.top, entries[index].bottom == lines.bottom {
                continue
            }
            entries[index].top = lines.top
            entries[index].bottom = lines.bottom
            entries[index].item.button?.image = Self.image(
                top: lines.top,
                bottom: lines.bottom,
                width: Self.imageWidth(top: lines.top, bottom: lines.bottom)
            )
            entries[index].item.button?.toolTip = Self.tooltip(metric: metric, lines: lines)
        }
    }

    private static func tooltip(metric: MonitorMetric, lines: (top: String, bottom: String)) -> String {
        let detail = lines.top.isEmpty ? lines.bottom : "\(lines.top) \(lines.bottom)"
        return "DSH 原生助手 · \(metric.title) \(detail)"
    }

    // MARK: - 画两行字

    private static func attributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.black]
    }

    private static func textSize(_ text: String, font: NSFont) -> NSSize {
        guard !text.isEmpty else { return .zero }
        return (text as NSString).size(withAttributes: attributes(font: font))
    }

    private static func imageWidth(top: String, bottom: String) -> CGFloat {
        let width = max(
            textSize(top, font: topFont).width,
            textSize(bottom, font: bottomFont).width
        )
        return ceil(width)
    }

    private static func image(top: String, bottom: String, width: CGFloat) -> NSImage {
        let width = max(width, imageWidth(top: top, bottom: bottom))
        let size = NSSize(width: width, height: imageHeight)
        let topAttributes = attributes(font: topFont)
        let bottomAttributes = attributes(font: bottomFont)
        let image = NSImage(size: size, flipped: true) { rect in
            if !top.isEmpty {
                let measured = textSize(top, font: topFont)
                (top as NSString).draw(
                    at: NSPoint(x: (rect.width - measured.width) / 2, y: 0),
                    withAttributes: topAttributes
                )
            }
            let measured = textSize(bottom, font: bottomFont)
            (bottom as NSString).draw(
                at: NSPoint(x: (rect.width - measured.width) / 2, y: rect.height - measured.height),
                withAttributes: bottomAttributes
            )
            return true
        }
        // template：跟着菜单栏的明暗自动反色。
        image.isTemplate = true
        return image
    }

    /// 自测/排查用：每项图片宽度、按钮宽度、item 长度（看「和系统图标间距不一样」是谁的锅）。
    func metrics() -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for entry in entries {
            let image = entry.item.button?.image?.size.width ?? 0
            let frame = entry.item.button?.window?.frame ?? .zero
            result[entry.metric.rawValue] = [
                "imageWidth": Double(image),
                "buttonWidth": Double(frame.width),
                "length": Double(entry.item.length),
            ]
        }
        return result
    }

    /// 文档/自测用：把三项按菜单栏的样子拼成一张位图（深色底 + 白色字），
    /// 不创建真正的 status item，所以可以在自测里安全调用。
    static func stripImage(totals: MonitorTotals, settings: MonitorSettings) -> NSImage? {
        let metrics = MonitorMetric.allCases.filter { metric in
            switch metric {
            case .network: return settings.showNetwork
            case .cpu: return settings.showCPU
            case .memory: return settings.showMemory
            }
        }
        guard !metrics.isEmpty else { return nil }

        let gap: CGFloat = 9
        let inset: CGFloat = 8
        var images: [(NSImage, NSSize)] = []
        var totalWidth = inset * 2 + gap * CGFloat(metrics.count - 1)
        for metric in metrics {
            let lines = MonitorFormat.menuLines(
                metric: metric,
                totals: totals,
                detailed: settings.networkDetailed
            )
            let sample = MonitorFormat.menuWidthSample(metric: metric, detailed: settings.networkDetailed)
            let image = Self.image(
                top: lines.top,
                bottom: lines.bottom,
                width: Self.imageWidth(top: sample.top, bottom: sample.bottom)
            )
            images.append((image, image.size))
            totalWidth += image.size.width
        }
        // 2x：文档里贴出来才清晰（菜单栏截图本身也是 Retina 的 2x）。
        let scale: CGFloat = 2
        let stripSize = NSSize(width: totalWidth * scale, height: (imageHeight + 2) * scale)

        let strip = NSImage(size: stripSize)
        strip.lockFocus()
        NSColor(calibratedWhite: 0.35, alpha: 1).setFill()
        NSRect(origin: .zero, size: stripSize).fill()
        var x = inset * scale
        for (image, size) in images {
            let tinted = NSImage(size: size)
            tinted.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .destinationIn, fraction: 1)
            tinted.unlockFocus()
            let scaled = NSSize(width: size.width * scale, height: size.height * scale)
            tinted.draw(in: NSRect(x: x, y: scale, width: scaled.width, height: scaled.height))
            x += scaled.width + gap * scale
        }
        strip.unlockFocus()
        return strip
    }

    /// 每个控件的屏幕位置（自测用来确认「三个都在屏幕内、宽度固定、没被挤成一行」）。
    func frames() -> [String: [String: Double]] {
        var result: [String: [String: Double]] = [:]
        for entry in entries {
            guard let window = entry.item.button?.window else { continue }
            let frame = window.frame
            result[entry.metric.rawValue] = [
                "x": Double(frame.origin.x),
                "y": Double(frame.origin.y),
                "width": Double(frame.size.width),
                "height": Double(frame.size.height),
                "visible": entry.item.isVisible ? 1 : 0,
            ]
        }
        return result
    }

    /// 自测用：当前三项的「上一行 / 下一行」文本。
    func lines() -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for entry in entries {
            result[entry.metric.rawValue] = ["top": entry.top, "bottom": entry.bottom]
        }
        return result
    }

    func button(for metric: MonitorMetric) -> NSStatusBarButton? {
        entries.first { $0.metric == metric }?.item.button
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let metric = entries.first(where: { $0.item.button === sender })?.metric else { return }
        onSelect?(metric, sender)
    }
}
