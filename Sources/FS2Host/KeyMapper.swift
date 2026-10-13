import C64Kit

/// A joystick action bound to a Mac key (keypad as joystick).
public struct JoystickBinding: Sendable, Equatable {
    /// Control port 1 (the yoke) or 2 (throttle and guns).
    public var port: Int
    public var state: JoystickState
}

/// One row of the mapping table: a physical Mac key and what it does on the C64.
public struct KeyBinding: Sendable {
    public var mac: MacKeyCode
    /// C64 keys held while the Mac key is down (several for a chord, e.g. SHIFT + CRSR for ←).
    public var c64: [C64Key]
    /// When set and keypad-as-joystick is on, the key drives a joystick instead of `c64`.
    public var joystick: JoystickBinding?
    /// What the C64 side is called in the keyboard reference, when it is not just the key label.
    public var c64Name: String?

    public init(_ mac: MacKeyCode, _ c64: [C64Key], joystick: JoystickBinding? = nil, name: String? = nil) {
        self.mac = mac
        self.c64 = c64
        self.joystick = joystick
        c64Name = name
    }

    /// Label for the C64 side, e.g. "SHIFT + CRSR →".
    public var c64Label: String {
        if let c64Name { return c64Name }
        return c64.map { $0 == .rightShift && c64.count > 1 ? "SHIFT" : $0.label }.joined(separator: " + ")
    }
}

/// The curated Mac → C64 keyboard table (the plan's "Keyboard and controls" section). Keys map by
/// position to C64 matrix positions; the original program's own scan, repeat and dispatch run on
/// top of the matrix unchanged. Command-key combinations are never mapped, so ⌘-shortcuts reach
/// the menus.
public enum KeyMapper {
    /// C64 keys deliberately left without a Mac key.
    public static let unmappedByDesign: [C64Key: String] = [
        .leftShift: "LEFT SHIFT gives the same code as CTRL-A (ADF select), so both Mac Shift keys act as "
            + "RIGHT SHIFT, which the game ignores. The ADF stays on A.",
    ]

    public static let bindings: [KeyBinding] = {
        var b: [KeyBinding] = []
        // Letters and digits: the same key.
        let letters: [(MacKeyCode, C64Key)] = [
            (.a, .a), (.b, .b), (.c, .c), (.d, .d), (.e, .e), (.f, .f), (.g, .g), (.h, .h), (.i, .i),
            (.j, .j), (.k, .k), (.l, .l), (.m, .m), (.n, .n), (.o, .o), (.p, .p), (.q, .q), (.r, .r),
            (.s, .s), (.t, .t), (.u, .u), (.v, .v), (.w, .w), (.x, .x), (.y, .y), (.z, .z),
        ]
        let digits: [(MacKeyCode, C64Key)] = [
            (.digit1, .digit1), (.digit2, .digit2), (.digit3, .digit3), (.digit4, .digit4), (.digit5, .digit5),
            (.digit6, .digit6), (.digit7, .digit7), (.digit8, .digit8), (.digit9, .digit9), (.digit0, .digit0),
        ]
        for (m, c) in letters + digits { b.append(KeyBinding(m, [c])) }
        b += [
            KeyBinding(.comma, [.comma]),
            KeyBinding(.period, [.period]),
            KeyBinding(.slash, [.slash]),
            KeyBinding(.space, [.space]),
            KeyBinding(.returnKey, [.returnKey]),
            // Punctuation by position.
            KeyBinding(.semicolon, [.semicolon]),
            KeyBinding(.quote, [.colon]),
            KeyBinding(.equal, [.plus]),
            KeyBinding(.minus, [.minus]),
            KeyBinding(.leftBracket, [.at]),
            KeyBinding(.rightBracket, [.asterisk]),
            KeyBinding(.backslash, [.pound]),
            KeyBinding(.grave, [.leftArrow]),
            KeyBinding(.isoSection, [.leftArrow]),
            // Editing and system keys.
            KeyBinding(.escape, [.runStop]),
            KeyBinding(.home, [.clrHome]),
            KeyBinding(.delete, [.instDel]),
            KeyBinding(.help, [.rightShift, .instDel], name: "INST (SHIFT + INST/DEL)"),
            KeyBinding(.end, [.upArrow]),
            KeyBinding(.forwardDelete, [.equals]),
            // Modifiers.
            KeyBinding(.control, [.control]),
            KeyBinding(.rightControl, [.control]),
            KeyBinding(.shift, [.rightShift]),
            KeyBinding(.rightShift, [.rightShift]),
            KeyBinding(.option, [.commodore]),
            KeyBinding(.rightOption, [.commodore]),
            // Cursor keys: the C64 has only CRSR → and CRSR ↓; ← and ↑ are their shifted forms.
            KeyBinding(.rightArrow, [.cursorRight]),
            KeyBinding(.downArrow, [.cursorDown]),
            KeyBinding(.leftArrow, [.rightShift, .cursorRight], name: "CRSR ← (SHIFT + CRSR →)"),
            KeyBinding(.upArrow, [.rightShift, .cursorDown], name: "CRSR ↑ (SHIFT + CRSR ↓)"),
            // Throttle aliases.
            KeyBinding(.pageUp, [.semicolon]),
            KeyBinding(.pageDown, [.colon]),
            // Function keys: F2/F4/F6/F8 are SHIFT + F1/F3/F5/F7 on the C64.
            KeyBinding(.f1, [.f1]),
            KeyBinding(.f2, [.rightShift, .f1], name: "F2 (SHIFT + F1)"),
            KeyBinding(.f3, [.f3]),
            KeyBinding(.f4, [.rightShift, .f3], name: "F4 (SHIFT + F3)"),
            KeyBinding(.f5, [.f5]),
            KeyBinding(.f6, [.rightShift, .f5], name: "F6 (SHIFT + F5)"),
            KeyBinding(.f7, [.f7]),
            KeyBinding(.f8, [.rightShift, .f7], name: "F8 (SHIFT + F7)"),
        ]
        // Keypad: joystick when keypad-as-joystick is on, otherwise the matching C64 key.
        func joy(_ port: Int, _ s: JoystickState) -> JoystickBinding { JoystickBinding(port: port, state: s) }
        b += [
            KeyBinding(.keypad8, [.digit8], joystick: joy(1, .up)),
            KeyBinding(.keypad2, [.digit2], joystick: joy(1, .down)),
            KeyBinding(.keypad4, [.digit4], joystick: joy(1, .left)),
            KeyBinding(.keypad6, [.digit6], joystick: joy(1, .right)),
            KeyBinding(.keypad7, [.digit7], joystick: joy(1, [.up, .left])),
            KeyBinding(.keypad9, [.digit9], joystick: joy(1, [.up, .right])),
            KeyBinding(.keypad1, [.digit1], joystick: joy(1, [.down, .left])),
            KeyBinding(.keypad3, [.digit3], joystick: joy(1, [.down, .right])),
            KeyBinding(.keypad5, [.digit5], joystick: joy(1, .fire)),
            KeyBinding(.keypad0, [.digit0], joystick: joy(1, .fire)),
            KeyBinding(.keypadPlus, [.plus], joystick: joy(2, .up)),
            KeyBinding(.keypadMinus, [.minus], joystick: joy(2, .down)),
            KeyBinding(.keypadEnter, [.returnKey], joystick: joy(2, .fire)),
            KeyBinding(.keypadDecimal, [.period]),
            KeyBinding(.keypadMultiply, [.asterisk]),
            KeyBinding(.keypadDivide, [.slash]),
            KeyBinding(.keypadEquals, [.equals]),
            KeyBinding(.keypadClear, [.clrHome]),
        ]
        return b
    }()

    private static let byCode: [UInt16: KeyBinding] = {
        var d: [UInt16: KeyBinding] = [:]
        for b in bindings { d[b.mac.rawValue] = b }
        return d
    }()

    /// The binding for a Mac key code, if the key is mapped.
    public static func binding(forKeyCode code: UInt16) -> KeyBinding? { byCode[code] }

    /// Every C64 key some Mac key reaches (directly or as part of a chord).
    public static var reachableC64Keys: Set<C64Key> { Set(bindings.flatMap(\.c64)) }

    /// The Mac keys that produce `key` (alone or in a chord), for the keyboard reference.
    public static func macKeys(for key: C64Key) -> [MacKeyCode] {
        bindings.filter { $0.c64.contains(key) }.map(\.mac)
    }
}
