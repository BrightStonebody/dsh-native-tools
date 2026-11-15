import AppKit
import CoreGraphics

/// Borderless, screen-filling window that hosts one frozen display.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // 默认的 .documentWindow 会让窗口淡入淡出（整屏一层遮罩，看起来像"闪一下灰"）。
        // 截图遮罩必须是瞬间盖上去的：没有任何过渡动画。
        animationBehavior = .none
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

protocol SelectionViewDelegate: AnyObject {
    func selectionViewDidConfirm(_ view: SelectionView)
    func selectionViewDidRequestSave(_ view: SelectionView)
    /// ⌥⏎ or the transcription card's copy button: text only, no picture.
    func selectionView(_ view: SelectionView, didCopyText text: String)
    func selectionViewDidCancel(_ view: SelectionView)
}

/// Draws the frozen frame, the selection mask, annotations and the action bar.
final class SelectionView: NSView {
    enum Phase {
        case idle
        case dragging
        case selected
    }

    enum Metrics {
        static let maskAlpha: CGFloat = 0.34
        static let borderWidth: CGFloat = 1
        static let minimumSelection: CGFloat = 4
        static let minimumAnnotation: CGFloat = 6
        static let annotationLineWidth: CGFloat = 3
        static let hintBottomInset: CGFloat = 64
    }

    let shot: ScreenShot
    weak var delegate: SelectionViewDelegate?

    private(set) var phase: Phase = .idle
    private(set) var selectionRect: CGRect = .zero
    /// Annotation rectangles in view coordinates (bottom-left origin).
    private(set) var annotations: [CGRect] = []
    private(set) var annotating = false

    private var dragOrigin: CGPoint = .zero
    private var annotationOrigin: CGPoint?
    private var pendingAnnotation: CGRect = .zero
    private var mouseLocation: CGPoint?
    private var trackingAreaRef: NSTrackingArea?
    private lazy var toolbar: ToolbarView = makeToolbar()
    private lazy var ocrPanel: OCRPanelView = makeOCRPanel()
    private var recognizing = false
    /// Text already read out of this selection, to answer a second ⌘T without
    /// running Vision again.
    private var recognizedText: String?

    init(shot: ScreenShot) {
        self.shot = shot
        super.init(frame: NSRect(origin: .zero, size: shot.screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unused")
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var toolbarView: ToolbarView? {
        toolbar.superview == nil ? nil : toolbar
    }

    var pixelSizeText: String {
        let scale = shot.scale
        return "\(Int((selectionRect.width * scale).rounded())) × \(Int((selectionRect.height * scale).rounded()))"
    }

    // MARK: - Presentation

    /// Shows the bar under the selection once the drag finished.
    func showToolbar() {
        toolbar.sizeText = pixelSizeText
        toolbar.isAnnotating = annotating
        if toolbar.superview == nil {
            addSubview(toolbar)
        }
        toolbar.isHidden = false
        toolbar.frame = toolbar.frame(forSelection: selectionRect, in: bounds)
        toolbar.needsDisplay = true
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func hideToolbar() {
        toolbar.isHidden = true
    }

    // MARK: - Transcription card

    var isShowingOCRPanel: Bool {
        ocrPanel.superview != nil && !ocrPanel.isHidden
    }

    /// Recognises the selection (annotations excluded — red boxes would only
    /// confuse the recogniser) and shows the editable result card.
    func showOCRPanel() {
        guard phase == .selected, selectionRect.width >= Metrics.minimumSelection else { return }
        hideToolbar()
        if ocrPanel.superview == nil {
            addSubview(ocrPanel)
        }
        ocrPanel.isHidden = false
        ocrPanel.frame = ocrPanel.frame(forSelection: selectionRect, in: bounds)
        ocrPanel.showBusy()
        ocrPanel.needsDisplay = true
        ocrPanel.focus()
        needsDisplay = true
        startRecognition { [weak self] result in
            guard let self, self.isShowingOCRPanel else { return }
            self.ocrPanel.show(result: result)
            self.ocrPanel.focus()
        }
    }

    func hideOCRPanel() {
        guard ocrPanel.superview != nil else { return }
        ocrPanel.isHidden = true
        showToolbar()
        // The text view took focus; give it back so ⏎ / ⌘T keep working.
        window?.makeFirstResponder(self)
    }

    /// ⌥⏎ fast path: read the text and hand it straight to the pasteboard.
    func copyRecognizedText() {
        guard phase == .selected else { return }
        if let recognizedText, !recognizedText.isEmpty {
            delegate?.selectionView(self, didCopyText: recognizedText)
            return
        }
        startRecognition { [weak self] result in
            guard let self, let text = result?.text, !text.isEmpty else { return }
            self.recognizedText = text
            self.delegate?.selectionView(self, didCopyText: text)
        }
    }

    private func startRecognition(completion: @escaping (RecognizedText?) -> Void) {
        guard !recognizing else {
            Log.error("ocr: already recognizing")
            return
        }
        guard let image = plainImage() else {
            Log.error("ocr: no image for selection \(selectionRect)")
            return
        }
        recognizing = true
        TextRecognition.recognize(
            image: image,
            keepLineBreaks: settingsKeepLineBreaks,
            languages: TextRecognition.languages(for: settingsOCRLanguages)
        ) { [weak self] result in
            guard let self else { return }
            self.recognizing = false
            if let text = result?.text, !text.isEmpty {
                self.recognizedText = text
            }
            completion(result)
        }
    }

    /// The crop without annotations, at native pixel size.
    private func plainImage() -> CGImage? {
        ImageOutput.compose(shot: shot, cropRect: selectionRect, annotations: [])
    }

    /// Pushed by the plugin through the control channel.
    var settingsOCRLanguages: String = "auto"
    var settingsKeepLineBreaks: Bool = true

    func setAnnotating(_ value: Bool) {
        annotating = value
        if toolbar.superview != nil {
            toolbar.isAnnotating = value
        }
        pendingAnnotation = .zero
        annotationOrigin = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func undoAnnotation() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        needsDisplay = true
    }

    /// Crops the frozen frame and stamps annotations, coordinates already
    /// translated to selection-local points.
    func composedImage() -> CGImage? {
        let local = annotations.map {
            CGRect(
                x: $0.minX - selectionRect.minX,
                y: $0.minY - selectionRect.minY,
                width: $0.width,
                height: $0.height
            )
        }
        return ImageOutput.compose(shot: shot, cropRect: selectionRect, annotations: local)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let frameImage = NSImage(cgImage: shot.image, size: bounds.size)
        frameImage.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )

        if phase == .idle {
            NSColor(calibratedWhite: 0, alpha: 0.28).setFill()
            bounds.fill()
            drawCrosshair()
            drawHint()
            return
        }

        drawMask()
        drawSelectionBorder()
        for annotation in annotations {
            drawAnnotation(annotation)
        }
        if annotationOrigin != nil {
            drawAnnotation(pendingAnnotation)
        }
        if phase == .dragging {
            drawSizeBadge()
        }
    }

    private func drawMask() {
        let mask = NSBezierPath(rect: bounds)
        mask.append(NSBezierPath(rect: selectionRect))
        mask.windingRule = .evenOdd
        NSColor(calibratedWhite: 0, alpha: Metrics.maskAlpha).setFill()
        mask.fill()
    }

    private func drawSelectionBorder() {
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = Metrics.borderWidth
        NSColor(calibratedWhite: 1, alpha: 0.95).setStroke()
        border.stroke()
    }

    private func drawAnnotation(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(rect: rect.insetBy(dx: Metrics.annotationLineWidth / 2, dy: Metrics.annotationLineWidth / 2))
        path.lineWidth = Metrics.annotationLineWidth
        path.lineJoinStyle = .miter
        NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1).setStroke()
        path.stroke()
    }

    private func drawCrosshair() {
        guard let point = mouseLocation else { return }
        let horizontal = NSBezierPath()
        horizontal.move(to: NSPoint(x: bounds.minX, y: point.y))
        horizontal.line(to: NSPoint(x: bounds.maxX, y: point.y))
        let vertical = NSBezierPath()
        vertical.move(to: NSPoint(x: point.x, y: bounds.minY))
        vertical.line(to: NSPoint(x: point.x, y: bounds.maxY))
        for path in [horizontal, vertical] {
            path.lineWidth = 1
            NSColor(calibratedWhite: 0, alpha: 0.45).setStroke()
            path.stroke()
            NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
    }

    private func drawHint() {
        let text = "拖动框选区域　·　⏎ 复制　·　⌘T 识别文字　·　⌘S 保存　·　Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 9
        let width = textSize.width + horizontalPadding * 2
        let height = textSize.height + verticalPadding * 2
        let rect = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.minY + Metrics.hintBottomInset,
            width: width,
            height: height
        )
        NSColor(calibratedWhite: 0, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        string.draw(
            at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func drawSizeBadge() {
        let text = pixelSizeText
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        let width = textSize.width + 16
        let height = textSize.height + 8
        let anchor = CGPoint(x: selectionRect.minX, y: selectionRect.maxY + 8)
        var rect = NSRect(x: anchor.x, y: anchor.y, width: width, height: height)
        rect.origin.x = min(max(rect.minX, bounds.minX + 4), bounds.maxX - width - 4)
        rect.origin.y = min(max(rect.minY, bounds.minY + 4), bounds.maxY - height - 4)
        NSColor(calibratedWhite: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        string.draw(
            at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch phase {
        case .idle, .dragging:
            cursor = .crosshair
        case .selected:
            cursor = annotating ? .crosshair : .arrow
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if phase == .idle {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .idle:
            beginSelection(at: point)
        case .dragging:
            break
        case .selected:
            if selectionRect.insetBy(dx: -1, dy: -1).contains(point) {
                if annotating {
                    annotationOrigin = point
                    pendingAnnotation = .zero
                } else if event.clickCount >= 2 {
                    delegate?.selectionViewDidConfirm(self)
                }
            } else {
                beginSelection(at: point)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseLocation = point
        switch phase {
        case .dragging:
            selectionRect = Self.normalizedRect(dragOrigin, point)
        case .selected:
            if let origin = annotationOrigin {
                pendingAnnotation = Self.normalizedRect(origin, point).intersection(selectionRect)
            }
        case .idle:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case .dragging:
            selectionRect = Self.normalizedRect(dragOrigin, point)
            if selectionRect.width < Metrics.minimumSelection
                || selectionRect.height < Metrics.minimumSelection {
                phase = .idle
                selectionRect = .zero
                hideToolbar()
            } else {
                phase = .selected
                showToolbar()
            }
        case .selected:
            if let origin = annotationOrigin {
                let rect = Self.normalizedRect(origin, point).intersection(selectionRect)
                if rect.width >= Metrics.minimumAnnotation, rect.height >= Metrics.minimumAnnotation {
                    annotations.append(rect)
                }
                annotationOrigin = nil
                pendingAnnotation = .zero
            }
        case .idle:
            break
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.selectionViewDidCancel(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc
            delegate?.selectionViewDidCancel(self)
        case 36, 76: // return, keypad enter
            guard phase == .selected else { return }
            if event.modifierFlags.contains(.option) {
                copyRecognizedText()
            } else {
                delegate?.selectionViewDidConfirm(self)
            }
        case 51, 117: // delete, forward delete
            undoAnnotation()
        default:
            if event.modifierFlags.contains(.command),
               let characters = event.charactersIgnoringModifiers?.lowercased() {
                switch characters {
                case "s":
                    if phase == .selected { delegate?.selectionViewDidRequestSave(self) }
                case "z":
                    undoAnnotation()
                case "r":
                    if phase == .selected { setAnnotating(!annotating) }
                case "t":
                    if phase == .selected { showOCRPanel() }
                default:
                    super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: - Internals

    private func beginSelection(at point: CGPoint) {
        dragOrigin = point
        selectionRect = CGRect(origin: point, size: .zero)
        annotations.removeAll()
        recognizedText = nil
        if isShowingOCRPanel {
            ocrPanel.isHidden = true
        }
        setAnnotating(false)
        hideToolbar()
        phase = .dragging
    }

    private func makeToolbar() -> ToolbarView {
        let bar = ToolbarView(frame: .zero)
        bar.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .annotate:
                // ToolbarView already flipped its own state; adopt it.
                self.setAnnotating(self.toolbar.isAnnotating)
            case .text:
                self.showOCRPanel()
            case .copy:
                self.delegate?.selectionViewDidConfirm(self)
            case .save:
                self.delegate?.selectionViewDidRequestSave(self)
            case .cancel:
                self.delegate?.selectionViewDidCancel(self)
            }
        }
        return bar
    }

    private func makeOCRPanel() -> OCRPanelView {
        let panel = OCRPanelView(frame: .zero)
        panel.onCopy = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.delegate?.selectionView(self, didCopyText: text)
        }
        panel.onClose = { [weak self] in
            self?.hideOCRPanel()
        }
        return panel
    }

    private static func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    // MARK: - Test hooks

    /// Test hook: the unannotated crop Vision is fed.
    var plainImageForTesting: CGImage? { plainImage() }

    func testSelect(_ rect: CGRect) {
        phase = .selected
        selectionRect = rect
        showToolbar()
    }

    func testAddAnnotation(_ rect: CGRect) {
        annotations.append(rect)
        needsDisplay = true
    }

    func testActivateAnnotationMode() {
        setAnnotating(true)
    }

    func testSetMouse(_ point: CGPoint?) {
        mouseLocation = point
        needsDisplay = true
    }

    func testSnapshot() -> NSBitmapImageRep? {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: representation)
        return representation
    }
}

protocol OverlayControllerDelegate: AnyObject {
    func overlayController(_ controller: OverlayController, didConfirm view: SelectionView)
    func overlayController(_ controller: OverlayController, didRequestSave view: SelectionView)
    func overlayController(_ controller: OverlayController, didCopyText text: String)
    func overlayControllerDidCancel(_ controller: OverlayController)
}

/// Owns one overlay window per display and forwards the user's decision.
final class OverlayController: SelectionViewDelegate {
    weak var delegate: OverlayControllerDelegate?
    private(set) var views: [SelectionView] = []
    private(set) var isPresented = false

    func present(_ shots: [ScreenShot]) {
        dismiss()
        guard !shots.isEmpty else { return }
        for shot in shots {
            let window = OverlayWindow(screen: shot.screen)
            let view = SelectionView(shot: shot)
            view.delegate = self
            window.contentView = view
            window.setFrame(shot.screen.frame, display: true)
            window.orderFrontRegardless()
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        let target = views.first { $0.window?.frame.contains(pointer) == true } ?? views[0]
        target.window?.makeKeyAndOrderFront(nil)
        target.window?.makeFirstResponder(target)
        isPresented = true
    }

    func dismiss() {
        for view in views {
            view.window?.orderOut(nil)
        }
        views.removeAll()
        isPresented = false
    }

    /// Temporarily hides the overlays so a save panel or sheet can be shown.
    func hideForModal() {
        for view in views {
            view.window?.orderOut(nil)
        }
    }

    /// Brings the overlays back after a modal panel was dismissed.
    func restoreAfterModal() {
        guard isPresented else { return }
        for view in views {
            view.window?.orderFrontRegardless()
        }
        let pointer = NSEvent.mouseLocation
        let target = views.first { $0.window?.frame.contains(pointer) == true } ?? views.first
        target?.window?.makeKeyAndOrderFront(nil)
        if let target {
            target.window?.makeFirstResponder(target)
        }
    }

    /// Renders the live overlays to PNG files without going through the screen
    /// recording permission, so the real on-screen state can be inspected.
    func debugSnapshot(to directory: String) -> [String] {
        var files: [String] = []
        for (index, view) in views.enumerated() {
            // An active field editor crashes cacheDisplay, so hand focus back to
            // the overlay before ripping the pixels out.
            view.window?.makeFirstResponder(view)
            guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                continue
            }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                continue
            }
            let url = URL(fileURLWithPath: directory.isEmpty ? NSTemporaryDirectory() : directory)
                .appendingPathComponent("overlay-\(index).png")
            do {
                try data.write(to: url, options: .atomic)
                files.append(url.path)
            } catch {
                Log.error("snapshot failed: \(error.localizedDescription)")
            }
        }
        return files
    }

    func selectionViewDidConfirm(_ view: SelectionView) {
        delegate?.overlayController(self, didConfirm: view)
    }

    func selectionViewDidRequestSave(_ view: SelectionView) {
        delegate?.overlayController(self, didRequestSave: view)
    }

    func selectionView(_ view: SelectionView, didCopyText text: String) {
        delegate?.overlayController(self, didCopyText: text)
    }

    func selectionViewDidCancel(_ view: SelectionView) {
        delegate?.overlayControllerDidCancel(self)
    }
}
