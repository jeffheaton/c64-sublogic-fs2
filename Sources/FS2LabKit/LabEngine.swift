import C64Kit
import FS2Core
import FS2Data

/// Development-only engine: the lab machine running SubLogic's original code, behind the same
/// interface as the native port, for side-by-side comparison in the app (FS2_ENGINE=lab).
public final class LabEngine: GameEngine {
    public let machine: C64Machine
    public var input = InputState()
    public var onFrame: ((FrameOutput) -> Void)?
    /// Kept for the `GameEngine` contract; the lab runs the original as it is (authentic pacing,
    /// the original's joystick arbitration) and ignores them.
    public var options = EngineOptions()
    /// Render a picture for each frame (turn off to run flat out through disk loading).
    public var renderFrames = true
    private var sidCursor = 0

    public init(data: GameData) {
        machine = Lab.boot(data)
        machine.captureFrames = true
        machine.onFrame = { [unowned self] m in self.frameDone(m) }
    }

    public var cycles: UInt64 { machine.cpu.cycles }

    public func run(untilCycle cycle: UInt64) {
        while machine.cpu.cycles < cycle {
            if !machine.step() { return }
        }
    }

    private func frameDone(_ m: C64Machine) {
        m.keyboard = input.keys
        if input.restore {
            input.restore = false
            m.pressNMI()
        }
        let writes = m.bus.sidWrites
        let new = Array(writes[sidCursor...])
        sidCursor = writes.count
        if sidCursor > 100_000 { m.bus.sidWrites.removeAll(keepingCapacity: true); sidCursor = 0 }
        // The color/B&W choice: background $00 in the window region means the B&W palette set.
        let mono = m.bus.ram[0x0E69] == 0
        guard renderFrames else { return }
        onFrame?(FrameOutput(pixels: m.renderLastFrame(), frame: UInt64(m.frameCount), sidWrites: new,
                             monochrome: mono))
    }
}
