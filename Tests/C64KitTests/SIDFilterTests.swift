#if DEBUG
@testable import C64Kit
#else
import C64Kit
#endif
import Foundation
import Testing

/// The multimode filter: a 12 dB/octave state-variable filter (data sheet) with low-, band- and
/// high-pass outputs, an 11-bit cutoff on a 6581-like curve and 4-bit resonance.
@Suite struct SIDFilterTests {
    private static let rate = 48_000.0

    /// The frequency register value closest to `hz`.
    private func register(for hz: Double) -> UInt16 {
        UInt16((hz * 16_777_216 / SIDModel.ntscClockHz).rounded())
    }

    /// Filtered / unfiltered amplitude of voice 1's fundamental (a triangle by default, nearly a sine).
    private func gain(at frequency: UInt16, fc: Int, resonance: Int = 0, mode: UInt8 = 0x10,
                      waveform: UInt8 = 0x10) -> Double {
        func amplitude(routed: Bool) -> Double {
            let sid = SIDModel(sampleRate: Self.rate)
            sid.setFrequency(voice: 0, frequency)
            sid.write(0x06, 0xF0)
            sid.write(0x15, UInt8(fc & 0x07))
            sid.write(0x16, UInt8(fc >> 3))
            sid.write(0x17, UInt8(resonance << 4) | (routed ? 0x01 : 0x00))
            sid.write(0x18, mode | 0x0F)
            sid.write(0x04, waveform | 0x01)
            let x = Array(sid.render(count: 9600 + 16_384).suffix(16_384))
            let hz = Double(frequency) * SIDModel.ntscClockHz / 16_777_216
            return toneAmplitude(x, at: hz, sampleRate: Self.rate)
        }
        return amplitude(routed: true) / amplitude(routed: false)
    }

    /// RMS of noise on voice 1 through the filter.
    private func noiseLevel(fc: Int, mode: UInt8) -> Double {
        let sid = SIDModel(sampleRate: Self.rate)
        sid.setFrequency(voice: 0, 0xFFFF)
        sid.write(0x06, 0xF0)
        sid.write(0x15, UInt8(fc & 0x07))
        sid.write(0x16, UInt8(fc >> 3))
        sid.write(0x17, 0x01)
        sid.write(0x18, mode | 0x0F)
        sid.write(0x04, 0x81)
        return acLevel(sid.render(count: 14_400)[4800...])
    }

    /// FC giving a cutoff closest to `hz`.
    private func fc(for hz: Double) -> Int {
        (0..<2048).min { abs(SIDModel.cutoffFrequency6581($0) - hz) < abs(SIDModel.cutoffFrequency6581($1) - hz) }!
    }

    @Test func cutoffCurveRisesSmoothlyFromAbout200Hz() {
        let f = (0..<2048).map { SIDModel.cutoffFrequency6581($0) }
        #expect(f[0] > 150 && f[0] < 300)
        #expect(f[2047] > 10_000 && f[2047] < 18_000)
        #expect(zip(f, f.dropFirst()).allSatisfy { $1 > $0 })
        // Nonlinear: flat at the bottom, steeper toward the top, with no jumps.
        #expect(f[256] - f[0] < 500)
        #expect(f[1024] < (f[0] + f[2047]) / 2)
        #expect(zip(f, f.dropFirst()).allSatisfy { $1 - $0 < 20 })
        #expect(SIDModel.cutoffFrequency6581(2048 + 5) == f[5])       // 11 bits
    }

    @Test func lowPassLevelRisesWithTheCutoff() {
        let levels = stride(from: 0, through: 2047, by: 256).map { noiseLevel(fc: $0, mode: 0x10) } + [noiseLevel(fc: 2047, mode: 0x10)]
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $1 > $0 }, "\(levels)")
    }

    @Test func highPassLevelFallsWithTheCutoff() {
        let levels = stride(from: 0, through: 2047, by: 256).map { noiseLevel(fc: $0, mode: 0x40) } + [noiseLevel(fc: 2047, mode: 0x40)]
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $1 < $0 }, "\(levels)")
    }

    @Test func lowPassRollsOffAt12dBPerOctave() {
        let cutoff = fc(for: 500)
        let hz = SIDModel.cutoffFrequency6581(cutoff)
        let pass = gain(at: register(for: hz / 5), fc: cutoff)
        let twice = gain(at: register(for: 2 * hz), fc: cutoff)
        let fourTimes = gain(at: register(for: 4 * hz), fc: cutoff)
        #expect(abs(pass - 1) < 0.02)
        let slope = 20 * log10(fourTimes / twice)
        #expect(slope > -13 && slope < -11, "\(slope) dB per octave")
    }

    @Test func highPassMirrorsTheLowPass() {
        let cutoff = fc(for: 500)
        let hz = SIDModel.cutoffFrequency6581(cutoff)
        #expect(abs(gain(at: register(for: 7 * hz), fc: cutoff, mode: 0x40) - 1) < 0.02)
        let slope = 20 * log10(gain(at: register(for: hz / 4), fc: cutoff, mode: 0x40)
                               / gain(at: register(for: hz / 2), fc: cutoff, mode: 0x40))
        #expect(slope > -13 && slope < -11, "\(slope) dB per octave")
    }

    @Test func lowPlusHighIsANotchAtTheCutoff() {
        let cutoff = fc(for: 1000)
        let hz = SIDModel.cutoffFrequency6581(cutoff)
        #expect(gain(at: register(for: hz), fc: cutoff, mode: 0x50) < 0.05)
        #expect(gain(at: register(for: hz / 6), fc: cutoff, mode: 0x50) > 0.9)
        #expect(gain(at: register(for: 3.5 * hz), fc: cutoff, mode: 0x50) > 0.85)
    }

    @Test func bandPassPeaksAtTheCutoff() {
        let cutoff = fc(for: 1000)
        let hz = SIDModel.cutoffFrequency6581(cutoff)
        let atCutoff = gain(at: register(for: hz), fc: cutoff, resonance: 8, mode: 0x20)
        #expect(atCutoff > 3 * gain(at: register(for: hz / 4), fc: cutoff, resonance: 8, mode: 0x20))
        #expect(atCutoff > 3 * gain(at: register(for: 3.9 * hz), fc: cutoff, resonance: 8, mode: 0x20))
    }

    @Test func resonanceRaisesTheResponseAtTheCutoff() {
        let cutoff = fc(for: 1000)
        let tone = register(for: SIDModel.cutoffFrequency6581(cutoff))
        let peaks = [0, 5, 10, 15].map { gain(at: tone, fc: cutoff, resonance: $0) }
        #expect(zip(peaks, peaks.dropFirst()).allSatisfy { $1 > $0 }, "\(peaks)")
        #expect(abs(peaks[0] - 0.707) < 0.05)                // no resonance: 3 dB down at the cutoff
        #expect(peaks[3] > 1.5 && peaks[3] < 2.2)             // a moderate peak, no self-oscillation
    }

    @Test func extremeSettingsStayBounded() {
        let sid = SIDModel(sampleRate: Self.rate)
        for v in 0..<3 {
            sid.setFrequency(voice: v, 0xFFFF)
            sid.write(v * 7 + 6, 0xF0)
        }
        sid.write(0x15, 0x07)
        sid.write(0x16, 0xFF)
        sid.write(0x17, 0xF7)
        sid.write(0x18, 0x7F)
        for v in 0..<3 { sid.write(v * 7 + 4, 0x81) }
        let s = sid.render(count: 48_000)
        #expect(s.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func fs2EngineCutoffDarkensHighTones() {
        // The engine drone runs through the low-pass at FC = $380 with resonance 8 (about 3.2 kHz
        // on this curve): a 100 Hz sawtooth keeps its sound, a 4 kHz one loses its harmonics.
        func levelRatio(_ frequency: UInt16, fc: Int) -> Double {
            func level(_ routed: Bool) -> Double {
                let sid = SIDModel(sampleRate: Self.rate)
                sid.setFrequency(voice: 0, frequency)
                sid.write(0x06, 0xF0)
                sid.write(0x16, UInt8(fc >> 3))
                sid.write(0x17, routed ? 0x81 : 0x80)
                sid.write(0x18, 0x1F)
                sid.write(0x04, 0x21)
                return acLevel(sid.render(count: 14_400)[4800...])
            }
            return level(true) / level(false)
        }
        let low = levelRatio(0x0668, fc: 0x380), high = levelRatio(0xFFFF, fc: 0x380)
        #expect(low > 0.9 && low < 1.25)
        #expect(high < 0.85 * low)
        // Far below the 4 kHz tone (FC = $100, under 500 Hz) it all but disappears.
        #expect(levelRatio(0xFFFF, fc: 0x100) < 0.05)
        #expect(levelRatio(0x0668, fc: 0x100) > 0.5)
    }
}
