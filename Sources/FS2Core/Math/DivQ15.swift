/// The signed fractional divide $1802.
extension Machine {
    /// $1802 (`divQ15`): signed fractional divide, `$C4:$C5` ≈ n / d × 32768 with the dividend
    /// n = A:X (A high, X low) and the divisor d = `$C6:$C7`. Valid only for |n| < |d|.
    ///
    /// Translated step for step:
    /// - The sign byte A ^ `$C7` is pushed; `$C4:$C5` = |n| and `$C6:$C7` = |d| (both negated in
    ///   memory; −32768 stays $8000).
    /// - 15 non-restoring steps on the remainder A:`$A7` (started at |n|): quotient bits rotate
    ///   into `$C4:$C5` from the bottom, pushing |n| out of the top. The sign test is bit 15 of
    ///   the 16-bit remainder, so |d| ≥ $4000 can overflow it.
    /// - A final shift doubles the quotient (bit 0 is always 0, so the resolution is 2 LSB). If
    ///   that sets bit 15 (|n| ≥ |d|), both bytes are decremented separately: $8000 → $7FFF, but
    ///   other values lose 257.
    /// - A negative sign negates `$C4:$C5`.
    ///
    /// Leaves `$A7` = the remainder's low byte. Returns A (the pulled sign byte when the quotient
    /// is positive, else the quotient's high byte), X (the remainder's high byte from the last
    /// step that saved it) and Y = 0. Cycles are counted exactly (692-771 measured).
    @discardableResult
    public func divQ15(a high: UInt8, x low: UInt8) -> (a: UInt8, x: UInt8, y: UInt8) {
        var c4 = low, c5 = high
        var c6 = mem[0xC6], c7 = mem[0xC7]
        let sign = high ^ c7                          // $1806: the result's sign, kept on the stack
        var cycles = 15
        if c5 & 0x80 != 0 {                           // $1809: |n|
            let negated = 0 &- Machine.word(c4, c5)
            c4 = UInt8(truncatingIfNeeded: negated); c5 = UInt8(truncatingIfNeeded: negated >> 8)
            cycles += 20
        } else {
            cycles += 3
        }
        cycles += 3
        if c7 & 0x80 != 0 {                           // $181A: |d|
            let negated = 0 &- Machine.word(c6, c7)
            c6 = UInt8(truncatingIfNeeded: negated); c7 = UInt8(truncatingIfNeeded: negated >> 8)
            cycles += 20
        } else {
            cycles += 3
        }

        // $182B: remainder A:$A7 = |n|, 15 steps.
        var x = c4, a7 = c4, a = c5, y: UInt8 = 15
        cycles += 11
        var carry = false

        enum Step { case trial, one, zero, done }
        var step = Step.trial
        while step != .done {
            switch step {
            case .trial:
                // $1833: remainder −= |d|; a negative result means a 0 bit.
                x = a
                let lowDiff = Int(a7) - Int(c6)
                a7 = UInt8(truncatingIfNeeded: lowDiff)
                let highDiff = Int(x) - Int(c7) - (lowDiff < 0 ? 1 : 0)
                a = UInt8(truncatingIfNeeded: highDiff)
                carry = highDiff >= 0
                if a & 0x80 != 0 { cycles += 21; step = .zero } else { cycles += 20; step = .one }
            case .one:
                // $1840: rotate the carry (a 1 bit) into the quotient, remainder <<= 1.
                let quotientOut = c4 >> 7
                c4 = c4 << 1 | (carry ? 1 : 0)
                c5 = c5 << 1 | quotientOut
                a = a << 1 | a7 >> 7
                a7 <<= 1
                y &-= 1
                if y != 0 { cycles += 22; step = .trial } else { cycles += 24; step = .done }
            case .zero:
                // $184C: shift a 0 bit into the quotient, remainder <<= 1, then remainder += |d|.
                c5 = c5 << 1 | c4 >> 7
                c4 <<= 1
                a = a << 1 | a7 >> 7
                a7 <<= 1
                y &-= 1
                if y == 0 { cycles += 22; step = .done; break }
                x = a
                let lowSum = UInt16(a7) + UInt16(c6)
                a7 = UInt8(truncatingIfNeeded: lowSum)
                a = a &+ c7 &+ UInt8(lowSum >> 8)
                if a & 0x80 != 0 {
                    cycles += 42                      // still negative: another 0 bit
                } else {
                    carry = true                      // $1863: back positive, so a 1 bit
                    cycles += 46
                    step = .one
                }
            case .done:
                break
            }
        }

        // $1866: final doubling; bit 15 set means overflow, patched by two separate DECs.
        c5 = c5 << 1 | c4 >> 7
        c4 <<= 1
        if c5 & 0x80 != 0 {
            c4 &-= 1; c5 &-= 1
            cycles += 22
        } else {
            cycles += 13
        }

        // $1870: apply the pulled sign.
        var aOut = sign
        if sign & 0x80 != 0 {
            let negated = 0 &- Machine.word(c4, c5)
            c4 = UInt8(truncatingIfNeeded: negated); c5 = UInt8(truncatingIfNeeded: negated >> 8)
            aOut = c5
            cycles += 24
        } else {
            cycles += 7
        }
        mem[0xA7] = a7
        mem[0xC4] = c4; mem[0xC5] = c5
        mem[0xC6] = c6; mem[0xC7] = c7
        charge(cycles + 6)
        return (aOut, x, y)
    }
}
