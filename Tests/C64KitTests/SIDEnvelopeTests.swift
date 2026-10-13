#if DEBUG
@testable import C64Kit
#else
import C64Kit
#endif
import Testing

/// The ADSR envelope, checked through ENV3 ($D41C) against the 6581's documented behavior: the
/// attack times of the data sheet, the piecewise-exponential decay and release, the sustain
/// levels, gate edges, the rate counter that is never cleared, and the gating FS2's pattern
/// player does.
@Suite struct SIDEnvelopeTests {
    /// Data sheet attack times in ms for rates 0-15 (at 1 MHz); decay and release are 3x as long.
    private let dataSheetAttackMs: [Double] = [2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000]

    /// Rate-counter matches per decay/release step when leaving `level`: the divider switches as the
    /// level reaches 93, 54, 26, 14 and 6.
    private func matchesPerStep(leaving level: Int) -> Int {
        switch level {
        case 94...: 1
        case 55...93: 2
        case 27...54: 4
        case 15...26: 8
        case 7...14: 16
        default: 30
        }
    }

    /// The cycle (from now) at which each level first shows while ENV3 falls to 0.
    private func fallTimes(_ sid: SIDModel, limit: Int) -> [Int: Int] {
        var seen = [Int(sid.read(0x1C)): 0]
        var n = 0
        while sid.read(0x1C) != 0 && n < limit {
            sid.clock(cycles: 1)
            n += 1
            let level = Int(sid.read(0x1C))
            if seen[level] == nil { seen[level] = n }
        }
        return seen
    }

    @Test func attackTakes255EqualStepsAtTheDataSheetRates() {
        for rate in 0..<16 {
            let sid = SIDModel(sampleRate: 48_000)
            sid.write(0x13, UInt8(rate << 4))
            sid.write(0x14, 0xF0)                          // sustain 15 holds the peak
            sid.write(0x12, 0x01)
            // A fresh chip's rate counter starts at 0, so the first step takes exactly one period.
            guard let period = sid.cyclesUntilEnv3(is: 1, limit: 40_000) else {
                Issue.record("rate \(rate): no attack step")
                continue
            }
            sid.clock(cycles: 253 * period)
            #expect(sid.read(0x1C) == 254, "rate \(rate)")
            sid.clock(cycles: period - 1)
            #expect(sid.read(0x1C) == 254, "rate \(rate)")
            sid.clock(cycles: 1)
            #expect(sid.read(0x1C) == 255, "rate \(rate)")
            // 255 steps at 1 MHz against the data sheet: within 2.5%, except the shortest rate, which
            // the chip runs about 15% slow.
            let ms = Double(255 * period) / 1000
            let tolerance = rate == 0 ? 0.16 : 0.025
            #expect(abs(ms / dataSheetAttackMs[rate] - 1) < tolerance, "rate \(rate): \(ms) ms")
        }
    }

    @Test func decayStepsThroughTheExponentialDivider() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x13, 0x00)                              // attack and decay rate 0: 9 cycles
        sid.write(0x14, 0x00)                              // sustain 0
        sid.write(0x12, 0x01)
        #expect(sid.cyclesUntilEnv3(is: 255, limit: 3000) == 255 * 9)
        let times = fallTimes(sid, limit: 20_000)
        var expected = 0
        for level in stride(from: 254, through: 0, by: -1) {
            expected += 9 * matchesPerStep(leaving: level + 1)
            #expect(times[level] == expected, "level \(level)")
        }
        #expect(expected == 9 * 756)
    }

    @Test func releaseStepsThroughTheExponentialDivider() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x13, 0x00)
        sid.write(0x14, 0xF2)                              // sustain 15, release rate 2: 63 cycles
        sid.write(0x12, 0x01)
        sid.clock(cycles: 3000)
        #expect(sid.read(0x1C) == 255)
        sid.write(0x12, 0x00)
        // The first step waits for the free-running counter to reach the new period.
        let first = sid.cyclesUntilEnv3(is: 254, limit: 100)
        #expect(first != nil && (1...63).contains(first!))
        let times = fallTimes(sid, limit: 60_000)
        var expected = 0
        for level in stride(from: 253, through: 0, by: -1) {
            expected += 63 * matchesPerStep(leaving: level + 1)
            #expect(times[level] == expected, "level \(level)")
        }
    }

    @Test func releaseLastsAboutThreeTimesTheAttack() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x13, 0x40)                              // attack rate 4
        sid.write(0x14, 0xF4)                              // release rate 4
        sid.write(0x12, 0x01)
        guard let attack = sid.cyclesUntilEnv3(is: 255, limit: 100_000) else {
            Issue.record("no attack")
            return
        }
        sid.write(0x12, 0x00)
        guard let release = sid.cyclesUntilEnv3(is: 0, limit: 300_000) else {
            Issue.record("no release")
            return
        }
        let ratio = Double(release) / Double(attack)
        #expect(ratio > 2.9 && ratio < 3.0, "release / attack = \(ratio)")
    }

    @Test func sustainLevelIsTheNibbleTimes0x11() {
        for sustain in 0..<16 {
            let sid = SIDModel(sampleRate: 48_000)
            sid.write(0x13, 0x00)
            sid.write(0x14, UInt8(sustain << 4))
            sid.write(0x12, 0x01)
            sid.clock(cycles: 12_000)
            #expect(Int(sid.read(0x1C)) == sustain * 0x11, "sustain \(sustain)")
        }
    }

    @Test func loweringTheSustainLevelResumesTheDecay() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x13, 0x00)
        sid.write(0x14, 0xA0)
        sid.write(0x12, 0x01)
        sid.clock(cycles: 12_000)
        #expect(sid.read(0x1C) == 0xAA)
        sid.write(0x14, 0x50)
        sid.clock(cycles: 12_000)
        #expect(sid.read(0x1C) == 0x55)
    }

    @Test func zeroHoldsUntilTheNextGateOn() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x13, 0x00)
        sid.write(0x14, 0xF0)
        sid.write(0x12, 0x01)
        sid.clock(cycles: 3000)
        sid.write(0x12, 0x00)
        #expect(sid.cyclesUntilEnv3(is: 0, limit: 10_000) != nil)
        sid.clock(cycles: 200_000)
        #expect(sid.read(0x1C) == 0)
        sid.write(0x12, 0x01)
        sid.clock(cycles: 100)
        #expect(sid.read(0x1C) > 0)
    }

    @Test func onlyGateEdgesRestartTheEnvelope() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x13, 0x00)
        sid.write(0x14, 0x80)
        sid.write(0x12, 0x21)
        sid.clock(cycles: 10_000)
        #expect(sid.read(0x1C) == 0x88)
        sid.write(0x12, 0x21)                              // the same value again: gate still on
        sid.clock(cycles: 3000)
        #expect(sid.read(0x1C) == 0x88)
        sid.write(0x12, 0x81)                              // another waveform, gate still on
        sid.clock(cycles: 3000)
        #expect(sid.read(0x1C) == 0x88)
        sid.write(0x12, 0x80)                              // off then on: a new attack
        sid.write(0x12, 0x81)
        sid.clock(cycles: 100)
        #expect(sid.read(0x1C) > 0x88)
    }

    @Test func rateCounterWrapsWhenThePeriodDropsBelowIt() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x13, 0xF0)                              // attack rate 15: 31,251 cycles per step
        sid.write(0x12, 0x01)
        sid.clock(cycles: 20_000)
        #expect(sid.read(0x1C) == 0)
        sid.write(0x13, 0x00)                              // period 9, but the counter is at 20,000
        // It runs on through the rest of its 32,767-state cycle and then up to 9.
        #expect(sid.cyclesUntilEnv3(is: 1, limit: 40_000) == 32_767 - 20_000 + 9)

        // A counter still below the new period simply continues.
        let early = SIDModel(sampleRate: 48_000)
        early.write(0x13, 0xF0)
        early.write(0x12, 0x01)
        early.clock(cycles: 5)
        early.write(0x13, 0x00)
        #expect(early.cyclesUntilEnv3(is: 1, limit: 100) == 4)
    }

    @Test func firstAttackStepComesWithinOnePeriodOfTheGate() {
        var rng = TestRandom(state: 0x5EED_1234_ABCD_0042)
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x13, 0x00)
        sid.write(0x14, 0x00)                              // release rate 0 keeps the counter below 9
        for _ in 0..<200 {
            sid.write(0x12, 0x00)
            sid.clock(cycles: 3000 + rng.next(500))        // released to 0 by now
            #expect(sid.read(0x1C) == 0)
            sid.write(0x12, 0x01)
            let first = sid.cyclesUntilEnv3(is: 1, limit: 20)
            #expect(first != nil && (1...9).contains(first!))
        }
    }

    /// FS2's pattern player writes voice 3's control once per step: the effect's control value for a 1
    /// bit of the rhythm, $00 for a 0 bit. Each 1 after a 0 is a gate-on edge (a fresh attack), each 0
    /// a release. Played here for the gun (noise, AD $00, SR $90, pattern $55, 2 frames per step)
    /// and the inner marker (sawtooth, AD $20, SR $62, pattern $55, 5 frames per step).
    @Test func patternPlayerGatingShapesEachBurst() {
        let effects: [(control: UInt8, ad: UInt8, sr: UInt8, frames: Int)] = [(0x81, 0x00, 0x90, 2), (0x21, 0x20, 0x62, 5)]
        for effect in effects {
            let sid = SIDModel(sampleRate: 48_000)
            sid.setFrequency(voice: 2, effect.control == 0x81 ? 0x1770 : 0xC037)
            sid.write(0x13, effect.ad)
            sid.write(0x14, effect.sr)
            sid.write(0x18, 0x0F)
            let segment = effect.frames * ntscCyclesPerFrame
            let sustain = (effect.sr >> 4) * 0x11
            let attackPeriod = [9, 32, 63][Int(effect.ad >> 4)]
            var loud: [Double] = [], quiet: [Double] = []
            var buffer = [Float](repeating: 0, count: 48_000)
            for step in 0..<16 {
                let gateOn = (0x55 >> (step % 8)) & 1 != 0
                sid.write(0x12, gateOn ? effect.control : 0x00)
                var done = 0
                if gateOn {
                    // A full attack: 255 steps, the first within one period of the edge.
                    guard let peak = sid.cyclesUntilEnv3(is: 0xFF, limit: 256 * attackPeriod) else {
                        Issue.record("step \(step): no attack")
                        break
                    }
                    #expect(peak > 254 * attackPeriod, "step \(step)")
                    done = peak
                }
                // The rest of the step, keeping the samples of its second half.
                let firstHalf = max(0, segment / 2 - done)
                sid.clock(cycles: firstHalf)
                let r = buffer.withUnsafeMutableBufferPointer {
                    sid.run(cycles: segment - done - firstHalf, into: $0.baseAddress!, maxSamples: $0.count)
                }
                let level = acLevel(buffer[0..<r.samples])
                if gateOn {
                    #expect(sid.read(0x1C) == sustain, "step \(step)")
                    loud.append(level)
                } else {
                    #expect(sid.read(0x1C) == 0, "step \(step)")
                    quiet.append(level)
                }
            }
            print("Pattern gating, control $\(String(effect.control, radix: 16)): gate-on level \(loud.min()!), gate-off level \(quiet.max()!)")
            #expect(loud.min()! > 8 * quiet.max()!, "loud \(loud.min()!) quiet \(quiet.max()!)")
        }
    }
}
