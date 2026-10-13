import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// The whole editor ($B09A, entry to exit) against the original on the flat bus, with scripted
/// keys on both sides (`ScriptedKeys`: the original's wait-for-key gets them at $226B, the
/// port's at its poll; an exhausted script answers E). Every run compares memory (stack page
/// excluded), the I/O state (VIC, SID, color RAM, `$DD00`) and the exact cycles. The flows are
/// those of the lab sessions (editor, slew, night, clouds/wind, failures/reliability, radios,
/// war) and every key on both pages: typing, accepting, backspacing, wrapping, the USER MODE
/// field, S, '+', and the mode requests the main loop makes (`$08BB` 1-3, demo).
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct EditorSessionTests {
    static func r(_ n: Int) -> String { D2.returns(n) }
    static func u(_ n: Int) -> String { D2.ups(n) }
    static let del = D2.del

    func check(_ state: String, _ keys: String, sourceLocation: SourceLocation = #_sourceLocation,
               _ prepare: (inout [UInt8]) -> Void = { _ in }) throws -> DiffRig {
        var ram = try D2.state(state)
        prepare(&ram)
        let (problems, rig) = D2.compareEditor(ram, keys: keys)
        let shown = keys.replacingOccurrences(of: "\r", with: "⏎").replacingOccurrences(of: "\u{08}", with: "⌫")
        #expect(problems.isEmpty, "\(state) keys \(shown): \(problems.joined(separator: "; "))", sourceLocation: sourceLocation)
        return rig
    }

    /// The lab sessions' editor flows.
    @Test func sessionFlows() throws {
        let r = Self.r(_:)
        let u = Self.u(_:)
        let del = Self.del
        // editor.txt: HEADING (page 0 line 15) 95, DEL, 0; on through page 1 and back; '-'.
        var rig = try check("d2-ed-entry", r(14) + "95" + del + "0" + r(7) + r(21) + u(1) + "E")
        #expect(rig.machine.mem[0x0A13] == 0x00 && rig.machine.mem[0x0A14] == 0x40, "HEADING 90 -> $4000")
        // slew.txt: SLEW (line 4) = 1.
        rig = try check("d2-ed-entry", r(3) + "1E")
        #expect(rig.machine.mem[0x0966] == 1)
        // night.txt: HOURS (page 1 line 1) = 22.
        rig = try check("d2-ed-entry", r(21) + "22E")
        #expect(rig.machine.mem[0x0983] == 22)
        // failures.txt: reality (line 5) = 1, reliability (page 1 line 19) = 0: the exit sets
        // the magnetos OFF.
        rig = try check("d2-ed-entry", r(4) + "1" + r(1) + u(8) + "0E")
        #expect(rig.machine.mem[0x0967] == 1 && rig.machine.mem[0x09A4] == 0)
        // radios.txt: '-' from line 1 to page 1 line 21 (ADF ENABLE) = 1.
        rig = try check("d2-ed-entry", u(1) + "1E")
        #expect(rig.machine.mem[0x09AA] == 1)
        // clouds/wind: cloud layer 1 (page 1 lines 6/7), wind level 1 (lines 14/15), surface wind
        // with turbulence (lines 17/18), shear 1 (line 16).
        rig = try check("d2-ed-entry", r(21) + r(5) + "2100" + r(1) + "1700" + r(7) + "512" + r(1) + "300"
                        + r(1) + "2500" + r(1) + "315" + r(1) + "90E")
        // war.txt: Europe 1917 (line 6) = 1: mode 7 forced, the latch set.
        rig = try check("d2-ed-entry", r(5) + "1E")
        #expect(rig.machine.mem[0x0963] == 7 && rig.machine.mem[0x0E7C] == 7 && rig.machine.mem[0x0969] == 1)
    }

    /// Every field of both pages typed with a value and accepted, then exited.
    @Test func everyField() throws {
        let r = Self.r(_:)
        var rng = TestRandom(seed: 0xF1E1D)
        for page in 0..<2 {
            for line in 1...21 {
                let value = [String(rng.next() % 10), String(rng.next() % 256), String(rng.next() % 65536),
                             "999999", "65536", "0"][Int(rng.next() % 6)]
                let keys = r(page * 21 + line - 1) + value + "E"
                _ = try check("d2-ed-entry", keys)
            }
        }
    }

    /// Typing details: seven digits (the seventh ignored), DEL past the start, DEL then retype,
    /// keys the editor ignores, '-' and RETURN accepting, a field left unchanged.
    @Test func typing() throws {
        let r = Self.r(_:)
        let u = Self.u(_:)
        let del = Self.del
        for keys in [
            r(9) + "1234567" + r(1) + "E",
            r(10) + del + del + "1" + del + del + "2" + u(1) + "E",
            r(11) + "12" + del + "34" + del + del + del + del + "5E",
            r(12) + "QZ!@*/ " + "7" + "A\u{01}" + r(1) + "E",
            r(13) + "000000" + r(1) + "E",
            r(2) + "1" + u(1) + u(1) + "2" + r(1) + "E",
            r(16) + "65535" + r(1) + "70000" + r(1) + "E",
            r(7) + "255" + r(1) + "256" + r(1) + "E",
        ] {
            _ = try check("d2-ed-entry", keys)
        }
    }

    /// The cursor wraps both ways, several times, across both pages.
    @Test func wrapping() throws {
        let r = Self.r(_:)
        let u = Self.u(_:)
        _ = try check("d2-ed-entry", r(42) + r(42) + r(3) + "E")
        _ = try check("d2-ed-entry", u(43) + u(21) + "E")
        _ = try check("d2-ed-entry", r(25) + u(30) + r(5) + "1" + u(1) + "E")
    }

    /// The USER MODE field (page 0 line 1): recall 0-24 (the editor stays open on the line),
    /// save 110-124, refusals (≥ 210, ≥ 25, 100-109, 125+), the current mode.
    @Test func userModeField() throws {
        for entry in ["0", "2", "7", "9", "10", "15", "24", "25", "99", "105", "110", "111", "124", "125", "200",
                      "209", "210", "255", "300", "999999"] {
            _ = try check("d2-ed-entry", entry + "E")
            _ = try check("d2-ed-entry", entry + "\r" + "E")
        }
        // A save, then the recall of the same slot (both inside one visit).
        _ = try check("d2-ed-entry", "112E" + "")
        _ = try check("d2-ed-entry", "112" + "12" + "E")
    }

    /// S and '+' inside the editor, a user mode saved then recalled, and both after edits.
    @Test func saveAndRecallKeys() throws {
        let r = Self.r(_:)
        var rig = try check("d2-ed-entry", "SE")
        #expect(rig.machine.mem[0x0963] == 10 && rig.machine.mem[0x09A5] == 10)
        rig = try check("d2-ed-entry", r(14) + "180" + "S" + r(3) + "+E")
        _ = try check("d2-ed-entry", "+E")
        _ = try check("d2-ed-entry", r(5) + "12+" + "E")
        _ = try check("d2-ed-entry", "111\r" + "S" + "+" + "E")
        // In user mode 24 S keeps the mode; above the limit S does nothing.
        _ = try check("d2-ed-entry", "SE") { $0[0x0963] = 24 }
        _ = try check("d2-ed-entry", "SE") { $0[0x0963] = 25 }
    }

    /// The main loop's requests: '+' (`$08BB` = 1), 'S' (2), the demo (3 and any other value):
    /// served without a key. From the lab states and from pokes.
    @Test func modeRequests() throws {
        for name in ["d2-ed-save", "d2-ed-recall", "d2-demo-entry"] {
            let rig = try check(name, "")
            #expect(rig.machine.mem[0x08BB] == 0 && rig.machine.mem[0x08BA] == 0, "\(name): requests cleared")
        }
        for request: UInt8 in [1, 2, 3, 4, 0x80, 0xFF] {
            let rig = try check("d2-ed-entry", "") { $0[0x08BB] = request; $0[0x08BA] = 0 }
            if request >= 3 { #expect(rig.machine.mem[0x0963] == 2, "request \(request) loads the demo mode") }
        }
        // The demo hand-over: `$095A` = `$095B`, `$095B` = 0.
        let rig = try check("d2-demo-entry", "")
        #expect(rig.machine.mem[0x095A] == 1 && rig.machine.mem[0x095B] == 0 && rig.machine.mem[0x0963] == 2)
        // A second entry from the cache, and an entry with the cache invalid (the course plotter).
        _ = try check("d2-ed-cached", Self.r(3) + "E")
        _ = try check("d2-ed-entry", "E") { $0[0x08BC] = 2 }
    }

    /// Europe 1917: forced from the field, from a mode that has it, while already in mode 7.
    @Test func europe1917() throws {
        let r = Self.r(_:)
        var rig = try check("d2-ed-entry", r(5) + "1" + r(10) + "270E")
        #expect(rig.machine.mem[0x0A13] == 0 && rig.machine.mem[0x0A14] == 0, "the heading typed is discarded (mode 7)")
        rig = try check("d2-ed-entry", "7E")
        #expect(rig.machine.mem[0x0963] == 7 && rig.machine.mem[0x0E7C] == 7)
        rig = try check("d2-ed-entry", "E") { $0[0x0969] = 1; $0[0x0963] = 7; $0[0x0E7C] = 7 }
        // Leaving mode 7 again: the latch stays (the main loop then restarts the game).
        rig = try check("d2-ed-entry", r(5) + "0" + u0() + "0E") { $0[0x0969] = 1; $0[0x0963] = 7; $0[0x0E7C] = 7 }
        #expect(rig.machine.mem[0x0E7C] == 7 && rig.machine.mem[0x0963] == 0)
        #expect(rig.machine.warModeRestartDue)
    }

    func u0() -> String { Self.u(5) }
}
