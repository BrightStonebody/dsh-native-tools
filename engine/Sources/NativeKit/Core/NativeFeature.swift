import Foundation

/// Everything a feature needs from the shared process.
///
/// A feature owns its own control socket and its own settings file (the paths it
/// used when it ran as its own helper), so the DSH Host plugins did not have to
/// change when the three helpers were merged into one process.
struct FeatureContext {
    /// `screenshot` / `clipboard` / `translate`.
    let slug: String
    /// The socket this feature answers on (`…/control.sock` under its own
    /// Application Support directory).
    let socketPath: String
    /// `~/Library/Application Support/<Feature>/`.
    let supportDirectory: URL
    /// Process-wide Carbon hot key registry, keyed by feature channel.
    let hotKeys: HotKeyCenter
    /// The DSH Host that started us; 0 when launched by hand.
    let parentPID: pid_t
    /// Which plugin instance owns us (a replaced instance must not tear us down).
    let generation: String
    /// `--dry-run`: paint a synthetic frame instead of grabbing the screen.
    let dryRun: Bool
    /// Open the feature's window as soon as it is ready (debugging).
    let activateOnLaunch: Bool
    /// `--hotkey` from the plugin half: only a fallback for a feature that has
    /// nothing stored yet (a stored choice always wins over a replayed hint).
    let launchHotkey: String?
    /// `--save-directory`, same precedence rule.
    let launchSaveDirectory: String?
    /// `--host-socket` (translate): where the Host listens for translation jobs.
    let hostSocket: String?
    /// 启动参数里 feature 自己的数值提示（`--max-items`、`--retention-days`）。
    let launchSettings: [String: Any]
}

/// One of the three tools hosted by the merged helper.
///
/// The host owns the process, the sockets' shared commands and the supervisor
/// watchdog; a feature owns its window/overlay, its shortcut and its commands.
protocol NativeFeature: AnyObject {
    static var slug: String { get }
    /// Shown in `--status` output.
    static var displayName: String { get }
    /// `~/Library/Application Support/<name>/` — unchanged from the standalone helper.
    static var supportDirectoryName: String { get }
    /// Environment variable that overrides the socket path (self tests, debugging).
    static var socketEnvironmentKey: String { get }

    init(context: FeatureContext)

    /// Register the shortcut, open the control channel, warm caches.
    func start()
    /// Tear down windows, timers and cards (called once, on termination).
    func stop()

    /// Feature-specific fields merged into the `status` reply.
    func status() -> [String: Any]

    /// Handles a command the host does not know.
    /// - Returns: `nil` when the command is not this feature's.
    func handle(_ command: String, _ request: [String: Any]) -> [String: Any]?

    /// Settings pushed by the plugin's settings page (also used for `hotkey`).
    func applySettings(_ request: [String: Any]) -> [String: Any]

    /// `--self-test`: runs without a window server session and returns an exit code.
    static func runSelfTest() -> Int32
}
