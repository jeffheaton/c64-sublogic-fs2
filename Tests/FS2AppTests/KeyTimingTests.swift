import C64Kit
import FS2Core
@testable import FS2App
@testable import FS2Host
import Testing

/// The key timing between the Mac keyboard and the C64 matrix (`KeyTiming`), frame by frame.
@Suite struct KeyTimingTests {
    /// Drives a `KeyTiming` like `EngineLoop`: per frame the player's matrix (observed), then the
    /// decided matrix committed. Returns the committed matrices.
    static func run(_ frames: [KeyMatrix]) -> [KeyMatrix] {
        var timing = KeyTiming()
        var out: [KeyMatrix] = []
        for user in frames {
            timing.observe(user)
            let m = timing.decide()
            timing.commit(m)
            out.append(m)
        }
        return out
    }

    static func m(_ keys: C64Key...) -> KeyMatrix {
        var k = KeyMatrix()
        for key in keys { k.set(key, pressed: true) }
        return k
    }

    static func pressed(_ frames: [KeyMatrix], _ key: C64Key) -> String {
        String(frames.map { $0.isPressed(key) ? "#" : "." })
    }

    @Test func aTapIsHeldFourFrames() {
        let out = Self.run([Self.m(.a)] + Array(repeating: Self.m(), count: 7))
        #expect(Self.pressed(out, .a) == "####....")
    }

    @Test func aLongPressFollowsThePlayer() {
        let out = Self.run(Array(repeating: Self.m(.a), count: 7) + Array(repeating: Self.m(), count: 3))
        #expect(Self.pressed(out, .a) == "#######...")
    }

    /// Two quick taps stay two presses: in 4 frames, out 4 frames, in again 4 frames.
    @Test func aDoubleTapIsTwoPresses() {
        let out = Self.run([Self.m(.a), Self.m(), Self.m(.a)] + Array(repeating: Self.m(), count: 11))
        #expect(Self.pressed(out, .a) == "####....####..")
    }

    /// A key released and pressed again while held stays out 4 frames first.
    @Test func aRepressWaitsForTheRelease() {
        let out = Self.run(Array(repeating: Self.m(.a), count: 5) + [Self.m(), Self.m(.a), Self.m(.a), Self.m(.a),
                                                                       Self.m(.a), Self.m(.a), Self.m(.a), Self.m()])
        #expect(Self.pressed(out, .a) == "#####....####")
    }

    /// CTRL and a letter pressed together: CTRL in first, the letter 4 frames later, and CTRL kept
    /// until the letter has been in 4 frames even when the player lets both go at once.
    @Test func controlGoesFirst() {
        let out = Self.run([Self.m(.control, .c), Self.m(.control, .c)] + Array(repeating: Self.m(), count: 10))
        #expect(Self.pressed(out, .control) == "########....")
        #expect(Self.pressed(out, .c) == "....####....")
    }

    /// The letter arriving in the same frame just before CTRL counts as pressed together.
    @Test func aLetterJustBeforeControlWaitsForIt() {
        var timing = KeyTiming()
        var out: [KeyMatrix] = []
        timing.observe(Self.m(.e))
        timing.observe(Self.m(.e, .control))
        for _ in 0..<10 {
            let d = timing.decide()
            timing.commit(d)
            out.append(d)
            timing.observe(Self.m(.e, .control))
        }
        #expect(Self.pressed(out, .control) == "##########")
        #expect(Self.pressed(out, .e) == "....######")
    }

    /// With CTRL held for a while, a letter goes in at once.
    @Test func aLetterUnderAHeldControlGoesInAtOnce() {
        let out = Self.run(Array(repeating: Self.m(.control), count: 6) + [Self.m(.control, .n), Self.m(.control)])
        #expect(Self.pressed(out, .n) == "......##")
    }

    /// A plain key right after a CTRL combination waits until CTRL has been out 4 frames, so the
    /// CTRL still in the matrix does not turn it into a CTRL code.
    @Test func aPlainKeyWaitsForControlToBeSeenUp() {
        let out = Self.run([Self.m(.control, .c), Self.m(), Self.m(), Self.m(), Self.m(), Self.m(), Self.m(.a)]
                           + Array(repeating: Self.m(), count: 11))
        #expect(Self.pressed(out, .control) == "########..........")
        #expect(Self.pressed(out, .c) == "....####..........")
        #expect(Self.pressed(out, .a) == "............####..")
    }

    @Test func joysticksPassUnchanged() {
        var a = Self.m()
        a.joystick1 = [.up, .fire]
        var b = Self.m(.space)
        b.joystick2 = [.down]
        let out = Self.run([a, b, Self.m()])
        #expect(out[0].joystick1 == [.up, .fire] && out[1].joystick2 == [.down] && out[2] == Self.m(.space))
    }

    /// Through `EngineLoop`: a one-frame tap reaches the engine as four frames of the key.
    @Test func theEngineLoopShapesTheKeys() {
        let recorder = EngineRecorder()
        let engine = FakeEngine(recorder: recorder)
        let loop = EngineLoop(engine: engine, frames: FrameExchange(), audio: nil)
        let cpf = VirtualClock.cyclesPerFrame
        func frame() { engine.run(untilCycle: (engine.cycles / cpf + 1) * cpf) }
        frame()
        var tap = InputState()
        tap.keys.set(.q, pressed: true)
        loop.setUserInput(tap)
        frame()
        loop.setUserInput(InputState())
        for _ in 0..<6 { frame() }
        // recorder.inputs[i]: what the engine latched at the end of frame i + 1.
        #expect(String(recorder.inputs.map { $0.keys.isPressed(.q) ? "#" : "." }) == ".####...")
    }
}
