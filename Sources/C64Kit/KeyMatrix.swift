/// A physical C64 key, identified by its keyboard-matrix position. `rawValue` = column * 8 + row,
/// where the column is selected by a low bit on CIA1 port A ($DC00) and the row reads on port B ($DC01).
public enum C64Key: Int, CaseIterable, Sendable {
    case instDel = 0, returnKey, cursorRight, f7, f1, f3, f5, cursorDown
    case digit3, w, a, digit4, z, s, e, leftShift
    case digit5, r, d, digit6, c, f, t, x
    case digit7, y, g, digit8, b, h, u, v
    case digit9, i, j, digit0, m, k, o, n
    case plus, p, l, minus, period, colon, at, comma
    case pound, asterisk, semicolon, clrHome, rightShift, equals, upArrow, slash
    case digit1, leftArrow, control, digit2, space, commodore, q, runStop

    public var column: Int { rawValue >> 3 }
    public var row: Int { rawValue & 7 }

    /// Label as printed on the C64 keycap (unshifted legend).
    public var label: String {
        switch self {
        case .instDel: return "INST/DEL"
        case .returnKey: return "RETURN"
        case .cursorRight: return "CRSR →"
        case .cursorDown: return "CRSR ↓"
        case .f1: return "F1"
        case .f3: return "F3"
        case .f5: return "F5"
        case .f7: return "F7"
        case .leftShift: return "LEFT SHIFT"
        case .rightShift: return "RIGHT SHIFT"
        case .plus: return "+"
        case .minus: return "-"
        case .period: return "."
        case .colon: return ":"
        case .at: return "@"
        case .comma: return ","
        case .pound: return "£"
        case .asterisk: return "*"
        case .semicolon: return ";"
        case .clrHome: return "CLR/HOME"
        case .equals: return "="
        case .upArrow: return "↑"
        case .slash: return "/"
        case .leftArrow: return "←"
        case .control: return "CTRL"
        case .space: return "SPACE"
        case .commodore: return "C="
        case .runStop: return "RUN/STOP"
        case .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
            return String(String(describing: self).last!)
        default:
            return String(describing: self).uppercased()
        }
    }
}

/// Joystick directions and fire, as the active-low bits of a control port (bit set here = pressed).
public struct JoystickState: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let up = JoystickState(rawValue: 0x01)
    public static let down = JoystickState(rawValue: 0x02)
    public static let left = JoystickState(rawValue: 0x04)
    public static let right = JoystickState(rawValue: 0x08)
    public static let fire = JoystickState(rawValue: 0x10)
}

/// Pressed keys and joysticks, and what CIA1's ports read back for a given column selection.
public struct KeyMatrix: Sendable, Equatable {
    /// Bit r of `columns[c]` set = key at (c, r) pressed.
    public private(set) var columns: [UInt8] = Array(repeating: 0, count: 8)
    /// Control port 1 (read on $DC01) and port 2 (read on $DC00).
    public var joystick1 = JoystickState()
    public var joystick2 = JoystickState()

    public init() {}

    public mutating func set(_ key: C64Key, pressed: Bool) {
        if pressed { columns[key.column] |= 1 << key.row } else { columns[key.column] &= ~(1 << key.row) }
    }

    public func isPressed(_ key: C64Key) -> Bool { columns[key.column] & (1 << key.row) != 0 }

    public mutating func releaseAll() {
        columns = Array(repeating: 0, count: 8)
        joystick1 = []; joystick2 = []
    }

    /// Value read on $DC01 when port A drives `portA` (active-low column select).
    public func readPortB(portA: UInt8, portBOut: UInt8 = 0xFF) -> UInt8 {
        var rows: UInt8 = 0
        for c in 0..<8 where portA & (1 << c) == 0 { rows |= columns[c] }
        return portBOut & ~rows & ~joystick1.rawValue
    }

    /// Value read on $DC00: the driven column bits, pulled low by joystick 2 and by keys whose
    /// row is driven low on port B (reverse scanning).
    public func readPortA(portAOut: UInt8, portB: UInt8 = 0xFF) -> UInt8 {
        var cols: UInt8 = 0
        for c in 0..<8 where columns[c] & ~portB != 0 { cols |= 1 << c }
        return portAOut & ~cols & ~joystick2.rawValue
    }
}
