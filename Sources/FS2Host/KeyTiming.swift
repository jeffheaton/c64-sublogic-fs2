import C64Kit

/// Shapes the player's keys into a matrix the original keyboard scan reads the way the player
/// meant it (`re/docs/input.md`, "Timing" and "The matrix scan").
///
/// The frame IRQ samples the matrix only every fourth frame (scan), and checks releases on the
/// frame after a scan. So:
/// - **Minimum hold**: a key is in the matrix at least 4 frames, so a short tap covers a scan
///   frame and is not lost.
/// - **Minimum release**: a key is out of the matrix at least 4 frames before it goes in again,
///   so a release-check frame sees it up and the next press is a new key (a double tap stays two
///   taps).
/// - **CTRL first**: a key pressed together with CTRL (or while CTRL is held) goes into the
///   matrix only once CTRL has been in it 4 frames, so CTRL is scanned first: a letter and CTRL
///   first seen in the same scan are processed letter first, without the −$40 (CTRL+C would be
///   C). CTRL then stays in until such keys have been in 4 frames themselves. A key pressed
///   without CTRL waits until CTRL has been out 4 frames (its release check cleared `$0E67`), so
///   it is not turned into a CTRL code by a CTRL the shaper is still holding. A CTRL pressed in
///   the same frame as a key, just after it, still counts as pressed together.
///
/// Joysticks pass unchanged. One `commit` per frame end, with the matrix the engine latched for
/// the next frame; `decide` gives the matrix for the frame after that.
public struct KeyTiming: Sendable, Equatable {
    public static let minimumFrames = 4

    private struct Key: Sendable, Equatable {
        /// In the shaped matrix, and since which frame (the frame it first was or was not).
        var down = false
        var since = -1_000_000
        /// A press edge not yet in the matrix (kept when the player lets go first: a tap).
        var requested = false
        /// The press came with CTRL.
        var withControl = false
    }

    private var keys = [Key](repeating: Key(), count: 64)
    /// The player's matrix as last observed.
    public private(set) var user = KeyMatrix()
    /// The frame the last committed matrix is in effect for.
    public private(set) var frame = 0

    private static let control = C64Key.control.rawValue

    /// The player's keys changed: records the new presses.
    public mutating func observe(_ matrix: KeyMatrix) {
        let controlHeld = matrix.isPressed(.control)
        if controlHeld && !user.isPressed(.control) {
            // CTRL arriving with keys whose press is still waiting: pressed together.
            for i in keys.indices where i != Self.control && keys[i].requested && !keys[i].down {
                keys[i].withControl = true
            }
        }
        for key in C64Key.allCases where matrix.isPressed(key) && !user.isPressed(key) {
            keys[key.rawValue].requested = true
            keys[key.rawValue].withControl = controlHeld && key != .control
        }
        user = matrix
    }

    /// The matrix for the frame after the last committed one.
    public func decide() -> KeyMatrix {
        let n = frame + 1
        let minimum = Self.minimumFrames
        var out = KeyMatrix()
        out.joystick1 = user.joystick1
        out.joystick2 = user.joystick2
        let control = keys[Self.control]
        // CTRL stays while a key typed with it waits or has not been in for the minimum yet.
        let controlNeeded = keys.indices.contains { i in
            let k = keys[i]
            return i != Self.control && k.withControl && (k.requested || (k.down && n - k.since < minimum))
        }
        for key in C64Key.allCases {
            let i = key.rawValue
            let k = keys[i]
            let down: Bool
            if k.down {
                if n - k.since < minimum {
                    down = true
                } else if k.requested {
                    down = false                            // released first, so the new press is seen
                } else {
                    down = user.isPressed(key) || (i == Self.control && controlNeeded)
                }
            } else {
                var allowed = (k.requested || user.isPressed(key)) && n - k.since >= minimum
                if allowed && i != Self.control {
                    allowed = k.withControl
                        ? control.down && n - control.since >= minimum
                        : !control.down && n - control.since >= minimum
                }
                down = allowed
            }
            out.set(key, pressed: down)
        }
        return out
    }

    /// The engine latched `matrix` at a frame end: it is in effect for the next frame.
    public mutating func commit(_ matrix: KeyMatrix) {
        frame += 1
        for key in C64Key.allCases {
            let i = key.rawValue
            let now = matrix.isPressed(key)
            guard now != keys[i].down else { continue }
            keys[i].down = now
            keys[i].since = frame
            if now { keys[i].requested = false } else { keys[i].withControl = false }
        }
    }

    /// Forgets the presses still waiting (the restart sequence took the keyboard over).
    public mutating func dropRequests() {
        for i in keys.indices {
            keys[i].requested = false
            if !keys[i].down { keys[i].withControl = false }
        }
    }
}
