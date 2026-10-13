
/// A scripted run: frames to wait, keys and joystick to hold, screenshots to take.
///
/// The format is shared by the lab (`fs2lab run`, which plays every step) and the app's headless
/// mode (`FS2 --headless`, which plays the steps any `GameEngine` supports), so it lives here and
/// not in the lab: the shipped app parses sessions without linking the lab.
public struct Session: Codable, Sendable {
    public enum Step: Codable, Sendable {
        case wait(frames: Int)
        case press(key: String, frames: Int)
        case screenshot(name: String)
        /// Hold joystick directions ("up+fire") on port 1 or 2 for some frames.
        case joystick(port: Int, directions: String, frames: Int)
        /// Write a byte into RAM (for experiments).
        case poke(address: Int, value: UInt8)
        /// Run until the PC reaches an address (or a frame limit passes).
        case waitPC(address: Int, maxFrames: Int)
        /// Save a RAM snapshot.
        case snapshot(name: String)
        /// Press (`down`) or release (`up`) keys without running any frames, so a key can stay held
        /// across later steps (e.g. RUN/STOP held while RESTORE is pressed).
        case keysDown(keys: String)
        case keysUp(keys: String)
        /// Raise an NMI, as the RESTORE key does (while a replay recorder is attached, through it:
        /// taken and logged at the next poll point).
        case nmi
        /// Print the frame number, PC, SP and `count` RAM bytes from `address` (for lab evidence).
        case peek(address: Int, count: Int)
        /// Run until RAM[address] equals (or, when `negate`, differs from) `value`, or a frame limit.
        case waitByte(address: Int, value: UInt8, negate: Bool, maxFrames: Int)
        /// Overlay-aware coverage recording: "on", "off", or "save" (writes NAME.cov).
        case coverage(command: String, name: String)
        /// Report every instruction that reads or writes RAM in [low, high] from now on (each PC
        /// once), for finding who touches an address. Not combinable with `cov:` recording.
        case watch(low: Int, high: Int)
        /// Print the 40x25 text screen the VIC shows (screen codes decoded as the upper/lowercase
        /// set), so text screens can be checked without a character ROM.
        case textScreen
    }
    public var steps: [Step]

    public init(steps: [Step]) { self.steps = steps }

    /// Compact form, whitespace separated (lines starting with # are comments):
    /// wait:FRAMES  key:NAME[+NAME]:FRAMES  shot:NAME  joy1:up+fire:FRAMES  joy2:down:FRAMES
    /// poke:ADDR:VAL (hex)  pc:ADDR[:MAXFRAMES] (hex)  snap:NAME
    /// down:NAME[+NAME]  up:NAME[+NAME]  nmi  peek:ADDR[:COUNT] (hex)
    /// until:ADDR:VAL[:MAXFRAMES] (hex; VAL may be !VAL for "until it differs")
    /// cov:on  cov:off  cov:save:NAME  (overlay-aware coverage, written as NAME.cov; see SessionCoverage)
    /// text  (print the text screen)  watch:LOW:HIGH (hex; report readers/writers of the range)
    /// Key names: see `C64Key.named` (the + and : keys are written PLUS and COLON).
    /// Addresses must lie in $0000-$FFFF; a malformed step throws `SessionError.badStep`.
    public static func parse(_ text: String) throws -> Session {
        var steps: [Step] = []
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: " ")
        func hex(_ s: String) -> Int? { Int(s.replacing("$", with: ""), radix: 16) }
        /// A hex address inside the 64 KB space (a sign or an out-of-range value is rejected).
        func address(_ s: String) -> Int? { hex(s).flatMap { (0...0xFFFF).contains($0) ? $0 : nil } }
        for token in body.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let parts = token.split(separator: ":").map(String.init)
            let bad = SessionError.badStep(String(token))
            switch parts.first {
            case "down", "up":
                guard parts.count == 2 else { throw bad }
                steps.append(parts[0] == "down" ? .keysDown(keys: parts[1]) : .keysUp(keys: parts[1]))
            case "nmi":
                guard parts.count == 1 else { throw bad }
                steps.append(.nmi)
            case "text":
                guard parts.count == 1 else { throw bad }
                steps.append(.textScreen)
            case "peek":
                guard (2...3).contains(parts.count), let a = address(parts[1]) else { throw bad }
                var count = 1
                if parts.count == 3 {
                    guard let c = hex(parts[2]), (1...0x10000).contains(c) else { throw bad }
                    count = c
                }
                steps.append(.peek(address: a, count: count))
            case "until":
                guard (3...4).contains(parts.count), let a = address(parts[1]) else { throw bad }
                let negate = parts[2].hasPrefix("!")
                guard let v = hex(String(parts[2].drop(while: { $0 == "!" }))), (0...0xFF).contains(v) else {
                    throw bad
                }
                steps.append(.waitByte(address: a, value: UInt8(v), negate: negate,
                                       maxFrames: parts.count > 3 ? Int(parts[3]) ?? 600 : 600))
            case "watch":
                guard parts.count == 3, let lo = address(parts[1]), let hi = address(parts[2]), lo <= hi else {
                    throw bad
                }
                steps.append(.watch(low: lo, high: hi))
            case "cov":
                guard parts.count >= 2, ["on", "off", "save"].contains(parts[1]),
                      parts[1] == "save" ? parts.count == 3 && !parts[2].isEmpty : parts.count == 2 else { throw bad }
                steps.append(.coverage(command: parts[1], name: parts.count > 2 ? parts[2] : ""))
            case "wait":
                guard parts.count >= 2 else { throw bad }
                steps.append(.wait(frames: Int(parts[1]) ?? 1))
            case "key":
                guard parts.count >= 2 else { throw bad }
                steps.append(.press(key: parts[1], frames: parts.count > 2 ? Int(parts[2]) ?? 8 : 8))
            case "shot":
                guard parts.count >= 2 else { throw bad }
                steps.append(.screenshot(name: parts[1]))
            case "joy1", "joy2":
                guard parts.count >= 2 else { throw bad }
                steps.append(.joystick(port: parts[0] == "joy1" ? 1 : 2, directions: parts[1],
                                       frames: parts.count > 2 ? Int(parts[2]) ?? 8 : 8))
            case "poke":
                guard parts.count == 3, let a = address(parts[1]),
                      let v = UInt8(parts[2].replacing("$", with: ""), radix: 16) else {
                    throw bad
                }
                steps.append(.poke(address: a, value: v))
            case "pc":
                guard parts.count >= 2, let a = address(parts[1]) else { throw bad }
                steps.append(.waitPC(address: a, maxFrames: parts.count > 2 ? Int(parts[2]) ?? 600 : 600))
            case "snap":
                guard parts.count >= 2 else { throw bad }
                steps.append(.snapshot(name: parts[1]))
            default: throw bad
            }
        }
        return Session(steps: steps)
    }
}

/// A session that cannot be parsed or played.
public enum SessionError: Error, CustomStringConvertible {
    case badStep(String)
    case unknownKey(String)

    public var description: String {
        switch self {
        case .badStep(let t): return "cannot parse session step '\(t)'"
        case .unknownKey(let k): return "unknown C64 key '\(k)'"
        }
    }
}

extension C64Key {
    /// Looks a key up by name: letters/digits, or names like RETURN, SPACE, RUNSTOP, F1, CTRL.
    /// In session steps '+' joins keys and ':' separates fields, so those two keys are PLUS and COLON.
    public static func named(_ name: String) -> C64Key? {
        let n = name.uppercased()
        if n.count == 1, let ch = n.first {
            if ch.isLetter { return allCases.first { String(describing: $0).uppercased() == n } }
            if ch.isNumber { return allCases.first { String(describing: $0) == "digit\(ch)" } }
            switch ch {
            case "+": return .plus
            case "-": return .minus
            case ".": return .period
            case ",": return .comma
            case ":": return .colon
            case ";": return .semicolon
            case "/": return .slash
            case "=": return .equals
            case "*": return .asterisk
            case "@": return .at
            default: return nil
            }
        }
        let aliases: [String: C64Key] = [
            "RETURN": .returnKey, "SPACE": .space, "RUNSTOP": .runStop, "STOP": .runStop, "HOME": .clrHome,
            "CLRHOME": .clrHome, "DEL": .instDel, "CTRL": .control, "LSHIFT": .leftShift, "RSHIFT": .rightShift,
            "F1": .f1, "F3": .f3, "F5": .f5, "F7": .f7, "CBM": .commodore, "LEFTARROW": .leftArrow, "UPARROW": .upArrow,
            "CRSRDOWN": .cursorDown, "CRSRRIGHT": .cursorRight, "POUND": .pound,
            "COLON": .colon, "PLUS": .plus,
        ]
        return aliases[n]
    }

    /// The keys of a "+"-joined name ("CTRL+C").
    public static func keys(named name: String) throws -> [C64Key] {
        try name.split(separator: "+").map { part -> C64Key in
            guard let k = named(String(part)) else { throw SessionError.unknownKey(String(part)) }
            return k
        }
    }
}

extension JoystickState {
    /// Directions from a "+"-joined list ("up+fire"; up, down, left, right, fire).
    public init(directions text: String) throws {
        self = []
        for d in text.lowercased().split(separator: "+") {
            switch d {
            case "up": insert(.up)
            case "down": insert(.down)
            case "left": insert(.left)
            case "right": insert(.right)
            case "fire": insert(.fire)
            default: throw SessionError.badStep(String(d))
            }
        }
    }
}

/// One screen code as text: the upper/lowercase set, a reverse-video cell prefixed with `~`.
public func screenCodeText(_ code: UInt8) -> String {
    let c = code & 0x7F
    let ch: Character
    switch c {
    case 0x00: ch = "@"
    case 0x01...0x1A: ch = Character(UnicodeScalar(c + 0x60))
    // $1B-$1F are [ £ ] ↑ ← (ASCII $5B-$5F positions), not the control codes $1B-$1F.
    case 0x1B: ch = "["
    case 0x1C: ch = "£"
    case 0x1D: ch = "]"
    case 0x1E: ch = "↑"
    case 0x1F: ch = "←"
    case 0x20...0x3F: ch = Character(UnicodeScalar(c))
    case 0x40: ch = "-"
    case 0x41...0x5A: ch = Character(UnicodeScalar(c))
    default: ch = "?"
    }
    return code & 0x80 != 0 ? "~\(ch)" : String(ch)
}
