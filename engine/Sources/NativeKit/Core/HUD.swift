import AppKit

/// Transient, click-through confirmation bubble used after copy and save.
final class HUDWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 48),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HUDContentView: NSView {
    var text: String = ""
    var symbolName: String = "checkmark.circle.fill"
    var tint: NSColor = NSColor(srgbRed: 0.2, green: 0.78, blue: 0.45, alpha: 1)

    private let font = NSFont.systemFont(ofSize: 13, weight: .semibold)

    override var isFlipped: Bool { false }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.white]
    }

    func fittingSize() -> NSSize {
        let textSize = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: textSize.width + 62, height: 34)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bubble = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(calibratedWhite: 0.09, alpha: 0.92).setFill()
        bubble.fill()

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let tinted = image.tinted(with: tint)
            tinted.draw(
                in: NSRect(x: 14, y: bounds.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: 38, y: bounds.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}

enum HUD {
    private static var window: HUDWindow?
    private static var content: HUDContentView?
    private static var pendingHide: DispatchWorkItem?

    /// Shows `text` near the pointer (or screen centre) for a moment.
    static func show(
        _ text: String,
        symbol: String = "checkmark.circle.fill",
        success: Bool = true,
        near point: CGPoint? = nil,
        duration: TimeInterval = 1.4
    ) {
        pendingHide?.cancel()
        let hud = window ?? HUDWindow()
        window = hud
        let view = content ?? HUDContentView()
        content = view
        view.text = text
        view.symbolName = symbol
        view.tint = success
            ? NSColor(srgbRed: 0.24, green: 0.82, blue: 0.5, alpha: 1)
            : NSColor(srgbRed: 1, green: 0.45, blue: 0.4, alpha: 1)
        let size = view.fittingSize()
        let anchor = point ?? CGPoint(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y)
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height - 26)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.frame.minY + 8), screen.frame.maxY - size.height - 8)
        }
        view.frame = NSRect(origin: .zero, size: size)
        hud.contentView = view
        hud.setFrame(NSRect(origin: origin, size: size), display: true)
        hud.alphaValue = 1
        hud.orderFrontRegardless()
        view.needsDisplay = true

        let work = DispatchWorkItem { [weak hud] in
            guard let hud else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                hud.animator().alphaValue = 0
            } completionHandler: {
                hud.orderOut(nil)
                hud.alphaValue = 1
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
