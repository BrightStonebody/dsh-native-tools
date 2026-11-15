import AppKit

/// Rounded action bar that appears under the selection, mirroring the menu
/// bar of mainstream macOS screenshot tools.
final class ToolbarView: NSView {
    enum Action {
        case annotate
        case text
        case save
        case copy
        case cancel
    }

    enum Metrics {
        static let height: CGFloat = 46
        static let padding: CGFloat = 10
        static let buttonSize: CGFloat = 34
        static let buttonGap: CGFloat = 2
        static let sectionGap: CGFloat = 8
        static let cornerRadius: CGFloat = 12
        static let gapToSelection: CGFloat = 10
        static let sizeLabelWidth: CGFloat = 82
        static let sizeLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    var onAction: ((Action) -> Void)?

    /// 从左到右的按钮顺序，自测用来盯版面（复制压在最后、取消在它左边）。
    var actionOrder: [Action] { buttons.map(\.action) }

    private let sizeLabel = NSTextField(labelWithString: "")
    private let buttons: [ToolButtonView]
    private var separator: NSView?

    var sizeText: String = "" {
        didSet {
            sizeLabel.stringValue = sizeText
            needsLayout = true
        }
    }

    var isAnnotating: Bool = false {
        didSet {
            for button in buttons where button.action == .annotate {
                button.isActive = isAnnotating
            }
        }
    }

    override init(frame frameRect: NSRect) {
        // 从左到右：编辑类动作 → 保存 → 取消 → 复制（主操作压在最右端收尾）。
        buttons = [
            ToolButtonView(action: .annotate, symbolName: "square.dashed", tooltip: "加红框（⌘R）", fallback: "框"),
            ToolButtonView(action: .text, symbolName: "text.viewfinder", tooltip: "识别文字（⌘T）", fallback: "文"),
            ToolButtonView(action: .save, symbolName: "square.and.arrow.down", tooltip: "保存图片（⌘S）", fallback: "存"),
            ToolButtonView(action: .cancel, symbolName: "xmark", tooltip: "取消（Esc）", fallback: "✕"),
            ToolButtonView(
                action: .copy,
                symbolName: "doc.on.clipboard",
                tooltip: "复制到剪贴板（⏎）",
                fallback: "确",
                style: .primary
            ),
        ]
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.masksToBounds = true

        sizeLabel.font = Metrics.sizeLabelFont
        sizeLabel.textColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        sizeLabel.alignment = .center
        addSubview(sizeLabel)

        let separatorView = NSView()
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.12).cgColor
        addSubview(separatorView)
        separator = separatorView

        for button in buttons {
            button.onTap = { [weak self] action in
                if action == .annotate {
                    self?.isAnnotating.toggle()
                }
                self?.onAction?(action)
            }
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused")
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// Total width for the current state.
    func preferredWidth() -> CGFloat {
        Metrics.padding * 2
            + Metrics.sizeLabelWidth
            + Metrics.sectionGap
            + CGFloat(buttons.count) * Metrics.buttonSize
            + CGFloat(buttons.count - 1) * Metrics.buttonGap
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x = Metrics.padding
        sizeLabel.frame = NSRect(x: x, y: (height - 16) / 2, width: Metrics.sizeLabelWidth, height: 16)
        x += Metrics.sizeLabelWidth + Metrics.sectionGap / 2
        let separatorX = x
        separator?.frame = NSRect(x: separatorX, y: 10, width: 1, height: height - 20)
        x += Metrics.sectionGap / 2
        let buttonY = (height - Metrics.buttonSize) / 2
        for button in buttons {
            button.frame = NSRect(x: x, y: buttonY, width: Metrics.buttonSize, height: Metrics.buttonSize)
            x += Metrics.buttonSize + Metrics.buttonGap
        }
    }

    /// Places the bar under the selection, above it when there is no room, and
    /// always inside `container` with a margin.
    func frame(forSelection selection: CGRect, in container: CGRect) -> NSRect {
        let width = preferredWidth()
        let height = Metrics.height
        let margin: CGFloat = 8
        var originX = selection.midX - width / 2
        originX = min(max(originX, container.minX + margin), container.maxX - width - margin)
        var originY = selection.minY - Metrics.gapToSelection - height
        if originY < container.minY + margin {
            originY = selection.maxY + Metrics.gapToSelection
        }
        originY = min(max(originY, container.minY + margin), container.maxY - height - margin)
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.97, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius).fill()
        NSColor(calibratedWhite: 0, alpha: 0.12).setStroke()
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        border.lineWidth = 1
        border.stroke()
    }
}

/// One icon button of the action bar.
final class ToolButtonView: NSView {
    enum Style {
        case normal
        case primary
    }

    enum Metrics {
        static let cornerRadius: CGFloat = 8
        static let iconSize: CGFloat = 15
    }

    /// SF Symbols fill different fractions of a same-size canvas (`xmark` is a
    /// thin cross, `doc.on.clipboard` is a solid page). Scaling the point size
    /// per symbol equalises the drawn mass, so the row reads as one set instead
    /// of four different sizes.
    private var opticalScale: CGFloat {
        switch symbolName {
        case "xmark": return 1.08
        case "square.and.arrow.down": return 1.04
        case "square.dashed": return 1.06
        case "text.viewfinder": return 1.06
        case "doc.on.clipboard": return 1.00
        default: return 1
        }
    }

    let action: ToolbarView.Action
    private let symbolName: String
    private let fallbackGlyph: String
    private let style: Style
    private var hovered = false
    private var trackingAreaRef: NSTrackingArea?

    var onTap: ((ToolbarView.Action) -> Void)?

    var isActive: Bool = false {
        didSet { needsDisplay = true }
    }

    init(
        action: ToolbarView.Action,
        symbolName: String,
        tooltip: String,
        fallback: String,
        style: Style = .normal
    ) {
        self.action = action
        self.symbolName = symbolName
        self.fallbackGlyph = fallback
        self.style = style
        super.init(frame: .zero)
        self.toolTip = tooltip
        setAccessibilityLabel(tooltip)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused")
    }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onTap?(action)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor?
        let foreground: NSColor
        switch style {
        case .primary:
            background = hovered
                ? NSColor(srgbRed: 0.10, green: 0.44, blue: 0.86, alpha: 1)
                : NSColor(srgbRed: 0.13, green: 0.49, blue: 0.92, alpha: 1)
            foreground = .white
        case .normal:
            if isActive {
                background = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.16)
                foreground = NSColor(srgbRed: 0.85, green: 0.15, blue: 0.12, alpha: 1)
            } else if hovered {
                background = NSColor(calibratedWhite: 0, alpha: 0.10)
                foreground = NSColor(calibratedWhite: 0.12, alpha: 1)
            } else {
                background = nil
                foreground = NSColor(calibratedWhite: 0.22, alpha: 1)
            }
        }
        if let background {
            background.setFill()
            let cell = style == .primary ? bounds.insetBy(dx: 1, dy: 1) : bounds
            NSBezierPath(
                roundedRect: cell,
                xRadius: Metrics.cornerRadius,
                yRadius: Metrics.cornerRadius
            ).fill()
        }

        let configuration = NSImage.SymbolConfiguration(
            pointSize: Metrics.iconSize * opticalScale,
            weight: style == .primary ? .semibold : .medium
        )
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let tinted = image.tinted(with: foreground)
            let size = tinted.size
            let rect = NSRect(
                x: (bounds.midX - size.width / 2).rounded(),
                y: (bounds.midY - size.height / 2).rounded(),
                width: size.width,
                height: size.height
            )
            tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: foreground,
            ]
            let text = fallbackGlyph as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }

        if isActive {
            NSColor(srgbRed: 0.85, green: 0.15, blue: 0.12, alpha: 1).setStroke()
            let outline = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                xRadius: Metrics.cornerRadius,
                yRadius: Metrics.cornerRadius
            )
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }
}

extension NSImage {
    /// Recolours a template symbol image.
    func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.isTemplate = false
        return result
    }
}
