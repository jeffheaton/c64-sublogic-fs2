import Foundation
import M6502
import Synchronization
import FS2Core
import FS2LabKit
import Testing

/// Shared fixtures of the scenery tests (`Scenery*Tests`).
enum SCN {
    /// The scratch area crafted display lists are built in ($C000-$C7FF: the debug-monitor
    /// buffer, unused by a scenery pass at Meigs).
    static let list = 0xC100
    /// Words the crafted lists store markers into.
    static let marker = 0xC7F0

    /// The regular-flight RAM at Meigs with the 10 Hz tick not due (`$0E6B` = 0).
    static func regular() throws -> [UInt8] {
        var r = R3D.sanitized(try Original.regularFlight())
        r[0x0E6B] = 0
        return r
    }

    /// A rig with the disk's blocks on the port's side (and, with `SCN_COVERAGE` set, the
    /// coverage recorder on the original's CPU).
    static func rig(_ ram: [UInt8]) -> DiffRig {
        let rig = DiffRig(ram)
        rig.machine.diskBlocks = Original.diskBlocks
        SCNCoverage.install(on: rig.harness.cpu)
        return rig
    }

    static func load(_ rig: DiffRig, _ bytes: [UInt8], at address: Int) {
        for (k, b) in bytes.enumerated() { rig.poke(address + k, b) }
    }

    /// The code the scenery pass runs: the library, the main code, the 3D engine and
    /// interpreter, the high code.
    static let codeRanges = [0x0F00..<0x1EB0, 0x2000..<0x4200, 0x77E0..<0xA7E0, 0xCC00..<0xD000, 0xE000..<0xF9F9]

    /// Restores the code ranges on both sides from `base`. Degenerate random polygons can make
    /// the original's spans write into code (`render3d.md`); a later round would then run
    /// damaged code on the original's side only.
    static func restoreCode(_ rig: DiffRig, from base: [UInt8]) {
        for r in codeRanges {
            for a in r where rig.harness.bus.ram[a] != base[a] || rig.machine.mem[a] != base[a] {
                rig.poke(a, base[a])
            }
        }
    }

    /// Runs the display list at `address` on both sides from $8742 (`dlInterpreter`).
    @discardableResult
    static func runList(_ rig: DiffRig, at address: Int, _ label: @autoclosure () -> String) -> RoutineHarness.Result {
        rig.poke16(0x8B, UInt16(address))
        let text = label()
        return rig.run(0x8742, .init(), text) { m in
            do { try m.dlInterpreter() } catch { Issue.record("\(text): \(error)") }
            return .init()
        }
    }

    /// Runs `address` on both sides with a throwing port.
    @discardableResult
    static func run(_ rig: DiffRig, _ address: UInt16, _ label: @autoclosure () -> String,
                    _ port: @escaping (Machine) throws(Scenery.Fault) -> Void) -> RoutineHarness.Result {
        let text = label()
        return rig.run(address, .init(), text) { m in
            do { try port(m) } catch { Issue.record("\(text): \(error)") }
            return .init()
        }
    }
}

/// Development aid: with `SCN_COVERAGE` set, every scenery rig records the instructions the
/// original executed in the scenery unit's ranges and the pairs of consecutive ones;
/// `SCNCoverage.flush()` (called by the suites) writes `build/testdata/scn-coverage.txt` (every
/// instruction start of the ranges never executed) and `scn-branches.txt` (every executed
/// conditional branch with an outcome no test produced).
enum SCNCoverage {
    static let enabled = ProcessInfo.processInfo.environment["SCN_COVERAGE"] != nil
    static let ranges: [ClosedRange<Int>] = [0x2330...0x2347, 0x8030...0x8110, 0x83A4...0x840E, 0x8730...0x8FE7,
                                             0xA5C8...0xA73D, 0xE565...0xE56E, 0xE58D...0xE617]
    private static let hits = Mutex(Set<Int>())
    private static let edges = Mutex(Set<Int>())
    private final class Previous: @unchecked Sendable { var pc = -1 }

    static func install<B>(on cpu: CPU6502<B>) {
        guard enabled else { return }
        for range in ranges { for a in range { cpu.traps[a] = true } }
        let previous = Previous()
        cpu.trapHandler = { pc in
            let p = Int(pc)
            hits.withLock { _ = $0.insert(p) }
            if previous.pc >= 0 { edges.withLock { _ = $0.insert(previous.pc << 16 | p) } }
            previous.pc = p
            return false
        }
    }

    static func flush() {
        guard enabled else { return }
        let executed = hits.withLock { $0 }
        let code = Original.data!.coldMemory
        // Instruction starts by linear disassembly of each range.
        var missing: [String] = []
        for range in ranges {
            var pc = range.lowerBound
            while pc <= range.upperBound {
                let info = Opcodes.table[Int(code[pc])]
                let length = info.documented ? info.length : 1
                if !executed.contains(pc) { missing.append(String(format: "%04X", pc)) }
                pc += max(1, length)
            }
        }
        let dir = Original.repoRoot.appendingPathComponent("build/testdata")
        try? missing.joined(separator: "\n").write(to: dir.appendingPathComponent("scn-coverage.txt"),
                                                   atomically: true, encoding: .utf8)
        let pairs = edges.withLock { $0 }
        var report: [String] = []
        for pc in executed.sorted() where code[pc] & 0x1F == 0x10 {
            let next = pc + 2, target = next + Int(Int8(bitPattern: code[pc + 1]))
            if !pairs.contains(pc << 16 | target) { report.append(String(format: "%04X never taken", pc)) }
            if !pairs.contains(pc << 16 | next) { report.append(String(format: "%04X never falls through", pc)) }
        }
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("scn-branches.txt"),
                                                  atomically: true, encoding: .utf8)
    }
}

extension DiffRig {
    /// `expectClean`, then the coverage flush (see `SCNCoverage`).
    func expectCleanSCN(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectClean(what, sourceLocation: sourceLocation)
        SCNCoverage.flush()
    }
}

/// A display list under construction.
struct DisplayList {
    let base: Int
    var bytes: [UInt8] = []
    init(at base: Int) { self.base = base }

    var here: Int { base + bytes.count }
    mutating func op(_ b: UInt8...) { bytes += b }
    mutating func word(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    mutating func long(_ v: Int) { word(v & 0xFFFF); word((v >> 16) & 0xFFFF) }
    /// Patches the rel16 at byte offset `at` to point from the opcode at `from` to `to`.
    mutating func patchRel(at: Int, from: Int, to: Int) {
        let rel = (to - from) & 0xFFFF
        bytes[at] = UInt8(rel & 0xFF); bytes[at + 1] = UInt8(rel >> 8)
    }
    /// `25 marker v`: stores a marker word (shows which path ran).
    mutating func mark(_ v: Int, slot: Int = 0) { op(0x25); word(SCN.marker + 2 * slot); word(v) }
    mutating func end() { op(0x79) }
}

extension TestRandom {
    mutating func scnBelow(_ n: Int) -> Int { Int(next() >> 33) % n }
    mutating func scnWord() -> Int { Int(next() >> 40) & 0xFFFF }
    mutating func scnSigned(_ magnitude: Int) -> Int { scnBelow(2 * magnitude + 1) - magnitude }
    /// A word that is an edge value a quarter of the time.
    mutating func scnEdgeWord() -> Int {
        if scnBelow(4) == 0 { return [0, 1, 0x7FFF, 0x8000, 0x8001, 0xFFFF, 0x00FF, 0xFF00][scnBelow(8)] }
        return scnWord()
    }
}

/// Every opcode handler on crafted display lists, against the original.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct SceneryVMTests {
    /// Calls (18, 09 with a pointer and with 0, 0A to $80D1), returns (19), jumps (0B), nops (11)
    /// and END, nested.
    @Test func controlFlow() throws {
        let rig = SCN.rig(try SCN.regular())
        var rng = TestRandom(seed: 0x8752)
        for round in 0..<40 {
            var l = DisplayList(at: SCN.list + rng.scnBelow(0x100))
            let pointer = 0xC0F0, zero = 0xC0F2, native = 0xC0F4
            let callOp = l.here
            l.op(0x18); let call = l.bytes.count; l.word(0)
            let jumpOp = l.here
            l.op(0x0B); let jump = l.bytes.count; l.word(0)
            for _ in 0..<rng.scnBelow(4) { l.op(0x46 + UInt8(rng.scnBelow(0xBA))) }   // never run
            l.patchRel(at: jump, from: jumpOp, to: l.here)
            l.op(0x09); l.word(pointer)
            l.op(0x09); l.word(zero)
            l.op(0x0A); l.word(native)
            l.op(0x0A); l.word(zero)
            l.op(0x11, 0x11)
            l.mark(round, slot: 0)
            l.end()
            l.patchRel(at: call, from: callOp, to: l.here)
            l.mark(0x1111 &+ round, slot: 1)
            let nestedOp = l.here
            l.op(0x18); let nested = l.bytes.count; l.word(0)
            l.op(0x19)
            l.patchRel(at: nested, from: nestedOp, to: l.here)
            l.mark(0x2222, slot: 2)
            l.op(0x19)
            let sub3 = l.here
            l.mark(0x3333 &+ round, slot: 3)
            l.op(0x11)
            l.end()
            l.op(0x2A, 0x2A, 0x30, 0x0A, 0x0B, 0x0C, 0xFF, 0x7F)   // operand bytes for $80D1
            SCN.load(rig, l.bytes, at: l.base)
            rig.poke16(pointer, UInt16(sub3))
            rig.poke16(zero, 0)
            rig.poke16(native, 0x80D1)
            SCN.runList(rig, at: l.base, "control flow \(round)")
        }
        rig.expectCleanSCN("control flow")
    }

    /// Native calls (op 0A) into the interpreter itself: $A731 (an absolute jump, entered with
    /// Y = 1, so it reads the op's high byte and the next byte as the new PC; the list there
    /// returns from the native call), $8752 and $8749; and the dashed line at a page end (the PC
    /// stepped back across a page).
    @Test func edgeCases() throws {
        let rig = SCN.rig(try SCN.regular())
        // [0A F4 C0 C2]: [$C0F4] = $A731 → PC = $C2C0 (the list there marks and ends), then the
        // byte $C2 after the op is an END.
        SCN.load(rig, [0x0A, 0xF4, 0xC0, 0xC2], at: SCN.list)
        rig.poke16(0xC0F4, 0xA731)
        var sub = DisplayList(at: 0xC2C0)
        sub.mark(0x5A5A); sub.op(0x11); sub.end()
        SCN.load(rig, sub.bytes, at: sub.base)
        SCN.runList(rig, at: SCN.list, "native $A731")
        // $8749 entered with A = $49 | $87 = $CF: the native call runs the list at PC + $CF.
        var l = DisplayList(at: SCN.list + 0x40)
        l.op(0x0A); l.word(0xC0F6)
        l.mark(0x1234)
        l.end()
        SCN.load(rig, l.bytes, at: l.base)
        rig.poke16(0xC0F6, 0x8749)
        var far = DisplayList(at: l.base + 0xCF)
        far.mark(0x4321, slot: 1); far.op(0x11); far.end()
        SCN.load(rig, far.bytes, at: far.base)
        SCN.runList(rig, at: l.base, "native $8749")
        // Stores into the PC itself: op 25 to $008B moves the PC before the op reads its high
        // byte (from the new PC + 4), and op 09 through the pointer at $008A reads the high byte
        // of the target from $8B after it got the low one ($8A = 0 there: a zero word, skipped).
        var store = DisplayList(at: SCN.list + 0x100)
        store.op(0x25); store.word(0x008B); store.op(0x40, 0xEE)   // [$8B] = $40; high byte from $C244
        store.end()
        SCN.load(rig, store.bytes, at: store.base)
        var moved = DisplayList(at: SCN.list + 0x144)
        moved.op(0xC2)                                              // the high byte: PC = $C240 + 5
        moved.mark(0x2525); moved.end()
        SCN.load(rig, moved.bytes, at: moved.base)
        SCN.runList(rig, at: store.base, "op 25 into the PC")
        var indirect = DisplayList(at: SCN.list + 0x60)
        indirect.op(0x09); indirect.word(0x008A)
        indirect.mark(0x0909); indirect.end()
        SCN.load(rig, indirect.bytes, at: indirect.base)
        SCN.runList(rig, at: indirect.base, "op 09 through $008A")
        // Dashed lines whose second point's PC step crosses back over a page boundary.
        var rng = TestRandom(seed: 0x8A56)
        for round in 0..<40 {
            let at = 0xC1FB - rng.scnBelow(2) * 0x100 + (round % 2 == 0 ? 0 : -16)
            var l = DisplayList(at: at)
            l.op(0x2B)
            for _ in 0..<4 { l.word(rng.scnSigned(3000) & 0xFFFF) }
            l.end()
            SCN.load(rig, l.bytes, at: l.base)
            SCN.runList(rig, at: l.base, "dashed at \(hex16(at))")
        }
        rig.expectCleanSCN("edge cases")
    }

    /// Op 0A into every vector of the renderer table $8000-$8027 and into each vector's target
    /// (the native-call ABI: A = low | high byte of the address, X = $14, Y = 1). The entries
    /// that run the list at the PC as it is ($8006, $8730, $8742, $8752) would run the op 0A
    /// again forever, on both sides, and are covered by `controlFlow`/`edgeCases` instead.
    @Test func nativeCallTargets() throws {
        let state = try SCN.regular()
        let rig = SCN.rig(state)
        let targets: [UInt16] = [
            0x8000, 0x8003, 0x8009, 0x800C, 0x800F, 0x8012, 0x8015, 0x8018, 0x801B, 0x801E, 0x8021,
            0x8024, 0x8027, 0x8111, 0x83A4, 0x9A1D, 0x99FD, 0x9BF5, 0xA532, 0xA558, 0x9996, 0x9C93,
            0xA378, 0x9C9C,
        ]
        for (round, target) in targets.enumerated() {
            SCN.restoreCode(rig, from: state)
            var l = DisplayList(at: SCN.list)
            l.op(0x0A); l.word(0xC0F8)
            l.mark(Int(target))
            l.end()
            SCN.load(rig, l.bytes, at: l.base)
            rig.poke16(0xC0F8, target)
            // $8018 and $8749 advance the PC by A = $98 / $CF and run the list there.
            let a = Int(UInt8(target & 0xFF) | UInt8(target >> 8))
            var far = DisplayList(at: l.base + a)
            far.mark(round, slot: 1); far.op(0x11); far.end()
            SCN.load(rig, far.bytes, at: far.base)
            // Screen line endpoints for $9A1D, an origin-free view for the horizon pass.
            rig.poke(0xEB, 0x10); rig.poke(0xEC, 0x08); rig.poke(0xED, 0x90); rig.poke(0xEE, 0x60)
            SCN.runList(rig, at: l.base, "native \(hex16(Int(target)))")
        }
        rig.expectCleanSCN("native-call targets")
    }

    /// A list ending in a jump op whose two outcomes store different markers.
    static func branch(_ rig: DiffRig, _ l: inout DisplayList, opcodeAt start: Int, relAt: Int, _ label: String) {
        l.mark(0xAAAA)
        l.end()
        let target = l.here
        l.patchRel(at: relAt, from: start, to: target)
        l.mark(0xBBBB)
        l.end()
        SCN.load(rig, l.bytes, at: l.base)
        SCN.runList(rig, at: l.base, label)
    }

    /// Ops 13 and 14: boxes around the eye (inside, outside, on the edge, across the wrap of the
    /// 16-bit differences), the altitude test of op 14 in normal and radar mode.
    @Test func rangeBoxes() throws {
        let rig = SCN.rig(try SCN.regular())
        var rng = TestRandom(seed: 0x8E74)
        var jumps = 0
        for round in 0..<600 {
            let op: UInt8 = rng.scnBelow(2) == 0 ? 0x13 : 0x14
            let eyeZ = rng.scnBelow(3) == 0 ? rng.scnWord() : Int(rig.machine.u16(0x64))
            let eyeX = rng.scnBelow(3) == 0 ? rng.scnWord() : Int(rig.machine.u16(0x5C))
            rig.poke16(0x64, UInt16(eyeZ)); rig.poke16(0x5C, UInt16(eyeX))
            rig.poke16(0x60, UInt16(rng.scnBelow(4) == 0 ? rng.scnWord() : rng.scnBelow(40)))
            rig.poke16(0x088A, UInt16(rng.scnBelow(60)))
            rig.poke(0x0836, rng.scnBelow(4) == 0 ? 1 : 0)
            let r = rng.scnBelow(4) == 0 ? rng.scnEdgeWord() : rng.scnBelow(600)
            let near = { (eye: Int) -> Int in
                rng.scnBelow(5) == 0 ? rng.scnEdgeWord() : (eye + rng.scnSigned(r + 3)) & 0xFFFF
            }
            var l = DisplayList(at: SCN.list + rng.scnBelow(0x100))
            let start = l.here
            l.op(op); let rel = l.bytes.count; l.word(0)
            l.word(r); l.word(near(eyeZ)); l.word(near(eyeX))
            Self.branch(rig, &l, opcodeAt: start, relAt: rel, "op \(hex(op)) round \(round)")
            if rig.harness.bus.ram[SCN.marker] == 0xBB { jumps += 1 }
        }
        rig.expectCleanSCN("ops 13/14")
        #expect(jumps > 100 && jumps < 500, "\(jumps) of 600 jumped")
    }

    /// Ops 20, 21, 22: 1-3 (variable, low, high) triples with signed bounds, edge words, and
    /// variables across a page (`$8E` = $FF).
    @Test func variableRanges() throws {
        let rig = SCN.rig(try SCN.regular())
        var rng = TestRandom(seed: 0x8F05)
        for round in 0..<600 {
            let count = 1 + rng.scnBelow(3)
            var l = DisplayList(at: SCN.list + rng.scnBelow(0x100))
            let start = l.here
            l.op(UInt8(0x1F + count)); let rel = l.bytes.count; l.word(0)
            for k in 0..<count {
                let address = rng.scnBelow(3) == 0 ? 0xC2FF : 0xC300 + 2 * k + 8 * rng.scnBelow(8)
                let value = rng.scnEdgeWord()
                rig.poke16(address, UInt16(value))
                let v = Int(Int16(truncatingIfNeeded: value))
                var lo = rng.scnBelow(3) == 0 ? rng.scnEdgeWord() : (v - rng.scnBelow(300)) & 0xFFFF
                var hi = rng.scnBelow(3) == 0 ? rng.scnEdgeWord() : (v + rng.scnBelow(300)) & 0xFFFF
                if rng.scnBelow(6) == 0 { lo = value; hi = value }
                if rng.scnBelow(8) == 0 { swap(&lo, &hi) }
                l.word(address); l.word(lo); l.word(hi)
            }
            Self.branch(rig, &l, opcodeAt: start, relAt: rel, "op \(0x1F + count) round \(round)")
        }
        rig.expectCleanSCN("ops 20-22")
    }

    /// Op 23 (bit test) and op 28 (types 0, 1, 2, 3; equal, overflowing and edge words).
    @Test func bitTestAndCompares() throws {
        let rig = SCN.rig(try SCN.regular())
        var rng = TestRandom(seed: 0x8F7A)
        for round in 0..<400 {
            var l = DisplayList(at: SCN.list + rng.scnBelow(0x100))
            let start = l.here
            let a = rng.scnBelow(4) == 0 ? 0xC2FF : 0xC300 + 2 * rng.scnBelow(16)
            let va = rng.scnEdgeWord()
            rig.poke16(a, UInt16(va))
            l.op(0x23); let rel = l.bytes.count; l.word(0)
            l.word(a)
            let mask = rng.scnBelow(3) == 0 ? (1 << rng.scnBelow(16)) : rng.scnEdgeWord()
            l.word(mask)
            Self.branch(rig, &l, opcodeAt: start, relAt: rel, "op 23 round \(round)")
        }
        for round in 0..<800 {
            var l = DisplayList(at: SCN.list + rng.scnBelow(0x100))
            let start = l.here
            let type = UInt8(rng.scnBelow(5) == 0 ? rng.scnBelow(256) : rng.scnBelow(4))
            let a = rng.scnBelow(5) == 0 ? 0xC2FF : 0xC300 + 2 * rng.scnBelow(16)
            let b = rng.scnBelow(5) == 0 ? 0xC4FF : 0xC400 + 2 * rng.scnBelow(16)
            let va = rng.scnEdgeWord()
            let vb = rng.scnBelow(4) == 0 ? va : (rng.scnBelow(3) == 0 ? (va ^ 0x8000) : rng.scnEdgeWord())
            rig.poke16(a, UInt16(va)); rig.poke16(b, UInt16(vb))
            l.op(0x28, type); let rel = l.bytes.count; l.word(0)
            l.word(a); l.word(b)
            Self.branch(rig, &l, opcodeAt: start, relAt: rel, "op 28 type \(type) round \(round)")
        }
        rig.expectCleanSCN("ops 23/28")
    }

    /// Ops 1A and 25 (pointers across pages, stores into their own pointers), op 0D with the
    /// block already in its slot, the pen ops 12/1B/1C (day and night) and op 11.
    @Test func dataOps() throws {
        let rig = SCN.rig(try SCN.regular())
        var rng = TestRandom(seed: 0x8DC3)
        for round in 0..<300 {
            var l = DisplayList(at: SCN.list + rng.scnBelow(0x100))
            for _ in 0..<8 {
                switch rng.scnBelow(6) {
                case 0:
                    // Destinations in the op's own pointers `$A5-$A8` change where the second byte
                    // goes: the source words keep that inside zero page or the scratch area.
                    let src = rng.scnBelow(6) == 0 ? 0xC3FF : 0xC300 + rng.scnBelow(0x1F0)
                    let dst = rng.scnBelow(8) == 0 ? 0x00A5 + rng.scnBelow(4) : 0xC300 + rng.scnBelow(0x200)
                    if dst == 0xA5 { rig.poke(src, 0xF0) }
                    if dst == 0xA6 { rig.poke(src, 0xC3) }
                    l.op(0x1A); l.word(dst); l.word(src)
                case 1:
                    let dst = rng.scnBelow(8) == 0 ? 0x00A7 + rng.scnBelow(2) : 0xC300 + rng.scnBelow(0x200)
                    let v = dst == 0xA7 ? 0xF0 | rng.scnWord() & 0xFF00 : dst == 0xA8 ? 0xC3 | rng.scnWord() & 0xFF00 : rng.scnWord()
                    l.op(0x25); l.word(dst); l.word(v)
                case 2:
                    l.op(0x12, UInt8(rng.scnBelow(16)))
                case 3:
                    l.op(rng.scnBelow(2) == 0 ? 0x1B : 0x1C)
                case 4:
                    // The slot already holds the block: nothing is read.
                    let slot = rng.scnBelow(2)
                    l.op(0x0D, rig.machine.mem[0x0900 + slot], 1); l.word(rng.scnWord()); l.op(UInt8(slot))
                default:
                    l.op(0x11)
                }
            }
            l.end()
            rig.poke(0x083C, UInt8(rng.scnBelow(4)))
            rig.poke(0x08D9, rng.scnBelow(4) == 0 ? 0x81 : UInt8(rng.scnBelow(4)))
            for k in 0..<0x200 where rng.scnBelow(8) == 0 && rig.machine.mem[0xC300 + k] != 0xC3
                && rig.machine.mem[0xC300 + k] != 0xF0 { rig.poke(0xC300 + k, UInt8(rng.scnBelow(256))) }
            SCN.load(rig, l.bytes, at: l.base)
            SCN.runList(rig, at: l.base, "data ops round \(round)")
        }
        rig.expectCleanSCN("data ops")
    }

    /// Ops 07 and 24: every scale 0-9 and a few odd ones, origins near and far (overflowing
    /// 32-bit differences), radar mode, y = 0 forced to 1, the ground base recomputed or not.
    @Test func origins() throws {
        let rig = SCN.rig(try SCN.regular())
        var rng = TestRandom(seed: 0x8C0D)
        for round in 0..<500 {
            let scales: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0x10, 0x82, 0xFF]
            let s = scales[rng.scnBelow(scales.count)]
            for a in 0x5A...0x65 where rng.scnBelow(3) == 0 { rig.poke(a, UInt8(rng.scnBelow(256))) }
            for a in 0x0888...0x088B where rng.scnBelow(3) == 0 { rig.poke(a, UInt8(rng.scnBelow(256))) }
            rig.poke(0x0836, rng.scnBelow(4) == 0 ? 1 : 0)
            if rng.scnBelow(3) == 0 { rig.poke16(0x35, rig.machine.u16(0x68)) }
            var l = DisplayList(at: SCN.list + rng.scnBelow(0x100))
            let eye = { (a: Int) -> Int in Int(rig.machine.u32(a)) }
            func origin(_ e: Int) -> Int {
                switch rng.scnBelow(4) {
                case 0: return Int(UInt32(truncatingIfNeeded: e + rng.scnSigned(0x7FFF)))
                case 1: return Int(UInt32(truncatingIfNeeded: e + rng.scnSigned(0x7FFFFF)))
                case 2: return e      // y = 0 at s = 0
                default: return Int(UInt32(truncatingIfNeeded: Int(rng.next() >> 32)))
                }
            }
            if rng.scnBelow(2) == 0 {
                l.op(0x07, s); l.long(origin(eye(0x5A))); l.long(origin(eye(0x5E))); l.long(origin(eye(0x62)))
            } else {
                l.op(0x24, s)
                l.word(origin(eye(0x5A)) >> 16); l.word(origin(eye(0x5E)) >> 16); l.word(origin(eye(0x62)) >> 16)
            }
            l.end()
            SCN.load(rig, l.bytes, at: l.base)
            SCN.runList(rig, at: l.base, "origin s=\(s) round \(round)")
        }
        rig.expectCleanSCN("ops 07/24")
    }

    /// Drawing: random scenes of dots, moves and lines (3D and ground), polygons (with points,
    /// ground points and cached vertices, up to and past 60 vertices), the vertex cache and its
    /// cull, screen lines, dashed lines and runways, from random eye attitudes and heights, in
    /// day and night pens, with the matrix rebuilt by the original.
    @Test func geometry() throws {
        var rng = TestRandom(seed: 0x8B40)
        for state in [try SCN.regular(), R3D.flipped(try SCN.regular())] {
            let rig = SCN.rig(state)
            var skipped = 0
            for round in 0..<220 {
                let label = "geometry round \(round)"
                SCN.restoreCode(rig, from: state)
                // Every sixth round a long polygon (past $8860's 60-vertex limit) to the right of a
                // level, north-facing front view, so the clipper drops it in its first pass.
                let longPolygon = round % 6 == 5
                rig.poke16(0x6C, UInt16(longPolygon ? 0 : rng.scnBelow(3) == 0 ? rng.scnWord() : rng.scnSigned(0x1800) & 0xFFFF))
                rig.poke16(0x6E, UInt16(longPolygon ? 0 : rng.scnBelow(3) == 0 ? rng.scnWord() : rng.scnSigned(0x2000) & 0xFFFF))
                rig.poke16(0x70, UInt16(longPolygon ? 0 : rng.scnWord()))
                rig.poke(0x0ACA, longPolygon ? 0 : [0, 0, 0, 2, 4, 6, 8, 0x0A, 0x0C, 0x0E, 0xFF][rng.scnBelow(11)])
                rig.poke(0x0836, !longPolygon && rng.scnBelow(8) == 0 ? 1 : 0)
                rig.poke16(0x0888, UInt16(rng.scnWord())); rig.poke16(0x088A, UInt16(rng.scnBelow(8)))
                rig.poke16(0x60, UInt16(rng.scnBelow(4) == 0 ? rng.scnBelow(30) : 0))
                rig.poke16(0x5E, UInt16(rng.scnWord()))
                rig.poke(0x083C, UInt8(rng.scnBelow(2)))
                rig.run(0x8111, .init(), "\(label) matrix") { m in m.buildViewMatrix(); return .init() }
                var l = DisplayList(at: SCN.list + rng.scnBelow(0x80))
                // The origin: the eye's high words (op 24, scale 4: meters), or a 3D one.
                l.op(0x24, 4)
                l.word(Int(rig.machine.u16(0x5C)) + rng.scnSigned(1))
                l.word(rng.scnBelow(4) == 0 ? Int(rig.machine.u16(0x60)) : 0)
                l.word(Int(rig.machine.u16(0x64)) + rng.scnSigned(1))
                let range = [60, 400, 2000, 9000, 0x7FFF][rng.scnBelow(5)]
                func coord() -> Int { rng.scnSigned(range) & 0xFFFF }
                func height() -> Int { rng.scnBelow(3) == 0 ? 0 : rng.scnSigned(range / 4) & 0xFFFF }
                var inPolygon = false, vertices = 0
                for _ in 0..<(4 + rng.scnBelow(24)) {
                    switch rng.scnBelow(16) {
                    case 0: l.op(0x00); l.word(coord()); l.word(height()); l.word(coord())
                    case 1: l.op(0x01); l.word(coord()); l.word(height()); l.word(coord())
                    case 2: l.op(0x02); l.word(coord()); l.word(height()); l.word(coord()); vertices += 1
                    case 3: l.op(0x40); l.word(coord()); l.word(coord())
                    case 4, 5: l.op(0x41); l.word(coord()); l.word(coord()); vertices += 1
                    case 6: l.op(0x31, UInt8(rng.scnBelow(8))); l.word(coord()); l.word(height()); l.word(coord())
                    case 7: l.op(0x42, UInt8(rng.scnBelow(8))); l.word(coord()); l.word(coord())
                    case 8: l.op(0x32, UInt8(rng.scnBelow(8)))
                    case 9: l.op(0x33, UInt8(rng.scnBelow(8))); vertices += 1
                    case 10: l.op(0x35, UInt8(rng.scnBelow(8)))
                    case 11:
                        if inPolygon {
                            l.op(0x29); inPolygon = false
                        } else if rng.scnBelow(3) == 0 {
                            l.op(0x29)                      // outside a polygon: the closing line
                        } else {
                            l.op(0x2F); inPolygon = true
                        }
                        vertices = 0
                    case 12:
                        let start = l.here
                        l.op(0x04); let rel = l.bytes.count; l.word(0)
                        for _ in 0..<(1 + rng.scnBelow(4)) { l.op(UInt8(rng.scnBelow(8))) }
                        l.op(0xFF)
                        l.patchRel(at: rel, from: start, to: l.here)
                    case 13: l.op(0x2B); l.word(coord()); l.word(coord()); l.word(coord()); l.word(coord())
                    case 14:
                        l.op(0x06, UInt8(rng.scnBelow(160)), UInt8(rng.scnBelow(112)), UInt8(rng.scnBelow(160)),
                             UInt8(rng.scnBelow(112)))
                    default:
                        if !inPolygon {
                            l.op(0x03, UInt8(rng.scnBelow(256))); l.word(rng.scnBelow(range)); l.word(rng.scnBelow(range / 8 + 1))
                        } else {
                            l.op(rng.scnBelow(2) == 0 ? 0x1B : 0x1C)
                        }
                    }
                }
                if inPolygon { l.op(0x29) }
                if longPolygon {
                    l.op(0x2F); l.op(0x40); l.word(5000); l.word(100)
                    for k in 0..<62 { l.op(0x41); l.word(5000 + 7 * k); l.word(100 + 11 * (k % 9)) }
                    l.op(0x29)
                }
                l.end()
                // The vertex cache entries 0-7: some valid, some clipped.
                for e in 0..<8 where rng.scnBelow(3) == 0 {
                    for k in 0..<8 { rig.poke(0x0400 + 8 * e + k, UInt8(rng.scnBelow(256))) }
                }
                SCN.load(rig, l.bytes, at: l.base)
                // Degenerate random polygons can make the original overwrite its own code
                // (`render3d.md`); such cases are skipped, not compared.
                rig.poke16(0x8B, UInt16(l.base))
                guard R3D.returns(rig, 0x8742, maxCycles: 40_000_000) else { skipped += 1; continue }
                SCN.runList(rig, at: l.base, label)
            }
            rig.expectCleanSCN("geometry")
            #expect(skipped < 10, "\(skipped) rounds skipped")
        }
    }

    /// Radio records: op 1D (NAV/LOC, both slots), op 1E (ATIS; the hook $802D runs the ported
    /// composer $F16A, `composeAtis`), op 05 (NDB, the ported `ndbHook`), with the searches
    /// active or not and matching or other frequencies.
    @Test func radioRecords() throws {
        let rig = SCN.rig(try SCN.regular())
        var rng = TestRandom(seed: 0x8030)
        for round in 0..<200 {
            let freqs = [0x1390, 0x0910, 0x1080, 0x3515, 0x2000, 0x1490, 0x3615]
            rig.poke16(0x0923, UInt16(freqs[rng.scnBelow(freqs.count)]))
            rig.poke16(0x0925, UInt16(freqs[rng.scnBelow(freqs.count)]))
            rig.poke16(0x08B3, UInt16(freqs[rng.scnBelow(freqs.count)]))
            rig.poke16(0xE7F4, UInt16(freqs[rng.scnBelow(freqs.count)]))
            rig.poke(0x0920, UInt8(rng.scnBelow(2)))
            rig.poke(0x0937, UInt8(rng.scnBelow(2)))
            rig.poke(0x08BD, UInt8(rng.scnBelow(2)))
            var l = DisplayList(at: SCN.list + rng.scnBelow(0x100))
            for _ in 0..<4 {
                switch rng.scnBelow(3) {
                case 0:
                    l.op(0x1D); l.word(freqs[rng.scnBelow(freqs.count)]); l.long(Int(rng.next() >> 32)); l.long(Int(rng.next() >> 32))
                case 1:
                    let text = Array("TEST ATIS RECORD".utf8) + [0]
                    l.op(0x1E, UInt8(13 + text.count), 0); l.word(freqs[rng.scnBelow(freqs.count)])
                    for _ in 0..<8 { l.op(UInt8(rng.scnBelow(256))) }
                    l.bytes += text
                default:
                    l.op(0x05); l.word(freqs[rng.scnBelow(freqs.count)])
                    for _ in 0..<6 { l.op(UInt8(rng.scnBelow(256))) }
                }
            }
            l.end()
            SCN.load(rig, l.bytes, at: l.base)
            // $8730 copies the requests to the per-pass flags first.
            rig.poke16(0x8B, UInt16(l.base))
            SCN.run(rig, 0x8730, "records round \(round)") { m throws(Scenery.Fault) in try m.runScenery() }
        }
        rig.expectCleanSCN("records")
    }

    /// The 10 Hz poll when the tick is due (`$0E6B` ≥ 6): one tick per poll, the tick body
    /// $2348 (`tick10Hz`). The flat bus has no I/O: both sides read the TOD seconds from the
    /// same RAM byte, set to the last second seen, and the engine and the bomb whistle are at
    /// rest, so the tick writes no SID register (whose stores would land in the flat bus's RAM).
    /// The tick's own cases are in `MainLoopTests.tick10Hz`.
    @Test func pollTickDue() throws {
        let rig = SCN.rig(try SCN.regular())
        rig.machine.ioReadHook = { [unowned machine = rig.machine] address, _ in machine.mem[address] }
        rig.poke(0xDC09, rig.machine.mem[0x0E6D])
        rig.poke(0x09BE, rig.machine.mem[0x0E58])
        rig.poke(0x0E7E, 0xFF)
        for (round, divider) in [6, 7, 11, 12, 13, 18, 0x40].enumerated() {
            rig.poke(0x0E6B, UInt8(divider))
            var l = DisplayList(at: SCN.list)
            for _ in 0..<5 { l.op(0x11) }
            l.end()
            SCN.load(rig, l.bytes, at: l.base)
            SCN.runList(rig, at: l.base, "poll \(round)")
        }
        rig.expectCleanSCN("poll")
    }

    /// An opcode whose handler is $8778 stops the port with `Scenery.Fault.invalidOpcode`
    /// (the original calls the fatal error $7303).
    @Test func invalidOpcode() throws {
        let m = Machine(memory: try SCN.regular())
        let unused: [UInt8] = [0x08, 0x0C, 0x0E, 0x0F, 0x10, 0x15, 0x16, 0x17, 0x1F, 0x26, 0x27, 0x2A, 0x2C, 0x2D, 0x2E,
                               0x30, 0x34, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x43, 0x44, 0x45]
        for op in unused {
            #expect(m.u16(Scenery.opcodeHandlers + 2 * Int(op)) == 0x8778, "opcode \(hex(op))")
            m.mem[SCN.list] = 0x11
            m.mem[SCN.list + 1] = op
            m.setU16(0x8B, UInt16(SCN.list))
            #expect(throws: Scenery.Fault.invalidOpcode(op, at: UInt16(SCN.list + 1))) { try m.dlInterpreter() }
        }
    }
}
