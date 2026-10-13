/// The block-floating-point ground transform $9FD0 (ops 40/41/42/2B, y = 0) and its
/// renormalization $A1B9. The scenery interpreter reaches it through the self-modified call
/// target at $8863/$8864. The per-point exponent in `$2F` (previous one in `$0905`) is the
/// source of the characteristic ground jitter.
extension Machine {
    // MARK: transformGround ($9FD0)

    /// $9FD0: transforms the ground point (x, z words at `($8B)+1..4`, y = 0) into eye space at
    /// zero page `dest` in block floating point.
    ///
    /// The base `$24-$2C` (per axis a high word and a low byte) is copied to `$3F-$47`, `$0905` =
    /// the previous exponent `$2F`, `$2F` = $40. dx, dz = P − (`$66`, `$6A`) go to `$9E/$9F` and
    /// `$A2/$A3`.
    /// - On an overflow, both differences (the true values) and the base high words (not the low
    ///   bytes) are halved and `$2F` decremented.
    /// - Otherwise, while dx, dz and the three base high words are all below $4000 in magnitude,
    ///   all five are shifted left (the bases as 24 bits) and `$2F` incremented. (All of them zero
    ///   never normalizes: the original hangs there; the horizon pass and real scenery never get
    ///   that case.)
    /// - Each axis then adds two `$196D` products of high bytes (dx_hi with $79/$7B/$7D, dz_hi
    ///   with $85/$87/$89) into its 16-bit word, with a sign/overflow extension byte replacing
    ///   the low byte in `$41/$44/$47`. The `$196D` bias carry is the carry left by the previous
    ///   add (for the first product, the normalization's: 0, or bit 0 of `$45` after a halving).
    /// - Renormalization (`renormalizeGround`, `$2F` − 1 each): 3 shifts when the extension bytes
    ///   XOR to neither 0 nor $FF, 2 when an extension disagrees with its word's sign, else 1
    ///   when a word is ≥ $4000 in magnitude.
    ///
    /// The words go to `dest`, and the display-list PC advances by 5 (a tail jump into `$8851`).
    public func transformGround(y dest: UInt8) {
        let m = mem
        m[0xE7] = dest
        m[0x3F] = m[0x24]; m[0x40] = m[0x25]; m[0x41] = m[0x26]
        m[0x42] = m[0x27]; m[0x43] = m[0x28]; m[0x44] = m[0x29]
        m[0x45] = m[0x2A]; m[0x46] = m[0x2B]; m[0x47] = m[0x2C]
        m[0x0905] = m[0x2F]
        m[0x2F] = 0x40
        let pc = zpPointer(0x8B)
        @inline(__always) func byte(_ i: Int) -> UInt8 { m[(pc + i) & 0xFFFF] }
        @inline(__always) func cross(_ i: Int) -> Int { (pc & 0xFF) + i > 0xFF ? 1 : 0 }
        @inline(__always) func store(_ a: Int, _ v: Int) {
            m[a] = UInt8(truncatingIfNeeded: v); m[a + 1] = UInt8(truncatingIfNeeded: v >> 8)
        }
        let px = Int(Int16(bitPattern: UInt16(byte(1)) | UInt16(byte(2)) << 8))
        let pz = Int(Int16(bitPattern: UInt16(byte(3)) | UInt16(byte(4)) << 8))
        let dx = px - Int(s16(0x66)), dz = pz - Int(s16(0x6A))
        let vx = dx != Int(Int16(truncatingIfNeeded: dx))
        let vz = dz != Int(Int16(truncatingIfNeeded: dz))
        let part = 25                               // one 16-bit difference from the eye position
        // Saving dest, the base copy, the exponent bookkeeping, then dx.
        var c = 71 + part + cross(1) + cross(2)
        var carry = false
        if vx || vz {
            store(0x9E, dx >> 1); store(0xA2, dz >> 1)
            if vx {
                // $A06D: x halved with its overflow carry; z halved as it comes (with its own
                // carry at $A065, else by an arithmetic shift that copies the sign).
                c += 13 + part + cross(3) + cross(4) + (vz ? 16 : 17)
            } else {
                // $9FC1: z halved with the carry, x by an arithmetic shift.
                c += 5 + part + cross(3) + cross(4) + 32
            }
            // $A088: the base high words halved (the low bytes stay), exponent - 1. The carry
            // left over is bit 0 of $45 before the last halving.
            carry = m[0x45] & 1 != 0
            for a in stride(from: 0x3F, through: 0x45, by: 3) {
                setU16(a, UInt16(bitPattern: s16(a) >> 1))
            }
            m[0x2F] &-= 1
            c += 50
        } else {
            store(0x9E, dx); store(0xA2, dz)
            c += 5 + part + cross(3) + cross(4) + 5
            c += groundNormalize()
        }
        // $A09F: the products, two per axis.
        for axis in 0..<3 {
            let w = 0x3F + 3 * axis                 // the word; w + 2 is the extension byte
            charge(c + 12)                   // dx high byte times the matrix entry
            let p1 = mul8x8(x: m[0x9F], y: m[0x79 + 2 * axis], carry: carry)
            let lowSum = UInt16(p1.a) + UInt16(m[w])
            let highIn = m[w + 1]
            let highSum = UInt16(p1.y) + UInt16(highIn) + (lowSum >> 8)
            let high = UInt8(truncatingIfNeeded: highSum)
            let overflow = ~(p1.y ^ highIn) & (p1.y ^ high) & 0x80 != 0
            m[w] = UInt8(truncatingIfNeeded: lowSum)
            m[w + 1] = high
            var ext: UInt8 = high & 0x80 != 0 ? 0xFF : 0
            // Add into the word; the extension byte follows its sign, inverted on overflow.
            c = 16 + (ext == 0 ? 5 : 7)
            if overflow { ext ^= 0xFF; c += 4 } else { c += 3 }
            m[w + 2] = ext
            carry = highSum > 0xFF
            charge(c + 15)               // store it; dz high byte times the matrix entry
            let p2 = mul8x8(x: m[0xA3], y: m[0x85 + 2 * axis], carry: carry)
            let lowSum2 = UInt16(p2.a) + UInt16(m[w])
            let highSum2 = UInt16(p2.y) + UInt16(m[w + 1]) + (lowSum2 >> 8)
            m[w] = UInt8(truncatingIfNeeded: lowSum2)
            m[w + 1] = UInt8(truncatingIfNeeded: highSum2)
            let signExtension: UInt16 = p2.y & 0x80 != 0 ? 0xFF : 0
            let extSum = signExtension + UInt16(m[w + 2]) + (highSum2 >> 8)
            m[w + 2] = UInt8(truncatingIfNeeded: extSum)
            carry = extSum > 0xFF
            // Add into the word, then the product's sign extension into the extension byte.
            c = 18 + (signExtension == 0 ? 5 : 7) + 6
        }
        // $A156: how many renormalization shifts.
        c += 9                             // the three extension bytes combined
        let e = m[0x41] ^ m[0x44] ^ m[0x47]
        var shifts = 0
        if e != 0 && e != 0xFF {
            c += 7                          // neither 0 nor $FF: three shifts
            shifts = 3
        } else {
            c += e == 0 ? 3 : 6             // 0 or $FF: on to the sign checks
            // $A162: an extension byte that disagrees with its word's sign?
            for k in 0..<3 {
                let a = 0x40 + 3 * k
                c += 6                          // extension byte against the word's sign
                let disagrees = (m[a + 1] ^ m[a]) & 0x80 != 0
                if k < 2 {
                    if disagrees { c += 3; shifts = 2; break }
                    c += 2
                } else if disagrees {
                    c += 5                      // the last one disagrees: two shifts
                    shifts = 2
                } else {
                    c += 3                          // all agree: the magnitude checks
                }
            }
            if shifts == 0 {
                // $A182: a word at least $4000 in magnitude?
                for k in 0..<3 {
                    let a = 0x40 + 3 * k
                    c += 7                          // the $4000 magnitude test
                    let outside = (m[a] &+ 0x40) & 0x80 != 0
                    if k < 2 {
                        if outside { c += 3; shifts = 1; break }
                        c += 2
                    } else if outside {
                        c += 2; shifts = 1          // falls into the one-shift case at $A197
                    } else {
                        c += 3                      // small enough: no shift
                    }
                }
            }
        }
        charge(c)
        for _ in 0..<shifts {
            charge(6)
            renormalizeGround()
        }
        if shifts >= 2 { charge(3) }                // the multi-shift paths jump to $A19A
        // $A19A: the words to dest, then the PC advance.
        let x = Int(m[0xE7])
        m[x] = m[0x3F]; m[(x + 1) & 0xFF] = m[0x40]
        m[(x + 2) & 0xFF] = m[0x42]; m[(x + 3) & 0xFF] = m[0x43]
        m[(x + 4) & 0xFF] = m[0x45]; m[(x + 5) & 0xFF] = m[0x46]
        charge(50)                      // six bytes copied to dest, the advance set up
        dlStep(5)                                   // $8851: advance the display-list PC by 5
    }

    /// $A023: while dx (`$9F`), dz (`$A3`) and the base high words (`$40`, `$43`, `$46`) are all
    /// below $4000 in magnitude, shifts all five left (the bases as 24-bit `$40:$3F:$41`, ...)
    /// and increments `$2F`. Returns the cycles; the carry it leaves is clear.
    private func groundNormalize() -> Int {
        let m = mem
        var c = 0
        var rounds = 0
        while true {
            for k in 0..<5 {
                let a = k == 0 ? 0x9F : k == 1 ? 0xA3 : 0x40 + 3 * (k - 2)
                c += 7                              // the $4000 magnitude test
                if (m[a] &+ 0x40) & 0x80 != 0 { return c + 3 }   // too big: on to $A09F
                c += 2
            }
            m[0x2F] &+= 1
            setU16(0x9E, u16(0x9E) << 1)
            setU16(0xA2, u16(0xA2) << 1)
            for w in stride(from: 0x3F, through: 0x45, by: 3) {
                let v = (UInt32(m[w + 1]) << 16 | UInt32(m[w]) << 8 | UInt32(m[w + 2])) << 1
                m[w + 2] = UInt8(truncatingIfNeeded: v)
                m[w] = UInt8(truncatingIfNeeded: v >> 8)
                m[w + 1] = UInt8(truncatingIfNeeded: v >> 16)
            }
            c += 5 + 13 * 5 + 3                     // exponent, 13 shifts, back to $A023
            rounds += 1
            assert(rounds < 64, "transformGround: a zero point on a zero base never normalizes")
        }
    }

    // MARK: renormalizeGround ($A1B9)

    /// $A1B9: shifts the three ground sums (extension byte, high, low: `$41:$40:$3F`,
    /// `$44:$43:$42`, `$47:$46:$45`) right by one, the extension bytes logically (a zero, not
    /// the sign, shifted in), and decrements the exponent `$2F`.
    public func renormalizeGround() {
        let m = mem
        for w in stride(from: 0x3F, through: 0x45, by: 3) {
            let v = (UInt32(m[w + 2]) << 16 | UInt32(m[w + 1]) << 8 | UInt32(m[w])) >> 1
            m[w] = UInt8(truncatingIfNeeded: v)
            m[w + 1] = UInt8(truncatingIfNeeded: v >> 8)
            m[w + 2] = UInt8(truncatingIfNeeded: v >> 16)
        }
        m[0x2F] &-= 1
        charge(9 * 5 + 5 + 6)
    }
}
