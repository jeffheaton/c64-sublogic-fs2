import C64Kit
import Foundation
import FS2Core
import FS2Data
import Testing

/// Inline execution (`NativeEngine.runInline`, the WebAssembly build's only kind): the program runs
/// on the host's stack and the host makes its calls at the parks. For the same calls it computes
/// exactly what the threaded engine computes.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct NativeEngineInlineTests {
    typealias Write = NativeEngineThreadTests.Write

    /// Makes the calls of `NativeEngineThreadTests.play` as an inline host: the same steps, the
    /// same slices, the same input set after each `.frames` step, `around` before each step. At the
    /// end of the session it reports and ends the thread the program runs on.
    final class ScriptedHost: NativeEngineInlineHost, @unchecked Sendable {
        let slice: ((UInt64, UInt64) -> [UInt64])?
        let around: ((Int) -> Void)?
        let finished: (ScriptedHost) -> Void
        private var step = -1
        private var cuts: [UInt64] = []
        private var inputAfterCuts: InputState?
        private(set) var keyWaits: [Bool] = []
        private(set) var runCalls = 0
        private(set) var endReason: String?

        init(slice: ((UInt64, UInt64) -> [UInt64])? = nil, around: ((Int) -> Void)? = nil,
             finished: @escaping (ScriptedHost) -> Void) {
            self.slice = slice
            self.around = around
            self.finished = finished
        }

        func next(_ engine: NativeEngine, after previous: InlineRequest?, stoppedAtKeyWait: Bool) -> InlineRequest {
            switch previous {
            case .run: runCalls += 1
            case .runToKeyWait: keyWaits.append(stoppedAtKeyWait)
            case .skipDiskLoading, nil: break
            }
            let frame = VirtualClock.cyclesPerFrame
            while true {
                if !cuts.isEmpty { return .run(untilCycle: cuts.removeFirst()) }
                if let input = inputAfterCuts {
                    engine.input = input
                    inputAfterCuts = nil
                }
                step += 1
                guard step < NativeEngineThreadTests.session.count else { end() }
                around?(step)
                switch NativeEngineThreadTests.session[step] {
                case .keyWait(let maxFrames):
                    return .runToKeyWait(maxFrames: maxFrames, deliverFrames: true)
                case .frames(let n, let input):
                    let target = (engine.cycles / frame + n) * frame
                    cuts = slice?(engine.cycles, target) ?? [target]
                    inputAfterCuts = input
                }
            }
        }

        func programEnded(_ engine: NativeEngine, reason: String) -> Never {
            endReason = reason
            end()
        }

        /// Reports, then leaves the program's frames for good (as the threaded engine's program
        /// thread does when its engine goes away).
        private func end() -> Never {
            finished(self)
            Thread.exit()
            fatalError("Thread.exit returned")
        }
    }

    /// Runs `engine` inline with `host` on a thread with the program's stack size, until the host
    /// ends that thread.
    static func runInline(_ engine: NativeEngine, _ makeHost: (@escaping (ScriptedHost) -> Void) -> ScriptedHost)
        -> ScriptedHost {
        let done = DispatchSemaphore(value: 0)
        let host = makeHost { _ in done.signal() }
        nonisolated(unsafe) let unsafeEngine = engine
        nonisolated(unsafe) let unsafeHost = host
        let thread = Thread { unsafeEngine.runInline(unsafeHost) }
        thread.stackSize = ProgramThread.defaultStackSize
        thread.start()
        done.wait()
        return host
    }

    /// The thread test's session inline, with the same thousands of random slices and the same
    /// observers, against the threaded engine making one call per step: the same key-wait stops,
    /// frames, SID writes, memory, clock and I/O state.
    @Test func inlineMatchesThreadedSession() throws {
        let reference = try NativeEngineThreadTests.engine()
        var referenceFrames: [UInt64: [UInt8]] = [:], referenceWrites: [Write] = []
        let r = NativeEngineThreadTests.play(reference, around: { k in
            if k == 7 {
                reference.onFrame = { f in referenceFrames[f.frame] = f.pixels; referenceWrites += f.sidWrites }
            }
            if k == 10 { reference.onFrame = nil }
        })
        #expect(r.keyWaits == [true, true, true, true])

        let inline = NativeEngine(data: try #require(Original.data), modeLibrary: ModeLibrary.InMemoryStore().io,
                                  execution: .inline)
        var rng = TestRandom(seed: 0xD1B)
        var frames: [UInt64] = [], sameFrames = 0, iterations = 0, inlineWrites: [Write] = []
        let host = Self.runInline(inline) { finished in
            ScriptedHost(slice: { from, to in
                var cuts: [UInt64] = []
                var t = from
                while t < to {
                    t = min(to, t + 1 + rng.next() % 60_000)
                    cuts.append(t)
                }
                return cuts
            }, around: { k in
                if k == 7 {
                    inline.onFrame = { f in
                        frames.append(f.frame)
                        if referenceFrames[f.frame] == f.pixels { sameFrames += 1 }
                        inlineWrites += f.sidWrites
                    }
                }
                if k == 10 { inline.onFrame = nil }
                if k == 16 { inline.onIteration = { _ in iterations += 1 } }
            }, finished: finished)
        }
        #expect(host.endReason == nil, "the program ended: \(host.endReason ?? "")")
        #expect(host.keyWaits == r.keyWaits)
        #expect(host.runCalls > 2000, "\(host.runCalls) slices")
        #expect(frames.count == referenceFrames.count && frames.count == 216, "\(frames.count) frames")
        #expect(sameFrames == frames.count, "\(frames.count - sameFrames) frames differ from the reference's")
        #expect(iterations > 3, "\(iterations) main-loop tops in the demo")
        NativeEngineThreadTests.expectSame(reference, inline, writes: (referenceWrites, inlineWrites))
    }

    /// The quick boot inline (`skipDiskLoading`, then frame-by-frame runs as the app's host makes
    /// them) against the threaded engine: the same frames from the skip on.
    @Test func inlineSkipDiskLoadingMatchesThreaded() throws {
        let frame = VirtualClock.cyclesPerFrame
        let reference = try NativeEngineThreadTests.engine()
        var referenceFrames: [[UInt8]] = []
        reference.onFrame = { referenceFrames.append($0.pixels) }
        reference.skipDiskLoading()
        for _ in 0..<120 { reference.run(untilCycle: (reference.cycles / frame + 1) * frame) }

        let inline = NativeEngine(data: try #require(Original.data), modeLibrary: ModeLibrary.InMemoryStore().io,
                                  execution: .inline)
        var inlineFrames: [[UInt8]] = []
        inline.onFrame = { inlineFrames.append($0.pixels) }
        final class QuickBootHost: NativeEngineInlineHost, @unchecked Sendable {
            var runs = 0
            let finished: () -> Void
            init(finished: @escaping () -> Void) { self.finished = finished }
            func next(_ engine: NativeEngine, after previous: InlineRequest?, stoppedAtKeyWait: Bool) -> InlineRequest {
                if previous == nil { return .skipDiskLoading }
                if runs == 120 { finished(); Thread.exit(); fatalError("Thread.exit returned") }
                runs += 1
                return .run(untilCycle: (engine.cycles / VirtualClock.cyclesPerFrame + 1) * VirtualClock.cyclesPerFrame)
            }
            func programEnded(_ engine: NativeEngine, reason: String) -> Never { finished(); Thread.exit(); fatalError() }
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let unsafeInline = inline
        let host = QuickBootHost { done.signal() }
        nonisolated(unsafe) let unsafeHost = host
        let thread = Thread { unsafeInline.runInline(unsafeHost) }
        thread.stackSize = ProgramThread.defaultStackSize
        thread.start()
        done.wait()

        #expect(inlineFrames.count == referenceFrames.count && inlineFrames.count == 121, "\(inlineFrames.count) frames")
        #expect(inlineFrames == referenceFrames)
        NativeEngineThreadTests.expectSame(reference, inline, writes: ([], []))
    }
}
