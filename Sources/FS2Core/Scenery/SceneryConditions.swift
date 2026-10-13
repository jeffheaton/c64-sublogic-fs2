/// Display-list conditional jumps: the cull (04), the range boxes around the eye (13, 14), the
/// variable range tests (20-22), the bit test (23) and the compares (28). Every target is the
/// opcode's own address plus a rel16 (`$8DB3`, kept in `$A5/$A6`); a taken jump sets the PC to
/// it (`$8F43`/`$8DA8`), otherwise the PC advances past the op.
extension Machine {
    // MARK: Op 04: cull

    /// $8E0C (op 04 rel16 i1 i2 ... term): jumps when every listed vertex-cache entry is invalid
    /// (byte 7 negative) and their outcodes (byte 6), and-ed together from $F8 in `$DE`, are not
    /// 0: the whole object lies beyond one frustum plane. A valid entry clears `$DE`. The list
    /// ends at the first byte with bit 7 set; the PC then moves past it.
    func opCull() -> Scenery.Flow {
        let m = mem
        let pc0 = zpPointer(0x8B)
        charge(6 + dlRelativeTarget(pc0, y: 0) + 8)     // the target, then the PC past the offset
        dlStep(2)
        var c = 2                                           // the mask starts at $F8
        var mask: UInt8 = 0xF8
        m[0xDE] = mask
        c += 3                                              // kept in $DE
        while true {
            let pc = zpPointer(0x8B)
            let index = dlByte(pc, 1)
            c += 9 + Self.dlCross(pc, 1)            // the next index
            if index & 0x80 != 0 { c += 3; break }          // the terminator
            charge(c + 8)                               // select the cache entry ($89E7)
            vertexCacheSetEntry(index)
            let entry = zpPointer(0x2D)
            c = 7                                       // the entry's validity byte
            if m[(entry + 7) & 0xFFFF] & 0x80 == 0 {
                mask = 0
                m[0xDE] = 0
                c += 10                          // valid: the mask is cleared
            } else {
                mask &= m[(entry + 6) & 0xFFFF]
                m[0xDE] = mask
                c += 19                  // invalid: its outcode joins the mask
            }
        }
        charge(c + 8)                                   // the PC past the list
        dlStep(2)
        if mask == 0 {
            charge(9)                               // mask 0: no jump
            return .loop
        }
        charge(5)
        return dlTakeJump()
    }

    // MARK: Ops 13, 14: range boxes

    /// $8E4A (op 13 rel16 R z x): jumps when the eye is outside the box of half-size R around
    /// (x, z) in high-word units: |z − `$64/$65`| > R or |x − `$5C/$5D`| > R (`$8E74`).
    func opRangeJump() -> Scenery.Flow {
        charge(6)                                           // the box test ($8E74)
        if !rangeBoxTest() { return .loop }
        charge(3)                                           // inside: on past the op
        return .loop
    }

    /// $8E50 (op 14 rel16 R z x): as op 13; inside the box it also jumps when the altitude high
    /// word (`$60/$61`, or `$088A/$088B` in radar mode) minus R is not negative.
    func opRangeAltitudeJump() -> Scenery.Flow {
        let m = mem
        charge(6)                                           // the box test ($8E74)
        if !rangeBoxTest() { return .loop }
        let r = Int(m[0x99]) << 8 | Int(m[0x98])
        let altitude: Int
        var c = 6                                       // the radar-mode test
        if m[0x0836] != 0 {
            altitude = Int(m[0x088B]) << 8 | Int(m[0x088A])
            c += 16                          // the radar height's high word
        } else {
            altitude = Int(m[0x61]) << 8 | Int(m[0x60])
            c += 12                              // the altitude's high word
        }
        c += 3                                              // minus R's high byte
        if (altitude - r) & 0x8000 != 0 {
            charge(c + 6)                               // negative: no jump
            return .loop
        }
        charge(c + 5)                                   // the jump
        return dlTakeJump()
    }

    /// $8E74: the box test of ops 13/14. `$A5/$A6` = the target, `$98/$99` = R; `$8EA1` tests z
    /// against `$64/$65`, then x against `$5C/$5D` (the zero-page operands $8EA6/$8EAD are
    /// patched before each), and on success the PC advances by 9. Returns false when a test
    /// failed: the original then pops both return addresses and jumps (the jump is charged
    /// here, through its return to $8752).
    private func rangeBoxTest() -> Bool {
        let m = mem
        let pc = zpPointer(0x8B)
        var c = 6 + dlRelativeTarget(pc, y: 0)              // the target
        m[0x98] = dlByte(pc, 3)
        m[0x99] = dlByte(pc, 4)
        c += 7 + Self.dlCross(pc, 3) + 10 + Self.dlCross(pc, 4) + 3
        m[0x8EA6] = 0x64; m[0x8EAD] = 0x65
        c += 18                              // the z operands patched, then $8EA1
        guard rangeAxisTest(pc, y: 5, c: &c) else { return false }
        m[0x8EA6] = 0x5C; m[0x8EAD] = 0x5D
        c += 18
        guard rangeAxisTest(pc, y: 7, c: &c) else { return false }
        charge(c + 8)                                   // past the 9-byte op
        dlStep(9)
        charge(6)                                           // return
        return true
    }

    /// $8EA1: d = the word at PC + y − the eye word at zero page [$8EA6]/[$8EAD] (`$AB/$AC`);
    /// out of range when R − d (d ≥ 0) or R + d (d < 0) has bit 15 set (a sign test of the high
    /// byte, no overflow correction). On failure charges through the jump ($8ECC: both return
    /// addresses dropped, PC = target).
    private func rangeAxisTest(_ pc: Int, y: Int, c: inout Int) -> Bool {
        let m = mem
        let eyeLo = Int(m[Int(m[0x8EA6])]), eyeHi = Int(m[Int(m[0x8EAD])])
        let v = Int(dlByte(pc, y)) | Int(dlByte(pc, y + 1)) << 8
        let d = (v - (eyeHi << 8 | eyeLo)) & 0xFFFF
        m[0xAB] = UInt8(d & 0xFF)
        m[0xAC] = UInt8(d >> 8)
        // d into $AB/$AC.
        c += 7 + Self.dlCross(pc, y) + 15 + Self.dlCross(pc, y + 1) + 6
        let r = Int(m[0x99]) << 8 | Int(m[0x98])
        let out: Bool
        if d & 0x8000 == 0 {
            out = (r - d) & 0x8000 != 0
            c += 16                      // d ≥ 0: R − d
            c += out ? 5 : 9                        // out: on to $8ECC; in: return
        } else {
            out = (r + d) & 0x8000 != 0
            c += 17                      // d < 0: R + d
            c += out ? 3 : 8                            // out, or in and return
        }
        if out {
            charge(c + 16)                                  // both return addresses dropped
            _ = dlTakeJump()
        }
        return !out
    }

    // MARK: Ops 20-22: variable ranges

    /// $8EDB/$8EE6/$8EF4 (ops 20/21/22 rel16, then 1/2/3 × (addr16, lo16, hi16)): jumps unless
    /// lo ≤ [addr] ≤ hi for every triple (signed 16-bit compares with the overflow taken into
    /// account). The op is 9, 15 or 21 bytes long.
    func opBoxJump(_ count: Int) -> Scenery.Flow {
        let pc = zpPointer(0x8B)
        charge(6 + dlRelativeTarget(pc, y: 0))              // the target
        for k in 0..<count {
            charge(6)                                       // one triple ($8F05)
            if !variableRangeTest(pc, y: 2 + 6 * k) { return .loop }
        }
        charge(5)                                       // past the op
        return .advance(UInt8(3 + 6 * count))
    }

    /// $8F05: one (addr, lo, hi) triple at PC + y + 1. `$8E/$8F` = addr (then + 1), the low byte of
    /// [addr] is patched into the immediate subtraction at $8F31 (operand $8F32). Fails when
    /// [addr] − lo or hi − [addr] is negative as a signed comparison (N ≠ V); the failure is
    /// charged through the jump ($8F41: the return address dropped, PC = target).
    private func variableRangeTest(_ pc: Int, y: Int) -> Bool {
        let m = mem
        m[0x8E] = dlByte(pc, y + 1)
        m[0x8F] = dlByte(pc, y + 2)
        let addr = zpPointer(0x8E)
        let lo = m[addr]
        m[0x8F32] = lo
        // addr into $8E/$8F, its low byte patched in, then the pointer moved to the high byte.
        var c = 7 + Self.dlCross(pc, y + 1) + 10 + Self.dlCross(pc, y + 2) + 20
        m[0x8E] &+= 1
        if m[0x8E] == 0 { m[0x8F] &+= 1; c += 7 } else { c += 3 }
        let hi = m[zpPointer(0x8E)]
        let value = Int(Int16(bitPattern: UInt16(hi) << 8 | UInt16(lo)))
        let low = Int(Int16(bitPattern: UInt16(dlByte(pc, y + 4)) << 8 | UInt16(dlByte(pc, y + 3))))
        let high = Int(Int16(bitPattern: UInt16(dlByte(pc, y + 6)) << 8 | UInt16(dlByte(pc, y + 5))))
        // [addr] − lo, 16-bit.
        c += 9 + Self.dlCross(pc, y + 3) + 13 + Self.dlCross(pc, y + 4)
        c += Self.signedBranchCycles(value - low)
        if value < low {
            charge(c + 8)                                   // the return address dropped
            _ = dlTakeJump()
            return false
        }
        // hi − [addr], the low byte through the patched operand.
        c += 7 + Self.dlCross(pc, y + 5) + 11 + Self.dlCross(pc, y + 6) + 6
        c += Self.signedBranchCycles(high - value)
        if high < value {
            charge(c + 8)
            _ = dlTakeJump()
            return false
        }
        charge(c + 6)                                       // return
        return true
    }

    /// Cycles of the branch chain (the sign first, then the overflow) the range tests use after a
    /// 16-bit signed subtraction whose true result is `difference`, up to the branch that decides
    /// (a fall-through or the branch to the jump).
    ///
    /// N = bit 15 of the 16-bit result, V = the signed overflow. Plus (N = 0): the sign branch
    /// falls through (2); an overflow then fails (3), otherwise a second overflow test passes
    /// (2 + 3). Minus (N = 1): the sign branch is taken (3); no overflow then fails (3, taken), an
    /// overflow passes (2, falling through).
    @inline(__always)
    static func signedBranchCycles(_ difference: Int) -> Int {
        let n = difference & 0x8000 != 0
        let v = difference < -0x8000 || difference > 0x7FFF
        if !n { return 2 + (v ? 3 : 5) }
        return 3 + (v ? 2 : 3)
    }

    // MARK: Op 23: bit test

    /// $8F4E (op 23 rel16 addr16 mask16): jumps when [addr] & mask = 0 (`$8E/$8F` = addr,
    /// `$A9` = mask low byte; the high bytes are tested first).
    func opBitTestJump() -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        var c = 6 + dlRelativeTarget(pc, y: 0)              // the target
        m[0x8E] = dlByte(pc, 3)
        m[0x8F] = dlByte(pc, 4)
        m[0xA9] = dlByte(pc, 5)
        let maskHi = dlByte(pc, 6)
        m[0xB5] = 6
        // addr and the mask's low byte stored, Y kept in $B5, then the high bytes tested.
        c += 3 * 10 + Self.dlCross(pc, 3) + Self.dlCross(pc, 4) + Self.dlCross(pc, 5)
        c += 7 + Self.dlCross(pc, 6) + 10 + (m[0x8E] == 0xFF ? 1 : 0)
        let addr = zpPointer(0x8E)
        if maskHi & m[(addr + 1) & 0xFFFF] != 0 {
            charge(c + 11)                       // a common bit: past the 7-byte op
            return .advance(7)
        }
        c += 12                                  // then the low bytes
        if m[0xA9] & m[addr] == 0 {
            charge(c + 3)                                   // none in common: the jump
            return dlTakeJump()
        }
        charge(c + 10)
        return .advance(7)
    }

    // MARK: Op 28: compare

    /// $8F7A (op 28 type rel16 a16 b16): type 0 jumps when [a] = [b]; type 2 when [a] ≥ [b];
    /// any other type when [a] < [b] (signed, with the overflow taken into account). The rel16 is
    /// at bytes 2-3, still relative to the opcode. `$A9` = type, `$AB/$AC` = a, `$AD/$AE` = b.
    func opCompareJump() -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        let type = dlByte(pc, 1)
        m[0xA9] = type
        var c = 7 + Self.dlCross(pc, 1) + 9 + dlRelativeTarget(pc, y: 1)   // the type, the target
        m[0xAB] = dlByte(pc, 4)
        m[0xAC] = dlByte(pc, 5)
        m[0xAD] = dlByte(pc, 6)
        m[0xAE] = dlByte(pc, 7)
        m[0xB5] = 7
        c += 3 * 10 + 13                // a and b into $AB-$AE, Y kept in $B5
        c += Self.dlCross(pc, 4) + Self.dlCross(pc, 5) + Self.dlCross(pc, 6) + Self.dlCross(pc, 7)
        c += 3                                              // the type
        let pa = zpPointer(0xAB), pb = zpPointer(0xAD)
        let crossA = m[0xAB] == 0xFF ? 1 : 0, crossB = m[0xAD] == 0xFF ? 1 : 0
        let a = Int(Int16(bitPattern: UInt16(m[(pa + 1) & 0xFFFF]) << 8 | UInt16(m[pa])))
        let b = Int(Int16(bitPattern: UInt16(m[(pb + 1) & 0xFFFF]) << 8 | UInt16(m[pb])))
        let jump: Bool
        if type == 0 {
            // Equality: the high bytes, then the low bytes.
            c += 10 + crossA + 5 + crossB
            if m[(pa + 1) & 0xFFFF] != m[(pb + 1) & 0xFFFF] {
                c += 3
                jump = false
            } else {
                c += 14
                jump = m[pa] == m[pb]
                c += jump ? 5 : 3
            }
        } else {
            c += 4 + (type == 2 ? 3 : 2)                // which ordered compare
            // a − b, 16-bit.
            c += 21 + crossA + 5 + crossB
            let d = a - b
            let n = d & 0x8000 != 0
            let v = d < -0x8000 || d > 0x7FFF
            if type == 2 {
                // a ≥ b when N = V: the sign branch, then the overflow tests.
                jump = n == v
                if !n { c += 2 + (v ? 3 : 5) } else { c += 3 + (v ? 2 : 3) }
                if jump { c += 3 }                          // on to $8F43
            } else {
                // a < b when N ≠ V: the same chain with the outcomes swapped.
                jump = n != v
                if !n { c += 2 + (v ? 5 : 3) } else { c += 3 + (v ? 3 : 2) }
                if jump { c += 3 }                          // on to $8F43
            }
        }
        if jump {
            charge(c)
            return dlTakeJump()
        }
        charge(c + 8)                               // no jump: past the 8-byte op
        return .advance(8)
    }
}
