import FS2Core
import FS2LabKit
import Foundation
import Testing

typealias MathRig = DiffRig


fileprivate extension TestRandom {
    mutating func word() -> UInt16 { UInt16(truncatingIfNeeded: next() >> 24) }
    mutating func bool() -> Bool { next() & 0x100 != 0 }
    /// A word that is an edge value a quarter of the time, otherwise random.
    mutating func edgeOrRandomWord() -> UInt16 {
        next() & 3 == 0 ? edgeWords[Int(next() % UInt64(edgeWords.count))] : word()
    }
}

/// Words that exercise the sign, saturation and carry edges of the 16-bit routines.
fileprivate let edgeWords: [UInt16] = {
    var v: Set<UInt16> = [0, 1, 2, 3, 5, 0x7F, 0x80, 0xFF, 0x100, 0x101, 0x3FFF, 0x4000, 0x4001,
                          0x7FFE, 0x7FFF, 0x8000, 0x8001, 0x8002, 0xBFFF, 0xC000, 0xFF00, 0xFF01,
                          0xFFFE, 0xFFFF, 546, 1000, 10000, 300, 100, 2000, 12345]
    for k in 0..<16 { v.insert(1 << k); v.insert(0 &- UInt16(1 << k)); v.insert(UInt16(1 << k) &- 1) }
    return v.sorted()
}()

@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct MathDiffTests {
    /// The running game at Meigs: realistic zero page and the loaded math library and tables.
    static let flight: [UInt8] = (try? Original.regularFlight()) ?? Original.data!.coldMemory

    // MARK: Recon vectors

    @Test func reconVectors() throws {
        let rig = MathRig(Self.flight)
        func mul(_ m: UInt16, _ n: UInt16) -> Int16 {
            rig.poke16(0xC4, m); rig.poke16(0xC6, n)
            let o = rig.run(0x16C9, .init(), "mul") { m in
                let r = m.mulQ15(); return .init(a: r.a, x: r.x)
            }
            return Int16(bitPattern: Machine.word(o.registers.a, o.registers.x))
        }
        func div(_ n: UInt16, _ d: UInt16) -> Int16 {
            rig.poke16(0xC6, d)
            rig.run(0x1802, .init(a: UInt8(n >> 8), x: UInt8(n & 0xFF)), "div") { m in
                let r = m.divQ15(a: UInt8(n >> 8), x: UInt8(n & 0xFF)); return .init(a: r.a, x: r.x, y: r.y)
            }
            return Int16(bitPattern: Machine.word(rig.harness.bus.ram[0xC4], rig.harness.bus.ram[0xC5]))
        }
        func trig(_ address: UInt16, _ angle: UInt16) -> Int16 {
            let hi = UInt8(angle >> 8), lo = UInt8(angle & 0xFF)
            let o = rig.run(address, .init(a: hi, x: lo), "trig") { m in
                let r = address == 0x18CD ? m.sin16(a: hi, x: lo) : m.cos16(a: hi, x: lo)
                return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
            }
            return Int16(bitPattern: Machine.word(o.registers.a, o.registers.x))
        }
        #expect(mul(1000, 1000) == 29)
        #expect(mul(546, 10000) == 166)
        #expect(mul(32767, 32767) == 32765)
        #expect(div(100, 300) == 10922)
        #expect(div(1000, 2000) == 16384)
        #expect(trig(0x18CD, 0x1234) == 14156)        // $18CD sin16, A = $12, X = $34
        #expect(trig(0x18D0, 0x1900) == 26489)        // $18D0 cos16: the entry-25 glitch
        rig.expectClean("recon vectors")
    }

    // MARK: Q15 multiply family

    @Test func mulQ15MatchesOriginal() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x16C9)
        func one(_ m: UInt16, _ n: UInt16, _ y: UInt8) {
            rig.poke16(0xC4, m); rig.poke16(0xC6, n)
            rig.run(0x16C9, .init(y: y), "mulQ15(\(m), \(n))") { mm in
                let r = mm.mulQ15(); return .init(a: r.a, x: r.x, y: r.y ?? y)
            }
        }
        for m in edgeWords { for n in edgeWords { one(m, n, rng.byte()) } }
        for _ in 0..<60_000 { one(rng.word(), rng.word(), rng.byte()) }
        // Small magnitudes, where the high-byte-only bits 0-5 dominate.
        for _ in 0..<20_000 {
            one(rng.word() >> (rng.byte() & 15) ^ (rng.bool() ? 0xFFFF : 0),
                rng.word() >> (rng.byte() & 15) ^ (rng.bool() ? 0xFFFF : 0), rng.byte())
        }
        rig.expectClean("$16C9 mulQ15")
    }

    @Test func mulQ15EntriesMatchOriginal() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x17EF)
        for i in 0..<40_000 {
            let m = i < edgeWords.count * 4 ? edgeWords[i % edgeWords.count] : rng.word()
            let n = i < edgeWords.count * 4 ? edgeWords[(i / 4 * 7) % edgeWords.count] : rng.word()
            let y = rng.byte()
            let a = UInt8(n & 0xFF), x = UInt8(n >> 8)
            rig.poke16(0xC4, m)
            rig.run(0x17EF, .init(a: a, x: x, y: y), "mulQ15AX(\(m), \(n))") { mm in
                let r = mm.mulQ15AX(a: a, x: x); return .init(a: r.a, x: r.x, y: r.y ?? y)
            }
            rig.poke16(0xC4, m)
            rig.run(0x17F6, .init(a: a, x: x, y: y), "mulQ15Chain(\(m), \(n))") { mm in
                let r = mm.mulQ15Chain(a: a, x: x); return .init(a: r.a, x: r.x, y: r.y ?? y)
            }
        }
        // Chained products, as the flight model uses them.
        rig.poke16(0xC4, 0x7123)
        for _ in 0..<2_000 {
            let n = rng.word(), a = UInt8(n & 0xFF), x = UInt8(n >> 8)
            rig.run(0x17F6, .init(a: a, x: x), "chain \(n)") { mm in
                let r = mm.mulQ15Chain(a: a, x: x); return .init(a: r.a, x: r.x)
            }
            if rig.harness.bus.ram[0xC4] | rig.harness.bus.ram[0xC5] == 0 { rig.poke16(0xC4, rng.word()) }
        }
        rig.expectClean("$17EF/$17F6")
    }

    @Test func mulZeroPageMatchesOriginal() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x16AA)
        // Every destination and source, including $FF (wrapping / $0100) and the routine's own
        // temporaries $A5 and $C4-$C7 as operands.
        let special: [UInt8] = [0x00, 0x01, 0xA4, 0xA5, 0xA6, 0xA7, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xFE, 0xFF]
        for i in 0..<30_000 {
            let d = i < 256 ? UInt8(i) : (rng.bool() ? special[Int(rng.byte()) % special.count] : rng.byte())
            let s1 = i < 512 ? UInt8(i & 0xFF) : (rng.bool() ? special[Int(rng.byte()) % special.count] : rng.byte())
            let s2 = i < 768 ? UInt8(i & 0xFF) : (rng.bool() ? special[Int(rng.byte()) % special.count] : rng.byte())
            for adr in [Int(s1), Int(s1 &+ 1), Int(s2), Int(s2) + 1] {
                if adr != 0x01FF && adr != 0x01FE { rig.poke(adr, rng.byte()) }
            }
            rig.run(0x16AA, .init(a: d, x: s1, y: s2), "mulZeroPage(\(hex(d)), \(hex(s1)), \(hex(s2)))") { m in
                let r = m.mulZeroPage(a: d, x: s1, y: s2); return .init(a: r.a, x: r.x, y: r.y)
            }
        }
        rig.expectClean("$16AA mulZeroPage")
    }

    // MARK: Divide and unsigned multiply

    @Test func divQ15MatchesOriginal() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x1802)
        func one(_ n: UInt16, _ d: UInt16) {
            rig.poke16(0xC6, d)
            let hi = UInt8(n >> 8), lo = UInt8(n & 0xFF), y = rng.byte()
            rig.run(0x1802, .init(a: hi, x: lo, y: y), "divQ15(\(Int16(bitPattern: n)), \(Int16(bitPattern: d)))") { m in
                let r = m.divQ15(a: hi, x: lo); return .init(a: r.a, x: r.x, y: r.y)
            }
        }
        for n in edgeWords { for d in edgeWords { one(n, d) } }
        for _ in 0..<40_000 { one(rng.word(), rng.word()) }
        // Valid inputs (|n| < |d|), the range callers use.
        for _ in 0..<40_000 {
            let d = rng.word() | 1
            let mag = Int(Int16(bitPattern: d)).magnitude
            let n = UInt16(truncatingIfNeeded: Int(rng.next() % UInt64(mag)) * (rng.bool() ? -1 : 1))
            one(n, d)
        }
        rig.expectClean("$1802 divQ15")
    }

    @Test func mulU16MatchesOriginal() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x188A)
        func one(_ m: UInt16, _ n: UInt16) {
            rig.poke16(0xC4, m)
            rig.poke16(0xC8, rng.word())                       // stale low product bytes
            let a = UInt8(n & 0xFF), x = UInt8(n >> 8), y = rng.byte()
            rig.run(0x188A, .init(a: a, x: x, y: y), "mulU16(\(m), \(n))") { mm in
                let r = mm.mulU16(a: a, x: x); return .init(a: r.a, x: r.x, y: y)
            }
        }
        for m in edgeWords { for n in edgeWords { one(m, n) } }
        for _ in 0..<40_000 { one(rng.word(), rng.word()) }
        rig.expectClean("$188A mulU16")
    }

    @Test func shiftAndNegateMatchOriginal() throws {
        let rig = MathRig(Self.flight)
        for v in 0..<0x10000 {
            let a = UInt8(v & 0xFF), x = UInt8(v >> 8)
            rig.run(0x1881, .init(a: a, x: x), "asr16(\(v))") { m in
                let r = m.asr16(a: a, x: x); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
            }
            rig.run(0x19D5, .init(a: a, x: x), "negate16(\(v))") { m in
                let r = m.negate16(a: a, x: x); return .init(a: r.a, x: r.x, y: r.y)
            }
        }
        rig.expectClean("$1881/$19D5")
    }

    // MARK: 8x8 multiplies and the speed table interpolation

    @Test func mul8x8MatchesOriginalExhaustively() throws {
        let rig = MathRig(Self.flight)
        for v in 0..<0x10000 {
            let x = UInt8(v & 0xFF), y = UInt8(v >> 8)
            for carry in [false, true] {
                rig.run(0x196D, .init(x: x, y: y, carry: carry), "mul8x8(\(hex(x)), \(hex(y)), c=\(carry))") { m in
                    let r = m.mul8x8(x: x, y: y, carry: carry); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
            }
        }
        rig.expectClean("$196D mul8x8")
    }

    @Test func mul8HalfMatchesOriginalExhaustively() throws {
        let rig = MathRig(Self.flight)
        for v in 0..<0x10000 {
            let x = UInt8(v & 0xFF), y = UInt8(v >> 8)
            for carry in [false, true] {
                rig.run(0x1961, .init(x: x, y: y, carry: carry), "mul8Half(\(hex(x)), \(hex(y)), c=\(carry))") { m in
                    let r = m.mul8Half(x: x, y: y, carry: carry); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
            }
        }
        rig.expectClean("$1961 mul8Half")
    }

    /// Points ($BA) at `table`, sets the airspeed high byte, and runs $19E2 on both sides with
    /// random incoming registers.
    static func interp(_ rig: MathRig, _ rng: inout TestRandom, _ table: UInt16, _ speed: UInt8) {
        rig.poke16(0xBA, table); rig.poke(0x0A4D, speed)
        rig.run(0x19E2, .init(a: rng.byte(), x: rng.byte(), y: rng.byte(), carry: rng.bool()),
                "interpBySpeed(\(String(table, radix: 16)), \(hex(speed)))") { m in
            let r = m.interpBySpeed(); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
        }
    }

    @Test func interpBySpeedMatchesOriginal() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x19E2)
        func one(_ table: UInt16, _ speed: UInt8) { Self.interp(rig, &rng, table, speed) }
        // The game's own gain tables, every speed.
        for table: UInt16 in [0x0E10, 0x0E1A, 0x0E24, 0x0E2E, 0x0E42] {
            for speed in 0..<256 { one(table, UInt8(speed)) }
        }
        // Random tables anywhere in $0300-$03FF, so reads at $03F0 and up cross into page 4.
        for _ in 0..<20_000 {
            let base = 0x0300 + UInt16(rng.byte())
            for k in 0..<17 { rig.poke(Int(base) + k, rng.byte()) }
            one(base, rng.byte())
        }
        rig.expectClean("$19E2 interpBySpeed")
    }

    /// Tables that wrap past $FFFF (the `(zp),Y` address wraps into page 0, with a page-crossing
    /// cycle), and tables in page 0 that overlap the routine's own pointer `$BA:$BB`, its scratch
    /// byte `$BE` (written between the two table reads) and the 8x8 temporaries.
    @Test func interpBySpeedWrapsAndOverlapsZeroPage() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x19E3)
        for k in 0..<12_000 {
            let base: UInt16 = k & 1 == 0 ? 0xFFEF &+ UInt16(rng.byte() & 0x1F) : 0x00A8 + UInt16(rng.byte() & 0x1F)
            for j in 0..<17 { rig.poke((Int(base) + j) & 0xFFFF, rng.byte()) }
            Self.interp(rig, &rng, base, rng.byte())
        }
        rig.expectClean("$19E2 wrapping and zero-page tables")
    }

    // MARK: Operand sweeps

    /// Every value of one Q15 operand, against a partner that is an edge value a quarter of the
    /// time and random otherwise (sign handling, the $8000 cases and the zero shortcut of each
    /// operand, whatever the other one is).
    @Test(arguments: [false, true]) func mulQ15SweepsEveryOperand(sweepSecond: Bool) throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: sweepSecond ? 0x16CA : 0x16CB)
        for v in 0..<0x10000 {
            let other = rng.edgeOrRandomWord()
            let m = sweepSecond ? other : UInt16(v), n = sweepSecond ? UInt16(v) : other
            let y = rng.byte()
            rig.poke16(0xC4, m); rig.poke16(0xC6, n)
            rig.run(0x16C9, .init(y: y, carry: rng.bool()), "mulQ15(\(m), \(n))") { mm in
                let r = mm.mulQ15(); return .init(a: r.a, x: r.x, y: r.y ?? y)
            }
        }
        rig.expectClean("$16C9 sweep of the \(sweepSecond ? "second" : "first") operand")
    }

    /// Every dividend (or every divisor) against a random partner, half the time chosen so that
    /// |n| < |d|, the range the callers use.
    @Test(arguments: [false, true]) func divQ15SweepsEveryOperand(sweepDivisor: Bool) throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: sweepDivisor ? 0x1803 : 0x1804)
        func magnitude(_ w: UInt16) -> Int { Int(Int16(bitPattern: w).magnitude) }
        func signed(_ mag: Int, _ negative: Bool) -> UInt16 { UInt16(truncatingIfNeeded: negative ? -mag : mag) }
        for v in 0..<0x10000 {
            var n = rng.edgeOrRandomWord(), d = rng.edgeOrRandomWord()
            let valid = rng.bool()
            if sweepDivisor {
                d = UInt16(v)
                if valid, magnitude(d) > 0 { n = signed(Int(rng.next() % UInt64(magnitude(d))), rng.bool()) }
            } else {
                n = UInt16(v)
                if valid, magnitude(n) < 0x8000 {
                    d = signed(magnitude(n) + 1 + Int(rng.next() % UInt64(0x8000 - magnitude(n))), rng.bool())
                }
            }
            rig.poke16(0xC6, d)
            let hi = UInt8(n >> 8), lo = UInt8(n & 0xFF)
            rig.run(0x1802, .init(a: hi, x: lo, y: rng.byte(), carry: rng.bool()),
                    "divQ15(\(Int16(bitPattern: n)), \(Int16(bitPattern: d)))") { m in
                let r = m.divQ15(a: hi, x: lo); return .init(a: r.a, x: r.x, y: r.y)
            }
        }
        rig.expectClean("$1802 sweep of the \(sweepDivisor ? "divisor" : "dividend")")
    }

    /// Every multiplicand (whose set bits set the cycle count) and every multiplier, against a
    /// random partner and stale low product bytes.
    @Test(arguments: [false, true]) func mulU16SweepsEveryOperand(sweepSecond: Bool) throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: sweepSecond ? 0x188B : 0x188C)
        for v in 0..<0x10000 {
            let other = rng.edgeOrRandomWord()
            let m = sweepSecond ? other : UInt16(v), n = sweepSecond ? UInt16(v) : other
            rig.poke16(0xC4, m)
            rig.poke16(0xC8, rng.word()); rig.poke16(0xCA, rng.word())
            let a = UInt8(n & 0xFF), x = UInt8(n >> 8), y = rng.byte()
            rig.run(0x188A, .init(a: a, x: x, y: y, carry: rng.bool()), "mulU16(\(m), \(n))") { mm in
                let r = mm.mulU16(a: a, x: x); return .init(a: r.a, x: r.x, y: y)
            }
        }
        rig.expectClean("$188A sweep of the \(sweepSecond ? "second" : "first") operand")
    }

    // MARK: Sine and cosine

    @Test func cos16AndSin16MatchOriginalForEveryAngle() throws {
        let rig = MathRig(Self.flight)
        for angle in 0..<0x10000 {
            let hi = UInt8(angle >> 8), lo = UInt8(angle & 0xFF)
            rig.run(0x18D0, .init(a: hi, x: lo), "cos16($\(hex16(angle)))") { m in
                let r = m.cos16(a: hi, x: lo); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
            }
            rig.run(0x18CD, .init(a: hi, x: lo), "sin16($\(hex16(angle)))") { m in
                let r = m.sin16(a: hi, x: lo); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
            }
        }
        rig.expectClean("$18D0/$18CD")
    }

    @Test func eightAndNineBitEntriesMatchOriginal() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x18B8)
        for hi in 0..<256 {
            let a = UInt8(hi), x = rng.byte()
            rig.run(0x18B8, .init(a: a, x: x), "cos8(\(hex(a)))") { m in
                let r = m.cos8(a: a); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
            }
            rig.run(0x18BD, .init(a: a, x: x), "sin8(\(hex(a)))") { m in
                let r = m.sin8(a: a); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
            }
            for lo in 0..<256 {                                  // every Y and every A
                let y = UInt8(hi), aa = UInt8(lo), xx = rng.byte()
                rig.run(0x18C2, .init(a: aa, x: xx, y: y), "cos9(\(hex(aa)), \(hex(y)))") { m in
                    let r = m.cos9(a: aa, y: y); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
                rig.run(0x18C9, .init(a: aa, x: xx, y: y), "sin9(\(hex(aa)), \(hex(y)))") { m in
                    let r = m.sin9(a: aa, y: y); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
            }
        }
        rig.expectClean("$18B8/$18BD/$18C2/$18C9")
    }

    /// The trig ports read the cosine table from memory, so they must follow the original for any
    /// table contents, not only the game's. Random tables reach the paths the real (falling,
    /// non-negative) table never does: rising steps, the dropped carry when two negative entries
    /// are averaged, a difference that wraps 16 bits, and a carry out of the interpolation's
    /// final add. Incoming Y and carry are random too (the routines must ignore them).
    @Test func trigMatchesOriginalWithRandomTables() throws {
        let rig = MathRig(Self.flight)
        var rng = TestRandom(seed: 0x158E)
        let extremes: [UInt16] = [0x7FFF, 0x7FFE, 0x8000, 0x8001, 0x0000, 0x0001, 0xFFFF, 0x4000, 0xC000]
        for table in 0..<24 {
            var walk = Int(Int16(bitPattern: rng.word()))
            for i in 0..<Machine.cosTableCount {
                let w: UInt16
                switch table % 4 {
                case 0: w = rng.word()                                     // anything
                case 1: w = rng.word() | 0x8000                            // all negative
                case 2: w = extremes[Int(rng.byte()) % extremes.count]     // saturation edges
                default:                                                   // a random walk
                    walk = max(-32768, min(32767, walk + Int(Int8(bitPattern: rng.byte())) * 32))
                    w = UInt16(bitPattern: Int16(walk))
                }
                rig.poke16(Machine.cosTableAddress + 2 * i, w)
            }
            for _ in 0..<1_500 {
                let angle = rng.word(), hi = UInt8(angle >> 8), lo = UInt8(angle & 0xFF)
                let regs = RoutineHarness.Registers(a: hi, x: lo, y: rng.byte(), carry: rng.bool())
                rig.run(0x18D0, regs, "cos16($\(hex16(Int(angle)))), table \(table)") { m in
                    let r = m.cos16(a: hi, x: lo); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
                rig.run(0x18CD, regs, "sin16($\(hex16(Int(angle)))), table \(table)") { m in
                    let r = m.sin16(a: hi, x: lo); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
            }
            for v in 0..<256 {
                let angle = UInt8(v), a = rng.byte()
                let regs = RoutineHarness.Registers(a: angle, x: rng.byte(), y: rng.byte(), carry: rng.bool())
                rig.run(0x18B8, regs, "cos8(\(hex(angle))), table \(table)") { m in
                    let r = m.cos8(a: angle); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
                rig.run(0x18BD, regs, "sin8(\(hex(angle))), table \(table)") { m in
                    let r = m.sin8(a: angle); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
                let regs9 = RoutineHarness.Registers(a: a, x: rng.byte(), y: angle, carry: rng.bool())
                rig.run(0x18C2, regs9, "cos9(\(hex(a)), \(hex(angle))), table \(table)") { m in
                    let r = m.cos9(a: a, y: angle); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
                rig.run(0x18C9, regs9, "sin9(\(hex(a)), \(hex(angle))), table \(table)") { m in
                    let r = m.sin9(a: a, y: angle); return .init(a: r.a, x: r.x, y: r.y, carry: r.carry)
                }
            }
        }
        rig.expectClean("trig with random cosine tables")
    }

    /// Spot check with the harness's own whole-image comparison (`Original.differences`), from
    /// the cold image as well as the running game.
    @Test func wholeImageSpotCheck() throws {
        var rng = TestRandom(seed: 0xD1FF)
        for base in [Self.flight, Original.data!.coldMemory] {
            for _ in 0..<40 {
                var ram = base
                ram[0xC4] = rng.byte(); ram[0xC5] = rng.byte(); ram[0xC6] = rng.byte(); ram[0xC7] = rng.byte()
                let angle = rng.word(), hi = UInt8(angle >> 8), lo = UInt8(angle & 0xFF)
                let m = Machine(memory: ram)
                m.mulQ15()
                let o = Original.call(0x16C9, ram: ram)
                #expect(Original.differences(m.memoryImage, o.ram).isEmpty)
                let m2 = Machine(memory: ram)
                let r = m2.cos16(a: hi, x: lo)
                let o2 = Original.call(0x18D0, ram: ram, .init(a: hi, x: lo))
                #expect(Original.differences(m2.memoryImage, o2.ram).isEmpty)
                #expect(r.a == o2.result.registers.a && r.x == o2.result.registers.x)
                #expect(m2.clock.cycles == o2.result.cycles)
            }
        }
    }
}
