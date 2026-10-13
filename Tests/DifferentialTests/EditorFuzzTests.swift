import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Random editor sessions against the original on the flat bus (memory with the stack page
/// excluded, the I/O state and the exact cycles, as `EditorSessionTests`): random key scripts
/// (RETURN, '-', digits, DEL, '+', S, E and ignored keys; the library keys need the drive and
/// are covered by `EditorLibraryTests`) from varied states: the first and the cached entry, any
/// current mode 0-24 (or above the limit), the demo running, reality mode, the three cache
/// states, a library pointer other than $C800.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct EditorFuzzTests {
    /// One random key: mostly RETURN and digits, some '-', DEL, '+', S, E, others ignored.
    static func key(_ rng: inout TestRandom) -> String {
        switch rng.next() % 32 {
        case 0..<10: return "\r"
        case 10..<20: return String(rng.next() % 10)
        case 20..<23: return "-"
        case 23..<26: return D2.del
        case 26: return "+"
        case 27: return "S"
        case 28: return "E"
        case 29: return ["Q", ":", "/", " ", "A", "\u{01}", "\u{7F}", "\u{91}"][Int(rng.next() % 8)]
        default: return String(repeating: String(rng.next() % 10), count: Int(1 + rng.next() % 7))
        }
    }

    @Test func randomSessions() throws {
        var rng = TestRandom(seed: 0xED17)
        var failures: [String] = []
        let states = ["d2-ed-entry", "d2-ed-cached"]
        for i in 0..<400 {
            var ram = try D2.state(states[i % states.count])
            let mode = UInt8(rng.next() % 28)
            ram[0x0963] = mode
            ram[0x09A5] = rng.next() % 4 == 0 ? rng.byte() : mode
            if rng.next() % 6 == 0 { ram[0x095A] = 1 }
            if rng.next() % 5 == 0 { ram[0x0967] = 1 }
            if rng.next() % 4 == 0 { ram[0x08BC] = UInt8(rng.next() % 3) }
            if rng.next() % 8 == 0 { ram[0x0961] = 0x00; ram[0x0962] = 0x30 }
            // Some runs with the 10 Hz divider due: the key waits then run the tick body ($2348,
            // the ported `tick10Hz` on the port's side) as in flight.
            if i % 4 == 3 { ram[0x0E6B] = 6 + UInt8(rng.next() % 4) }
            var keys = ""
            for _ in 0..<(4 + rng.next() % 40) { keys += Self.key(&rng) }
            let (problems, _) = D2.compareEditor(ram, keys: keys)
            if !problems.isEmpty && failures.count < 6 {
                let shown = keys.replacingOccurrences(of: "\r", with: "⏎").replacingOccurrences(of: "\u{08}", with: "⌫")
                failures.append("run \(i) mode \(mode) keys \(shown): " + problems.joined(separator: "; "))
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
