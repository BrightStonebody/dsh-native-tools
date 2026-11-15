import AppKit
import CoreGraphics

/// One captured display: the frozen frame plus the geometry needed to map
/// points on screen onto pixels in `image`.
struct ScreenShot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Backing scale of the display; the image is `frame.size * scale` pixels.
    let scale: CGFloat

    var imageSize: CGSize {
        CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case captureFailed(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有屏幕录制权限"
        case .noDisplay:
            return "没有找到可用的显示器"
        case let .captureFailed(display):
            return "无法抓取显示器 \(display) 的画面"
        }
    }
}

enum ScreenCapture {
    /// Whether macOS currently allows this app to read screen content.
    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks macOS for screen-recording trust; the system may show its own prompt.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Freezes every attached display.
    static func captureAllScreens() throws -> [ScreenShot] {
        guard hasPermission else { throw CaptureError.permissionDenied }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw CaptureError.noDisplay }
        var shots: [ScreenShot] = []
        for screen in screens {
            let id = displayID(for: screen)
            guard let image = CGDisplayCreateImage(id) else {
                throw CaptureError.captureFailed(id)
            }
            shots.append(ScreenShot(screen: screen, displayID: id, image: image, scale: screen.backingScaleFactor))
        }
        return shots
    }

    /// A synthetic frame with obvious orientation cues, used by `--self-test`
    /// and by `--dry-run` so the overlay can be exercised without screen trust.
    static func syntheticShot(for screen: NSScreen) -> ScreenShot {
        let scale = screen.backingScaleFactor
        let width = Int((screen.frame.width * scale).rounded())
        let height = Int((screen.frame.height * scale).rounded())
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Background gradient with a checkerboard so scaling and cropping are visible.
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.16, blue: 0.28, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cell = 48
        context.setFillColor(CGColor(srgbRed: 0.16, green: 0.22, blue: 0.36, alpha: 1))
        for y in stride(from: 0, to: height, by: cell) {
            for x in stride(from: 0, to: width, by: cell) where (x / cell + y / cell) % 2 == 0 {
                context.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        // Orientation marks: thick bars on every edge, a solid corner top-left.
        let band = CGFloat(72) * scale
        let marks: [(CGColor, CGRect)] = [
            (CGColor(srgbRed: 0.98, green: 0.78, blue: 0.2, alpha: 1),
             CGRect(x: 0, y: 0, width: band, height: band)),
            (CGColor(srgbRed: 0.2, green: 0.85, blue: 0.5, alpha: 1),
             CGRect(x: CGFloat(width) - band, y: 0, width: band, height: band)),
            (CGColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1),
             CGRect(x: 0, y: CGFloat(height) - band, width: band, height: band)),
            (CGColor(srgbRed: 1, green: 0.35, blue: 0.75, alpha: 1),
             CGRect(x: CGFloat(width) - band, y: CGFloat(height) - band, width: band, height: band)),
        ]
        for (color, rect) in marks {
            context.setFillColor(color)
            context.fill(rect)
        }
        // Grid lines every 200 points.
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
        context.setLineWidth(1 * scale)
        let step = CGFloat(200) * scale
        var x = step
        while x < CGFloat(width) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: CGFloat(height)))
            x += step
        }
        var y = step
        while y < CGFloat(height) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: CGFloat(width), y: y))
            y += step
        }
        context.strokePath()
        // Labels use AppKit drawing so text orientation is verifiable too.
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        let labels: [(String, CGPoint)] = [
            ("左下", CGPoint(x: band + 24, y: band + 12)),
            ("右下", CGPoint(x: CGFloat(width) - band - 130, y: band + 12)),
            ("左上", CGPoint(x: band + 24, y: CGFloat(height) - band - 60)),
            ("右上", CGPoint(x: CGFloat(width) - band - 130, y: CGFloat(height) - band - 60)),
        ]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30 * scale, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        for (text, point) in labels {
            (text as NSString).draw(at: point, withAttributes: attributes)
        }
        let title = "DSH 截图助手 · 测试画面"
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 44 * scale, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        (title as NSString).draw(
            at: CGPoint(x: (CGFloat(width) - titleSize.width) / 2, y: (CGFloat(height) - titleSize.height) / 2),
            withAttributes: titleAttributes
        )
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()!
        return ScreenShot(screen: screen, displayID: displayID(for: screen), image: image, scale: scale)
    }
}
