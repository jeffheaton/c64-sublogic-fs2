/// Horizontal spans ($9996 short, $9910 long) and the unrolled row filler at $851B they share
/// with the horizon fill.
extension Machine {
    // MARK: span ($9996 = $801B)

    /// $9996 (vector $801B): fills A+1 pixels leftwards from x = $1E (inclusive) on the row at
    /// $8E/$8F (a row base from the row tables), with the span color of `setSpanColor`: partial
    /// bytes through the patched pixel writes, whole bytes with the pattern $1A.
    ///
    /// Spans of 25 pixels or more (A >= $18) go to `longSpan`. A short span copies the row pointer
    /// to $9A/$9B (+$100 when x >= 128) and walks it; $8E/$8F are left unchanged. Clobbers A, X, Y.
    public func span(_ lengthMinusOne: UInt8) {
        charge(spanBody(lengthMinusOne))
    }

    @usableFromInline
    func spanBody(_ a: UInt8) -> Int {
        let m = mem
        m[0xF3] = a
        var cycles = 5                           // the count kept, the long-span test
        if a >= 0x18 { return cycles + 5 + longSpanBody() }   // long: on to $9910
        cycles += 3                                  // short
        var count = a &+ 1                           // the pixel count
        let lo = m[0x8E]
        var hi = m[0x8F]
        m[0x9A] = lo
        let x = m[0x1E]
        cycles += 22          // the count, the row pointer copy, x
        if x & 0x80 != 0 { hi &+= 1; cycles += 7 } else { cycles += 3 }
        var col = m[Self.columnOffset + Int(x)]
        var px = x & 3
        cycles += 4 + (x >= 0x26 ? 1 : 0) + 6   // the byte offset, the pixel index
        let pattern = m[0x1A]
        let w = pixelWriter(.spanShort)
        var af = m[0xAF]
        var wholeBytes = px == 3          // on a byte's last pixel: straight to whole bytes ($99DB)
        cycles += wholeBytes ? 3 : 2
        while true {
            if !wholeBytes {
                // $99BA: one pixel, then the next to the left until the byte or the count runs out.
                let addr = Self.indirectY(lo, hi, col)
                cycles += w.write(m, addr, px, crossed: Int(lo) + Int(col) > 0xFF, count: count, af: &af)
                cycles += 2                          // the next pixel
                if px != 0 {
                    px &-= 1
                    count &-= 1
                    cycles += 7                  // still in the byte: the count down
                    if count != 0 { cycles += 3; continue }
                    cycles += 8                  // done: the return
                    break
                }
                // $99CC: the next byte to the left.
                px = 0xFF
                count &-= 1
                cycles += 8                      // the byte ran out: the count down
                if count == 0 { cycles += 9; break }      // done: the return
                px = 3
                cycles += 12      // pixel 3 of the byte to the left (8 bytes back)
                let (c, borrow) = col.subtractingReportingOverflow(8)
                col = c
                if borrow { hi &-= 1; cycles += 7 } else { cycles += 3 }
                wholeBytes = true
            }
            // $99DB: count >> 2 whole bytes with the pattern, then the remaining count & 3 pixels.
            cycles += 7                      // the whole-byte count
            var n = count >> 2
            if n == 0 { cycles += 3; wholeBytes = false; continue }   // none: single pixels ($99BA)
            cycles += 4                          // some: counted in X
            repeat {
                m[Self.indirectY(lo, hi, col)] = pattern
                cycles += 17      // the pattern stored, 8 bytes back
                let (c, borrow) = col.subtractingReportingOverflow(8)
                col = c
                if borrow { hi &-= 1; cycles += 7 } else { cycles += 3 }
                n &-= 1
                cycles += 2 + (n != 0 ? 3 : 2)       // the byte loop
            } while n != 0
            px = 3
            count &= 3
            cycles += 10                  // pixel 3, the leftover count
            if count != 0 { cycles += 3; wholeBytes = false; continue }
            cycles += 8                          // none left: the return
            break
        }
        m[0x9B] = hi
        m[0xF3] = count
        if w.dotted { m[0xAF] = af }
        return cycles
    }

    // MARK: longSpan ($9910)

    /// $9910: the long span (entered from `span` for A >= $18). The left partial byte goes through
    /// the patched writes at $992A while $AF counts x up to the byte boundary; the whole bytes are
    /// filled by calling into the unrolled row filler at $851B + 4·($AF >> 2) (+2 from column 32,
    /// past its high-byte step), with a return opcode planted on the store of x's column ($F5 = its
    /// offset; the store opcode $91 is put back afterwards); the call's operand at $996B/$996C is
    /// self-modified; the right partial byte goes through $9986 (or is stored whole when
    /// x & 3 = 3). $9B saves $8F, which is restored. Clobbers A, X, Y.
    public func longSpan() {
        charge(longSpanBody())
    }

    @usableFromInline
    func longSpanBody() -> Int {
        let m = mem
        let lo = m[0x8E]
        var hi = m[0x8F]
        m[0x9B] = hi
        let x = m[0x1E]
        var left = x &- m[0xF3]                      // $AF: the leftmost pixel
        var cycles = 19       // `$8F` saved, the leftmost pixel into `$AF`
        if left & 0x80 != 0 { hi &+= 1; cycles += 7 } else { cycles += 3 }
        var y = m[Self.columnOffset + Int(left)]
        cycles += 4 + (left >= 0x26 ? 1 : 0) + 2     // its byte offset, its pixel index
        var af = m[0xAF]
        if left & 3 == 0 {
            cycles += 3                              // byte-aligned: no left part
        } else {
            // $9928: pixels (left & 3)..3 of the left byte.
            cycles += 4                          // a left part
            let w = pixelWriter(.spanLongLeft)
            var px = left & 3
            let count = m[0xF3]
            repeat {
                let addr = Self.indirectY(lo, hi, y)
                cycles += w.write(m, addr, px, crossed: Int(lo) + Int(y) > 0xFF, count: count, af: &af)
                left &+= 1
                px &+= 1
                cycles += 9 + (px != 4 ? 3 : 2)   // x and the pixel index up to the byte boundary
            } while px != 4
            if w.dotted { m[0xAF] = af }
            cycles += 5                          // into the right half?
            if left == 0x80 { hi &+= 1; cycles += 7 } else { cycles += 3 }
        }
        m[0xAF] = left
        // $9941: a return opcode planted on the store of x's column.
        var stop = Int(x & 0xFC)
        cycles += 5                              // x's column
        if x & 0x80 != 0 { stop += 2; cycles += 6 } else { cycles += 3 }
        m[0x851D + stop] = 0x60
        m[0xF5] = UInt8(stop)
        cycles += 12                      // planted, its offset kept in `$F5`
        // The entry point: the index load of the column at `$AF`.
        var entry = Int(left & 0xFC)
        cycles += 5                              // the leftmost whole column
        if left & 0x80 != 0 { entry += 2; cycles += 6 } else { cycles += 3 }
        let target = 0x851B + entry
        m[0x996B] = UInt8(target & 0xFF)
        m[0x996C] = UInt8(target >> 8)
        cycles += 16              // the call's operand patched
        let pattern = m[0x1A]
        m[0x8F] = hi
        cycles += 9                              // the pattern, the call
        let fill = unrolledRowFillBody(entry: target, stop: 0x851D + stop, pattern: pattern, y: y)
        y = fill.y
        cycles += fill.cycles
        hi = m[0x8F]
        m[0x851D + Int(m[0xF5])] = 0x91
        cycles += 17              // the store put back, the right byte's pixel index
        if x & 3 == 3 {
            m[Self.indirectY(lo, hi, y)] = pattern
            cycles += 14                  // a full right byte: the pattern
        } else {
            // $9984: pixels (x & 3)..0 of the right byte.
            cycles += 5                          // a partial right byte
            let w = pixelWriter(.spanLongRight)
            var px = x & 3
            let count = m[0xF3]
            let addr = Self.indirectY(lo, hi, y)
            let crossed = Int(lo) + Int(y) > 0xFF
            while true {
                cycles += w.write(m, addr, px, crossed: crossed, count: count, af: &af) + 2  // next
                if px == 0 { cycles += 2; break }    // the last pixel
                px &-= 1
                cycles += 3
            }
            if w.dotted { m[0xAF] = af }
        }
        m[0x8F] = m[0x9B]
        return cycles + 12                    // `$8F` restored, the return
    }

    // MARK: unrolledRowFill ($851B)

    /// $851B: the unrolled row filler: for each of the 40 byte columns of a row, an index load of
    /// the column's offset (8k) and a store of the pattern through `$8E/$8F`; after column 31
    /// ($859B) the pointer's high byte steps up, and at $85BD the filler resets the index to 0 and
    /// returns.
    ///
    /// Callers cut it short by planting a return opcode ($60) on one of its instructions and
    /// calling into it at a column's index load: `longSpan` plants on a column's store ($851D +
    /// offset), the horizon fill ($85C0) on a column's index load. This runs the instructions from
    /// `entry` up to the planted return at `stop` (pass $85BF for the filler's own return), storing
    /// `pattern`; the caller writes the planted byte itself, as the original does (debug builds
    /// assert that `stop` holds a return opcode, since the original would run past it otherwise).
    /// `y` is the Y register on entry (used only when `entry` is a store). Returns Y on exit;
    /// charges the cycles (without the caller's call).
    @discardableResult
    public func unrolledRowFill(entry: Int, stop: Int, pattern: UInt8, y: UInt8 = 0) -> UInt8 {
        let r = unrolledRowFillBody(entry: entry, stop: stop, pattern: pattern, y: y)
        charge(r.cycles)
        return r.y
    }

    @usableFromInline
    func unrolledRowFillBody(entry: Int, stop: Int, pattern: UInt8, y: UInt8) -> (y: UInt8, cycles: Int) {
        let m = mem
        // The original stops at the planted return, so the caller must have planted it.
        assert(m[stop] == 0x60, "unrolledRowFill: no RTS planted at the stop address")
        let lo = m[0x8E]
        var hi = m[0x8F]
        var y = y
        var pc = entry
        var cycles = 6                               // the planted return
        while pc != stop && pc < 0x85BF {
            if pc == 0x859B {                        // the high-byte step after column 31
                hi &+= 1
                cycles += 5
            } else {
                let offset = pc < 0x859B ? pc - 0x851B : pc - 0x859D
                if offset & 3 == 0 {                 // a column's index load
                    y = pc == 0x85BD ? 0 : UInt8(truncatingIfNeeded: offset << 1)
                    cycles += 2
                } else {                             // a column's store
                    m[Self.indirectY(lo, hi, y)] = pattern
                    cycles += 6
                }
            }
            pc += 2
        }
        m[0x8F] = hi
        return (y, cycles)
    }
}
