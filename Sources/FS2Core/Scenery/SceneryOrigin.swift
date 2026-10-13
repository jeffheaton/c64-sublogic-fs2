/// Display-list object origins (ops 07 and 24): the eye position relative to an object, scaled to
/// 16 bits, in `$66/$68/$6A`.
extension Machine {
    /// $8BFD (op 07 s X32 Y32 Z32): eye − origin in 32 bits (`$3F/$40:$66/$67` x, `$42/$43:$68/$69`
    /// y, `$45/$46:$6A/$6B` z; the eye y is the radar height `$0888-$088B` in radar mode), then 16
    /// bits of it by the scale s ($8C9C): 0 → bits 0-15, 2 → 4-19, 4 → 8-23, 6 → 12-27, any
    /// other value → 16-31 (s = 1 and s ≥ $82 also take bits 0-15). y = 0 becomes 1; a y different
    /// from the one in `$35/$36` recomputes the ground base (`$8324`).
    func opOrigin() -> Scenery.Flow {
        let pc = zpPointer(0x8B)
        let scale = dlByte(pc, 1)
        mem[0xAD] = 0
        charge(7 + Self.dlCross(pc, 1) + 13)   // the scale, `$AD` cleared, the body called
        originBody(pc, scale: scale, wholeWords: false)
        charge(5)                                       // past the 14-byte op
        return .advance(14)
    }

    /// $8BC1 (op 24 s Xhi Yhi Zhi): as op 07 with the origin at whole high words: the eye's low
    /// words go to `$3F/$40`, `$42/$43`, `$45/$46` unchanged (`$AD` = $FF), and only the high
    /// words are subtracted.
    func opOriginHigh() -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        let scale = dlByte(pc, 1)
        m[0x3F] = m[0x5A]; m[0x40] = m[0x5B]
        m[0x45] = m[0x62]; m[0x46] = m[0x63]
        // The scale saved, the eye's x and z low words copied, then the radar-mode test.
        var c = 7 + Self.dlCross(pc, 1) + 31
        if m[0x0836] != 0 {
            m[0x42] = m[0x0888]; m[0x43] = m[0x0889]
            c += 19
        } else {
            m[0x42] = m[0x5E]; m[0x43] = m[0x5F]
            c += 15
        }
        m[0xAD] = 0xFF
        charge(c + 17)                       // `$AD` set, the scale back, the body called
        originBody(pc, scale: scale, wholeWords: true)
        charge(5)                                       // past the 8-byte op
        return .advance(8)
    }

    /// $8C0D: the subtractions (Y from 1), the scale selection and the y update. Charges from
    /// $8C0D through its return.
    private func originBody(_ pc: Int, scale: UInt8, wholeWords: Bool) {
        let m = mem
        var y = 1
        var c = 5                                       // x: the low-words test
        /// One eye byte minus the next operand byte into `dest`, the borrow chained through the
        /// carry; returns the new carry.
        func subtract(_ eye: UInt8, into dest: Int, eyeCycles: Int, carry: Bool) -> Bool {
            y += 1
            let v = Int(eye) - Int(dlByte(pc, y)) - (carry ? 0 : 1)
            m[dest] = UInt8(truncatingIfNeeded: v)
            c += eyeCycles + 7 + Self.dlCross(pc, y) + 3
            return v >= 0
        }
        // x
        var carry = true
        if !wholeWords {
            c += 2                                          // low words included
            carry = subtract(m[0x5A], into: 0x3F, eyeCycles: 3, carry: carry)
            carry = subtract(m[0x5B], into: 0x40, eyeCycles: 3, carry: carry)
        } else {
            c += 3
        }
        carry = subtract(m[0x5C], into: 0x66, eyeCycles: 3, carry: carry)
        _ = subtract(m[0x5D], into: 0x67, eyeCycles: 3, carry: carry)
        // y
        c += 6                                          // y: the radar-mode test
        carry = true
        if m[0x0836] != 0 {
            c += 5                                      // radar height; the low-words test
            if !wholeWords {
                c += 2
                carry = subtract(m[0x0888], into: 0x42, eyeCycles: 4, carry: carry)
                carry = subtract(m[0x0889], into: 0x43, eyeCycles: 4, carry: carry)
            } else {
                c += 3
            }
            carry = subtract(m[0x088A], into: 0x68, eyeCycles: 4, carry: carry)
            _ = subtract(m[0x088B], into: 0x69, eyeCycles: 4, carry: carry)
            c += 3                                          // past the altitude path
        } else {
            c += 6                                      // eye altitude; the low-words test
            if !wholeWords {
                c += 2
                carry = subtract(m[0x5E], into: 0x42, eyeCycles: 3, carry: carry)
                carry = subtract(m[0x5F], into: 0x43, eyeCycles: 3, carry: carry)
            } else {
                c += 3
            }
            carry = subtract(m[0x60], into: 0x68, eyeCycles: 3, carry: carry)
            _ = subtract(m[0x61], into: 0x69, eyeCycles: 3, carry: carry)
        }
        // z
        c += 5                                          // z: the low-words test
        carry = true
        if !wholeWords {
            c += 2
            carry = subtract(m[0x62], into: 0x45, eyeCycles: 3, carry: carry)
            carry = subtract(m[0x63], into: 0x46, eyeCycles: 3, carry: carry)
        } else {
            c += 3
        }
        carry = subtract(m[0x64], into: 0x6A, eyeCycles: 3, carry: carry)
        _ = subtract(m[0x65], into: 0x6B, eyeCycles: 3, carry: carry)
        // $8C9C: the scale picks the 16 bits kept (s − 2 is tested for sign, then zero, ...).
        let x = scale &- 2
        c += 4
        // Per axis k: the low word at $3F + 3k (its high byte at $40 + 3k), the result at $66 + 2k.
        if x & 0x80 != 0 {
            // $8CB0: bits 0-15 (the low words).
            for k in 0..<3 { m[0x66 + 2 * k] = m[0x3F + 3 * k]; m[0x67 + 2 * k] = m[0x40 + 3 * k] }
            c += 42
        } else if x == 0 {
            // $8D2B: bits 4-19.
            for k in 0..<3 {
                let r = 0x66 + 2 * k
                var w = UInt32(m[r]) << 16 | UInt32(m[0x40 + 3 * k]) << 8 | UInt32(m[0x3F + 3 * k])
                w = (w << 4) >> 8
                m[r] = UInt8(w & 0xFF); m[r + 1] = UInt8((w >> 8) & 0xFF)
            }
            c += 196
        } else if x == 2 {
            // $8CCB: bits 8-23.
            for k in 0..<3 { let r = 0x66 + 2 * k; m[r + 1] = m[r]; m[r] = m[0x40 + 3 * k] }
            c += 49
        } else if x == 4 {
            // $8CE6: bits 12-27.
            for k in 0..<3 {
                let r = 0x66 + 2 * k
                let w = (UInt32(m[r + 1]) << 16 | UInt32(m[r]) << 8 | UInt32(m[0x40 + 3 * k])) << 4
                m[r] = UInt8((w >> 8) & 0xFF); m[r + 1] = UInt8((w >> 16) & 0xFF)
            }
            c += 170
        } else {
            // bits 16-31: the high words as subtracted.
            c += 16
        }
        // $8D85: y = 0 becomes 1; a changed y recomputes the ground base.
        c += 3                                              // the high byte first
        if m[0x69] != 0 {
            c += 3
        } else {
            c += 5                                      // then the low byte
            if m[0x68] != 0 { c += 3 } else { m[0x68] = 1; c += 7 }
        }
        let yLo = m[0x68], previousLo = m[0x35]
        m[0x35] = yLo
        c += 9                                      // compared with the cached low byte
        var changed = yLo != previousLo
        if changed {
            c += 3                                          // changed
        } else {
            c += 8                                  // same low byte: compare the high bytes
            changed = m[0x69] != m[0x36]
            c += changed ? 2 : 3
        }
        if changed {
            charge(c + 6)                                   // the call to $8324
            computeGroundBase()
            c = 0
        }
        m[0x36] = m[0x69]
        charge(c + 12)                               // cache the high byte, return
    }
}
