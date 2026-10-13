import C64Kit
import Carbon.HIToolbox
@testable import FS2App
import Testing

@Suite struct KeyMapperTests {
    @Test func everyC64KeyIsReachableExceptTheDocumentedOnes() {
        let reachable = KeyMapper.reachableC64Keys
        let unreachable = Set(C64Key.allCases).subtracting(reachable)
        #expect(unreachable == Set(KeyMapper.unmappedByDesign.keys),
                "unreachable: \(unreachable.map(\.label)), documented: \(KeyMapper.unmappedByDesign.keys.map(\.label))")
        // The by-design exception list stays tiny: only LEFT SHIFT (the ADF-select quirk).
        #expect(Set(KeyMapper.unmappedByDesign.keys) == [.leftShift])
    }

    @Test func noMacKeyIsMappedTwice() {
        var seen: [MacKeyCode: Int] = [:]
        for b in KeyMapper.bindings { seen[b.mac, default: 0] += 1 }
        let duplicates = seen.filter { $0.value > 1 }.map(\.key.label)
        #expect(duplicates.isEmpty, "mapped more than once: \(duplicates)")
    }

    @Test func commandKeysAreNeverMapped() {
        for code in [MacKeyCode.command, .rightCommand, .capsLock, .function] {
            #expect(KeyMapper.binding(forKeyCode: code.rawValue) == nil)
        }
    }

    @Test func keyCodesMatchCarbon() {
        let expected: [(MacKeyCode, Int)] = [
            (.a, kVK_ANSI_A), (.z, kVK_ANSI_Z), (.q, kVK_ANSI_Q), (.digit0, kVK_ANSI_0), (.digit5, kVK_ANSI_5),
            (.digit9, kVK_ANSI_9), (.semicolon, kVK_ANSI_Semicolon), (.quote, kVK_ANSI_Quote),
            (.equal, kVK_ANSI_Equal), (.minus, kVK_ANSI_Minus), (.leftBracket, kVK_ANSI_LeftBracket),
            (.rightBracket, kVK_ANSI_RightBracket), (.backslash, kVK_ANSI_Backslash), (.grave, kVK_ANSI_Grave),
            (.comma, kVK_ANSI_Comma), (.period, kVK_ANSI_Period), (.slash, kVK_ANSI_Slash),
            (.isoSection, kVK_ISO_Section), (.returnKey, kVK_Return), (.space, kVK_Space), (.delete, kVK_Delete),
            (.escape, kVK_Escape), (.home, kVK_Home), (.end, kVK_End), (.pageUp, kVK_PageUp),
            (.pageDown, kVK_PageDown), (.forwardDelete, kVK_ForwardDelete), (.help, kVK_Help),
            (.leftArrow, kVK_LeftArrow), (.rightArrow, kVK_RightArrow), (.upArrow, kVK_UpArrow),
            (.downArrow, kVK_DownArrow), (.control, kVK_Control), (.rightControl, kVK_RightControl),
            (.shift, kVK_Shift), (.rightShift, kVK_RightShift), (.option, kVK_Option),
            (.rightOption, kVK_RightOption), (.command, kVK_Command), (.rightCommand, kVK_RightCommand),
            (.capsLock, kVK_CapsLock), (.function, kVK_Function), (.f1, kVK_F1), (.f2, kVK_F2), (.f3, kVK_F3),
            (.f4, kVK_F4), (.f5, kVK_F5), (.f6, kVK_F6), (.f7, kVK_F7), (.f8, kVK_F8), (.keypad0, kVK_ANSI_Keypad0),
            (.keypad5, kVK_ANSI_Keypad5), (.keypad8, kVK_ANSI_Keypad8), (.keypad9, kVK_ANSI_Keypad9),
            (.keypadPlus, kVK_ANSI_KeypadPlus), (.keypadMinus, kVK_ANSI_KeypadMinus),
            (.keypadEnter, kVK_ANSI_KeypadEnter), (.keypadEquals, kVK_ANSI_KeypadEquals),
            (.keypadClear, kVK_ANSI_KeypadClear), (.keypadDecimal, kVK_ANSI_KeypadDecimal),
            (.keypadMultiply, kVK_ANSI_KeypadMultiply), (.keypadDivide, kVK_ANSI_KeypadDivide),
        ]
        for (code, carbon) in expected { #expect(Int(code.rawValue) == carbon, "\(code)") }
    }

    @Test func planTableMappings() {
        func keys(_ code: MacKeyCode) -> [C64Key] { KeyMapper.binding(forKeyCode: code.rawValue)?.c64 ?? [] }
        #expect(keys(.semicolon) == [.semicolon])
        #expect(keys(.quote) == [.colon])
        #expect(keys(.equal) == [.plus])
        #expect(keys(.minus) == [.minus])
        #expect(keys(.leftBracket) == [.at])
        #expect(keys(.rightBracket) == [.asterisk])
        #expect(keys(.backslash) == [.pound])
        #expect(keys(.grave) == [.leftArrow])
        #expect(keys(.escape) == [.runStop])
        #expect(keys(.home) == [.clrHome])
        #expect(keys(.delete) == [.instDel])
        #expect(keys(.returnKey) == [.returnKey])
        #expect(keys(.space) == [.space])
        #expect(keys(.control) == [.control] && keys(.rightControl) == [.control])
        #expect(keys(.shift) == [.rightShift] && keys(.rightShift) == [.rightShift])
        #expect(keys(.option) == [.commodore])
        #expect(keys(.rightArrow) == [.cursorRight])
        #expect(keys(.downArrow) == [.cursorDown])
        #expect(Set(keys(.leftArrow)) == [.rightShift, .cursorRight])
        #expect(Set(keys(.upArrow)) == [.rightShift, .cursorDown])
        #expect(keys(.pageUp) == [.semicolon])
        #expect(keys(.pageDown) == [.colon])
        for (m, c) in [(MacKeyCode.a, C64Key.a), (.r, .r), (.digit1, .digit1), (.digit0, .digit0), (.comma, .comma),
                       (.period, .period), (.slash, .slash)] {
            #expect(keys(m) == [c])
        }
    }

    @Test func keypadIsJoystickOrDigits() throws {
        var kb = KeyboardState()
        kb.keyDown(MacKeyCode.keypad8.rawValue)
        kb.keyDown(MacKeyCode.keypad5.rawValue)
        kb.keyDown(MacKeyCode.keypadPlus.rawValue)
        kb.keyDown(MacKeyCode.keypadEnter.rawValue)
        let joy = kb.matrix(keypadJoystick: true)
        #expect(joy.joystick1 == [.up, .fire])
        #expect(joy.joystick2 == [.up, .fire])
        #expect(!joy.isPressed(.digit8) && !joy.isPressed(.returnKey))
        let typed = kb.matrix(keypadJoystick: false)
        #expect(typed.joystick1.isEmpty && typed.joystick2.isEmpty)
        #expect(typed.isPressed(.digit8) && typed.isPressed(.digit5) && typed.isPressed(.plus)
                && typed.isPressed(.returnKey))
        // Port 1 directions and port 2 throttle per the plan.
        func joystick(_ c: MacKeyCode) -> JoystickBinding? { KeyMapper.binding(forKeyCode: c.rawValue)?.joystick }
        #expect(joystick(.keypad2) == JoystickBinding(port: 1, state: .down))
        #expect(joystick(.keypad4) == JoystickBinding(port: 1, state: .left))
        #expect(joystick(.keypad6) == JoystickBinding(port: 1, state: .right))
        #expect(joystick(.keypad0) == JoystickBinding(port: 1, state: .fire))
        #expect(joystick(.keypadMinus) == JoystickBinding(port: 2, state: .down))
    }

    @Test func chordsReleaseIndependently() {
        var kb = KeyboardState()
        kb.modifierChanged(MacKeyCode.shift.rawValue, modifierFlags: 0x0002_0002)   // left shift down
        kb.keyDown(MacKeyCode.leftArrow.rawValue)
        #expect(kb.matrix(keypadJoystick: true).isPressed(.rightShift))
        kb.keyUp(MacKeyCode.leftArrow.rawValue)
        let m = kb.matrix(keypadJoystick: true)
        #expect(m.isPressed(.rightShift) && !m.isPressed(.cursorRight))   // Shift is still held
        kb.modifierChanged(MacKeyCode.shift.rawValue, modifierFlags: 0)
        #expect(kb.matrix(keypadJoystick: true) == KeyMatrix())
    }

    @Test func autoRepeatAndCommandAreIgnored() {
        var kb = KeyboardState()
        let repeatUsed = kb.keyDown(MacKeyCode.a.rawValue, isRepeat: true)
        #expect(repeatUsed && kb.held.isEmpty)        // consumed, but does not press
        let commandUsed = kb.keyDown(MacKeyCode.r.rawValue, command: true)
        #expect(!commandUsed && kb.held.isEmpty)      // ⌘R goes to the menus
        let tabUsed = kb.keyDown(MacKeyCode.tab.rawValue)
        #expect(!tabUsed)                             // unmapped keys pass through
    }

    @Test func leftAndRightModifiersAreTrackedSeparately() {
        var kb = KeyboardState()
        // Both Shifts down, then the left one released: right shift still holds RIGHT SHIFT.
        kb.modifierChanged(MacKeyCode.shift.rawValue, modifierFlags: 0x0002_0002)
        kb.modifierChanged(MacKeyCode.rightShift.rawValue, modifierFlags: 0x0002_0006)
        kb.modifierChanged(MacKeyCode.shift.rawValue, modifierFlags: 0x0002_0004)
        #expect(kb.held == [.rightShift])
        // Without device bits, the shared flag decides.
        #expect(MacKeyCode.option.isDown(modifierFlags: 1 << 19))
        #expect(!MacKeyCode.option.isDown(modifierFlags: 0))
    }

    @Test func oppositeDirectionsCancel() {
        #expect(JoystickState([.up, .down, .fire]).resolvingOpposites == [.fire])
        #expect(JoystickState([.left, .right, .up]).resolvingOpposites == [.up])
        #expect(Gamepad.directions(x: -0.9, y: 0.7) == [.left, .up])
        #expect(Gamepad.directions(x: 0.3, y: -0.3).isEmpty)
    }

    @Test func referenceCoversEveryBinding() {
        let sections = KeyReference.sections()
        let rows = sections.flatMap(\.rows)
        for b in KeyMapper.bindings {
            #expect(rows.contains { $0.mac == b.mac.label }, "\(b.mac.label) missing from the reference")
        }
        #expect(rows.contains { $0.c64 == C64Key.leftShift.label && $0.mac == "(none)" })
        #expect(!KeyReference.function(of: .semicolon).isEmpty)
        #expect(KeyReference.plainText().contains("Throttle up"))
    }

    /// Each Mac key alone gives exactly its binding: those C64 keys (or that joystick) and nothing else.
    @Test func everyKeyAloneGivesExactlyItsBinding() {
        for code in MacKeyCode.allCases {
            for keypadJoystick in [true, false] {
                var kb = KeyboardState()
                let used = code.isModifier
                    ? kb.modifierChanged(code.rawValue, modifierFlags: (code.deviceModifierMask ?? 0) | (code.modifierFlag ?? 0))
                    : kb.keyDown(code.rawValue)
                let m = kb.matrix(keypadJoystick: keypadJoystick)
                guard let b = KeyMapper.binding(forKeyCode: code.rawValue) else {
                    #expect(!used && m == KeyMatrix(), "\(code) is unmapped but changed the matrix")
                    continue
                }
                #expect(used, "\(code)")
                var expected = KeyMatrix()
                if keypadJoystick, let j = b.joystick {
                    if j.port == 1 { expected.joystick1 = j.state } else { expected.joystick2 = j.state }
                } else {
                    for c in b.c64 { expected.set(c, pressed: true) }
                }
                #expect(m == expected, "\(code) keypadJoystick \(keypadJoystick)")
            }
        }
    }

    /// Random presses and releases, in any order and with chords sharing C64 keys: the matrix is always
    /// the union of what the held keys map to, and letting go of everything leaves it empty.
    @Test func randomPressAndReleaseSequences() {
        var rng = SystemRandomNumberGenerator()
        let codes = MacKeyCode.allCases.filter { !$0.isModifier && KeyMapper.binding(forKeyCode: $0.rawValue) != nil }
        let modifiers = MacKeyCode.allCases.filter { $0.isModifier && KeyMapper.binding(forKeyCode: $0.rawValue) != nil }
        for _ in 0..<300 {
            var kb = KeyboardState()
            var held: Set<MacKeyCode> = []
            var flags: UInt = 0
            for _ in 0..<Int.random(in: 1...24, using: &rng) {
                if Bool.random(using: &rng) {
                    let m = modifiers.randomElement(using: &rng)!
                    let mask = m.deviceModifierMask!
                    if held.contains(m) { held.remove(m); flags &= ~mask } else { held.insert(m); flags |= mask }
                    kb.modifierChanged(m.rawValue, modifierFlags: flags)
                } else {
                    let k = codes.randomElement(using: &rng)!
                    let wasHeld = held.contains(k)
                    if wasHeld && Bool.random(using: &rng) {
                        held.remove(k); kb.keyUp(k.rawValue)
                    } else {
                        // Auto-repeats only ever come for a key that is down already.
                        let isRepeat = wasHeld && Bool.random(using: &rng)
                        held.insert(k); kb.keyDown(k.rawValue, isRepeat: isRepeat)
                    }
                }
                #expect(kb.held == held)
                var expected = KeyMatrix()
                for k in held {
                    let b = KeyMapper.binding(forKeyCode: k.rawValue)!
                    if let j = b.joystick {
                        if j.port == 1 { expected.joystick1.formUnion(j.state) } else { expected.joystick2.formUnion(j.state) }
                    } else {
                        for c in b.c64 { expected.set(c, pressed: true) }
                    }
                }
                #expect(kb.matrix(keypadJoystick: true) == expected)
            }
            for k in held.shuffled(using: &rng) {
                if k.isModifier {
                    flags &= ~k.deviceModifierMask!
                    kb.modifierChanged(k.rawValue, modifierFlags: flags)
                } else {
                    kb.keyUp(k.rawValue)
                }
            }
            #expect(kb.held.isEmpty && kb.matrix(keypadJoystick: true) == KeyMatrix())
        }
    }

    /// Every combination of left/right modifier device bits: each key reads as down exactly when its
    /// own bit is set, whatever the others do.
    @Test func modifierDeviceBitsAreIndependent() {
        let modifiers = MacKeyCode.allCases.filter { $0.deviceModifierMask != nil }
        #expect(modifiers.count == 8)
        for combination in 0..<(1 << modifiers.count) {
            var raw: UInt = 0
            for (i, m) in modifiers.enumerated() where combination & (1 << i) != 0 {
                raw |= m.deviceModifierMask! | m.modifierFlag!
            }
            for (i, m) in modifiers.enumerated() {
                #expect(m.isDown(modifierFlags: raw) == (combination & (1 << i) != 0), "\(m) in \(combination)")
            }
        }
    }

    /// The key reference describes what each mapped key does, never an empty cell for a game key.
    @Test func referenceDescribesTheFlightKeys() {
        for key in [C64Key.a, .b, .c, .f, .g, .h, .m, .n, .r, .t, .v, .y, .semicolon, .colon, .comma, .period,
                    .digit5, .runStop, .control, .returnKey, .space] {
            #expect(!KeyReference.function(of: key).isEmpty, "\(key.label)")
        }
        let keypad = KeyReference.sections().first { $0.title.hasPrefix("Keypad") }
        #expect(keypad?.rows.count == KeyMapper.bindings.filter { $0.joystick != nil }.count)
    }
}
