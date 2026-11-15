import AppKit
import Foundation

// Host 掌握着我们的 stdout：它一旦消失，后续写入会收到 SIGPIPE，默认动作是直接杀进程
// （没有崩溃日志，看起来像"莫名退出"）。后台助手不该被一条断掉的管道弄死。
signal(SIGPIPE, SIG_IGN)

let options = LaunchOptions(arguments: CommandLine.arguments)

/// The features this launch is about: the ones it named, else every feature.
func requestedFeatures() -> [any NativeFeature.Type] {
    let named = options.features.isEmpty
        ? NativeHost.availableFeatures.map { $0.slug }
        : options.features
    var types: [any NativeFeature.Type] = []
    for slug in named {
        if let type = NativeHost.availableFeatures.first(where: { $0.slug == slug }) {
            types.append(type)
        } else {
            Log.scope = "native"
            Log.error("unknown feature \(slug)")
        }
    }
    return types
}

// MARK: - --status

if options.printStatus {
    var merged: [String: Any] = [:]
    var any = false
    for type in requestedFeatures() {
        let path = NativeHost.socketPath(for: type)
        if let reply = ControlClient.send(["command": "status"], to: path) {
            merged[type.slug] = reply
            any = true
        }
    }
    if any {
        printJSON(merged)
        exit(0)
    }
    printJSON(["ok": false, "error": "native helper is not running"])
    exit(1)
}

// MARK: - --self-test

if options.selfTest {
    _ = NSApplication.shared
    var failures: Int32 = 0
    for type in requestedFeatures() {
        Log.scope = type.slug
        failures |= type.runSelfTest()
    }
    exit(failures)
}

// MARK: - adopt an already running process

if !options.skipAdopt {
    var adoptRequest: [String: Any] = [
        "command": "adopt",
        "parentPID": Int(options.parentPID),
        "generation": options.generation,
    ]
    if let hotkey = options.hotkey { adoptRequest["hotkey"] = hotkey }
    if let saveDirectory = options.saveDirectory { adoptRequest["saveDirectory"] = saveDirectory }
    if let hostSocket = options.hostSocket { adoptRequest["hostSocket"] = hostSocket }

    var joined = 0
    var running: pid_t = 0
    var aliveHelper = false
    for type in requestedFeatures() {
        var reply = ControlClient.send(adoptRequest, to: NativeHost.socketPath(for: type))
        if reply?["ok"] as? Bool != true {
            // 这个 feature 还没在进程里跑：请进程级控制通道把它挂进来，再接管。
            let shared = ControlClient.send(
                ["command": "ensure-feature", "feature": type.slug],
                to: NativeHost.sharedSocketPath
            )
            if let shared, shared["ok"] as? Bool == true {
                aliveHelper = true
                reply = ControlClient.send(adoptRequest, to: NativeHost.socketPath(for: type))
            }
        }
        guard let reply, reply["ok"] as? Bool == true else { continue }
        aliveHelper = true
        joined += 1
        running = pid_t(JSONValue.int(reply["pid"]) ?? 0)
        Log.scope = "native"
        Log.info("\(type.slug) joined pid \(reply["pid"] ?? "?"); adopted")
        printJSON([
            "event": "already-running",
            "feature": type.slug,
            "pid": reply["pid"] ?? 0,
            "features": reply["features"] ?? [],
        ])
    }
    // 已经有一个 native helper 在跑就别再起第二个：三个插件要么都挂上去，
    // 要么报错让插件自己重试，绝不能变成两个进程。
    if joined > 0 || aliveHelper {
        if aliveHelper {
            Log.scope = "native"
            Log.info("joined running helper pid \(running)")
        }
        exit(0)
    }
}

// MARK: - run

let host = NativeHost.shared
host.loadFeatures()

let application = NSApplication.shared
application.delegate = host
application.setActivationPolicy(.accessory)
application.run()
