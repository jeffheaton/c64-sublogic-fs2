/// The attitude indicator ($A378-$A4F1): a chord across the 40×32 instrument face (panel rows
/// 120-151, byte columns 8-12) separating sky (set bits, light blue) from ground (clear bits,
/// brown). The chord is walked by the horizon Bresenham ($8623) with the split row $85C0
/// patched to jump to $A4CA (`aiSpan`), which fills one span per row instead.
extension Machine {
    /// $A354/$A355: pitch and bank high bytes at the last redraw.
    public static let aiLastAttitude = 0xA354
    /// $A356: 34 chord-angle offsets indexed by (pitch_hi + $20) / 2.
    public static let aiPitchTable = 0xA356

    // MARK: drawAttitudeIndicator ($A378 = $8021)

    /// $A378 (vector $8021, every pass): redraws the attitude indicator when the pitch `$6D` or
    /// bank `$6F` high byte moved outside −2...+1 of the values drawn last (`$A354/$A355`).
    ///
    /// 1. Store the new values; span color X = 0 (pitch ≥ 0) or 3, and fill all 32 rows
    ///    ($97 down to $78) with it (`aiFillRows`, A = $1F).
    /// 2. If pitch_hi + $20 < $40 (within ±45°): off = `$A356[(pitch_hi + $20) / 2]`; the chord
    ///    ends are at angles bank_hi − off and (bank_hi ^ $80) + off: x = $29 + `$1961`(cos_hi,
    ///    $12) high byte (the carry of `$18B8` is the multiply's bias bit), y = $88 +
    ///    (sin_hi >> 3, arithmetic), into `$EB-$EE`.
    /// 3. `$8A` = $FF when the bank is negative, inverted when the pitch is negative; the other
    ///    span color (X = 3 for pitch ≥ 0, else 0); $85C0-$85C2 patched to jump to `aiSpan`,
    ///    `horizonBresenham`, then the split row's own three bytes written back.
    /// 4. When the ends lie on opposite sides of x = $2A (signs of x − $2A differ): with
    ///    |bank| < 90° and pitch ≥ 0, or |bank| ≥ 90° and pitch < 0, the rows above the higher
    ///    end are filled down to row $78 (`$E9` = min y − 1, A = min y − $79); otherwise the rows
    ///    below the lower end up to row $97 (`$E9` = $97, A = $97 − (max y + 1)), when any.
    ///
    /// Also writes `$98`, `$AD`, `$B7`, `$E9`, and what the raster routines write. Clobbers A, X, Y.
    public func drawAttitudeIndicator() {
        let m = mem
        let bank = m[0x6F], pitch = m[0x6D]
        var c = 11                       // bank change since the last redraw, low bit ignored
        var redraw: Bool
        switch (bank &- m[Self.aiLastAttitude + 1]) & 0xFE {
        case 0: c += 3; redraw = false
        case 0xFE: c += 6; redraw = false
        default: c += 7; redraw = true
        }
        if !redraw {
            c += 11                      // the same test on the pitch
            switch (pitch &- m[Self.aiLastAttitude]) & 0xFE {
            case 0: charge(c + 9); return
            case 0xFE: charge(c + 12); return
            default: c += 7
            }
        }
        // $A395: background fill.
        m[Self.aiLastAttitude + 1] = bank
        m[Self.aiLastAttitude] = pitch
        c += 16                      // remember both, background color 0 to start
        let background: UInt8
        if pitch & 0x80 == 0 { background = 0; c += 3 } else { background = 3; c += 4 }
        charge(c + 6)
        setSpanColor(background)
        m[0xE9] = 0x97
        charge(13)
        aiFillRows(0x1F)
        c = 9                           // pitch within ±45°?
        let index = pitch &+ 0x20
        if index >= 0x40 { charge(c + 11); return }
        // $A3BD: the chord ends.
        let offset = m[Self.aiPitchTable + Int(index >> 1)]
        m[0xAD] = offset
        m[0x98] = bank &- offset
        charge(c + 31)
        aiChordEnd(m[0x98], x: 0xEB, y: 0xEC)
        m[0x98] = (bank ^ 0x80) &+ offset
        charge(19)
        aiChordEnd(m[0x98], x: 0xED, y: 0xEE)
        // $A418: which side of the chord gets the spans.
        m[0x8A] = 0
        c = 8                               // clear the side flag, test the bank
        if bank & 0x80 == 0 { c += 3 } else { m[0x8A] = 0xFF; c += 7 }
        c += 5                                  // span color 3, test the pitch
        var spanColor: UInt8 = 3
        if pitch & 0x80 == 0 { c += 3 } else { m[0x8A] ^= 0xFF; spanColor = 0; c += 12 }
        charge(c + 6)
        setSpanColor(spanColor)
        m[Self.horizonSplitRowEntry] = 0x4C
        m[Self.horizonSplitRowEntry + 1] = 0xCA
        m[Self.horizonSplitRowEntry + 2] = 0xA4
        charge(24)
        horizonBresenham()
        m[Self.horizonSplitRowEntry] = 0xA4
        m[Self.horizonSplitRowEntry + 1] = 0xE9
        m[Self.horizonSplitRowEntry + 2] = 0xB9
        // $A454: the rows outside the chord's row range.
        let x1 = m[0xEB], x2 = m[0xED], y1 = m[0xEC], y2 = m[0xEE]
        m[0x98] = x1 &- 0x2A
        c = 38      // restore, then both ends against x = $2A
        if ((x1 &- 0x2A) ^ (x2 &- 0x2A)) & 0x80 == 0 { charge(c + 12); return }
        c += 9                          // opposite sides: is |bank| below 90°?
        let above: Bool
        if (bank &+ 0x40) & 0x80 == 0 {
            c += 5                              // yes: the pitch's sign decides
            if pitch & 0x80 == 0 { c += 2; above = true } else { c += 3; above = false }
        } else {
            c += 6                              // no: the pitch's sign decides, reversed
            if pitch & 0x80 != 0 { c += 3; above = true } else { c += 2; above = false }
        }
        if above {
            // $A46F: rows from min y - 1 up to $78.
            c += 6                              // the higher end
            let top: UInt8
            if y1 < y2 { top = y1; c += 3 } else { top = y2; c += 5 }
            m[0xE9] = top &- 1
            let count = top &- 0x79
            c += 12                      // start row and row count
            if count & 0x80 != 0 { charge(c + 11); return }
            charge(c + 9)
            aiFillRows(count)
        } else {
            // $A487: rows from $97 up to max y + 1.
            c += 6                              // the lower end
            let bottom: UInt8
            if y1 >= y2 { bottom = y1; c += 3 } else { bottom = y2; c += 5 }
            m[0xB7] = bottom &+ 1
            m[0xE9] = 0x97
            let count = 0x97 &- m[0xB7]
            c += 18              // start at row $97, count the rows up to the end
            if count & 0x80 != 0 { charge(c + 9); return }
            charge(c + 8)
            aiFillRows(count)
        }
        charge(6)
    }

    /// $A3CB-$A3EB (and $A3F6-$A416): one chord end at angle A: x = $29 + high byte of
    /// `mul8Half`(cos_hi, $12) and y = $88 + (sin_hi >> 3), stored at zero-page `x` / `y`.
    private func aiChordEnd(_ angle: UInt8, x xAddress: Int, y yAddress: Int) {
        let m = mem
        let cv = cos8(a: angle)
        charge(8)                               // cos_hi times $12
        let p = mul8Half(x: cv.x, y: 0x12, carry: cv.carry)
        m[xAddress] = p.y &+ 0x29
        charge(18)               // x stored, then the sine of the same angle
        let sv = sin8(a: m[0x98])
        let s = Int8(bitPattern: sv.x)
        m[yAddress] = UInt8(bitPattern: s >> 3) &+ 0x88
        charge(33)
    }

    // MARK: aiFillRows ($A4A0)

    /// $A4A0: fills A + 1 rows (from row `$E9` downwards) of the attitude-indicator columns 8-12
    /// (row offsets $40-$60) with the span pattern `$1A`. `$B7` counts down to $FF; `$8E/$8F` =
    /// the last row's base. Clobbers A, X, Y.
    public func aiFillRows(_ count: UInt8) {
        let m = mem
        var x = m[0xE9]
        var n = count
        let pattern = m[0x1A]
        var c = 6
        while true {
            let lo = m[Self.rowAddressLo + Int(x)], hi = m[Self.rowAddressHi + Int(x)]
            m[0x8E] = lo; m[0x8F] = hi
            for column in stride(from: 0x40, through: 0x60, by: 8) {
                m[Self.indirectY(lo, hi, UInt8(column))] = pattern
            }
            // The row pointer (its table read crosses a page from row $38), the five pattern
            // bytes, and both counters.
            c += 4 + (x >= 0x38 ? 1 : 0) + 60
            x &-= 1
            n &-= 1
            if n & 0x80 != 0 { c += 2; break }
            c += 3
        }
        m[0xB7] = n
        charge(c + 6)
    }

    // MARK: aiSpan ($A4CA)

    /// $A4CA: the attitude indicator's split row (reached through the jump patched over
    /// $85C0): on row `$E9`, a span from x to $33 when `$8A` = 0, else from $20 to x (`$1E` = the
    /// right end, A = length − 1, through `span`). X is preserved (`$B4`).
    public func aiSpan(x: UInt8) {
        charge(aiSpanBody(x: x))
    }

    @usableFromInline
    func aiSpanBody(x: UInt8) -> Int {
        let m = mem
        m[0xB4] = x
        let row = Int(m[0xE9])
        m[0x8E] = m[Self.rowAddressLo + row]
        m[0x8F] = m[Self.rowAddressHi + row]
        var c = 10 + (row >= 0x38 ? 1 : 0) + 13
        let length: UInt8
        if m[0x8A] == 0 {
            m[0x1E] = 0x33
            length = 0x33 &- x
            c += 15
        } else {
            m[0x1E] = x
            length = x &- 0x20
            c += 12
        }
        c += 6 + spanBody(length)
        return c + 9
    }
}
