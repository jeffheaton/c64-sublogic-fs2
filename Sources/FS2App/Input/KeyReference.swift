import C64Kit

/// The keyboard reference: Machine ▸ Keyboard Reference (⌘/), the controls tables of README.md
/// (`FS2 --key-reference` prints them) and the key names the help uses. Everything is generated
/// from `KeyMapper.bindings` plus what each key does in Flight Simulator II (re/docs/input.md,
/// editor.md).
///
/// What a key does follows the original's own path, so the reference is complete by construction:
/// a matrix position gives a command code (the code table $2482), CTRL held subtracts $40, and
/// the code picks a handler (the dispatch table $2718); the editor reads the same codes. The
/// codes and functions here are the documented ones; `KeyReferenceDiskTests` checks them against the
/// tables on the user's disk.
enum KeyReference {
    struct Row: Sendable, Equatable {
        var mac: String
        var c64: String
        var function: String
        /// The command code the row's keys queue, for keyboard and Control rows (not displayed).
        var code: UInt8?

        init(mac: String, c64: String, function: String, code: UInt8? = nil) {
            self.mac = mac
            self.c64 = c64
            self.function = function
            self.code = code
        }
    }

    struct Section: Sendable, Equatable {
        var title: String
        var rows: [Row]
    }

    enum SectionTitle {
        static let keyboard = "Keyboard"
        static let control = "Control combinations"
        static let keypad = "Keypad as joystick (Settings)"
        static let gamepad = "Game controller"
        static let prompts = "Prompts and menus in the game"
        static let machine = "Mac shortcuts"
        static let unmapped = "Not mapped"
    }

    // MARK: The original's command codes

    /// The command code the original's code table ($2482) gives a key (input.md, "Matrix →
    /// command code"): letters and digits their ASCII code, the punctuation and editing keys the
    /// codes below. nil stands for a code of $80 or more, which is never queued: the F-keys, the
    /// cursor keys, @ £ * =, RIGHT SHIFT, C= and CTRL itself (its code only marks CTRL as held).
    static func code(of key: C64Key) -> UInt8? {
        switch key {
        case .instDel, .colon, .leftArrow: return 0x08
        case .returnKey: return 0x0D
        case .cursorDown: return 0x00
        case .leftShift: return 0x01
        case .clrHome: return 0x1B
        case .semicolon: return 0x15
        case .space: return 0x20
        case .plus: return 0x2B
        case .comma: return 0x2C
        case .minus, .upArrow: return 0x2D
        case .period: return 0x2E
        case .slash: return 0x2F
        case .runStop: return 0x50
        case .cursorRight, .f1, .f3, .f5, .f7, .at, .pound, .asterisk, .equals, .rightShift, .commodore, .control:
            return nil
        default:
            // Letters and digits.
            let label = key.label.unicodeScalars
            guard label.count == 1, let scalar = label.first, scalar.isASCII else { return nil }
            return UInt8(scalar.value)
        }
    }

    /// The code queued for `key` pressed while CTRL is held: its code − $40 (`requeueKey` $24EB),
    /// nil when the dispatcher drops the result. Codes below $40 wrap to $C0 and up, so CTRL with
    /// a digit, SPACE or punctuation does nothing; letters give the CTRL codes $01-$1A.
    static func controlCode(of key: C64Key) -> UInt8? {
        guard let c = code(of: key), c >= 0x40 else { return nil }
        let result = c - 0x40
        return result < 0x60 ? result : nil
    }

    /// What each command code does in flight: the handlers of the dispatch table $2718
    /// (input.md, "Command map"). Every other code $00-$5F goes to an RTS and does nothing.
    static let flightFunctions: [UInt8: String] = {
        let adf = "ADF: select the first frequency digit; quick repeats select the next digits, then the fuel tank"
        let editor = "Open the editor (the mode settings screens)"
        let pause = "Pause (the next key resumes)"
        let lights = "Lights on/off"
        // In slew the throttle keys also step the altitude rate `$0AC5` (input.md, "Slew mode").
        let throttleDown = "Throttle down. Slew: altitude rate down"
        let throttleUp = "Throttle up. Slew: altitude rate up"
        return [
            0x01: adf,
            0x02: "Recalibrate the altimeter (clears its drift)",
            0x03: "COM radio: select the MHz; a quick second press selects the kHz",
            0x04: "Realign the heading indicator (DG) with the compass",
            0x05: "Database info screen (the scenery areas on the disk)",
            0x06: "Select the fuel tank (, and . switch tanks)",
            0x08: throttleDown,
            0x09: "Carburetor heat on/off",
            0x0C: lights,
            0x0D: "Magnetos and mixture: then 1-5 sets the magnetos (OFF, R, L, BOTH, START), , and . the mixture",
            0x0E: "NAV radio: select the MHz (then 1 or 2 picks NAV 1 or NAV 2); a quick second press selects the kHz",
            0x10: pause,
            0x14: "Transponder: select the digits (as Control-X). Slew: copy the view angles back into the attitude",
            0x15: throttleUp,
            0x16: "OBS: select the course (then 1 or 2 picks OBS 1 or OBS 2)",
            0x18: "Transponder: select the first digit; quick repeats select the next digits, then the OBS",
            0x1B: editor,
            0x20: "Brakes on the ground; guns in the air (Europe 1917)",
            0x2B: "Recall the current mode (start the flight over from its settings)",
            0x2C: "Decrease the selected item (radio, transponder, OBS, ADF, mixture, fuel tank). Radar: zoom out",
            0x2E: "Increase the selected item. Radar: zoom in",
            0x2F: "The next throttle key goes straight to full or idle",
            0x31: "After Return: magnetos OFF. After Control-N: NAV 1. After Control-V: OBS 1",
            0x32: "After Return: magnetos R. After Control-N: NAV 2. After Control-V: OBS 2",
            0x33: "Magnetos L (no Return needed)",
            0x34: "Radar view (, and . zoom, 5 leaves it). After Return: magnetos BOTH",
            0x35: "View select: then T Y H N B V F R G picks the view. Leaves the radar view. After Return: START",
            0x38: "Slew: pitch rate down",
            0x39: "Slew: pitch rate up",
            0x41: adf,
            0x42: "Elevator up (nose up). After 5: look back. Slew: south",
            0x43: "Rudder left",
            0x45: editor,
            0x46: "Ailerons left (bank left). After 5: look left. Slew: west",
            0x47: "Center the ailerons and rudder. After 5: look down (the bombsight in Europe 1917). Slew: stop all motion",
            0x48: "Ailerons right (bank right). After 5: look right. Slew: east",
            0x4C: lights,
            0x4D: "Rudder right",
            0x4E: "Flaps down. After 5: look back right. Slew: heading rate down",
            0x50: pause,
            0x51: "Course plotter (a menu: A to E)",
            0x52: "Trim nose down. After 5: look front left. Slew: bank rate up",
            0x53: "Save the situation as a user mode (the current mode + 10)",
            0x54: "Elevator down (nose down). After 5: look ahead. Slew: north",
            0x56: "Trim nose up. After 5: look back left. Slew: heading rate up",
            0x57: "Declare war (Europe 1917)",
            0x58: "Drop a bomb (Europe 1917)",
            0x59: "Flaps up. After 5: look front right. Slew: bank rate down",
            0x5A: "Slew: zero the pitch, bank and heading",
        ]
    }()

    /// What the editor (E or CLR/HOME) does with a code (editor.md, "Keys"). It ignores the rest.
    static let editorFunctions: [UInt8: String] = {
        var f: [UInt8: String] = [
            0x0D: "next line (accepts the number typed)",
            0x2D: "previous line",
            0x45: "leave the editor",
            0x08: "delete the last digit",
            0x2B: "recall the current mode",
            0x53: "save the situation as a user mode",
            0x18: "load the mode library file",
            0x1A: "save the mode library file",
        ]
        for digit in UInt8(0x30)...0x39 { f[digit] = "type a digit" }
        return f
    }()

    /// What a command code does, in flight and in the editor.
    static func describe(code: UInt8?) -> String {
        guard let code else { return noFunction }
        var parts: [String] = []
        if let f = flightFunctions[code] { parts.append(f) }
        if let e = editorFunctions[code] { parts.append("In the editor: " + e) }
        return parts.isEmpty ? noFunction : parts.joined(separator: ". ")
    }

    static let noFunction = "No function in the game"

    /// What a C64 key does on its own.
    static func function(of key: C64Key) -> String {
        switch key {
        case .control: return "Hold for the Control combinations below (the C64's CTRL commands)"
        case .rightShift: return "Nothing (the game ignores it)"
        case .leftShift: return describe(code: code(of: .leftShift)) + " (as Control-A)"
        default: return describe(code: code(of: key))
        }
    }

    /// The C64 key a binding stands for when RIGHT SHIFT (which queues nothing) is left out of its
    /// chord: SHIFT + INST/DEL is INST/DEL to the game. nil for a chord of two live keys.
    static func effectiveKey(of binding: KeyBinding) -> C64Key? {
        let keys = binding.c64.filter { $0 != .rightShift }
        if keys.isEmpty { return binding.c64.first }
        return keys.count == 1 ? keys[0] : nil
    }

    /// The Mac key that types `key` on its own (not a chord, not the keypad), for running text.
    static func macName(for key: C64Key) -> String {
        let binding = KeyMapper.bindings.first { $0.c64 == [key] && !$0.mac.label.hasPrefix("Keypad") }
            ?? KeyMapper.bindings.first { $0.c64 == [key] }
        guard let label = binding?.mac.label else { return key.label }
        // "Home (fn ←)" → "Home".
        if let paren = label.range(of: " (") { return String(label[..<paren.lowerBound]) }
        return label
    }

    // MARK: Sections

    /// All sections, in display order.
    static func sections() -> [Section] {
        [keyboardSection(), controlSection(), keypadSection(), gamepadSection(), promptsSection(),
         machineSection(), unmappedSection()]
    }

    /// One row per key binding that is not a keypad joystick, in `KeyMapper.bindings` order.
    static func keyboardSection() -> Section {
        let rows = KeyMapper.bindings.filter { $0.joystick == nil }.map { b -> Row in
            let key = effectiveKey(of: b)
            let code = key.flatMap(code(of:))
            return Row(mac: b.mac.label, c64: b.c64Label, function: key.map(function(of:)) ?? noFunction, code: code)
        }
        return Section(title: SectionTitle.keyboard, rows: rows)
    }

    /// One row per Mac key that, with Control held, queues a code the game uses. Sorted by code.
    static func controlSection() -> Section {
        var rows: [Row] = []
        for b in KeyMapper.bindings where b.joystick == nil {
            guard let key = effectiveKey(of: b), let code = controlCode(of: key),
                  flightFunctions[code] != nil || editorFunctions[code] != nil else { continue }
            rows.append(Row(mac: "Control-" + b.mac.label, c64: "CTRL + " + key.label,
                            function: describe(code: code), code: code))
        }
        rows.sort { ($0.code ?? 0, $0.mac) < ($1.code ?? 0, $1.mac) }
        return Section(title: SectionTitle.control, rows: rows)
    }

    /// The keypad bindings that drive a joystick when keypad-as-joystick is on.
    static func keypadSection() -> Section {
        let rows = KeyMapper.bindings.compactMap { b -> Row? in
            guard let j = b.joystick else { return nil }
            return Row(mac: b.mac.label, c64: joystickLabel(j),
                       function: joystickFunction(j) + " (keypad-as-joystick off: \(b.c64Label))")
        }
        return Section(title: SectionTitle.keypad, rows: rows)
    }

    /// Game controllers (`Gamepad`).
    static func gamepadSection() -> Section {
        Section(title: SectionTitle.gamepad, rows: [
            Row(mac: "Left stick or D-pad", c64: "Joystick 1", function: "The yoke: nose down/up (like T/B), bank left/right (like F/H)"),
            Row(mac: "A button", c64: "Joystick 1 fire", function: "View select (like 5)"),
            Row(mac: "Right stick up / down", c64: "Joystick 2 up / down", function: "Throttle up / down"),
            Row(mac: "B button or right trigger", c64: "Joystick 2 fire", function: "Guns (Europe 1917)"),
        ])
    }

    /// The original's own prompts and menus (`waitForKey` users other than the editor).
    static func promptsSection() -> Section {
        Section(title: SectionTitle.prompts, rows: [
            Row(mac: "A / B", c64: "A / B", function: "Title, WHAT DISPLAY ARE YOU USING?: A color, B black and white"),
            Row(mac: "A / B", c64: "A / B", function: "SELECT OPERATING MODE: A the demo (any key takes over), B regular flight"),
            Row(mac: "A to E", c64: "A to E", function: "Course plotter menu (Q): A record, B show the plot, C precise recording, D off, E back to flight"),
            Row(mac: "Any key", c64: "Any key", function: "Ends the pause and the database info screen (the key is used up)"),
        ])
    }

    /// The Machine menu items that act on the C64.
    static func machineSection() -> Section {
        Section(title: SectionTitle.machine, rows: [
            Row(mac: "⌘P", c64: "—", function: "Pause or resume the whole machine, sound included (Machine ▸ Pause)"),
            Row(mac: "⌘R", c64: "RUN/STOP + RESTORE", function: "Restart the program: back to the title after the reload (Machine ▸ Restart)"),
            Row(mac: "⇧⌘R", c64: "Power off and on", function: "Cold start without the disk loading wait (Machine ▸ Reset)"),
            Row(mac: "⌘/", c64: "—", function: "This keyboard reference"),
            Row(mac: "⌥⌘/", c64: "—", function: "Flight Simulator II Help"),
        ])
    }

    static func unmappedSection() -> Section {
        let rows = KeyMapper.unmappedByDesign.keys.sorted { $0.rawValue < $1.rawValue }.map { key in
            Row(mac: "(none)", c64: key.label, function: KeyMapper.unmappedByDesign[key] ?? "", code: code(of: key))
        }
        return Section(title: SectionTitle.unmapped, rows: rows)
    }

    // MARK: Joysticks

    static func joystickLabel(_ j: JoystickBinding) -> String {
        var parts: [String] = []
        if j.state.contains(.up) { parts.append("up") }
        if j.state.contains(.down) { parts.append("down") }
        if j.state.contains(.left) { parts.append("left") }
        if j.state.contains(.right) { parts.append("right") }
        if j.state.contains(.fire) { parts.append("fire") }
        return "Joystick \(j.port) " + parts.joined(separator: "+")
    }

    /// What the original's joystick routine ($2688) does with the bits (input.md, "Joysticks").
    static func joystickFunction(_ j: JoystickBinding) -> String {
        if j.port == 2 {
            if j.state.contains(.fire) { return "Guns (Europe 1917)" }
            return j.state.contains(.up) ? "Throttle up" : "Throttle down"
        }
        if j.state == .fire { return "View select (like 5)" }
        var parts: [String] = []
        if j.state.contains(.up) { parts.append("nose down (like T)") }
        if j.state.contains(.down) { parts.append("nose up (like B)") }
        if j.state.contains(.left) { parts.append("bank left (like F)") }
        if j.state.contains(.right) { parts.append("bank right (like H)") }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + String(text.dropFirst())
    }

    // MARK: Text forms

    /// The reference as plain text (tab separated), for copying.
    static func plainText() -> String {
        sections().map { s in
            ([s.title] + s.rows.map { "\($0.mac)\t\($0.c64)\t\($0.function)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static let markdownBegin = "<!-- BEGIN KEYBOARD REFERENCE: generated by `FS2 --key-reference`; do not edit by hand -->"
    static let markdownEnd = "<!-- END KEYBOARD REFERENCE -->"

    /// The controls tables of README.md (between the markers), as `FS2 --key-reference` prints them.
    static func markdown() -> String {
        var lines = [markdownBegin]
        for s in sections() {
            lines += ["", "### " + s.title, "", "| Mac | Commodore 64 | In Flight Simulator II |", "|---|---|---|"]
            for r in s.rows {
                lines.append("| \(markdownCode(r.mac)) | \(markdownCode(r.c64)) | \(markdownText(r.function)) |")
            }
        }
        lines += ["", markdownEnd]
        return lines.joined(separator: "\n")
    }

    /// A key label as a code span (backticks inside get a longer fence; table pipes are escaped).
    static func markdownCode(_ s: String) -> String {
        let fenced = s.contains("`") ? "`` \(s) ``" : "`\(s)`"
        return fenced.replacingOccurrences(of: "|", with: "\\|")
    }

    static func markdownText(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "|*_<>[]\\`".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
