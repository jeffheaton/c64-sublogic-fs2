/// Perspective projection ($9D05-$9E91, $9F94) with the tables $9E92 (TX) and $9F13 (TY).
///
/// A point (x, y, z) in eye space projects to sx = $50 + TX[q(x)] (x ≥ 0) or $4F − TX[q(x)],
/// sy = $37 − TY[q(y)] (y ≥ 0) or $38 + TY[q(y)], where q(n) = floor(128·|n| / z) as the 7-bit
/// quotient of an unrolled non-restoring division ($9D3D). The tables are read from memory.
extension Machine {
    /// $9E92: TX[i] = floor(5i/8), 129 bytes.
    public static let projectionX = 0x9E92
    /// $9F13: TY[i] = floor(7i/16), 129 bytes.
    public static let projectionY = 0x9F13
    /// $9E89/$9E8A: the self-modified operand of the table read in `projectionDivide`
    /// (the indexed table read at $9E88), set by `project`.
    public static let projectionTableOperand = 0x9E89

    // MARK: projectPointA / projectPointB ($9D05 / $9D21)

    /// $9D05: projects point A (`$CD-$D2`) into `$D3/$D4` (sx, sy). Also writes `$C4-$C7`.
    public func projectPointA() {
        let m = mem
        m[0xC4] = m[0xCD]; m[0xC5] = m[0xCE]
        m[0xC6] = m[0xD1]; m[0xC7] = m[0xD2]
        charge(36)
        let r = project(a: m[0xD0], y: m[0xCF])
        m[0xD3] = r.a
        m[0xD4] = r.y
        charge(12)
    }

    /// $9D21: projects point B (`$D6-$DB`) into `$DC/$DD` (sx, sy). Also writes `$C4-$C7`.
    public func projectPointB() {
        let m = mem
        m[0xC4] = m[0xD6]; m[0xC5] = m[0xD7]
        m[0xC6] = m[0xDA]; m[0xC7] = m[0xDB]
        charge(36)
        let r = project(a: m[0xD9], y: m[0xD8])
        m[0xDC] = r.a
        m[0xDD] = r.y
        charge(12)
    }

    // MARK: project ($9F94)

    /// $9F94: projects (x = `$C4:$C5`, y = A:Y (A high), z = `$C6:$C7`). Points the table
    /// operand at TY, divides y, `$A7` = $37 − (TY[q] or its complement) (`$AF` = the divide's A),
    /// points the operand at TX and divides x. Returns A = sx = $50 + (TX[q] or its
    /// complement), X = q(x), Y = sy.
    @discardableResult
    public func project(a yHigh: UInt8, y yLow: UInt8) -> (a: UInt8, x: UInt8, y: UInt8) {
        let m = mem
        m[Self.projectionTableOperand] = 0x13; m[Self.projectionTableOperand + 1] = 0x9F
        let ry = projectionDivideBody(yHigh, yLow)
        m[0xAF] = ry.a
        m[0xA7] = 0x37 &- ry.a
        m[Self.projectionTableOperand] = 0x92; m[Self.projectionTableOperand + 1] = 0x9E
        let rx = projectionDivideBody(m[0xC5], m[0xC4])
        // Operand at TY and the y divide, sy into `$A7`, operand at TX and the x divide, then
        // sx = $50 + the x result.
        charge(18 + ry.cycles + 37 + rx.cycles + 13)
        return (rx.a &+ 0x50, rx.x, m[0xA7])
    }

    // MARK: projectionDivide ($9D3D)

    /// $9D3D: the projection quotient of the numerator A:Y (A high) by z = `$C6:$C7`, looked up in
    /// the table the operand at $9E89 names. Returns A = table[q] (complemented when the
    /// numerator is negative), X = q, Y = `$A6` = the numerator's high byte.
    ///
    /// n = z gives q = $7F (`$A6` = 0) and n = −z gives q = $7F (`$A6` = $FF). Otherwise eight
    /// steps of R = 2R ∓ z on the 16-bit remainder (started at n; a step subtracts after a
    /// non-negative remainder, adds after a negative one; bit 15 of 2R is lost), each step's
    /// carry rotated into `$A5` at the start of the next (the first gets the sign: 0, or 1 for
    /// negative n). q = bits 6-0 of `$A5` (inverted for negative n). The add chain falls back
    /// into the fifth subtract step when its eighth step ends negative with carry set (only
    /// reachable with a signed overflow), as in the original.
    @discardableResult
    public func projectionDivide(a high: UInt8, y low: UInt8) -> (a: UInt8, x: UInt8, y: UInt8) {
        let r = projectionDivideBody(high, low)
        charge(r.cycles)
        return (r.a, r.x, r.y)
    }

    @usableFromInline
    func projectionDivideBody(_ high: UInt8, _ low: UInt8) -> (a: UInt8, x: UInt8, y: UInt8, cycles: Int) {
        let m = mem
        let zl = m[0xC6], zh = m[0xC7]
        var c = 5                               // n = z? the high bytes first
        var q: UInt8
        found: do {
            if high == zh {
                c += 5                          // then the low bytes
                if low == zl {
                    m[0xA6] = 0
                    q = 0x7F
                    c += 12          // q = $7F, straight to the table read
                    break found
                }
            }
            c += 3                                  // on to $9D4F
            // $9D4F: n = -z?
            c += 7                          // the low bytes of n + z
            let lowSum = UInt16(low) + UInt16(zl)
            if lowSum & 0xFF == 0 {
                c += 7                      // then the high bytes
                if high &+ zh &+ UInt8(lowSum >> 8) == 0 {
                    m[0xA6] = 0xFF
                    q = 0x7F
                    c += 12
                    break found
                }
            }
            c += 3                                  // on to $9D63
            // $9D63: the division.
            m[0xA6] = high
            c += 5                              // keep the numerator's high byte
            var subtract = high & 0x80 == 0
            var carry = !subtract
            c += subtract ? 4 : 5           // the first carry is the sign
            var a5 = m[0xA5]
            var r = UInt16(high) << 8 | UInt16(low)
            let z = UInt16(zh) << 8 | UInt16(zl)
            var step = 1
            while true {
                a5 = a5 << 1 | (carry ? 1 : 0)      // the previous carry into the quotient
                let doubled = r << 1
                if subtract {
                    carry = doubled >= z
                    r = doubled &- z
                } else {
                    let sum = UInt32(doubled) + UInt32(z)
                    carry = sum > 0xFFFF
                    r = UInt16(truncatingIfNeeded: sum)
                }
                c += 27
                let negative = r & 0x8000 != 0
                if step == 8 {
                    if subtract { c += negative ? 3 : 2; break }   // done either way
                    if !negative { c += 3; break }  // done
                    if !carry { c += 5; break } // done
                    c += 4                      // falls into $9E3B, the fifth subtract step
                    step = 5
                    subtract = true
                    continue
                }
                let changes = subtract == negative  // the branch to the other chain is taken
                if changes {
                    c += step == 4 && !subtract ? 4 : 3
                } else {
                    c += step == 4 && subtract ? 5 : 2
                }
                subtract = !negative
                step += 1
            }
            m[0xA5] = a5
            // $9E7F: the last carry shifted in, all inverted for a negative numerator, and the
            // top bit dropped.
            var a = a5 << 1 | (carry ? 1 : 0)
            if a5 & 0x80 != 0 { a ^= 0xFF; c += 9 } else { c += 8 }
            q = a >> 1
            c += 4
        }
        // $9E88: the table read through the self-modified operand.
        let table = Int(m[Self.projectionTableOperand]) | Int(m[Self.projectionTableOperand + 1]) << 8
        var a = m[(table + Int(q)) & 0xFFFF]
        let sign = m[0xA6]
        c += 4 + ((table & 0xFF) + Int(q) > 0xFF ? 1 : 0) + 3
        if sign & 0x80 != 0 { a ^= 0xFF; c += 4 } else { c += 3 }
        return (a, q, sign, c + 6)
    }
}
