/// The instrument enable masks and the failure graphics ($F2E6-$F521).
///
/// `$FD/$FE/$FF` gate the gauge and readout drivers. Each is the bitwise product of three
/// factors: the instrument settings `$09A6+`, the failure masks `$0942+` (reality-mode failures
/// clear bits) and the lighting masks `$0945+`. When a bit goes from 1 to 0, the instrument's
/// rectangle of the panel bitmap is moved bit by bit into a save buffer and cleared, so the
/// instrument goes blank and frozen; when it comes back, the saved bits are XORed back in. The
/// rectangles and buffers come from three tables of 6-byte entries (one per bit) read from memory
/// at run time.
///
/// Literal translation, exact cycles (see `GaugesNeedles.swift`).
public enum Instruments {
    /// $FD / $FE / $FF: the enable masks (`instrumentMask0` + k).
    public static let instrumentMask0 = 0xFD
    /// $09A6 / $0942 / $0945: the three factors of each mask (3 bytes each).
    public static let instrumentSettings = 0x09A6
    public static let failureMasks = 0x0942
    public static let lightingMasks = 0x0945
    /// $F2E6 / $F316 / $F346: the area tables of `$FD` / `$FE` / `$FF`, 8 entries of 6 bytes:
    /// [x low][rows << 1 | x bit 8][first row][width][buffer low][buffer high]. Only 4 entries
    /// of the `$FF` table exist: entries 4-7 read the code that follows at $F35E.
    public static let areaTables: [UInt16] = [0xF2E6, 0xF316, 0xF346]

    /// The variables of the module at $F3E6-$F3EF.
    public enum Scratch {
        /// $F3E6: the new state of the bit being drawn (1 = restore, 0 = save and clear).
        public static let areaNewBit = 0xF3E6
        /// $F3E7 / $F3E8: the area's x (low byte, bit 8).
        public static let areaX = 0xF3E7
        public static let areaXHigh = 0xF3E8
        /// $F3E9: the current row.
        public static let areaRow = 0xF3E9
        /// $F3EA: rows left.
        public static let areaRowsLeft = 0xF3EA
        /// $F3EB: the width in pixels.
        public static let areaWidth = 0xF3EB
        /// $F3EC / $F3ED: the current x (16-bit).
        public static let areaColumn = 0xF3EC
        public static let areaColumnHigh = 0xF3ED
        /// $F3EE: pixels left in the row.
        public static let areaPixelsLeft = 0xF3EE
        /// $F3EF: bits used of the current save-buffer byte (1-8; 0 at the start of an area).
        public static let savedBitCounter = 0xF3EF
    }

    /// $F4BD: MSB-first bit masks for `bitmapBitAddress`.
    public static let bitMasksF4BD = 0xF4BD
    /// $BC/$BD: the save-buffer pointer.
    public static let bufferPointer = 0xBC
}

extension Machine {
    // MARK: updateInstrumentMasks ($F35E)

    /// $F35E (every pass, after the gauge drivers): recomputes `$FD/$FE/$FF`.
    ///
    /// For each mask k: new = `$09A6[k] & $0942[k] & $0945[k]`; when it differs from the stored
    /// mask: `$9E` = new, `$A0` = old, the mask is stored, and `applyMaskChanges` runs over the
    /// k-th area table. Clobbers A, X, Y.
    public func updateInstrumentMasks() {
        let m = mem
        var cycles = 0
        for k in 0..<3 {
            // Combine the three factors; nothing to do while the mask is unchanged.
            let value = m[Instruments.instrumentSettings + k] & m[Instruments.failureMasks + k]
                & m[Instruments.lightingMasks + k]
            cycles += 15
            if value == m[Instruments.instrumentMask0 + k] { cycles += 3; continue }
            // Store the new mask, and hand the new and old ones to $F3B3 with this mask's table.
            m[0x9E] = value
            m[0xA0] = m[Instruments.instrumentMask0 + k]
            m[Instruments.instrumentMask0 + k] = value
            cycles += 24
            cycles += applyMaskChangesBody(Instruments.areaTables[k])
        }
        charge(cycles + 6)                                  // the return
    }

    /// $F3B3: runs `toggleInstrumentArea` for the 8 bits of a mask change, entries of 6 bytes
    /// from the table at A (low) / X (high). Inputs: `$9E` = new mask, `$A0` = old mask (both
    /// shifted right once per bit). Per bit: `$B8` = old bit, `$B9` = new bit, `$BA/$BB` = entry.
    /// `$BE/$BF` = table pointer (advanced by 6), `$A2` = bits left. Clobbers A, X, Y.
    public func applyMaskChanges(table: UInt16) {
        charge(applyMaskChangesBody(table))
    }

    @usableFromInline
    func applyMaskChangesBody(_ table: UInt16) -> Int {
        let m = mem
        m[0xBE] = UInt8(table & 0xFF)
        m[0xBF] = UInt8(table >> 8)
        m[0xA2] = 8
        var cycles = 11                          // the table pointer, and 8 bits to go
        while true {
            // The low bits of the old and new masks, and the current entry, for $F3F0.
            m[0xB8] = m[0xA0] & 1
            m[0xB9] = m[0x9E] & 1
            m[0xBA] = m[0xBE]
            m[0xBB] = m[0xBF]
            cycles += 34 + toggleInstrumentAreaBody()
            // Shift both masks on to the next bit and step to the next 6-byte entry.
            m[0x9E] >>= 1
            m[0xA0] >>= 1
            let (lo, carry) = m[0xBE].addingReportingOverflow(6)
            m[0xBE] = lo
            cycles += 20
            if carry { m[0xBF] &+= 1; cycles += 7 } else { cycles += 3 }
            // Count the bit off.
            m[0xA2] &-= 1
            cycles += 5
            if m[0xA2] == 0 { return cycles + 8 }      // with the return
            cycles += 3
        }
    }

    // MARK: toggleInstrumentArea ($F3F0)

    /// $F3F0: one bit of a mask change. Inputs: `$B8` = old bit, `$B9` = new bit, `$BA/$BB` =
    /// the area entry. Nothing happens when the bits are equal.
    ///
    /// The entry gives x (9 bits), the row count, the first row, the width and the save buffer
    /// (`$BC/$BD`); `$F3EF` = 0. The area is walked row by row, left to right, through the row
    /// tables (`bitmapBitAddress`):
    /// - new bit 0 (failure): each pixel's bit is read and cleared ($F493) and pushed into the
    ///   buffer (`pushSavedBit`); afterwards the last buffer byte is shifted left so its first
    ///   bit is bit 7.
    /// - new bit 1 (repair): each pixel takes the next buffer bit (`popSavedBit`, which rotates
    ///   the buffer byte) and XORs it in ($F4A9; a 0 bit stores the byte back unchanged).
    ///
    /// Memory: $F3E6-$F3EF, `$BA/$BB` = the last pixel's byte address, `$BC/$BD`, `$A5`, `$A7`.
    /// Clobbers A, X, Y.
    public func toggleInstrumentArea() {
        charge(toggleInstrumentAreaBody())
    }

    @usableFromInline
    func toggleInstrumentAreaBody() -> Int {
        let m = mem
        typealias S = Instruments.Scratch
        // Nothing to do when the bit did not change.
        let newBit = m[0xB9]
        if newBit == m[0xB8] { return 14 }
        var cycles = 9
        // Unpack the 6-byte entry into the scratch bytes (the second byte holds the row count
        // above x bit 8) and the buffer pointer, and start with an empty buffer byte.
        m[S.areaNewBit] = newBit
        func entry(_ y: UInt8) -> (value: UInt8, cycles: Int) {
            let p = zpPointer(0xBA)
            return (m[(p + Int(y)) & 0xFFFF], 5 + Machine.pageCrossing(p, y))
        }
        let e0 = entry(0), e1 = entry(1)
        m[S.areaX] = e0.value
        m[S.areaRowsLeft] = e1.value >> 1
        m[S.areaXHigh] = e1.value & 1
        cycles += 6 + e0.cycles + 6 + e1.cycles + 16
        let e2 = entry(2)
        m[S.areaRow] = e2.value
        let e3 = entry(3)
        m[S.areaWidth] = e3.value
        let e4 = entry(4)
        m[Instruments.bufferPointer] = e4.value
        let e5 = entry(5)
        m[Instruments.bufferPointer + 1] = e5.value
        m[S.savedBitCounter] = 0
        cycles += 2 + e2.cycles + 6 + e3.cycles + 6 + e4.cycles + 5 + e5.cycles + 9
        while true {
            // $F42A: each row starts at the area's left edge with the full width to go.
            m[S.areaPixelsLeft] = m[S.areaWidth]
            let x = m[S.areaX], xHigh = m[S.areaXHigh]
            m[S.areaColumn] = x
            m[S.areaColumnHigh] = xHigh
            cycles += 24
            while true {
                // $F43C: restore or save, by the new bit.
                cycles += 4
                if m[S.areaNewBit] != 0 {
                    // Repair: take the next saved bit and XOR it into the pixel ($F4A9).
                    cycles += 8
                    let bit = popSavedBitBody()
                    cycles += bit.cycles
                    m[0xA5] = m[S.areaColumnHigh]
                    cycles += 21
                    cycles += restoreAreaBit(bit.a, x: m[S.areaColumn], row: m[S.areaRow]) + 3
                } else {
                    // Failure: read and clear the pixel ($F493), then save its bit ($F4E0).
                    m[0xA5] = m[S.areaColumnHigh]
                    cycles += 24
                    let saved = clearAreaBit(x: m[S.areaColumn], row: m[S.areaRow])
                    cycles += saved.cycles + 6 + pushSavedBitBody(saved.a)
                }
                // $F466: the next pixel, carrying into x bit 8; the row ends with its width.
                m[S.areaColumn] &+= 1
                cycles += 6
                if m[S.areaColumn] == 0 { m[S.areaColumnHigh] &+= 1; cycles += 8 } else { cycles += 3 }
                m[S.areaPixelsLeft] &-= 1
                cycles += 6
                if m[S.areaPixelsLeft] == 0 { cycles += 2; break }
                cycles += 3
            }
            // The next row, until the row count runs out.
            m[S.areaRow] &+= 1
            m[S.areaRowsLeft] &-= 1
            cycles += 12
            if m[S.areaRowsLeft] == 0 { cycles += 2; break }
            cycles += 3
        }
        // A restore is done here.
        cycles += 4
        if m[S.areaNewBit] != 0 { return cycles + 9 }
        // A save left-aligns the last, partly filled buffer byte: it is shifted until its first
        // bit sits at bit 7, the bit counter running on up to 9.
        var x = m[S.savedBitCounter]
        let pointer = zpPointer(Instruments.bufferPointer)
        var a = m[pointer]
        cycles += 13
        while true {
            x &+= 1
            cycles += 4
            if x == 9 { cycles += 3; break }
            let carry: UInt8 = x >= 9 ? 1 : 0               // the carry of the compare with 9
            a = a << 1 | carry
            cycles += 7
        }
        m[zpPointer(Instruments.bufferPointer)] = a
        return cycles + 12
    }

    /// $F493: reads and clears the bit of pixel (x, row) (`$A5` = x bit 8). Returns A = the bit
    /// (0/1, also in `$A7`) and the cycles (the return included, the call excluded).
    private func clearAreaBit(x: UInt8, row: UInt8) -> (a: UInt8, cycles: Int) {
        let m = mem
        // Locate the pixel, note its bit in $A7, then clear it with the inverted mask.
        let address = bitmapBitAddressBody(x: x, row: row)
        var cycles = 6 + address.cycles + 5
        let pointer = zpPointer(0xBA)
        let bit: UInt8 = address.mask & m[pointer] == 0 ? 0 : 1
        cycles += bit == 0 ? 3 : 4
        m[0xA7] = bit
        m[pointer] = ~address.mask & m[pointer]
        return (m[0xA7], cycles + 29)
    }

    /// $F4A9: XORs `bit` into pixel (x, row) (`$A5` = x bit 8); a 0 bit stores the byte back.
    /// Returns the cycles (the return included, the call excluded).
    private func restoreAreaBit(_ bit: UInt8, x: UInt8, row: UInt8) -> Int {
        let m = mem
        // Locate the pixel; a 1 bit flips it, a 0 bit writes the byte back as it was.
        let address = bitmapBitAddressBody(x: x, row: row)
        var cycles = 9 + address.cycles + 6
        let pointer = zpPointer(0xBA)
        if bit != 0 {
            m[pointer] = address.mask ^ m[pointer]
            cycles += 12
        } else {
            m[pointer] = m[pointer]
            cycles += 8
        }
        return cycles + 12
    }

    // MARK: Bit helpers ($F4C5, $F4E0, $F502)

    /// $F4C5: `$BA/$BB` = row base (`$02C8/$0200[row]`) + (x & $F8) + `$A5` pages (x bit 8);
    /// returns the bit mask `$F4BD[x & 7]` (left in A and X; Y = 0). Clobbers A, X, Y.
    @discardableResult
    public func bitmapBitAddress(x: UInt8, row: UInt8) -> UInt8 {
        let r = bitmapBitAddressBody(x: x, row: row)
        charge(r.cycles)
        return r.mask
    }

    @usableFromInline
    func bitmapBitAddressBody(x: UInt8, row: UInt8) -> (mask: UInt8, cycles: Int) {
        let m = mem
        // The row base plus x's 8-pixel cell, a page further per unit of x bit 8; then the mask
        // for x within the cell.
        let (lo, carry) = (x & 0xF8).addingReportingOverflow(m[Machine.rowAddressLo + Int(row)])
        m[0xBA] = lo
        m[0xBB] = m[Machine.rowAddressHi + Int(row)] &+ m[0xA5] &+ (carry ? 1 : 0)
        let mask = m[Instruments.bitMasksF4BD + Int(x & 7)]
        let cycles = 10 + Machine.pageCrossing(Machine.rowAddressLo, row) + 13
            + 20
        return (mask, cycles)
    }

    /// $F4E0: pushes bit 0 of A into the save buffer: `$A5` = A; `$F3EF` += 1, and at 9 it
    /// becomes 1 and `$BC/$BD` moves to the next byte; then the buffer byte is rotated left
    /// with the bit coming in at bit 0. Clobbers A, Y.
    public func pushSavedBit(_ a: UInt8) {
        charge(pushSavedBitBody(a))
    }

    @usableFromInline
    func pushSavedBitBody(_ a: UInt8) -> Int {
        let m = mem
        m[0xA5] = a
        var cycles = 3 + advanceSavedBitCounter().cycles
        // Rotate the bit into the bottom of the buffer byte, passing it through the carry.
        let pointer = zpPointer(Instruments.bufferPointer)
        m[pointer] = m[pointer] << 1 | (m[0xA5] & 1)
        cycles += 26
        return cycles
    }

    /// $F502: pops the next bit from the save buffer: `$F3EF` += 1 (at 9: 1 and the next byte);
    /// the buffer byte is rotated left, taking in the carry of the count's compare with 9 (1 when
    /// a new byte was started, else 0); returns its old bit 7 in A. Clobbers Y.
    @discardableResult
    public func popSavedBit() -> UInt8 {
        let r = popSavedBitBody()
        charge(r.cycles)
        return r.a
    }

    @usableFromInline
    func popSavedBitBody() -> (a: UInt8, cycles: Int) {
        let m = mem
        let counter = advanceSavedBitCounter()
        // Rotate the buffer byte left; the bit that drops out of the top is the result.
        let pointer = zpPointer(Instruments.bufferPointer)
        let byte = m[pointer]
        m[pointer] = byte << 1 | (counter.carry ? 1 : 0)
        return (byte >> 7, counter.cycles + 25)
    }

    /// The counter step shared by $F4E0 and $F502: `$F3EF` += 1 and is compared with 9; at 9 it
    /// restarts at 1 and the buffer pointer `$BC/$BD` moves on a byte. Returns the carry left by
    /// the compare and the cycles.
    private func advanceSavedBitCounter() -> (carry: Bool, cycles: Int) {
        let m = mem
        m[Instruments.Scratch.savedBitCounter] &+= 1
        let count = m[Instruments.Scratch.savedBitCounter]
        if count != 9 { return (count >= 9, 15) }
        m[Instruments.Scratch.savedBitCounter] = 1
        m[Instruments.bufferPointer] &+= 1
        if m[Instruments.bufferPointer] != 0 { return (true, 28) }
        m[Instruments.bufferPointer + 1] &+= 1
        return (true, 32)
    }
}
