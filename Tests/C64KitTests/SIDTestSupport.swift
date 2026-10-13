import C64Kit
import Foundation

/// Cycles per NTSC video frame (263 lines of 65 cycles): the pattern player's time base.
let ntscCyclesPerFrame = 17_095

extension SIDModel {
    /// Writes the 16-bit frequency of voice 0-2, low byte first.
    func setFrequency(voice: Int, _ f: UInt16) {
        write(voice * 7, UInt8(f & 0xFF))
        write(voice * 7 + 1, UInt8(f >> 8))
    }

    /// Writes the 12-bit pulse width of voice 0-2.
    func setPulseWidth(voice: Int, _ pw: UInt16) {
        write(voice * 7 + 2, UInt8(pw & 0xFF))
        write(voice * 7 + 3, UInt8(pw >> 8))
    }

    /// Clocks one cycle at a time until ENV3 equals `level`; the cycles taken, or nil after `limit`.
    func cyclesUntilEnv3(is level: UInt8, limit: Int) -> Int? {
        var n = 0
        while read(0x1C) != level {
            if n == limit { return nil }
            clock(cycles: 1)
            n += 1
        }
        return n
    }
}

/// Standard deviation (the RMS of the signal without its mean).
func acLevel<C: Collection>(_ s: C) -> Double where C.Element == Float {
    let mean = s.reduce(0.0) { $0 + Double($1) } / Double(s.count)
    return (s.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(s.count)).squareRoot()
}

/// Amplitude of the component of `x` at `frequency` Hz, measured under a Blackman-Harris window
/// (a Goertzel filter, so only the frequencies asked for are computed).
func toneAmplitude(_ x: [Float], at frequency: Double, sampleRate: Double) -> Double {
    let n = x.count
    var s1 = 0.0, s2 = 0.0, windowSum = 0.0
    let k = 2 * cos(2 * Double.pi * frequency / sampleRate)
    for i in 0..<n {
        let t = 2 * Double.pi * Double(i) / Double(n - 1)
        let w = 0.35875 - 0.48829 * cos(t) + 0.14128 * cos(2 * t) - 0.01168 * cos(3 * t)
        windowSum += w
        let s0 = Double(x[i]) * w + k * s1 - s2
        s2 = s1
        s1 = s0
    }
    return 2 * max(0, s1 * s1 + s2 * s2 - k * s1 * s2).squareRoot() / windowSum
}

/// Deterministic xorshift64 generator for the randomized tests.
struct TestRandom {
    var state: UInt64

    mutating func next(_ bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}
