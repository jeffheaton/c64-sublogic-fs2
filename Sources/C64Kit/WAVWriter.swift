#if !os(WASI)
import Foundation

/// Writes 16-bit mono PCM WAV files.
public enum WAVWriter {
    /// The WAV file for `samples` (-1...1, clamped).
    public static func data(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var bytes = [UInt8]()
        bytes.reserveCapacity(44 + dataSize)
        func ascii(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        func u16(_ v: Int) { for i in 0..<2 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
        ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1)                  // PCM
        u16(1)                  // mono
        u32(sampleRate)
        u32(sampleRate * 2)     // byte rate
        u16(2)                  // block align
        u16(16)                 // bits per sample
        ascii("data"); u32(dataSize)
        for s in samples {
            let x = s.isNaN ? 0 : min(1, max(-1, s))
            u16(Int((x * 32767).rounded()))
        }
        return Data(bytes)
    }

    public static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        try data(samples: samples, sampleRate: sampleRate).write(to: url)
    }
}
#endif
