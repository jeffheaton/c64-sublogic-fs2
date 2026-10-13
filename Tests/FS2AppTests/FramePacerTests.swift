import FS2Core
@testable import FS2App
import Testing

/// The engine thread's wall-clock pacing, on a simulated clock.
@Suite struct FramePacerTests {
    static let cpf = VirtualClock.cyclesPerFrame
    /// One frame of wall time in nanoseconds (about 16.7 ms).
    static let frameNanoseconds = UInt64((Double(cpf) / VirtualClock.hz * 1e9).rounded())

    /// A simulated engine: `run` advances the clock by the frame's cost and the cycles to the boundary
    /// (overshooting it a little, like an instruction that crosses it).
    struct Simulation {
        var pacer: FramePacer
        var now: UInt64 = 1_000_000_000
        var cycles: UInt64 = 0
        var framesRun = 0
        var sleeps = 0
        var maxLag: UInt64 = 0

        init() { pacer = FramePacer(now: now, cycles: 0) }

        mutating func step(frameCost: UInt64, overshoot: UInt64 = 3) {
            switch pacer.next(now: now, cycles: cycles) {
            case .run(let boundary):
                #expect(boundary > cycles && boundary % FramePacerTests.cpf == 0)
                #expect(boundary - cycles <= FramePacerTests.cpf, "never more than one frame per slice")
                cycles = boundary + overshoot
                now += frameCost
                framesRun += 1
            case .sleep(let ns):
                #expect(ns > 0 && ns <= FramePacerTests.frameNanoseconds + 1)
                now += ns
                sleeps += 1
            }
            let target = pacer.target(now: now)
            if target > cycles { maxLag = max(maxLag, target - cycles) }
        }
    }

    @Test func fastEngineRunsAtTheNTSCRate() {
        var s = Simulation()
        let end = s.now + 10_000_000_000                 // 10 simulated seconds
        while s.now < end { s.step(frameCost: 2_000_000) }
        // 59.826 frames per second.
        #expect(abs(s.framesRun - 598) <= 1, "frames in 10 s: \(s.framesRun)")
        #expect(s.sleeps >= s.framesRun - 1, "a fast engine sleeps between frames")
    }

    @Test func slowEngineRunsFlatOutWithABoundedBacklog() {
        for cost in [2 * Self.frameNanoseconds, 3 * Self.frameNanoseconds, 25 * Self.frameNanoseconds] {
            var s = Simulation()
            s.step(frameCost: cost)                      // waits for the first frame to come due
            #expect(s.sleeps == 1 && s.framesRun == 0)
            for _ in 0..<500 { s.step(frameCost: cost) }
            #expect(s.sleeps == 1, "an engine slower than real time never sleeps (cost \(cost) ns)")
            #expect(s.framesRun == 500)
            #expect(s.maxLag <= FramePacer.maxBacklog + UInt64(Double(cost) * VirtualClock.hz / 1e9) + 1,
                    "the debt stays capped (cost \(cost) ns, lag \(s.maxLag))")
        }
    }

    @Test func aStallIsCaughtUpByAtMostTheBacklog() {
        var s = Simulation()
        for _ in 0..<120 { s.step(frameCost: 1_000_000) }
        s.now += 5_000_000_000                           // the machine slept for 5 s
        let before = s.framesRun
        // At the same instant, the engine may run only the capped backlog before it has to wait.
        var burst = 0
        while case .run = s.pacer.next(now: s.now, cycles: s.cycles) {
            s.step(frameCost: 0)
            burst += 1
            if burst > 100 { break }
        }
        let backlogFrames = Int(FramePacer.maxBacklog / Self.cpf)
        #expect((backlogFrames...(backlogFrames + 1)).contains(burst), "catch-up burst: \(burst) frames")
        #expect(s.framesRun - before == burst)
        // Then it is back on the wall clock.
        let resumed = s.framesRun
        let end = s.now + 1_000_000_000
        while s.now < end { s.step(frameCost: 1_000_000) }
        #expect(abs(s.framesRun - resumed - 60) <= 1)
    }

    @Test func rebaseForgetsTheBacklog() {
        var pacer = FramePacer(now: 0, cycles: 0)
        pacer.rebase(now: 7_000_000_000, cycles: 123 * Self.cpf + 40)
        #expect(pacer.target(now: 7_000_000_000) == 123 * Self.cpf + 40)
        // Right after a rebase nothing is due: the next frame comes one frame period later.
        guard case .sleep(let ns) = pacer.next(now: 7_000_000_000, cycles: 123 * Self.cpf + 40) else {
            Issue.record("a rebased pacer must not run immediately")
            return
        }
        #expect(ns < Self.frameNanoseconds)
        #expect(pacer.next(now: 7_000_000_000 + ns, cycles: 123 * Self.cpf + 40) == .run(untilCycle: 124 * Self.cpf))
    }
}
