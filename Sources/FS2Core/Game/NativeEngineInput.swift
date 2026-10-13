import C64Kit

/// What the CIA shows the game in the next frame, from the player's keys and joysticks.
///
/// The keyboard and the joysticks share CIA1's lines. The original's column sampler ($2574) aborts
/// the matrix scan ($2418) and the release check ($2505) whenever a joystick bit is low, latching
/// the joystick instead, so on a C64 no key is seen pressed or released while a stick is
/// deflected (`input.md`, "CIA sampling and joystick arbitration").
///
/// - **Strict** (`EngineOptions.strictJoystick`): the matrix as it is, the original's behavior.
/// - **Shared** (the default): the frame IRQ samples the CIA only on its scan and release frames
///   (`$08A6`: the next IRQ scans when it is 1 now, checks releases when it is 0). On such a frame
///   the joysticks are hidden when the keyboard needs that frame: before a scan when a pressed key
///   is in none of the held-key slots `$089B-$089E` (a new press; ignored when all four slots are
///   taken, since a fifth key is lost anyway), before a release check when a slot holds a key that
///   is no longer pressed. Every other sampled frame shows the joysticks (with the keys), so the
///   stick is latched as before and the 5 Hz joystick action keeps its rate.
///
/// The decision reads only memory and the input, at a frame end, so it is deterministic.
final class JoystickSharing {
    func matrix(for keys: KeyMatrix, strict: Bool, machine m: Machine) -> KeyMatrix {
        guard !strict, !keys.joystick1.isEmpty || !keys.joystick2.isEmpty else { return keys }
        let phase = m.mem[MainLoop.RAM.scanPhase]
        let slots = (0..<4).map { m.mem[Input.RAM.heldKeySlots + $0] }
        let held = slots.filter { $0 & 0x80 == 0 }
        let keyboardNeedsFrame: Bool
        switch phase {
        case 1:
            // The next IRQ scans: a new key must be seen.
            keyboardNeedsFrame = held.count < 4 && C64Key.allCases.contains { key in
                keys.isPressed(key) && !held.contains(UInt8(key.rawValue))
            }
        case 0:
            // The next IRQ checks the releases: a released key must be seen up.
            keyboardNeedsFrame = held.contains { index in
                guard let key = C64Key(rawValue: Int(index)) else { return false }
                return !keys.isPressed(key)
            }
        default:
            keyboardNeedsFrame = false
        }
        guard keyboardNeedsFrame else { return keys }
        var shown = keys
        shown.joystick1 = []
        shown.joystick2 = []
        return shown
    }
}
