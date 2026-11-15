import AppKit
import ApplicationServices

/// One pasteboard snapshot, already decoded into the shape the store accepts.
struct CapturedClipboard {
    enum Payload {
        case text(String)
        case image(pngData: Data, thumbData: Data?, width: Int, height: Int)
    }

    var payload: Payload
    var source: ClipboardSource
}

/// Polls `NSPasteboard.general.changeCount` and reports new content.
///
/// A poll is used instead of a pasteboard notification because macOS has none;
/// 0.4 s keeps the history current without measurable CPU cost.
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int
    private(set) var isRunning = false
    var interval: TimeInterval = 0.4
    var sourceProvider: () -> ClipboardSource = {
        ClipboardMonitor.frontmostSource()
    }
    var onCapture: ((CapturedClipboard) -> Void)?

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// Call after the helper writes the pasteboard itself so its own write is
    /// not captured as a new history entry.
    func ignoreCurrentChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        let source = sourceProvider()
        guard let captured = ClipboardMonitor.capture(from: pasteboard, source: source) else {
            return
        }
        onCapture?(captured)
    }

    static func frontmostSource() -> ClipboardSource {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .unknown
        }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return .unknown
        }
        return ClipboardSource(
            name: app.localizedName,
            bundleID: app.bundleIdentifier
        )
    }

    static func capture(from pasteboard: NSPasteboard, source: ClipboardSource) -> CapturedClipboard? {
        let text = pasteboard.string(forType: .string)
        let pngData = ImageSupport.pngData(from: pasteboard)

        let usableText: String? = {
            guard let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= ClipboardStore.maxTextBytes
            else { return nil }
            return text
        }()

        // Browsers copy "image + source URL" as one pasteboard item; the image is
        // what the user sees, so the URL only counts as a caption when it is long
        // or multi-line (a real text selection).
        if let usableText, pngData == nil || !imageWinsOverText(usableText) {
            return CapturedClipboard(payload: .text(usableText), source: source)
        }

        if let pngData,
           pngData.count <= ClipboardStore.maxImageBytes,
           let size = ImageSupport.pixelSize(of: pngData) {
            let thumb = ImageSupport.thumbnail(from: pngData)
            return CapturedClipboard(
                payload: .image(pngData: pngData, thumbData: thumb, width: size.width, height: size.height),
                source: source
            )
        }

        // Huge images can still be copied as text when a caption is present.
        if let usableText {
            return CapturedClipboard(payload: .text(usableText), source: source)
        }
        return nil
    }

    /// True when the accompanying text looks like a URL/file path rather than a
    /// description of the image.
    static func imageWinsOverText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return true
        }
        if trimmed.count > 2_048 || trimmed.contains("\n") {
            return false
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "data"].contains(scheme) {
            return true
        }
        if trimmed.hasPrefix("/") && !trimmed.contains(" ") {
            return true
        }
        return false
    }
}

/// Writes a history item back to the pasteboard and synthesizes ⌘V.
enum PasteService {
    private static var didPromptAccessibility = false

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func writeToPasteboard(_ item: ClipboardItem, store: ClipboardStore) -> Bool {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: item),
                  let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data)
            else { return false }
            pasteboard.clearContents()
            var ok = pasteboard.setData(data, forType: .png)
            if let tiff = image.tiffRepresentation {
                ok = pasteboard.setData(tiff, forType: .tiff) || ok
            }
            return ok
        }
    }

    static func activate(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    /// Extra time for the target app to take focus before the synthetic ⌘V.
    static func pasteCommandV(after delay: TimeInterval = 0.12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard AXIsProcessTrusted() else { return }
            let source = CGEventSource(stateID: .combinedSessionState)
            source?.setLocalEventsFilterDuringSuppressionState(
                [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
                state: .eventSuppressionStateSuppressionInterval
            )
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            down?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            up?.flags = .maskCommand
            up?.post(tap: .cghidEventTap)
        }
    }

    /// The system prompt is shown at most once per helper process; afterwards the
    /// settings page is the place to point the user at.
    static func promptForAccessibility() {
        guard !didPromptAccessibility else { return }
        didPromptAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        Log.info("requested Accessibility permission")
    }

    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
