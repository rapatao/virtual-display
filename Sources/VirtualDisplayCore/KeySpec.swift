import Carbon.HIToolbox

/// A shortcut written the way a config file or a plugin says it: `"ctrl-opt-cmd-r"`,
/// `"cmd-shift-f5"`, `"ctrl-cmd-left"`. Parsed into what `HotKeyCenter.register` takes.
///
/// Key names are ANSI positions, not layout-dependent characters: `"q"` is the key where
/// Q sits on a US keyboard, which is what Carbon registers against anyway.
public struct KeySpec: Equatable, Sendable {
    public let keyCode: Int
    public let modifiers: UInt32

    /// `nil` when the spec names something that does not exist, so a typo in the config
    /// costs one logged line rather than a shortcut that silently never fires.
    public init?(_ spec: String) {
        var parts = spec.lowercased().split(whereSeparator: { $0 == "-" || $0 == "+" }).map(String.init)
        // A trailing "-" means the key itself is the hyphen: "ctrl-cmd--".
        if spec.hasSuffix("-") || spec.hasSuffix("+") { parts.append(String(spec.last!)) }
        guard let keyName = parts.popLast(), let code = Self.keyCodes[keyName] else { return nil }

        var mask: UInt32 = 0
        for part in parts {
            guard let modifier = Self.modifiers[part] else { return nil }
            mask |= modifier
        }
        keyCode = code
        modifiers = mask
    }

    private static let modifiers: [String: UInt32] = [
        "cmd": UInt32(cmdKey), "command": UInt32(cmdKey),
        "ctrl": UInt32(controlKey), "control": UInt32(controlKey),
        "opt": UInt32(optionKey), "option": UInt32(optionKey), "alt": UInt32(optionKey),
        "shift": UInt32(shiftKey),
    ]

    private static let keyCodes: [String: Int] = {
        var codes: [String: Int] = [
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
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
            "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
            "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow,
            "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "\\": kVK_ANSI_Backslash,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionKeys.enumerated() { codes["f\(index + 1)"] = code }
        return codes
    }()
}
