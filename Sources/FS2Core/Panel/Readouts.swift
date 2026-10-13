/// The panel's digital readouts ($2240-$224F, $3773-$3AF0, $EB82-$EBA4): the DG and compass
/// headings, the 3-digit formatter, OBS courses, clock, DME distance, magneto/lights/carb-heat
/// labels, tach and the slew position readout. The radio frequency readouts are in
/// `Radio/RadioDisplays.swift`.
///
/// Every readout is a text record `[row][x/2][ASCII...][0]` (see `Raster/Text.swift`): the code
/// writes the digits into the record in memory and redraws it with `drawTextRecord` ($1DDE).
/// The cells are opaque, so a redraw replaces the old digits; nothing is XORed here.
///
/// Literal translation: every byte the original reads is read from `mem` when it reads it,
/// every byte it writes is written in the same order (zero-page scratch included), and the
/// original's exact cycle count is charged (each routine's own instructions through its return;
/// the call itself belongs to the caller). Nothing touches I/O. `re/docs/panel.md` documents
/// every routine.
public enum Readouts {
    /// $2196 / $2199: OBS1 / OBS2 course in 2-degree units (0-$B3). The bytes after each
    /// ($2197, $2198) are the DG and tach "last drawn" values below.
    public static let obs1 = 0x2196
    public static let obs2 = 0x2199
    /// $2197: low byte of the DG heading in degrees as last drawn ($377C compares only this byte).
    public static let dgDrawnDegrees = 0x2197
    /// $2198: the engine value `$09BE` the tach last showed.
    public static let tachDrawnRpm = 0x2198

    // MARK: Text records (the digits start at record + 2)

    /// $219C / $21A2: DG heading (171, 35) and its reciprocal (187, 35), 3 digits.
    public static let dgRecord: UInt16 = 0x219C
    public static let dgReciprocalRecord: UInt16 = 0x21A2
    /// $21A8: magnetic compass, (106, 114) inside the window, 3 digits.
    public static let compassRecord: UInt16 = 0x21A8
    /// $21AE: COM (122, 120), 4 digits after the painted '1' (118.00-135.95).
    public static let comRecord: UInt16 = 0x21AE
    /// $21B5 / $21BC: NAV1 (138, 120) / NAV2 (154, 120), 4 digits (108.00-117.95).
    public static let nav1Record: UInt16 = 0x21B5
    public static let nav2Record: UInt16 = 0x21BC
    /// $21C3 / $21C9: OBS1 (117, 93) and reciprocal (149, 93); $21CF / $21D5: OBS2 (160, 93)
    /// and reciprocal (192, 93). 3 digits each.
    public static let obs1Record: UInt16 = 0x21C3
    public static let obs1ReciprocalRecord: UInt16 = 0x21C9
    public static let obs2Record: UInt16 = 0x21CF
    public static let obs2ReciprocalRecord: UInt16 = 0x21D5
    /// $21DB: transponder (154, 140), 4 octal digits.
    public static let transponderRecord: UInt16 = 0x21DB
    /// $21E2: tach (194, 132), 4 digits (the last is always '0').
    public static let tachRecord: UInt16 = 0x21E2
    /// $21E9 / $21EE / $21F3: clock hours / minutes / seconds (163, 129 / 138 / 147).
    public static let clockHoursRecord: UInt16 = 0x21E9
    public static let clockMinutesRecord: UInt16 = 0x21EE
    public static let clockSecondsRecord: UInt16 = 0x21F3
    /// $21F8: DME (138, 140), 3 digits around a painted point (NN.N).
    public static let dmeRecord: UInt16 = 0x21F8
    /// $21FE / $2202: lights '1' / 'O' (170, 155).
    public static let lightsOnRecord: UInt16 = 0x21FE
    public static let lightsOffRecord: UInt16 = 0x2202
    /// $2206 / $220B: carb heat 'HT' (on) / 'CH' (off) at (194, 150).
    public static let carbHeatOnRecord: UInt16 = 0x2206
    public static let carbHeatOffRecord: UInt16 = 0x220B
    /// $2210: six 8-byte TO/FROM records: NAV1 OFF/TO/FR (141, 94), then NAV2 (184, 94).
    public static let toFromRecords: UInt16 = 0x2210
    /// $3A67: five pointers to the magneto label records O/L/R/B/S at $EE57-$EE67.
    public static let magnetoLabelPointers = 0x3A67
    /// $7FE5-$7FE7: the screen-RAM color cells of the CH/HT label ($FE off, $B8 on).
    public static let carbHeatCells = 0x7FE5
    /// $EB63 / $EB73: slew readouts ' NNNNN NORTH ' (2, 20) and ' NNNNN EAST ' (2, 82).
    public static let slewNorthRecord: UInt16 = 0xEB63
    public static let slewEastRecord: UInt16 = 0xEB73

    // MARK: Variables read

    /// $0966: slew mode (mode record +02).
    public static let slewMode = 0x0966
    /// $096B / $096D: the editor's NORTH / EAST settings, printed by the slew readout.
    public static let settingNorth = 0x096B
    public static let settingEast = 0x096D
    /// $08C0: DG offset (binary angle); $08C5: compass heading (binary angle).
    public static let dgOffset = 0x08C0
    public static let compassHeading = 0x08C5
    /// $0846 / $0848: the per-area heading offsets (binary angles).
    public static let headingOffsetA = 0x0846
    public static let headingOffsetB = 0x0848
    /// $70/$71: view heading (binary angle).
    public static let viewHeading = 0x70
    /// $091A / $0984 / $0983: clock seconds / minutes / hours.
    public static let clockSeconds = 0x091A
    public static let clockMinutes = 0x0984
    public static let clockHours = 0x0983
    /// $09BE: engine value (RPM/50).
    public static let engineRpm = 0x09BE
    /// $0AA9 carb heat, $0AB5 lights, $0AB6 magneto label index (0-4).
    public static let carbHeat = 0x0AA9
    public static let lights = 0x0AB5
    public static let magnetoLabel = 0x0AB6
    /// $09AA: ADF enable (the NAV2 readouts give way to the ADF).
    public static let adfEnable = 0x09AA
    /// $FD / $FE / $FF: the instrument enable masks.
    public static let instrumentMask0 = 0xFD
    public static let instrumentMask1 = 0xFE
    public static let instrumentMask2 = 0xFF

    /// The DME state the nav code ($3DA2) leaves for `drawDme`.
    public enum Dme {
        /// $09AB: 1 when NAV1 has no station (the DME shows blanks).
        public static let noStation = 0x09AB
        /// $09AC: redraw request, consumed by `drawDme`, which shifts it right.
        public static let redraw = 0x09AC
        /// $09AD / $09AE: tenths and whole nautical miles.
        public static let tenths = 0x09AD
        public static let miles = 0x09AE
    }

    // MARK: 6502 arithmetic helpers

    /// The 6502's subtract with borrow: a - b - (1 - carry); returns the result and the carry
    /// out (set = no borrow).
    @inline(__always)
    static func sbc(_ a: UInt8, _ b: UInt8, _ carry: Bool) -> (UInt8, Bool) {
        let r = Int(a) - Int(b) - (carry ? 0 : 1)
        return (UInt8(truncatingIfNeeded: r), r >= 0)
    }

    /// The 6502's add with carry (binary mode): a + b + carry; returns the result and the carry
    /// out.
    @inline(__always)
    static func adc(_ a: UInt8, _ b: UInt8, _ carry: Bool) -> (UInt8, Bool) {
        let r = Int(a) + Int(b) + (carry ? 1 : 0)
        return (UInt8(truncatingIfNeeded: r), r > 0xFF)
    }

    /// The decimal digit loop: X counts up from '0' - 1 while 10 is subtracted until it borrows,
    /// then 10 + '0' is added back for the ones: tens in X, ones in A (both ASCII; values of 100
    /// and more give tens past '9'). `crossing` is true when the loop's branch crosses a page (one
    /// more cycle per taken branch). Returns the loop's cycles.
    @inline(__always)
    static func decimalDigits(_ value: UInt8, crossing: Bool) -> (tens: UInt8, ones: UInt8, cycles: Int) {
        let n = value / 10
        let tens = 0x30 &+ n
        let ones = 0x30 &+ (value - n * 10)
        // Setup (2), n + 1 passes of the count-and-subtract body (6 each), n taken branches (3,
        // or 4 across a page) and the final one not taken (2), then the add-back (4).
        let cycles = 2 + 6 * (Int(n) + 1) + (crossing ? 4 : 3) * Int(n) + 6
        return (tens, ones, cycles)
    }
}

extension Machine {
    // MARK: panelRedraw ($2240)

    /// $2240: redraws the radio and clock readouts at init (the disk's panel bitmap has stale
    /// digits): NAV1, NAV2, COM, transponder, clock. Each is skipped when `$FE` bit 7 (radios)
    /// is clear. Clobbers A, X, Y.
    public func panelRedraw() {
        charge(6); drawNav1Frequency()
        charge(6); drawNav2Frequency()
        charge(6); drawComFrequency()
        charge(6); drawTransponder()
        charge(6); drawClock()
        charge(6)                                           // the return
    }

    // MARK: radioGate ($3A53)

    /// $3A53: the radio gate. When `$FE` bit 7 (radios) is set it simply returns; otherwise it
    /// pulls the caller's return address off the stack, so its own return leaves the caller as
    /// well. Returns whether the gate is open and its cycles (its return included; when closed
    /// that return ends the caller too, which then charges nothing more).
    @inline(__always)
    func radioGate() -> (open: Bool, cycles: Int) {
        mem[Readouts.instrumentMask1] & 0x80 != 0 ? (true, 14) : (false, 21)
    }

    // MARK: Heading and DG ($3773-$3803)

    /// $3773 (draw sequence): in slew mode (`$0966`), the slew position readout ($EB82).
    public func headingReadout() {
        guard mem[Readouts.slewMode] != 0 else { charge(13); return }
        charge(12)
        drawSlewReadout()
        charge(6)
    }

    /// $377C (draw sequence): the DG, when `$FD` bit 2 is set.
    ///
    /// heading = view heading `$70/$71` + DG offset `$08C0` - `$0848` - `$0846` (16-bit), with
    /// $8000 turned into $8001 (so the Q15 multiply does not meet -32768); degrees = $37EA. When
    /// the low byte of the degrees equals `$2197` nothing is drawn (so headings 256 degrees apart,
    /// e.g. 5 and 261, do not redraw). Otherwise `$2197` = that byte, the heading goes into the
    /// record at $219C and degrees - 180 (wrapped by $37F5) into $21A2. Uses `$39` as scratch for
    /// the high byte. Clobbers A, X, Y.
    public func drawDgDigits() {
        let m = mem
        guard m[Readouts.instrumentMask0] & 0x04 != 0 else { charge(14); return }
        let sum = u16(Readouts.viewHeading) &+ u16(Readouts.dgOffset)
            &- u16(Readouts.headingOffsetB) &- u16(Readouts.headingOffsetA)
        var lo = UInt8(sum & 0xFF)
        let hi = UInt8(sum >> 8)
        // The gate, the three 16-bit sums (24 + 18 + 18), and the test for a high byte of $80.
        var c = 69
        if hi != 0x80 {
            c += 3                                          // not $80xx
        } else {
            c += 4                                      // $80xx: is the low byte 0?
            if lo != 0 { c += 3 } else { c += 4; lo = 1 }   // $8000 becomes $8001
        }
        charge(c + 6)                                       // to degrees ($37EA)
        let degrees = headingToDegrees(lo, hi)
        guard degrees.lo != m[Readouts.dgDrawnDegrees] else { charge(13); return }
        m[Readouts.dgDrawnDegrees] = degrees.lo
        m[0x39] = degrees.hi
        // Record the drawn byte, keep the degrees (low byte on the stack, high in $39), and
        // format them into $219C.
        charge(26)
        format3Digits(field: Readouts.dgRecord + 2)
        charge(10)
        drawTextRecord(Readouts.dgRecord)
        // The reciprocal: degrees - 180, wrapped by $37F5.
        let (rlo, noBorrow) = Readouts.sbc(degrees.lo, 0xB4, true)
        let (rhi, _) = Readouts.sbc(m[0x39], 0, noBorrow)
        charge(27)
        wrapDegrees(rlo, rhi)
        charge(10)
        format3Digits(field: Readouts.dgReciprocalRecord + 2)
        charge(7)                                   // on into the text drawer by a jump
        drawTextRecord(Readouts.dgReciprocalRecord)
    }

    /// $37EA: a binary angle (A = low, X = high) to degrees: `$C4/$C5` = the angle, times 180
    /// through `mulQ15AX` ($17EF), then `wrapDegrees`. Returns the degrees as stored in `$B8/$B9`.
    @discardableResult
    public func headingToDegrees(_ lo: UInt8, _ hi: UInt8) -> (lo: UInt8, hi: UInt8) {
        mem[0xC4] = lo
        mem[0xC5] = hi
        charge(16)                           // the angle times 180
        let p = mulQ15AX(a: 0xB4, x: 0)
        return wrapDegrees(p.a, p.x)
    }

    /// $37F5: adds 360 to a negative value (A = low, X = high; the sign test leaves the carry
    /// set, so adding $67 to the low byte really adds $68, and the high byte gets +1), then stores
    /// it in `$B8/$B9`. Returns it.
    @discardableResult
    public func wrapDegrees(_ lo: UInt8, _ hi: UInt8) -> (lo: UInt8, hi: UInt8) {
        var a = lo, x = hi
        var c = 2                                           // the sign test
        if x < 0x80 {
            c += 3                                          // not negative: as it is
        } else {
            let (s, carry) = Readouts.adc(a, 0x67, true)
            a = s
            c += 4                                      // negative: add to the low byte
            if carry { c += 4; x &+= 1 } else { c += 3 }   // carry into the high byte
            x &+= 1
            c += 2                                          // and the high byte's +1
        }
        mem[0xB8] = a
        mem[0xB9] = x
        charge(c + 12)                               // store, return
        return (a, x)
    }

    // MARK: format3Digits ($3804)

    /// $3804 (vector $2033): writes the unsigned value at `$B8/$B9` as three ASCII digits at
    /// `field` (A = low, X = high): hundreds and tens through the text unit's digit routine $1DBB (`printDigit`), then
    /// `$B8 | '0'`. `$BA/$BB` = field, `$A5-$A7` and `$B8/$B9` as $1DBB leaves them. Values of
    /// 1000 and more give a first digit past '9'. Clobbers A, X, Y.
    public func format3Digits(field: UInt16) {
        let m = mem
        m[0xBA] = UInt8(field & 0xFF)
        m[0xBB] = UInt8(field >> 8)
        var c = 18                       // the field pointer, then the hundreds
        c += printDigit(divisor: 100, place: 0, field: Int(u16(0xBA)))
        c += 12
        c += printDigit(divisor: 10, place: 1, field: Int(u16(0xBA)))
        m[Machine.indirectY(m[0xBA], m[0xBB], 2)] = m[0xB8] | 0x30
        charge(c + 19)                       // the ones digit straight from the remainder
    }

    // MARK: updateCompass ($3823)

    /// $3823 (draw sequence): the magnetic compass, when `$FE` bit 4 is set.
    ///
    /// d = compass `$08C5` - view heading `$70/$71` + `$0848` + `$0846` (16-bit). The compass
    /// moves toward the heading: d >= $0A00 by -1200, 0 <= d < $0A00 by -75, -$0A00 <= d < 0 by
    /// +75, d < -$0A00 by +1200 (the tests are signed compares of the high byte). Every call
    /// moves it, so it hunts around the heading. Then degrees ($37EA) into the record at $21A8,
    /// drawn in the window (106, 114). Clobbers A, X, Y.
    public func updateCompass() {
        let m = mem
        guard m[Readouts.instrumentMask1] & 0x10 != 0 else { charge(14); return }
        let compass = u16(Readouts.compassHeading)
        let d = compass &- u16(Readouts.viewHeading) &+ u16(Readouts.headingOffsetB) &+ u16(Readouts.headingOffsetA)
        let x = UInt8(d >> 8)
        // The gate, the three 16-bit sums (24 + 18 + 18), and the flags of the high byte.
        var c = 71
        let step: UInt16
        if x & 0x80 == 0 {
            c += 4                                      // not negative: against $0A
            if (x &- 0x0A) & 0x80 == 0 {
                c += 10; step = 0xFB50           // far ahead: -1200
            } else {
                c += 9; step = 0xFFB5           // -75
            }
        } else {
            c += 5                                      // negative: against $F6
            if (x &- 0xF6) & 0x80 != 0 {
                c += 7; step = 0x04B0               // far behind: +1200
            } else {
                c += 9; step = 0x004B           // +75
            }
        }
        let new = compass &+ step
        setU16(Readouts.compassHeading, new)
        charge(c + 32)                                  // the add and stores, then to degrees ($37EA)
        headingToDegrees(UInt8(new & 0xFF), UInt8(new >> 8))
        charge(10)
        format3Digits(field: Readouts.compassRecord + 2)
        charge(7)                                   // on into the text drawer by a jump
        drawTextRecord(Readouts.compassRecord)
    }

    // MARK: OBS courses ($3923, $3976)

    /// $3923: OBS1 and its reciprocal into the records at $21C3/$21C9, when `$FD` bit 5 (NAV1)
    /// is set. The reciprocal is OBS - 90 units, + 180 when that borrows. Clobbers A, X, Y.
    public func drawObs1() {
        guard mem[Readouts.instrumentMask0] & 0x20 != 0 else { charge(14); return }
        charge(7)
        drawObsPair(Readouts.obs1, Readouts.obs1Record, Readouts.obs1ReciprocalRecord)
    }

    /// $3976: OBS2 and its reciprocal ($21CF/$21D5), when `$FF` bit 3 (NAV2) is set and the ADF
    /// is off (`$09AA` = 0). Clobbers A, X, Y.
    public func drawObs2() {
        let m = mem
        guard m[Readouts.instrumentMask2] & 0x08 != 0 else { charge(14); return }
        guard m[Readouts.adfEnable] == 0 else { charge(20); return }
        charge(13)
        drawObsPair(Readouts.obs2, Readouts.obs2Record, Readouts.obs2ReciprocalRecord)
    }

    /// The shared body of $3923/$3976, from the first read of the OBS value to the return.
    private func drawObsPair(_ obs: Int, _ record: UInt16, _ reciprocal: UInt16) {
        let m = mem
        let first = Machine.obsDigits(m[obs])
        let field = Int(record) + 2
        m[field] = first.hundreds
        m[field + 1] = first.tens
        m[field + 2] = first.ones
        // The course's digits ($395E) into the record, then the reciprocal, 90 units back.
        var c = 10 + first.cycles + 20
        let v = m[obs]
        var r = v &- 0x5A
        if v >= 0x5A { c += 3 } else { c += 6; r = r &+ 0xB4 }   // borrowed: wrap by 180 units
        let second = Machine.obsDigits(r)
        let field2 = Int(reciprocal) + 2
        m[field2] = second.hundreds
        m[field2 + 1] = second.tens
        m[field2 + 2] = second.ones
        charge(c + 6 + second.cycles + 22)
        drawTextRecord(record)
        charge(10)
        drawTextRecord(reciprocal)
        charge(6)                                           // the return
    }

    /// $395E: an OBS value (2-degree units) as three ASCII digits of degrees: Y = '0' + v / 50,
    /// then (v mod 50) × 2 gives X = tens and A = ones. Cycles include the return.
    static func obsDigits(_ value: UInt8) -> (hundreds: UInt8, tens: UInt8, ones: UInt8, cycles: Int) {
        let n1 = value / 50
        let twice = (value - n1 * 50) << 1
        let n2 = twice / 10
        // Setup (2), the fifties loop (9 n1 + 8), add back and double (6), setup (2), the tens
        // loop (9 n2 + 8), then the add-back and the return (10).
        let cycles = 2 + 9 * Int(n1) + 8 + 2 + 2 + 2 + 2 + 9 * Int(n2) + 18
        return (0x30 &+ n1, 0x30 &+ n2, 0x30 &+ (twice - n2 * 10), cycles)
    }

    // MARK: Clock ($39B6, $39D9)

    /// $39B6 (the 1 Hz clock tick at $2409): seconds `$091A` into the record at $21F3; when the
    /// seconds are 0 it falls into `drawClock`. Gated by $3A53. Clobbers A, X, Y.
    public func drawClockSeconds() {
        let m = mem
        let gate = radioGate()
        guard gate.open else { charge(6 + gate.cycles); return }
        let d = Readouts.decimalDigits(m[Readouts.clockSeconds], crossing: false)
        m[Int(Readouts.clockSecondsRecord) + 2] = d.tens
        m[Int(Readouts.clockSecondsRecord) + 3] = d.ones
        charge(6 + gate.cycles + 4 + d.cycles + 18)
        drawTextRecord(Readouts.clockSecondsRecord)
        // Minutes and hours only on the full minute (the skip branch crosses a page).
        guard m[Readouts.clockSeconds] == 0 else { charge(14); return }
        charge(6)
        drawClock()
    }

    /// $39D9 (vector $2000): minutes `$0984` into $21EE and hours `$0983` into $21E9, redrawn.
    /// Gated by $3A53. Clobbers A, X, Y.
    public func drawClock() {
        let m = mem
        let gate = radioGate()
        guard gate.open else { charge(6 + gate.cycles); return }
        let minutes = Readouts.decimalDigits(m[Readouts.clockMinutes], crossing: false)
        m[Int(Readouts.clockMinutesRecord) + 2] = minutes.tens
        m[Int(Readouts.clockMinutesRecord) + 3] = minutes.ones
        charge(6 + gate.cycles + 4 + minutes.cycles + 18)
        drawTextRecord(Readouts.clockMinutesRecord)
        // The hours loop's branch at $3A00 crosses back into page $39.
        let hours = Readouts.decimalDigits(m[Readouts.clockHours], crossing: true)
        m[Int(Readouts.clockHoursRecord) + 2] = hours.tens
        m[Int(Readouts.clockHoursRecord) + 3] = hours.ones
        charge(4 + hours.cycles + 18)
        drawTextRecord(Readouts.clockHoursRecord)
        charge(6)                                           // the return
    }

    // MARK: DME ($3A13)

    /// $3A13 (phase 0): the DME readout. Gated by $3A53; draws only when shifting `$09AC` right
    /// drops out a 1 (the nav code sets it on a change). With no NAV1 station (`$09AB` != 0) the
    /// three digits become blanks; otherwise tenths `$09AD` and miles `$09AE` (two digits; 100 and
    /// more give a tens digit past '9') go into the record at $21F8. Clobbers A, X, Y.
    public func drawDme() {
        let m = mem
        let gate = radioGate()
        guard gate.open else { charge(6 + gate.cycles); return }
        let request = m[Readouts.Dme.redraw]
        m[Readouts.Dme.redraw] = request >> 1
        var c = 6 + gate.cycles + 6                         // consume the request bit
        guard request & 1 != 0 else { charge(c + 9); return }
        c += 6                                          // requested: is there a station?
        let field = Int(Readouts.dmeRecord) + 2
        if m[Readouts.Dme.noStation] != 0 {
            m[field] = 0x20
            m[field + 1] = 0x20
            m[field + 2] = 0x20
            c += 20                      // no station: three blanks
        } else {
            m[field + 2] = m[Readouts.Dme.tenths] &+ 0x30
            let d = Readouts.decimalDigits(m[Readouts.Dme.miles], crossing: false)
            m[field] = d.tens
            m[field + 1] = d.ones
            c += 18 + d.cycles + 8  // the tenths digit, then the two digits of the miles
        }
        charge(c + 10)
        drawTextRecord(Readouts.dmeRecord)
        charge(6)                                           // the return
    }

    // MARK: Engine labels ($3A71, $3AB9)

    /// $3A71: the carb-heat label ('HT' when `$0AA9` != 0, else 'CH') with its color cells
    /// $7FE5-$7FE7 ($B8 / $FE), the lights label ('1' when `$0AB5` != 0, else 'O') and the
    /// magneto label `$0AB6` through the pointers at $3A67. Gated by $3A53. Clobbers A, X, Y.
    public func drawMagnetoLabel() {
        let m = mem
        let gate = radioGate()
        guard gate.open else { charge(6 + gate.cycles); return }
        var c = 6 + gate.cycles + 8                 // assume 'HT', test the carb heat
        let cells: UInt8
        if m[Readouts.carbHeat] != 0 {
            charge(c + 9)                               // on: draw 'HT'
            drawTextRecord(Readouts.carbHeatOnRecord)
            c = 2; cells = 0xB8
        } else {
            charge(c + 12)                       // off: draw 'CH'
            drawTextRecord(Readouts.carbHeatOffRecord)
            c = 5; cells = 0xFE                         // the off color
        }
        m[Readouts.carbHeatCells] = cells
        m[Readouts.carbHeatCells + 1] = cells
        m[Readouts.carbHeatCells + 2] = cells
        c += 20                          // color the three cells, assume '1', test the lights
        let lightsRecord: UInt16
        if m[Readouts.lights] != 0 { c += 3; lightsRecord = Readouts.lightsOnRecord } else {
            c += 6; lightsRecord = Readouts.lightsOffRecord
        }
        charge(c + 6)
        drawTextRecord(lightsRecord)
        // The magneto label's record, through the pointer table at $3A67.
        let x = m[Readouts.magnetoLabel] << 1
        let lo = m[Readouts.magnetoLabelPointers + Int(x)]
        let hi = m[Readouts.magnetoLabelPointers + 1 + Int(x)]
        charge(12 + Machine.pageCrossing(Readouts.magnetoLabelPointers, x) + 3
               + 4 + Machine.pageCrossing(Readouts.magnetoLabelPointers + 1, x) + 12)
        drawTextRecord(UInt16(hi) << 8 | UInt16(lo))
        charge(6)                                           // the return
    }

    /// $3AB9 (draw sequence): the tach, when `$FD` bit 6 is set and `$09BE` differs from the
    /// value last drawn (`$2198`): digits of `$09BE` >> 1, then '0' or '5' from bit 0 (RPM =
    /// `$09BE` × 50; the record's last '0' is fixed). Clobbers A, X, Y.
    public func drawTach() {
        let m = mem
        guard m[Readouts.instrumentMask0] & 0x40 != 0 else { charge(14); return }
        let rpm = m[Readouts.engineRpm]
        guard rpm != m[Readouts.tachDrawnRpm] else { charge(26); return }
        m[Readouts.tachDrawnRpm] = rpm
        // The gate, the change test, record the value, halve it, then '0' or '5' by the odd bit.
        var c = 31
        let field = Int(Readouts.tachRecord) + 2
        if rpm & 1 == 0 { c += 3; m[field + 2] = 0x30 } else { c += 4; m[field + 2] = 0x35 }
        let d = Readouts.decimalDigits(rpm >> 1, crossing: false)
        m[field] = d.tens
        m[field + 1] = d.ones
        charge(c + 6 + d.cycles + 18)    // the last digit, the digit loop, two digits, then draw
        drawTextRecord(Readouts.tachRecord)
        charge(6)                                           // the return
    }

    // MARK: Slew readout ($EB82)

    /// $EB82 (via $3773 in slew mode): prints the NORTH (`$096B`) and EAST (`$096D`) settings
    /// as signed 5-digit numbers into the records at $EB63/$EB73 through $1D54 (drawn at the top
    /// of the window). Clobbers A, X, Y.
    public func drawSlewReadout() {
        let m = mem
        m[0xB8] = m[Readouts.settingNorth]
        m[0xB9] = m[Readouts.settingNorth + 1]
        charge(24)
        printSigned5(record: Readouts.slewNorthRecord)
        m[0xB8] = m[Readouts.settingEast]
        m[0xB9] = m[Readouts.settingEast + 1]
        charge(24)
        printSigned5(record: Readouts.slewEastRecord)
        charge(6)                                           // the return
    }
}
