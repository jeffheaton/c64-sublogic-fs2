/// The 3x5 font text renderer ($1D54-$1EC9): number formatting, text records and record lists,
/// and the window clear used by the text menus.
///
/// A text record is `[row][x][ASCII...][terminator]`: `row` is a bitmap row (through the row
/// tables), `x` a multicolor pixel column (2 hi-res pixels on the panel). Any byte below $20 or
/// from $A0 up ends it. A list of records ends with a record whose first two bytes are 0.
/// Each character is an opaque 4x5 cell of pen 3 drawn with the glyph words at $1634; codes
/// $5B-$9F read past the 59 glyphs into the code at $16AA, exactly as the original does.
///
/// The record routines return the carry flag they exit with (left by subtracting $20 from the
/// terminator: set for $A0-$FF, clear for $00-$1F), because the failure picker at $EB25 adds it in
/// without clearing the carry first.
extension Machine {
    /// $1634: 59 glyph words, ASCII $20-$5A: 5 rows of 3 bits, top row in bits 0-2; bit 2 of
    /// each group is the leftmost pixel.
    public static let fontGlyphs = 0x1634
    /// $1624: 3-bit font row -> pen-3 pixel pairs.
    public static let fontRowExpand = 0x1624
    /// $162C / $1630: x & 3 -> masks that clear the cell in the first / second byte.
    public static let fontClearMaskLo = 0x162C
    public static let fontClearMaskHi = 0x1630

    // MARK: printSigned5 ($1D54)

    /// $1D54: formats the signed 16-bit value at $B8/$B9 as a sign (' ' or '-') and 5 digits into
    /// bytes 2-7 of the record at `record` (A = low, X = high), then draws the record.
    ///
    /// Digits come from repeated subtraction of 10000/1000/100/10 (the loop stops when the high
    /// byte goes negative); the remainder in $B8 gives the last digit. -32768 cannot be negated
    /// and prints as six dashes. $B8/$B9 are left holding the last remainder; $BA/$BB = record+2,
    /// $C0/$C1 = record. Returns the carry on exit (see the type comment). Clobbers A, X, Y.
    @discardableResult
    public func printSigned5(record: UInt16) -> Bool {
        let (cycles, carry) = printSigned5Body(lo: UInt8(record & 0xFF), hi: UInt8(record >> 8))
        charge(cycles)
        return carry
    }

    @usableFromInline
    func printSigned5Body(lo a: UInt8, hi x: UInt8) -> (cycles: Int, carry: Bool) {
        let m = mem
        m[0xC0] = a
        m[0xC1] = x
        var cycles = 10                   // the record address kept, the field 2 past it
        let (lo, carry) = a.addingReportingOverflow(2)
        var hi = x
        if carry { hi &+= 1; cycles += 4 } else { cycles += 3 }   // the carry into the high byte
        m[0xBA] = lo
        m[0xBB] = hi
        let field = Int(hi) << 8 | Int(lo)
        cycles += 11                      // the field pointer, the sign test
        if m[0xB9] & 0x80 == 0 {
            m[field] = 0x20
            cycles += 13                  // positive: a space
        } else {
            m[field] = 0x2D
            let (vlo, borrow) = UInt8(0).subtractingReportingOverflow(m[0xB8])
            let vhi = 0 &- m[0xB9] &- (borrow ? 1 : 0)
            m[0xB8] = vlo
            m[0xB9] = vhi
            cycles += 29   // negative: a dash, the value negated
            if vhi & 0x80 != 0 {
                // $1DAF: -32768: dashes in all five digit places.
                cycles += 7                  // still negative: the dash fill
                for y in stride(from: 5, through: 1, by: -1) {
                    m[(field + y) & 0xFFFF] = 0x2D
                    cycles += 8 + (y != 1 ? 3 : 2)   // one dash per place
                }
                let record = drawTextRecordAtBody()          // on into $1DE2
                return (cycles + 3 + record.cycles, record.carry)
            }
            cycles += 2                              // the overflow test
        }
        // $1D81: the four leading digits.
        cycles += 12 + printDigit(divisor: 10000, place: 1, field: field)
        cycles += 12 + printDigit(divisor: 1000, place: 2, field: field)
        cycles += 12 + printDigit(divisor: 100, place: 3, field: field)
        cycles += 12 + printDigit(divisor: 10, place: 4, field: field)
        m[(field + 5) & 0xFFFF] = m[0xB8] | 0x30
        cycles += 16                  // the last digit from the remainder
        let record = drawTextRecordAtBody()          // on into $1DE2
        return (cycles + 3 + record.cycles, record.carry)
    }

    /// $1DBB: one digit by repeated subtraction of the divisor ($A5/$A6) from $B8/$B9, stored as
    /// ASCII at field + place ($A7). Returns the cycles including its return.
    @inline(__always)
    func printDigit(divisor: UInt16, place: UInt8, field: Int) -> Int {
        let m = mem
        let dlo = UInt8(divisor & 0xFF), dhi = UInt8(divisor >> 8)
        m[0xA5] = dlo
        m[0xA6] = dhi
        m[0xA7] = place
        var digit: UInt8 = 0x30
        var vlo = m[0xB8], vhi = m[0xB9]
        var cycles = 14               // the divisor and the place kept, the digit from '0'
        while true {
            let (tlo, borrow) = vlo.subtractingReportingOverflow(dlo)
            let thi = vhi &- dhi &- (borrow ? 1 : 0)
            cycles += 13              // one 16-bit trial subtraction
            if thi & 0x80 != 0 { cycles += 3; break } // negative: done
            digit &+= 1
            vlo = tlo
            vhi = thi
            cycles += 15          // the difference kept, the digit counted
        }
        m[0xB8] = vlo
        m[0xB9] = vhi
        m[(field + Int(place)) & 0xFFFF] = digit
        return cycles + 17                // the digit stored, the return
    }

    // MARK: Text records ($1DDE, $1DE2, $1E01)

    /// $1DDE: draws the text record at `record` (A = low, X = high). Leaves $C0/$C1 just past the
    /// terminator. Returns the carry on exit: set when the terminator is $A0-$FF, clear for
    /// $00-$1F ($EB25 adds it). Clobbers A, X, Y.
    @discardableResult
    public func drawTextRecord(_ record: UInt16) -> Bool {
        let m = mem
        m[0xC0] = UInt8(record & 0xFF)
        m[0xC1] = UInt8(record >> 8)
        let r = drawTextRecordAtBody()
        charge(6 + r.cycles)
        return r.carry
    }

    /// $1DE2: draws the text record at $C0/$C1 (the inner entry of $1DDE): $C2 = row, $C3 = x,
    /// then one glyph per character until the terminator. Returns the carry on exit, as
    /// `drawTextRecord`. Clobbers A, X, Y.
    @discardableResult
    public func drawTextRecordAt() -> Bool {
        let r = drawTextRecordAtBody()
        charge(r.cycles)
        return r.carry
    }

    @usableFromInline
    func drawTextRecordAtBody() -> (cycles: Int, carry: Bool) {
        let m = mem
        // $1DEC: the row and x bytes, each through $1DF6.
        var cycles = 33
        let row = nextRecordByte(&cycles)
        let x = nextRecordByte(&cycles)
        m[0xC2] = row
        m[0xC3] = x
        cycles += 9                          // the position, on into the character loop $1E8E
        let rest = drawRecordCharacters()
        return (cycles + rest.cycles, rest.carry)
    }

    /// $1E01: draws glyph A (= character - $20) at ($C3, $C2), then continues with the rest of the
    /// record at $C0/$C1 like `drawTextRecordAt` (and returns its carry). Clobbers A, X, Y.
    @discardableResult
    public func drawGlyph(_ index: UInt8) -> Bool {
        let glyph = drawGlyphBody(index)
        let rest = drawRecordCharacters()
        charge(glyph + rest.cycles)
        return rest.carry
    }

    /// $1E8E: the character loop: fetch, subtract $20, stop when the result is negative. The carry
    /// on exit is the borrow of that final subtraction: set for a terminator $A0-$FF.
    @inline(__always)
    private func drawRecordCharacters() -> (cycles: Int, carry: Bool) {
        var cycles = 0
        while true {
            cycles += 6
            let byte = nextRecordByte(&cycles)
            let index = byte &- 0x20
            cycles += 4                          // subtract $20
            if index & 0x80 != 0 { return (cycles + 9, byte >= 0x20) }   // a terminator
            cycles += 5                          // a glyph: on to $1E01
            cycles += drawGlyphBody(index)
        }
    }

    /// $1DF6: the next record byte through the pointer $C0/$C1, which then advances by one (into
    /// $C1 on a page wrap).
    @inline(__always)
    private func nextRecordByte(_ cycles: inout Int) -> UInt8 {
        let m = mem
        let lo = m[0xC0]
        let value = m[Int(m[0xC1]) << 8 | Int(lo)]
        m[0xC0] = lo &+ 1
        if lo == 0xFF {
            m[0xC1] &+= 1
            cycles += 25          // the page wrap: carry into $C1
        } else {
            cycles += 22              // no wrap: the skip crosses a page to $1E00
        }
        return value
    }

    /// One glyph cell ($1E01 up to the fall-through into $1E8E). Returns its cycles.
    @usableFromInline
    func drawGlyphBody(_ index: UInt8) -> Int {
        let m = mem
        let i = Int(index << 1)                      // the glyph word offset
        var word = UInt16(m[Self.fontGlyphs + i]) | UInt16(m[Self.fontGlyphs + 1 + i]) << 8
        let x = m[0xC3]
        let px = x & 3
        let keepLeft = m[Self.fontClearMaskLo + Int(px)]
        let keepRight = m[Self.fontClearMaskHi + Int(px)]
        m[0xA7] = 5
        m[0xA9] = px
        m[0xAD] = keepRight
        m[0xAE] = keepLeft
        // The setup: the glyph word into $A5/$A6, five rows to go in $A7, the pixel phase x & 3 in
        // $A9 and its two clear masks in $AD/$AE.
        var cycles = 47
        if i >= 0xCC { cycles += 2 }                 // both glyph loads cross a page
        let offsetLo = (x << 1) & 0xF8
        let offsetHi: UInt8 = x >> 7
        var row = m[0xC2]
        var ptrLo: UInt8 = 0, ptrHi: UInt8 = 0
        var left: UInt8 = 0, right: UInt8 = 0
        for _ in 0..<5 {
            // The row pointer: row base + ((x << 1) & $1F8).
            let (sum, carry) = offsetLo.addingReportingOverflow(m[Self.rowAddressLo + Int(row)])
            ptrLo = sum
            ptrHi = offsetHi &+ m[Self.rowAddressHi + Int(row)] &+ (carry ? 1 : 0)
            // The row pointer into $8E/$8F (the low row table read crosses a page from row $38 on).
            cycles += 27 + (row >= 0x38 ? 1 : 0) + 15
            // Three bits shifted out of the bottom of the glyph word one at a time, in reverse: the
            // first one taken becomes bit 2 of the $1624 index, the rightmost pixel, so bit 2 of
            // each 3-bit group is the leftmost pixel.
            let bits = (word & 1) << 2 | (word >> 1 & 1) << 1 | (word >> 2 & 1)
            word >>= 3
            let pixels = m[Self.fontRowExpand + Int(bits)]
            cycles += 3 * 12 + 17   // the three bits, the expansion, the shift setup
            // Shift the pixel pairs right by x & 3 pixels across two bytes.
            let shift = (UInt16(pixels) << 8) >> (UInt16(px) << 1)
            left = UInt8(shift >> 8)
            right = UInt8(shift & 0xFF)
            cycles += Int(px) * 19 + 4   // one 19-cycle pass per pixel of shift
            let a0 = Self.indirectY(ptrLo, ptrHi, 0), a8 = Self.indirectY(ptrLo, ptrHi, 8)
            m[a0] = (keepLeft & m[a0]) | left
            m[a8] = (keepRight & m[a8]) | right
            // Both bytes merged under their masks (a row pointer at $F8 or above crosses a page for
            // the second byte), the next row, the row count down.
            cycles += 32 + (ptrLo >= 0xF8 ? 1 : 0) + 22
            row &+= 1
        }
        cycles -= 1                                  // the last loop branch is not taken
        m[0x38] = offsetHi
        m[0x8E] = ptrLo
        m[0x8F] = ptrHi
        m[0xA5] = UInt8(word & 0xFF)
        m[0xA6] = UInt8(word >> 8)
        m[0xA7] = 0
        m[0xAB] = right
        m[0xAC] = left
        m[0xC3] = x &+ 4
        m[0xC2] = row &- 5
        // x one cell (4) on, the row back by 5.
        return cycles + 20
    }

    // MARK: drawTextList ($1E99)

    /// $1E99: draws the records of the list at `list` (A = low, X = high) until a record starting
    /// with `00 00`. Clobbers A, X, Y.
    public func drawTextList(_ list: UInt16) {
        let m = mem
        m[0xC0] = UInt8(list & 0xFF)
        m[0xC1] = UInt8(list >> 8)
        var cycles = 6
        while true {
            let ptr = Int(m[0xC1]) << 8 | Int(m[0xC0])
            cycles += 7                          // the record's first byte
            if m[ptr] != 0 {
                cycles += 3                          // nonzero: a record
            } else {
                cycles += 9 + (ptr & 0xFF == 0xFF ? 1 : 0)   // zero: test the second byte
                if m[(ptr + 1) & 0xFFFF] == 0 { cycles += 9; break }   // both zero: the end
                cycles += 2
            }
            cycles += 6 + drawTextRecordAtBody().cycles + 3   // the record drawn, the loop
        }
        charge(cycles)
    }

    // MARK: clearWindow ($1EAF)

    /// $1EAF: clears $4000-$517F (bitmap A window rows 0-111, regardless of the row tables) for
    /// the text menus and messages. Leaves $8E/$8F = $5100.
    public func clearWindow() {
        let m = mem
        (m + 0x4000).update(repeating: 0, count: 0x1180)
        m[0x8E] = 0
        m[0x8F] = 0x51
        // The setup, then 10 cycles per byte and two loop tests: 4480 bytes, 17 page wraps (each
        // also steps the pointer's high byte), 18 stops at Y = $80 (an end test whose branch is
        // taken 17 times), then the return.
        let bytes = 0x1180, wraps = 17, halves = 18
        let cycles = 12 + bytes * 10
            + (bytes - wraps) * 3 + wraps * 7
            + (bytes - halves) * 3 + halves * 7 + (halves - 1) * 3 + 2
            + 6
        charge(cycles)
    }
}
