import AppKit

/// Editable transcription card: what Vision read out of the selection, with a
/// copy button. Sits in the same slot as the action bar (under the selection),
/// so only one of the two is visible at a time.
final class OCRPanelView: NSView {
    enum Metrics {
        static let padding: CGFloat = 12
        static let footerHeight: CGFloat = 30
        static let height: CGFloat = 208
        static let minWidth: CGFloat = 320
        static let maxWidth: CGFloat = 560
        static let cornerRadius: CGFloat = 12
        static let gapToSelection: CGFloat = 10
        static let buttonHeight: CGFloat = 26
    }

    var onCopy: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let textView = OCRTextView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let copyButton = PanelTextButton(title: "复制文字", primary: true)
    private let closeButton = PanelTextButton(title: "关闭", primary: false)

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textView.setSelectedRange(NSRange(location: newValue.utf16.count, length: 0))
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cornerRadius
        layer?.masksToBounds = true

        textView.font = NSFont.systemFont(ofSize: 12.5)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.onEscape = { [weak self] in self?.onClose?() }
        textView.onCommandReturn = { [weak self] in
            guard let self else { return }
            self.onCopy?(self.textView.string)
        }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        addSubview(scrollView)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        copyButton.onTap = { [weak self] in
            guard let self else { return }
            self.onCopy?(self.textView.string)
        }
        closeButton.onTap = { [weak self] in self?.onClose?() }
        addSubview(copyButton)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused")
    }

    override var isFlipped: Bool { false }

    /// Placeholder shown while Vision is still working.
    func showBusy() {
        text = ""
        textView.isEditable = false
        statusLabel.stringValue = "正在识别…"
        needsLayout = true
    }

    func show(result: RecognizedText?) {
        textView.isEditable = true
        guard let result, !result.isEmpty else {
            text = ""
            statusLabel.stringValue = "没有识别到文字"
            needsLayout = true
            return
        }
        text = result.text
        statusLabel.stringValue = "\(result.lineCount) 行 · \(result.characterCount) 字 · \(result.milliseconds) ms"
        needsLayout = true
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    override func layout() {
        super.layout()
        let inset = Metrics.padding
        let footerY = inset - 4
        let scrollHeight = bounds.height - footerY - Metrics.footerHeight - 4
        scrollView.frame = NSRect(
            x: inset,
            y: footerY + Metrics.footerHeight,
            width: bounds.width - inset * 2,
            height: max(0, scrollHeight)
        )
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: scrollView.contentSize.width, height: scrollView.contentSize.height)
        )

        let buttonY = footerY + (Metrics.footerHeight - Metrics.buttonHeight) / 2
        let closeWidth = closeButton.preferredWidth()
        let copyWidth = copyButton.preferredWidth()
        var x = bounds.width - inset
        x -= closeWidth
        closeButton.frame = NSRect(x: x, y: buttonY, width: closeWidth, height: Metrics.buttonHeight)
        x -= 8 + copyWidth
        copyButton.frame = NSRect(x: x, y: buttonY, width: copyWidth, height: Metrics.buttonHeight)

        statusLabel.frame = NSRect(
            x: inset,
            y: buttonY + 1,
            width: max(0, x - inset - 10),
            height: 18
        )
    }

    /// Under the selection when it fits, above it otherwise, always inside the
    /// screen with a margin.
    func frame(forSelection selection: CGRect, in container: CGRect) -> NSRect {
        let margin: CGFloat = 8
        let width = min(
            max(selection.width, Metrics.minWidth),
            min(Metrics.maxWidth, container.width - margin * 2)
        )
        let height = min(Metrics.height, container.height - margin * 2)
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
        NSColor(calibratedWhite: 0.97, alpha: 0.985).setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        ).fill()
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

/// Text view that gives the panel its Esc / ⌘⏎ shortcuts back.
final class OCRTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Small pill button for the transcription card.
final class PanelTextButton: NSView {
    enum Metrics {
        static let height: CGFloat = 26
        static let horizontalPadding: CGFloat = 12
        static let cornerRadius: CGFloat = 7
        static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    }

    let title: String
    private let isPrimary: Bool
    private var hovered = false
    private var trackingAreaRef: NSTrackingArea?
    private var titleSize: NSSize = .zero

    var onTap: (() -> Void)?

    init(title: String, primary: Bool) {
        self.title = title
        self.isPrimary = primary
        super.init(frame: .zero)
        titleSize = (title as NSString).size(withAttributes: [.font: Metrics.font])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused")
    }

    override var isFlipped: Bool { false }

    func preferredWidth() -> CGFloat {
        ceil(titleSize.width) + Metrics.horizontalPadding * 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
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
        onTap?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor
        let foreground: NSColor
        if isPrimary {
            background = hovered
                ? NSColor(srgbRed: 0.10, green: 0.44, blue: 0.86, alpha: 1)
                : NSColor(srgbRed: 0.13, green: 0.49, blue: 0.92, alpha: 1)
            foreground = .white
        } else {
            background = NSColor(calibratedWhite: 0, alpha: hovered ? 0.14 : 0.08)
            foreground = NSColor(calibratedWhite: 0.2, alpha: 1)
        }
        background.setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        ).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Metrics.font,
            .foregroundColor: foreground,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            ),
            withAttributes: attributes
        )
    }
}
