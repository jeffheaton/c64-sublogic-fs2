import C64Kit
import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Headless parity in replay mode: a session recorded in the lab (`ReplayLab.record`, the recorder
/// behind `fs2lab record`) and replayed through the native engine (D1a's `ReplayDriver` driving
/// `NativeEngine` on its program thread, `run` called in random slices) gives, at every main-loop
/// checkpoint, the lab's memory (the driver's hash) and the lab's frame, pixel for pixel.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct NativeEngineReplayTests {
    /// The lab's frame at checkpoint `k`: its RAM and color RAM with the split its raster IRQ
    /// latched there, the window state through the badline $A3 (as the lab's VIC shows it).
    static func labFrame(_ r: ReplayLab.Recording, _ k: Int) -> [UInt8]? {
        guard k < r.io.count, let view = r.io[k].view, let panel = r.io[k].panel else { return nil }
        var out: [UInt8] = []
        r.images[k].withUnsafeBufferPointer { ram in
            VICPresenter.render(into: &out, ram: ram, colorRAM: r.io[k].colorRAM, charROM: nil) { raster in
                raster >= 0x20 && raster <= 0xA3 ? view : panel
            }
        }
        return out
    }

    /// Records `name` (`session`, by default `re/sessions/replay-<name>.txt`, after `prefix`) and
    /// replays it through a native engine in random slices; the first `frames` frame ends deliver
    /// their frames too. `observe` sees the machine at every matching checkpoint.
    static func check(_ name: String, prefix: String = ReplaySessions.meigs, session: String? = nil, seed: UInt64,
                      frames: Int = 0, sourceLocation: SourceLocation = #_sourceLocation,
                      observe: ((Int, Machine) -> Void)? = nil) throws -> NativeEngine {
        let session = try session ?? ReplaySessions.text("replay-\(name)")
        let r = try ReplayLab.record(name, prefix: prefix, session: session)
        let engine = NativeEngine(replaying: r.log, on: ReplayLab.portMachine(r), from: .mainLoop)
        var compared = 0, problems: [String] = [], frameEnds = 0
        engine.onCheckpoint = { [unowned engine] k, frame in
            observe?(k, engine.machine)
            guard let expected = labFrame(r, k) else { return }
            compared += 1
            let differing = zip(frame.pixels, expected).filter { $0 != $1 }.count
            if differing != 0 && problems.count < 10 { problems.append("checkpoint \(k): \(differing) pixels differ") }
        }
        if frames > 0 { engine.onFrame = { _ in frameEnds += 1 } }
        var rng = TestRandom(seed: seed)
        var calls = 0
        while engine.endReason == nil && calls < 2_000_000 {
            engine.run(untilCycle: engine.cycles + 1 + rng.next() % 250_000)
            calls += 1
            if frameEnds >= frames { engine.onFrame = nil }
        }
        let outcome = try #require(engine.replayOutcome, "the replay ended", sourceLocation: sourceLocation)
        print("native replay \(name): \(outcome.matched)/\(outcome.checkpoints) checkpoints, \(compared) frames, "
              + "\(calls) run calls, \(frameEnds) frame ends; \(engine.endReason ?? "")")
        #expect(outcome.passed, "\(outcome.mismatch.map { "\($0)" } ?? outcome.error ?? "")", sourceLocation: sourceLocation)
        #expect(outcome.checkpoints >= 5 && compared >= outcome.checkpoints - 1, "\(compared) frames compared",
                sourceLocation: sourceLocation)
        #expect(problems.isEmpty, "\(problems)", sourceLocation: sourceLocation)
        #expect(calls > 100, "\(calls) slices", sourceLocation: sourceLocation)
        if frames > 0 { #expect(frameEnds >= frames, "frames between the checkpoints", sourceLocation: sourceLocation) }
        return engine
    }

    /// Take-off and climb: the scenery moves, the panel instruments all change.
    @Test func takeoff() throws {
        let engine = try Self.check("takeoff", seed: 0x7A4E)
        #expect(engine.machine.mem[0x0A12] == 0, "airborne")
    }

    /// Europe 1917, through the ported editor and war overlay, whose polls the driver counts like
    /// any other: the editor opened with E (its field loop and key waits), Europe 1917 turned on
    /// (page 0, line 6), the exit (mode 7, the WWI area, the war overlay loaded), then war passes
    /// with the slot $A7EE every pass (`warMain`, the enemies drawn through the scenery
    /// interpreter), W declaring war ('WAR !!!!' with its delay) and full throttle for the
    /// take-off roll.
    static let europe1917 = """
        key:E:14 pc:2250:1500 wait:10
        key:RETURN:14 wait:30 key:RETURN:14 wait:30 key:RETURN:14 wait:30 key:RETURN:14 wait:30
        key:RETURN:14 wait:30 key:1:14 wait:30
        key:E:14 pc:204B:3000 pc:204B:3000 wait:600
        key:W:14 wait:300
        key:;:150 wait:400
        """

    @Test func europe1917() throws {
        typealias R = MainLoop.RAM
        var overlays: Set<UInt16> = [], declared: Set<UInt8> = [], editor = false
        let engine = try Self.check("europe1917", session: Self.europe1917, seed: 0xE917, frames: 300) { _, m in
            overlays.insert(m.u16(0xA7E0))
            declared.insert(m.mem[War.declared])
            if m.mem[Input.RAM.editorRequest] != 0 { editor = true }
        }
        let m = engine.machine
        #expect(overlays.contains(0xB1EA), "the war overlay was resident: \(overlays.map { String(format: "$%04X", $0) })")
        #expect(m.mem[R.europe1917] == 1 && m.mem[R.currentMode] == 7 && m.u16(0xA7E0) == 0xB1EA, "war mode")
        #expect(declared.contains(3) && m.mem[War.started] == 1, "war declared: \(declared.sorted())")
        #expect(m.mem[0x0AC9] >= 0x40, "the throttle went up")
        #expect(editor, "a pass started with the editor requested by E")
    }

    /// A crash: the message, the editor overlay ported (the mode reload in text mode through
    /// `editorEntry`), the flight overlay and the scenery streamed in again. Frame ends are
    /// delivered too.
    @Test func crash() throws {
        let engine = try Self.check("crash", seed: 0xC4A5, frames: 200)
        #expect(engine.machine.mem[MainLoop.RAM.editorCacheState] == 1, "the editor overlay was loaded and cached")
        #expect(engine.machine.u16(0xA7E0) == 0xA800)
    }
}
