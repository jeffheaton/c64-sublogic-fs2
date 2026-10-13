/// Sine and cosine of binary angles ($18B8-$1960) from the cosine table at $158E.
///
/// Angles are 16-bit binary ($10000 = 360°), passed as A = high byte and X = low byte. Results
/// are Q15 words in A (low) and X (high). The table holds 66 signed words, cos(i · 1.40625°) for
/// i = 0...65, and is always read from memory: entry 25 ($15C0) is a data glitch of the original
/// that must be reproduced, so the table is never regenerated.
extension Machine {
    /// Address of the 66-word Q15 cosine table.
    public static let cosTableAddress = 0x158E
    /// Number of words in the cosine table (entries 0...65; entry 64 is cos 90°).
    public static let cosTableCount = 66

    /// Entry `i` of the cosine table, read from memory.
    @inline(__always)
    public func cosTableEntry(_ i: Int) -> Int16 { s16(Machine.cosTableAddress + 2 * i) }

    /// $18D0 (`cos16`): cosine of the 16-bit angle A:X (A high).
    ///
    /// - Angles with bit 15 set are negated first (cos is even); $8000, which has no positive
    ///   twin, becomes $7FFF.
    /// - High byte $40-$7F (90°-180°): cos θ = −cos($8000 − θ), via `cosFirstQuadrant` and a
    ///   negate that leaves `$BE:$BF` = the unnegated value.
    /// - Otherwise `cosFirstQuadrant` directly.
    ///
    /// Returns A (low), X (high), Y (the table index, or the result's low byte after an
    /// interpolation or a negate) and the carry, which callers pass on into `mul8x8`/`mul8Half`
    /// ($A3CB → $A3D0, $A3F6 → $A3FB, $E7C2 → $E7CF): clear for an exact entry, the bit the
    /// average shifts out, the carry of the interpolation's high-byte add, or, in the second
    /// quadrant, set only when the result is 0. Cycles are counted exactly: 33 for an exact
    /// entry, up to 514 with a folded, mirrored interpolation.
    @discardableResult
    public func cos16(a high: UInt8, x low: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        var h = high, l = low
        var cycles: Int
        if h & 0x80 != 0 {
            // $18FA: negate the angle.
            h = ~h; l = ~l &+ 1
            if l != 0 {
                cycles = 23
            } else {
                h &+= 1
                if h & 0x80 == 0 {
                    cycles = 29
                } else {
                    h = 0x7F; l = 0xFF                 // $190A: $8000 → $7FFF
                    cycles = 34
                }
            }
        } else {
            cycles = 4
        }
        // $18D4: first quadrant or second (h is 0...$7F here).
        if h < 0x40 {
            charge(cycles + 6)
            return cosFirstQuadrant(a: h, x: l)
        }
        // $18D8: second quadrant, mirrored around 90°. The original first parks the angle in
        // $BE:$BF; every path stores the result there afterwards, so only those final writes
        // are visible and the port makes only them.
        let mirroredLow = 0 &- l
        let mirroredHigh = 0x80 &- h &- (l != 0 ? 1 : 0)
        charge(cycles + 30)
        let r = cosFirstQuadrant(a: mirroredHigh, x: mirroredLow)
        mem[0xBE] = r.a; mem[0xBF] = r.x
        let negated = 0 &- Machine.word(r.a, r.x)
        let lo = UInt8(truncatingIfNeeded: negated)
        charge(30)
        return (lo, UInt8(truncatingIfNeeded: negated >> 8), lo, r.a | r.x == 0)
    }

    /// $18CD (`sin16`): sine of the 16-bit angle A:X, as cos(θ − $4000) (the high byte is
    /// decremented by $40 with 8-bit wrap). 4 cycles + `cos16`.
    @inline(__always) @discardableResult
    public func sin16(a high: UInt8, x low: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        charge(4)
        return cos16(a: high &- 0x40, x: low)
    }

    /// $18B8 (`cos8`): cosine of the 8-bit angle A (the low byte is 0). 5 cycles + `cos16`.
    @inline(__always) @discardableResult
    public func cos8(a angle: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        charge(5)
        return cos16(a: angle, x: 0)
    }

    /// $18BD (`sin8`): sine of the 8-bit angle A (the low byte is 0). 5 cycles + `sin16`.
    @inline(__always) @discardableResult
    public func sin8(a angle: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        charge(5)
        return sin16(a: angle, x: 0)
    }

    /// $18C2 (`cos9`): cosine of the angle Y:(A & $80), a 9-bit angle whose half step selects
    /// the average of two adjacent entries. 9 cycles + `cos16`.
    @inline(__always) @discardableResult
    public func cos9(a halfStep: UInt8, y angle: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        charge(9)
        return cos16(a: angle, x: halfStep & 0x80)
    }

    /// $18C9 (`sin9`): sine of the angle Y:(A & $80) (falls into `sin16`). 6 cycles + `sin16`.
    @inline(__always) @discardableResult
    public func sin9(a halfStep: UInt8, y angle: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        charge(6)
        return sin16(a: angle, x: halfStep & 0x80)
    }

    /// $1911 (`cosFirstQuadrant`): cosine of A:X for A = 0...$40 (0°-90°), entered by branch
    /// from `cos16` or as a subroutine from its second-quadrant path. With i = A and Y = 2i:
    /// - X = 0: entry i exactly (23 cycles, +1 per page-crossing read).
    /// - X = $80: the average of entries i and i+1, computed as a 16-bit sum whose carry out is
    ///   dropped before a logical shift right (`$BE` = the sum's low byte). 48 cycles (+crossings).
    /// - Otherwise: entry i + `mulQ15AX`(entry i+1 − entry i, (X >> 1) << 8), so X = 1 adds
    ///   nothing. `$BE:$BF` = entry i, `$C4:$C5` = the difference before `mulQ15`. 85 cycles
    ///   (+crossings) + `mulQ15AX`.
    /// Returns A (low), X (high), Y (2i, or the result's low byte after an interpolation) and the
    /// carry (clear, the averaged-out bit, or the carry of the final high-byte add).
    func cosFirstQuadrant(a index: UInt8, x fraction: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        let y = index << 1
        let t = Machine.cosTableAddress
        let entry = t + Int(y)
        if fraction == 0 {
            // $192F: exact entry.
            charge(23 + Machine.pageCrossing(t, y) + Machine.pageCrossing(t + 1, y))
            return (mem[entry], mem[entry + 1], y, false)   // doubling A ≤ $40 clears the carry
        }
        if fraction & 0x7F == 0 {
            // $191A: half step. The high-byte add's carry is lost to the halving shift.
            let lowSum = UInt16(mem[entry]) + UInt16(mem[entry + 2])
            let lowByte = UInt8(truncatingIfNeeded: lowSum)
            mem[0xBE] = lowByte
            let highSum = mem[entry + 1] &+ mem[entry + 3] &+ UInt8(lowSum >> 8)
            charge(48 + Machine.pageCrossing(t, y) + Machine.pageCrossing(t + 2, y)
                   + Machine.pageCrossing(t + 1, y) + Machine.pageCrossing(t + 3, y))
            return (lowByte >> 1 | (highSum & 1) << 7, highSum >> 1, y, lowByte & 1 != 0)
        }
        // $1936: linear interpolation through the Q15 multiply.
        let base = Machine.word(mem[entry], mem[entry + 1])
        mem[0xBE] = mem[entry]; mem[0xBF] = mem[entry + 1]
        let difference = Machine.word(mem[entry + 2], mem[entry + 3]) &- base
        mem[0xC4] = UInt8(truncatingIfNeeded: difference)
        mem[0xC5] = UInt8(truncatingIfNeeded: difference >> 8)
        charge(63 + Machine.pageCrossing(t, y) + Machine.pageCrossing(t + 1, y)
               + Machine.pageCrossing(t + 2, y) + Machine.pageCrossing(t + 3, y))
        let p = mulQ15AX(a: 0, x: fraction >> 1)
        let sum = UInt32(Machine.word(p.a, p.x)) + UInt32(base)
        let lo = UInt8(truncatingIfNeeded: sum)
        charge(22)
        return (lo, UInt8(truncatingIfNeeded: sum >> 8), lo, sum > 0xFFFF)
    }
}
