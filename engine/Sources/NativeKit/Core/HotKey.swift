import Carbon.HIToolbox
import Cocoa

/// One parsed global shortcut.
struct KeySpec {
    let keyCode: UInt32
    let modifiers: UInt32
    /// Human readable form, e.g. `⇧⌘2`.
    let label: String
}

/// Registers system-wide hot keys through Carbon's `RegisterEventHotKey`.
///
/// Carbon hot keys need no Accessibility trust and fire while another app is
/// frontmost, which is what these tools require. They are delivered to the
/// application event target, so the process must run an `NSApplication` event
/// loop.
///
/// The merged helper hosts several features in one process, so registrations are
/// keyed by channel (`screenshot.capture`, `clipboard.toggle`, …): each feature
/// registers and unregisters its own shortcut without touching the others.
final class HotKeyCenter {
    private struct Registration {
        let channel: String
        let reference: EventHotKeyRef
        let onFire: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextIdentifier: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private var installed = false

    private static let signature: OSType = 0x4453_484E // 'DSHN'

    private static let callback: EventHandlerUPP = { _, event, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr, identifier.signature == HotKeyCenter.signature else {
            return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async { center.fire(identifier.id) }
        return noErr
    }

    /// Installs the Carbon handler once per process.
    private func installHandlerIfNeeded() -> OSStatus {
        if installed { return noErr }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            HotKeyCenter.callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        installed = status == noErr
        return status
    }

    private func fire(_ identifier: UInt32) {
        registrations[identifier]?.onFire()
    }

    /// Registers `spec` for `channel`, replacing whatever that channel had.
    /// - Returns: `nil` on success, otherwise a human readable failure reason.
    @discardableResult
    func register(_ spec: KeySpec, channel: String, onFire: @escaping () -> Void) -> String? {
        unregister(channel: channel)
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else {
            return "无法安装快捷键事件处理器（OSStatus \(handlerStatus)）"
        }
        let identifier = nextIdentifier
        nextIdentifier += 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: identifier)
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return "快捷键 \(spec.label) 已被其他程序占用（OSStatus \(status)）"
        }
        registrations[identifier] = Registration(
            channel: channel,
            reference: reference,
            onFire: onFire
        )
        return nil
    }

    func unregister(channel: String) {
        for (identifier, registration) in registrations where registration.channel == channel {
            UnregisterEventHotKey(registration.reference)
            registrations.removeValue(forKey: identifier)
        }
    }

    func unregisterAll() {
        for (identifier, registration) in registrations {
            UnregisterEventHotKey(registration.reference)
            registrations.removeValue(forKey: identifier)
        }
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}

/// Parses `cmd+shift+2` style shortcut strings into Carbon key codes.
///
/// The grammar is one or more modifiers (`cmd`/`shift`/`opt`/`alt`/`ctrl`, or
/// their glyphs) and exactly one key, joined by `+`. Any letter, digit, named
/// symbol, arrow or function key is a key, so the plugin's settings page can
/// hand over whatever combination the user pressed. A bare key never registers:
/// a modifier-less global hot key would swallow normal typing, and only function
/// keys are exempt because that is how macOS itself treats them.
enum KeySpecParser {
    /// Shortcut strings offered as suggestions in the settings page.
    static let presets = [
        "cmd+shift+2",
        "cmd+shift+3",
        "cmd+shift+4",
        "cmd+shift+5",
        "cmd+shift+s",
        "cmd+shift+a",
        "opt+shift+a",
        "ctrl+shift+a",
    ]

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "minus": kVK_ANSI_Minus,
        "=": kVK_ANSI_Equal, "equal": kVK_ANSI_Equal, "equals": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "leftbracket": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "rightbracket": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "semicolon": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "quote": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, "comma": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, "period": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "slash": kVK_ANSI_Slash,
        "\\": kVK_ANSI_Backslash, "backslash": kVK_ANSI_Backslash,
        "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave,
        "space": kVK_Space,
        "return": kVK_Return, "enter": kVK_Return,
        "escape": kVK_Escape, "esc": kVK_Escape,
        "tab": kVK_Tab,
        "delete": kVK_Delete, "backspace": kVK_Delete,
        "forwarddelete": kVK_ForwardDelete, "del": kVK_ForwardDelete,
        "home": kVK_Home, "end": kVK_End,
        "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "insert": kVK_Help, "help": kVK_Help,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5,
        "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
        "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14,
        "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18,
        "f19": kVK_F19, "f20": kVK_F20,
        "left": kVK_LeftArrow, "leftarrow": kVK_LeftArrow,
        "right": kVK_RightArrow, "rightarrow": kVK_RightArrow,
        "up": kVK_UpArrow, "uparrow": kVK_UpArrow,
        "down": kVK_DownArrow, "downarrow": kVK_DownArrow,
    ]

    private static let modifierAliases: [String: (UInt32, String)] = [
        "cmd": (UInt32(cmdKey), "⌘"),
        "command": (UInt32(cmdKey), "⌘"),
        "⌘": (UInt32(cmdKey), "⌘"),
        "shift": (UInt32(shiftKey), "⇧"),
        "⇧": (UInt32(shiftKey), "⇧"),
        "opt": (UInt32(optionKey), "⌥"),
        "option": (UInt32(optionKey), "⌥"),
        "alt": (UInt32(optionKey), "⌥"),
        "⌥": (UInt32(optionKey), "⌥"),
        "ctrl": (UInt32(controlKey), "⌃"),
        "control": (UInt32(controlKey), "⌃"),
        "⌃": (UInt32(controlKey), "⌃"),
    ]

    /// Key tokens whose menu form is a glyph rather than the spelled-out name.
    private static let keyGlyphs: [String: String] = [
        "left": "←", "leftarrow": "←", "right": "→", "rightarrow": "→",
        "up": "↑", "uparrow": "↑", "down": "↓", "downarrow": "↓",
        "return": "↩", "enter": "↩", "tab": "⇥", "escape": "⎋", "esc": "⎋",
        "delete": "⌫", "backspace": "⌫", "forwarddelete": "⌦", "del": "⌦",
        "space": "Space", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
        "insert": "Ins", "help": "Ins",
        "-": "-", "minus": "-", "=": "=", "equal": "=", "equals": "=",
        "[": "[", "leftbracket": "[", "]": "]", "rightbracket": "]",
        ";": ";", "semicolon": ";", "'": "'", "quote": "'",
        ",": ",", "comma": ",", ".": ".", "period": ".", "/": "/", "slash": "/",
        "\\": "\\", "backslash": "\\", "`": "`", "grave": "`",
    ]

    /// Glyph form used in HUDs and the settings page, e.g. `⇧⌘2`.
    static func label(_ spec: String) -> String {
        guard let parsed = parse(spec) else { return spec }
        return parsed.label
    }

    /// Whether `spec` names a combinable, registerable shortcut.
    static func isValid(_ spec: String) -> Bool {
        parse(spec) != nil
    }

    static func parse(_ spec: String) -> KeySpec? {
        var tokens = spec
            .lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        // Accept `cmd-shift-2` only when nothing else parses, so that `-` keeps
        // working as a key of its own (`cmd+shift+-`).
        if tokens.count == 1, spec.contains("-") {
            let dashed = tokens[0].split(separator: "-").map(String.init).filter { !$0.isEmpty }
            if dashed.count > 1 { tokens = dashed }
        }
        guard !tokens.isEmpty else { return nil }

        var modifiers: UInt32 = 0
        var keyToken: String?

        for token in tokens {
            if let alias = modifierAliases[token] {
                modifiers |= alias.0
            } else {
                guard keyToken == nil else { return nil }
                keyToken = token
            }
        }

        guard let keyToken, let keyCode = keyCodes[keyToken] else { return nil }
        let isFunctionKey = keyToken.hasPrefix("f") && Int(keyToken.dropFirst()) != nil
        guard modifiers != 0 || isFunctionKey else { return nil }

        // Order the glyphs the way macOS does: ⌃⌥⇧⌘.
        let glyphOrder: [(UInt32, String)] = [
            (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"),
            (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘"),
        ]
        var display = ""
        for (mask, glyph) in glyphOrder where modifiers & mask != 0 {
            display += glyph
        }
        display += keyGlyphs[keyToken] ?? keyToken.uppercased()
        return KeySpec(keyCode: UInt32(keyCode), modifiers: modifiers, label: display)
    }
}
