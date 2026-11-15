import AppKit
import Foundation

/// Command line switches used by the DSH Host plugins and by manual debugging.
struct LaunchOptions {
    /// Feature slugs requested by this launch (`--feature screenshot`). A plain
    /// `--feature` with no value means "every feature this build knows".
    var features: [String] = []
    var parentPID: pid_t = 0
    var generation = ProcessInfo.processInfo.environment["DSHS_GENERATION"] ?? ""
    var selfTest = false
    var printStatus = false
    var skipAdopt = false
    var dryRun = false
    /// Open the feature's window right after launch (debugging / `--capture-on-launch`).
    var activateOnLaunch = false
    /// `--hotkey` / `--save-directory` from the plugin half: used only as a
    /// fallback when the feature has nothing stored yet.
    var hotkey: String?
    var saveDirectory: String?
    /// `--host-socket` (translate): where the Host listens for translation jobs.
    var hostSocket: String?
    /// `--control-socket`: the plugin tells us where *its* feature should listen
    /// (only meaningful together with a single `--feature`).
    var controlSocket: String?
    /// Feature specific launch hints (`--max-items`, `--retention-days`).
    var launchSettings: [String: Any] = [:]

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            func next() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--feature", "--features":
                if let value = next(), !value.isEmpty {
                    features.append(contentsOf: value.split(separator: ",").map(String.init))
                }
            case "--parent-pid":
                if let value = next() { parentPID = pid_t(value) ?? 0 }
            case "--generation":
                if let value = next(), !value.isEmpty { generation = value }
            case "--self-test":
                selfTest = true
            case "--status":
                printStatus = true
            case "--no-adopt":
                skipAdopt = true
            case "--dry-run":
                dryRun = true
            case "--capture-on-launch", "--activate-on-launch":
                activateOnLaunch = true
            case "--hotkey":
                hotkey = next()
            case "--save-directory":
                saveDirectory = next()
            case "--host-socket":
                hostSocket = next()
            case "--control-socket":
                controlSocket = next()
            case "--max-items":
                if let value = next(), let number = Int(value) { launchSettings["maxItems"] = number }
            case "--retention-days":
                if let value = next(), let number = Int(value) { launchSettings["retentionDays"] = number }
            default:
                break
            }
            index += 1
        }
    }
}

/// One feature plus the control socket it answers on.
final class FeatureRuntime {
    let feature: NativeFeature
    let server: ControlServer
    /// True while some DSH Host plugin instance is supervising this feature.
    var attached = false
    /// Which plugin instance attached last.
    var generation = ""

    init(feature: NativeFeature, socketPath: String) {
        self.feature = feature
        self.server = ControlServer(socketPath: socketPath)
    }
}

/// The merged helper process: one `NSApplication`, one process, N features.
///
/// Each feature keeps the control socket and settings file it had when it ran as
/// its own helper, so the three DSH plugins keep working unchanged: they spawn
/// this binary with `--feature <slug>` and talk to their own socket. Whichever
/// plugin starts first becomes the process; the others adopt it.
final class NativeHost: NSObject, NSApplicationDelegate {
    static let shared = NativeHost()

    private let options: LaunchOptions
    private let hotKeys = HotKeyCenter()
    /// 进程级控制通道：后到的插件用它让本进程临时加载自己的 feature。
    private var sharedServer: ControlServer?
    private var runtimes: [FeatureRuntime] = []
    /// 每个 feature 的控制通道路径覆盖（插件显式指定的，或 join 时带过来的）。
    private var socketOverrides: [String: String] = [:]
    private var supervisorPID: pid_t
    private var supervisorToken: String
    private var supervisorTimer: Timer?
    private var releaseTimer: Timer?
    private var started = false

    private init(options: LaunchOptions = LaunchOptions(arguments: CommandLine.arguments)) {
        self.options = options
        self.supervisorPID = options.parentPID
        self.supervisorToken = options.generation
        super.init()
        if options.features.count == 1, let socket = options.controlSocket, !socket.isEmpty {
            socketOverrides[options.features[0]] = socket
        }
    }

    static func bootstrap() -> NativeHost {
        shared
    }

    // MARK: - Wiring

    /// Registers the requested features (all of them when none was named).
    func loadFeatures() {
        let requested = options.features.isEmpty
            ? NativeHost.availableFeatures.map { $0.slug }
            : options.features
        for slug in requested {
            guard let type = NativeHost.featureType(forSlug: slug) else {
                Log.error("unknown feature \(slug)")
                continue
            }
            load(type)
        }
    }

    /// Creates the feature object (no socket yet).
    @discardableResult
    private func load(_ type: any NativeFeature.Type, socketPath override: String? = nil) -> FeatureRuntime? {
        guard runtime(for: type) == nil else { return runtime(for: type) }
        if let override, !override.isEmpty {
            socketOverrides[type.slug] = override
        }
        let socketPath = socketOverrides[type.slug] ?? NativeHost.socketPath(for: type)
        let context = FeatureContext(
            slug: type.slug,
            socketPath: socketPath,
            supportDirectory: NativeHost.supportDirectory(for: type),
            hotKeys: hotKeys,
            parentPID: options.parentPID,
            generation: options.generation,
            dryRun: options.dryRun,
            activateOnLaunch: options.activateOnLaunch,
            launchHotkey: options.hotkey,
            launchSaveDirectory: options.saveDirectory,
            hostSocket: options.hostSocket,
            launchSettings: options.launchSettings
        )
        let runtime = FeatureRuntime(feature: type.init(context: context), socketPath: socketPath)
        runtimes.append(runtime)
        Log.scope = type.slug
        Log.info("feature \(type.slug) loaded (socket \(socketPath))")
        return runtime
    }

    func runtime(for slug: String) -> FeatureRuntime? {
        runtimes.first { type(of: $0.feature).slug == slug }
    }

    private func runtime(for type: any NativeFeature.Type) -> FeatureRuntime? {
        runtime(for: type.slug)
    }

    /// Feature types this build knows about, in start order.
    static let availableFeatures: [any NativeFeature.Type] = [
        ScreenshotFeature.self,
        ClipboardFeature.self,
        TranslateFeature.self,
        MonitorFeature.self,
    ]

    static func supportDirectory(for type: any NativeFeature.Type) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(type.supportDirectoryName, isDirectory: true)
    }

    /// 共享目录：进程级控制通道放这里（各 feature 自己的目录保持不变）。
    static var sharedDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["DSHS_NATIVE_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("DSHNative", isDirectory: true)
    }

    static var sharedSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["DSHS_NATIVE_SOCKET"],
           !override.isEmpty {
            return override
        }
        return sharedDirectory.appendingPathComponent("control.sock").path
    }

    static func featureType(forSlug slug: String) -> (any NativeFeature.Type)? {
        availableFeatures.first { $0.slug == slug }
    }

    static func socketPath(for type: any NativeFeature.Type) -> String {
        if let override = ProcessInfo.processInfo.environment[type.socketEnvironmentKey],
           !override.isEmpty {
            return override
        }
        return supportDirectory(for: type).appendingPathComponent("control.sock").path
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startSharedChannel()
        for runtime in runtimes {
            start(runtime)
        }
        watchSupervisor()
        Log.scope = "native"
        Log.info(
            "ready pid=\(getpid()) features=\(runtimes.map { type(of: $0.feature).slug }.joined(separator: ",")) "
                + "supervisor=\(supervisorPID)"
        )
        printJSON([
            "event": "ready",
            "pid": getpid(),
            "features": runtimes.map { type(of: $0.feature).slug },
            "supervisor": Int(supervisorPID),
        ])
    }

    /// 进程级控制通道：`ensure-feature` 让后到的插件把它的 feature 挂进来，
    /// 这样三个插件共用一个进程而不是各起一个。
    private func startSharedChannel() {
        let server = ControlServer(socketPath: NativeHost.sharedSocketPath)
        server.handler = { [weak self] request in
            self?.handleShared(request) ?? ["ok": false, "error": "helper is not ready"]
        }
        do {
            try server.start()
            sharedServer = server
            Log.scope = "native"
            Log.info("shared control channel at \(server.path)")
        } catch {
            // 另一个进程已经占着共享通道：本次启动的 feature 会因 socket 冲突退出。
            Log.scope = "native"
            Log.error("shared control channel failed: \(error.localizedDescription)")
        }
    }

    private func handleShared(_ request: [String: Any]) -> [String: Any] {
        let command = request["command"] as? String ?? ""
        Log.scope = "native"
        switch command {
        case "status":
            return [
                "ok": true,
                "pid": getpid(),
                "supervisor": Int(supervisorPID),
                "features": runtimes.map { runtime -> [String: Any] in
                    ["feature": type(of: runtime.feature).slug,
                     "socket": runtime.server.path,
                     "attached": runtime.attached]
                },
            ]
        case "features":
            return [
                "ok": true,
                "pid": getpid(),
                "available": NativeHost.availableFeatures.map { $0.slug },
                "loaded": runtimes.map { type(of: $0.feature).slug },
            ]
        case "ensure-feature":
            guard let slug = request["feature"] as? String, !slug.isEmpty else {
                return ["ok": false, "error": "missing feature"]
            }
            guard let type = NativeHost.featureType(forSlug: slug) else {
                return ["ok": false, "error": "unknown feature \(slug)"]
            }
            if runtime(for: type) != nil {
                return ["ok": true, "feature": slug, "alreadyLoaded": true, "pid": getpid()]
            }
            let requestedSocket = request["socket"] as? String
            load(type, socketPath: requestedSocket)
            if let loaded = runtime(for: type) {
                start(loaded)
                return ["ok": true, "feature": slug, "pid": getpid(), "socket": loaded.server.path]
            }
            return ["ok": false, "error": "cannot load \(slug)"]
        case "detach-feature":
            // 插件里关掉某个功能：停掉它、摘掉它的控制通道，进程留着（可能还有别的功能在跑）。
            guard let slug = request["feature"] as? String, !slug.isEmpty,
                  let targetType = NativeHost.featureType(forSlug: slug) else {
                return ["ok": false, "error": "unknown feature"]
            }
            guard let target = runtime(for: targetType) else {
                return ["ok": true, "feature": slug, "alreadyDetached": true, "remaining": runtimes.count]
            }
            Log.scope = slug
            target.feature.stop()
            target.server.stop()
            runtimes.removeAll { candidate in Swift.type(of: candidate.feature).slug == slug }
            Log.scope = "native"
            Log.info("detached \(slug); \(runtimes.count) feature(s) left")
            return [
                "ok": true,
                "feature": slug,
                "remaining": runtimes.count,
                "features": runtimes.map { Swift.type(of: $0.feature).slug },
            ]
        case "adopt":
            // 插件没起进程就找到了我们：先按需加载它的 feature（它会把期望的
            // 控制通道路径一起带过来），再像自己的 socket 那样接管。
            guard let slug = request["feature"] as? String, !slug.isEmpty else {
                return ["ok": false, "error": "missing feature"]
            }
            guard let requestedType = NativeHost.featureType(forSlug: slug) else {
                return ["ok": false, "error": "unknown feature \(slug)"]
            }
            if runtime(for: requestedType) == nil {
                load(requestedType, socketPath: request["socket"] as? String)
                if let loaded = runtime(for: requestedType) { start(loaded) }
            }
            guard let joined = runtime(for: requestedType) else {
                return ["ok": false, "error": "cannot load \(slug)"]
            }
            adopt(joined, request)
            return [
                "ok": true,
                "pid": getpid(),
                "feature": slug,
                "attached": joined.attached,
                "supervisor": Int(supervisorPID),
                "features": runtimes.map { type(of: $0.feature).slug },
            ]
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown command \(command)"]
        }
    }

    /// Starts one feature and puts its control socket up.
    private func start(_ runtime: FeatureRuntime) {
        let slug = type(of: runtime.feature).slug
        Log.scope = slug
        runtime.feature.start()
        runtime.server.handler = { [weak self] request in
            self?.handle(runtime, request) ?? ["ok": false, "error": "helper is not ready"]
        }
        do {
            try runtime.server.start()
            Log.info("control channel up")
        } catch ControlServerError.alreadyRunning {
            // Another process serves this socket: it owns the feature, so bow out.
            Log.error("another helper already serves \(slug)")
            exit(0)
        } catch {
            Log.error("control channel failed: \(error.localizedDescription)")
        }
        printJSON([
            "event": "feature-ready",
            "feature": slug,
            "pid": getpid(),
            "socket": runtime.server.path,
        ])
    }

    func applicationWillTerminate(_ notification: Notification) {
        supervisorTimer?.invalidate()
        releaseTimer?.invalidate()
        hotKeys.unregisterAll()
        sharedServer?.stop()
        for runtime in runtimes {
            runtime.server.stop()
            runtime.feature.stop()
        }
        Log.scope = "native"
        Log.info("terminated")
    }

    // MARK: - Control channel

    /// Shared commands (status / adopt / release / quit / hotkey / settings) are
    /// answered here; everything else belongs to the feature.
    private func handle(_ runtime: FeatureRuntime, _ request: [String: Any]) -> [String: Any] {
        let command = request["command"] as? String ?? ""
        let slug = type(of: runtime.feature).slug
        Log.scope = slug
        switch command {
        case "status":
            var payload = runtime.feature.status()
            payload["ok"] = true
            payload["pid"] = getpid()
            payload["supervisor"] = supervisorPID
            payload["feature"] = slug
            payload["attached"] = runtime.attached
            payload["generation"] = substring(runtime.generation)
            payload["features"] = runtimes.map { type(of: $0.feature).slug }
            payload["generationOwn"] = substring(supervisorToken)
            return payload

        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return ["ok": true]

        case "adopt":
            adopt(runtime, request)
            return [
                "ok": true,
                "pid": getpid(),
                "feature": slug,
                "attached": runtime.attached,
                "supervisor": Int(supervisorPID),
                "features": runtimes.map { type(of: $0.feature).slug },
            ]

        case "release":
            return release(runtime, request)

        case "hotkey":
            if let value = request["value"] as? String, !value.isEmpty {
                return runtime.feature.applySettings(["hotkey": value])
            }
            return ["ok": false, "error": "missing value"]

        case "save-directory":
            if let value = request["value"] as? String, !value.isEmpty {
                return runtime.feature.applySettings(["saveDirectory": value])
            }
            return ["ok": false, "error": "missing value"]

        case "features":
            return [
                "ok": true,
                "features": runtimes.map { [ "feature": type(of: $0.feature).slug,
                                             "socket": $0.server.path,
                                             "attached": $0.attached ] },
            ]

        default:
            if let reply = runtime.feature.handle(command, request) {
                return reply
            }
            return ["ok": false, "error": "unknown command \(command)"]
        }
    }

    private func substring(_ value: String) -> String {
        value.count <= 8 ? value : String(value.prefix(8))
    }

    /// A plugin instance hands us its supervision (and its settings).
    private func adopt(_ runtime: FeatureRuntime, _ request: [String: Any]) {
        let slug = type(of: runtime.feature).slug
        if let token = request["generation"] as? String, !token.isEmpty {
            runtime.generation = token
            supervisorToken = token
        }
        if let pid = JSONValue.int(request["parentPID"]), pid > 1 {
            supervisorPID = pid_t(pid)
            watchSupervisor()
        }
        runtime.attached = true
        releaseTimer?.invalidate()
        releaseTimer = nil
        // Settings ride along with the adopt request; the feature decides which
        // of them it stores (a stored hotkey always wins over a replay).
        var settings = request
        settings.removeValue(forKey: "command")
        _ = runtime.feature.applySettings(settings)
        Log.info("adopted supervisor \(supervisorPID)")
        // A plugin that attaches to a helper it did not start has no `ready`
        // event to sync against, so it pushes settings itself right after this.
        printJSON(["event": "adopted", "feature": slug, "pid": getpid(), "supervisor": Int(supervisorPID)])
    }

    private func release(_ runtime: FeatureRuntime, _ request: [String: Any]) -> [String: Any] {
        // 代号按前 8 位比对：控制通道里对外只露前缀，插件重载后旧实例的发布也不算数。
        if let token = request["generation"] as? String, !token.isEmpty,
           !runtime.generation.isEmpty, substring(token) != substring(runtime.generation) {
            return ["ok": true, "ignored": true]
        }
        runtime.attached = false
        runtime.generation = ""
        if runtimes.allSatisfy({ !$0.attached }) {
            supervisorPID = 0
            supervisorTimer?.invalidate()
            supervisorTimer = nil
            scheduleReleaseExit()
        }
        return ["ok": true, "attached": runtime.attached]
    }

    /// Exits soon after a release unless a replacement supervisor adopts first.
    private func scheduleReleaseExit() {
        releaseTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            Log.scope = "native"
            Log.info("released without a new supervisor; quitting")
            NSApp.terminate(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    // MARK: - Supervisor

    /// Exits when the DSH Host that started us is gone.
    private func watchSupervisor() {
        supervisorTimer?.invalidate()
        supervisorTimer = nil
        guard supervisorPID > 1 else { return }
        let pid = supervisorPID
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if kill(pid, 0) != 0, errno == ESRCH {
                Log.scope = "native"
                Log.info("supervisor \(pid) exited; quitting")
                NSApp.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        supervisorTimer = timer
    }
}
