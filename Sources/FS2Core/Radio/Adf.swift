/// The ADF ($E7F2-$EA5B): the NDB lookup hook of display-list op 05, the bearing needle and
/// readout that replace the NAV2 OBI when the editor's ADF enable (`$09AA`) is set, and the
/// tuning helpers of the ',' '.' keys (ADF digits and the mixture).
///
/// Literal translation with exact cycles (see `Panel/Readouts.swift`).
public enum Adf {
    /// $E7F2: 1 until the ADF face has been drawn once ($E7FE shifts it out).
    public static let panelPending = 0xE7F2
    /// $E7F3: 1 when op 05 found the NDB tuned in `$E7F4/$E7F5`.
    public static let found = 0xE7F3
    /// $E7F4/$E7F5: the ADF frequency as op 05 compares it: d1·16 + d2, then d0 (BCD-like).
    public static let frequency = 0xE7F4
    /// $E7F6: the ADF needle angle as drawn (gauge 4 of `drawNeedle`; negative: none).
    public static let needle = 0xE7F6
    /// $E7F7: the ' ddd' record of the ADF frequency (154, 115); digits at $E7FA-$E7FC.
    public static let frequencyRecord: UInt16 = 0xE7F7
    public static let digits = 0xE7FA
    /// $E886: the record list of the ADF face; $E930: the bearing readout record (165, 95).
    public static let panelRecords: UInt16 = 0xE886
    public static let bearingRecord: UInt16 = 0xE930
    /// $08BD / $08BE: ADF search request / per-pass flag (the interpreter copies one to the other).
    public static let searchRequest = 0x08BD
    public static let searchActive = 0x08BE
    /// $8B/$8C: the display-list PC (the op 05 record: [05][freq lo][freq hi][X24][Z24]).
    public static let displayListPc = 0x8B
    /// $FC: the selected item of ',' and '.'; $091C: the quick-repeat window.
    public static let selectedItem = 0xFC
    public static let quickRepeatWindow = 0x091C
    /// $0A9A: the mixture (0-7).
    public static let mixture = 0x0A9A
}

extension Machine {
    // MARK: updateAdf ($E7FE)

    /// $E7FE (odd passes): the ADF, when `$09AA` is set. The first call (the flag `$E7F2` shifted
    /// out) draws the face ($E936). With a station found (`$E7F3`): `stationBearing` of station A,
    /// then h = (bearing - view heading `$70/$71`, with the carry $3C8F left) + $4000 + the offsets
    /// (high bytes `$0849`, `$0847`), halved into `$C4/$C5` and `$C0/$C1`; needle = $58 - 1 -
    /// (h × 88 >> 15). The needle (gauge 4, angle `$E7F6`) is redrawn when it changed and `$E7F6`
    /// is not negative, followed by the bearing readout ($E860). Clobbers A, X, Y.
    public func updateAdf() {
        let m = mem
        guard m[Readouts.adfEnable] != 0 else { charge(13); return }
        let pending = m[Adf.panelPending]
        m[Adf.panelPending] = pending >> 1
        var c = 12                                          // enabled: is the face still pending?
        if pending & 1 == 0 { c += 3 } else {
            charge(c + 8)
            drawAdfPanel()
            c = 0
        }
        guard m[Adf.found] != 0 else { charge(c + 13); return }
        charge(c + 14)                                      // a station: its bearing
        let carry = stationBearing(station: 0)
        // The relative bearing plus a quarter turn and both heading offsets (high bytes),
        // halved into `$C4/$C5` and `$C0/$C1` alike.
        let (lo, k) = Readouts.sbc(m[0xB8], m[Readouts.viewHeading], carry)
        m[0xC4] = lo
        m[0xC0] = lo
        let (d, _) = Readouts.sbc(m[0xB9], m[Readouts.viewHeading + 1], k)
        let sum = d &+ 0x40 &+ m[Readouts.headingOffsetB + 1] &+ m[Readouts.headingOffsetA + 1]
        m[0xC5] = sum >> 1
        m[0xC1] = sum >> 1
        let c4 = m[0xC4]
        m[0xC4] = c4 >> 1 | (sum & 1) << 7
        m[0xC0] = m[0xC0] >> 1 | (c4 & 1) << 7
        charge(62)
        let p = mulQ15AX(a: 0x58, x: 0)
        let angle = (p.a ^ 0xFF) &+ 0x58
        // The needle angle; a negative stored angle means no needle is drawn.
        let old = m[Adf.needle]
        guard old & 0x80 == 0 else { charge(19); return }
        let same = angle == m[Adf.needle]
        m[Adf.needle] = angle
        guard !same else { charge(29); return }
        charge(32)                                          // changed: erase the old needle
        drawNeedle(angle: old, gauge: 4)
        charge(12)
        drawNeedle(angle: m[Adf.needle], gauge: 4)
        charge(6)
        drawAdfBearing()
        charge(6)
    }

    /// $E860: the ADF bearing readout: (`$C0/$C1` + $2000) & $7FFF (the halved relative bearing,
    /// turned to point at the station) × 360 >> 15 = degrees into `$B8/$B9`, three digits into
    /// the record at $E930 (inside the ADF face). Clobbers A, X, Y.
    public func drawAdfBearing() {
        let m = mem
        m[0xC4] = m[0xC0]
        m[0xC5] = (m[0xC1] &+ 0x20) & 0x7F
        charge(28)
        let p = mulQ15AX(a: 0x68, x: 0x01)
        m[0xB8] = p.a
        m[0xB9] = p.x
        charge(16)
        format3Digits(field: Adf.bearingRecord + 2)
        charge(7)                                           // tail jump to drawTextRecord
        drawTextRecord(Adf.bearingRecord)
    }

    /// $E936: draws the ADF face (the record list $E886 over the NAV2 OBI), the needle at angle
    /// 10 (`$E7F6` = 10), the bearing record $E930 and the frequency record $E7F7. Clobbers
    /// A, X, Y.
    public func drawAdfPanel() {
        charge(10)
        drawTextList(Adf.panelRecords)
        mem[Adf.needle] = 0x0A
        charge(14)
        drawNeedle(angle: 0x0A, gauge: 4)
        charge(10)
        drawTextRecord(Adf.bearingRecord)
        charge(10)
        drawTextRecord(Adf.frequencyRecord)
        charge(6)
    }

    // MARK: ndbHook ($E956)

    /// $E956: display-list op 05 (through the hook $802A patched at init), an NDB record
    /// `[05][freq lo][freq hi][X24][Z24]` at the display-list PC `$8B/$8C`. While the ADF search
    /// is active (`$08BE`): clears the request `$08BD`; when the frequency matches `$E7F4/$E7F5`,
    /// station A = (fraction 0, X24) and (fraction 0, Z24) and `$E7F3` = 1.
    ///
    /// Returns A = 9, the record length: the original ends by loading 9 and jumping to $8018, the
    /// interpreter's advance ($8749), which the caller (the scenery interpreter) continues with.
    /// The cycles charged end with that jump to $8018; the jump on to $8749 is the interpreter's.
    @discardableResult
    public func ndbHook() -> UInt8 {
        let m = mem
        let tail = 5                                        // the record length and the jump back
        guard m[Adf.searchActive] != 0 else { charge(7 + tail); return 9 }
        m[Adf.searchRequest] = 0
        let pc = zpPointer(Adf.displayListPc)
        func record(_ i: UInt8) -> UInt8 { m[(pc + Int(i)) & 0xFFFF] }
        // Searching: clear the request, then compare the frequency's low byte with the record's.
        var c = 23 + Machine.pageCrossing(pc, 1)
        guard m[Adf.frequency] == record(1) else { charge(c + 3 + tail); return 9 }
        c += 13 + Machine.pageCrossing(pc, 2)               // then the high byte
        guard m[Adf.frequency + 1] == record(2) else { charge(c + 3 + tail); return 9 }
        m[Radio.navStationA] = 0
        m[Radio.navStationA + 4] = 0
        c += 12                                             // a match: both fraction bytes zeroed
        for (i, offset) in [(UInt8(3), 1), (4, 2), (5, 3), (6, 5), (7, 6), (8, 7)] {
            m[Radio.navStationA + offset] = record(i)
            c += 7 + Machine.pageCrossing(pc, i) + 4        // one coordinate byte copied
        }
        m[Adf.found] = 1
        charge(c + 6 + tail)
        return 9
    }

    // MARK: Tuning helpers ($E9A7-$EA5B)

    /// $E9A7 (A, CTRL-A, left SHIFT): selects the ADF digits: `$FC` = $0D, or within the quick-
    /// repeat window (`$091C` != 0) and `$FC` in $0D-$0F, the next item ($0E, $0F, then $10 the
    /// fuel tank). Ends with a jump to $2BBC (`storeSelected`: `$FC` = A, `$091C` = 3).
    public func selectAdfDigit() {
        let m = mem
        var c = 4
        var item: UInt8 = 0x0D
        if m[Adf.quickRepeatWindow] == 0 {
            c += 5
        } else {
            let fc = m[Adf.selectedItem]
            c += 7
            if fc < 0x0D {
                c += 5
            } else {
                c += 4
                if fc >= 0x10 { c += 5 } else { c += 7; item = fc &+ 1 }   // the next digit
            }
        }
        charge(c + 3)                                       // on to $2BBC
        storeSelected(item)
    }

    /// $E9BF (',' before its own handling at $286D): with the ADF enabled and `$FC` = $0D-$0F,
    /// lowers that ADF digit ('0' wraps to '9') via $EA2B; with `$FC` = 3, raises the mixture
    /// `$0A9A` (stops at 7) through $1C23. Returns A = `$FC` (the caller continues with it).
    /// Clobbers X, Y.
    @discardableResult
    public func tuneDecrementPre() -> UInt8 {
        let m = mem
        var c = 4                                           // is the ADF enabled?
        if m[Readouts.adfEnable] == 0 { c += 3 } else {
            let fc = m[Adf.selectedItem]
            c += 7
            if fc < 0x0D { c += 3 } else {
                c += 4
                if fc >= 0x10 { c += 3 } else {
                    let x = fc &- 0x0D
                    var digit = m[Adf.digits + Int(x)]
                    // The digit's index and the digit itself.
                    c += 12 + Machine.pageCrossing(Adf.digits, x) + 2
                    if digit != 0x30 { c += 3 } else { c += 4; digit = 0x3A }
                    charge(c + 10)                          // one lower, stored through $EA2B
                    c = 0
                    setAdfDigit(x, digit &- 1)
                }
            }
        }
        c += 5                                              // the mixture prefix?
        if m[Adf.selectedItem] != 3 { c += 3 } else {
            let x = m[Adf.mixture] &+ 1
            c += 10                                         // one richer, up to 7
            if x == 8 { c += 3 } else {
                charge(c + 10)
                c = 0
                drawMixtureIndicator(x)
            }
        }
        charge(c + 12)                                      // returns `$FC` through $EA28
        return m[Adf.selectedItem]
    }

    /// $E9F6 ('.' before $298E): the counterpart of `tuneDecrementPre`: raises the ADF digit ('9'
    /// wraps to '0') and lowers the mixture (stops at 0). Returns A = `$FC`. Clobbers X, Y.
    @discardableResult
    public func tuneIncrementPre() -> UInt8 {
        let m = mem
        var c = 4                                           // is the ADF enabled?
        if m[Readouts.adfEnable] == 0 { c += 4 } else {     // the skip branch to $EA18 crosses a page
            let fc = m[Adf.selectedItem]
            c += 7
            if fc < 0x0D { c += 3 } else {
                c += 4
                if fc >= 0x10 { c += 3 } else {
                    let x = fc &- 0x0D
                    var digit = m[Adf.digits + Int(x)]
                    c += 12 + Machine.pageCrossing(Adf.digits, x) + 2
                    if digit != 0x39 { c += 3 } else { c += 4; digit = 0x2F }
                    charge(c + 10)                          // one higher, stored through $EA2B
                    c = 0
                    setAdfDigit(x, digit &+ 1)
                }
            }
        }
        c += 5                                              // the mixture prefix?
        if m[Adf.selectedItem] != 3 { c += 3 } else {
            let x = m[Adf.mixture] &- 1
            c += 8                                          // one leaner, down to 0
            if x & 0x80 != 0 { c += 3 } else {
                charge(c + 10)
                c = 0
                drawMixtureIndicator(x)
            }
        }
        charge(c + 9)                                       // returns `$FC`
        return m[Adf.selectedItem]
    }

    /// $EA2B: stores ADF digit X, redraws the frequency record $E7F7, rebuilds `$E7F4` = d1·16
    /// + (d2 & 15) and `$E7F5` = d0 & 15 (`$B9` = scratch), then `renewAdfSearch`.
    private func setAdfDigit(_ x: UInt8, _ digit: UInt8) {
        let m = mem
        m[Adf.digits + Int(x)] = digit
        charge(15)
        drawTextRecord(Adf.frequencyRecord)
        m[0xB9] = m[Adf.digits + 1] << 4
        m[Adf.frequency] = (m[Adf.digits + 2] & 0x0F) | m[0xB9]
        m[Adf.frequency + 1] = m[Adf.digits] & 0x0F
        charge(38)
        renewAdfSearch()
    }

    /// $EA50 (once per 8 passes; also the tail of $EA2B): `$E7F3` = 0 and the ADF search request
    /// `$08BD` = 1, so the NDB is looked up again. Returns A = `$FC`.
    @discardableResult
    public func renewAdfSearch() -> UInt8 {
        mem[Adf.found] = 0
        mem[Adf.searchRequest] = 1
        charge(24)                                          // returns `$FC` through $EA28
        return mem[Adf.selectedItem]
    }
}
