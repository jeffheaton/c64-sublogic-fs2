/// The browser's names for the keys (`KeyboardEvent.code`, the UI Events code values): physical
/// positions, as the Mac's virtual key codes are, so the web build maps the same keys to the C64
/// as the Mac app (`KeyMapper` stays keyed by `MacKeyCode`). The web page translates each key
/// event's code with the table the worker sends it (`webCodeTable`).
extension MacKeyCode {
    /// The browser's `KeyboardEvent.code` for this key.
    public var webCode: String {
        switch self {
        case .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w,
             .x, .y, .z:
            return "Key" + String(describing: self).uppercased()
        case .digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9:
            return "Digit" + String(String(describing: self).last!)
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4, .keypad5, .keypad6, .keypad7, .keypad8,
             .keypad9:
            return "Numpad" + String(String(describing: self).last!)
        case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
            return String(describing: self).uppercased()
        case .isoSection: return "IntlBackslash"
        case .equal: return "Equal"
        case .minus: return "Minus"
        case .rightBracket: return "BracketRight"
        case .leftBracket: return "BracketLeft"
        case .returnKey: return "Enter"
        case .quote: return "Quote"
        case .semicolon: return "Semicolon"
        case .backslash: return "Backslash"
        case .comma: return "Comma"
        case .slash: return "Slash"
        case .period: return "Period"
        case .tab: return "Tab"
        case .space: return "Space"
        case .grave: return "Backquote"
        case .delete: return "Backspace"
        case .escape: return "Escape"
        case .command: return "MetaLeft"
        case .rightCommand: return "MetaRight"
        case .shift: return "ShiftLeft"
        case .rightShift: return "ShiftRight"
        case .capsLock: return "CapsLock"
        case .option: return "AltLeft"
        case .rightOption: return "AltRight"
        case .control: return "ControlLeft"
        case .rightControl: return "ControlRight"
        case .function: return "Fn"
        case .keypadDecimal: return "NumpadDecimal"
        case .keypadMultiply: return "NumpadMultiply"
        case .keypadPlus: return "NumpadAdd"
        case .keypadClear: return "NumLock"
        case .keypadDivide: return "NumpadDivide"
        case .keypadEnter: return "NumpadEnter"
        case .keypadMinus: return "NumpadSubtract"
        case .keypadEquals: return "NumpadEqual"
        case .help: return "Insert"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "PageUp"
        case .pageDown: return "PageDown"
        case .forwardDelete: return "Delete"
        case .leftArrow: return "ArrowLeft"
        case .rightArrow: return "ArrowRight"
        case .downArrow: return "ArrowDown"
        case .upArrow: return "ArrowUp"
        }
    }

    /// The key a browser names `webCode`, nil for keys the Mac has no code for.
    public init?(webCode: String) {
        guard let key = Self.byWebCode[webCode] else { return nil }
        self = key
    }

    private static let byWebCode: [String: MacKeyCode] = {
        var d: [String: MacKeyCode] = [:]
        for key in allCases { d[key.webCode] = key }
        return d
    }()

    /// The keys the C64 uses (those with a binding), as `code=mac key code` lines in code order:
    /// what the web page translates its key events with.
    public static var webCodeTable: String {
        KeyMapper.bindings.map(\.mac).reduce(into: [MacKeyCode]()) { if !$0.contains($1) { $0.append($1) } }
            .sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.webCode)=\($0.rawValue)" }
            .joined(separator: "\n")
    }
}

/// Which keyboard the reference names the keys for.
public enum KeyLabelStyle: Sendable, Equatable {
    /// The Mac's key caps (Return, Option, Control, Delete, fn combinations).
    case mac
    /// A browser's generic names (Enter, Alt, Ctrl, Backspace, Delete, Insert, Num Lock).
    case web
}

extension MacKeyCode {
    /// The label printed on this key for `style`.
    public func label(_ style: KeyLabelStyle) -> String {
        guard style == .web else { return label }
        switch self {
        case .returnKey: return "Enter"
        case .delete: return "Backspace"
        case .forwardDelete: return "Delete"
        case .help: return "Insert"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .option: return "Left Alt"
        case .rightOption: return "Right Alt"
        case .control: return "Left Ctrl"
        case .rightControl: return "Right Ctrl"
        case .command: return "Left Meta"
        case .rightCommand: return "Right Meta"
        case .keypadClear: return "Num Lock"
        case .isoSection: return "§ (ISO key)"
        case .function: return "Fn"
        default: return label
        }
    }
}
