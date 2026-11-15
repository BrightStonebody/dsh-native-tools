import AppKit
import Foundation

/// 把待翻译文本送到 Host 那一侧的翻译套接字，等它回结果。
///
/// helper 不含任何翻译逻辑：语言方向、分片、走哪个通道全由 Host 的 JS 决定。
/// 这里只负责一次请求/应答，以及把「第几片/共几片」的进度转给界面。
enum TranslateClient {
    struct Outcome {
        var ok: Bool
        var text: String = ""
        var error: String?
        var detail: String?
        var target: String?
        var chunks: Int = 0
        var elapsedMs: Int = 0
        var unchanged: Bool = false
    }

    /// 整次翻译的死线：Host 那边是 90 秒，这里留点余量。
    private static let deadline: TimeInterval = 120

    static func translate(
        text: String,
        hostSocket: String,
        onProgress: @escaping (Int, Int) -> Void,
        completion: @escaping (Outcome) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = perform(text: text, hostSocket: hostSocket) { index, total in
                DispatchQueue.main.async { onProgress(index, total) }
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private static func perform(
        text: String,
        hostSocket: String,
        onProgress: (Int, Int) -> Void
    ) -> Outcome {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return Outcome(ok: false, error: "无法创建套接字（errno \(errno)）")
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        hostSocket.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
                pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    _ = strncpy(destination, source, capacity)
                }
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else {
            return Outcome(
                ok: false,
                error: "翻译通道没有就绪：DSH 那边没在监听，重启 DSH 或重新启用插件后再试"
            )
        }

        let request: [String: Any] = ["command": "translate", "text": text]
        guard let payload = try? JSONSerialization.data(withJSONObject: request) else {
            return Outcome(ok: false, error: "无法编码请求")
        }
        var framed = payload
        framed.append(0x0A)
        let written = framed.withUnsafeBytes { write(fd, $0.baseAddress, framed.count) }
        guard written == framed.count else {
            return Outcome(ok: false, error: "发送请求失败")
        }

        let started = Date()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while Date().timeIntervalSince(started) < deadline {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                return Outcome(ok: false, error: "读取回包失败（errno \(errno)）")
            }
            if count == 0 { break }
            buffer.append(contentsOf: chunk[0..<count])

            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                guard let line = String(data: Data(lineData), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !line.isEmpty
                else { continue }
                guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
                    as? [String: Any]
                else { continue }

                if message["event"] as? String == "progress" {
                    let index = message["index"] as? Int ?? 0
                    let total = message["total"] as? Int ?? 0
                    onProgress(index, total)
                    continue
                }
                return decode(message)
            }
        }
        return Outcome(ok: false, error: "翻译超过 \(Int(deadline)) 秒还没回结果，已放弃")
    }

    private static func decode(_ message: [String: Any]) -> Outcome {
        let ok = message["ok"] as? Bool ?? false
        return Outcome(
            ok: ok,
            text: message["text"] as? String ?? "",
            error: message["error"] as? String,
            detail: message["detail"] as? String,
            target: message["target"] as? String,
            chunks: message["chunks"] as? Int ?? 0,
            elapsedMs: message["elapsedMs"] as? Int ?? 0,
            unchanged: message["unchanged"] as? Bool ?? false
        )
    }
}
