/// ATIS ($E713, $F07A-$F25A, $F26B-$F2E5): the value composer that writes the live weather into
/// the phrase strings, and the teletype that types a matched record's broadcast into the window.
///
/// How a broadcast happens: tuning the COM radio (`$3903`) sets the search request `$0937` and
/// the one-shot `atisOneShot` `$0941`. When the scenery interpreter meets an in-range op 1E record
/// ($8084) with the tuned frequency, it copies the record's 8 parameter bytes to `$0939-$0940`,
/// points `atisTextPtr` at the record's text (record + 13), clears `atisOneShot` and calls the
/// hook $802D, which init patches to jump to $F16A (`composeAtis`). On the next flip pass the
/// main loop calls $E713 (a jump to $F239, `atisTeletype`), which types the text once.
///
/// The record text is plain ASCII plus tokens $80-$8C. Token n types a space cell, the phrase at
/// $F087 + [$EFFA + n] (offset table $F07A), and another space cell:
///
/// | Token | Phrase ($F087 + offset) | Live part written by $F16A |
/// |---|---|---|
/// | $80 | weather | |
/// | $81 | observation | |
/// | $82 | the Zulu time | hours at $F09E-$F09F |
/// | $83 | '' (empty: two space cells) | |
/// | $84 | the temperature | value at $F0B6-$F0B7 |
/// | $85 | information | |
/// | $86 | the active runway | number at $F0E5-$F0E6 |
/// | $87 | advise the controller | |
/// | $88 | the altimeter setting (fixed) | |
/// | $89 | the visibility (fixed) | |
/// | $8A | the wind | direction at $F125-$F127, speed at $F12C-$F12D |
/// | $8B | the measured ceiling | $F133 = 0 cuts it to ' '; hundreds of feet at $F145-$F147 |
/// | $8C | on initial contact | |
///
/// The phrases themselves are read from the disk's bytes at $F087, never written here.
///
/// Literal translation with exact cycles. The busy-waits (per character and at the end) are
/// charged in steps of one outer loop pass (606 / 1791 cycles), so the clock and its events keep
/// running while the message is typed, as the raster IRQ did on the C64.
public enum Atis {
    /// $F07A: token $80-$8C -> offset into the phrases; the teletype reads it as $EFFA + token.
    public static let tokenOffsets = 0xF07A
    public static let tokenOffsetBase = 0xEFFA
    /// $F087: the phrase strings (0-terminated).
    public static let phrases = 0xF087

    // MARK: Phrase bytes $F16A patches

    /// $F09E-$F09F: the Zulu hour in '12:00 ZULU' (tens, units).
    public static let zuluHourDigits = 0xF09E
    /// $F0B6-$F0B7: the temperature in its phrase (tens, units).
    public static let temperatureDigits = 0xF0B6
    /// $F0E5-$F0E6: the runway in 'RUNWAY 31' (tens, units).
    public static let runwayDigits = 0xF0E5
    /// $F125-$F127: the wind direction in 'WIND 330' (hundreds, ' ' for a leading 0; tens; units).
    public static let windDirectionDigits = 0xF125
    /// $F12C-$F12D: the wind speed in 'AT 27' (tens, ' ' for a leading 0; units).
    public static let windSpeedDigits = 0xF12C
    /// $F133: the second byte of the ceiling phrase: 0 (no ceiling: the phrase types as ' ') or ' '.
    public static let ceilingSwitch = 0xF133
    /// $F145-$F147: the ceiling in hundreds of feet in its phrase (leading zeros as ' ').
    public static let ceilingDigits = 0xF145
    /// $F21E-$F220: the three digits `format3Digits` writes for $F221/$F223 (three bytes inside
    /// the code region, zero on disk).
    public static let digitField: UInt16 = 0xF21E

    // MARK: RAM

    /// $0939-$0940: the 8 parameter bytes of the matched record: the runway (a plain number) for
    /// each wind quadrant at $0939 + ($09A3 >> 6), and the temperature for each season at
    /// $093C + season (season 1-4 reads $093D-$0940).
    public static let parameters = 0x0939
    public static let seasonTemperatures = 0x093C
    /// $0941 (`Radio.atisOneShot`): cleared by op 1E; the teletype types once and sets it.
    public static let oneShot = Radio.atisOneShot
    /// $0958/$0959: the record text (record + 13).
    public static let textPointer = 0x0958
    /// $095F: added to the seasonal temperature (the editor's exit stores ($0ACF & $1F) - $10).
    public static let temperatureOffset = 0x095F
    /// $096A: the editor's communication rate: the per-character delay is (256 - rate) mod 256
    /// passes (0: 256).
    public static let commRate = 0x096A
    public static let clockHours = 0x0983
    public static let season = 0x0985
    /// $09A0: surface wind speed; $09A2/$09A3: surface wind direction (binary angle).
    public static let windSpeed = 0x09A0
    public static let windDirection = 0x09A2
    public static let zuluOffset = 0x0854
    /// $0856/$0857: the base of cloud layer 1 in meters (the editor's CLOUD 1 BOTTOMS × $4E >> 8).
    public static let cloudBase = 0x0856
    /// $B8/$B9: the text cursor of the teletype (`printValue`).
    public static let textCursor = 0xB8
    /// $BA-$BD: the one-character text record the teletype draws: row, x, character, 0.
    public static let cellRecord: UInt16 = 0x00BA
    public static let cellRow = 0xBA
    public static let cellX = 0xBB
    public static let cellCharacter = 0xBC
    public static let cellTerminator = 0xBD
    /// The cell layout: x starts at 3 and steps 4; a new line (row += 8, x = 3) when a space or a
    /// token's cell finds x at least $64 (characters never check, so words are not split); a new
    /// page (`clearWindow`, row 3) when the new row would be at least $5A.
    public static let lineEnd: UInt8 = 0x64
    public static let pageEnd: UInt8 = 0x5A
}

extension Machine {
    // MARK: composeAtis ($F16A)

    /// $F16A (through the op 1E hook $802D): writes the live values into the phrase strings.
    ///
    /// - temperature: `$093C[season] + $095F` (8-bit) as tens and units at $F0B6;
    /// - wind direction: (`$09A2/$09A3` × 360) >> 16 degrees at $F125-$F127, a leading '0' as ' ';
    /// - wind speed: `$09A0` at $F12C-$F12D, a leading '0' as ' ';
    /// - Zulu hour: `clockHours + zuluOffset` (8-bit), minus 24 once when at least 24, at $F09E;
    /// - ceiling: (`$0856/$0857` meters × 2150) >> 16 hundreds of feet; when 0, $F133 = 0 drops the
    ///   ceiling phrase, else $F133 = ' ' and the digits go to $F145-$F147 (a leading '0' as ' ',
    ///   and a second '0' as ' ' after a blank hundreds digit);
    /// - runway: `$0939[$09A3 >> 6]` (wind quadrant) at $F0E5.
    ///
    /// Each number goes through `format3Digits` into $F21E-$F220, so `$A5-$A7`, `$B8-$BB` and the
    /// multiply's `$C4-$CB` are left as the original leaves them. Clobbers A, X, Y.
    public func composeAtis() {
        let m = mem
        // Temperature: the season's value plus the editor's offset.
        let season = m[Atis.season]
        let temperature = m[(Atis.seasonTemperatures + Int(season)) & 0xFFFF] &+ m[Atis.temperatureOffset]
        charge(8 + Machine.pageCrossing(Atis.seasonTemperatures, season) + 12)
        var d = atisFormat(lo: temperature, hi: 0, byteEntry: true)
        m[Atis.temperatureDigits] = d.a
        m[Atis.temperatureDigits + 1] = d.x

        // Wind direction: $0168 × $09A2/$09A3, bits 16-31.
        m[0xC4] = 0x68
        m[0xC5] = 0x01
        charge(32)                                       // store the temperature, set up the multiply
        var p = mulU16(a: m[Atis.windDirection], x: m[Atis.windDirection + 1])
        charge(11)                                       // the product's high word to the formatter
        d = atisFormat(lo: p.x, hi: m[0xCB], byteEntry: false)
        m[Atis.windDirectionDigits + 1] = d.a
        m[Atis.windDirectionDigits + 2] = d.x
        var c = 10                                       // tens and units stored; a leading zero?
        var hundreds = d.y
        if hundreds == 0x30 {
            hundreds = 0x20
            c += 4
        } else {
            c += 3
        }
        m[Atis.windDirectionDigits] = hundreds

        // Wind speed.
        charge(c + 14)
        d = atisFormat(lo: m[Atis.windSpeed], hi: 0, byteEntry: true)
        c = 2                                            // a leading zero?
        var tens = d.a
        if tens == 0x30 {
            tens = 0x20
            c += 4
        } else {
            c += 3
        }
        m[Atis.windSpeedDigits] = tens
        m[Atis.windSpeedDigits + 1] = d.x

        // Zulu hour.
        var hour = m[Atis.clockHours] &+ m[Atis.zuluOffset]
        c += 20                                          // the speed stored, the hour compared with 24
        if hour < 0x18 {
            c += 3
        } else {
            hour &-= 0x18
            c += 6
        }
        charge(c + 6)
        d = atisFormat(lo: hour, hi: 0, byteEntry: true)
        m[Atis.zuluHourDigits] = d.a
        m[Atis.zuluHourDigits + 1] = d.x

        // Ceiling: $0866 (2150) × the cloud base in meters, bits 16-31 = hundreds of feet.
        m[0xC4] = 0x66
        m[0xC5] = 0x08
        charge(32)
        p = mulU16(a: m[Atis.cloudBase], x: m[Atis.cloudBase + 1])
        m[Atis.ceilingSwitch] = 0
        let ceilingLo = p.x, ceilingHi = m[0xCB]
        c = 11                                           // no ceiling until a nonzero byte shows one
        var hasCeiling = true
        if ceilingHi != 0 {
            c += 3
        } else if ceilingLo != 0 {
            c += 6
        } else {
            c += 8                                       // the branch to $F207 crosses into page $F2
            hasCeiling = false
        }
        if hasCeiling {
            m[Atis.ceilingSwitch] = 0x20
            charge(c + 12)                               // the ceiling phrase switched on
            d = atisFormat(lo: ceilingLo, hi: ceilingHi, byteEntry: false)
            c = 2                                        // a leading zero?
            var y = d.y, a = d.a
            if y != 0x30 {
                c += 3
            } else {
                y = 0x20
                c += 6                                   // blanked; then the tens
                if a != 0x30 {
                    c += 3
                } else {
                    a = 0x20
                    c += 4
                }
            }
            m[Atis.ceilingDigits] = y
            m[Atis.ceilingDigits + 1] = a
            m[Atis.ceilingDigits + 2] = d.x
            c += 12
        }

        // Runway by wind quadrant: $0939[$09A3 >> 6].
        let quadrant = m[Atis.windDirection + 1] >> 6
        charge(c + 28)                                   // the quadrant's runway to the formatter
        d = atisFormat(lo: m[Atis.parameters + Int(quadrant)], hi: 0, byteEntry: true)
        m[Atis.runwayDigits] = d.a
        m[Atis.runwayDigits + 1] = d.x
        charge(14)
    }

    /// $F221 (`byteEntry`: the high byte cleared first) / $F223: formats the value `hi:lo` as
    /// three digits at $F21E through `format3Digits` and returns them as the original does:
    /// Y = hundreds, A = tens, X = units. Charges through its return.
    private func atisFormat(lo: UInt8, hi: UInt8, byteEntry: Bool) -> (y: UInt8, a: UInt8, x: UInt8) {
        let m = mem
        m[0xB8] = lo
        m[0xB9] = hi
        charge((byteEntry ? 2 : 0) + 16)                 // the value into `$B8/$B9`, the field address
        format3Digits(field: Atis.digitField)
        let f = Int(Atis.digitField)
        charge(18)                                       // the three digits into Y, A and X
        return (m[f], m[f + 1], m[f + 2])
    }

    // MARK: atisTeletype ($E713 / $F239)

    /// $E713 (flip passes): a jump to $F239.
    public func atisTeletypeJump() {
        charge(3)
        atisTeletype()
    }

    /// $F239: types the ATIS broadcast once per tune. When `atisOneShot` is clear: set it, clear
    /// the window, type the text at `atisTextPtr` from (x 3, row 3) with the 3x5 font, then wait
    /// `busyDelay` with Y = 4 (1,826,849 cycles, about 1.8 s).
    ///
    /// Each visible character is the one-character record at $BA-$BD (row, x, character, 0)
    /// drawn by `drawTextRecord`, followed by a busy-wait of (256 - `commRate`) mod 256 passes (0
    /// means 256) of 606 cycles, then x += 4. A space only advances the cell, which is where lines
    /// and pages break. Tokens $80-$8C expand to phrases (see `Atis`). Leaves `$B8/$B9` past the
    /// text, `$BA-$BD` as the last cell and `$C0-$C3` as `drawTextRecord` leaves them. Clobbers
    /// A, X, Y.
    public func atisTeletype() {
        let m = mem
        guard m[Atis.oneShot] == 0 else {
            charge(13)                                   // already typed for this tune
            return
        }
        m[Atis.oneShot] = 1                              // incremented from 0
        m[Atis.cellTerminator] = 0                       // A is still 0 here
        m[Atis.cellRow] = 3
        m[Atis.cellX] = 3
        charge(29)                                       // the first cell at (3, 3), then the window clear
        clearWindow()
        m[Atis.textCursor] = m[Atis.textPointer]
        m[Atis.textCursor + 1] = m[Atis.textPointer + 1]
        charge(20)                                       // the cursor at the record text
        atisTypeText()
        charge(2)                                        // Y = 4, then falls into $F25B
        busyDelay(y: 4)
    }

    /// $F26B (`entry` nil) / $F275 (`entry` = A): types characters from the cursor `$B8/$B9`
    /// until a 0, which returns (at $F278). The token path calls the $F275 entry with A = ' '
    /// for the phrase, so a phrase starts with a space cell; tokens nest the same way. The rare
    /// zero results of the cell advance (x wrapping to 0) take the original's fall-through paths.
    /// Charges through its return.
    private func atisTypeText(entry: UInt8? = nil) {
        let m = mem
        enum Label { case fetch, test, dispatch, character, space }
        var label: Label = entry == nil ? .fetch : .test
        var a = entry ?? 0
        var c = 0
        while true {
            switch label {
            case .fetch:                                 // $F26B: fetch a byte, advance the cursor
                a = m[zpPointer(Atis.textCursor)]
                m[Atis.textCursor] &+= 1
                c += 12
                if m[Atis.textCursor] != 0 {
                    c += 3
                } else {
                    m[Atis.textCursor + 1] &+= 1
                    c += 7
                }
                label = .test
            case .test:                                  // $F275: 0 ends the text; $F279: bit 7 is a token
                c += 2
                if a == 0 {
                    charge(c + 8)
                    return
                }
                c += 3
                if a & 0x80 == 0 {
                    c += 3
                    label = .character
                    continue
                }
                // $F27B: a token. Save the cursor, point it at the phrase, type ' ' + phrase, then
                // one more space cell, and restore the cursor.
                let lo = m[Atis.textCursor], hi = m[Atis.textCursor + 1]
                let offset = m[(Atis.tokenOffsetBase + Int(a)) & 0xFFFF]
                let sum = Int(offset) + 0x87
                m[Atis.textCursor] = UInt8(sum & 0xFF)
                m[Atis.textCursor + 1] = sum > 0xFF ? 0xF1 : 0xF0
                // The cursor pushed, the phrase looked up, then the nested call with A = ' '.
                c += 18 + Machine.pageCrossing(Atis.tokenOffsetBase, a)
                    + 22
                charge(c)
                c = 0
                atisTypeText(entry: 0x20)
                charge(6)                                // the closing space cell
                _ = atisNextCell()
                m[Atis.textCursor] = lo
                m[Atis.textCursor + 1] = hi
                a = hi
                c += 14                                  // the cursor popped
                label = .dispatch
            case .dispatch:                              // $F29D: a nonzero A fetches the next byte
                if a != 0 {
                    c += 3
                    label = .fetch
                } else {
                    c += 2
                    label = .character
                }
            case .character:                             // $F29F: a space only advances the cell
                c += 2
                if a == 0x20 {
                    c += 3
                    label = .space
                    continue
                }
                c += 2
                m[Atis.cellCharacter] = a
                charge(c + 13)                           // draw the one-character record at $BA
                c = 0
                drawTextRecord(Atis.cellRecord)
                // The per-character delay: (256 - rate) mod 256 passes of an inner count of $78,
                // 606 cycles each, the last one 605.
                charge(10)
                let x = 0 &- m[Atis.commRate]
                let passes = x == 0 ? 256 : Int(x)
                for i in 0..<passes { charge(i < passes - 1 ? 606 : 605) }
                charge(6)
                a = atisAdvanceColumn()
                if a != 0 {
                    c += 3                               // back to $F29D
                    label = .dispatch
                } else {
                    c += 2
                    label = .space
                }
            case .space:                                 // $F2C0: the next cell, then back to $F29D
                charge(c + 6)
                c = 0
                a = atisNextCell()
                if a != 0 {
                    c += 3
                    label = .dispatch
                } else {
                    // Zero: falls into $F2C5, whose return ends this level.
                    charge(2)
                    _ = atisNextCell()
                    return
                }
            }
        }
    }

    /// $F2C5: the next cell. x < $64: x += 4 ($F2DE). Otherwise a new line: row += 8 (the carry of
    /// the compare is added), or a new page (`clearWindow`, row 3) when that is at least $5A; x = 3.
    /// Returns the new x (A; the Z flag the callers branch on). Charges through its return.
    private func atisNextCell() -> UInt8 {
        let m = mem
        let x = m[Atis.cellX]
        if x < Atis.lineEnd {
            charge(8)                                    // room left on the line
            return atisAdvanceColumn()
        }
        var c = 14                                       // a new line: row + 7 plus the compare's carry
        var row = m[Atis.cellRow] &+ 8
        if row < Atis.pageEnd {
            c += 3
        } else {
            charge(c + 8)                                // a new page
            c = 0
            clearWindow()
            row = 3
            c += 2
        }
        m[Atis.cellRow] = row
        m[Atis.cellX] = 3
        charge(c + 17)                                   // the row stored, x = 3
        return 3
    }

    /// $F2DE: x += 4. Returns the new x. Charges through its return.
    private func atisAdvanceColumn() -> UInt8 {
        let x = mem[Atis.cellX] &+ 4
        mem[Atis.cellX] = x
        charge(16)
        return x
    }
}
