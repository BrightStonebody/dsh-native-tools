import AppKit
import Foundation

/// 拼一个 Unix-domain 地址。
private func makeUnixAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strncpy(destination, source, capacity)
            }
        }
    }
    return address
}

/// helper 这边监听的控制通道。
///
/// 一个 Unix socket 够用了：DSH 的 Host 半边用它下发 adopt / configure / release，
/// 调试时 `--status` 也走这里，不用引入别的 IPC 框架。
final class ControlServer {
    private let socketPath: String
    private let lockPath: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1

    /// 处理一条已解码的请求，返回回包字典。
    var handler: (([String: Any]) -> [String: Any])?

    init(socketPath: String) {
        self.socketPath = socketPath
        self.lockPath = socketPath + ".lock"
    }

    /// Where this server listens (`…/control.sock` under the feature's own
    /// Application Support directory).
    var path: String { socketPath }

    /// 抢单实例锁：返回 false 说明另一个 helper 正持有它。
    private func acquireLock() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Log.error("cannot create support directory: \(error.localizedDescription)")
        }
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        _ = ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    func start() throws {
        guard acquireLock() else { throw ControlServerError.alreadyRunning }
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.socketFailed(errno) }
        listenFD = fd
        var address = makeUnixAddress(socketPath)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bindResult == 0 else { throw ControlServerError.bindFailed(errno) }
        chmod(socketPath, 0o600)
        guard listen(fd, 8) == 0 else { throw ControlServerError.listenFailed(errno) }
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        readSource.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        readSource.setCancelHandler { [weak self] in
            if let fd = self?.listenFD, fd >= 0 {
                close(fd)
            }
        }
        readSource.resume()
        source = readSource
    }

    func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(socketPath)
        if lockFD >= 0 {
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }

    private func acceptConnection() {
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &length) }
        }
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            clientFD,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(clientFD, &buffer, buffer.count)
        guard count > 0 else { return }
        let data = Data(buffer[0..<count])
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            Log.error("control: malformed request")
            return
        }
        let reply = handler?(request) ?? ["ok": false, "error": "no handler"]
        guard let replyData = try? JSONSerialization.data(withJSONObject: reply) else { return }
        // 行分隔：Host 端按换行切帧，收到完整一行才算回包。
        var payload = replyData
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { write(clientFD, $0.baseAddress, payload.count) }
    }

    deinit {
        stop()
    }
}

enum ControlServerError: LocalizedError {
    case alreadyRunning
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "已有翻译助手在运行"
        case let .socketFailed(code):
            return "无法创建控制套接字（errno \(code)）"
        case let .bindFailed(code):
            return "无法绑定控制套接字（errno \(code)）"
        case let .listenFailed(code):
            return "无法监听控制套接字（errno \(code)）"
        }
    }
}

enum ControlClient {
    /// 发一条 JSON 请求并解码回包；没有 helper 在听就返回 nil。
    static func send(
        _ payload: [String: Any],
        to path: String,
        timeout: TimeInterval = 2
    ) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeoutValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        var address = makeUnixAddress(path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connectResult == 0 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        shutdown(fd, SHUT_WR)
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return [:] }
        let reply = Data(buffer[0..<count])
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }
}
