import C64Kit
import FS2Host
import GameController

/// Game controllers (GameController framework) as C64 joysticks, polled once per display refresh.
///
/// - Left stick or D-pad: port 1 (the yoke), thresholded to digital directions like a real joystick.
/// - Right stick Y axis: port 2 up/down (throttle).
/// - A: port-1 fire (view prefix). B or the right trigger: port-2 fire (guns).
@MainActor
final class Gamepad {
    /// Stick deflection that counts as a pressed direction.
    nonisolated static let threshold: Float = 0.5

    init() {}

    /// The joystick bits from every connected extended gamepad, merged.
    func poll() -> (port1: JoystickState, port2: JoystickState) {
        var p1 = JoystickState(), p2 = JoystickState()
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            p1.formUnion(Self.directions(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value))
            p1.formUnion(Self.directions(x: pad.dpad.xAxis.value, y: pad.dpad.yAxis.value))
            if pad.buttonA.isPressed { p1.insert(.fire) }
            p2.formUnion(Self.directions(x: 0, y: pad.rightThumbstick.yAxis.value))
            if pad.buttonB.isPressed || pad.rightTrigger.isPressed { p2.insert(.fire) }
        }
        return (p1.resolvingOpposites, p2.resolvingOpposites)
    }

    /// Digital directions for an analog position (y positive is up, as GameController reports it).
    nonisolated static func directions(x: Float, y: Float, threshold: Float = Gamepad.threshold) -> JoystickState {
        var s = JoystickState()
        if y >= threshold { s.insert(.up) }
        if y <= -threshold { s.insert(.down) }
        if x <= -threshold { s.insert(.left) }
        if x >= threshold { s.insert(.right) }
        return s
    }
}
