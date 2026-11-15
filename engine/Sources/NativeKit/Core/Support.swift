import Foundation

/// Line-oriented logger for every feature in the merged helper.
///
/// One process now hosts three features, so each line carries which feature
/// wrote it: the plugin halves still forward stderr into their own logs, and
/// `[native:clipboard]` is how a reader tells the two apart at a glance.
enum Log {
    /// Set by the host before a feature starts; the feature's slug.
    nonisolated(unsafe) static var scope = "native"

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func info(_ message: String) {
        write("info", message)
    }

    static func error(_ message: String) {
        write("error", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "[native:\(scope) \(formatter.string(from: Date()))] \(level): \(message)\n"
        if let data = line.data(using: .utf8) {
            Output.write(data, to: STDERR_FILENO)
        }
    }
}

/// One JSON object per line on stdout: the Host plugin parses these events.
func printJSON(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    var line = data
    line.append(0x0A)
    Output.write(line, to: STDOUT_FILENO)
}

/// Writes to a pipe that may already be gone.
///
/// `FileHandle.write` raises an Objective-C exception when the other end closed
/// (`EPIPE`), which terminates the process — the helper kept dying with
/// `SIGABRT` inside `-[NSConcreteFileHandle writeData:]` whenever the plugin
/// instance that owned its stdout went away (Host restart, plugin reload). A
/// detached helper must survive that: logs are diagnostics, never a reason to
/// die. The raw `write(2)` returns an error instead of throwing, and a closed
/// pipe then costs nothing.
enum Output {
    static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                // 明确调到 libc 的 write(2)：Output.write 自己就在作用域里，会遮蔽同名符号。
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                return // EPIPE / EBADF / anything else: drop the line, keep running.
            }
        }
    }
}

/// Coerces the loosely typed values that arrive over the control channel.
enum JSONValue {
    static func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    /// A rect arriving as `[x, y, w, h]` (JSON arrays decode to `[Any]`).
    static func rect(_ value: Any?) -> CGRect? {
        guard let array = value as? [Any], array.count == 4 else { return nil }
        let numbers = array.compactMap { double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
}
