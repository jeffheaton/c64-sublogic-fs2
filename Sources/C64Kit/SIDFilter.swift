#if os(WASI)
import WASILibc
#else
import Foundation
#endif

/// The SID's multimode filter: a two-pole state-variable filter (two integrators in a feedback
/// loop) whose low-pass, band-pass and high-pass taps are summed according to the mode bits of
/// $D418, with the resonance nibble of $D417 setting the loop damping.
///
/// The loop is discretized with the trapezoidal rule in its zero-delay ("topology-preserving")
/// form, which keeps the analog tuning and stays stable at any cutoff. It runs at the chip clock,
/// so it sees the waveforms exactly as the chip produces them.
struct MultimodeFilter {
    /// Integrator states.
    private var band = 0.0, low = 0.0
    /// Per-cutoff coefficients and the damping 1/Q.
    private var a1 = 1.0, a2 = 0.0, a3 = 0.0, damping = 1.0
    /// How much of each tap reaches the output: 1 when its mode bit is set.
    var lowLevel = 0.0, bandLevel = 0.0, highLevel = 0.0

    /// Cutoff in Hz of a typical 6581 for an 11-bit FC value.
    ///
    /// The 6581 sets its cutoff with transistors used as voltage-controlled resistors, and the
    /// cutoff is far from linear in FC: it barely moves above a couple of hundred Hz for small
    /// values and rises steeply over the upper part of the range. This model gives that shape with
    /// a smooth square law in FC, from 200 Hz at FC = 0 to 16 kHz at FC = 2047; real chips scatter
    /// widely around such a curve.
    static func cutoff6581(_ fc: Int) -> Double {
        let x = Double(fc & 0x7FF) / 2047
        return 200 + 15_800 * x * x
    }

    /// Filter Q for the 4-bit resonance value: from 0.707 (no peak) at 0, rising by equal ratios
    /// to about 1.8 at 15, a gentle peak like the 6581's.
    static func quality(resonance: Int) -> Double {
        0.707 * pow(2.5, Double(resonance & 0x0F) / 15)
    }

    mutating func tune(cutoffHz: Double, quality: Double, clockHz: Double) {
        let g = tan(Double.pi * min(cutoffHz, 0.45 * clockHz) / clockHz)
        damping = 1 / quality
        a1 = 1 / (1 + g * (g + damping))
        a2 = g * a1
        a3 = g * a2
    }

    /// Clears the integrators.
    mutating func discharge() {
        band = 0
        low = 0
    }

    /// Sets integrator states that have decayed to nothing to exactly 0. Without input the loop
    /// would otherwise settle on subnormal values, which some CPUs process many times slower.
    @inline(__always)
    mutating func flushTinyStates() {
        if abs(band) < 1e-20 { band = 0 }
        if abs(low) < 1e-20 { low = 0 }
    }

    /// One cycle: filters `input` and returns the selected mix of the three taps.
    @inline(__always)
    mutating func process(_ input: Double) -> Double {
        let drive = input - low
        let bp = a1 * band + a2 * drive
        let lp = low + a2 * band + a3 * drive
        band = 2 * bp - band
        low = 2 * lp - low
        let hp = input - damping * bp - lp
        return lowLevel * lp + bandLevel * bp + highLevel * hp
    }
}

/// The C64 board's analog path from the SID's output pin to the audio jack: an RC low-pass at about
/// 16 kHz, applied at the chip clock, and the coupling capacitor's high-pass at about 16 Hz, applied
/// at the output rate (it removes DC, such as the step a volume write makes with the 6581's offsets).
struct BoardOutput {
    private let lowPassCoefficient: Double
    private let highPassPole: Double
    private var lowPassState = 0.0
    private var highPassIn = 0.0, highPassOut = 0.0

    init(clockHz: Double, sampleRate: Double) {
        lowPassCoefficient = 1 - exp(-2 * Double.pi * 16_000 / clockHz)
        highPassPole = exp(-2 * Double.pi * 16 / sampleRate)
    }

    @inline(__always)
    mutating func lowPass(_ x: Double) -> Double {
        lowPassState += lowPassCoefficient * (x - lowPassState)
        return lowPassState
    }

    @inline(__always)
    mutating func highPass(_ x: Double) -> Double {
        highPassOut = highPassPole * (highPassOut + x - highPassIn)
        highPassIn = x
        return highPassOut
    }

    /// As `MultimodeFilter.flushTinyStates()`, for the two one-pole stages.
    @inline(__always)
    mutating func flushTinyStates() {
        if abs(lowPassState) < 1e-30 { lowPassState = 0 }
        if abs(highPassOut) < 1e-30 { highPassOut = 0 }
    }
}

/// Converts the cycle-rate signal to the output rate in two stages.
///
/// 1. A linear-phase FIR keeps every 8th cycle (about 128 kHz for an NTSC clock).
/// 2. A polyphase interpolator evaluates a band-limited reconstruction of that signal at each
///    output instant. Its filter is tabulated at 256 sub-sample offsets and linearly interpolated
///    between them, so any output rate works and the output clock never drifts.
///
/// Both filters are Kaiser-windowed sincs designed at init for the actual rates: the band up to
/// 20 kHz (at most 43% of the output rate) is flat, and everything that would fold back below that
/// edge is attenuated by about 100 dB. The output instants are tracked relative to the newest
/// stage-1 sample, so the timing keeps full precision however long the session runs.
///
/// Holds manually allocated buffers: the owner calls `deallocate()` once.
struct OutputResampler {
    static let decimation = 8
    static let offsets = 256

    private let taps1: Int
    private let kernel1: UnsafeMutablePointer<Float>
    /// The last `taps1` cycle samples, each written twice (at i and i + taps1), so the newest
    /// window is always contiguous.
    private let window1: UnsafeMutablePointer<Float>
    private var next1 = 0
    private var cyclesInGroup = 0

    private let taps2: Int
    /// Row r holds the interpolation filter for offset r / `offsets`, oldest sample first.
    private let kernel2: UnsafeMutablePointer<Float>
    private let window2: UnsafeMutablePointer<Float>
    private var next2 = 0
    /// Stage-1 samples per output sample.
    private let outputStep: Double
    /// When the next output sample falls, in stage-1 samples after the newest one; it is due
    /// once that is below 1.
    private var pending = 1.0

    init(clockHz: Double, sampleRate: Double) {
        let rate1 = clockHz / Double(Self.decimation)
        let edge = min(20_000, 0.43 * sampleRate)
        let stop2 = min(sampleRate - edge, rate1 / 2)
        let stop1 = rate1 - stop2
        let attenuation = 100.0

        taps1 = Self.length(attenuation: attenuation, transition: (stop1 - edge) / clockHz)
        kernel1 = .allocate(capacity: taps1)
        let center1 = Double(taps1 - 1) / 2
        let cutoff1 = (edge + stop1) / 2 / clockHz
        var sum1 = 0.0
        for i in 0..<taps1 {
            let h = Self.windowedSinc(Double(i) - center1, cutoff: cutoff1, halfWidth: center1 + 1, attenuation: attenuation)
            kernel1[i] = Float(h)
            sum1 += h
        }
        for i in 0..<taps1 { kernel1[i] = Float(Double(kernel1[i]) / sum1) }
        window1 = .allocate(capacity: 2 * taps1)
        window1.initialize(repeating: 0, count: 2 * taps1)

        taps2 = Self.length(attenuation: attenuation, transition: (stop2 - edge) / rate1)
        let rows = Self.offsets + 1
        kernel2 = .allocate(capacity: rows * taps2)
        let center2 = Double(taps2) / 2
        let cutoff2 = (edge + stop2) / 2 / rate1
        var sum2 = 0.0
        for r in 0..<rows {
            let offset = Double(r) / Double(Self.offsets)
            for k in 0..<taps2 {
                // Column k multiplies the sample (taps2 - 1 - k) steps before the newest one.
                let age = Double(taps2 - 1 - k) + offset
                let h = Self.windowedSinc(age - center2, cutoff: cutoff2, halfWidth: center2, attenuation: attenuation)
                kernel2[r * taps2 + k] = Float(h)
                if r < Self.offsets { sum2 += h }
            }
        }
        let scale2 = Double(Self.offsets) / sum2
        for i in 0..<(rows * taps2) { kernel2[i] = Float(Double(kernel2[i]) * scale2) }
        window2 = .allocate(capacity: 2 * taps2)
        window2.initialize(repeating: 0, count: 2 * taps2)

        outputStep = rate1 / sampleRate
    }

    func deallocate() {
        kernel1.deallocate()
        window1.deallocate()
        kernel2.deallocate()
        window2.deallocate()
    }

    /// Takes one cycle's sample; returns true when it completed a stage-1 sample.
    @inline(__always)
    mutating func push(_ x: Float) -> Bool {
        window1[next1] = x
        window1[next1 + taps1] = x
        next1 = next1 + 1 == taps1 ? 0 : next1 + 1
        cyclesInGroup += 1
        if cyclesInGroup < Self.decimation { return false }
        cyclesInGroup = 0
        let y = Self.dot(kernel1, window1 + next1, taps1)
        window2[next2] = y
        window2[next2 + taps2] = y
        next2 = next2 + 1 == taps2 ? 0 : next2 + 1
        pending -= 1
        return true
    }

    /// Whether an output sample falls before the next stage-1 sample.
    var outputDue: Bool { pending < 1 }

    /// Computes the due output sample.
    @inline(__always)
    mutating func nextOutput() -> Double {
        let position = max(0, pending) * Double(Self.offsets)
        let row = min(Int(position), Self.offsets - 1)
        let blend = Float(position - Double(row))
        let window = UnsafePointer(window2 + next2)
        let a = Self.dot(kernel2 + row * taps2, window, taps2)
        let b = Self.dot(kernel2 + (row + 1) * taps2, window, taps2)
        pending += outputStep
        return Double(a + (b - a) * blend)
    }

    // MARK: Filter design

    /// Kaiser's estimate of the taps needed for `attenuation` dB over a transition band of
    /// `transition` (as a fraction of the sample rate), rounded up to a multiple of 8.
    private static func length(attenuation: Double, transition: Double) -> Int {
        let n = Int(((attenuation - 7.95) / (2.285 * 2 * Double.pi * transition)).rounded(.up)) + 1
        return max(16, (n + 7) / 8 * 8)
    }

    /// A low-pass impulse response with `cutoff` (cycles per sample) at `t` samples from its
    /// center, under a Kaiser window reaching zero at `halfWidth`.
    private static func windowedSinc(_ t: Double, cutoff: Double, halfWidth: Double, attenuation: Double) -> Double {
        let x = 2 * cutoff * t
        let sinc = abs(x) < 1e-12 ? 1 : sin(Double.pi * x) / (Double.pi * x)
        let beta = 0.1102 * (attenuation - 8.7)
        let r = t / halfWidth
        guard abs(r) < 1 else { return 0 }
        return 2 * cutoff * sinc * besselI0(beta * (1 - r * r).squareRoot()) / besselI0(beta)
    }

    /// Modified Bessel function of the first kind, order 0 (power series).
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let q = x * x / 4
        var k = 1.0
        while term > sum * 1e-17 {
            term *= q / (k * k)
            sum += term
            k += 1
        }
        return sum
    }

    @inline(__always)
    private static func dot(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ n: Int) -> Float {
        let ra = UnsafeRawPointer(a), rb = UnsafeRawPointer(b)
        var even = SIMD8<Float>(), odd = SIMD8<Float>()
        var offset = 0
        let bytes = n * MemoryLayout<Float>.stride
        let chunk = MemoryLayout<SIMD8<Float>>.stride
        while offset + 2 * chunk <= bytes {
            even += ra.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
                * rb.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
            odd += ra.loadUnaligned(fromByteOffset: offset + chunk, as: SIMD8<Float>.self)
                * rb.loadUnaligned(fromByteOffset: offset + chunk, as: SIMD8<Float>.self)
            offset += 2 * chunk
        }
        if offset < bytes {
            even += ra.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
                * rb.loadUnaligned(fromByteOffset: offset, as: SIMD8<Float>.self)
        }
        return (even + odd).sum()
    }
}
