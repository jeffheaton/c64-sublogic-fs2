/// The radio stack readouts ($3896-$3922, $3A5C): COM, NAV1, NAV2 and transponder. The tuning
/// keys ($286D/$298E) edit the ASCII digits in the records and then call these routines, which
/// redraw the record and turn the digits into the BCD frequency the scenery interpreter's
/// station records (op 1D NAV/LOC, op 1E ATIS) are matched against, raising the search request.
///
/// Literal translation with exact cycles (see `Panel/Readouts.swift`).
public enum Radio {
    /// $08B3/$08B4: the COM frequency (BCD, low byte first: $3515 = 135.15) matched by op 1E.
    public static let comFrequency = 0x08B3
    /// $0923/$0924 and $0925/$0926: the NAV2 and NAV1 frequencies (BCD) matched by op 1D.
    public static let navFrequencyA = 0x0923
    public static let navFrequencyB = 0x0925
    /// $0920: NAV search request (the interpreter copies it to `$0921` each pass).
    public static let navSearchRequest = 0x0920
    /// $0922: stations found: bit 0 NAV1 (station B), bit 1 NAV2 or ADF-shared (station A).
    public static let navFoundBits = 0x0922
    /// $0927 / $092F: station records A (NAV2, or the NDB of op 05) and B (NAV1): X32 (east) at
    /// +0..+3 and Z32 (north) at +4..+7, little-endian, in the position units (1/256 m). A
    /// nonzero fraction byte +4 of station B marks a localizer.
    public static let navStationA = 0x0927
    public static let navStationB = 0x092F
    /// $0937: COM search request; $0941: the ATIS one-shot (1 = typed for this tune).
    public static let comSearchRequest = 0x0937
    public static let atisOneShot = 0x0941
}

extension Machine {
    /// $3896: four ASCII digits at `field` (A = low, X = high) as a BCD word: X = d0·16 + (d1 &
    /// 15), A = d2·16 + (d3 & 15). `$C0/$C1` = field, `$B9`/`$B8` = d0·16 / d2·16.
    public func parseFrequencyDigits(_ field: UInt16) -> (lo: UInt8, hi: UInt8) {
        let m = mem
        m[0xC0] = UInt8(field & 0xFF)
        m[0xC1] = UInt8(field >> 8)
        let base = Int(field)
        func digit(_ i: UInt8) -> UInt8 { m[(base + Int(i)) & 0xFFFF] }
        m[0xB9] = digit(0) << 4
        let hi = (digit(1) & 0x0F) | m[0xB9]
        m[0xB8] = digit(2) << 4
        let lo = (digit(3) & 0x0F) | m[0xB8]
        // 74 cycles for the pointer setup and the four digits, plus the page crossings of the
        // indexed digit reads.
        var crossings = 0
        for i: UInt8 in 0...3 { crossings += Machine.pageCrossing(base, i) }
        charge(74 + crossings)
        return (lo, hi)
    }

    /// $38BD: redraws NAV1 (record $21B5) and sets the NAV1 frequency `$0925/$0926` from its
    /// digits, then falls into `renewNav1Search`. Gated by $3A53. Clobbers A, X, Y.
    public func drawNav1Frequency() {
        let gate = radioGate()
        guard gate.open else { charge(6 + gate.cycles); return }
        charge(6 + gate.cycles + 10)
        drawTextRecord(Readouts.nav1Record)
        charge(10)
        let f = parseFrequencyDigits(Readouts.nav1Record + 2)
        mem[Radio.navFrequencyB] = f.lo
        mem[Radio.navFrequencyB + 1] = f.hi
        charge(8)
        renewNav1Search()
    }

    /// $38D4 (once per 8 passes; also the tail of $38BD): clears the NAV1 found bit (`$0922` &=
    /// $FE) and raises the NAV search request `$0920`, so the station is looked up again (and
    /// lost when out of range). Clobbers A.
    public func renewNav1Search() {
        charge(5)                                       // mask $FE, tail jump to $38F7
        renewNavSearch(0xFE)
    }

    /// $38D9: NAV2 (record $21BC) into `$0923/$0924` unless the ADF is enabled, then
    /// `renewNav2Search`. Gated by $3A53. Clobbers A, X, Y.
    public func drawNav2Frequency() {
        let gate = radioGate()
        guard gate.open else { charge(6 + gate.cycles); return }
        // The ADF owns NAV2's slot while enabled (the skip branch to $3902 crosses a page).
        guard mem[Readouts.adfEnable] == 0 else { charge(6 + gate.cycles + 14); return }
        charge(6 + gate.cycles + 16)
        drawTextRecord(Readouts.nav2Record)
        charge(10)
        let f = parseFrequencyDigits(Readouts.nav2Record + 2)
        mem[Radio.navFrequencyA] = f.lo
        mem[Radio.navFrequencyA + 1] = f.hi
        charge(8)
        renewNav2Search()
    }

    /// $38F5 (once per 8 passes; also the tail of $38D9): `$0922` &= $FD and the NAV search
    /// request. Clobbers A.
    public func renewNav2Search() {
        charge(2)                                           // mask $FD, falls into $38F7
        renewNavSearch(0xFD)
    }

    /// $38F7: `$0922` &= A and `$0920` = 1.
    private func renewNavSearch(_ mask: UInt8) {
        mem[Radio.navFoundBits] &= mask
        mem[Radio.navSearchRequest] = 1
        charge(20)
    }

    /// $3903: redraws COM (record $21AE), sets the COM frequency `$08B3/$08B4` from its digits,
    /// and sets `$0941` = 1 and the COM search request `$0937` = 1. Gated by $3A53. Clobbers
    /// A, X, Y.
    public func drawComFrequency() {
        let gate = radioGate()
        guard gate.open else { charge(6 + gate.cycles); return }
        charge(6 + gate.cycles + 10)
        drawTextRecord(Readouts.comRecord)
        charge(10)
        let f = parseFrequencyDigits(Readouts.comRecord + 2)
        let m = mem
        m[Radio.comFrequency] = f.lo
        m[Radio.comFrequency + 1] = f.hi
        m[Radio.atisOneShot] = 1
        m[Radio.comSearchRequest] = 1
        charge(24)
    }

    /// $3A5C: redraws the transponder record $21DB (the keys edit its octal digits). Gated by
    /// $3A53. Clobbers A, X, Y.
    public func drawTransponder() {
        let gate = radioGate()
        guard gate.open else { charge(6 + gate.cycles); return }
        charge(6 + gate.cycles + 10)
        drawTextRecord(Readouts.transponderRecord)
        charge(6)
    }
}
