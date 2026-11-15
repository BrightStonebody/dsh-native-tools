import AppKit
import CoreGraphics

/// Turns a selection on a frozen screen into the final PNG, then publishes it
/// to the pasteboard or the file system.
enum ImageOutput {
    /// Style of the red annotation rectangles, in points.
    static let annotationColor = CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    static let annotationLineWidth: CGFloat = 3

    /// Crops `cropRect` (view points, bottom-left origin) out of the frozen frame
    /// and stamps every annotation rectangle.
    /// - Parameter annotations: rectangles in selection-local points, bottom-left origin.
    static func compose(shot: ScreenShot, cropRect: CGRect, annotations: [CGRect]) -> CGImage? {
        let scale = shot.scale
        let imageHeight = shot.imageSize.height
        let imageWidth = shot.imageSize.width
        var pixelRect = CGRect(
            x: cropRect.minX * scale,
            y: imageHeight - cropRect.maxY * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale
        ).integral
        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = shot.image.cropping(to: pixelRect)
        else {
            return nil
        }
        guard !annotations.isEmpty else { return cropped }

        // Pixels lost to the integral crop on the left and bottom edge, so an
        // annotation still lands on the pixels it was drawn over.
        let padX = pixelRect.minX - cropRect.minX * scale
        let padY = (imageHeight - pixelRect.maxY) - cropRect.minY * scale

        let width = cropped.width
        let height = cropped.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return cropped
        }
        context.interpolationQuality = .high
        // A y-up context draws the image upright (its top row at the top of the
        // rect), which is also the space annotation coordinates live in.
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        context.setStrokeColor(annotationColor)
        context.setLineWidth(annotationLineWidth * scale)
        context.setLineJoin(.miter)
        context.setShouldAntialias(true)
        for annotation in annotations {
            let rect = CGRect(
                x: padX + annotation.minX * scale,
                y: padY + annotation.minY * scale,
                width: annotation.width * scale,
                height: annotation.height * scale
            )
            context.stroke(rect)
        }
        return context.makeImage() ?? cropped
    }

    /// Encodes a PNG and records the logical point size so pasted images keep
    /// their on-screen dimensions on Retina captures.
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        return representation.representation(using: .png, properties: [:])
    }

    static func tiffData(_ image: CGImage, scale: CGFloat) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        return representation.representation(using: .tiff, properties: [:])
    }

    /// Writes the image to the general pasteboard as PNG and TIFF.
    @discardableResult
    static func copyToPasteboard(_ image: CGImage, scale: CGFloat) -> Bool {
        guard let png = pngData(image, scale: scale) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var wrote = pasteboard.setData(png, forType: .png)
        if let tiff = tiffData(image, scale: scale) {
            wrote = pasteboard.setData(tiff, forType: .tiff) || wrote
        }
        return wrote
    }

    /// Adds the recognised text next to the picture that is already on the
    /// pasteboard, so a chat box can take the words while an editor takes the
    /// image. Never clears what is there.
    @discardableResult
    static func appendTextToPasteboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        if pasteboard.types?.contains(.string) == true,
           pasteboard.string(forType: .string) == text {
            return true
        }
        return pasteboard.setString(text, forType: .string)
    }

    /// Replaces the pasteboard with plain text only.
    @discardableResult
    static func copyTextToPasteboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static func timestampedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).png"
    }

    /// Saves the PNG, creating the directory when needed.
    static func write(_ image: CGImage, scale: CGFloat, to url: URL) throws -> URL {
        guard let png = pngData(image, scale: scale) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url, options: .atomic)
        return url
    }
}
