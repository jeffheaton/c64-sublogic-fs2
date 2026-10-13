/// Point plot ($99FD) and the multicolor Bresenham line ($9A1D), with the dotted plot ($9B80).
///
/// Coordinates are multicolor pixels (x 0-159) and bitmap rows (0-199, through the row tables
/// $0200/$02C8, so the window rows follow the double buffer). The line keeps the original's
/// pointer walk: it never consults the row tables after its first pixel, stepping the row
/// pointer $8E/$8F by ±1 inside a character cell and ±$139 across character rows.
extension Machine {
    /// $0200 / $02C8: bitmap row base, high and low bytes, rows 0-199.
    public static let rowAddressHi = 0x0200
    public static let rowAddressLo = 0x02C8
    /// $14DA: multicolor x -> byte offset in the row, `((x >> 2) * 8) & $FF`.
    public static let columnOffset = 0x14DA

    /// Registers left by `plot`, which `drawLine` keeps using (X -> $B2, Y -> $B3).
    public struct PlotRegisters: Equatable, Sendable {
        /// A: the byte stored.
        public var a: UInt8
        /// X: the pixel index `x & 3`.
        public var x: UInt8
        /// Y: the byte offset `$14DA[x]`.
        public var y: UInt8
    }

    // MARK: plot ($99FD = $800C)

    /// $99FD (vector $800C): plots pixel (x, row) with the current pen of the plot site ($9A14).
    /// Sets the row pointer $8E/$8F to the row base, +$100 when x >= 128.
    @discardableResult
    public func plot(x: UInt8, row: UInt8) -> PlotRegisters {
        let (regs, cycles) = plotBody(x: x, row: row)
        charge(cycles)
        return regs
    }

    @usableFromInline
    @inline(__always)
    func plotBody(x: UInt8, row: UInt8) -> (PlotRegisters, Int) {
        let m = mem
        let r = Int(row)
        let lo = m[Self.rowAddressLo + r]
        var hi = m[Self.rowAddressHi + r]
        // The row base into $8E/$8F (the low table read crosses a page for rows >= $38).
        var cycles = 4 + (row >= 0x38 ? 1 : 0) + 12
        if x & 0x80 != 0 { hi &+= 1; cycles += 7 } else { cycles += 3 }   // x >= 128: a page up
        m[0x8E] = lo
        m[0x8F] = hi
        let col = m[Self.columnOffset + Int(x)]
        cycles += 4 + (x >= 0x26 ? 1 : 0) + 4                    // the byte offset, the pixel index
        let px = x & 3
        let addr = Self.indirectY(lo, hi, col)
        var af = m[0xAF]
        let w = pixelWriter(.plot)
        cycles += w.write(m, addr, px, crossed: Int(lo) + Int(col) > 0xFF, count: m[0xF3], af: &af)
        if w.dotted { m[0xAF] = af }
        return (PlotRegisters(a: m[addr], x: px, y: col), cycles + 6)          // the return
    }

    // MARK: drawLine ($9A1D = $8009)

    /// $9A1D (vector $8009): draws the line ($EB,$EC)-($ED,$EE) with the current pen.
    ///
    /// The endpoints are swapped (in memory) so that ($EB,$EC) is the right one; it is plotted
    /// first and x only ever steps left. $18 = |dx|, $19 = |dy|, $F3 = major delta (steps),
    /// $F4 = error, starting at major >> 1. Each step: error -= minor; on borrow error += major
    /// and the minor axis steps. One of four loops runs (y-major up $9A7C / down $9ABD, x-major
    /// up $9AFE / down $9B3F), each with its own patched pixel write. Also writes $B2/$B3 (the
    /// start pixel index and byte offset) and $8E/$8F. Clobbers A, X, Y.
    public func drawLine() {
        charge(drawLineBody())
    }

    @usableFromInline
    func drawLineBody() -> Int {
        let m = mem
        var x1 = m[0xEB], y1 = m[0xEC]
        let x2 = m[0xED], y2 = m[0xEE]
        var cycles = 8                       // dx
        let dx: UInt8
        if x1 >= x2 {
            dx = x1 &- x2
            cycles += 3                              // already right to left
        } else {
            dx = x2 &- x1                            // negated
            m[0xED] = x1; m[0xEB] = x2
            m[0xEE] = y1; m[0xEC] = y2
            x1 = x2; y1 = y2
            cycles += 2 + 2 + 2 + 8 * 3
        }
        let yEnd = m[0xEE]
        m[0x18] = dx
        cycles += 15                      // |dx| kept, the start plotted
        let (start, plotCycles) = plotBody(x: x1, row: y1)
        cycles += plotCycles
        m[0xB2] = start.x
        m[0xB3] = start.y
        cycles += 16              // the start's index and offset kept, dy
        let dy: UInt8
        let down: Bool                               // X = $FF: rows increase
        if y1 >= yEnd {
            dy = y1 &- yEnd; down = false
            cycles += 3
        } else {
            dy = yEnd &- y1; down = true
            cycles += 8
        }
        m[0x19] = dy
        cycles += 6                              // |dy| kept, a single point?
        if dx | dy == 0 { return cycles + 8 }    // one point: the return
        cycles += 9                          // which axis is major?
        let major: UInt8
        if dy >= dx {
            major = dy
            cycles += 12              // y-major: the step count, the error at half
            cycles += down ? 5 : 3               // the dispatch to the up or down loop
        } else {
            major = dx
            cycles += 16          // x-major: the step count, the error at half
            cycles += down ? 5 : 6           // the dispatch to the up or down loop
        }
        m[0xF3] = major
        m[0xF4] = major >> 1
        cycles += 6                              // the start's index and offset
        if dy >= dx {
            cycles += lineYMajor(dx: dx, dy: dy, down: down, px: start.x, col: start.y)
        } else {
            cycles += lineXMajor(dx: dx, dy: dy, down: down, px: start.x, col: start.y)
        }
        return cycles + 6                            // the return
    }

    /// The y-major loops $9A7C (up) and $9ABD (down): a row step every iteration, an x step on
    /// error borrow.
    @inline(__always)
    private func lineYMajor(dx: UInt8, dy: UInt8, down: Bool, px startPx: UInt8, col startCol: UInt8) -> Int {
        let m = mem
        let w = pixelWriter(down ? .lineYMajorDown : .lineYMajorUp)
        let cellMask = m[0x1B]
        var lo = m[0x8E], hi = m[0x8F]
        var err = m[0xF4], count = m[0xF3]
        var px = startPx, col = startCol
        var af = m[0xAF]
        var cycles = 0
        repeat {
            // Error step: the minor delta subtracted.
            let (e, borrow) = err.subtractingReportingOverflow(dx)
            err = e
            if !borrow {
                cycles += 14
            } else {
                err &+= dy
                cycles += 21         // a borrow: the major delta added back, x one pixel left
                if px != 0 {
                    px &-= 1; cycles += 3            // within the byte
                } else {
                    px = 3
                    cycles += 12  // pixel 3 of the byte to the left (8 bytes back)
                    let (c, b) = col.subtractingReportingOverflow(8)
                    col = c
                    if b { hi &-= 1; cycles += 7 } else { cycles += 3 }
                }
            }
            if down {
                // One row down: +1 inside the character cell; when the cell mask `$1B` shows the
                // cell was left, another +$138 to the next character row.
                lo &+= 1
                cycles += 11
                if lo & cellMask != 0 {
                    cycles += 3
                } else {
                    let s = UInt16(lo) + 0x38
                    lo = UInt8(truncatingIfNeeded: s); hi = hi &+ 1 &+ UInt8(s >> 8)
                    cycles += 17           // the character row step
                }
            } else {
                // One row up: at the top of a cell (by the mask `$1B`) first back to the previous
                // character row (-$138), then -1.
                cycles += 6
                if lo & cellMask != 0 {
                    cycles += 3
                } else {
                    let s = UInt16(lo) + 0xC8
                    lo = UInt8(truncatingIfNeeded: s); hi = hi &+ 0xFE &+ UInt8(s >> 8)
                    cycles += 17           // the character row step
                }
                lo &-= 1
                cycles += 5
            }
            let addr = Self.indirectY(lo, hi, col)
            cycles += w.write(m, addr, px, crossed: Int(lo) + Int(col) > 0xFF, count: count, af: &af)
            count &-= 1
            cycles += 5 + (count != 0 ? 3 : 2)       // the step count
        } while count != 0
        m[0x8E] = lo; m[0x8F] = hi
        m[0xF3] = count; m[0xF4] = err
        if w.dotted { m[0xAF] = af }
        return cycles
    }

    /// The x-major loops $9AFE (up) and $9B3F (down): an x step every iteration, a row step on
    /// error borrow.
    @inline(__always)
    private func lineXMajor(dx: UInt8, dy: UInt8, down: Bool, px startPx: UInt8, col startCol: UInt8) -> Int {
        let m = mem
        let w = pixelWriter(down ? .lineXMajorDown : .lineXMajorUp)
        let cellMask = m[0x1B]
        var lo = m[0x8E], hi = m[0x8F]
        var err = m[0xF4], count = m[0xF3]
        var px = startPx, col = startCol
        var af = m[0xAF]
        var cycles = 0
        repeat {
            // Error step: the minor delta subtracted.
            let (e, borrow) = err.subtractingReportingOverflow(dy)
            err = e
            if !borrow {
                cycles += 14
            } else {
                err &+= dx
                cycles += 19             // a borrow: the major delta added back
                if down {
                    // One row down: +1 inside the character cell; when the cell mask `$1B` shows
                    // the cell was left, another +$138 to the next character row.
                    lo &+= 1
                    cycles += 11
                    if lo & cellMask != 0 {
                        cycles += 3
                    } else {
                        let s = UInt16(lo) + 0x38
                        lo = UInt8(truncatingIfNeeded: s); hi = hi &+ 1 &+ UInt8(s >> 8)
                        cycles += 17           // the character row step
                    }
                } else {
                    // One row up: at the top of a cell (by the mask `$1B`) first back to the
                    // previous character row (-$138), then -1.
                    cycles += 6
                    if lo & cellMask != 0 {
                        cycles += 3
                    } else {
                        let s = UInt16(lo) + 0xC8
                        lo = UInt8(truncatingIfNeeded: s); hi = hi &+ 0xFE &+ UInt8(s >> 8)
                        cycles += 17           // the character row step
                    }
                    lo &-= 1
                    cycles += 5
                }
            }
            // X step: one pixel left; past the byte's first pixel, pixel 3 of the byte 8 back (the
            // high byte steps down on a borrow).
            cycles += 2
            if px != 0 {
                px &-= 1; cycles += 3
            } else {
                px = 3
                cycles += 12
                let (c, b) = col.subtractingReportingOverflow(8)
                col = c
                if b { hi &-= 1; cycles += 7 } else { cycles += 3 }
            }
            let addr = Self.indirectY(lo, hi, col)
            cycles += w.write(m, addr, px, crossed: Int(lo) + Int(col) > 0xFF, count: count, af: &af)
            count &-= 1
            cycles += 5 + (count != 0 ? 3 : 2)       // the step count
        } while count != 0
        m[0x8E] = lo; m[0x8F] = hi
        m[0xF3] = count; m[0xF4] = err
        if w.dotted { m[0xAF] = af }
        return cycles
    }
}
