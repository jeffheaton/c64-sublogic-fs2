/// The signed 8×8 multiplies $196D and $1961, and the speed-indexed table interpolation $19E2.
extension Machine {
    /// $196D (`mul8x8`): signed 8×8 multiply, Y:A (Y high) ≈ 2·x·y, with x in X and y in Y.
    ///
    /// The original is a 7-step shift-add loop over the inverted bits of |y|, collecting the low
    /// bits in `$C6`. It reduces exactly to
    ///
    ///     magnitude = 2·|x|·|y| + c     (−128 counts as 127 for both operands)
    ///
    /// where c, the bit the loop's first rotate brings into `$C6`, is the **caller's carry** when
    /// x ≥ 0 and y ≥ 0, 1 when x ≥ 0 and y < 0 (left set by negating y), and 0 when x < 0 (left
    /// clear by negating x). This is the "bias" quirk: 1×1 = 3 with carry set, 2 with carry clear,
    /// and 0 × (y < 0) = −1. A negative x XOR y negates the magnitude.
    ///
    /// Memory: `$A5` = y, `$C4` = |x|, `$C6:$C7` = magnitude (never negated).
    /// Registers: A = low, Y = high; X = x when the product is positive, else the low byte.
    /// Carry out (callers chain it into the next 8×8 multiply, e.g. $E7CF → $E7D5): set for a
    /// positive product, else set only when the magnitude is 0.
    /// Cycles: counted exactly, 119-152 (path costs plus 2 per set bit 1-6 of |y|).
    @inline(__always) @discardableResult
    public func mul8x8(x: UInt8, y: UInt8, carry: Bool) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        mem[0xA5] = y
        var cycles: Int
        var c = carry
        let ym: UInt8                                  // |y|, −128 → 127 (C6 holds ~|y|)
        if y & 0x80 == 0 {
            ym = y; cycles = 10
        } else if y != 0x80 {
            ym = 0 &- y; c = true; cycles = 14
        } else {
            ym = 0x7F; c = true; cycles = 15
        }
        let xm: UInt8                                  // |x|, −128 → 127
        if x & 0x80 == 0 {
            xm = x; cycles += 8
        } else if x != 0x80 {
            xm = 0 &- x; c = false; cycles += 16
        } else {
            xm = 0x7F; c = false; cycles += 17
        }
        // $1987-$19BD: shift-add over bits 0-6 of |y|.
        cycles += 8 + (ym & 1 != 0 ? 3 : 4) + 60 + 2 * ((ym >> 1) & 0x3F).nonzeroBitCount + 15
        let product = UInt16(xm) * UInt16(ym)
        let c6 = UInt8(truncatingIfNeeded: product << 1) | (c ? 1 : 0)
        let c7 = UInt8(truncatingIfNeeded: product >> 7)
        mem[0xC4] = xm
        mem[0xC6] = c6
        mem[0xC7] = c7
        // $19BE: sign.
        if (x ^ y) & 0x80 == 0 {
            charge(cycles + 15)
            return (c6, x, c7, true)                  // the last rotate shifted out ~|y| bit 7 = 1
        }
        let negated = 0 &- Machine.word(c6, c7)
        let lo = UInt8(truncatingIfNeeded: negated)
        charge(cycles + 26)
        return (lo, lo, UInt8(truncatingIfNeeded: negated >> 8), c6 | c7 == 0)
    }

    /// $1961 (`mul8Half`): `mul8x8`, then an arithmetic shift right of Y:A, so ≈ x·y. With the
    /// bias bit c of `mul8x8`, a positive product is x·y exactly, and a negative one is
    /// −|x·y| − c (that is, −|x·y| − 1 when x ≥ 0 > y). X is as `mul8x8` leaves it; carry out is
    /// the bit shifted out (bit 0 of `mul8x8`'s low byte). 31 cycles + `mul8x8`.
    @inline(__always) @discardableResult
    public func mul8Half(x: UInt8, y: UInt8, carry: Bool) -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        let r = mul8x8(x: x, y: y, carry: carry)
        charge(31)
        return (r.a >> 1 | (r.y & 1) << 7, r.x, r.y >> 1 | (r.y & 0x80), r.a & 1 != 0)
    }

    /// $19E2 (`interpBySpeed`): 8.8 interpolation of the byte table at (`$BA`) by the airspeed
    /// high byte `$0A4D`: with i = `$0A4D` >> 4 and f = `$0A4D` & 15,
    ///
    ///     $C5:$C4 = t[i]·256 + 2·mul8Half(x: f·8, y: t[i+1] − t[i])
    ///
    /// where the difference is an 8-bit wrapping subtraction (a step of more than 127 wraps the
    /// other way) and the incoming carry is 0 (left by the index shifts), so only a falling step
    /// gets the bias. Reads t[i] and t[i+1] (i ≤ 15, so up to 17 bytes). Memory: `$BE` = t[i],
    /// `$C4:$C5` = result, plus `mul8x8`'s `$A5`, `$C4`, `$C6`, `$C7`. Returns A = `$C5`, X and Y
    /// as `mul8Half` leaves them, and the carry out of the final high-byte add (the caller at
    /// $2FA4 passes it into `mul8Half`). 79 cycles (+1 per table read that crosses a page) +
    /// `mul8Half`.
    @discardableResult
    public func interpBySpeed() -> (a: UInt8, x: UInt8, y: UInt8, carry: Bool) {
        let speed = mem[0x0A4D]
        let table = zpPointer(0xBA)
        let i = speed >> 4
        let t0 = mem[(table + Int(i)) & 0xFFFF]
        mem[0xBE] = t0
        let t1 = mem[(table + Int(i) + 1) & 0xFFFF]
        let r = mul8Half(x: (speed & 0x0F) << 3, y: t1 &- t0, carry: false)
        // Double the product and add t[i] into the high byte.
        let doubledHigh = UInt16(r.y << 1 | r.a >> 7) + UInt16(mem[0xBE])
        let hi = UInt8(truncatingIfNeeded: doubledHigh)
        mem[0xC4] = r.a << 1
        mem[0xC5] = hi
        charge(79 + Machine.pageCrossing(table, i) + Machine.pageCrossing(table, i &+ 1))
        return (hi, r.x, r.y, doubledHigh > 0xFF)
    }
}
