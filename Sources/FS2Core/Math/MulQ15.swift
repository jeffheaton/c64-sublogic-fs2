/// The signed Q15 multiply $16C9 and its entries $16AA, $17EF and $17F6.
extension Machine {
    /// $16C9 (`mulQ15`): signed 16×16 multiply, ≈ (m × n) >> 15, with m = `$C4:$C5` and
    /// n = `$C6:$C7` (Q15 words). Returns the product in A (low) and X (high).
    ///
    /// The original is an inverted-bit shift-add loop, translated step for step:
    /// - Either operand zero: A = X = 0, Y and memory untouched (17 or 24 cycles).
    /// - Y = `$C5 ^ $C7` (the product's sign).
    /// - `$C4:$C5` := ~|m|: the loop adds where a bit of ~|m| is 0. m = −32768 stays $8000,
    ///   which acts as |m| = 32767.
    /// - `$C6:$C7` := |n|; n = −32768 becomes $7FFF.
    /// - Bit 0 of |m| starts the 8-bit accumulator A at the value still in A, which is |n|'s high
    ///   byte except for n = −32768, where it is $80 instead of $7F.
    /// - Bits 1-5 of |m| add only |n|'s high byte to the 8-bit accumulator; the bits it shifts out
    ///   are rotated into the top of `$C4`.
    /// - Bits 6-14 add the full |n| into the 16-bit accumulator A:`$A7`, shifting right each step.
    ///   Bit 15 is ignored.
    /// - A negative product is negated through `$A8`.
    ///
    /// Leaves `$A7` = result low byte, `$A8` = unnegated high byte (negative products only),
    /// `$C4`/`$C5` = the shifted-out remains of ~|m|, and `$C6:$C7` = |n|. The error against the
    /// exact m·n/32768 stays within −1.95..+1.97 LSB.
    ///
    /// Cycles: 17 or 24 for the zero shortcut, otherwise 271-454, counted exactly: 39 + sign
    /// handling (m: 14/21/23, n: 6/26/35) + 8/9 for bit 0 + 10/12 per bit 1-5 + 15/30 per
    /// bit 6-14 + 12/29 for the result sign (the larger figure when a bit of |m| adds).
    /// - Returns: A, X, and Y (nil when the zero shortcut leaves Y unchanged). Carry is not
    ///   modeled (no caller tests it).
    @discardableResult
    public func mulQ15() -> (a: UInt8, x: UInt8, y: UInt8?) {
        var c4 = mem[0xC4], c5 = mem[0xC5]
        var c6 = mem[0xC6], c7 = mem[0xC7]
        // $16C9-$16D6: zero shortcut.
        if c4 | c5 == 0 { charge(17); return (0, 0, nil) }
        if c6 | c7 == 0 { charge(24); return (0, 0, nil) }

        // $16D7: Y = sign of the product.
        let sign = c5 ^ c7
        var cycles = 28

        // $16DC-$16FB: C4:C5 = ~|m| (ones' complement of a positive m, m − 1 for a negative one).
        if c5 & 0x80 == 0 {
            c4 = ~c4; c5 = ~c5
            cycles += 21
        } else if c4 != 0 {
            c4 &-= 1
            cycles += 14
        } else if c5 != 0x80 {
            c5 &-= 1; c4 = 0xFF
            cycles += 21
        } else {
            cycles += 23                          // −32768: the decrement and its undo leave $8000
        }

        // $16FC-$1712: C6:C7 = |n|; A keeps |n|'s high byte (or $80 for n = −32768).
        var a: UInt8
        if c7 & 0x80 == 0 {
            a = c7
            cycles += 6
        } else {
            let negated = 0 &- Machine.word(c6, c7)
            c6 = UInt8(truncatingIfNeeded: negated); c7 = UInt8(truncatingIfNeeded: negated >> 8)
            a = c7
            if c7 & 0x80 == 0 {
                cycles += 26
            } else {
                c6 &-= 1; c7 &-= 1                // $8000 → $7FFF; A stays $80
                cycles += 35
            }
        }

        // $1713: bit 0. A set bit of ~|m| clears the accumulator, a clear one keeps A.
        let skipFirst = c4 & 1 != 0
        c4 >>= 1
        if skipFirst { a = 0; cycles += 9 } else { cycles += 8 }

        // $1719-$173B: bits 1-5 add only the high byte of |n|.
        for _ in 0..<5 {
            let out = a & 1
            a >>= 1
            let skip = c4 & 1 != 0
            c4 = c4 >> 1 | out << 7
            if skip { cycles += 10 } else { a &+= c7; cycles += 12 }
        }

        // $173C-$1740: the bit shifted out of A here is lost; the 16-bit phase starts with $A7 = 0.
        a >>= 1
        var a7: UInt8 = 0

        // $1741-$17D6: bit 6 (from $C4), then bits 7 ($C4) and 8-14 ($C5), each after a shift of
        // A:$A7. An add is A:$A7 += |n|.
        var skip = c4 & 1 != 0
        c4 >>= 1
        if skip {
            cycles += 15
        } else {
            let low = UInt16(a7) + UInt16(c6)
            a7 = UInt8(truncatingIfNeeded: low)
            a = a &+ c7 &+ UInt8(low >> 8)
            cycles += 30
        }
        for bit in 7...14 {
            a7 = a7 >> 1 | (a & 1) << 7
            a >>= 1
            if bit == 7 {
                skip = c4 & 1 != 0; c4 >>= 1
            } else {
                skip = c5 & 1 != 0; c5 >>= 1
            }
            if skip {
                cycles += 15
            } else {
                let low = UInt16(a7) + UInt16(c6)
                a7 = UInt8(truncatingIfNeeded: low)
                a = a &+ c7 &+ UInt8(low >> 8)
                cycles += 30
            }
        }
        // $17D7: final shift.
        a7 = a7 >> 1 | (a & 1) << 7
        a >>= 1

        // $17DA-$17EE: apply the sign.
        var lo = a7, hi = a
        if sign & 0x80 != 0 {
            mem[0xA8] = hi
            let negated = 0 &- Machine.word(lo, hi)
            lo = UInt8(truncatingIfNeeded: negated); hi = UInt8(truncatingIfNeeded: negated >> 8)
            a7 = lo
            cycles += 29
        } else {
            cycles += 12
        }
        mem[0xA7] = a7
        mem[0xC4] = c4; mem[0xC5] = c5
        mem[0xC6] = c6; mem[0xC7] = c7
        charge(cycles + 11)
        return (lo, hi, sign)
    }

    /// $17EF (`mulQ15AX`): `$C6:$C7` = A:X (X high), then `mulQ15`. 9 cycles + `mulQ15`.
    @inline(__always) @discardableResult
    public func mulQ15AX(a: UInt8, x: UInt8) -> (a: UInt8, x: UInt8, y: UInt8?) {
        mem[0xC6] = a; mem[0xC7] = x
        charge(9)
        return mulQ15()
    }

    /// $17F6 (`mulQ15Chain`): as `mulQ15AX`, then also stores the product to `$C4:$C5` so the
    /// next multiply can chain from it. 24 cycles + `mulQ15`.
    @inline(__always) @discardableResult
    public func mulQ15Chain(a: UInt8, x: UInt8) -> (a: UInt8, x: UInt8, y: UInt8?) {
        mem[0xC6] = a; mem[0xC7] = x
        let r = mulQ15()
        mem[0xC4] = r.a; mem[0xC5] = r.x
        charge(24)
        return r
    }

    /// $16AA (`mulZeroPage`): zp[A] = zp[X] × zp[Y] through `mulQ15` (Q15 words).
    ///
    /// The addressing modes matter at the end of page zero: zp[X] is read with `zp,X` (its high
    /// byte wraps to $00), zp[Y] with `abs,Y` (Y = $FF reads $0100), the low byte of the product
    /// is stored with `abs,Y` and the high byte with `zp,Y` (wraps). `$A5` keeps the destination.
    /// Returns A, X (product) and Y (= destination). 55 cycles + `mulQ15`, 56 when Y = $FF.
    @discardableResult
    public func mulZeroPage(a destination: UInt8, x first: UInt8, y second: UInt8) -> (a: UInt8, x: UInt8, y: UInt8) {
        mem[0xA5] = destination
        mem[0xC4] = mem[Int(first)]
        mem[0xC5] = mem[Machine.zp(1, first)]
        mem[0xC6] = mem[Int(second)]
        mem[0xC7] = mem[Int(second) + 1]
        let r = mulQ15()
        let d = mem[0xA5]
        mem[Int(d)] = r.a
        mem[Machine.zp(1, d)] = r.x
        charge(second == 0xFF ? 56 : 55)
        return (r.a, r.x, d)
    }
}
