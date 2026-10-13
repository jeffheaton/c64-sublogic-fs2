/// The runway op 03 ($A5C8-$A730) and its template list $A5A7.
extension Machine {
    /// $A5A7: the runway template, a display list whose corner words op 03 patches: a polygon
    /// through the ground points V1-V4 (a pen-0 filled rectangle), then the dashed pen-3
    /// centerline C1-C2, then a return.
    public static let runwayTemplate = 0xA5A7

    /// Stores the 16-bit word `v` at `address` and its negation (two's complement) at `negated`.
    @inline(__always)
    private func runwayCorner(_ address: Int, _ v: UInt16, negated: Int) {
        setU16(address, v)
        setU16(negated, 0 &- v)
    }

    /// $A5C8 (op 03 hdg8 len16 wid16): a runway. θ = $40 − (hdg + hi(`$0849`) + hi(`$0847`)),
    /// c = cos θ (`$A9/$AA`), s = sin θ (`$C0/$C1`); with L = len (`$39/$3A`) and W = wid
    /// (`$9A/$9B`), the products (`$16C9`) L·s (`$3F/$40`), L·c (`$42/$43`), W·s (`$45/$46`),
    /// W·c (`$A9/$AA`) give the corners V1 = (L·c − W·s, W·c + L·s), V2 = (L·c + W·s,
    /// L·s − W·c), V3 = −V1, V4 = −V2 and the centerline (L·c, L·s)-(−L·c, −L·s), patched into the
    /// template. The template then runs as a nested scenery pass ($8730, which also copies
    /// the search requests again) with `$0876` = `$0877` = 0, and the PC is restored and advanced
    /// by 6. The sizes are half-extents: the runway drawn is 2L × 2W.
    func opRunway() throws(Scenery.Fault) -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        let theta = (~(dlByte(pc, 1) &+ m[0x0849] &+ m[0x0847])) &+ 0x41
        m[0xF4] = theta
        // θ from the heading operand and the two area offsets (kept in $F4), then cos8.
        charge(7 + Self.dlCross(pc, 1) + 27)
        let cosine = cos8(a: theta)
        m[0xA9] = cosine.a; m[0xAA] = cosine.x
        charge(15)                               // keep cos θ, then sin8 of $F4
        let sine = sin8(a: theta)
        m[0xC0] = sine.a; m[0xC1] = sine.x
        m[0xC6] = sine.a; m[0xC7] = sine.x
        m[0x39] = dlByte(pc, 2); m[0xC4] = m[0x39]
        m[0x3A] = dlByte(pc, 3); m[0xC5] = m[0x3A]
        // Keep sin θ twice, read L into $39/$3A and the multiplicand, then L·s.
        charge(19 + Self.dlCross(pc, 2) + 13 + Self.dlCross(pc, 3) + 12)
        var p = mulQ15()
        m[0x3F] = p.a; m[0x40] = p.x
        runwayCorner(0xA5C1, Machine.word(p.a, p.x), negated: 0xA5C5)
        // Keep L·s and patch it and its negation in; the negation costs a cycle more when the
        // low byte is 0 (the borrow reaches the high byte).
        var c = 24 + (p.a == 0 ? 4 : 3) + 8
        m[0xC6] = m[0xA9]; m[0xC7] = m[0xAA]
        m[0xC4] = m[0x39]; m[0xC5] = m[0x3A]
        charge(c + 30)                                  // set up L·c and multiply
        p = mulQ15()
        m[0x42] = p.a; m[0x43] = p.x
        runwayCorner(0xA5BF, Machine.word(p.a, p.x), negated: 0xA5C3)
        c = 24 + (p.a == 0 ? 4 : 3) + 8
        m[0x9A] = dlByte(pc, 4); m[0xC4] = m[0x9A]
        m[0x9B] = dlByte(pc, 5); m[0xC5] = m[0x9B]
        m[0xC6] = m[0xC0]; m[0xC7] = m[0xC1]
        // Read W into $9A/$9B and the multiplicand, with s as the multiplier, then W·s.
        c += 7 + Self.dlCross(pc, 4) + 13 + Self.dlCross(pc, 5) + 24
        charge(c)
        p = mulQ15()
        m[0x45] = p.a; m[0x46] = p.x
        m[0xC4] = m[0x9A]; m[0xC5] = m[0x9B]
        m[0xC6] = m[0xA9]; m[0xC7] = m[0xAA]
        charge(36)                                  // keep W·s, set up W·c and multiply
        p = mulQ15()
        m[0xA9] = p.a; m[0xAA] = p.x
        let ls = u16(0x3F), lc = u16(0x42), ws = u16(0x45), wc = u16(0xA9)
        c = 6                                           // keep W·c in $A9/$AA
        // Each corner: the 16-bit sum or difference patched into the template, then its
        // negation, which costs more when the low byte is 0 (the carry reaches the high byte).
        func corner(_ address: Int, _ v: UInt16, negated: Int, sumCycles: Int) {
            runwayCorner(address, v, negated: negated)
            c += sumCycles + 20 + (v & 0xFF == 0 ? 8 : 3)
        }
        corner(0xA5AB, wc &+ ls, negated: 0xA5B5, sumCycles: 18)
        corner(0xA5AE, lc &+ ws, negated: 0xA5B8, sumCycles: 22)
        corner(0xA5A9, lc &- ws, negated: 0xA5B3, sumCycles: 22)
        corner(0xA5B0, ls &- wc, negated: 0xA5BA, sumCycles: 22)
        // Run the template as a nested pass.
        let savedLo = m[0x8B], savedHi = m[0x8C]
        m[0x8B] = UInt8(Self.runwayTemplate & 0xFF)
        m[0x8C] = UInt8(Self.runwayTemplate >> 8)
        m[0x0876] = 0
        m[0x0877] = 0
        // The PC is saved on the stack, pointed at the template, and the pass runs.
        charge(c + 40)
        try runScenery()
        m[0x8C] = savedHi
        m[0x8B] = savedLo
        charge(19)                       // restore the PC, then advance past the operands
        return .advance(6)
    }
}
