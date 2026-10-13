import FS2Core
import Testing

/// Unit tests of the math library ports that need no disk image: the documented results,
/// quirks and cycle costs. The differential tests (DifferentialTests/MathDiffTests.swift) prove
/// the ports against the original routines.
struct MathTests {
    /// A machine with all-zero memory.
    static func machine() -> Machine { Machine(memory: [UInt8](repeating: 0, count: Machine.memorySize)) }

    static func q15(_ m: Machine, _ p: Int16, _ n: Int16) -> (value: Int16, cycles: UInt64) {
        m.setS16(0xC4, p); m.setS16(0xC6, n)
        let start = m.clock.cycles
        let r = m.mulQ15()
        return (Int16(bitPattern: Machine.word(r.a, r.x)), m.clock.cycles - start)
    }

    // MARK: $16C9 family

    @Test func mulQ15ReconVectors() {
        let m = Self.machine()
        #expect(Self.q15(m, 1000, 1000) == (29, 336))
        #expect(Self.q15(m, 546, 10000) == (166, 291))
        #expect(Self.q15(m, 32767, 32767) == (32765, 416))
    }

    @Test func mulQ15ZeroShortcutTouchesNothing() {
        let m = Self.machine()
        m[0xA7] = 0x55
        m.setS16(0xC4, 0); m.setS16(0xC6, 1234)
        var before = m.memoryImage
        var r = m.mulQ15()
        #expect(r.a == 0 && r.x == 0 && r.y == nil && m.clock.cycles == 17 && m.memoryImage == before)
        m.setS16(0xC4, -5); m.setS16(0xC6, 0)
        before = m.memoryImage
        r = m.mulQ15()
        #expect(r.a == 0 && r.x == 0 && r.y == nil && m.clock.cycles == 17 + 24 && m.memoryImage == before)
    }

    @Test func mulQ15IsSignSymmetricAndClose() {
        let m = Self.machine()
        var rng = SplitMix(seed: 1)
        for _ in 0..<20_000 {
            let p = Int16(truncatingIfNeeded: rng.next()), n = Int16(truncatingIfNeeded: rng.next())
            guard p != .min, n != .min else { continue }
            let v = Self.q15(m, p, n).value
            #expect(Self.q15(m, -p, n).value == -v)
            #expect(Self.q15(m, p, -n).value == -v)
            let exact = Double(p) * Double(n) / 32768
            #expect(abs(Double(v) - exact) < 2, "\(p) x \(n) = \(v), exact \(exact)")
        }
    }

    @Test func mulQ15SideEffectsAndSaturation() {
        let m = Self.machine()
        // −32768 as the first operand acts as −32767; the product sign still comes from both.
        #expect(Self.q15(m, .min, 16384).value == Self.q15(m, -32767, 16384).value)
        // The result side effects: $A7 = low byte, $C6:$C7 = |n|, $A8 = high byte before negation.
        let r = Self.q15(m, -1000, 1000).value
        #expect(r == -29)
        #expect(m[0xA7] == UInt8(bitPattern: Int8(truncatingIfNeeded: r)))
        #expect(m.s16(0xC6) == 1000 && m[0xA8] == 0)
        _ = Self.q15(m, 1000, -32768)
        #expect(m.u16(0xC6) == 0x7FFF)
    }

    @Test func mulQ15EntriesStoreOperandsAndChain() {
        let m = Self.machine()
        let plain = Self.q15(m, 16384, 16384)                  // 0.5 × 0.5
        #expect(plain.value == 0x2000)
        m.setS16(0xC4, 16384)
        var start = m.clock.cycles
        let r = m.mulQ15AX(a: 0x00, x: 0x40)
        #expect(Machine.word(r.a, r.x) == 0x2000 && m.u16(0xC6) == 0x4000)
        #expect(m.clock.cycles - start == plain.cycles + 9)
        m.setS16(0xC4, 16384)
        start = m.clock.cycles
        let c = m.mulQ15Chain(a: 0x00, x: 0x40)
        #expect(Machine.word(c.a, c.x) == 0x2000 && m.u16(0xC4) == 0x2000)
        #expect(m.clock.cycles - start == plain.cycles + 24)
    }

    @Test func mulZeroPageAddressingWraps() {
        let m = Self.machine()
        m.setS16(0x10, 16384); m.setS16(0x20, 16384)
        let r = m.mulZeroPage(a: 0x30, x: 0x10, y: 0x20)
        #expect(m.s16(0x30) == 8192 && r.y == 0x30 && m[0xA5] == 0x30)
        // Destination $FF: low byte at $00FF, high byte wraps to $0000.
        m.mulZeroPage(a: 0xFF, x: 0x10, y: 0x20)
        #expect(m[0xFF] == 0x00 && m[0x00] == 0x20)
        // Second source $FF reads its high byte from $0100 (abs,Y), first source $FF from $0000.
        m[0xFF] = 0x00; m[0x100] = 0x40; m[0x00] = 0x40
        let start = m.clock.cycles
        m.mulZeroPage(a: 0x30, x: 0xFF, y: 0xFF)
        #expect(m.s16(0x30) == 8192)
        let mulCycles = m.clock.cycles - start - 56
        #expect(mulCycles > 200 && mulCycles < 500)
    }

    // MARK: $1802

    static func div(_ m: Machine, _ n: Int16, _ d: Int16) -> (value: Int16, cycles: UInt64) {
        m.setS16(0xC6, d)
        let u = UInt16(bitPattern: n)
        let start = m.clock.cycles
        m.divQ15(a: UInt8(u >> 8), x: UInt8(u & 0xFF))
        return (m.s16(0xC4), m.clock.cycles - start)
    }

    @Test func divQ15ReconVectors() {
        let m = Self.machine()
        #expect(Self.div(m, 100, 300) == (10922, 728))
        #expect(Self.div(m, 1000, 2000) == (16384, 697))
        #expect(Self.div(m, -100, 300).value == -10922)
        #expect(Self.div(m, 100, -300).value == -10922)
        #expect(Self.div(m, -100, -300).value == 10922)
    }

    @Test func divQ15HasTwoLSBResolutionAndSaturatesAtOne() {
        let m = Self.machine()
        var rng = SplitMix(seed: 2)
        for _ in 0..<20_000 {
            let d = Int16(truncatingIfNeeded: rng.next() | 1)
            guard d != .min, abs(Int(d)) < 0x4000 else { continue }
            let n = Int16(Int(rng.next() % UInt64(abs(Int(d)))))
            let q = Self.div(m, n, d).value
            #expect(q & 1 == 0)
            let exact = Double(n) * 32768 / Double(d)
            #expect(abs(Double(q) - exact) < 2, "\(n) / \(d) = \(q), exact \(exact)")
        }
        #expect(Self.div(m, 1234, 1234).value == 0x7FFF)       // n = d: $8000 patched to $7FFF
        #expect(m.u16(0xC6) == 1234)
    }

    // MARK: $188A, $1881, $19D5

    @Test func mulU16IsExact() {
        let m = Self.machine()
        var rng = SplitMix(seed: 3)
        for _ in 0..<5_000 {
            let a = UInt16(truncatingIfNeeded: rng.next()), b = UInt16(truncatingIfNeeded: rng.next())
            m.setU16(0xC4, a)
            let start = m.clock.cycles
            let r = m.mulU16(a: UInt8(b & 0xFF), x: UInt8(b >> 8))
            let p = UInt32(a) * UInt32(b)
            #expect(m.u32(0xC8) == p && m.u16(0xC4) == 0 && m.u16(0xC6) == b)
            #expect(r.a == UInt8(truncatingIfNeeded: p >> 8) && r.x == UInt8(truncatingIfNeeded: p >> 16))
            #expect(m.clock.cycles - start == UInt64(635 + 16 * a.nonzeroBitCount))
        }
    }

    @Test func asr16AndNegate16() {
        let m = Self.machine()
        for v in 0..<0x10000 {
            let a = UInt8(v & 0xFF), x = UInt8(v >> 8), s = Int16(bitPattern: UInt16(v))
            let r = Machine.asr16(a: a, x: x)
            #expect(Int16(bitPattern: Machine.word(r.a, r.x)) == s >> 1 && r.y == a && r.carry == (v & 1 != 0))
            let n = Machine.negate16(a: a, x: x)
            #expect(Machine.word(n.a, n.x) == 0 &- UInt16(v) && n.y == n.a)
        }
        m.asr16(a: 1, x: 2)
        #expect(m.clock.cycles == 20)
        m.negate16(a: 0, x: 2)
        #expect(m.clock.cycles == 44)
    }

    // MARK: $196D, $1961, $19E2

    static func mul8(_ m: Machine, _ x: Int8, _ y: Int8, carry: Bool) -> Int16 {
        let r = m.mul8x8(x: UInt8(bitPattern: x), y: UInt8(bitPattern: y), carry: carry)
        return Int16(bitPattern: Machine.word(r.a, r.y))
    }

    @Test func mul8x8BiasQuirks() {
        let m = Self.machine()
        #expect(Self.mul8(m, 1, 1, carry: true) == 3)
        #expect(Self.mul8(m, 1, 1, carry: false) == 2)
        #expect(Self.mul8(m, 3, 5, carry: true) == 31)
        #expect(Self.mul8(m, 10, 20, carry: false) == 400)
        #expect(Self.mul8(m, 100, 100, carry: true) == 20001)
        #expect(Self.mul8(m, 0, 0, carry: true) == 1)
        // y < 0 with x ≥ 0 always adds the bias (the carry its sign handling leaves), whatever the
        // carry passed in.
        #expect(Self.mul8(m, 3, -5, carry: false) == -31)
        #expect(Self.mul8(m, 0, -5, carry: false) == -1)
        // x < 0 never does.
        #expect(Self.mul8(m, -3, 5, carry: true) == -30)
        #expect(Self.mul8(m, -3, -5, carry: true) == 30)
        // −128 counts as 127.
        #expect(Self.mul8(m, -128, 1, carry: false) == -254)
        #expect(Self.mul8(m, 1, -128, carry: false) == -255)
        #expect(m[0xC4] == 1 && m[0xA5] == 0x80 && m.u16(0xC6) == 255)   // magnitude, never negated
    }

    @Test func mul8x8MatchesItsClosedForm() {
        let m = Self.machine()
        for v in 0..<0x10000 {
            let x = Int8(truncatingIfNeeded: v), y = Int8(truncatingIfNeeded: v >> 8)
            for carry in [false, true] {
                let xm = x == .min ? 127 : abs(Int(x)), ym = y == .min ? 127 : abs(Int(y))
                let bias = x < 0 ? 0 : (y < 0 ? 1 : (carry ? 1 : 0))
                let magnitude = 2 * xm * ym + bias
                let expected = (x < 0) != (y < 0) ? -magnitude : magnitude
                #expect(Int(Self.mul8(m, x, y, carry: carry)) == expected)
                let h = m.mul8Half(x: UInt8(bitPattern: x), y: UInt8(bitPattern: y), carry: carry)
                #expect(Int(Int16(bitPattern: Machine.word(h.a, h.y))) == expected >> 1)
            }
        }
    }

    @Test func interpBySpeedInterpolatesInEighthSteps() {
        let m = Self.machine()
        let table = 0x0E10
        for (i, v) in [10, 20, 40, 30, 30, 200, 0, 255, 1, 2, 3, 4, 5, 6, 7, 8, 9].enumerated() {
            m[table + i] = UInt8(v)
        }
        m.setU16(0xBA, UInt16(table))
        func at(_ speed: UInt8) -> UInt16 {
            m[0x0A4D] = speed
            let r = m.interpBySpeed()
            #expect(r.a == m[0xC5])
            return m.u16(0xC4)
        }
        #expect(at(0x00) == 10 << 8)                              // exact entries
        #expect(at(0x10) == 20 << 8)
        #expect(at(0x08) == 15 << 8)                              // halfway, rising
        #expect(at(0x18) == 30 << 8)
        // Halfway from 40 down to 30: mul8Half(64, −10) = −641 (the x ≥ 0 > y bias), so
        // 40·256 − 1282 = 8958 instead of 35·256 = 8960.
        #expect(at(0x28) == 8958)
        // 200 → 0: the 8-bit difference wraps to +56, so it interpolates upward: 200·256 + 7168.
        #expect(at(0x58) == 0xE400)
        #expect(m[0xBE] == 200)
    }

    // MARK: Trig (synthetic table; the real one is tested against the original)

    /// Fills the cosine table area with t[i] = 32000 − 500·i, then makes entries 10 and 11
    /// negative to expose the averaging carry quirk.
    static func trigMachine() -> Machine {
        let m = machine()
        for i in 0..<Machine.cosTableCount { m.setS16(Machine.cosTableAddress + 2 * i, Int16(32000 - 500 * i)) }
        return m
    }

    static func cos(_ m: Machine, _ angle: UInt16) -> Int16 {
        let r = m.cos16(a: UInt8(angle >> 8), x: UInt8(angle & 0xFF))
        return Int16(bitPattern: Machine.word(r.a, r.x))
    }

    static func sin(_ m: Machine, _ angle: UInt16) -> Int16 {
        let r = m.sin16(a: UInt8(angle >> 8), x: UInt8(angle & 0xFF))
        return Int16(bitPattern: Machine.word(r.a, r.x))
    }

    @Test func cosReadsTheTableFromMemory() {
        let m = Self.trigMachine()
        for i in 0...64 {
            #expect(Self.cos(m, UInt16(i) << 8) == m.cosTableEntry(i))
        }
        for i in 0..<64 {                                         // X = $80: the average
            #expect(Self.cos(m, UInt16(i) << 8 | 0x80) == Int16((Int(m.cosTableEntry(i)) + Int(m.cosTableEntry(i + 1))) / 2))
        }
        // X = 1: (X >> 1) = 0, so the interpolation adds nothing.
        #expect(Self.cos(m, 0x0501) == m.cosTableEntry(5))
        // Interpolation between entries 5 and 6 (difference −500) at X = $40: about a quarter.
        let q = Self.cos(m, 0x0540)
        #expect(q <= m.cosTableEntry(5) - 122 && q >= m.cosTableEntry(5) - 128)
        let start = m.clock.cycles
        _ = Self.cos(m, 0x1900)
        #expect(m.clock.cycles - start == 33)
    }

    @Test func averageDropsTheSeventeenthBit() {
        let m = Self.trigMachine()
        m.setS16(Machine.cosTableAddress + 20, -2)
        m.setS16(Machine.cosTableAddress + 22, -4)
        // $FFFE + $FFFC = $1FFFA; the carry is lost and the right shift brings in a 0: $7FFD.
        #expect(Self.cos(m, 0x0A80) == 0x7FFD)
        #expect(m[0xBE] == 0xFA)
    }

    @Test func quadrantsFoldBySymmetry() {
        let m = Self.trigMachine()
        for angle in stride(from: 0, to: 0x10000, by: 7) {
            let a = UInt16(angle)
            if a != 0x8000 {
                #expect(Self.cos(m, 0 &- a) == Self.cos(m, a), "cos even at \(a)")
            }
            #expect(Self.sin(m, a) == Self.cos(m, a &- 0x4000), "sin at \(a)")
            if a > 0, a < 0x4000 {
                #expect(Self.cos(m, 0x8000 &- a) == -Self.cos(m, a), "second quadrant at \(a)")
            }
        }
        #expect(Self.cos(m, 0x8000) == Self.cos(m, 0x7FFF))
        // The 8- and 9-bit entries.
        let c8 = m.cos8(a: 0x12), s8 = m.sin8(a: 0x12)
        #expect(Machine.word(c8.a, c8.x) == UInt16(bitPattern: Self.cos(m, 0x1200)))
        #expect(Machine.word(s8.a, s8.x) == UInt16(bitPattern: Self.sin(m, 0x1200)))
        let c9 = m.cos9(a: 0xFF, y: 0x12), s9 = m.sin9(a: 0x7F, y: 0x12)
        #expect(Machine.word(c9.a, c9.x) == UInt16(bitPattern: Self.cos(m, 0x1280)))
        #expect(Machine.word(s9.a, s9.x) == UInt16(bitPattern: Self.sin(m, 0x1200)))
    }
}

/// Deterministic test numbers (SplitMix64).
fileprivate struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
