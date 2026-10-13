#if DEBUG
@testable import C64Kit
#else
import C64Kit
#endif
import Foundation
import Testing

/// The oscillators, the mixer, the output path and the streaming API, checked against the 6581's
/// documented behavior (data sheet and well-known chip facts).
@Suite struct SIDModelTests {
    // MARK: Oscillators

    @Test func sawtoothPitchIsFrequencyTimesClockOver2To24() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 2, 0x1C32)
        sid.write(0x13, 0x00)
        sid.write(0x14, 0xF0)
        sid.write(0x18, 0x0F)
        sid.write(0x12, 0x21)
        let s = sid.render(count: 52_800)
        // The ramp crosses zero upward once per period; interpolate the crossings.
        var crossings: [Double] = []
        for i in 4800..<s.count where s[i - 1] < 0 && s[i] >= 0 {
            crossings.append(Double(i - 1) + Double(-s[i - 1] / (s[i] - s[i - 1])))
        }
        let measured = Double(crossings.count - 1) * 48_000 / (crossings.last! - crossings.first!)
        let expected = 0x1C32 * SIDModel.ntscClockHz / 16_777_216
        #expect(abs(measured - expected) < expected * 0.0005)
        #expect(abs(expected - 440) < 0.1)                 // $1C32 is concert A on an NTSC machine
    }

    @Test func waveformsAreReadOffTheAccumulator() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 2, 0x1000)
        sid.write(0x12, 0x20)                              // sawtooth: the top 12 bits
        sid.clock(cycles: 1000)                            // accumulator $3E8000
        #expect(sid.waveformOutput(voice: 2) == 0x3E8)
        #expect(sid.read(0x1B) == 0x3E)
        sid.write(0x12, 0x10)                              // triangle, bit 23 clear: bits 22-11
        #expect(sid.waveformOutput(voice: 2) == 0x7D0)
        sid.clock(cycles: 1500)                            // $9C4000: bit 23 set, the ramp inverted
        #expect(sid.waveformOutput(voice: 2) == UInt16(0xFFF ^ ((0x9C4000 >> 11) & 0xFFF)))
        sid.setPulseWidth(voice: 2, 0x800)
        sid.write(0x12, 0x40)                              // pulse: high while $9C4 >= the width
        #expect(sid.waveformOutput(voice: 2) == 0xFFF)
        sid.setPulseWidth(voice: 2, 0xA00)
        #expect(sid.waveformOutput(voice: 2) == 0x000)
        sid.setPulseWidth(voice: 2, 0x800)
        sid.write(0x12, 0x60)                              // two waveforms: their AND
        #expect(sid.waveformOutput(voice: 2) == 0x9C4)
        sid.write(0x12, 0x00)                              // none: the DAC keeps its last input
        sid.clock(cycles: 700)
        #expect(sid.waveformOutput(voice: 2) == 0x9C4)
        #expect(sid.read(0x1B) == 0x9C)
    }

    @Test func frequencyBytesAreIndependentLatches() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x0E, 0x34)
        sid.write(0x0F, 0x12)
        sid.write(0x0F, 0x56)                              // only the high byte changes: $5634
        sid.write(0x12, 0x20)
        sid.clock(cycles: 100)
        #expect(sid.waveformOutput(voice: 2) == UInt16(((100 * 0x5634) & 0xFF_FFFF) >> 12))
    }

    @Test func pulseDutyCycleFollowsTheWidth() {
        for width: UInt16 in [0x000, 0x200, 0x800, 0xC00, 0xFFF] {
            let sid = SIDModel(sampleRate: 48_000)
            sid.setFrequency(voice: 0, 0x1000)             // the top 12 bits count one per cycle
            sid.setPulseWidth(voice: 0, width)
            sid.write(0x04, 0x40)
            var high = 0
            for _ in 0..<4096 {
                sid.clock(cycles: 1)
                if sid.waveformOutput(voice: 0) == 0xFFF { high += 1 }
            }
            #expect(high == 4096 - Int(width), "width \(width)")
        }
    }

    @Test func triangleRisesAndFallsSymmetrically() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 1, 0x1000)
        sid.write(0x0B, 0x10)
        var values: [Int] = []
        for _ in 0..<4096 {
            values.append(Int(sid.waveformOutput(voice: 1)))
            sid.clock(cycles: 1)
        }
        let rising = values[0..<2048], falling = values[2048...]
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $1 - $0 == 2 })
        #expect(zip(falling, falling.dropFirst()).allSatisfy { $0 - $1 == 2 })
        #expect(values.min() == 0 && values.max() == 0xFFF)
        #expect(values[2048] == 0xFFF)
    }

    @Test func testBitHoldsTheAccumulatorAtZero() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 2, 0x4321)
        sid.write(0x12, 0x20)
        sid.clock(cycles: 333)
        #expect(sid.read(0x1B) != 0)
        sid.write(0x12, 0x28)
        sid.clock(cycles: 5000)
        #expect(sid.waveformOutput(voice: 2) == 0)
        sid.write(0x12, 0x48)                              // pulse is forced high under TEST
        #expect(sid.waveformOutput(voice: 2) == 0xFFF)
        sid.write(0x12, 0x20)
        sid.clock(cycles: 10)
        #expect(sid.waveformOutput(voice: 2) == UInt16((10 * 0x4321) >> 12))
    }

    @Test func hardSyncRestartsTheSyncedVoice() {
        for synced in [false, true] {
            let sid = SIDModel(sampleRate: 48_000)
            sid.setFrequency(voice: 1, 0x8000)             // voice 2's bit 23 rises at cycle 256
            sid.setFrequency(voice: 2, 0x1000)
            sid.write(0x12, synced ? 0x22 : 0x20)          // voice 3 syncs to voice 2
            sid.clock(cycles: 255)
            #expect(sid.read(0x1B) == 0x0F)
            sid.clock(cycles: 1)
            #expect(sid.read(0x1B) == (synced ? 0x00 : 0x10))
        }
    }

    @Test func ringModulationInvertsTheTriangleWithTheModulatorsTopBit() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 1, 0x8000)
        sid.setFrequency(voice: 2, 0x1000)
        sid.write(0x12, 0x10)
        sid.clock(cycles: 300)                             // voice 2 bit 23 set, voice 3 bit 23 clear
        let plain = sid.waveformOutput(voice: 2)
        #expect(plain == UInt16(((300 * 0x1000) >> 11) & 0xFFF))
        sid.write(0x12, 0x14)
        #expect(sid.waveformOutput(voice: 2) == plain ^ 0xFFF)
        sid.write(0x12, 0x24)                              // ring modulation affects only the triangle
        #expect(sid.waveformOutput(voice: 2) == UInt16((300 * 0x1000) >> 12))
    }

    // MARK: Noise

    /// The 6581's noise source as documented: a 23-bit shift register with feedback from bits 22
    /// and 17, whose bits 22, 20, 16, 13, 11, 7, 4 and 2 are the top eight waveform bits.
    private struct NoiseRegister {
        var bits: UInt32 = 0x7F_FFFF

        mutating func shift() { bits = (bits << 1 | (bits >> 22 ^ bits >> 17) & 1) & 0x7F_FFFF }

        var osc3: UInt8 {
            [22, 20, 16, 13, 11, 7, 4, 2].reduce(0) { $0 << 1 | UInt8(bits >> UInt32($1) & 1) }
        }
    }

    @Test func noiseShiftsOnRisingEdgesOfAccumulatorBit19() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 2, 0x8000)                 // bit 19 rises at cycle 16, then every 32
        sid.write(0x12, 0x88)                              // TEST fills the register with ones
        #expect(sid.read(0x1B) == 0xFF)
        sid.write(0x12, 0x80)
        var reference = NoiseRegister()
        for step in 0..<400 {
            sid.clock(cycles: step == 0 ? 15 : 31)
            #expect(sid.read(0x1B) == reference.osc3, "before shift \(step)")
            sid.clock(cycles: 1)
            reference.shift()
            #expect(sid.read(0x1B) == reference.osc3, "after shift \(step)")
        }
    }

    /// The output bits are taps of one shift register: each reappears a fixed number of shifts later
    /// at the next tap up, and the new bit is bit 22 exclusive-or bit 17 (seen at bit 20 three
    /// shifts later). Checked on the outputs alone, without a reference register.
    @Test func noiseOutputIsTheShiftRegistersTaps() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 2, 0x8000)
        sid.write(0x12, 0x80)
        sid.clock(cycles: 16)
        var o: [UInt8] = []
        for _ in 0..<5000 {
            o.append(sid.read(0x1B))
            sid.clock(cycles: 32)
        }
        func bit(_ n: Int, _ b: Int) -> UInt8 { o[n] >> UInt8(b) & 1 }
        // (output bit, its register bit) for consecutive taps; the gap is the number of shifts.
        let taps = [(7, 22), (6, 20), (5, 16), (4, 13), (3, 11), (2, 7), (1, 4), (0, 2)]
        for n in 0..<(o.count - 4) {
            for i in 1..<taps.count {
                let gap = taps[i - 1].1 - taps[i].1
                #expect(bit(n + gap, taps[i - 1].0) == bit(n, taps[i].0))
            }
            // Register bit 0 after shift n is bit 22 ^ bit 17 before it; it shows at bit 2 two shifts
            // later, and bit 17 shows at bit 20 three shifts later.
            if n + 3 < o.count { #expect(bit(n + 3, 0) == bit(n, 7) ^ bit(n + 3, 6)) }
        }
        // A maximal-length sequence looks random: balanced bits, nearly every byte value.
        for b in 0..<8 {
            let ones = o.reduce(0) { $0 + Int($1 >> UInt8(b) & 1) }
            #expect(abs(Double(ones) / Double(o.count) - 0.5) < 0.03, "bit \(b)")
        }
        #expect(Set(o).count > 250)
    }

    // MARK: Mixer and output

    @Test func fullScaleSawHasTheDocumentedOutputLevel() {
        // One voice at full envelope and volume 15 spans 1/3 of the +/-0.5 three-voice range; a
        // sawtooth of peak A has a fundamental of 2A/pi.
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 0, 0x8000)                 // clock / 512, about 1998 Hz
        sid.write(0x05, 0x00)
        sid.write(0x06, 0xF0)
        sid.write(0x18, 0x0F)
        sid.write(0x04, 0x21)
        let x = Array(sid.render(count: 12_000 + 8192).suffix(8192))
        let fundamental = toneAmplitude(x, at: SIDModel.ntscClockHz / 512, sampleRate: 48_000)
        #expect(abs(fundamental - 2 / Double.pi * 0.5 / 3) < 0.002)
    }

    @Test func masterVolumeScalesTheOutputLinearly() {
        func level(_ volume: UInt8) -> Double {
            let sid = SIDModel(sampleRate: 48_000)
            sid.setFrequency(voice: 0, 0x1000)
            sid.write(0x06, 0xF0)
            sid.write(0x18, volume)
            sid.write(0x04, 0x21)
            return acLevel(sid.render(count: 14_400)[4800...])
        }
        #expect(abs(level(15) / level(5) - 3) < 0.01)
        #expect(level(0) == 0)
    }

    @Test func voice3OffMutesOnlyTheDirectPath() {
        func level(routing: UInt8, modeVolume: UInt8) -> Double {
            let sid = SIDModel(sampleRate: 48_000)
            sid.setFrequency(voice: 2, 0x0800)
            sid.write(0x14, 0xF0)
            sid.write(0x16, 0xFF)
            sid.write(0x17, routing)
            sid.write(0x18, modeVolume)
            sid.write(0x12, 0x21)
            return acLevel(sid.render(count: 9600)[4800...])
        }
        #expect(level(routing: 0x00, modeVolume: 0x0F) > 0.05)
        #expect(level(routing: 0x00, modeVolume: 0x8F) == 0)
        #expect(level(routing: 0x04, modeVolume: 0x9F) > 0.05)   // routed through the low-pass
        #expect(level(routing: 0x04, modeVolume: 0x0F) == 0)     // routed, but no filter mode selected
    }

    @Test func volumeWritesAreSilentInTheCenteredMixer() {
        let sid = SIDModel(sampleRate: 48_000)
        _ = sid.render(count: 4800)
        sid.write(0x18, 0x0F)
        #expect(sid.render(count: 4800).allSatisfy { $0 == 0 })
    }

    @Test func chipOffsetsMakeVolumeWritesClick() {
        // The 6581's mixer carries a DC level that the volume DAC scales, so a volume write is a step
        // (the basis of "volume register" sample playback); the board's coupling capacitor then
        // drains it within a fraction of a second.
        let sid = SIDModel(sampleRate: 48_000)
        sid.authenticDCOffsets = true
        _ = sid.render(count: 4800)
        sid.write(0x18, 0x0F)
        let step = sid.render(count: 48_000)
        #expect(step.prefix(48).map { abs($0) }.max()! > 0.1)
        #expect(step.suffix(4800).map { abs($0) }.max()! < 0.001)
    }

    @Test func gameEngineDroneRendersCleanly() {
        // FS2's idle sound (two sawtooth voices an octave apart near 23 Hz through the low-pass at
        // FC = $380, resonance 8, volume 11), plus noise on voice 3 as an effect would add.
        let sid = SIDModel(sampleRate: 44_100)
        sid.setFrequency(voice: 0, 368)
        sid.setFrequency(voice: 1, 737)
        sid.setFrequency(voice: 2, 0x2000)
        for v in 0..<3 { sid.write(v * 7 + 6, 0xB2) }
        sid.write(0x16, 0x70)
        sid.write(0x17, 0x83)
        sid.write(0x18, 0x1B)
        sid.write(0x04, 0x21)
        sid.write(0x0B, 0x21)
        sid.write(0x12, 0x81)
        let s = sid.render(count: 88_200)
        #expect(s.allSatisfy { $0.isFinite })
        #expect(s.map { abs($0) }.max()! < 0.9)
        #expect(acLevel(s[44_100...]) > 0.05)
    }

    @Test func writeOnlyRegistersReadTheFadingBusValue() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.write(0x05, 0x5A)
        #expect(sid.read(0x05) == 0x5A)
        #expect(sid.read(0x18) == 0x5A)                    // the bus, not the register
        #expect(sid.read(0x19) == 0xFF && sid.read(0x1A) == 0xFF)
        sid.clock(cycles: 0x1FFF)
        #expect(sid.read(0x05) == 0x5A)
        sid.clock(cycles: 1)
        #expect(sid.read(0x05) == 0)
        sid.write(0x3F, 0x77)                              // mirrored every 32 bytes; read-only target
        #expect(sid.read(0x1F) == 0x77)
    }

    @Test func resetSilencesTheChipButKeepsTheClock() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 0, 0x2000)
        sid.write(0x06, 0xF0)
        sid.write(0x18, 0x0F)
        sid.write(0x04, 0x21)
        _ = sid.render(count: 4800)
        let before = sid.cycle
        sid.reset()
        #expect(sid.cycle == before)
        #expect(sid.envelopeLevel(voice: 0) == 0 && sid.waveformOutput(voice: 0) == 0)
        let after = sid.render(count: 9600)
        #expect(after.suffix(2400).map { abs($0) }.max()! < 1e-4)
    }

    // MARK: Resampling

    @Test func resamplerKeepsAliasesBelowMinus90dB() {
        // A sawtooth with a period of exactly 512 cycles has harmonics only at multiples of
        // clock / 512. Energy anywhere else below 19 kHz was folded in by the rate conversion.
        for rate in [44_100.0, 48_000.0] {
            let sid = SIDModel(sampleRate: rate)
            sid.setFrequency(voice: 0, 0x8000)
            sid.write(0x06, 0xF0)
            sid.write(0x18, 0x0F)
            sid.write(0x04, 0x21)
            let x = Array(sid.render(count: Int(rate / 4) + 8192).suffix(8192))
            let f0 = SIDModel.ntscClockHz / 512
            let fundamental = toneAmplitude(x, at: f0, sampleRate: rate)
            var worst = -300.0
            for k in 10...150 {
                var alias = (Double(k) * f0).truncatingRemainder(dividingBy: rate)
                if alias > rate / 2 { alias = rate - alias }
                // Skip folds that land on (or right next to) a real harmonic, or above 19 kHz.
                guard alias < 19_000, abs(alias - (alias / f0).rounded() * f0) > 40 else { continue }
                worst = max(worst, 20 * log10(toneAmplitude(x, at: alias, sampleRate: rate) / fundamental))
            }
            print("Resampler at \(Int(rate)) Hz: worst alias \(worst) dB")
            #expect(worst < -90, "worst alias \(worst) dB at \(rate) Hz")
        }
    }

    @Test func outputClockTracksTheChipClock() {
        for rate in [22_050.0, 44_100.0, 48_000.0, 96_000.0, 192_000.0] {
            let sid = SIDModel(sampleRate: rate)
            var total = 0
            for chunk in [1, 7, 512, 4096, Int(rate) * 5] {
                _ = sid.render(count: chunk)
                total += chunk
                // Sample n completes with the stage-1 sample (8 cycles) its instant falls in.
                let perSample = SIDModel.ntscClockHz / rate
                let error = Double(sid.cycle) - Double(total - 1) * perSample
                #expect(error >= 0 && error <= 16, "\(rate) Hz after \(total) samples: \(error)")
            }
        }
    }

    @Test func otherOutputRatesKeepLevelAndPitch() {
        for rate in [22_050.0, 96_000.0, 192_000.0] {
            let sid = SIDModel(sampleRate: rate)
            sid.setFrequency(voice: 0, 0x2000)             // about 500 Hz
            sid.write(0x06, 0xF0)
            sid.write(0x18, 0x0F)
            sid.write(0x04, 0x21)
            let x = Array(sid.render(count: Int(rate / 2)).suffix(Int(rate / 4)))
            #expect(x.allSatisfy { $0.isFinite && abs($0) <= 1 })
            let f0 = 0x2000 * SIDModel.ntscClockHz / 16_777_216
            #expect(abs(toneAmplitude(x, at: f0, sampleRate: rate) - 2 / Double.pi * 0.5 / 3) < 0.003, "\(rate) Hz")
        }
    }

    // MARK: Streaming

    @Test func renderSmoke() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 0, 0x1C32)
        sid.setFrequency(voice: 1, 0x0E19)
        sid.setFrequency(voice: 2, 0x4000)
        sid.setPulseWidth(voice: 0, 0x800)
        for v in 0..<3 {
            sid.write(v * 7 + 5, 0x09)
            sid.write(v * 7 + 6, 0xA4)
        }
        sid.write(0x17, 0xF7)
        sid.write(0x18, 0x3F)
        sid.write(0x04, 0x41)
        sid.write(0x0B, 0x21)
        sid.write(0x12, 0x81)
        let s = sid.render(count: 9600)
        #expect(s.count == 9600)
        #expect(s.allSatisfy { $0.isFinite && $0 >= -1 && $0 <= 1 })
        #expect(s.contains { $0 != 0 })
    }

    @Test func streamAppliesWritesAtExactCycles() {
        let writes: [(UInt64, Int, UInt8)] = [(0, 0x18, 0x0F), (0, 0x0E, 0x00), (0, 0x0F, 0x20), (0, 0x13, 0x00),
                                              (0, 0x14, 0xF4), (5003, 0x12, 0x21), (40_001, 0x0F, 0x31),
                                              (60_007, 0x12, 0x20), (60_007, 0x14, 0xF2)]
        // Reference: clock the chip to each write's cycle, then write.
        let direct = SIDModel(sampleRate: 44_100)
        var expected = [Float](repeating: 0, count: 4410)
        var produced = 0
        expected.withUnsafeMutableBufferPointer { buf in
            for (cycle, reg, value) in writes {
                let r = direct.run(cycles: Int(cycle - direct.cycle), into: buf.baseAddress! + produced,
                                   maxSamples: buf.count - produced)
                produced += r.samples
                #expect(direct.cycle == cycle)
                direct.write(reg, value)
            }
            direct.render(into: buf.baseAddress! + produced, count: buf.count - produced)
        }
        // The stream, rendered in uneven chunks, must give the same samples bit for bit.
        let stream = SIDStream(sid: SIDModel(sampleRate: 44_100))
        for (cycle, reg, value) in writes { stream.enqueue(cycle: cycle, reg: reg, value: value) }
        var got: [Float] = []
        for chunk in [1, 100, 509, 1000, 2800] { got += stream.render(count: chunk) }
        #expect(got == expected)
        #expect(stream.pendingCount == 0)
        #expect(stream.sid.read(0x1C) == direct.read(0x1C))

        let log = writes.map { SIDWrite(cycle: $0.0, reg: $0.1, value: $0.2) }
        let end = UInt64((4410 * SIDModel.ntscClockHz / 44_100).rounded())
        #expect(SIDStream.render(log: log, from: 0, to: end, sampleRate: 44_100) == expected)
    }

    @Test func wavWriterProduces16BitMonoPCM() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sid-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVWriter.write(samples: [0, 1, -1, 0.5, 2], sampleRate: 44_100, to: url)
        let d = [UInt8](try Data(contentsOf: url))
        func u32(_ o: Int) -> Int { (0..<4).reduce(0) { $0 | Int(d[o + $1]) << (8 * $1) } }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        #expect(d.count == 44 + 10)
        #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF")
        #expect(u32(4) == 36 + 10)
        #expect(String(decoding: d[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(u16(20) == 1 && u16(22) == 1 && u32(24) == 44_100 && u32(28) == 88_200)
        #expect(u16(32) == 2 && u16(34) == 16)
        #expect(String(decoding: d[36..<40], as: UTF8.self) == "data" && u32(40) == 10)
        let pcm = (0..<5).map { Int16(bitPattern: UInt16(u16(44 + 2 * $0))) }
        #expect(pcm == [0, 32767, -32767, 16384, 32767])
    }

    @Test func rendersFasterThanRealTime() {
        let sid = SIDModel(sampleRate: 48_000)
        sid.setFrequency(voice: 0, 384)
        sid.setFrequency(voice: 1, 768)
        sid.setFrequency(voice: 2, 0x2000)
        for v in 0..<3 {
            sid.write(v * 7 + 5, 0x00)
            sid.write(v * 7 + 6, 0xF0)
        }
        sid.write(0x16, 0x70)
        sid.write(0x17, 0x83)
        sid.write(0x18, 0x1F)
        sid.write(0x04, 0x21)
        sid.write(0x0B, 0x21)
        sid.write(0x12, 0x81)
        // Best of three runs, so other work on the machine (parallel builds) doesn't fail the test;
        // 10x real time still leaves the audio thread ample headroom.
        let seconds = 2
        var buffer = [Float](repeating: 0, count: 48_000 * seconds)
        var factor = 0.0
        for _ in 0..<3 {
            let elapsed = ContinuousClock().measure {
                buffer.withUnsafeMutableBufferPointer { sid.render(into: $0.baseAddress!, count: $0.count) }
            }
            let s = Double(elapsed.components.attoseconds) * 1e-18 + Double(elapsed.components.seconds)
            factor = max(factor, Double(seconds) / s)
        }
        print("SID renders at \(Int(factor))x real time (best of 3)")
        #if !DEBUG
        #expect(factor > 10)
        #endif
    }
}
