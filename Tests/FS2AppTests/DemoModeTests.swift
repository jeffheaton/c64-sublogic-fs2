import C64Kit
import FS2Core
import FS2Data
@testable import FS2App
import Foundation
import Testing

/// Machine ▸ Demo Mode on the native engine (needs the disk), played headless: the menu's request
/// starts the same demo as A at the operating-mode prompt, any key leaves it, and it is not offered
/// outside flight.
@Suite(.enabled(if: TestDisk.data != nil, "needs the Flight Simulator II disk image"), .serialized)
struct DemoModeTests {
    /// A native engine after `session` (headless steps).
    static func engine(after session: String) throws -> NativeEngine {
        let engine = NativeEngine(data: try #require(TestDisk.data), modeLibrary: ModeLibrary.InMemoryStore().io)
        try play(session, on: engine)
        return engine
    }

    static func play(_ session: String, on engine: NativeEngine) throws {
        let runner = HeadlessRunner(engine: engine)
        runner.output = { _ in }
        try runner.play(try Session.parse(session), screenshots: nil)
    }

    /// One engine through every state (a debug-build boot is slow):
    /// - the title, the mode prompt, the pause (a key wait) and the editor refuse the request: the
    ///   prompt answers the title itself, a key wait is the player's to end, and the editor's exit
    ///   would clear `$095B` before the demo check saw it;
    /// - in regular flight the request is `$095B` = 1, the byte the prompt's A (`INC $095B`)
    ///   leaves; the main loop's demo check sets `$08BB` = 3, the editor loads built-in mode 2 and
    ///   its exit sets `$095A` (the prompt's own path is replayed by `ColdInitTests` and
    ///   `ReplayTests.demoMode`);
    /// - a key (D, which does nothing else) clears `$095A`: the demo is over and the flight goes on.
    @Test func menuStartsTheDemoAsThePromptDoes() throws {
        let engine = try Self.engine(after: "pc:2250:9000")
        let mem = engine.machine.mem
        func expectRefused(_ state: String) {
            #expect(!DemoMode.status(of: engine).available, "\(state)")
            #expect(!DemoMode.start(on: engine), "\(state)")
            #expect(mem[MainLoop.RAM.demoRequest] == 0, "\(state)")
        }
        expectRefused("title")
        try Self.play("key:A:12 pc:2250:600", on: engine)
        expectRefused("mode prompt")
        // B, then flying at Meigs once the first scenery loads are done (keys are not scanned
        // during a load): the flight overlay, whose end word $A800 is at $A7E0, is resident.
        try Self.play("key:B:12 until:A7E1:A8:3000 wait:1800", on: engine)
        #expect(DemoMode.status(of: engine) == DemoMode.Status(available: true, running: false), "flying")
        try Self.play("key:P:12 pc:2250:600", on: engine)
        expectRefused("paused")
        try Self.play("wait:30 key:P:12 wait:300", on: engine)
        #expect(DemoMode.status(of: engine).available, "flying again")
        try Self.play("key:E:12 pc:2250:3000", on: engine)
        #expect(mem[MainLoop.RAM.editorRequest] != 0, "in the editor")
        expectRefused("editor")
        try Self.play("wait:30 key:E:12 until:A7E1:A8:3000 wait:1800", on: engine)

        #expect(DemoMode.status(of: engine) == DemoMode.Status(available: true, running: false), "flying")
        #expect(mem[0x095A] == 0 && mem[ModeLibrary.currentMode] == 0, "regular flight in mode 0")
        #expect(DemoMode.start(on: engine))
        #expect(mem[MainLoop.RAM.demoRequest] == 1, "the prompt's INC $095B")
        #expect(DemoMode.status(of: engine) == DemoMode.Status(available: false, running: true), "requested")
        #expect(!DemoMode.start(on: engine), "requested once, as the prompt answers once")
        #expect(mem[MainLoop.RAM.demoRequest] == 1, "not INC'd to 2")

        let before = engine.cycles
        try Self.play("until:095A:01:3000", on: engine)
        let frames = (engine.cycles - before) / VirtualClock.cyclesPerFrame
        #expect(mem[0x095A] == 1 && mem[MainLoop.RAM.demoRequest] == 0, "the editor's exit hands the request over")
        #expect(mem[ModeLibrary.currentMode] == 2)
        // The editor overlay is still resident: the record is its built-in mode 2.
        let mode2 = ModeLibrary.builtInModes + 2 * ModeLibrary.recordSize
        #expect((0..<ModeLibrary.recordSize).allSatisfy { mem[ModeLibrary.record + $0] == mem[mode2 + $0] },
                "mode 2 loaded")
        // The help says the demo begins within about 20 seconds: a demo check every 8 passes, then
        // the editor overlay's load at the 1541's speed.
        #expect(frames < 30 * 60, "the demo began after \(frames) frames")

        // The demo flies; any key takes over (once its scenery is loaded: keys are not scanned
        // during a load).
        try Self.play("until:A7E1:A8:3000 wait:1800", on: engine)
        #expect(DemoMode.status(of: engine) == DemoMode.Status(available: false, running: true), "the demo")
        // The menu does not start it over while it runs (the original never reloads mode 2 then).
        let cyclesInDemo = engine.cycles
        #expect(!DemoMode.start(on: engine))
        #expect(mem[MainLoop.RAM.demoRequest] == 0 && mem[MainLoop.RAM.modeRequest] == 0)
        #expect(engine.cycles == cyclesInDemo)
        try Self.play("key:D:12 until:095A:00:300 wait:60", on: engine)
        #expect(mem[0x095A] == 0, "a key ends the demo")
        #expect(mem[ModeLibrary.currentMode] == 2, "the flight goes on in mode 2, the player's now")
        #expect(DemoMode.status(of: engine) == DemoMode.Status(available: true, running: false))
    }
}

/// The menu's path through `EngineHost`: the request reaches the engine on its thread, and the
/// status the menu shows comes back.
@Suite(.serialized) struct DemoModeHostTests {
    /// A `GameEngine` with memory only: frames of nothing, `peek` and `poke` on 64 KB.
    final class MemoryEngine: GameEngine, EngineDebugging {
        var cycles: UInt64 = 0
        var input = InputState()
        var onFrame: ((FrameOutput) -> Void)?
        var options = EngineOptions()
        var mem = [UInt8](repeating: 0, count: 0x10000)

        init(flying: Bool) {
            if flying { mem[0xA7E0] = 0x00; mem[0xA7E1] = 0xA8 } else { mem[0xA7E0] = 0x00; mem[0xA7E1] = 0xAD }
        }

        func run(untilCycle cycle: UInt64) {
            let cpf = VirtualClock.cyclesPerFrame
            while cycles < cycle {
                cycles = min(cycle, (cycles / cpf + 1) * cpf)
                if cycles % cpf == 0 {
                    onFrame?(FrameOutput(pixels: [], frame: cycles / cpf, sidWrites: [], monochrome: false))
                }
            }
        }

        func poke(_ address: Int, _ value: UInt8) { mem[address & 0xFFFF] = value }
        func peek(_ address: Int) -> UInt8 { mem[address & 0xFFFF] }
        func run(untilPC address: UInt16, maxFrames: Int) throws -> Bool { false }
        func run(untilByte address: Int, equals value: UInt8, negate: Bool, maxFrames: Int) -> Bool { false }
        func textScreen() -> String { "" }
        func writeSnapshot(to url: URL) throws {}
        func skipDiskLoading() {}
    }

    /// Hands the engine the host's thread made back to the test (read after `stop`).
    final class EngineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _engine: MemoryEngine?
        var engine: MemoryEngine? {
            get { lock.withLock { _engine } }
            set { lock.withLock { _engine = newValue } }
        }
    }

    static func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    @Test(arguments: [true, false]) func requestReachesTheEngine(flying: Bool) throws {
        let box = EngineBox()
        let host = EngineHost(frames: FrameExchange(), audio: nil) {
            let engine = MemoryEngine(flying: flying)
            box.engine = engine
            return engine
        }
        host.start()
        #expect(Self.waitFor { host.demoStatus.available == flying || !flying && box.engine != nil })
        #expect(!host.demoStatus.running)
        host.requestDemo()
        if flying {
            #expect(Self.waitFor { host.demoStatus.running }, "the status shows the demo requested")
            #expect(!host.demoStatus.available, "requested once")
        } else {
            Thread.sleep(forTimeInterval: 0.2)
            #expect(!host.demoStatus.running && !host.demoStatus.available)
        }
        host.stop()
        let engine = try #require(box.engine)
        #expect(engine.mem[MainLoop.RAM.demoRequest] == (flying ? 1 : 0))
    }

    /// Each condition of `DemoMode.status` on its own, in memory: the flight overlay resident, not
    /// Europe 1917, no editor visit, mode request or key wait, and the demo neither running nor
    /// requested. `start` pokes `$095B` = 1 exactly when the status allows it.
    @Test func statusFollowsMemory() {
        typealias R = MainLoop.RAM
        func status(_ change: (MemoryEngine) -> Void) -> (DemoMode.Status, started: Bool, request: UInt8) {
            let engine = MemoryEngine(flying: true)
            change(engine)
            let before = DemoMode.status(of: engine)
            let started = DemoMode.start(on: engine)
            return (before, started, engine.mem[R.demoRequest])
        }
        let flying = status { _ in }
        #expect(flying.0 == DemoMode.Status(available: true, running: false))
        #expect(flying.started && flying.request == 1)
        let refused: [(String, (MemoryEngine) -> Void)] = [
            ("cold-start overlay", { $0.mem[0xA7E1] = 0xAD }),
            ("overlay end word low byte", { $0.mem[0xA7E0] = 0x01 }),
            ("Europe 1917", { $0.mem[R.warModeLatch] = 7 }),
            ("editor or key wait", { $0.mem[R.editorRequest] = 1 }),
            ("mode request", { $0.mem[R.modeRequest] = 1 }),
            ("demo check's request", { $0.mem[R.modeRequest] = 3 }),
        ]
        for (what, change) in refused {
            let s = status(change)
            #expect(s.0 == DemoMode.Status(available: false, running: false), "\(what)")
            #expect(!s.started && s.request == 0, "\(what)")
        }
        let demo = status { $0.mem[0x095A] = 1 }
        #expect(demo.0 == DemoMode.Status(available: false, running: true), "the demo runs")
        #expect(!demo.started && demo.request == 0, "the demo runs")
        let requested = status { $0.mem[R.demoRequest] = 1 }
        #expect(requested.0 == DemoMode.Status(available: false, running: true), "requested")
        #expect(!requested.started && requested.request == 1, "requested")
        // The prompt's A while the title is up: running (checked) but not the menu's to start.
        let prompt = status { $0.mem[0xA7E1] = 0xAD; $0.mem[R.demoRequest] = 1 }
        #expect(prompt.0 == DemoMode.Status(available: false, running: true))
        // An engine without memory access never offers the demo.
        final class Opaque: GameEngine {
            var cycles: UInt64 = 0
            var input = InputState()
            var onFrame: ((FrameOutput) -> Void)?
            var options = EngineOptions()
            func run(untilCycle cycle: UInt64) { cycles = cycle }
        }
        #expect(DemoMode.status(of: Opaque()) == DemoMode.Status())
        #expect(!DemoMode.start(on: Opaque()))
    }

    @Test func statusRoundTrips() {
        for available in [false, true] {
            for running in [false, true] {
                let s = DemoMode.Status(available: available, running: running)
                #expect(DemoMode.Status(rawValue: s.rawValue) == s)
            }
        }
    }
}
