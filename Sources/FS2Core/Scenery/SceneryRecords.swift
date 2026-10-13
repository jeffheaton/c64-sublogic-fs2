/// Display-list data ops: word copies and stores (1A, 25), the radio station records found while
/// drawing (1D NAV/LOC, 1E ATIS, 05 NDB) and the block load (0D).
extension Machine {
    // MARK: Ops 1A, 25

    /// $8DC3 (op 1A dst16 src16): [dst] = [src] (two bytes, indexed through the pointers `$A5/$A6`
    /// and `$A7/$A8`; `$B5` keeps Y = 4).
    func opCopyWord() -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        for k in 0..<4 { m[0xA5 + k] = dlByte(pc, 1 + k) }
        m[0xB5] = 4
        // The pointers are read again for the second byte (a store into $A5-$A8 changes them).
        m[zpPointer(0xA5)] = m[zpPointer(0xA7)]
        let crossed = m[0xA7] == 0xFF ? 1 : 0               // the second source read crosses a page
        m[(zpPointer(0xA5) + 1) & 0xFFFF] = m[(zpPointer(0xA7) + 1) & 0xFFFF]
        // The operands into $A5-$A8, Y kept in $B5, the two byte copies and the advance.
        var c = 3 * 10 + 47 + crossed
        for k in 1...4 { c += Self.dlCross(pc, k) }
        charge(c)
        return .advance(5)
    }

    /// $8DEB (op 25 dst16 v16): stores the word v at dst (the low byte through the pointer
    /// `$A7/$A8` itself, the high byte one past it; `$B5` keeps Y = 4).
    func opStoreWord() -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        m[0xA7] = dlByte(pc, 1)
        m[0xA8] = dlByte(pc, 2)
        m[zpPointer(0xA7)] = dlByte(pc, 3)
        // The high byte is read after the low one is stored (a store into `$8B/$8C` moves the PC).
        let pcAfter = zpPointer(0x8B)
        let high = dlByte(pcAfter, 4)
        m[0xB5] = 4
        m[(zpPointer(0xA7) + 1) & 0xFFFF] = high
        // The destination into $A7/$A8, the two stores, Y kept in $B5 and the advance.
        var c = 2 * 10 + 41
        for k in 1...3 { c += Self.dlCross(pc, k) }
        c += Self.dlCross(pcAfter, 4)
        charge(c)
        return .advance(5)
    }

    // MARK: Op 1D: NAV/VOR/LOC record

    /// $8030 (op 1D freq16 X32 Z32): while the NAV search is active (`$0921`), clears the
    /// request `$0920` and compares the record's frequency with `$0925` (match: the 8 coordinate
    /// bytes to `$092F`, `$0922` |= 1) and `$0923` (match: to `$0927`, `$0922` |= 2). `$B8`
    /// takes the slot offset and then counts the copy. 11 bytes.
    func opNavRecord() -> Scenery.Flow {
        let m = mem
        var c = 4                                           // the search-active test
        if m[Scenery.navSearchActive] == 0 {
            charge(c + 8)                           // inactive: past the 11-byte op
            return .advance(11)
        }
        m[Scenery.navSearchRequest] = 0
        c += 24                      // the request cleared; slot 8 against frequency B
        c += navRecordMatch(slot: 8, frequency: Radio.navFrequencyB)
        c += 16                                  // slot 0 against frequency A
        c += navRecordMatch(slot: 0, frequency: Radio.navFrequencyA)
        charge(c + 5)                                   // past the 11-byte op
        return .advance(11)
    }

    /// $8055: on a match of the record's frequency with the word at `frequency`, copies the 8
    /// bytes after it to `$0927 + slot` and ORs `$0922` with 1 (slot 8) or 2 (slot 0). Returns its
    /// cycles, return included.
    private func navRecordMatch(slot: UInt8, frequency: Int) -> Int {
        let m = mem
        let pc = zpPointer(0x8B)
        m[0xB8] = slot
        var c = 10 + Self.dlCross(pc, 1)             // the slot kept, the low bytes compared
        guard m[frequency] == dlByte(pc, 1) else { return c + 9 }
        c += 11 + Self.dlCross(pc, 2)            // then the high bytes
        guard m[frequency + 1] == dlByte(pc, 2) else { return c + 9 }
        c += 12                              // a match: `$B8` becomes the copy count
        for k in 0..<8 {
            m[Radio.navStationA + Int(slot) + k] = dlByte(pc, 3 + k)
            c += 5 + Self.dlCross(pc, 3 + k) + 14 + (k == 7 ? 2 : 3)
        }
        m[0xB8] = 0
        let bit: UInt8 = slot == 8 ? 1 : 2
        m[Radio.navFoundBits] |= bit
        c += 4 + (bit == 1 ? 3 : 4) + 14     // the slot's found bit merged into $0922
        return c
    }

    // MARK: Op 1E: ATIS record

    /// $8084 (op 1E len ? com16 params8 text...): while the COM search is active (`$0938`),
    /// clears the request `$0937`; when the record's frequency (bytes 3-4) equals the COM
    /// frequency `$08B3/$08B4`, the 8 parameter bytes go to `$0939-$0940`, `$0958/$0959` = the
    /// record + 13 (its text), `$0941` = 0, and the ATIS hook `$802D` runs (patched at init to
    /// jump to $F16A, the ATIS composer). Then PC += len and the interpreter restarts at $8742
    /// (which clears `$0916` and `$8A`).
    func opAtisRecord() -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        let length = dlByte(pc, 1)
        var c = 7 + Self.dlCross(pc, 1) + 9     // the length saved, the search-active test
        record: if m[Scenery.comSearchActive] == 0 {
            c += 3
        } else {
            m[Scenery.comSearchRequest] = 0
            c += 19 + Self.dlCross(pc, 3)   // the request cleared, the low bytes compared
            guard m[Radio.comFrequency] == dlByte(pc, 3) else { c += 3; break record }
            c += 13 + Self.dlCross(pc, 4)        // then the high bytes
            guard m[Radio.comFrequency + 1] == dlByte(pc, 4) else { c += 3; break record }
            c += 6                                  // a match: the parameter copy
            for k in 0..<8 {
                m[0x0939 + k] = dlByte(pc, 5 + k)
                c += 5 + Self.dlCross(pc, 5 + k) + 9 + (k == 7 ? 2 : 3)
            }
            let text = pc + 13
            m[0x0958] = UInt8(text & 0xFF)
            m[Radio.atisOneShot] = 0
            m[0x0959] = UInt8((text >> 8) & 0xFF)
            charge(c + 30)  // the text pointer, the one-shot flag, the hook call
            c = 0
            atisHook(a: m[0x0959], y: 13)
        }
        // $80C4: PC += the saved length, then the interpreter restarts at $8742.
        let sum = Int(m[0x8B]) + Int(length)
        m[0x8B] = UInt8(truncatingIfNeeded: sum)
        c += 12
        if sum > 0xFF { m[0x8C] &+= 1; c += 7 } else { c += 3 }
        charge(c + 3)
        dlResetClipFlags()
        return .advance(0)
    }

    /// $802D: the ATIS hook, a jump to $F16A after init (`patchRadioHooks`): the ATIS composer
    /// (`composeAtis`; op 1E enters it with A = the text pointer's high byte, X = 0, Y = 13, which
    /// it does not use). Nothing on the disk patches another target there, so any other one stops
    /// the program with its address (`fatalError`, whose message every build keeps). Charges the
    /// hook's jump.
    func atisHook(a: UInt8, y: UInt8) {
        let target = u16(0x802E)
        precondition(mem[0x802D] == 0x4C && target != 0x802D, "the ATIS hook $802D is not patched")
        guard target == 0xF16A else {
            fatalError(String(format: "the ATIS hook $802D jumps to $%04X, which has no port "
                                  + "(only the composer $F16A has one)", target))
        }
        charge(3)
        composeAtis()
    }

    // MARK: Op 05: NDB record

    /// Op 05 freq16 X24 Z24: the handler is the hook $802A, patched at init to jump to $E956
    /// (`ndbHook`, the ADF unit's), which ends by advancing the PC through the vector $8018
    /// (to $8749).
    func opNdbRecord() -> Scenery.Flow {
        precondition(mem[0x802A] == 0x4C && u16(0x802B) == 0xE956, "the NDB hook $802A is not patched to $E956")
        charge(3)                                           // the hook's jump
        let length = ndbHook()
        charge(3)                                           // the vector $8018 on to $8749
        return .advance(length)
    }

    // MARK: Op 0D: block load

    /// $80E2 (op 0D blk cnt rel16 slot): copies the five operand bytes to `$08FB-$08FF`; unless
    /// `$08D9` bit 7 is set the destination becomes PC + rel16 (otherwise it is absolute, once:
    /// `$08D9` &= 3 afterwards). Then `loadBlockCached` through $2036 (nothing happens when the
    /// slot already holds the block).
    func opLoadBlocks() -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        var c = 2                                           // copied from the last byte down
        for y in stride(from: 5, through: 1, by: -1) {
            m[0x08FA + y] = dlByte(pc, y)
            c += 5 + Self.dlCross(pc, y) + 7 + (y == 1 ? 2 : 3)
        }
        let flags = m[0x08D9]
        c += 4                                              // the flag test
        if flags & 0x80 != 0 {
            c += 4                                          // absolute: the branch crosses a page
        } else {
            let dst = (Int(m[0x08FE]) << 8 | Int(m[0x08FD])) + pc
            m[0x08FD] = UInt8(dst & 0xFF)
            m[0x08FE] = UInt8((dst >> 8) & 0xFF)
            c += 33
        }
        m[0x08D9] = flags & 0x03
        charge(c + 15)                           // the flags masked, the call via $2036 to $E58F
        loadBlockCached()
        charge(5)                                       // past the 6-byte op
        return .advance(6)
    }
}
