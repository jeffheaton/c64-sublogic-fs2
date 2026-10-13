/// The 3D point transform $A1CE (ops 00/01/02/31). It reads the point from the display list at
/// `($8B)` and writes the eye-space words to the zero-page buffer named by Y (`$CD` = point A or
/// `$D6` = point B). The scenery interpreter reaches it through the self-modified call target at
/// $88A4/$88A5. The ground transform $9FD0 is in `GroundTransform.swift`.
extension Machine {
    // MARK: transform3D ($A1CE)

    /// $A1CE: transforms the display-list point (x, y, z words at `($8B)+1..6`) into eye space at
    /// zero page `dest` (`$E7` = dest, advanced by 2 per word).
    ///
    /// 1. d = P − (`$66`, `$68`, `$6A`) into `$9E/$9F`, `$A0/$A1`, `$A2/$A3`. If any subtraction
    ///    overflows, all three become the true (17-bit) difference halved; then, if any |d| ≥
    ///    $4000 (high byte + $40 negative), all three are halved again (arithmetic shifts).
    /// 2. `$2F` = `$30` = 0; the display-list PC advances by 7 (`$8851`).
    /// 3. Per eye axis i: `$A9` = dx·M[$78+2i], `$AB` = dy·M[$7E+2i] (`$16AA`),
    ///    dz·M[$84+2i] (`$16C9`), summed with 16-bit wraparound ($A332) into the next word of
    ///    `dest`; a sum with |high byte + $40| negative increments `$30`.
    /// 4. If `$30` ≠ 0 all three result words are halved.
    public func transform3D(y dest: UInt8) {
        let m = mem
        m[0xE7] = dest
        let pc = zpPointer(0x8B)
        @inline(__always) func byte(_ i: Int) -> UInt8 { m[(pc + i) & 0xFFFF] }
        @inline(__always) func cross(_ i: Int) -> Int { (pc & 0xFF) + i > 0xFF ? 1 : 0 }
        @inline(__always) func store(_ a: Int, _ v: Int) {
            m[a] = UInt8(truncatingIfNeeded: v); m[a + 1] = UInt8(truncatingIfNeeded: v >> 8)
        }
        // The true differences and their overflow flags.
        let px = Int(Int16(bitPattern: UInt16(byte(1)) | UInt16(byte(2)) << 8))
        let py = Int(Int16(bitPattern: UInt16(byte(3)) | UInt16(byte(4)) << 8))
        let pz = Int(Int16(bitPattern: UInt16(byte(5)) | UInt16(byte(6)) << 8))
        let dx = px - Int(s16(0x66)), dy = py - Int(s16(0x68)), dz = pz - Int(s16(0x6A))
        let vx = dx != Int(Int16(truncatingIfNeeded: dx))
        let vy = dy != Int(Int16(truncatingIfNeeded: dy))
        let vz = dz != Int(Int16(truncatingIfNeeded: dz))
        let part = 25                               // one 16-bit difference from the eye position
        var c = 5 + part + cross(1) + cross(2)  // saving dest, then dx
        if vx || vy || vz {
            store(0x9E, dx >> 1); store(0xA0, dy >> 1); store(0xA2, dz >> 1)
            if vx {
                // $A2D7: x halved with the carry, then y and z halved as they come.
                c += 15 + part + cross(3) + cross(4)
                c += vy ? 13 : 20
                c += part + cross(5) + cross(6) + (vz ? 3 : 4) + 13
            } else if vy {
                // $A30D: y halved with the carry, x by an arithmetic shift, then z ($A2F4).
                c += 6 + part + cross(3) + cross(4) + 33
                c += part + cross(5) + cross(6) + (vz ? 3 : 4) + 13
            } else {
                // $A31C: z halved with the carry, y and x by arithmetic shifts.
                c += 6 + part + cross(3) + cross(4) + 6 + part + cross(5) + cross(6) + 48
            }
        } else {
            store(0x9E, dx); store(0xA0, dy); store(0xA2, dz)
            c += 6 + part + cross(3) + cross(4) + 6 + part + cross(5) + cross(6) + 6
        }
        // $A20E: |d| < $4000, else halve all three once.
        c += 7
        var big = (m[0x9F] &+ 0x40) & 0x80 != 0
        if big { c += 3 } else {
            c += 9
            big = (m[0xA1] &+ 0x40) & 0x80 != 0
            if big { c += 3 } else {
                c += 9
                big = (m[0xA3] &+ 0x40) & 0x80 != 0
                c += big ? 2 : 3
            }
        }
        if big {
            for a in stride(from: 0x9E, through: 0xA2, by: 2) {
                setU16(a, UInt16(bitPattern: s16(a) >> 1))
            }
            c += 45
        }
        // $A238
        m[0x2F] = 0
        m[0x30] = 0
        charge(c + 16)
        dlStep(7)                                   // $8851: advance the display-list PC by 7
        for axis in 0..<3 {
            charge(12)
            mulZeroPage(a: 0xA9, x: 0x9E, y: UInt8(0x78 + 2 * axis))
            charge(12)
            mulZeroPage(a: 0xAB, x: 0xA0, y: UInt8(0x7E + 2 * axis))
            m[0xC4] = m[0xA2]; m[0xC5] = m[0xA3]
            m[0xC6] = m[0x84 + 2 * axis]; m[0xC7] = m[0x85 + 2 * axis]
            charge(30)
            let p = mulQ15()
            charge(6)
            transformAccumulate(p.a, p.x)
        }
        // $A2BB
        let x = m[0xE7]
        c = 6                                   // did any axis sum get large?
        if m[0x30] != 0 {
            for k in stride(from: 6, through: 2, by: -2) {
                let lo = Int(x &- UInt8(k)), hi = Int(x &- UInt8(k - 1))
                let v = Int16(bitPattern: UInt16(m[lo]) | UInt16(m[hi]) << 8) >> 1
                m[lo] = UInt8(truncatingIfNeeded: v); m[hi] = UInt8(truncatingIfNeeded: v >> 8)
            }
            c += 56
        } else {
            c += 3
        }
        charge(c + 6)
    }

    /// $A332: the axis sum A:X + `$A9:$AA` + `$AB:$AC` stored at zero page `$E7`, which advances
    /// by 2; `$30` is incremented when the high byte + $40 is negative.
    private func transformAccumulate(_ lo: UInt8, _ hi: UInt8) {
        let m = mem
        let sum = Machine.word(lo, hi) &+ u16(0xA9) &+ u16(0xAB)
        let x = m[0xE7]
        m[Int(x &+ 1)] = UInt8(truncatingIfNeeded: sum >> 8)
        m[Int(x)] = UInt8(truncatingIfNeeded: sum)
        m[0xE7] = x &+ 2
        if (UInt8(truncatingIfNeeded: sum >> 8) &+ 0x40) & 0x80 != 0 {
            m[0x30] &+= 1
            charge(66)
        } else {
            charge(62)
        }
    }
}
