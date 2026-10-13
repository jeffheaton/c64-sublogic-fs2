import C64Kit
import FS2Core

/// The Mac keys currently held, turned into the C64 keyboard matrix and joystick bits.
///
/// The matrix is recomputed from the whole set of held keys, so chords that share a C64 key
/// (← and Shift both hold RIGHT SHIFT) release correctly. Auto-repeat events are ignored: the
/// original program does its own key repeat from the held matrix.
public struct KeyboardState: Sendable, Equatable {
    public private(set) var held: Set<MacKeyCode> = []

    public init() {}

    /// Exactly these keys held (the web worker's view of the browser's keys); keys that belong to
    /// no binding are left out, as `keyDown` leaves them out.
    public init(held: Set<MacKeyCode>) {
        self.held = held.filter { KeyMapper.binding(forKeyCode: $0.rawValue) != nil }
    }

    /// Handles a key-down event. Returns true when the key belongs to the C64 (so the view consumes it).
    @discardableResult
    public mutating func keyDown(_ code: UInt16, isRepeat: Bool = false, command: Bool = false) -> Bool {
        guard !command, let key = MacKeyCode(rawValue: code), KeyMapper.binding(forKeyCode: code) != nil else {
            return false
        }
        if !isRepeat { held.insert(key) }
        return true
    }

    /// Handles a key-up event.
    @discardableResult
    public mutating func keyUp(_ code: UInt16) -> Bool {
        guard let key = MacKeyCode(rawValue: code) else { return false }
        return held.remove(key) != nil
    }

    /// Handles a `flagsChanged` event for a modifier key.
    @discardableResult
    public mutating func modifierChanged(_ code: UInt16, modifierFlags: UInt) -> Bool {
        guard let key = MacKeyCode(rawValue: code), key.isModifier,
              KeyMapper.binding(forKeyCode: code) != nil else { return false }
        if key.isDown(modifierFlags: modifierFlags) { held.insert(key) } else { held.remove(key) }
        return true
    }

    /// Lets go of everything (window lost focus, app deactivated).
    public mutating func releaseAll() { held.removeAll() }

    /// The matrix (keys and keypad joysticks) for the held keys.
    public func matrix(keypadJoystick: Bool) -> KeyMatrix {
        var m = KeyMatrix()
        for key in held {
            guard let b = KeyMapper.binding(forKeyCode: key.rawValue) else { continue }
            if keypadJoystick, let j = b.joystick {
                if j.port == 1 { m.joystick1.formUnion(j.state) } else { m.joystick2.formUnion(j.state) }
            } else {
                for c in b.c64 { m.set(c, pressed: true) }
            }
        }
        return m
    }
}

extension JoystickState {
    /// A physical stick cannot point up and down (or left and right) at once; opposite directions cancel.
    public var resolvingOpposites: JoystickState {
        var s = self
        if s.contains(.up) && s.contains(.down) { s.subtract([.up, .down]) }
        if s.contains(.left) && s.contains(.right) { s.subtract([.left, .right]) }
        return s
    }
}

extension InputState {
    /// The engine's input for the held keys and the game controller's two sticks: the keypad
    /// drives the joysticks when `keypadJoystick` is on, and opposite directions cancel.
    public init(keyboard: KeyboardState, keypadJoystick: Bool,
                gamepad: (JoystickState, JoystickState) = ([], [])) {
        var keys = keyboard.matrix(keypadJoystick: keypadJoystick)
        keys.joystick1 = keys.joystick1.union(gamepad.0).resolvingOpposites
        keys.joystick2 = keys.joystick2.union(gamepad.1).resolvingOpposites
        self.init()
        self.keys = keys
    }
}
