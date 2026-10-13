import C64Kit
import Foundation
import FS2Core
import Testing

/// The native engine's input side: the `GameEngine` contract (input latched at frame ends, before
/// `onFrame`) and the joystick option (strict: the original's arbitration; shared: the keyboard
/// gets the CIA on the scan and release frames it needs).
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct NativeEngineInputTests {
    static let frame = VirtualClock.cyclesPerFrame

    static func keys(_ k: C64Key...) -> InputState {
        var i = InputState()
        for key in k { i.keys.set(key, pressed: true) }
        return i
    }

    /// Input set between `run` calls (mid-frame) is in the CIA from the next frame end, already
    /// when that frame's `onFrame` is called; input set inside `onFrame` from the frame end after.
    @Test func inputIsLatchedAtFrameEnds() throws {
        let engine = try NativeEngineBootTests.engine()
        #expect(engine.runToKeyWait(maxFrames: 9000, deliverFrames: false), "the title")
        var seen: [(frame: UInt64, space: Bool, q: Bool)] = []
        var setInsideAt: UInt64?
        engine.onFrame = { [unowned engine] f in
            let k = engine.machine.io.keyboard
            seen.append((f.frame, k.isPressed(.space), k.isPressed(.q)))
            if setInsideAt == nil && k.isPressed(.space) {
                setInsideAt = f.frame
                engine.input = Self.keys(.q)
            }
        }
        engine.run(untilCycle: (engine.cycles / Self.frame + 2) * Self.frame + Self.frame / 2)
        let before = try #require(seen.last)
        #expect(!before.space, "nothing pressed yet")
        engine.input = Self.keys(.space)
        engine.run(untilCycle: (engine.cycles / Self.frame + 4) * Self.frame)
        engine.onFrame = nil
        let first = try #require(seen.firstIndex { $0.space })
        #expect(seen[first].frame == before.frame + 1, "set mid-frame: in effect from that frame's end")
        #expect(setInsideAt == seen[first].frame)
        #expect(!seen[first].q && seen[first + 1].q && !seen[first + 1].space,
                "set inside onFrame: in effect from the next frame end")
    }

    /// Flying at Meigs with the stick held left: in strict mode (the original) an L typed meanwhile
    /// is lost; shared (the default), it toggles the lights once and is released while the stick
    /// is still held, and a key held from before the stick is released too (strict keeps it in
    /// its slot until the stick centers). The stick moves the ailerons in both modes.
    @Test func strictAndSharedJoysticks() throws {
        let engine = try NativeEngineSmoothTests.engine(.authentic)
        NativeEngineSmoothTests.prepare(engine, throttle: false)
        let m = engine.machine
        func frames(_ n: UInt64, _ input: InputState) {
            engine.input = input
            engine.run(untilCycle: (engine.cycles / Self.frame + n) * Self.frame)
        }
        func slotsHold(_ key: C64Key) -> Bool {
            (0..<4).contains { m.mem[Input.RAM.heldKeySlots + $0] == UInt8(key.rawValue) }
        }
        var stick = InputState()
        stick.keys.joystick1 = [.left]
        for strict in [true, false] {
            engine.options.strictJoystick = strict
            frames(60, InputState())                                // centered, keys up
            let lights = m.mem[Input.RAM.lights]
            // CRSR-DN (the no-op command) held, then the stick too, then CRSR-DN let go.
            frames(14, Self.keys(.cursorDown))
            #expect(slotsHold(.cursorDown), "strict \(strict): the key took a slot")
            var both = Self.keys(.cursorDown)
            both.keys.joystick1 = [.left]
            frames(14, both)
            frames(30, stick)
            #expect(slotsHold(.cursorDown) == strict, "strict \(strict): the key let go under the stick")
            // L typed while the stick stays left.
            var typed = Self.keys(.l)
            typed.keys.joystick1 = [.left]
            frames(14, typed)
            frames(60, stick)
            let aileron = Int8(bitPattern: m.mem[Input.RAM.ailerons + 1])
            #expect(aileron <= -16, "strict \(strict): the stick moved the ailerons left (\(aileron))")
            #expect(!slotsHold(.l), "strict \(strict): no L left in a slot")
            frames(60, InputState())
            #expect((m.mem[Input.RAM.lights] == lights) == strict,
                    "strict \(strict): lights \(lights) → \(m.mem[Input.RAM.lights])")
            #expect(!slotsHold(.cursorDown) && Int8(bitPattern: m.mem[Input.RAM.ailerons + 1]) == 0,
                    "strict \(strict): everything let go, the ailerons centered")
        }
        #expect(engine.endReason == nil)
    }
}

