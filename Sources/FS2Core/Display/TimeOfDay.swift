/// Time of day ($EBA5-$EC98): the day/dusk/night state from the clock and season, the window
/// palette it selects (screen-RAM colors of the window and the window border the raster IRQ
/// shows), and the instrument lighting masks of the lights switch.
///
/// The palette is plain memory: the window's 2-bit pixels take their colors from screen RAM
/// $7C00-$7E2F (pen 1 = high nibble, pen 2 = low nibble) and the border from `$22B5`, the immediate
/// operand of the IRQ's border load at $22B4 (written here, read by the raster split). Nothing
/// touches I/O. Literal translation with exact cycles (see `Panel/Readouts.swift`).
public enum TimeOfDay {
    /// $083C: 1 day, 2 dusk, 4 night (bit 0 clear also enables op 1C's dotted lines).
    public static let timeOfDay = 0x083C
    /// $0985: season (mode record +21; & 3 indexes the thresholds).
    public static let season = 0x0985
    /// $EBD2: thresholds, 4 seasons × 4 × (minute, hour).
    public static let thresholds = 0xEBD2
    /// $0E61-$0E66: (window screen byte, border color) for day, dusk and night, set by the
    /// display prompt (color or black and white).
    public static let windowPalette = 0x0E61
    /// $22B5: the window border color, the operand the raster IRQ stores to $D020 at line $20.
    public static let windowBorder = 0x22B5
    /// $7C00-$7E2F: the screen RAM of window rows 0-13.
    public static let windowScreen = 0x7C00
    public static let windowScreenEnd = 0x7E2F
    /// $0884: 1 << (season - 1) (0 for seasons 0 and 9+), read by the scenery bytecode.
    public static let seasonBit = 0x0884
    /// $08DC-$08DE: the lighting masks with the lights on (or by day).
    public static let lightsColorSet = 0x08DC
}

extension Machine {
    // MARK: selectTimeOfDay ($EBF2)

    /// $EBF2 (phase 0, and the display prompt): compares the clock (`$0983` hours, `$0984`
    /// minutes) with the four thresholds of the season (`$0985` & 3): before T1 night (4), before
    /// T2 dusk (2), before T3 day (1), before T4 dusk, else night. Each compare is minute - T.min
    /// (only for the borrow) then hour - T.hour - borrow, negative meaning "before"; the minute
    /// is always read from the season-0 row (`$EBD2 + 2k`, a quirk; all minutes are :00 or :30).
    /// Then `applyPalette`. Clobbers A, X.
    public func selectTimeOfDay() {
        let m = mem
        let x = (m[TimeOfDay.season] & 3) << 3
        var c = 14                       // the season row offset
        func before(_ k: Int) -> Bool {
            let (_, borrow) = m[Readouts.clockMinutes].subtractingReportingOverflow(m[TimeOfDay.thresholds + 2 * k])
            let threshold = TimeOfDay.thresholds + 1 + 2 * k
            let hour = m[Readouts.clockHours] &- m[threshold + Int(x)] &- (borrow ? 1 : 0)
            // The minute borrow, then the hour difference (indexed by the season: a page crossing
            // costs one more).
            c += 18 + Machine.pageCrossing(threshold, x)
            return hour & 0x80 != 0
        }
        // Before T1 → $EC37 (night), T2 → $EC3B (dusk), T3 → $EC3F (day), T4 → $EC3B; after all
        // four the code falls into $EC37.
        let outcomes: [UInt8] = [4, 2, 1, 2]
        var state: UInt8 = 4
        for k in 0..<4 {
            if before(k) { c += 3; state = outcomes[k]; break }   // before it
            c += 2
        }
        c += state == 1 ? 2 : 5                         // the state, on to $EC41
        charge(c)
        applyPalette(state)
    }

    /// $EC41: stores the state A in `$083C`; when it changed, the border `$22B5` and the window
    /// screen byte come from the palette pair of the state (1 → `$0E61/$0E62`, 2 → `$0E63/$0E64`,
    /// anything else → `$0E65/$0E66`) and `fillWindowColors` paints it. Always: `$0884` =
    /// 1 << (season - 1) by a loop of `$0985` iterations (256 for season 0, which leaves 0).
    /// Clobbers A, X, Y.
    public func applyPalette(_ state: UInt8) {
        let m = mem
        var c = 8                                       // `$083C` compared and stored
        let changed = state != m[TimeOfDay.timeOfDay]
        m[TimeOfDay.timeOfDay] = state
        if !changed {
            c += 3
        } else {
            c += 4                                      // changed: which state?
            let pair: Int
            if state == 1 {
                c += 11; pair = 0                    // day: the first pair
            } else if state == 2 {
                c += 18; pair = 2        // dusk: the second pair
            } else {
                c += 17; pair = 4
            }
            let byte = m[TimeOfDay.windowPalette + pair]
            m[TimeOfDay.windowBorder] = m[TimeOfDay.windowPalette + pair + 1]
            charge(c + 10)                               // the border, the call of $EC7C
            fillWindowColors(byte)
            c = 0
        }
        // $EC6F: a bit shifted left once per season step, stored into `$0884` on each pass.
        var n = m[TimeOfDay.season]
        var a: UInt8 = 1
        c += 6
        repeat {
            m[TimeOfDay.seasonBit] = a
            a <<= 1
            n &-= 1
            c += 8 + (n != 0 ? 3 : 2)
        } while n != 0
        charge(c + 6)
    }

    /// $EC7C: fills the window screen RAM $7C00-$7E2F with A (from the top down, through the
    /// pointer `$A5/$A6`, which ends at $7BFF). 7884 cycles.
    public func fillWindowColors(_ byte: UInt8) {
        let m = mem
        (m + TimeOfDay.windowScreen).update(repeating: byte, count: TimeOfDay.windowScreenEnd - TimeOfDay.windowScreen + 1)
        m[0xA5] = 0xFF
        m[0xA6] = 0x7B
        // The pointer setup (12); inner loops of 47, 255 and 255 stores (14 per store, -1 per
        // loop); per page the store at offset 0, the pointer step and the end test (24, 23 for the
        // last); the return.
        charge(12 + (14 * 47 - 1) + 24 + (14 * 255 - 1) + 24 + (14 * 255 - 1) + 29)
    }

    // MARK: updateLightingMasks ($EBA5)

    /// $EBA5 (draw sequence): the third factor of the instrument masks. By day (`$083C` bit 0)
    /// and at dusk or night with the lights on (`$0AB5`), `$0945-$0947` = `$08DC-$08DE`; at dusk
    /// or night with the lights off, $10 / $80 / $01 (only the radios, the CH label and `$FD`
    /// bit 4 stay lit). Clobbers A, X.
    public func updateLightingMasks() {
        let m = mem
        var c = 6                                       // the day bit
        if m[TimeOfDay.timeOfDay] & 1 != 0 {
            c += 3
        } else {
            m[Instruments.lightingMasks] = 0x10
            m[Instruments.lightingMasks + 1] = 0x80
            m[Instruments.lightingMasks + 2] = 0x01
            c += 24               // the lights-off masks, then the lights switch
            guard m[Readouts.lights] != 0 else { charge(c + 9); return }
            c += 2
        }
        let lo = m[TimeOfDay.lightsColorSet], mid = m[TimeOfDay.lightsColorSet + 1]
        m[Instruments.lightingMasks] = lo
        m[Instruments.lightingMasks + 1] = mid
        m[Instruments.lightingMasks + 2] = m[TimeOfDay.lightsColorSet + 2]
        charge(c + 30)
    }
}
