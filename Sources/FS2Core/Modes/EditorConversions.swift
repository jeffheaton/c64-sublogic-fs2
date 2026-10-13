/// The editor's conversions between the simulator's state and the mode record's display values:
/// `stateToRecord` ($B3F6, on entry), `recordToState` ($B559, the exit) and `windToDisplay`
/// ($B865, both directions). All integer, through the unsigned multiply $188A (`mulU16`).
///
/// | Field | State → record ($B3F6) | Record → state ($B559) |
/// |---|---|---|
/// | NORTH / EAST | `slewAux`: position bytes 2-3, high + $40 | bytes 2-3 = field, high − $40; bytes 0-1 = 0 |
/// | ALTITUDE | ((alt m + field elevation) · $D1EB) >> 14 − 9 ft | `setAltitudeFromEditor` ($F9C1) |
/// | PITCH / BANK / HEADING | raw · 360 >> 16 (heading less `$0846` and `$0848`, stored back) | deg · $B60C >> 8 (heading plus both offsets) |
/// | AIRSPEED | raw · $0200 >> 16 | knots · $7FFF >> 8 |
/// | THROTTLE / FLAPS | copied | copied |
/// | RUDDER / AILERONS / ELEVATORS | raw + $7FFF | field − $7FFF |
/// | Shear 1-3 ($098E-$0993) | m · $0348 >> 8 = ft | ft · $4E >> 8 = m |
/// | Winds ($0994-$09A3) | knots + 100 · turbulence; deg = angle · 360 >> 16 | split at 100; angle = deg · $B60C >> 8 |
/// | $085C-$0869 (7 words) | m · $0348 >> 8 | ft · $4E0C >> 16 |
/// | Clouds ($0986-$098D) | (feet in both) | `$0856-$085D` = ft · $4E >> 8 (meters) |
extension Machine {
    // MARK: stateToRecord ($B3F6)

    /// $B3F6: the simulator state into the record (see the table above). `$0ACD/$0ACE` are kept
    /// in `$08B5/$08B6` unless the demo runs (`$095A`). Leaves `heading` $0A13 less the two
    /// heading offsets (the exit adds them back), and the shears and the words at $085C in feet.
    public func stateToRecord() {
        let m = mem
        let R = Editor.Record.self, S = Editor.State.self
        charge(9)                                       // through the $200C vector
        slewAux()
        var carry = false
        m[0xC4] = FlightModel.adc(m[S.altitude + 1], m[S.fieldElevation], &carry)
        m[0xC5] = FlightModel.adc(m[S.altitude + 2], m[S.fieldElevation + 1], &carry)
        charge(32)       // altitude + field elevation, then × $D1EB
        var a = mulU16(a: 0xEB, x: 0xD1).a
        for _ in 0..<2 {
            // One left shift of the product through $CA/$CB.
            var c = a & 0x80 != 0
            a <<= 1
            let ca = m[0xCA]
            m[0xCA] = ca << 1 | (c ? 1 : 0)
            c = ca & 0x80 != 0
            m[0xCB] = m[0xCB] << 1 | (c ? 1 : 0)
        }
        carry = true
        m[R.altitude] = FlightModel.sbc(m[0xCA], 0x09, &carry)
        m[R.altitude + 1] = FlightModel.sbc(m[0xCB], 0x00, &carry)
        // The two shifts, then 9 ft less.
        var c = 2 * 12 + 20
        for offset in [S.headingOffsetB, S.headingOffsetA] {
            carry = true
            m[S.heading] = FlightModel.sbc(m[S.heading], m[offset], &carry)
            m[S.heading + 1] = FlightModel.sbc(m[S.heading + 1], m[offset + 1], &carry)
            c += 26                  // one heading offset taken out
        }
        // Heading, bank, pitch: × 360, the degrees from bits 16-31.
        for (source, target) in [(S.heading, R.heading), (S.bankAngle, R.bank),
                                 (S.flightPathAngle, R.pitch)] {
            m[0xC4] = m[source]
            m[0xC5] = m[source + 1]
            charge(c + 24)           // the raw angle × 360
            let p = mulU16(a: 0x68, x: 0x01)
            m[target] = p.x
            m[target + 1] = m[0xCB]
            c = 11                                   // bits 16-31
        }
        m[0xC4] = m[S.airspeed]
        m[0xC5] = m[S.airspeed + 1]
        charge(c + 24)
        let speed = mulU16(a: 0x00, x: 0x02)
        m[R.airspeed] = speed.x
        m[R.airspeed + 1] = m[0xCB]
        c = 11
        m[R.throttle] = m[S.throttle]
        m[R.throttle + 1] = m[S.throttle + 1]
        m[R.flaps] = m[S.flaps]
        m[R.flaps + 1] = m[S.flaps + 1]
        c += 2 * 16                            // throttle and flaps copied
        for (source, target) in [(S.rudder, R.rudder), (S.ailerons, R.ailerons), (S.elevator, R.elevators)] {
            carry = false
            m[target] = FlightModel.adc(m[source], 0xFF, &carry)
            m[target + 1] = FlightModel.adc(m[source + 1], 0x7F, &carry)
            c += 22                  // + $7FFF
        }
        c += 4                                              // the demo?
        if m[S.demoActive] != 0 {
            c += 3
        } else {
            m[S.savedACD] = m[S.acd]
            m[S.savedACD + 1] = m[S.acd + 1]
            c += 18
        }
        charge(c + 8)                                   // the winds to display units
        windToDisplay(toInternal: false)
        // The shears: meters × $0348 >> 8 = feet.
        c = 0
        for shear in [R.shear1, R.shear2, R.shear3] {
            m[0xC4] = m[shear]
            m[0xC5] = m[shear + 1]
            charge(c + 24)
            let p = mulU16(a: 0x48, x: 0x03)
            m[shear] = p.a
            m[shear + 1] = p.x
            c = 8                                       // stored
        }
        charge(c + 6)
    }

    // MARK: recordToState ($B559)

    /// $B559 (the editor's exit): Europe 1917 (`$0969`) forces mode 7 (`$09A5` = `$0963` =
    /// `$0E7C` = 7, `loadModeRecord`), then the bitmap display comes back (`$2042`), the clock
    /// is redrawn, and the record goes into the state (see the table above). In reality mode
    /// with the throttle's low byte 0 the magnetos are set OFF (`$2009` with A = 0 and the
    /// label X = the FLAPS high byte, as the original leaves X). Then `$095A` = `$095B`,
    /// `$095B` = 0, the war counters are reset (ammo 100, bombs '5', the rest 0), the aircraft
    /// is serviced (`$200F`), the reposition counter `$0A83` = 20, the cloud altitudes in meters
    /// go to `$0856-$085D`, the four control indicators are redrawn ($2024-$202D), the requests
    /// `$08BA`/`$08BB` are cleared, `$0886` = USER MODE, the ATIS temperature offset `$095F` =
    /// (`$22` & $1F) − 16, SOUND (`$0964`) is copied to `$08D3`, `$0E86` = `$08BC` − 2 unless that
    /// is 0, and the flaps are applied (`$2045` with A = `$0AB0`).
    public func recordToState() {
        let m = mem
        let R = Editor.Record.self, S = Editor.State.self
        var c = 4                                           // Europe 1917?
        if m[R.europe1917] != 0 {
            m[Editor.RAM.userModeEntry] = 7
            m[ModeLibrary.currentMode] = 7
            m[S.warModeLatch] = 7
            charge(c + 22)               // mode 7 forced and loaded
            loadModeRecord()
            c = 0
        } else {
            c += 3
        }
        charge(c + 9)                                   // through the $2042 vector
        displayInit()
        charge(9)                                       // through the $2000 vector
        drawClock()
        m[S.northPosition + 2] = m[R.north]
        m[S.northPosition + 3] = m[R.north + 1] &- 0x40
        m[S.eastPosition + 2] = m[R.east]
        m[S.eastPosition + 3] = m[R.east + 1] &- 0x40
        m[S.northPosition] = m[Editor.Table.powersOfTen + 18]
        m[S.northPosition + 1] = m[Editor.Table.powersOfTen + 19]
        m[S.eastPosition] = m[Editor.Table.powersOfTen + 20]
        m[S.eastPosition + 1] = m[Editor.Table.powersOfTen + 21]
        // North and east (their high bytes less $40), their low words from the bytes after the
        // powers of ten, then the altitude through the $2006 vector.
        charge(2 * 18 + 2 * 14 + 9)
        setAltitudeFromEditor()
        // The heading, bank and pitch: degrees × $B60C >> 8.
        m[0xC4] = m[R.heading]
        m[0xC5] = m[R.heading + 1]
        charge(24)
        var p = mulU16(a: 0x0C, x: 0xB6)
        m[S.heading] = p.a
        m[S.heading + 1] = p.x
        c = 8
        for offset in [S.headingOffsetB, S.headingOffsetA] {
            var carry = false
            m[S.heading] = FlightModel.adc(m[S.heading], m[offset], &carry)
            m[S.heading + 1] = FlightModel.adc(m[S.heading + 1], m[offset + 1], &carry)
            c += 26                  // one heading offset added back
        }
        for (source, target) in [(R.bank, S.bankAngle), (R.pitch, S.flightPathAngle)] {
            m[0xC4] = m[source]
            m[0xC5] = m[source + 1]
            charge(c + 24)
            p = mulU16(a: 0x0C, x: 0xB6)
            m[target] = p.a
            m[target + 1] = p.x
            c = 8
        }
        m[0xC4] = m[R.airspeed]
        m[0xC5] = m[R.airspeed + 1]
        charge(c + 24)
        p = mulU16(a: 0xFF, x: 0x7F)
        m[S.airspeed] = p.a
        m[S.airspeed + 1] = p.x
        c = 8
        m[S.throttle] = m[R.throttle]
        m[S.throttle + 1] = m[R.throttle + 1]
        m[S.flaps] = m[R.flaps]
        m[S.flaps + 1] = m[R.flaps + 1]
        let labelX = m[R.flaps + 1]                  // X as the original leaves it ($B634)
        c += 2 * 16
        for (source, target) in [(R.rudder, S.rudder), (R.ailerons, S.ailerons), (R.elevators, S.elevator)] {
            var carry = true
            m[target] = FlightModel.sbc(m[source], 0xFF, &carry)
            m[target + 1] = FlightModel.sbc(m[source + 1], 0x7F, &carry)
            c += 22                  // − $7FFF
        }
        c += editorExitHook()                               // the hook at $0ACF
        c += 4                                              // reality mode?
        if m[R.reality] == 0 {
            c += 3
        } else {
            c += 6                                      // the throttle's low byte
            if m[S.throttle] != 0 {
                c += 3
            } else {
                c += 2
                c += editorExitHook()
                charge(c + 11)                       // magnetos off, through the $2009 vector
                setMagnetos(0, label: labelX)
                c = 0
            }
        }
        m[S.demoActive] = m[S.demoRequest]
        m[S.demoRequest] = 0
        c += 14                                  // the demo request taken over and cleared
        // The shears: feet × $4E >> 8 = meters.
        for shear in [R.shear1, R.shear2, R.shear3] {
            m[0xC4] = m[shear]
            m[0xC5] = m[shear + 1]
            charge(c + 24)
            p = mulU16(a: 0x4E, x: 0x00)
            m[shear] = p.a
            m[shear + 1] = p.x
            c = 8
        }
        charge(c + 8)                                   // the winds to internal units
        windToDisplay(toInternal: true)
        m[S.ammo] = 0x64
        m[S.bombCount] = 0x35
        for a in [S.warDeclared, S.warFlag08D6, S.killCount, S.damageLevel, S.warFlag0AA7, S.warScore, S.warScore + 1] { m[a] = 0 }
        // The war counters reset, then the service through the $200F vector.
        charge(2 + 4 + 2 + 4 + 2 + 7 * 4 + 6 + 3)
        serviceAircraft()
        m[S.temperatureOffset] = (m[S.exitHook] & 0x1F) &- 0x10
        m[S.repositionCounter] = 0x14
        // The temperature offset from the hook byte; the reposition counter.
        c = 20
        // The cloud altitudes: feet × $4E >> 8 = meters, into $0856-$085D.
        for (source, target) in [(R.cloud1Bottoms, S.cloudMeters), (R.cloud1Tops, S.cloudMeters + 2), (R.cloud2Bottoms, S.cloudMeters + 4), (R.cloud2Tops, S.cloudMeters + 6)] {
            m[0xC4] = m[source]
            m[0xC5] = m[source + 1]
            charge(c + 24)
            p = mulU16(a: 0x4E, x: 0x00)
            m[target] = p.a
            m[target + 1] = p.x
            c = 8
        }
        charge(c + 9)                                   // the four indicators, each through its vector
        updateElevatorIndicator()
        charge(9)
        _ = updateThrottleIndicator()
        charge(9)
        updateRudderIndicator()
        charge(9)
        updateAileronIndicator()
        m[Input.RAM.editorRequest] = 0
        m[Input.RAM.modeRequest] = 0
        m[S.lastUserMode] = m[Editor.RAM.userModeEntry]
        m[S.temperatureOffset] = (m[S.mainLoopCounter] & 0x1F) &- 0x10
        m[Input.RAM.soundEnable] = m[ModeLibrary.record]
        // The requests cleared, the last user mode, the temperature offset again (now from the
        // pass counter), SOUND; then the cache state less 2.
        c = 47
        let x = m[Machine.editorCacheState] &- 2
        if x == 0 {
            c += 3
        } else {
            m[S.plotRecorded] = x
            c += 6
        }
        charge(c + 13)                               // the flaps, through the $2045 vector
        updateFlaps(m[S.flaps + 1])
        charge(6)
    }

    /// The call to $0ACF: the last byte of the flight variables is a return instruction ($60),
    /// which the exit calls as a hook (and reads as data for `$095F`). Returns the cycles of the
    /// call and the return.
    private func editorExitHook() -> Int {
        precondition(mem[Editor.State.exitHook] == 0x60, "the editor exit hook $0ACF is not an RTS")
        return 12
    }

    // MARK: windToDisplay ($B865)

    /// $B865 (Y = 0 display, 1 internal): converts the four wind records $0994/$0998/$099C/$09A0
    /// (`windRecord`, $B901) and the seven words $085C-$0869, through the pointer `$A2/$A3`, the
    /// count `$BA` and the factor `$BC/$BD` = $4E0C; `$9E` keeps Y.
    public func windToDisplay(toInternal: Bool) {
        let m = mem
        let y: UInt8 = toInternal ? 1 : 0
        var c = 0
        for record in Editor.Record.winds {
            m[0xA2] = UInt8(record & 0xFF)
            m[0xA3] = UInt8(record >> 8)
            charge(c + 16)                   // the record's address, then the call
            windRecord(y)
            c = 0
        }
        m[0xBA] = 7
        m[0xA2] = 0x5C
        m[0xA3] = 0x08
        m[0xBC] = 0x0C
        m[0xBD] = 0x4E
        c = 5 * 5                                     // the count, the pointer, the factor
        repeat {
            c += 2                                          // which direction?
            m[0x9E] = y
            let w = zpPointer(0xA2)
            if y != 1 {
                // Meters to feet: × $0348, bits 8-23.
                m[0xC4] = m[w]
                m[0xC5] = m[(w + 1) & 0xFFFF]
                charge(c + 12 + Editor.crossing(w, 0) + 10 + Editor.crossing(w, 1) + 13)
                let p = mulU16(a: 0x48, x: 0x03)
                let w2 = zpPointer(0xA2)
                m[w2] = p.a
                m[(w2 + 1) & 0xFFFF] = p.x
                c = 21                   // the product stored
            } else {
                // Feet to meters: $4E0C × the word, bits 16-31.
                m[0xC4] = m[0xBC]
                m[0xC5] = m[0xBD]
                let hi = m[(w + 1) & 0xFFFF], lo = m[w]
                // The factor and the word into the multiply.
                charge(c + 25 + Editor.crossing(w, 1) + 15)
                _ = mulU16(a: lo, x: hi)
                let w2 = zpPointer(0xA2)
                m[w2] = m[0xCA]
                m[(w2 + 1) & 0xFFFF] = m[0xCB]
                c = 22                   // bits 16-31 stored
            }
            // $B8E8: Y back from $9E, the pointer + 2, the count − 1.
            var carry = false
            m[0xA2] = FlightModel.adc(m[0xA2], 2, &carry)
            m[0xA3] = FlightModel.adc(m[0xA3], 0, &carry)
            carry = true
            m[0xBA] = FlightModel.sbc(m[0xBA], 1, &carry)
            c += 31
            if m[0xBA] != 0 { c += 4 } else { c += 2; break }   // the loop branch crosses a page
        } while true
        charge(c + 6)
    }

    /// $B901: one wind record at `$A2/$A3`: [0-1] knots field, [2-3] direction. Its bytes go to
    /// `$BC`, `$BD`, `$BA`, `$BB` first. Y = 0: direction · 360 >> 16 = degrees, knots field =
    /// low + 100 · high; Y = 1: degrees · $B60C >> 8 = the binary angle, and the knots field
    /// split by repeated subtraction of 100 into the knots (low) and the turbulence (high).
    private func windRecord(_ y: UInt8) {
        let m = mem
        m[0x9E] = y
        var w = zpPointer(0xA2)
        m[0xBC] = m[w]
        m[0xBD] = m[(w + 1) & 0xFFFF]
        m[0xBA] = m[(w + 2) & 0xFFFF]
        m[0xBB] = m[(w + 3) & 0xFFFF]
        // Y saved, the record's four bytes copied out, Y back.
        var c = 3 + 2 + 4 * 8 + 3 * 2 + 3
        for k in 0..<4 { c += Editor.crossing(w, k) }
        var hi: UInt8, lo: UInt8
        if y == 0 {
            c += 3
            m[0xC4] = 0x68
            m[0xC5] = 0x01
            charge(c + 22)           // the direction × 360
            _ = mulU16(a: m[0xBA], x: m[0xBB])
            w = zpPointer(0xA2)
            m[(w + 2) & 0xFFFF] = m[0xCA]
            m[(w + 3) & 0xFFFF] = m[0xCB]
            m[0xC4] = 0x64
            m[0xC5] = 0x00
            // The degrees stored; then the turbulence byte × 100.
            charge(43)
            let p = mulU16(a: 0x00, x: m[0xBD])
            var carry = false
            var a = FlightModel.adc(p.a, m[0xBC], &carry)
            var x = p.x
            c = 5                                       // plus the knots
            if carry { x &+= 1; c += 4 } else { c += 3 }   // the carry into the high byte
            m[0xBC] = a
            a = x
            x = m[0xBC]
            hi = a
            lo = x
            c += 11                              // the high byte in A, the low byte in X
        } else {
            c += 5                                      // to the internal units
            m[0xC4] = 0x0C
            m[0xC5] = 0xB6
            charge(c + 22)
            let p = mulU16(a: m[0xBA], x: m[0xBB])
            w = zpPointer(0xA2)
            m[(w + 2) & 0xFFFF] = p.a
            m[(w + 3) & 0xFFFF] = p.x
            // The angle stored; the knots field and the hundreds count set up.
            c = 26
            var a = m[0xBC], x = m[0xBD], count: UInt8 = 0xFF
            repeat {
                count &+= 1
                var carry = false
                a = FlightModel.adc(a, 0x9C, &carry)
                c += 6                              // one more hundred, taken off by adding −100
                if carry { x &+= 1; c += 4 } else { c += 3 }   // the carry into the high byte
                x &-= 1
                c += 2                                      // the subtraction's borrow
                if x & 0x80 == 0 { c += 3 } else { c += 2; break }   // until it turns negative
            } while true
            var carry = false
            a = FlightModel.adc(a, 0x64, &carry)
            lo = a
            hi = count
            c += 8                              // the last hundred added back
        }
        // $B982: [1] = A, [0] = X.
        w = zpPointer(0xA2)
        m[(w + 1) & 0xFFFF] = hi
        m[w] = lo
        charge(c + 27)               // both bytes stored; Y back
    }
}
