import C64Kit
import FS2Core
import FS2LabKit
@testable import FS2App
import Foundation
import Testing

/// Input timing of the headless runner against an engine that only keeps time (no disk needed).
@Suite struct HeadlessRunnerTests {
    /// The input each frame runs with: what the engine latched at the end of the frame before.
    private func framesInputs(_ session: String) throws -> (runner: HeadlessRunner, perFrame: [InputState]) {
        let recorder = EngineRecorder()
        let runner = HeadlessRunner(engine: FakeEngine(recorder: recorder))
        try runner.play(try Session.parse(session), screenshots: nil)
        // recorder.inputs[i] was latched at the end of frame i+1, so frame i+2 ran with it; frame 1
        // ran with the engine's initial (released) input.
        return (runner, [InputState()] + recorder.inputs.dropLast())
    }

    private func keys(_ k: C64Key...) -> InputState {
        var i = InputState()
        for key in k { i.keys.set(key, pressed: true) }
        return i
    }

    /// Like `fs2lab run`: a step's input covers exactly its own frames, starting with the frame right
    /// after the previous step, and steps that take no time (shots) do not shift anything.
    @Test func eachStepCoversExactlyItsOwnFrames() throws {
        let (runner, frames) = try framesInputs("wait:2 key:A:3 shot:x key:B+CTRL:1 joy1:up+fire:2 wait:1 joy2:down:1")
        var joy1 = InputState(); joy1.keys.joystick1 = [.up, .fire]
        var joy2 = InputState(); joy2.keys.joystick2 = [.down]
        let none = InputState()
        #expect(frames == [none, none, keys(.a), keys(.a), keys(.a), keys(.b, .control), joy1, joy1, none, joy2])
        #expect(runner.framesSeen == 10)
        #expect(runner.engine.input == none, "everything is released after the last step")
    }

    @Test func zeroFrameStepsDoNothing() throws {
        let (_, frames) = try framesInputs("wait:1 key:A:0 wait:0 key:B:1 joy1:up:0")
        #expect(frames == [InputState(), keys(.b)])
    }

    @Test func badNamesFailBeforeAnythingRuns() throws {
        for session in ["wait:5 key:NOSUCHKEY:2", "wait:5 joy1:sideways:2", "wait:5 down:NOSUCHKEY", "wait:5 up:CTRL+NOPE"] {
            let recorder = EngineRecorder()
            let runner = HeadlessRunner(engine: FakeEngine(recorder: recorder))
            #expect(throws: (any Error).self) { try runner.play(try Session.parse(session), screenshots: nil) }
            #expect(runner.framesSeen == 0, "\(session)")
        }
    }

    @Test func debuggingStepsNeedADebuggableEngine() throws {
        for session in ["pc:2250:10", "poke:0400:01", "snap:x", "peek:0400", "until:0400:01:10", "text"] {
            let runner = HeadlessRunner(engine: FakeEngine(recorder: EngineRecorder()))
            #expect(throws: HeadlessRunner.Error.self) { try runner.play(try Session.parse(session), screenshots: nil) }
        }
        let runner = HeadlessRunner(engine: FakeEngine(recorder: EngineRecorder()))
        #expect(throws: HeadlessRunner.Error.self) { try runner.quickBoot() }
        #expect(throws: HeadlessRunner.Error.self) { try runner.play(try Session.parse("shot:early"), screenshots: nil) }
    }

    /// The lab's instrumentation steps watch the original's code: skipped, on any engine.
    @Test func instrumentationStepsAreSkipped() throws {
        let (runner, frames) = try framesInputs("cov:on wait:1 watch:0400:0401 cov:save:x wait:1 cov:off")
        #expect(runner.skippedSteps == 4)
        #expect(frames.count == 2 && runner.framesSeen == 2)
    }

    /// `down:` holds keys across the following steps until `up:` (a `key:` step naming a held key
    /// lets it go afterward, as the lab's player does); `nmi` is RESTORE on the first frame end
    /// the next step's input is latched at, once.
    @Test func heldKeysAndRestore() throws {
        let recorder = EngineRecorder()
        let runner = HeadlessRunner(engine: FakeEngine(recorder: recorder))
        try runner.play(try Session.parse("""
            wait:2 down:CTRL key:C:2 wait:1 up:CTRL wait:1 nmi wait:2
            down:RUNSTOP wait:1 nmi key:A:1 down:L key:L:1 wait:1 shot:x down:CTRL
            """), screenshots: nil)
        let frames = [InputState()] + recorder.inputs.dropLast()
        func restored(_ i: InputState) -> InputState {
            var i = i
            i.restore = true
            return i
        }
        let none = InputState()
        #expect(frames == [none, none, keys(.control, .c), keys(.control, .c), keys(.control), none, restored(none), none,
                           keys(.runStop), restored(keys(.runStop, .a)), keys(.runStop, .l), keys(.runStop)])
        #expect(recorder.restores == 2, "RESTORE once per nmi step")
        #expect(runner.engine.input == keys(.runStop, .control), "the keys still held after the last step")
    }

    /// RESTORE goes with the input of the next step that sets one (also a `pc:` step's); one left
    /// after the last step stays in the input the engine keeps.
    @Test func restoreGoesWithTheNextInput() throws {
        let plan = try HeadlessRunner.plan(try Session.parse("nmi pc:2250:10 wait:2 nmi").steps)
        var waitPC = InputState()
        waitPC.restore = true
        #expect(plan.inputs == [nil, waitPC, InputState(), nil])
        #expect(plan.after.restore, "a final nmi is left for the engine")
    }

    @Test func stepInputs() throws {
        #expect(try HeadlessRunner.input(during: .screenshot(name: "x")) == nil)
        #expect(try HeadlessRunner.input(during: .poke(address: 1, value: 2)) == nil)
        #expect(try HeadlessRunner.input(during: .waitPC(address: 0x2250, maxFrames: 9)) == InputState())
        #expect(try HeadlessRunner.input(during: .waitByte(address: 0x0901, value: 0x4E, negate: false, maxFrames: 9))
                == InputState())
        #expect(try HeadlessRunner.input(during: .press(key: "CTRL+F1", frames: 2)) == keys(.control, .f1))
        var held = KeyMatrix()
        held.set(.control, pressed: true)
        #expect(try HeadlessRunner.input(during: .press(key: "X", frames: 2), held: held) == keys(.control, .x))
        #expect(try HeadlessRunner.input(during: .nmi) == nil)
        #expect(try HeadlessRunner.joystick("UP+Left+fire") == [.up, .left, .fire])
    }
}
