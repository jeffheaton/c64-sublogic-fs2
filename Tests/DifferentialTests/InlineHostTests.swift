import C64Kit
import Foundation
import FS2Core
import FS2Data
import FS2Host
import Testing

/// The web worker's way of driving the engine (`SessionDriver` with an inline engine through
/// `InlineSessionHost`) against the Mac host's (the same driver's calls made of a threaded engine):
/// with the same clock and controls, the same frames, sound, demo states and final state.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct InlineHostTests {
    /// A scripted player with a fake clock: the controls change at given frames, every read of
    /// them advances the clock by a little (the time the host spends), the waits advance it by
    /// what they ask. Everything it does depends only on what the engine delivered, so two
    /// engines that compute the same see the same controls at the same moments.
    final class ScriptedControls: @unchecked Sendable {
        var clock: UInt64 = 1_000_000_000
        var frames = 0
        private var reads = 0
        private var rng = TestRandom(seed: 0xF52)
        private var requests = HostRequests()
        private var pauseUntilRead: Int?
        private var nextAction = 0
        private let actions: [(frame: Int, apply: (ScriptedControls) -> Void)]
        private let endFrame: Int
        var demoStatuses: [UInt8] = []

        init(endFrame: Int, actions: [(frame: Int, apply: (ScriptedControls) -> Void)]) {
            self.endFrame = endFrame
            self.actions = actions
        }

        func press(_ keys: C64Key..., joystick1: JoystickState = []) {
            var input = InputState()
            for k in keys { input.keys.set(k, pressed: true) }
            input.keys.joystick1 = joystick1
            requests.input = input
            requests.inputChanged = true
            for k in keys { requests.pressedSinceRead.set(k, pressed: true) }
        }

        /// A key pressed and let go between two reads.
        func tap(_ key: C64Key) {
            requests.inputChanged = true
            requests.pressedSinceRead.set(key, pressed: true)
        }

        func restart() { requests.restart = true }
        func demo() { requests.demo = true }
        func pause(reads: Int) { requests.paused = true; pauseUntilRead = self.reads + reads }
        func stall(nanoseconds: UInt64) { clock += nanoseconds }
        func options(_ change: (inout EngineOptions) -> Void) { change(&requests.options) }

        var io: SessionDriver.IO {
            var io = SessionDriver.IO(now: { [unowned self] in clock },
                                      wait: { [unowned self] in clock += $0 },
                                      readRequests: { [unowned self] in read() })
            io.demoStatus = { [unowned self] in
                if demoStatuses.last != $0.rawValue { demoStatuses.append($0.rawValue) }
            }
            return io
        }

        private func read() -> HostRequests? {
            reads += 1
            clock += 100_000 + rng.next() % 3_000_000
            if let until = pauseUntilRead, reads >= until {
                requests.paused = false
                pauseUntilRead = nil
            }
            while nextAction < actions.count && actions[nextAction].frame <= frames {
                actions[nextAction].apply(self)
                nextAction += 1
            }
            guard frames < endFrame else { return nil }
            let r = requests
            requests.restart = false; requests.demo = false; requests.inputChanged = false
            requests.pressedSinceRead = KeyMatrix()
            return r
        }
    }

    /// Title (A), the mode prompt (B), regular flight with a tap, a stall and a pause, the menu's
    /// demo (its editor visit), Smooth pacing, the keypad joystick with strict sharing, and the
    /// RUN/STOP + RESTORE sequence. Every frame is presented (as the app's host presents them),
    /// which is what a frame costs here.
    static func controls() -> ScriptedControls {
        ScriptedControls(endFrame: 2000, actions: [
            (30, { $0.press(.a) }), (44, { $0.press() }),
            (120, { $0.press(.b) }), (134, { $0.press() }),
            (900, { $0.tap(.l) }),
            (1000, { $0.stall(nanoseconds: 2_000_000_000) }),
            (1100, { $0.pause(reads: 40) }),
            (1200, { $0.demo() }),
            (1300, { $0.options { $0.pacing = .smooth } }),
            (1350, { $0.options { $0.strictJoystick = true } }),
            (1360, { $0.press(joystick1: [.up, .left]) }), (1400, { $0.press() }),
            (1450, { $0.press(.space) }), (1464, { $0.press() }),
            (1550, { $0.options { $0.pacing = .authentic; $0.strictJoystick = false } }),
            (1650, { $0.restart() }),
        ])
    }

    struct Run {
        var frames: [UInt64] = []
        var hashes: [Int] = []
        var writes: [UInt64] = []
        var audio: [AudioEvent] = []
    }

    /// A hash of the picture (the process's seed: comparable within one test run).
    static func hash(_ pixels: [UInt8]) -> Int {
        var h = Hasher()
        pixels.withUnsafeBytes { h.combine(bytes: $0) }
        return h.finalize()
    }

    static func driver(_ engine: NativeEngine, _ controls: ScriptedControls, _ run: UnsafeMutablePointer<Run>)
        -> SessionDriver {
        let feed = AudioFeed()
        feed.active.store(true, ordering: .relaxed)
        var io = controls.io
        io.sliceEnded = { _ in
            while let e = feed.ring.pop() { run.pointee.audio.append(e) }
        }
        return SessionDriver(engine: engine, audio: feed, options: EngineOptions(), io: io) { frame in
            run.pointee.frames.append(frame.frame)
            run.pointee.hashes.append(hash(frame.pixels))
            run.pointee.writes += frame.sidWrites.map { $0.cycle << 16 | UInt64($0.reg) << 8 | UInt64($0.value) }
            controls.frames += 1
        }
    }

    @Test func inlineHostMatchesThreadedHost() throws {
        let data = try #require(Original.data)

        let threaded = NativeEngine(data: data, modeLibrary: ModeLibrary.InMemoryStore().io, execution: .thread)
        let threadedControls = Self.controls()
        let threadedRun = UnsafeMutablePointer<Run>.allocate(capacity: 1)
        threadedRun.initialize(to: Run())
        defer { threadedRun.deinitialize(count: 1); threadedRun.deallocate() }
        let t = Self.driver(threaded, threadedControls, threadedRun)
        var previous: InlineRequest?
        while let request = t.next(after: previous) {
            switch request {
            case .run(let cycle): threaded.run(untilCycle: cycle)
            case .skipDiskLoading: threaded.skipDiskLoading()
            case .runToKeyWait(let n, let d): threaded.runToKeyWait(maxFrames: n, deliverFrames: d)
            }
            previous = request
        }

        let inline = NativeEngine(data: data, modeLibrary: ModeLibrary.InMemoryStore().io, execution: .inline)
        let inlineControls = Self.controls()
        let inlineRun = UnsafeMutablePointer<Run>.allocate(capacity: 1)
        inlineRun.initialize(to: Run())
        defer { inlineRun.deinitialize(count: 1); inlineRun.deallocate() }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var endReason: String?
        let host = InlineSessionHost(driver: Self.driver(inline, inlineControls, inlineRun),
                                     stopped: { done.signal(); Thread.exit(); fatalError("Thread.exit returned") },
                                     ended: { endReason = $0; done.signal(); Thread.exit(); fatalError("Thread.exit returned") })
        nonisolated(unsafe) let unsafeInline = inline
        nonisolated(unsafe) let unsafeHost = host
        let thread = Thread { unsafeInline.runInline(unsafeHost) }
        thread.stackSize = ProgramThread.defaultStackSize
        thread.start()
        done.wait()

        let a = threadedRun.pointee, b = inlineRun.pointee
        #expect(endReason == nil, "the inline program ended: \(endReason ?? "")")
        #expect(a.frames.count >= 2000 && a.frames == b.frames, "\(a.frames.count) vs \(b.frames.count) frames")
        let firstDifferent = zip(a.hashes, b.hashes).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(firstDifferent == nil, "frame \(firstDifferent ?? -1) differs")
        #expect(a.writes == b.writes, "SID writes differ (\(a.writes.count) vs \(b.writes.count))")
        #expect(a.audio == b.audio, "audio events differ (\(a.audio.count) vs \(b.audio.count))")
        #expect(threadedControls.demoStatuses == inlineControls.demoStatuses)
        #expect(threadedControls.clock == inlineControls.clock)
        NativeEngineThreadTests.expectSame(threaded, inline, writes: ([], []))
        // The script did what it is about: the demo was offered, then ran.
        let running = DemoMode.Status(running: true).rawValue
        #expect(threadedControls.demoStatuses.contains(running), "statuses \(threadedControls.demoStatuses)")
        #expect(a.audio.contains { $0.kind == .write }, "SID writes reached the audio feed")
    }
}
