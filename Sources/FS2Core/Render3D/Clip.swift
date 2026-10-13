/// Outcodes ($93D2/$941B) and the parametric line clipping ($9464-$96D3) against the eye-apex
/// pyramid |x| ≤ z, |y| ≤ z (no near plane: z < 0 always sets an x bit too).
///
/// Points: A at `$CD-$D2` with outcode `$CC` and screen position `$D3/$D4`; B at `$D6-$DB` with
/// `$D5` and `$DC/$DD` (x, y, z words). A clip plane moves point B onto the plane along A→B.
extension Machine {
    // MARK: Outcodes ($93D2 / $941B)

    /// $93D2: the outcode of point A into `$CC`: $80 z < 0, $40 x + z < 0, $20 z − x < 0,
    /// $10 y + z < 0, $08 z − y < 0 (each the sign of a 16-bit sum, overflow ignored).
    public func computeOutcodeA() {
        mem[0xCC] = outcode(0xCD)
    }

    /// $941B: the outcode of point B into `$D5` (see `computeOutcodeA`).
    public func computeOutcodeB() {
        mem[0xD5] = outcode(0xD6)
    }

    @inline(__always)
    private func outcode(_ p: Int) -> UInt8 {
        let x = u16(p), y = u16(p + 2), z = u16(p + 4)
        var code: UInt8 = 0
        var c = 5                               // clear the code, z's sign
        if z & 0x8000 != 0 { code = 0x80; c += 4 } else { c += 3 }
        c += 14                                     // a 16-bit sum, its sign
        if (x &+ z) & 0x8000 != 0 { code |= 0x40; c += 8 } else { c += 3 }
        c += 14
        if (z &- x) & 0x8000 != 0 { code |= 0x20; c += 8 } else { c += 3 }
        c += 14
        if (y &+ z) & 0x8000 != 0 { code |= 0x10; c += 8 } else { c += 3 }
        c += 14
        if (z &- y) & 0x8000 != 0 { code |= 0x08; c += 9 } else { c += 6 }
        charge(c + 6)
        return code
    }

    // MARK: clipLine ($9464)

    /// $9464: clips point A: swaps the points ($946A), clips the far point (`clipLineEnd`) and
    /// swaps back (falling into $946A).
    public func clipLine() {
        charge(6)
        swapClipEndpoints()
        charge(6)
        clipLineEnd()
        swapClipEndpoints()
    }

    /// $946A: exchanges `$CC-$D2` (outcode and point A) with `$D5-$DB` (outcode and point B).
    public func swapClipEndpoints() {
        let m = mem
        for i in 0..<7 {
            let a = m[0xCC + i]
            m[0xCC + i] = m[0xD5 + i]
            m[0xD5 + i] = a
        }
        charge(2 + 7 * 21 - 1 + 6)
    }

    // MARK: clipLineEnd ($9478)

    /// $9478: clips point B plane by plane — x = −z ($40), x = z ($20), y = −z ($10), y = z
    /// ($08) — recomputing its outcode after each clip and returning as soon as the outcodes
    /// share a bit (the segment is outside) or B has no bits left.
    public func clipLineEnd() {
        let m = mem
        var c = 3                                   // any bits in B's outcode?
        if m[0xD5] == 0 { charge(c + 8); return }
        c += 3
        // $947D: x = -z (A still holds $D5).
        c += 2
        if m[0xD5] & 0x40 != 0 {
            charge(c + 8)
            clipPlaneXNeg()
            charge(6)
            computeOutcodeB()
            c = 6                               // a bit shared with A's outcode?
            if m[0xD5] & m[0xCC] != 0 { charge(c + 9); return }
            c += 2
        } else {
            c += 3
        }
        // $948D: x = z
        c += 5
        if m[0xD5] & 0x20 != 0 {
            charge(c + 8)
            clipPlaneXPos()
            charge(6)
            computeOutcodeB()
            c = 6
            if m[0xD5] & m[0xCC] != 0 { charge(c + 9); return }
            c += 2
        } else {
            c += 3
        }
        // $949F: y = -z
        c += 5
        if m[0xD5] & 0x10 != 0 {
            charge(c + 8)
            clipPlaneYNeg()
            charge(6)
            computeOutcodeB()
            c = 6
            if m[0xD5] & m[0xCC] != 0 { charge(c + 9); return }
            c += 2
        } else {
            c += 3
        }
        // $94B1: y = z, then a tail jump into the outcode.
        c += 5
        if m[0xD5] & 0x08 == 0 { charge(c + 9); return }
        charge(c + 8)
        clipPlaneYPos()
        charge(3)
        computeOutcodeB()
    }

    // MARK: The four planes ($94C0, $953E, $95C6, $9644)

    /// $96C9: halves points A and B (`$8B2A` on `$CD` and `$D6`) after an overflowing
    /// denominator; the plane routine then starts over.
    private func halveClipPoints() {
        charge(8)
        halvePoint(x: 0xCD)                         // $8B2A
        charge(8)
        halvePoint(x: 0xD6)                         // $8B2A
        charge(6)
    }

    /// The common start of a plane: `$C6:$C7` = zA − zB, then the denominator
    /// (aA − aB) − (zA − zB) (or (aB − aA) − (zA − zB) when `negated`) for the component at
    /// offset `component` (0 = x, 2 = y). Returns false when its subtraction overflows: the points
    /// are halved and the caller starts over.
    @inline(__always)
    private func clipDenominator(_ component: Int, negated: Bool) -> Bool {
        let m = mem
        let dz = u16(0xD1) &- u16(0xDA)
        setU16(0xC6, dz)
        let da = negated ? u16(0xD6 + component) &- u16(0xCD + component)
                         : u16(0xCD + component) &- u16(0xD6 + component)
        let (den, overflow) = Int16(bitPattern: da).subtractingReportingOverflow(Int16(bitPattern: dz))
        m[0xC6] = UInt8(truncatingIfNeeded: den)
        if overflow {
            charge(62)                      // the differences, the overflow test, the halving call
            halveClipPoints()
            return false
        }
        m[0xC7] = UInt8(truncatingIfNeeded: UInt16(bitPattern: den) >> 8)
        return true
    }

    /// One interpolation step: `$C6:$C7` = A − B of the word at offset `component`, t from `$C4`
    /// (saved in `$A9/$AA` when `save`, else reloaded from them), `$16C9`, and the product added
    /// to B's word. Returns B's new word. Charges everything but the code after the add.
    @inline(__always)
    private func clipInterpolate(_ component: Int, save: Bool) -> UInt16 {
        let m = mem
        setU16(0xC6, u16(0xCD + component) &- u16(0xD6 + component))
        if save {
            m[0xA9] = m[0xC4]; m[0xAA] = m[0xC5]
        } else {
            m[0xC4] = m[0xA9]; m[0xC5] = m[0xAA]
        }
        charge(38)                         // the difference, t saved or reloaded, the multiply call
        let p = mulQ15()
        let v = Machine.word(p.a, p.x) &+ u16(0xD6 + component)
        return v
    }

    /// $94C0: clips point B to the plane y = z: t = (zB − yB) / ((yA − yB) − (zA − zB)) by
    /// `$1802` (into `$C4`, kept in `$A9/$AA`), xB += t·(xA − xB), zB += t·(zA − zB), yB = zB.
    public func clipPlaneYPos() {
        while !clipDenominator(2, negated: false) {}
        charge(80)                 // the rest of the denominator, the numerator, the divide call
        let num = u16(0xDA) &- u16(0xD8)
        divQ15(a: UInt8(num >> 8), x: UInt8(truncatingIfNeeded: num))
        setU16(0xD6, clipInterpolate(0, save: true))
        charge(16)
        let z = clipInterpolate(4, save: false)
        setU16(0xDA, z)
        setU16(0xD8, z)
        charge(28)
    }

    /// $953E: clips point B to the plane y = −z: t = (zB + yB) / ((yB − yA) − (zA − zB)),
    /// xB += t·(xA − xB), zB += t·(zA − zB), yB = −zB.
    public func clipPlaneYNeg() {
        while !clipDenominator(2, negated: true) {}
        charge(80)
        let num = u16(0xDA) &+ u16(0xD8)
        divQ15(a: UInt8(num >> 8), x: UInt8(truncatingIfNeeded: num))
        setU16(0xD6, clipInterpolate(0, save: true))
        charge(16)
        let z = clipInterpolate(4, save: false)
        setU16(0xDA, z)
        setU16(0xD8, 0 &- z)
        charge(31 + (z & 0xFF == 0 ? 7 : 3) + 6)
    }

    /// $95C6: clips point B to the plane x = z: t = (zB − xB) / ((xA − xB) − (zA − zB)),
    /// zB += t·(zA − zB), xB = zB, yB += t·(yA − yB).
    public func clipPlaneXPos() {
        while !clipDenominator(0, negated: false) {}
        charge(80)
        let num = u16(0xDA) &- u16(0xD6)
        divQ15(a: UInt8(num >> 8), x: UInt8(truncatingIfNeeded: num))
        let z = clipInterpolate(4, save: true)
        setU16(0xDA, z)
        setU16(0xD6, z)
        charge(22)
        setU16(0xD8, clipInterpolate(2, save: false))
        charge(22)
    }

    /// $9644: clips point B to the plane x = −z: t = (zB + xB) / ((xB − xA) − (zA − zB)),
    /// yB += t·(yA − yB), zB += t·(zA − zB), xB = −zB.
    public func clipPlaneXNeg() {
        while !clipDenominator(0, negated: true) {}
        charge(80)
        let num = u16(0xDA) &+ u16(0xD6)
        divQ15(a: UInt8(num >> 8), x: UInt8(truncatingIfNeeded: num))
        setU16(0xD8, clipInterpolate(2, save: true))
        charge(16)
        let z = clipInterpolate(4, save: false)
        setU16(0xDA, z)
        setU16(0xD6, 0 &- z)
        charge(31 + (z & 0xFF == 0 ? 7 : 3) + 6)
    }
}
