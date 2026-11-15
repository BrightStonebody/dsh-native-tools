import AppKit
import CoreGraphics
import CoreText
import Vision

/// What Vision read out of one picture.
struct RecognizedText {
    let text: String
    let lineCount: Int
    let characterCount: Int
    let milliseconds: Int
    let languages: [String]

    var isEmpty: Bool { text.isEmpty }
}

/// On-device text recognition (Vision). Nothing leaves the machine, and the
/// screen-recording permission already covers the pixels we hand it.
///
/// The first call in a process spends ~19s loading the language model, so the
/// helper warms the recogniser up in the background at launch; every call after
/// that is 100–500 ms depending on the area.
enum TextRecognition {
    /// Concurrent, so a user request never waits behind the warm-up call.
    private static let queue = DispatchQueue(
        label: "ai.deepseek.dsh.screenshot.ocr",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Language codes Vision should try, in order. Empty means "detect it".
    static func languages(for setting: String) -> [String] {
        switch setting.lowercased() {
        case "zh", "chinese", "zh-hans", "chs":
            return ["zh-Hans", "en"]
        case "en", "english":
            return ["en", "zh-Hans"]
        default:
            return []
        }
    }

    /// Runs one throwaway recognition so the model is resident before the user
    /// ever asks for text.
    static func warmUp() {
        queue.async {
            _ = perform(image: probeImage(), keepLineBreaks: true, languages: [])
        }
    }

    /// Recognises `image` off the main thread and answers on the main thread.
    static func recognize(
        image: CGImage,
        keepLineBreaks: Bool,
        languages: [String],
        completion: @escaping (RecognizedText?) -> Void
    ) {
        queue.async {
            let result = perform(image: image, keepLineBreaks: keepLineBreaks, languages: languages)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Blocking variant, used by the self-test.
    static func recognizeSync(image: CGImage, keepLineBreaks: Bool, languages: [String]) -> RecognizedText? {
        queue.sync {
            perform(image: image, keepLineBreaks: keepLineBreaks, languages: languages)
        }
    }

    // MARK: - Vision

    private struct Piece {
        let text: String
        let box: CGRect
    }

    private static func perform(image: CGImage?, keepLineBreaks: Bool, languages: [String]) -> RecognizedText? {
        guard let image else { return nil }
        let started = Date()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.error("ocr failed: \(error.localizedDescription)")
            return nil
        }

        let pieces: [Piece] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Piece(text: text, box: observation.boundingBox)
        }

        let lines = assemble(pieces)
        let text = keepLineBreaks
            ? lines.joined(separator: "\n")
            : joinLines(lines)
        let elapsed = Int((Date().timeIntervalSince(started) * 1000).rounded())
        return RecognizedText(
            text: text,
            lineCount: lines.count,
            characterCount: text.count,
            milliseconds: elapsed,
            languages: request.recognitionLanguages
        )
    }

    /// Groups observations into visual lines (top to bottom) and orders each
    /// line left to right. Vision hands back one box per fragment, so this is
    /// what turns "三个字 + 一个词 + 一个数字" back into sentences.
    private static func assemble(_ pieces: [Piece]) -> [String] {
        var groups: [(midY: CGFloat, tolerance: CGFloat, pieces: [Piece])] = []
        for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            let tolerance = max(piece.box.height * 0.6, 0.004)
            if let index = groups.firstIndex(where: { abs($0.midY - piece.box.midY) <= max($0.tolerance, tolerance) }) {
                groups[index].pieces.append(piece)
                groups[index].tolerance = max(groups[index].tolerance, tolerance)
            } else {
                groups.append((piece.box.midY, tolerance, [piece]))
            }
        }

        return groups.map { group in
            var line = ""
            for piece in group.pieces.sorted(by: { $0.box.minX < $1.box.minX }) {
                guard !piece.text.isEmpty else { continue }
                if line.isEmpty {
                    line = piece.text
                    continue
                }
                line += separator(between: line, and: piece.text) + piece.text
            }
            return line
        }
    }

    /// Flows lines into one paragraph when the user does not want hard breaks.
    private static func joinLines(_ lines: [String]) -> String {
        lines.reduce(into: "") { result, line in
            guard !line.isEmpty else { return }
            if result.isEmpty {
                result = line
            } else {
                result += separator(between: result, and: line) + line
            }
        }
    }

    /// CJK runs together, Latin words keep the gap they had on screen.
    private static func separator(between left: String, and right: String) -> String {
        guard let before = left.last, let after = right.first else { return "" }
        if isCJK(before) || isCJK(after) { return "" }
        return " "
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, // CJK punctuation
             0x3400...0x4DBF, // extension A
             0x4E00...0x9FFF, // unified ideographs
             0xF900...0xFAFF, // compatibility ideographs
             0xFF00...0xFFEF, // full-width forms
             0x20000...0x2FA1F: // extensions B–F
            return true
        default:
            return scalar.properties.isIdeographic
        }
    }

    /// A tiny picture with text on it, so the first real call does not pay for
    /// the model load.
    private static func probeImage() -> CGImage? {
        let width = 180
        let height = 64
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Ag1", attributes: attributes)
        )
        context.textPosition = CGPoint(x: 16, y: 18)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
