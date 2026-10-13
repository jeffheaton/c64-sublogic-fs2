import C64Kit
import Foundation
import FS2Core
import FS2Data
import FS2LabKit
import Testing

/// The native engine's thread handshake: however `run(untilCycle:)` slices the virtual time, and
/// whatever the host observes on the way (frames, main-loop tops), the program computes exactly the
/// same thing.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct NativeEngineThreadTests {
    typealias R = MainLoop.RAM

    /// One step of the scripted session, performed identically on every engine.
    enum Step {
        /// Run to the next key wait (`runToKeyWait`, never sliced: the stop is a poll).
        case keyWait(maxFrames: Int)
        /// Run `frames` frames past the current frame's start (sliced at random on the stressed
        /// engine), then set `input`.
        case frames(UInt64, then: InputState)
    }

    static func keys(_ k: C64Key..., restore: Bool = false) -> InputState {
        var i = InputState()
        for key in k { i.keys.set(key, pressed: true) }
        i.restore = restore
        return i
    }

    /// Boot, color, regular flight (the overlay and scenery loads, then passes at Meigs), RUN/STOP
    /// + RESTORE (the pause, then the cold restart nested inside its key wait), the title again,
    /// color, the demo (its editor visit loads mode 2 in text mode, then it flies). Keys are held
    /// 14 frames, and released 8 frames before the next press (the scan must see them up).
    static let session: [Step] = [
        .keyWait(maxFrames: 9000),                                          // 0: the title
        .frames(8, then: keys(.a)), .frames(14, then: InputState()),
        .keyWait(maxFrames: 600),                                           // 3: the mode prompt
        .frames(8, then: keys(.b)), .frames(14, then: InputState()),
        .frames(1100, then: InputState()),                                  // 6: loads, flight
        .frames(200, then: keys(.runStop)),                                 // 7: frames delivered
        .frames(14, then: keys(.runStop, restore: true)),
        .frames(2, then: InputState()),
        .keyWait(maxFrames: 9000),                                          // 10: the title again
        .frames(8, then: keys(.a)), .frames(14, then: InputState()),
        .keyWait(maxFrames: 600),
        .frames(8, then: keys(.a)), .frames(14, then: InputState()),
        .frames(2400, then: InputState()),                                  // 16: the demo
    ]

    /// Plays `session` on `engine`; `slice` splits each `.frames` run into pieces (nil: one call).
    /// `around` is called before every step with its index (to attach or detach observers).
    static func play(_ engine: NativeEngine, slice: ((UInt64, UInt64) -> [UInt64])? = nil,
                     around: ((Int) -> Void)? = nil) -> (keyWaits: [Bool], runCalls: Int) {
        var keyWaits: [Bool] = [], calls = 0
        let frame = VirtualClock.cyclesPerFrame
        for (k, step) in session.enumerated() {
            around?(k)
            switch step {
            case .keyWait(let maxFrames):
                keyWaits.append(engine.runToKeyWait(maxFrames: maxFrames))
            case .frames(let n, let input):
                let target = (engine.cycles / frame + n) * frame
                for t in slice?(engine.cycles, target) ?? [target] {
                    engine.run(untilCycle: t)
                    calls += 1
                }
                engine.input = input
            }
        }
        return (keyWaits, calls)
    }

    static func engine() throws -> NativeEngine {
        NativeEngine(data: try #require(Original.data), modeLibrary: ModeLibrary.InMemoryStore().io)
    }

    typealias Write = (cycle: UInt64, reg: UInt8, value: UInt8)

    /// The state that must be identical between two runs (with the SID writes the frames took).
    static func expectSame(_ a: NativeEngine, _ b: NativeEngine, writes: ([Write], [Write]),
                           sourceLocation: SourceLocation = #_sourceLocation) {
        let ma = a.machine, mb = b.machine
        #expect(ma.clock.cycles == mb.clock.cycles, "clock \(ma.clock.cycles) vs \(mb.clock.cycles)",
                sourceLocation: sourceLocation)
        let d = Original.differences(ma.memoryImage, mb.memoryImage, ignoring: [])
        #expect(d.isEmpty, "\(d.count) bytes differ, first \(d.prefix(8).map { String(format: "$%04X", $0) })",
                sourceLocation: sourceLocation)
        #expect(ma.io.vic == mb.io.vic && ma.io.sid == mb.io.sid && ma.io.colorRAM == mb.io.colorRAM,
                sourceLocation: sourceLocation)
        #expect(ma.io.viewRegion == mb.io.viewRegion && ma.io.panelRegion == mb.io.panelRegion,
                sourceLocation: sourceLocation)
        #expect(ma.io.cia2PortA == mb.io.cia2PortA && ma.io.timeOfDay == mb.io.timeOfDay,
                sourceLocation: sourceLocation)
        let wa = (writes.0 + ma.io.sidWrites).map { "\($0.cycle):\($0.reg):\($0.value)" }
        let wb = (writes.1 + mb.io.sidWrites).map { "\($0.cycle):\($0.reg):\($0.value)" }
        #expect(wa == wb, "SID write streams differ (\(wa.count) vs \(wb.count))", sourceLocation: sourceLocation)
    }

    /// Thousands of `run` slices of random sizes (1 to 60,000 cycles, so targets fall anywhere:
    /// inside interrupt handlers, disk loads, the scenery interpreter, the nested restart), and
    /// main-loop tops delivered during the demo, against one call per step: the same memory,
    /// clock, I/O state, frames and SID writes, the same key-wait stops.
    @Test func randomSlicesComputeTheSame() throws {
        let reference = try Self.engine()
        var referenceFrames: [UInt64: [UInt8]] = [:], referenceWrites: [Write] = []
        let start = Date()
        let r = Self.play(reference, around: { k in
            if k == 7 {
                reference.onFrame = { f in referenceFrames[f.frame] = f.pixels; referenceWrites += f.sidWrites }
            }
            if k == 10 { reference.onFrame = nil }
        })
        let referenceSeconds = Date().timeIntervalSince(start)
        #expect(r.keyWaits == [true, true, true, true], "every key wait was reached: \(r.keyWaits)")
        #expect(reference.endReason == nil)

        let stressed = try Self.engine()
        var rng = TestRandom(seed: 0xD1B)
        var frames: [UInt64] = [], sameFrames = 0, iterations = 0, stressedWrites: [Write] = []
        let s = Self.play(stressed, slice: { from, to in
            var cuts: [UInt64] = []
            var t = from
            while t < to {
                t = min(to, t + 1 + rng.next() % 60_000)
                cuts.append(t)
            }
            return cuts
        }, around: { k in
            if k == 7 {
                stressed.onFrame = { f in
                    frames.append(f.frame)
                    if referenceFrames[f.frame] == f.pixels { sameFrames += 1 }
                    stressedWrites += f.sidWrites
                }
            }
            if k == 10 { stressed.onFrame = nil }
            if k == 16 { stressed.onIteration = { _ in iterations += 1 } }
        })
        print("thread stress: reference \(r.runCalls) run calls in \(String(format: "%.1f", referenceSeconds)) s; "
              + "stressed \(s.runCalls) run calls, \(frames.count) frames, \(iterations) main-loop tops")
        #expect(s.keyWaits == r.keyWaits)
        #expect(s.runCalls > 2000, "\(s.runCalls) slices")
        #expect(frames.count == referenceFrames.count && frames.count == 216, "\(frames.count) frames")
        #expect(frames == Array(frames.first!...frames.last!), "one frame per frame end, in order")
        #expect(sameFrames == frames.count, "\(frames.count - sameFrames) frames differ from the reference's")
        #expect(iterations > 3, "\(iterations) main-loop tops in the demo")
        Self.expectSame(reference, stressed, writes: (referenceWrites, stressedWrites))
        // The session did what it is about: the demo after the restart, flying mode 2.
        let m = stressed.machine
        #expect(m.mem[0x0E69] == 0x0B && m.mem[Input.RAM.demoActive] == 1, "color, the demo running")
        #expect(m.mem[R.currentMode] == 2 && m.mem[R.restoreOneShot] == 0, "mode 2; the restart cleared the one-shot")
    }

    /// Engines dropped in every state (not started, parked in the boot, at the title, in flight,
    /// inside the nested restart) end their program threads, and the rest goes on.
    @Test func enginesEndTheirThreads() throws {
        let frame = VirtualClock.cyclesPerFrame
        for k in 0..<5 {
            let engine = try Self.engine()
            switch k {
            case 0: break
            case 1: engine.run(untilCycle: 5_000_000)
            case 2: engine.runToKeyWait(maxFrames: 9000, deliverFrames: false)
            default:
                engine.runToKeyWait(maxFrames: 9000, deliverFrames: false)
                engine.run(untilCycle: engine.cycles + 8 * frame)
                engine.input = Self.keys(.a)
                engine.run(untilCycle: engine.cycles + 14 * frame)
                engine.input = InputState()
                engine.runToKeyWait(maxFrames: 600)
                engine.run(untilCycle: engine.cycles + 8 * frame)
                engine.input = Self.keys(.b)
                engine.run(untilCycle: engine.cycles + 14 * frame)
                engine.input = InputState()
                // In flight (the scenery interpreter runs most of the time), then for k = 4 the
                // RUN/STOP + RESTORE restart, parked inside the nested cold start's boot loads.
                engine.run(untilCycle: engine.cycles + 1300 * frame + 12_345)
                #expect(engine.machine.u16(0xA7E0) == 0xA800, "the flight overlay is resident")
                if k == 4 {
                    engine.input = Self.keys(.runStop)
                    engine.run(untilCycle: engine.cycles + 14 * frame)
                    engine.input = Self.keys(.runStop, restore: true)
                    engine.run(untilCycle: engine.cycles + 2 * frame)
                    engine.input = InputState()
                    engine.run(untilCycle: engine.cycles + 100 * frame)
                    #expect(engine.machine.u16(0xA7E0) == 0xAD00, "the cold-start overlay is back (restarting)")
                }
                #expect(engine.endReason == nil)
            }
        }
        // Still alive and computing after all those threads went away.
        let engine = try Self.engine()
        #expect(engine.runToKeyWait(maxFrames: 9000, deliverFrames: false))
    }
}
