import C64Kit
import Darwin
import FS2Core
import FS2Data
@testable import FS2App
import FS2LabKit
import Foundation
import Testing

/// Release-build performance numbers for the final pass (opt-in, `FS2_PERF=1`; meaningful only in
/// a release build):
///
///     FS2_PERF=1 swift test -c release -Xswiftc -enable-testing --build-path .build-reltest \
///         --filter PerformanceProbeTests
///
/// Run it alone: the CPU times are the whole process's (`getrusage`), and suites that swift test
/// runs alongside (`PacingTests` with `FS2_PACING=1`, say) inflate them, down to a negative
/// re-render cost.
///
/// - the native engine at Authentic pacing: CPU time per emulated second, with and without a
///   presented frame per display frame;
/// - Smooth pacing: the extra cost of the window re-render per display frame (the same flight
///   in both pacings) and the slowest display frames, against the 16.6 ms of a 60 Hz frame;
/// - audio: `SIDRenderer` rendering the flight's SID writes at 48 kHz, per second of audio and
///   per 512-sample callback.
@Suite(.enabled(if: TestDisk.data != nil && ProcessInfo.processInfo.environment["FS2_PERF"] != nil,
                "FS2_PERF=1 and the disk image"), .serialized)
struct PerformanceProbeTests {
    /// The flight measured: take-off from Meigs and a climbing turn over Chicago (scenery streams,
    /// the window changes every pass).
    static let setup = "key:A:12 wait:60 key:B:12 wait:900 key:;:150 wait:540 key:B:6 wait:20 key:B:6 wait:20"
    static let flight = "key:B:6 wait:600 key:H:6 wait:20 key:H:6 wait:600 key:G:6 wait:2340"
    static let flightFrames = 3600.0

    /// The process's CPU time (user + system), seconds.
    static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    struct Run {
        var wall: Double
        var cpu: Double
        /// Wall time of every display frame (the `run` call that delivers it).
        var frameTimes: [Double]
        var smoothFrames: UInt64
        var sidWrites: [(cycle: UInt64, reg: UInt8, value: UInt8)]
        var frameEnds: [UInt64]
    }

    /// Plays the setup, then measures the flight frame by frame.
    static func fly(pacing: Pacing, present: Bool = true) throws -> Run {
        let engine = NativeEngine(data: try #require(TestDisk.data), options: EngineOptions(pacing: pacing),
                                  modeLibrary: ModeLibrary.InMemoryStore().io)
        let runner = HeadlessRunner(engine: engine)
        try runner.quickBoot()
        try runner.play(try Session.parse(setup), screenshots: nil)
        var writes: [(cycle: UInt64, reg: UInt8, value: UInt8)] = []
        var ends: [UInt64] = []
        // The flight's inputs, frame by frame, as the headless runner would apply them.
        var inputs: [InputState] = []
        for step in try Session.parse(flight).steps {
            switch step {
            case .wait(let n): inputs += Array(repeating: InputState(), count: n)
            case .press(let name, let n):
                var input = InputState()
                for k in try HeadlessRunner.keys(name) { input.keys.set(k, pressed: true) }
                inputs += Array(repeating: input, count: n)
            default: break
            }
        }
        engine.onFrame = present ? { frame in
            writes += frame.sidWrites
            ends.append(frame.frame)
        } : nil
        let smoothBefore = engine.smoothFrames
        var times: [Double] = []
        times.reserveCapacity(inputs.count)
        let cpf = VirtualClock.cyclesPerFrame
        let cpu0 = cpuTime()
        let wall0 = DispatchTime.now().uptimeNanoseconds
        for input in inputs {
            engine.input = input
            let t0 = DispatchTime.now().uptimeNanoseconds
            engine.run(untilCycle: (engine.cycles / cpf + 1) * cpf)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1e9
        return Run(wall: wall, cpu: cpuTime() - cpu0, frameTimes: times, smoothFrames: engine.smoothFrames - smoothBefore,
                   sidWrites: writes, frameEnds: ends)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let s = values.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    @Test func engineSmoothAndAudio() throws {
        let seconds = Self.flightFrames / VirtualClock.framesPerSecond
        let bare = try Self.fly(pacing: .authentic, present: false)
        let authentic = try Self.fly(pacing: .authentic)
        let smooth = try Self.fly(pacing: .smooth)
        print(String(format: "perf authentic, no frames: %.1f ms CPU per emulated second (wall %.2f s for %.1f s)",
                     bare.cpu / seconds * 1000, bare.wall, seconds))
        print(String(format: "perf authentic, frames presented: %.1f ms CPU per emulated second (wall %.2f s); "
                     + "per display frame mean %.3f ms, p99 %.3f ms, max %.3f ms",
                     authentic.cpu / seconds * 1000, authentic.wall,
                     authentic.frameTimes.reduce(0, +) / Self.flightFrames * 1000,
                     Self.percentile(authentic.frameTimes, 0.99) * 1000, authentic.frameTimes.max()! * 1000))
        // The same flight (Smooth changes nothing the program computes): the difference is the
        // re-render (CPU time, which other processes on the machine do not inflate).
        let extra = (smooth.cpu - authentic.cpu) / Double(max(smooth.smoothFrames, 1))
        let extraWall = (smooth.wall - authentic.wall) / Double(max(smooth.smoothFrames, 1))
        print(String(format: "perf smooth: %llu of %.0f frames redrawn; %.1f ms CPU per emulated second (wall %.2f s); "
                     + "re-render %.3f ms CPU (%.3f ms wall) per redrawn frame; per display frame mean %.3f ms, "
                     + "p99 %.3f ms, max %.3f ms",
                     smooth.smoothFrames, Self.flightFrames, smooth.cpu / seconds * 1000, smooth.wall, extra * 1000,
                     extraWall * 1000,
                     smooth.frameTimes.reduce(0, +) / Self.flightFrames * 1000,
                     Self.percentile(smooth.frameTimes, 0.99) * 1000, smooth.frameTimes.max()! * 1000))
        for (label, run) in [("authentic", authentic), ("smooth", smooth)] {
            let slowest = run.frameTimes.enumerated().sorted { $0.element > $1.element }.prefix(5)
            print("perf \(label) slowest display frames: " + slowest.map {
                String(format: "#%d %.2f ms", $0.offset, $0.element * 1000) }.joined(separator: ", "))
        }
        #expect(smooth.smoothFrames > UInt64(Self.flightFrames / 2), "Smooth redrew most frames")
        #expect(extra < 0.002, "the Smooth re-render costs \(extra * 1000) ms per frame")

        // Audio: the flight's SID writes through the app's renderer, frame by frame as the engine
        // loop feeds it, rendered in 512-sample callbacks at 48 kHz.
        let feed = AudioFeed()
        feed.active.store(true, ordering: .relaxed)
        let renderer = SIDRenderer(sampleRate: 48_000, feed: feed)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { buffer.deallocate() }
        var next = 0
        var rendered = 0, callbacks = 0
        var worst = 0.0
        let cpf = VirtualClock.cyclesPerFrame
        let samplesPerFrame = 48_000 / VirtualClock.framesPerSecond
        var owed = 0.0
        let t0 = DispatchTime.now().uptimeNanoseconds
        for frame in authentic.frameEnds {
            let end = frame * cpf
            var batch: [(cycle: UInt64, reg: UInt8, value: UInt8)] = []
            while next < authentic.sidWrites.count && authentic.sidWrites[next].cycle < end {
                batch.append(authentic.sidWrites[next]); next += 1
            }
            feed.push(writes: batch)
            feed.mark(end)
            owed += samplesPerFrame
            while owed >= 512 {
                let c0 = DispatchTime.now().uptimeNanoseconds
                renderer.render(into: buffer, count: 512)
                worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - c0) / 1e9)
                owed -= 512; rendered += 512; callbacks += 1
            }
        }
        let audioWall = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
        let audioSeconds = Double(rendered) / 48_000
        print(String(format: "perf audio: %.1f s of audio (%d SID writes) rendered in %.3f s: %.2f ms per audio second, "
                     + "%.1f µs per 512-sample callback (worst %.1f µs, budget %.0f µs)",
                     audioSeconds, authentic.sidWrites.count, audioWall, audioWall / audioSeconds * 1000,
                     audioWall / Double(callbacks) * 1e6, worst * 1e6, 512.0 / 48_000 * 1e6))
        #expect(audioWall / audioSeconds < 0.1, "audio rendering takes \(audioWall / audioSeconds * 100)% of real time")
    }
}
