/// The view matrix ($8111) and the ground-plane base ($8324).
///
/// Conventions of every file in `Render3D/` (see `re/docs/render3d.md`):
/// - Each routine reads and writes the bytes its original reads and writes (zero-page
///   temporaries, the self-modified code bytes) and charges the original's exact cycles, from
///   its first instruction through its return; the cost of the call itself belongs to the
///   caller.
/// - Routines in other units are called through their ports.
extension Machine {
    // MARK: buildViewMatrix ($8111 = $8000)

    /// $8111 (vector $8000): builds the rotation matrix `$78-$89` from the camera attitude
    /// `$6C-$71`, the view direction `$0ACA` and the radar flag `$0836`.
    ///
    /// The effective angles (`$72`-`$77`):
    /// - Radar (`$0836` ≠ 0): pitch $4000, bank = −heading, yaw = 0 (`$76` written).
    /// - Down view (`$0ACA` bit 7): pitch + $4000 (high byte only), bank = −heading, yaw = 0.
    /// - Otherwise view v = `$0ACA << 4` (45° steps): with |bank| ≥ 90° pitch is first folded to
    ///   $8000 − pitch and bank/heading flipped by $8000; then
    ///   pitch' = p·cos v − b·sin v, bank' = b·cos v + p·sin v (`$16AA` products), and only the
    ///   yaw high byte `$77` = heading_hi + v is written: **`$76` keeps its stale value**.
    /// - Then |pitch'| ≥ 90° folds pitch' to $8000 − pitch' and flips bank'/yaw by $8000.
    ///
    /// sin/cos of the three angles go through `$18C9/$18C2` (9-bit angles) into `$CD-$D2` (sin)
    /// and `$3F/$40`, `$D6-$D9` (cos); twelve `$16AA` products give the matrix, whose x row
    /// ($78, $7E, $84) is then halved and z row ($7C, $82, $88) quartered (loop $8306). The
    /// products use `$DA`, `$42`, `$DF`, `$E1`, `$E3`, `$45`, `$24` and `$27` as temporaries, so
    /// the ground base `$24-$29` is clobbered (recomputed by `computeGroundBase`). Also writes
    /// `$38`, `$39`, `$98`/`$99`, `$AD`/`$AE`, `$B8`/`$B9`, `$BC`/`$BD`, `$C0`-`$C3` (views only).
    public func buildViewMatrix() {
        let m = mem
        if m[0x0836] != 0 {
            // $8116: radar.
            m[0x72] = 0; m[0x73] = 0x40
            m[0x76] = 0; m[0x77] = 0
            let bank = 0 &- Machine.word(m[0x70], m[0x71])
            m[0x74] = UInt8(truncatingIfNeeded: bank); m[0x75] = UInt8(truncatingIfNeeded: bank >> 8)
            charge(45)
        } else if m[0x0ACA] & 0x80 != 0 {
            // $8139: the down view.
            let bank = 0 &- Machine.word(m[0x70], m[0x71])
            m[0x74] = UInt8(truncatingIfNeeded: bank); m[0x75] = UInt8(truncatingIfNeeded: bank >> 8)
            m[0x76] = 0; m[0x77] = 0
            m[0x72] = m[0x6C]
            m[0x73] = m[0x6D] &+ 0x40
            charge(60)
        } else {
            buildViewAngles()
        }
        buildMatrixFromAngles()
    }

    /// $815C-$81F6: the effective pitch and bank of view direction `$0ACA` (8 views at 45°).
    private func buildViewAngles() {
        let m = mem
        let v = m[0x0ACA] << 4
        m[0x39] = v
        m[0xB8] = m[0x6E]; m[0xB9] = m[0x6F]
        m[0xC2] = m[0x6C]; m[0xC3] = m[0x6D]
        m[0x38] = m[0x71]
        var c = 66                 // $8111-$8137, then $815C-$817E
        if (m[0xB9] &+ 0x40) & 0x80 != 0 {
            // $8183: |bank| >= 90 deg: pitch = $8000 - pitch, flip bank and heading.
            let p = 0x8000 &- Machine.word(m[0xC2], m[0xC3])
            m[0xC2] = UInt8(truncatingIfNeeded: p); m[0xC3] = UInt8(truncatingIfNeeded: p >> 8)
            m[0xB9] ^= 0x80
            m[0x38] ^= 0x80
            c += 45
        } else {
            c += 5                              // straight on to $81A0
        }
        // $81A0: yaw high byte; the low byte $76 is left as it is.
        m[0x77] = m[0x38] &+ v
        charge(c + 20)          // the yaw, then the cosine of v
        let cv = cos8(a: v)
        m[0xBC] = cv.a; m[0xBD] = cv.x
        charge(15)                       // stored; then the sine of v
        let sv = sin8(a: v)
        m[0xC0] = sv.a; m[0xC1] = sv.x
        charge(18)
        mulZeroPage(a: 0x98, x: 0xC2, y: 0xBC)      // p * cos v
        charge(12)
        mulZeroPage(a: 0xAD, x: 0xB8, y: 0xC0)      // b * sin v
        let pitch = Machine.word(m[0x98], m[0x99]) &- Machine.word(m[0xAD], m[0xAE])
        m[0x72] = UInt8(truncatingIfNeeded: pitch); m[0x73] = UInt8(truncatingIfNeeded: pitch >> 8)
        charge(32)
        mulZeroPage(a: 0x98, x: 0xB8, y: 0xBC)      // b * cos v
        charge(12)
        mulZeroPage(a: 0xAD, x: 0xC2, y: 0xC0)      // p * sin v
        let bank = Machine.word(m[0xAD], m[0xAE]) &+ Machine.word(m[0x98], m[0x99])
        m[0x74] = UInt8(truncatingIfNeeded: bank); m[0x75] = UInt8(truncatingIfNeeded: bank >> 8)
        charge(20)
    }

    /// $81F7-$8323: the |pitch| >= 90 deg fold, the trig of the effective angles, the twelve
    /// products and the x-row halving / z-row quartering loop.
    private func buildMatrixFromAngles() {
        let m = mem
        var c = 7                           // |pitch'| ≥ 90°?
        if (m[0x73] &+ 0x40) & 0x80 != 0 {
            let p = 0x8000 &- Machine.word(m[0x72], m[0x73])
            m[0x72] = UInt8(truncatingIfNeeded: p); m[0x73] = UInt8(truncatingIfNeeded: p >> 8)
            m[0x75] ^= 0x80
            m[0x77] ^= 0x80
            c += 36
        } else {
            c += 4                                  // no fold (the branch crosses a page)
        }
        // $8217: sines into $CD/$CF/$D1, cosines into $3F/$D6/$D8.
        charge(c + 12)
        var r = sin9(a: m[0x72], y: m[0x73])
        m[0xCD] = r.a; m[0xCE] = r.x
        charge(18)
        r = sin9(a: m[0x74], y: m[0x75])
        m[0xCF] = r.a; m[0xD0] = r.x
        charge(18)
        r = sin9(a: m[0x76], y: m[0x77])
        m[0xD1] = r.a; m[0xD2] = r.x
        charge(18)
        r = cos9(a: m[0x72], y: m[0x73])
        m[0x3F] = r.a; m[0x40] = r.x
        charge(18)
        r = cos9(a: m[0x74], y: m[0x75])
        m[0xD6] = r.a; m[0xD7] = r.x
        charge(18)
        r = cos9(a: m[0x76], y: m[0x77])
        m[0xD8] = r.a; m[0xD9] = r.x
        // $8259: the products (dest = first * second).
        charge(18)
        mulZeroPage(a: 0xDA, x: 0xD8, y: 0xD6)      // cy*cb
        charge(12)
        mulZeroPage(a: 0x42, x: 0xD1, y: 0xCF)      // sy*sb
        charge(12)
        mulZeroPage(a: 0xDF, x: 0xD8, y: 0xCF)      // cy*sb
        charge(12)
        mulZeroPage(a: 0xE1, x: 0xD1, y: 0xD6)      // sy*cb
        charge(12)
        mulZeroPage(a: 0xE3, x: 0xCD, y: 0x42)      // sp*sy*sb
        charge(12)
        mulZeroPage(a: 0x45, x: 0xCD, y: 0xE1)      // sp*sy*cb
        charge(12)
        mulZeroPage(a: 0x24, x: 0xDF, y: 0xCD)      // cy*sb*sp
        charge(12)
        mulZeroPage(a: 0x27, x: 0xCD, y: 0xDA)      // sp*cy*cb
        setU16(0x78, u16(0xDA) &+ u16(0xE3))
        setU16(0x7A, u16(0x45) &- u16(0xDF))
        charge(52)
        mulZeroPage(a: 0x7C, x: 0xD1, y: 0x3F)      // sy*cp
        charge(12)
        mulZeroPage(a: 0x7E, x: 0xCF, y: 0x3F)      // sb*cp
        charge(12)
        mulZeroPage(a: 0x80, x: 0x3F, y: 0xD6)      // cp*cb
        setU16(0x82, 0 &- u16(0xCD))
        setU16(0x84, u16(0x24) &- u16(0xE1))
        setU16(0x86, u16(0x42) &+ u16(0x27))
        charge(70)
        mulZeroPage(a: 0x88, x: 0xD8, y: 0x3F)      // cy*cp
        // $8306: halve the x row, quarter the z row (arithmetic shifts).
        for x in stride(from: 0x0C, through: 0, by: -6) {
            setU16(0x78 + x, UInt16(bitPattern: Int16(bitPattern: u16(0x78 + x)) >> 1))
            setU16(0x7C + x, UInt16(bitPattern: Int16(bitPattern: u16(0x7C + x)) >> 2))
        }
        charge(2 + 3 * 63 + 3 + 3 + 2 + 6)
    }

    // MARK: computeGroundBase ($8324)

    /// $8324: the ground-plane base terms, −y × the matrix Y column, for the eye height
    /// `$68/$69`: `$25:$24:$26` (high, middle, low) from `$7E`, `$28:$27:$29` from `$80` and
    /// `$2B:$2A:$2C` from `$82`. Each term is `$188A`(|M|, y) shifted left once and keeping bits
    /// 8-31 (so 24 bits of 2·|M|·y / 256), negated unless M and y differ in sign (the signs of
    /// `$C5` and `$69` are compared before |M| is formed). Also leaves `$C4:$C5` = 0,
    /// `$C6:$C7` = y and `$C8-$CB` from the last product. Called by op 07/24 when y changes
    /// ($8D9D).
    public func computeGroundBase() {
        let m = mem
        for k in 0..<3 {
            let column = 0x7E + 2 * k, dest = 0x24 + 3 * k
            m[0xC4] = m[column]; m[0xC5] = m[column + 1]
            charge(18)
            groundBaseTerm()
            m[dest + 2] = m[0xC9]
            m[dest] = m[0xCA]; m[dest + 1] = m[0xCB]
            charge(18)
        }
        charge(6)
    }

    /// $836A: `$C9-$CB` = −(M × y) for M = `$C4:$C5` and y = `$68/$69` (24 bits of 2·M·y / 256).
    private func groundBaseTerm() {
        let m = mem
        let differ = (m[0xC5] ^ m[0x69]) & 0x80 != 0
        var c = 12                       // the sign comparison saved on the stack; M's sign
        if m[0xC5] & 0x80 != 0 {
            let v = 0 &- Machine.word(m[0xC4], m[0xC5])
            m[0xC4] = UInt8(truncatingIfNeeded: v); m[0xC5] = UInt8(truncatingIfNeeded: v >> 8)
            c += 20
        } else {
            c += 3
        }
        charge(c + 12)                       // |M| times y
        mulU16(a: m[0x68], x: m[0x69])
        var v = (UInt32(m[0xC9]) | UInt32(m[0xCA]) << 8 | UInt32(m[0xCB]) << 16) << 1
        c = 19                           // doubled, then the saved sign comparison
        if differ {
            c += 3
        } else {
            v = 0 &- v
            c += 28
        }
        m[0xC9] = UInt8(truncatingIfNeeded: v)
        m[0xCA] = UInt8(truncatingIfNeeded: v >> 8)
        m[0xCB] = UInt8(truncatingIfNeeded: v >> 16)
        charge(c + 6)
    }
}
