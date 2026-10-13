import C64Kit
import FS2Core
@testable import FS2App
@testable import FS2Host
import Foundation
import Testing

@Suite struct SPSCRingTests {
    @Test func roundsCapacityAndKeepsOrder() {
        let ring = SPSCRing<UInt64>(capacity: 5)
        #expect(ring.capacity == 8)
        #expect(ring.pop() == nil && ring.peek() == nil)
        for i in 0..<8 { #expect(ring.push(UInt64(i))) }
        #expect(!ring.push(99), "a full ring refuses the push")
        #expect(ring.count == 8)
        #expect(ring.peek() == 0)
        for i in 0..<8 { #expect(ring.pop() == UInt64(i)) }
        #expect(ring.pop() == nil)
        // Wraps around many times.
        for i in 0..<1000 {
            #expect(ring.push(UInt64(i)))
            #expect(ring.pop() == UInt64(i))
        }
    }

    @Test func capacityOneRing() {
        let ring = SPSCRing<UInt8>(capacity: 1)
        #expect(ring.capacity == 1)
        for i in 0..<10 {
            #expect(ring.push(UInt8(i)) && !ring.push(99))
            #expect(ring.count == 1 && ring.peek() == UInt8(i))
            #expect(ring.pop() == UInt8(i) && ring.pop() == nil)
        }
    }

    /// One producer thread and one consumer thread hammer a small ring; every value must arrive
    /// exactly once, in order.
    @Test func concurrentProducerAndConsumer() async {
        let ring = SPSCRing<AudioEvent>(capacity: 64)
        let total = 400_000
        let producer = Thread {
            var i = 0
            while i < total {
                if ring.push(.write(UInt64(i), UInt8(i & 0x1F), UInt8(truncatingIfNeeded: i * 7))) { i += 1 }
            }
        }
        let result = await withCheckedContinuation { (done: CheckedContinuation<(Int, Bool), Never>) in
            let consumer = Thread {
                var expected = 0
                var ordered = true
                while expected < total {
                    guard let e = ring.pop() else { continue }
                    if e.cycle != UInt64(expected) || e.reg != UInt8(expected & 0x1F)
                        || e.value != UInt8(truncatingIfNeeded: expected * 7) || e.kind != .write {
                        ordered = false
                    }
                    expected += 1
                }
                done.resume(returning: (expected, ordered && ring.pop() == nil))
            }
            consumer.start()
            producer.start()
        }
        #expect(result.0 == total)
        #expect(result.1)
    }
}

@Suite struct SIDRendererTests {
    /// A sawtooth on voice 1 written through the feed is heard; muting silences it.
    @Test func rendersWritesFromTheFeed() {
        let feed = AudioFeed()
        feed.active.store(true, ordering: .relaxed)
        let r = SIDRenderer(sampleRate: 48_000, feed: feed)
        r.volume = 1
        let start: UInt64 = 1_000_000
        feed.reset(start)
        let writes: [(cycle: UInt64, reg: UInt8, value: UInt8)] = [
            (start, 0x18, 0x0F), (start, 0x05, 0x00), (start, 0x06, 0xF0),
            (start, 0x00, 0x00), (start, 0x01, 0x1C), (start + 10, 0x04, 0x21),
        ]
        feed.push(writes: writes)
        var samples = [Float](repeating: 0, count: 4800)
        // Announce the engine two frames ahead so the chip starts right at the writes.
        feed.mark(start + SIDRenderer.latency)
        samples.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, count: $0.count) }
        #expect(samples.map(abs).max()! > 0.05)
        #expect(r.registers[0x01] == 0x1C && r.registers[0x04] == 0x21)

        r.muted.store(true, ordering: .relaxed)
        samples.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, count: $0.count) }
        #expect(samples.allSatisfy { $0 == 0 })
    }

    /// A big jump of the engine clock moves the chip's clock instead of rendering through the gap.
    @Test func jumpsOverGaps() {
        let feed = AudioFeed()
        feed.active.store(true, ordering: .relaxed)
        let r = SIDRenderer(sampleRate: 44_100, feed: feed)
        feed.mark(100_000)
        var samples = [Float](repeating: 0, count: 512)
        samples.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, count: $0.count) }
        let before = r.chipCycle
        #expect(before < 100_000 + 20_000)
        let far: UInt64 = 60_000_000
        feed.mark(far)
        samples.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, count: $0.count) }
        // One buffer of 512 samples is about 11,900 cycles; the chip must now sit near far − latency.
        #expect(r.chipCycle >= far - SIDRenderer.latency)
        #expect(r.chipCycle < far - SIDRenderer.latency + 20_000)
        // A cold reset to a smaller clock follows the new engine.
        feed.reset(5_000)
        samples.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, count: $0.count) }
        #expect(r.chipCycle < 50_000)
        #expect(r.registers.allSatisfy { $0 == 0 })
    }

    /// A burst bigger than the limit (a quick boot's writes in one frame) keeps only each register's
    /// last write, in the order those writes happened, with their timestamps.
    @Test func burstsKeepTheLastWritePerRegister() {
        let feed = AudioFeed()
        feed.active.store(true, ordering: .relaxed)
        var writes: [(cycle: UInt64, reg: UInt8, value: UInt8)] = []
        for i in 0..<(AudioFeed.burstLimit + 500) {
            writes.append((UInt64(i), UInt8(i % 7 == 0 ? 0x18 : i % 0x19), UInt8(truncatingIfNeeded: i)))
        }
        feed.push(writes: writes)
        var got: [AudioEvent] = []
        while let e = feed.ring.pop() { got.append(e) }
        var lastIndex: [UInt8: Int] = [:]
        for (i, w) in writes.enumerated() { lastIndex[w.reg] = i }
        let expected = lastIndex.values.sorted().map { AudioEvent.write(writes[$0].cycle, writes[$0].reg, writes[$0].value) }
        #expect(got == expected)
        // A normal frame passes through unchanged.
        feed.push(writes: Array(writes.prefix(10)))
        var small: [AudioEvent] = []
        while let e = feed.ring.pop() { small.append(e) }
        #expect(small == writes.prefix(10).map { AudioEvent.write($0.cycle, $0.reg, $0.value) })
    }

    /// More queued writes than the stream holds (the engine ran far ahead) never grow its queue:
    /// the overflow is applied at once and the chip ends with the last values written.
    @Test func streamOverflowAppliesWritesWithoutGrowing() {
        let feed = AudioFeed()
        feed.active.store(true, ordering: .relaxed)
        let r = SIDRenderer(sampleRate: 48_000, feed: feed)
        feed.reset(0)
        var samples = [Float](repeating: 0, count: 256)
        samples.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, count: $0.count) }
        // Three ring loads of writes, all timestamped in the future, drained between loads.
        var cycle: UInt64 = 10_000_000
        for round in 0..<3 {
            for i in 0..<(feed.ring.capacity - 1) {
                cycle += 1
                #expect(feed.ring.push(.write(cycle, UInt8(i % 0x19), UInt8(truncatingIfNeeded: i + round))))
            }
            samples.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, count: $0.count) }
            #expect(feed.ring.count == 0)
        }
        // Jump the engine past all of them: every write is applied, the last per register wins.
        feed.mark(cycle + SIDRenderer.latency + 1)
        samples.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, count: $0.count) }
        let n = feed.ring.capacity - 1
        for reg in 0..<0x19 {
            let lastI = stride(from: n - 1, through: 0, by: -1).first { $0 % 0x19 == reg }!
            #expect(r.registers[reg] == UInt8(truncatingIfNeeded: lastI + 2), "register \(reg)")
        }
    }

    @Test func inactiveFeedDropsEverything() {
        let feed = AudioFeed()
        feed.push(writes: [(1, 0x18, 0x0F)])
        feed.mark(5)
        #expect(feed.ring.count == 0)
    }
}

@Suite struct EngineSupportTests {
    @Test func restartSequenceHoldsRunStopThenRestore() {
        var seq = RestartSequencer()
        var user = InputState()
        user.keys.set(.a, pressed: true)
        #expect(seq.next(user: user) == user)
        seq.start()
        var inputs: [InputState] = []
        while seq.isActive { inputs.append(seq.next(user: user)) }
        #expect(inputs.count == RestartSequencer.totalFrames)
        // Everything released first (frees the held-key slots), then RUN/STOP alone.
        #expect(inputs.prefix(RestartSequencer.releaseFrames).allSatisfy { $0 == InputState() })
        let held = inputs.dropFirst(RestartSequencer.releaseFrames)
        #expect(held.allSatisfy { $0.keys.isPressed(.runStop) && !$0.keys.isPressed(.a) })
        #expect(held.filter(\.restore).count == 1 && inputs.last!.restore)
        #expect(held.count >= 8, "RUN/STOP must be seen by at least two 4-frame matrix scans")
        #expect(seq.next(user: user) == user)
    }

    /// The native engine by default; `FS2_ENGINE` and `--engine` (which wins) pick either.
    @Test func engineResolution() throws {
        #expect(try EngineFactory.resolve(requested: nil, environment: [:]) == .native)
        #expect(try EngineFactory.resolve(requested: nil, environment: ["FS2_ENGINE": ""]) == .native)
        #expect(try EngineFactory.resolve(requested: nil, environment: ["FS2_ENGINE": "lab"]) == .lab)
        #expect(try EngineFactory.resolve(requested: "LAB", environment: ["FS2_ENGINE": "native"]) == .lab)
        #expect(try EngineFactory.resolve(requested: "native", environment: ["FS2_ENGINE": "lab"]) == .native)
        #expect(throws: EngineFactory.Error.self) { try EngineFactory.resolve(requested: "emulator", environment: [:]) }
    }

    @Test func frameExchangeHandsOverTheNewestFrame() {
        let x = FrameExchange()
        #expect(x.takeLatest() == nil)
        for n in 1...5 {
            x.publish(FrameOutput(pixels: [UInt8(n)], frame: UInt64(n), sidWrites: [], monochrome: n == 5))
        }
        let s = x.takeLatest()
        #expect(s?.frame == 5 && s?.pixels == [5] && s?.monochrome == true)
        #expect(x.takeLatest() == nil)
        x.publish(FrameOutput(pixels: [6], frame: 6, sidWrites: [], monochrome: false))
        #expect(x.takeLatest()?.frame == 6)
    }

    @Test func headlessOptions() throws {
        let o = try HeadlessCommand.parse(["--headless", "--engine", "lab", "--session", "@a.txt",
                                           "--screenshot-dir", "out", "--scale", "2x2"])
        #expect(o.engine == "lab" && o.session == "@a.txt" && o.screenshotDirectory == "out")
        #expect(o.scaleX == 2 && o.scaleY == 2)
        #expect(throws: HeadlessCommand.UsageError.self) { try HeadlessCommand.parse(["--headless"]) }
        #expect(throws: HeadlessCommand.UsageError.self) {
            try HeadlessCommand.parse(["--headless", "--session", "x", "--bogus"])
        }
        #expect(try HeadlessCommand.sessionText("wait:10 shot:a") == "wait:10 shot:a")
        let native = try HeadlessCommand.parse(["--headless", "--engine", "native", "--session", "x", "--smooth",
                                                "--strict-joystick", "--mode-library", "lib.bin", "--quick-boot"])
        #expect(native.engineOptions == EngineOptions(pacing: .smooth, strictJoystick: true))
        #expect(native.modeLibrary == "lib.bin" && native.quickBoot)
        #expect(try HeadlessCommand.parse(["--session", "x"]).engineOptions == EngineOptions())
    }
}
