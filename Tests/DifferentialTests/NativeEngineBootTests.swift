import C64Kit
import Foundation
import FS2Core
import FS2Data
import FS2LabKit
import Testing

/// Scripted input for a native engine: keys held for frame ranges, set at frame ends (the input
/// set from `onFrame` applies from the end of the next frame, as the `GameEngine` contract says).
final class NativeScript {
    /// (first frame, frames, keys) steps, by the frame index `FrameOutput.frame`.
    var steps: [(start: UInt64, frames: UInt64, keys: [C64Key])] = []
    private(set) var frames: [UInt64] = []

    func attach(to engine: NativeEngine, keep: Bool = false, observe: ((FrameOutput) -> Void)? = nil) {
        engine.onFrame = { [unowned self, unowned engine] frame in
            if keep { self.frames.append(frame.frame) }
            observe?(frame)
            let next = frame.frame + 1
            var input = InputState()
            for s in self.steps where next >= s.start && next < s.start + s.frames {
                for k in s.keys { input.keys.set(k, pressed: true) }
            }
            engine.input = input
        }
    }

    /// Holds `keys` for `frames` frames from frame `start` on.
    func press(_ keys: [C64Key], at start: UInt64, frames: UInt64 = 12) {
        steps.append((start, frames, keys))
    }
}

/// The native engine's boot: the cold start from the disk through the title and the prompts.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct NativeEngineBootTests {
    static func engine(options: EngineOptions = EngineOptions()) throws -> NativeEngine {
        let data = try #require(Original.data)
        return NativeEngine(data: data, options: options, modeLibrary: ModeLibrary.InMemoryStore().io)
    }

    /// The boot runs to the title prompt (the first key wait) in about the lab's time, and the
    /// title frame is the lab's, pixel for pixel (the crack's rows blank).
    @Test func bootsToTheTitle() throws {
        let engine = try Self.engine()
        let start = Date()
        #expect(engine.runToKeyWait(maxFrames: 9000, deliverFrames: false))
        let bootSeconds = Date().timeIntervalSince(start)
        let titleCycles = engine.cycles
        var last: FrameOutput?
        engine.onFrame = { last = $0 }
        engine.run(untilCycle: engine.cycles + 10 * VirtualClock.cyclesPerFrame)
        let frame = try #require(last)

        let lab = Lab.boot(try #require(Original.data))
        try lab.play(try Session.parse("pc:2250:9000"), screenshots: nil)
        let labCycles = lab.cpu.cycles
        try lab.play(try Session.parse("wait:10"), screenshots: nil)
        let reference = lab.renderLastFrame()
        let differing = zip(frame.pixels, reference).filter { $0 != $1 }.count
        print("native boot: \(titleCycles) cycles (lab \(labCycles)) in \(String(format: "%.2f", bootSeconds)) s")
        if differing != 0 {
            let at = (0..<frame.pixels.count).filter { frame.pixels[$0] != reference[$0] }
            let rows = Set(at.map { $0 / VICPresenter.width }).sorted()
            print("rows \(rows), columns \(at.prefix(8).map { $0 % VICPresenter.width }), native \(at.prefix(4).map { frame.pixels[$0] }) lab \(at.prefix(4).map { reference[$0] })")
            let dir = Original.repoRoot.appendingPathComponent("build/testdata")
            try? ImageWriter.writePNG(indices: frame.pixels, width: VICPresenter.width, height: VICPresenter.height,
                                      scaleX: 2, scaleY: 2, to: dir.appendingPathComponent("native-title.png"))
            try? ImageWriter.writePNG(indices: reference, width: VICPresenter.width, height: VICPresenter.height,
                                      scaleX: 2, scaleY: 2, to: dir.appendingPathComponent("lab-title.png"))
        }
        #expect(differing == 0, "\(differing) pixels of the title differ from the lab's")
        let ratio = Double(titleCycles) / Double(labCycles)
        #expect(ratio > 0.9 && ratio < 1.1, "the boot takes \(titleCycles) cycles, the lab \(labCycles)")
        #expect(frame.monochrome == (engine.machine.mem[0x0E69] == 0))
    }

    /// From the title: A (color), then B (regular flight) at the mode prompt; the flight overlay
    /// loads, the main loop runs at Meigs, and the frames show the split with the window border.
    @Test func answersThePromptsAndFlies() throws {
        let engine = try Self.engine()
        #expect(engine.runToKeyWait(maxFrames: 9000, deliverFrames: false))
        let script = NativeScript()
        var frames = 0, monochrome = 0, last: FrameOutput?
        script.attach(to: engine) { f in
            frames += 1
            if f.monochrome { monochrome += 1 }
            last = f
        }
        var iterations = 0
        engine.onIteration = { _ in iterations += 1 }
        let title = engine.cycles / VirtualClock.cyclesPerFrame
        script.press([.a], at: title + 4)
        #expect(engine.runToKeyWait(maxFrames: 600), "the mode prompt waits for a key")
        let prompt = engine.cycles / VirtualClock.cyclesPerFrame
        script.press([.b], at: prompt + 4)
        let start = Date()
        engine.run(untilCycle: engine.cycles + 1200 * VirtualClock.cyclesPerFrame)
        let seconds = Date().timeIntervalSince(start)
        print("native flight: \(iterations) passes in 1200 frames, \(String(format: "%.2f", seconds)) s")
        let m = engine.machine
        #expect(m.mem[0x0E69] == 0x0B, "A chose the color display")
        #expect(m.mem[MainLoop.RAM.demoRequest] == 0, "B chose regular flight")
        #expect(m.u16(0xA7E0) == 0xA800, "the flight overlay is resident")
        // The flight overlay, the root block and the Chicago and Meigs blocks load first (~6 s).
        #expect(iterations >= 4, "\(iterations) main-loop passes")
        #expect(frames >= 1200 && monochrome == 0)
        #expect(engine.endReason == nil)
        let f = try #require(last)
        // The window border is the time-of-day color, the panel's $0C.
        let leftBorder = { (row: Int) in f.pixels[row * VICPresenter.width] }
        #expect(leftBorder(VICPresenter.rasterLineRow(0x40)) == m.mem[MainLoop.RAM.borderOperand] & 0x0F)
        #expect(leftBorder(VICPresenter.rasterLineRow(0xC0)) == 0x0C)
    }
}

extension VICPresenter {
    /// The frame row that shows raster line `line`.
    static func rasterLineRow(_ line: Int) -> Int { (line - firstRasterLine + rasterLines) % rasterLines }
}
