import C64Kit
import FS2Core
import Foundation

/// Plays a lab-format session (re/sessions/*.txt) against any `GameEngine`, as fast as it runs:
/// `wait:`, `key:`, `joy1:`/`joy2:`, `down:`/`up:`, `nmi` and `shot:` steps go through `InputState`
/// and the frame callback only, so the native port and the lab can be compared frame for frame.
/// `poke:`, `pc:`, `snap:`, `peek:`, `until:` and `text` need an engine that implements
/// `EngineDebugging` (the native engine's `pc:` stops only at the key wait $2250 and at the top of
/// the main loop $204B). The lab's instrumentation steps `cov:` and `watch:` watch the original's
/// code and are skipped (`skippedSteps`). The keys go to the engine unshaped (`KeyTiming` is the
/// app's).
///
/// Input timing matches `fs2lab run` (`C64Machine.play`), which changes the keyboard right after the
/// frame that ends the previous step, so a `key:NAME:N` step holds the key for exactly the next N
/// frames. A `GameEngine` latches `input` at each frame end (the lab in `LabEngine.frameDone`), so
/// an input meant to start with frame k+1 has to be set *before* frame k ends: the runner sets each
/// step's input while the previous step runs its last frame. After a `pc:` or `until:` step (which
/// stop in the middle of a frame) and at the very start there is no such frame, and the next input
/// starts at the next frame end, up to one frame later than in the lab's player.
///
/// Keys held with `down:` stay in every following step's input until `up:` lets them go (a
/// `key:` step naming a held key lets it go afterwards, as the lab's player does). `nmi` is RESTORE
/// (`InputState.restore`) on the input of the next step that sets one: with the same timing as a
/// key, the engine raises the NMI at the frame end where the lab's player presses it.
final class HeadlessRunner {
    enum Error: Swift.Error, CustomStringConvertible {
        case engineStopped(cycle: UInt64)
        case unsupported(String)
        case noFrame(String)

        var description: String {
            switch self {
            case .engineStopped(let c): return "the engine stopped making progress at cycle \(c)"
            case .unsupported(let step): return "step '\(step)' needs an engine with debugging support (try --engine lab)"
            case .noFrame(let name): return "no frame has been produced yet for screenshot '\(name)'"
            }
        }
    }

    let engine: any GameEngine
    /// PNG scale factors (3×4 matches `fs2lab run` screenshots).
    var scaleX = 3, scaleY = 4
    /// Where `peek:` and `text` print (standard output by default).
    var output: (String) -> Void = { print($0) }
    private(set) var framesSeen: UInt64 = 0
    private(set) var latest: FrameOutput?
    private(set) var screenshots: [URL] = []
    /// The `cov:` and `watch:` steps skipped (lab instrumentation of the original's code).
    private(set) var skippedSteps = 0

    init(engine: any GameEngine) {
        self.engine = engine
        engine.onFrame = { [unowned self] frame in
            self.framesSeen += 1
            self.latest = frame
        }
    }

    /// Runs `n` complete frames.
    func runFrames(_ n: Int) throws {
        let target = framesSeen + UInt64(max(0, n))
        let cpf = VirtualClock.cyclesPerFrame
        while framesSeen < target {
            let before = engine.cycles
            engine.run(untilCycle: (before / cpf + 1) * cpf)
            if engine.cycles == before { throw Error.engineStopped(cycle: before) }
        }
    }

    /// Runs through the original's disk loading to the title prompt (engines with `EngineDebugging`).
    func quickBoot() throws {
        guard let d = engine as? EngineDebugging else { throw Error.unsupported("--quick-boot") }
        d.skipDiskLoading()
    }

    /// The input of every step (nil for steps that set none) with the held keys and RESTORE folded
    /// in, and the input after the last step (the keys still held).
    struct Plan: Equatable {
        var inputs: [InputState?]
        var after: InputState
    }

    /// Works out the inputs of `steps` (key and joystick names are checked here).
    static func plan(_ steps: [Session.Step]) throws -> Plan {
        var held = KeyMatrix()
        var restore = false
        var inputs: [InputState?] = []
        for step in steps {
            switch step {
            case .keysDown(let names):
                for key in try keys(names) { held.set(key, pressed: true) }
                inputs.append(nil)
            case .keysUp(let names):
                for key in try keys(names) { held.set(key, pressed: false) }
                inputs.append(nil)
            case .nmi:
                restore = true
                inputs.append(nil)
            default:
                var input = try input(during: step, held: held)
                if input != nil, restore {
                    input?.restore = true
                    restore = false
                }
                inputs.append(input)
                // The lab's player lets go of a step's keys afterwards, held ones included.
                if case .press(let name, _) = step {
                    for key in try keys(name) { held.set(key, pressed: false) }
                }
            }
        }
        var after = InputState()
        after.keys = held
        after.restore = restore
        return Plan(inputs: inputs, after: after)
    }

    /// Plays every step of `session`, writing screenshots into `directory` (when given). Key and
    /// joystick names are checked before anything runs.
    func play(_ session: Session, screenshots directory: URL?) throws {
        let steps = session.steps
        let plan = try Self.plan(steps)
        /// The step whose input the previous step's last frame already handed to the engine.
        var handedOver: Int?
        for (index, step) in steps.enumerated() {
            // What the first frame after this step must see: the input of the next step that sets
            // one (instant steps in between happen at the same moment), else what stays held.
            let nextIndex = plan.inputs.indices.dropFirst(index + 1).first { plan.inputs[$0] != nil }
            let next = nextIndex.flatMap { plan.inputs[$0] } ?? plan.after
            let handed = try perform(step, input: plan.inputs[index], alreadyHandedOver: handedOver == index,
                                     next: next, directory: directory)
            if handed { handedOver = nextIndex }
        }
    }

    /// Sets the engine's input, keeping a RESTORE the engine has not taken yet, and asking for one
    /// only once (not again when the input was handed over at the previous step's last frame).
    private func setInput(_ input: InputState, alreadyHandedOver: Bool) {
        var input = input
        if alreadyHandedOver { input.restore = false }
        if engine.input.restore { input.restore = true }
        engine.input = input
    }

    /// The input while `step` runs its frames: the step's keys or joystick on top of everything
    /// released (as in the lab's player, every step lets go of what it pressed). Nil for steps that
    /// run no frames of their own.
    static func input(during step: Session.Step) throws -> InputState? {
        try input(during: step, held: KeyMatrix())
    }

    /// The input while `step` runs its frames, with the keys `held` by `down:` steps. Nil for steps
    /// that set none.
    static func input(during step: Session.Step, held: KeyMatrix) throws -> InputState? {
        var input = InputState()
        input.keys = held
        switch step {
        case .wait(let frames):
            return frames > 0 ? input : nil
        case .press(let name, let frames):
            for key in try keys(name) { input.keys.set(key, pressed: true) }
            return frames > 0 ? input : nil
        case .joystick(let port, let directions, let frames):
            let state = try joystick(directions)
            if port == 1 { input.keys.joystick1 = state } else { input.keys.joystick2 = state }
            return frames > 0 ? input : nil
        case .waitPC, .waitByte:
            return input
        case .screenshot, .poke, .snapshot, .keysDown, .keysUp, .nmi, .peek, .coverage, .watch, .textScreen:
            return nil
        }
    }

    /// Performs `step`; returns true when it handed `next` to the engine before its last frame.
    private func perform(_ step: Session.Step, input: InputState?, alreadyHandedOver: Bool, next: InputState,
                         directory: URL?) throws -> Bool {
        switch step {
        case .wait(let frames), .press(_, let frames), .joystick(_, _, let frames):
            guard frames > 0, let input else { return false }
            // Already latched when the previous step ran its last frame (a no-op then); otherwise
            // it starts at the next frame end.
            setInput(input, alreadyHandedOver: alreadyHandedOver)
            try runFrames(frames - 1)
            setInput(next, alreadyHandedOver: false)
            try runFrames(1)
            return true
        case .screenshot(let name):
            guard let frame = latest else { throw Error.noFrame(name) }
            if let directory {
                let url = directory.appendingPathComponent("\(name).png")
                try ImageWriter.writePNG(indices: frame.pixels, width: VICPresenter.width,
                                         height: VICPresenter.height, scaleX: scaleX, scaleY: scaleY, to: url)
                screenshots.append(url)
            }
        case .poke(let address, let value):
            try debugging("poke").poke(address, value)
        case .waitPC(let address, let maxFrames):
            let d = try debugging("pc")
            if let input { setInput(input, alreadyHandedOver: alreadyHandedOver) }
            try d.run(untilPC: UInt16(truncatingIfNeeded: address), maxFrames: maxFrames)
        case .waitByte(let address, let value, let negate, let maxFrames):
            let d = try debugging("until")
            if let input { setInput(input, alreadyHandedOver: alreadyHandedOver) }
            d.run(untilByte: address, equals: value, negate: negate, maxFrames: maxFrames)
        case .snapshot(let name):
            let d = try debugging("snap")
            if let directory { try d.writeSnapshot(to: directory.appendingPathComponent("\(name).snap")) }
        case .peek(let address, let count):
            let d = try debugging("peek")
            let bytes = (0..<max(1, count)).map { String(format: "%02X", d.peek((address + $0) & 0xFFFF)) }
            output(String(format: "frame %llu $%04X: ", engine.cycles / VirtualClock.cyclesPerFrame, address)
                   + bytes.joined(separator: " "))
        case .textScreen:
            let d = try debugging("text")
            output("frame \(engine.cycles / VirtualClock.cyclesPerFrame) text screen:\n" + d.textScreen())
        case .keysDown, .keysUp, .nmi:
            break                                           // folded into the inputs (`plan`)
        case .coverage, .watch:
            skippedSteps += 1
        }
        return false
    }

    private func debugging(_ step: String) throws -> EngineDebugging {
        guard let d = engine as? EngineDebugging else { throw Error.unsupported(step) }
        return d
    }

    /// Parses "CTRL+C"-style key names.
    static func keys(_ name: String) throws -> [C64Key] { try C64Key.keys(named: name) }

    /// Parses "up+fire"-style joystick directions.
    static func joystick(_ text: String) throws -> JoystickState { try JoystickState(directions: text) }
}
