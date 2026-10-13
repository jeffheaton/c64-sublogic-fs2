/// The sky/ground fill of the window ($840F-$86A3): the fill bytes from `$0880/$0882`, the
/// orientation swap $84FB, whole rows $8504 (through the raster unit's row filler $851B), split
/// rows $85C0 and the horizon Bresenham $8623.
///
/// The start of the horizon pass ($83A4-$840E) runs the 16-byte horizon display list through the
/// scenery interpreter with line drawing disabled, so the clipped horizon endpoints are left in
/// `$EB-$EE` (`$EC` = $FF: no horizon). That glue belongs to the scenery-VM port; `horizonFill`
/// continues from there.
extension Machine {
    /// $8458: the 7-byte horizon line display list (`1B 06 x1 y1 x2 y2 19`) whose endpoints
    /// `horizonFill` rewrites; area lists draw it with `09 90 08` (through `$0890`).
    public static let horizonLineList = 0x8458
    /// $85C0: the split row, patched to jump to `aiSpan` ($A4CA) while the attitude indicator
    /// draws its chord with `horizonBresenham`.
    public static let horizonSplitRowEntry = 0x85C0

    // MARK: horizonFill ($840F, the tail of $83A4 = $8003)

    /// $840F: fills all 112 window rows with the sky and ground patterns, given the horizon
    /// endpoints `$EB-$EE` captured by the horizon pass (`$EC` bit 7 set: no horizon).
    ///
    /// - `$EF` (below/left of the line) = `$0882` if 0 or $FF, else $AA; `$F0` (above) = `$0880`
    ///   if 0 or $FF, else $55.
    /// - No horizon: `$0890` = 0, rows $6F..0 get `$EF`, swapped first when the effective pitch
    ///   `$73` is negative (nose up: sky).
    /// - Otherwise `$0890` = $8458 and the list's endpoints are rewritten; `$F1`/`$F2` = the row
    ///   range of the line ($844B); rows above it are filled whole with `$EF`, the crossed rows by
    ///   `horizonBresenham`, the rows below with `$EF` again, with `horizonColorSwap` applied
    ///   before each part as the endpoints' window edges dictate (an endpoint on x = 0 or $9F or
    ///   on y = 0 tells which side of the line is the sky).
    ///
    /// Also writes `$E9`, `$F3`, and everything the fills write. Clobbers A, X, Y.
    public func horizonFill() {
        let m = mem
        var c = 4                                   // the ground fill byte
        var ground = m[0x0882]
        if ground == 0 { c += 3 } else if ground == 0xFF { c += 7 } else { ground = 0xAA; c += 8 }
        m[0xEF] = ground
        c += 7                                  // store it; the sky fill byte
        var sky = m[0x0880]
        if sky == 0 { c += 3 } else if sky == 0xFF { c += 7 } else { sky = 0x55; c += 8 }
        m[0xF0] = sky
        m[0xF2] = 0
        m[0xF1] = 0x6F
        c += 16                  // store it, reset the row range, test for a horizon
        if m[0xEC] & 0x80 != 0 {
            // $8435: no horizon.
            m[0x0890] = 0; m[0x0891] = 0
            m[0xF2] &-= 1
            c += 22          // clear the list pointer, `$F2` − 1, read the pitch
            if m[0x73] & 0x80 != 0 {
                charge(c + 8)
                horizonColorSwap()
                c = 0
            } else {
                c += 3
            }
            charge(c + 3)                           // on to the shared tail at $84EE
            horizonFillBelow()
            return
        }
        // $845F: the horizon line list and the line's row range.
        m[0x0890] = 0x58; m[0x0891] = 0x84
        m[Self.horizonLineList + 4] = m[0xED]
        m[Self.horizonLineList + 3] = m[0xEC]
        c += 35 // point at the list, y1 and x2 into it, widen the range by y1
        c += horizonRowRange(m[0xEC])
        m[Self.horizonLineList + 5] = m[0xEE]
        c += 13
        c += horizonRowRange(m[0xEE])
        let x1 = m[0xEB], y1 = m[0xEC], x2 = m[0xED], y2 = m[0xEE]
        m[Self.horizonLineList + 2] = x1
        c += 7                                  // x1 into the list
        // $8483: which side is the sky above the line.
        var swap: Bool
        if x1 == 0 {
            c += 3; swap = true
        } else if y1 == 0 {
            c += 8; swap = false
        } else if x2 == 0 {
            c += 13; swap = false
        } else if y2 == 0 {
            c += 18; swap = true
        } else if x1 == 0x9F {
            c += 30; swap = false
        } else {
            c += 30; swap = true
        }
        if swap {
            charge(c + 6)
            horizonColorSwap()
            c = 0
        }
        // $84A5: the rows above the line.
        c += 3                                      // any rows above the line?
        let top = m[0xF1]
        if top != 0 {
            m[0xF3] = top
            m[0xE9] = top &- 1
            charge(c + 16)
            fillWholeRows()
            c = 0
        } else {
            c += 3
        }
        // $84B1: orientation for the crossed rows.
        c += 3                                      // does the line start on the left edge?
        if x1 == 0 {
            c += 8                          // yes: the slope's sign decides
            if y2 >= y1 { c += 3; swap = true } else { c += 5; swap = false }
        } else {
            c += 6                              // does it end there?
            if x2 != 0 {
                c += 3; swap = false
            } else {
                c += 8                      // yes: the slope's sign decides
                if y1 < y2 { c += 3; swap = false } else { c += 2; swap = true }
            }
        }
        if swap {
            charge(c + 6)
            horizonColorSwap()
            c = 0
        }
        charge(c + 6)                               // the crossed rows
        horizonBresenham()
        // $84CE: the rows below the line, unless it ends on the bottom row.
        c = 5                                   // does the line end on the bottom row?
        if m[0xF2] == 0x6F { charge(c + 9); return }
        c += 5                                  // no: the same edge tests as above
        if x1 == 0 {
            c += 8                          // starts on the left edge: the slope decides
            if y2 < y1 { c += 3; swap = true } else { c += 5; swap = false }
        } else {
            c += 6                              // does it end there?
            if x2 != 0 {
                c += 3; swap = false
            } else {
                c += 8                      // yes: the slope decides
                if y1 >= y2 { c += 3; swap = false } else { c += 2; swap = true }
            }
        }
        if swap {
            charge(c + 6)
            horizonColorSwap()
            c = 0
        }
        charge(c)
        horizonFillBelow()
    }

    /// $84EE: rows $6F down to `$F2` + 1 with `$EF` (`$E9` = $6F, `$F3` = $6F − `$F2`), then
    /// returns from `horizonFill`.
    private func horizonFillBelow() {
        let m = mem
        m[0xE9] = 0x6F
        m[0xF3] = 0x6F &- m[0xF2]
        charge(19)
        fillWholeRows()
        charge(6)
    }

    /// $844B: widens the row range `$F1` (min) / `$F2` (max) by A. Returns the cycles, including
    /// the return.
    private func horizonRowRange(_ a: UInt8) -> Int {
        let m = mem
        var c = 3
        if a < m[0xF1] { m[0xF1] = a; c += 5 } else { c += 3 }
        c += 3
        if a >= m[0xF2] { m[0xF2] = a; c += 5 } else { c += 3 }
        return c + 6
    }

    // MARK: horizonColorSwap ($84FB)

    /// $84FB: exchanges the fill bytes `$EF` and `$F0`. Clobbers X, Y.
    public func horizonColorSwap() {
        let m = mem
        let g = m[0xEF]
        m[0xEF] = m[0xF0]
        m[0xF0] = g
        charge(18)
    }

    // MARK: fillWholeRows ($8504)

    /// $8504: fills `$F3` whole rows (0 means 256) with `$EF` through the unrolled filler $851B,
    /// from row `$E9` downwards (rows through the row tables; X counts down and wraps). Leaves
    /// `$8E/$8F` at the last row's base + $100 and `$F3` = 0. Clobbers A, X, Y.
    public func fillWholeRows() {
        let m = mem
        var x = m[0xE9]
        var count = m[0xF3]
        var c = 3
        repeat {
            m[0x8E] = m[Self.rowAddressLo + Int(x)]
            m[0x8F] = m[Self.rowAddressHi + Int(x)]
            c += 4 + (x >= 0x38 ? 1 : 0) + 19
            c += unrolledRowFillBody(entry: 0x851B, stop: 0x85BF, pattern: m[0xEF], y: 0).cycles
            x &-= 1
            count &-= 1
            c += 7 + (count != 0 ? 3 : 2)
        } while count != 0
        m[0xF3] = 0
        charge(c + 6)
    }

    // MARK: horizonSplitRow ($85C0)

    /// $85C0: fills row `$E9` with `$EF` from pixel 0 through pixel x and `$F0` to its right.
    ///
    /// The whole bytes come from two calls into the unrolled filler $851B. A return opcode is
    /// planted over the first byte of column (x + 4) >> 2's entry (offset `(x + 4) & $FC`, +2
    /// from column 32; saved in `$F5`), so the first call fills up to that column with `$EF`.
    /// The entry's original byte is then put back, the second call's target (`$85FC/$85FD`)
    /// aimed at that same column, and the filler run from there to its end with `$F0`.
    /// Unless x & 3 = 3, the byte of x's column is then rebuilt: `$F0` shifted right two bits per
    /// pixel 0..x & 3 with `$EF`'s low bits rotated in from `$AF` (left `$EF` >> 2·(x & 3 + 1)),
    /// stored at `$14DA[x]` (`$8F` decremented again for x < 128). X is preserved (`$B4` = x).
    /// x must be at most 159: larger values plant the return past the filler's end.
    public func horizonSplitRow(x: UInt8) {
        charge(horizonSplitRowBody(x: x))
    }

    @usableFromInline
    func horizonSplitRowBody(x: UInt8) -> Int {
        let m = mem
        let row = Int(m[0xE9])
        m[0x8E] = m[Self.rowAddressLo + row]
        m[0x8F] = m[Self.rowAddressHi + row]
        var c = 7 + (row >= 0x38 ? 1 : 0) + 18   // row pointer, the column after x's byte
        var offset = (x &+ 4) & 0xFC
        if offset & 0x80 != 0 { offset &+= 2; c += 6 } else { c += 3 }
        let plant = 0x851B + Int(offset)
        m[plant] = 0x60
        m[0xF5] = offset
        c += 21                  // plant the return, remember the column, first call
        c += unrolledRowFillBody(entry: 0x851B, stop: plant, pattern: m[0xEF], y: offset).cycles
        let saved = Int(m[0xF5])
        m[0x851B + saved] = 0xA0
        let entry = 0x851B + saved
        m[0x85FC] = UInt8(truncatingIfNeeded: entry)
        m[0x85FD] = UInt8(truncatingIfNeeded: entry >> 8)
        c += 37
        c += unrolledRowFillBody(entry: Int(m[0x85FC]) | Int(m[0x85FD]) << 8, stop: 0x85BF,
                                 pattern: m[0xF0], y: UInt8(saved)).cycles
        c += 6                              // is a partial byte left over?
        let px = x & 3
        if px == 3 { return c + 9 }
        m[0xB4] = x
        var af = m[0xEF]
        var a = m[0xF0]
        c += 16                  // save x, set up the two patterns
        var k = px
        while true {
            a = a >> 1 | (af & 1) << 7; af >>= 1
            a = a >> 1 | (af & 1) << 7; af >>= 1
            c += 16                  // one pixel of the left pattern shifted in
            if k == 0 { c += 2; break }
            k -= 1
            c += 3
        }
        m[0xAF] = af
        c += 3                                      // restore x
        if x & 0x80 != 0 { c += 3 } else { m[0x8F] &-= 1; c += 7 }
        let column = m[Self.columnOffset + Int(x)]
        m[Self.indirectY(m[0x8E], m[0x8F], column)] = a
        return c + 4 + (x >= 0x26 ? 1 : 0) + 12
    }

    // MARK: horizonBresenham ($8623)

    /// $8623: walks the line ($EB,$EC)-($ED,$EE) row by row and calls the split row ($85C0) with
    /// X = the line's x for every row it enters, starting with ($EB,$EC).
    ///
    /// `$18` = |dx|, `$19` = |dy|. The x step at $8678/$868C is patched to an increment when
    /// x2 ≥ x1, else a decrement; the row step at $8679/$869A likewise moves `$E9` down the window
    /// when y2 ≥ y1, else up (self-modified code: the loops carry no direction tests).
    /// dy ≥ dx: `$93` = `$F4` = dy; per step error −= dx, on borrow error += dy and x steps; then
    /// the row steps and the row is split. Otherwise `$93` = dx, error = dx − dy; per step x
    /// steps, error −= dy, and only on borrow error += dx, the row steps and the row is split.
    /// The split row is whatever $85C0 holds: the attitude indicator's patch sends every row to
    /// `aiSpan`.
    public func horizonBresenham() {
        let m = mem
        let x1 = m[0xEB], y1 = m[0xEC], x2 = m[0xED], y2 = m[0xEE]
        var c = 10                       // dx, assuming x steps right
        let xForward = x2 >= x1
        let dx: UInt8
        if xForward { dx = x2 &- x1; c += 3 } else { dx = x1 &- x2; c += 8 }
        m[0x18] = dx
        m[0x8678] = xForward ? 0xE8 : 0xCA
        m[0x868C] = xForward ? 0xE8 : 0xCA
        c += 21              // patch both x steps; dy, assuming rows step down
        let rowsDown = y2 >= y1
        let dy: UInt8
        if rowsDown { dy = y2 &- y1; c += 3 } else { dy = y1 &- y2; c += 8 }
        m[0x19] = dy
        m[0x8679] = rowsDown ? 0xE6 : 0xC6
        m[0x869A] = rowsDown ? 0xE6 : 0xC6
        m[0xE9] = y1
        c += 26              // patch both row steps, start at (x1, y1) and split it
        // What the call to $85C0 runs: the split row, or the attitude indicator's jump to `aiSpan`.
        let patched = m[Self.horizonSplitRowEntry] == 0x4C
        if patched {
            assert(u16(Self.horizonSplitRowEntry + 1) == 0xA4CA, "unexpected patch of the split row")
        }
        @inline(__always) func splitRow(_ x: UInt8) -> Int {
            patched ? 3 + aiSpanBody(x: x) : horizonSplitRowBody(x: x)
        }
        var x = x1
        c += splitRow(x)
        c += 6                                  // a single point?
        if dx | dy == 0 { charge(c + 8); return }
        c += 9                              // which axis is the major one
        var err: UInt8
        var count: UInt8
        if dy >= dx {
            // $8667: y-major, a split every row.
            m[0x93] = dy
            err = dy
            count = dy
            c += 8                          // counter and error start at dy
            repeat {
                let (e, borrow) = err.subtractingReportingOverflow(dx)
                err = e
                c += 11                  // error −= dx
                if borrow {
                    err = err &+ dy
                    x = xForward ? x &+ 1 : x &- 1
                    c += 10              // borrow: error += dy, x steps
                } else {
                    c += 3
                }
                m[0xF4] = err
                m[0xE9] = rowsDown ? m[0xE9] &+ 1 : m[0xE9] &- 1
                c += 11                          // next row, split it
                c += splitRow(x)
                count &-= 1
                c += 5 + (count != 0 ? 3 : 2)       // count the step
            } while count != 0
        } else {
            // $8683: x-major, a split only where the row changes.
            m[0x93] = dx
            err = dx &- dy
            m[0xF4] = err
            count = dx
            c += 17              // counter = dx, error = dx − dy
            repeat {
                x = xForward ? x &+ 1 : x &- 1
                let (e, borrow) = err.subtractingReportingOverflow(dy)
                err = e
                c += 13              // x steps, error −= dy
                if borrow {
                    err = err &+ dx
                    m[0xF4] = err
                    m[0xE9] = rowsDown ? m[0xE9] &+ 1 : m[0xE9] &- 1
                    c += 19          // borrow: error += dx, next row, split it
                    c += splitRow(x)
                } else {
                    m[0xF4] = err
                    c += 3
                }
                count &-= 1
                c += 5 + (count != 0 ? 3 : 2)       // count the step
            } while count != 0
        }
        m[0x93] = 0
        charge(c + 6)
    }
}
