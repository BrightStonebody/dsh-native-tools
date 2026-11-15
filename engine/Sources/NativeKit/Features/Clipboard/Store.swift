import AppKit
import CryptoKit

enum ClipboardKind: String, Codable {
    case text
    case image
}

struct ClipboardSource {
    var name: String?
    var bundleID: String?

    static let unknown = ClipboardSource(name: nil, bundleID: nil)
}

struct ClipboardItem: Codable, Identifiable, Equatable {
    var id: String
    var kind: ClipboardKind
    var text: String?
    var imageFileName: String?
    var thumbFileName: String?
    var width: Int?
    var height: Int?
    var digest: String
    /// Unix epoch seconds.
    var copiedAt: Double
    var sourceName: String?
    var sourceBundleID: String?
    var byteSize: Int

    var copiedDate: Date {
        Date(timeIntervalSince1970: copiedAt)
    }

    var searchableText: String {
        switch kind {
        case .text:
            return text ?? ""
        case .image:
            let labels = "图片 照片 截图 image screenshot picture"
            let dimensions = "\(width ?? 0)x\(height ?? 0) \(width ?? 0)×\(height ?? 0)"
            return "\(labels) \(dimensions) \(sourceName ?? "")"
        }
    }

    /// First line, collapsed for the list row.
    var title: String {
        switch kind {
        case .image:
            let w = width ?? 0
            let h = height ?? 0
            return w > 0 && h > 0 ? "图片 · \(w) × \(h)" : "图片"
        case .text:
            let firstLine = (text ?? "")
                .split(whereSeparator: { $0.isNewline })
                .first
                .map(String.init) ?? ""
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                return "空白文本"
            }
            return String(trimmed.prefix(200))
        }
    }

    func metaText(now: Date = Date()) -> String {
        var parts: [String] = []
        if let sourceName, !sourceName.isEmpty {
            parts.append(sourceName)
        }
        parts.append(ClipboardStore.relativeTime(copiedDate, now: now))
        return parts.joined(separator: " · ")
    }

    var sizeText: String {
        switch kind {
        case .text:
            return "\(ClipboardStore.numberFormatter.string(from: NSNumber(value: (text ?? "").count)) ?? "0") 字符"
        case .image:
            let w = width ?? 0
            let h = height ?? 0
            return "\(w) × \(h) · \(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file))"
        }
    }
}

/// JSON history plus the PNG payloads it references.
///
/// History is intentionally a plain JSON file: it is small (the helper caps
/// text at 1 MB and images at 25 MB), inspectable, and a corrupt file can be
/// moved aside without touching the images directory.
final class ClipboardStore {
    static let maxTextBytes = 1_000_000
    static let maxImageBytes = 25_000_000

    private(set) var items: [ClipboardItem] = []
    private(set) var maxItems: Int
    private(set) var retentionDays: Int

    let directory: URL
    let imagesDirectory: URL
    let historyURL: URL

    private let fileManager = FileManager.default

    static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    init(directory: URL = ClipboardSettings.supportDirectory) {
        self.directory = directory
        self.imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        self.historyURL = directory.appendingPathComponent("history.json", isDirectory: false)
        self.maxItems = ClipboardSettings.clamp(maxItems: 200)
        self.retentionDays = ClipboardSettings.clamp(retentionDays: 30)
        prepareDirectories()
        load()
    }

    // MARK: - Configuration

    func setLimits(maxItems: Int, retentionDays: Int) {
        self.maxItems = ClipboardSettings.clamp(maxItems: maxItems)
        self.retentionDays = ClipboardSettings.clamp(retentionDays: retentionDays)
        prune()
    }

    // MARK: - Reading

    func item(id: String) -> ClipboardItem? {
        items.first { $0.id == id }
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDirectory.appendingPathComponent(name, isDirectory: false)
    }

    func thumbURL(for item: ClipboardItem) -> URL? {
        guard let name = item.thumbFileName else { return nil }
        return imagesDirectory.appendingPathComponent(name, isDirectory: false)
    }

    func search(_ query: String) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { item in
            if item.searchableText.localizedCaseInsensitiveContains(trimmed) { return true }
            if let source = item.sourceName, source.localizedCaseInsensitiveContains(trimmed) { return true }
            if let bundle = item.sourceBundleID, bundle.localizedCaseInsensitiveContains(trimmed) { return true }
            return false
        }
    }

    // MARK: - Writing

    @discardableResult
    func addText(_ text: String, source: ClipboardSource, at date: Date = Date()) -> ClipboardItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maxTextBytes
        else { return nil }

        let digest = "t:" + Self.sha256Hex(Data(text.utf8))
        let timestamp = date.timeIntervalSince1970
        if let existingIndex = items.firstIndex(where: { $0.digest == digest }) {
            items[existingIndex].copiedAt = timestamp
            items[existingIndex].sourceName = source.name
            items[existingIndex].sourceBundleID = source.bundleID
            let item = items[existingIndex]
            moveToTop(existingIndex)
            prune(now: date)
            save()
            return item
        }

        let item = ClipboardItem(
            id: UUID().uuidString,
            kind: .text,
            text: text,
            imageFileName: nil,
            thumbFileName: nil,
            width: nil,
            height: nil,
            digest: digest,
            copiedAt: timestamp,
            sourceName: source.name,
            sourceBundleID: source.bundleID,
            byteSize: text.utf8.count
        )
        items.insert(item, at: 0)
        prune(now: date)
        save()
        return item
    }

    @discardableResult
    func addImage(
        pngData: Data,
        thumbData: Data?,
        source: ClipboardSource,
        at date: Date = Date()
    ) -> ClipboardItem? {
        guard pngData.count <= Self.maxImageBytes,
              let size = ImageSupport.pixelSize(of: pngData)
        else { return nil }

        let digest = "i:" + Self.sha256Hex(pngData)
        let timestamp = date.timeIntervalSince1970
        if let existingIndex = items.firstIndex(where: { $0.digest == digest }) {
            items[existingIndex].copiedAt = timestamp
            items[existingIndex].sourceName = source.name
            items[existingIndex].sourceBundleID = source.bundleID
            let item = items[existingIndex]
            moveToTop(existingIndex)
            prune(now: date)
            save()
            return item
        }

        let id = UUID().uuidString
        let fileName = "\(id).png"
        let thumbName = "\(id)-thumb.png"
        let fileURL = imagesDirectory.appendingPathComponent(fileName, isDirectory: false)
        let thumbURL = imagesDirectory.appendingPathComponent(thumbName, isDirectory: false)
        do {
            try pngData.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let thumbnail = thumbData ?? ImageSupport.thumbnail(from: pngData)
            if let thumbnail {
                try thumbnail.write(to: thumbURL, options: [.atomic])
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: thumbURL.path)
            }
        } catch {
            Log.error("cannot store image: \(error.localizedDescription)")
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: thumbURL)
            return nil
        }

        let item = ClipboardItem(
            id: id,
            kind: .image,
            text: nil,
            imageFileName: fileName,
            thumbFileName: fileManager.fileExists(atPath: thumbURL.path) ? thumbName : nil,
            width: size.width,
            height: size.height,
            digest: digest,
            copiedAt: timestamp,
            sourceName: source.name,
            sourceBundleID: source.bundleID,
            byteSize: pngData.count
        )
        items.insert(item, at: 0)
        prune(now: date)
        save()
        return item
    }

    /// Selecting an item promotes it to the top of the history (requirement 4).
    @discardableResult
    func touch(_ id: String, at date: Date = Date()) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].copiedAt = date.timeIntervalSince1970
        let item = items[index]
        moveToTop(index)
        save()
        return item
    }

    func delete(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        removeFiles(for: item)
        save()
    }

    func clear() {
        for item in items {
            removeFiles(for: item)
        }
        items.removeAll()
        save()
    }

    // MARK: - Pruning

    @discardableResult
    func prune(now: Date = Date()) -> Int {
        var removed: [ClipboardItem] = []
        if retentionDays > 0 {
            let cutoff = now.timeIntervalSince1970 - Double(retentionDays) * 86_400
            items.removeAll { item in
                if item.copiedAt < cutoff {
                    removed.append(item)
                    return true
                }
                return false
            }
        }
        if items.count > maxItems {
            let overflow = items.count - maxItems
            removed.append(contentsOf: items.suffix(overflow))
            items.removeLast(overflow)
        }
        guard !removed.isEmpty else { return 0 }
        for item in removed {
            removeFiles(for: item)
        }
        save()
        return removed.count
    }

    // MARK: - Persistence

    private func prepareDirectories() {
        for url in [directory, imagesDirectory] {
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            } catch {
                Log.error("cannot create \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: historyURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyURL)
            let decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
            items = decoded.filter { item in
                switch item.kind {
                case .text:
                    return item.text != nil
                case .image:
                    guard let url = imageURL(for: item) else { return false }
                    return fileManager.fileExists(atPath: url.path)
                }
            }
        } catch {
            Log.error("history is unreadable: \(error.localizedDescription)")
            let stamp = Int(Date().timeIntervalSince1970)
            let broken = directory.appendingPathComponent("history.broken-\(stamp).json")
            try? fileManager.moveItem(at: historyURL, to: broken)
            items = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(items)
            try data.write(to: historyURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch {
            Log.error("cannot save history: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func moveToTop(_ index: Int) {
        guard index > 0 else { return }
        let item = items.remove(at: index)
        items.insert(item, at: 0)
    }

    private func removeFiles(for item: ClipboardItem) {
        if let url = imageURL(for: item) {
            try? fileManager.removeItem(at: url)
        }
        if let url = thumbURL(for: item) {
            try? fileManager.removeItem(at: url)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 {
            return "刚刚"
        }
        if seconds < 3_600 {
            return "\(Int(seconds / 60)) 分钟前"
        }
        if seconds < 86_400 {
            return "\(Int(seconds / 3_600)) 小时前"
        }
        if seconds < 7 * 86_400 {
            return "\(Int(seconds / 86_400)) 天前"
        }
        return monthDayFormatter.string(from: date)
    }
}

enum ImageSupport {
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let representation = NSBitmapImageRep(data: tiff) {
            return representation.representation(using: .png, properties: [:])
        }
        return nil
    }

    static func pixelSize(of pngData: Data) -> (width: Int, height: Int)? {
        guard let representation = NSBitmapImageRep(data: pngData) else { return nil }
        guard representation.pixelsWide > 0, representation.pixelsHigh > 0 else { return nil }
        return (representation.pixelsWide, representation.pixelsHigh)
    }

    static func image(from pngData: Data) -> NSImage? {
        NSImage(data: pngData)
    }

    static func thumbnail(from pngData: Data, maxDimension: CGFloat = 160) -> Data? {
        guard let representation = NSBitmapImageRep(data: pngData) else { return nil }
        let pixelWidth = CGFloat(representation.pixelsWide)
        let pixelHeight = CGFloat(representation.pixelsHigh)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let scale = min(1, maxDimension / max(pixelWidth, pixelHeight))
        let targetWidth = max(1, Int((pixelWidth * scale).rounded()))
        let targetHeight = max(1, Int((pixelHeight * scale).rounded()))

        guard let target = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: target) else {
            return nil
        }

        let image = NSImage(size: NSSize(width: pixelWidth, height: pixelHeight))
        image.addRepresentation(representation)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return target.representation(using: .png, properties: [:])
    }
}
