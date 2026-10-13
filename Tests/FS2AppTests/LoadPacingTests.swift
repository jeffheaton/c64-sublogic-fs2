import C64Kit
import FS2Core
import FS2LabKit
@testable import FS2App
import Foundation
import Testing

/// Frames in real time through the disk loads, on the native engine: the loader's time passes as
/// on the C64 (each sector's bytes at the drive's pace, `Machine.elapse`), and the clock stops at
/// every frame end, IRQ and run target inside a long charge (`Machine.charge`). So the headless
/// runner's waits run exactly their frames, and the app's paced loop (`FramePacer` and
/// `EngineLoop`, as `EngineHost` drives them) gets one frame per frame boundary, each presented at
/// its own cycle, never a burst after a load. (At its own cycle: or as late as the end of an IRQ
/// handler that ran past it, `slack`; the scheduler delivers no frame end inside a handler.)
@Suite(.enabled(if: TestDisk.data != nil, "needs the Flight Simulator II disk image"), .serialized)
struct LoadPacingTests {
    typealias R = MainLoop.RAM
    static let cpf = VirtualClock.cyclesPerFrame
    /// The longest an IRQ handler (the split, the frame tick with the keyboard scan) runs past a
    /// frame end or a run target. A load used to deliver its frames up to 22 frames late.
    static let slack: UInt64 = 5_000

    static func engine() throws -> NativeEngine {
        NativeEngine(data: try #require(TestDisk.data), modeLibrary: ModeLibrary.InMemoryStore().io)
    }

    /// Color display, regular flight: the flight overlay, then the Chicago area and the Meigs
    /// detail load in the frames that follow (over a thousand frames of disk I/O).
    static let prompts = "key:A:12 wait:60 key:B:12"

    /// `wait:30` steps through the loads: each runs exactly 30 frames and moves the clock 30 frames,
    /// and every frame is delivered with the clock at its own end (no frame of a load comes late,
    /// none in a burst).
    @Test func headlessWaitsRunTheirFramesDuringLoads() throws {
        let engine = try Self.engine()
        let runner = HeadlessRunner(engine: engine)
        try runner.quickBoot()
        try runner.play(try Session.parse(Self.prompts), screenshots: nil)
        #expect(engine.machine.vicDMA, "normal mode runs at the C64's pace, the VIC's DMA included")
        let runnersCallback = engine.onFrame
        var loadingFrames = 0, misplaced: [String] = [], indexes: [UInt64] = []
        engine.onFrame = { [unowned engine] f in
            runnersCallback?(f)
            indexes.append(f.frame)
            if engine.machine.mem[R.diskLoading] != 0 { loadingFrames += 1 }
            if engine.cycles - f.frame * Self.cpf > Self.slack, misplaced.count < 8 {
                misplaced.append("frame \(f.frame) delivered at cycle \(engine.cycles)")
            }
        }
        var steps: [String] = []
        for k in 0..<45 {
            let frames = runner.framesSeen, start = engine.cycles
            try runner.play(try Session.parse("wait:30"), screenshots: nil)
            let ran = runner.framesSeen - frames, moved = Int(engine.cycles) - Int(start)
            if ran != 30 || abs(moved - 30 * Int(Self.cpf)) > Int(Self.slack) {
                steps.append("wait \(k): \(ran) frames, \(moved) cycles")
            }
        }
        #expect(steps.isEmpty, "waits that did not run exactly 30 frames: \(steps.prefix(8))")
        #expect(loadingFrames > 600, "the waits ran through the loads: \(loadingFrames) frames inside them")
        #expect(misplaced.isEmpty, "\(misplaced)")
        #expect(indexes == Array(indexes.first!...indexes.last!), "one frame per frame end, in order")
    }

    /// The app's pacing loop with a simulated wall clock: whenever the clock passes the next frame
    /// boundary the engine runs to it (`FramePacer`), and through the loads every run delivers
    /// exactly one frame, at the boundary, so the frames reach the window one per 1/59.83 s.
    @Test func pacedLoopGetsOneFramePerBoundaryDuringLoads() throws {
        let engine = try Self.engine()
        let runner = HeadlessRunner(engine: engine)
        try runner.quickBoot()
        try runner.play(try Session.parse(Self.prompts), screenshots: nil)
        let exchange = FrameExchange()
        let loop = EngineLoop(engine: engine, frames: exchange, audio: nil)
        var published: [UInt64] = []
        var loadingFrames = 0
        let loopsCallback = engine.onFrame
        engine.onFrame = { [unowned engine] f in
            loopsCallback?(f)
            published.append(f.frame)
            if engine.machine.mem[R.diskLoading] != 0 { loadingFrames += 1 }
        }
        _ = loop
        var now: UInt64 = 1_000_000_000
        var pacer = FramePacer(now: now, cycles: engine.cycles)
        var runs = 0, bursts: [String] = [], late: [String] = []
        while published.count < 1_200 {
            switch pacer.next(now: now, cycles: engine.cycles) {
            case .run(let boundary):
                let before = published.count
                engine.run(untilCycle: boundary)
                runs += 1
                if published.count - before != 1, bursts.count < 8 {
                    bursts.append("run to \(boundary): \(published.count - before) frames")
                }
                if engine.cycles - boundary > Self.slack, late.count < 8 {
                    late.append("run to \(boundary) ended at \(engine.cycles)")
                }
            case .sleep(let nanoseconds):
                now += nanoseconds
            }
        }
        #expect(bursts.isEmpty, "\(bursts)")
        #expect(late.isEmpty, "\(late)")
        #expect(runs == published.count)
        #expect(published == Array(published.first!...published.last!), "one frame per frame end, in order")
        #expect(loadingFrames > 600, "the loop ran through the loads: \(loadingFrames) frames inside them")
    }
}
