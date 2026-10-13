/// Mac virtual key codes (`NSEvent.keyCode`), with the values of Carbon's `kVK_*` constants
/// (HIToolbox/Events.h). They name physical key positions on an ANSI keyboard, independent of the
/// active keyboard layout, which is what a positional C64 mapping needs.
public enum MacKeyCode: UInt16, CaseIterable, Sendable {
    case a = 0x00, s = 0x01, d = 0x02, f = 0x03, h = 0x04, g = 0x05, z = 0x06, x = 0x07
    case c = 0x08, v = 0x09, isoSection = 0x0A, b = 0x0B, q = 0x0C, w = 0x0D, e = 0x0E, r = 0x0F
    case y = 0x10, t = 0x11, digit1 = 0x12, digit2 = 0x13, digit3 = 0x14, digit4 = 0x15, digit6 = 0x16
    case digit5 = 0x17, equal = 0x18, digit9 = 0x19, digit7 = 0x1A, minus = 0x1B, digit8 = 0x1C
    case digit0 = 0x1D, rightBracket = 0x1E, o = 0x1F, u = 0x20, leftBracket = 0x21, i = 0x22, p = 0x23
    case returnKey = 0x24, l = 0x25, j = 0x26, quote = 0x27, k = 0x28, semicolon = 0x29
    case backslash = 0x2A, comma = 0x2B, slash = 0x2C, n = 0x2D, m = 0x2E, period = 0x2F
    case tab = 0x30, space = 0x31, grave = 0x32, delete = 0x33, escape = 0x35
    case rightCommand = 0x36, command = 0x37, shift = 0x38, capsLock = 0x39, option = 0x3A
    case control = 0x3B, rightShift = 0x3C, rightOption = 0x3D, rightControl = 0x3E, function = 0x3F
    case keypadDecimal = 0x41, keypadMultiply = 0x43, keypadPlus = 0x45, keypadClear = 0x47
    case keypadDivide = 0x4B, keypadEnter = 0x4C, keypadMinus = 0x4E, keypadEquals = 0x51
    case keypad0 = 0x52, keypad1 = 0x53, keypad2 = 0x54, keypad3 = 0x55, keypad4 = 0x56
    case keypad5 = 0x57, keypad6 = 0x58, keypad7 = 0x59, keypad8 = 0x5B, keypad9 = 0x5C
    case f5 = 0x60, f6 = 0x61, f7 = 0x62, f3 = 0x63, f8 = 0x64, f9 = 0x65, f11 = 0x67, f10 = 0x6D
    case f12 = 0x6F, help = 0x72, home = 0x73, pageUp = 0x74, forwardDelete = 0x75, f4 = 0x76
    case end = 0x77, f2 = 0x78, pageDown = 0x79, f1 = 0x7A
    case leftArrow = 0x7B, rightArrow = 0x7C, downArrow = 0x7D, upArrow = 0x7E

    /// True for the modifier keys, which arrive as `flagsChanged` events instead of key down/up.
    public var isModifier: Bool {
        switch self {
        case .command, .rightCommand, .shift, .rightShift, .capsLock, .option, .rightOption, .control,
             .rightControl, .function:
            return true
        default:
            return false
        }
    }

    /// The bit for this key in the device-dependent part of `NSEvent.modifierFlags` (IOKit's
    /// `NX_DEVICE*KEYMASK`), which tells the left and right modifier keys apart.
    public var deviceModifierMask: UInt? {
        switch self {
        case .control: return 0x0000_0001
        case .shift: return 0x0000_0002
        case .rightShift: return 0x0000_0004
        case .command: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .option: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        case .rightControl: return 0x0000_2000
        default: return nil
        }
    }

    /// The device-independent modifier flag (`NSEvent.ModifierFlags` raw value) for this key.
    public var modifierFlag: UInt? {
        switch self {
        case .capsLock: return 1 << 16
        case .shift, .rightShift: return 1 << 17
        case .control, .rightControl: return 1 << 18
        case .option, .rightOption: return 1 << 19
        case .command, .rightCommand: return 1 << 20
        case .function: return 1 << 23
        default: return nil
        }
    }

    /// Whether a `flagsChanged` event for this key means it is now down. Uses the left/right
    /// device bits when the event carries them and the shared modifier flag otherwise.
    public func isDown(modifierFlags raw: UInt) -> Bool {
        let deviceBits: UInt = 0x0000_207F
        if let mask = deviceModifierMask, raw & deviceBits != 0 { return raw & mask != 0 }
        if let flag = modifierFlag { return raw & flag != 0 }
        return false
    }

    /// Short label printed on the Mac key, for the keyboard reference.
    public var label: String {
        switch self {
        case .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w,
             .x, .y, .z:
            return String(describing: self).uppercased()
        case .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
            return String(String(describing: self).last!)
        case .isoSection: return "§"
        case .equal: return "="
        case .minus: return "-"
        case .rightBracket: return "]"
        case .leftBracket: return "["
        case .returnKey: return "Return"
        case .quote: return "'"
        case .semicolon: return ";"
        case .backslash: return "\\"
        case .comma: return ","
        case .slash: return "/"
        case .period: return "."
        case .tab: return "Tab"
        case .space: return "Space"
        case .grave: return "`"
        case .delete: return "Delete"
        case .escape: return "Esc"
        case .command: return "Left Command"
        case .rightCommand: return "Right Command"
        case .shift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .capsLock: return "Caps Lock"
        case .option: return "Left Option"
        case .rightOption: return "Right Option"
        case .control: return "Left Control"
        case .rightControl: return "Right Control"
        case .function: return "fn"
        case .keypadDecimal: return "Keypad ."
        case .keypadMultiply: return "Keypad *"
        case .keypadPlus: return "Keypad +"
        case .keypadClear: return "Keypad Clear"
        case .keypadDivide: return "Keypad /"
        case .keypadEnter: return "Keypad Enter"
        case .keypadMinus: return "Keypad -"
        case .keypadEquals: return "Keypad ="
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4, .keypad5, .keypad6, .keypad7, .keypad8,
             .keypad9:
            return "Keypad " + String(String(describing: self).last!)
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return String(describing: self).uppercased()
        case .help: return "Help / Insert"
        case .home: return "Home (fn ←)"
        case .end: return "End (fn →)"
        case .pageUp: return "Page Up (fn ↑)"
        case .pageDown: return "Page Down (fn ↓)"
        case .forwardDelete: return "Forward Delete (fn Delete)"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .downArrow: return "↓"
        case .upArrow: return "↑"
        }
    }
}
