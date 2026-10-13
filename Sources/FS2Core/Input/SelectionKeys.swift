/// The selected item `$FC` and the keys that use it ($2807-$2AD4, $2ADF-$2B27, $2B8C-$2BC8,
/// $2C55-$2C86): the RETURN magneto/mixture prefix and the digits 1-5, the radio selects
/// (COM, NAV, OBS, transponder, ADF, fuel tank), radar and the view prefix, and the ',' / '.'
/// adjustments with their wrap rules.
///
/// `$FC` values: 1 view prefix, 2 radar zoom, 3 magnetos/mixture, 4/5 COM MHz/kHz, 6/7 NAV
/// MHz/kHz, 8-$0B transponder digits, $0C OBS, $0D-$0F ADF digits, $10 fuel tank. The
/// quick-repeat window `$091C` (set to 3 by `storeSelected` and the elevator keys, decremented
/// at 5 Hz, cleared by ',' and '.') lets a repeated select key step to the next sub-field.
extension Machine {
    // MARK: Digits 1-3 and the magnetos ($2807-$2864)

    /// $2807 ('1'): with `$FC` = 3 the magnetos OFF (code 0, label 0); with `$FC` 6/7 NAV1
    /// (`$0AB7` = 1); with `$FC` $0C OBS1 (`$0ACB` = 1). Clobbers A, X, Y.
    public func key1() { digitKey(1, magnetoCode: 0, label: 0) }

    /// $283D ('2'): as '1' with magnetos R (code 1, label 2), NAV2 and OBS2. Clobbers A, X, Y.
    public func key2() { digitKey(2, magnetoCode: 1, label: 2) }

    /// The common shape of $2807 and $283D (the same tests in the same order, the same cycles).
    private func digitKey(_ x: UInt8, magnetoCode: UInt8, label: UInt8) {
        let m = mem
        let R = Input.RAM.self
        let fc = m[R.selectedItem]
        var c = 7                                           // the RETURN prefix test
        guard fc != 3 else {
            charge(c + 9)                                   // the magnetos
            setMagnetos(magnetoCode, label: label)
            return
        }
        c += 5
        if fc != 6 {
            c += 4
            if fc != 7 {
                c += 5
                if fc == 0x0C { m[R.obsSelect] = x; c += 6 } else { c += 3 }
                charge(c + 6)
                return
            }
            c += 2
        } else {
            c += 3
        }
        m[R.navSelect] = x
        charge(c + 10)                                      // NAV1 or NAV2
    }

    /// $285F ('3'): magnetos L (code 1, label 1) unconditionally, even without the RETURN prefix
    /// (R and L set the same switch bits; only the label differs). Clobbers A, X, Y.
    public func key3() {
        charge(7)
        setMagnetos(1, label: 1)
    }

    /// $2829 (vector $2009): `$FC` = 0, the magneto switch `$EE15` = code >> 1 and `$EE14` =
    /// code & 1, then `setMagnetoLabel`. Codes: 0 OFF, 1 R or L, 3 BOTH and START (labels 0 OFF,
    /// 1 L, 2 R, 3 BOTH, 4 START). Clobbers A, X, Y.
    public func setMagnetos(_ code: UInt8, label: UInt8) {
        let m = mem
        let R = Input.RAM.self
        m[R.selectedItem] = 0
        m[R.magnetoState + 1] = code >> 1
        m[R.magnetoState] = code & 1
        charge(19)                                          // clear the prefix, split the code
        setMagnetoLabel(label)
    }

    /// $2837 (also called from the engine's starter at $EECE with X = 3): `$0AB6` = X, then the
    /// labels ($3A71, `drawMagnetoLabel`). Clobbers A, X, Y.
    public func setMagnetoLabel(_ label: UInt8) {
        mem[Input.RAM.magnetoLabel] = label
        charge(7)
        drawMagnetoLabel()
    }

    // MARK: RETURN, radar and the view prefix

    /// $2BC4 (RETURN): `$FC` = 3, the magneto/mixture prefix.
    public func keyReturn() {
        mem[Input.RAM.selectedItem] = 3
        charge(11)
    }

    /// $2C5A ('4'): with `$FC` = 3 the magnetos BOTH (code 3, label 3); otherwise `$FC` = 2 (the
    /// radar zoom) and the radar view on (`$0836` = 1). Clobbers A, X, Y.
    public func keyRadar() {
        let m = mem
        let R = Input.RAM.self
        guard m[R.selectedItem] != 3 else {
            charge(14)                                      // magnetos BOTH
            setMagnetos(3, label: 3)
            return
        }
        m[R.selectedItem] = 2
        m[R.radarMode] = 1
        charge(25)                                          // radar zoom, radar view on
    }

    /// $2C70 ('5'; joystick port 1 fire): with `$FC` = 3 the magnetos START (code 3, label 4);
    /// in radar the radar view off (`$0836` = 0, `$FC` kept); otherwise `$FC` = 1, the view prefix
    /// that the next T/Y/H/N/B/V/F/R/G key consumes. Clobbers A, X, Y.
    public func keyViewSelect() {
        let m = mem
        let R = Input.RAM.self
        guard m[R.selectedItem] != 3 else {
            charge(14)                                      // magnetos START
            setMagnetos(3, label: 4)
            return
        }
        var c = 14                                          // not the prefix: is radar on?
        if m[R.radarMode] != 0 {
            m[R.radarMode] = 0
            c += 15                                         // radar view off
        } else {
            m[R.selectedItem] = 1
            c += 11                                         // the view prefix
        }
        charge(c)
    }

    // MARK: Radio and fuel selects

    /// $2BBC: `$FC` = A and the quick-repeat window `$091C` = 3.
    public func storeSelected(_ item: UInt8) {
        mem[Input.RAM.selectedItem] = item
        mem[Input.RAM.quickRepeatWindow] = 3
        charge(15)
    }

    /// $2B8C (CTRL-C): COM. Within the window, `$FC` 4 → 5 (kHz; the window is not renewed);
    /// otherwise `$FC` = 4 and the window, and when `$FC` was 5 inside the window, also
    /// increments `$0937` (the COM search request). The routine's first load of A is dead.
    public func keyComSelect() {
        let m = mem
        let R = Input.RAM.self
        var c = 6                                           // the dead load, the window test
        var a: UInt8 = 0
        if m[R.quickRepeatWindow] == 0 { c += 3 } else {
            a = m[R.selectedItem]
            c += 7
            if a == 4 {
                m[R.selectedItem] = 5
                charge(c + 13)                              // MHz → kHz
                return
            }
            c += 3
        }
        c += 2
        if a == 5 { m[R.comSearchRequest] &+= 1; c += 8 } else { c += 3 }
        charge(c + 5)                                       // on to $2BBC with item 4
        storeSelected(4)
    }

    /// $2BAC (CTRL-N): NAV. Within the window `$FC` 6 → 7 (kHz); otherwise `$FC` = 6 and the
    /// window.
    public func keyNavSelect() {
        let m = mem
        let R = Input.RAM.self
        var c = 4
        if m[R.quickRepeatWindow] == 0 { c += 3 } else {
            c += 7
            if m[R.selectedItem] == 6 {
                m[R.selectedItem] = 7
                charge(c + 13)                              // MHz → kHz
                return
            }
            c += 3
        }
        charge(c + 2)                                       // falls into $2BBC with item 6
        storeSelected(6)
    }

    /// $2BA7 (CTRL-V): `$FC` = $0C, OBS (no window).
    public func keyObsSelect() {
        mem[Input.RAM.selectedItem] = 0x0C
        charge(11)
    }

    /// $2C55 (CTRL-F): `$FC` = $10, the fuel tank selector.
    public func keyFuelTankSelect() {
        mem[Input.RAM.selectedItem] = 0x10
        charge(11)
    }

    /// $2B25 (A, CTRL-A, left SHIFT): a jump to $E9A7 (`selectAdfDigit`).
    public func keyAdfSelect() {
        charge(3)
        selectAdfDigit()
    }

    /// $2ADF (CTRL-T): outside slew, `keyTransponderSelect` (a branch that crosses a page). In
    /// slew it copies the view attitude back into the flight state: γ `$09DE/$09DF` = -`$6C/$6D`,
    /// bank `$09E0/$09E1` = -`$6E/$6F` (16-bit negations) and the heading `$0A13/$0A14` = `$70/$71`.
    public func keyCtrlT() {
        let m = mem
        let R = Input.RAM.self
        guard m[R.slewMode] != 0 else {
            charge(8)                                       // not slewing (the branch crosses a page)
            keyTransponderSelect()
            return
        }
        setU16(R.flightPathAngle, 0 &- u16(R.viewPitch))
        setU16(R.bankAngle, 0 &- u16(R.viewBank))
        m[R.heading] = m[R.viewHeading]
        m[R.heading + 1] = m[R.viewHeading + 1]
        // The slew test, two 16-bit negations of 20 cycles each, and the heading copy.
        charge(4 + 2 + 2 * 20 + 20)
    }

    /// $2B0D (CTRL-X; CTRL-T outside slew): the transponder digits. Within the window and with
    /// `$FC` in 8-$0B, the next item (`$FC` + 1, so the fifth quick press reaches $0C, OBS);
    /// otherwise 8. Then `storeSelected`.
    public func keyTransponderSelect() {
        let m = mem
        let R = Input.RAM.self
        var c = 4
        var item: UInt8 = 8
        if m[R.quickRepeatWindow] == 0 { c += 5 } else {
            let fc = m[R.selectedItem]
            c += 7
            if fc < 8 { c += 5 } else {
                c += 4
                if fc >= 0x0C { c += 5 } else { c += 7; item = fc &+ 1 }   // the next digit
            }
        }
        charge(c + 3)                                       // on to $2BBC
        storeSelected(item)
    }

    // MARK: ',' and '.' ($286D, $298E)

    /// $286D (','): first `tuneDecrementPre` ($E9BF: the ADF digit, or the mixture with
    /// `$FC` = 3), then the window `$091C` = 0. In war mode (`$0969`) or with `$FC` = 2 the radar
    /// eye height zooms out: the 24-bit `$0889-$088B` shifts left with a 1 in, bit 23 cleared.
    /// Otherwise by `$FC`: 4 COM MHz down (118 wraps to 135), 5 COM kHz down (.x5 → .x0 → .(x-1)5,
    /// .00 → .95 without a borrow), 6 NAV MHz down (108 → 117), 7 NAV kHz down (as COM), NAV1 or
    /// NAV2 by `$0AB7`; 8-$0B transponder digit `$FC` - 8 down (octal, 0 → 7); $0C OBS1/OBS2
    /// (by `$0ACB`) down one 2° unit (0 → $B3); $10 fuel tank `$09C6` 1 → 0. Each change redraws
    /// its readout. Clobbers A, X, Y.
    public func decrementSelected() {
        let m = mem
        let R = Input.RAM.self
        charge(6)
        let fc = tuneDecrementPre()
        m[R.quickRepeatWindow] = 0
        var c = 10                                          // close the window, test war mode
        if m[R.europe1917] != 0 { c += 3 } else {
            c += 6                                          // is it the radar zoom?
            guard fc == 2 else { charge(c + 3); decrementRadio(fc); return }
            c += 2
        }
        // $287F: zoom out: the 24-bit height shifts left with a 1 in, then bit 23 is cleared.
        let b1 = m[R.radarEyeHeight + 1], b2 = m[R.radarEyeHeight + 2], b3 = m[R.radarEyeHeight + 3]
        m[R.radarEyeHeight + 1] = b1 << 1 | 1
        m[R.radarEyeHeight + 2] = b2 << 1 | b1 >> 7
        m[R.radarEyeHeight + 3] = (b3 << 1 | b2 >> 7) & 0x7F
        charge(c + 40)
    }

    /// $2891-$2962: the ',' adjustments of the items 4-$10 (A = `$FC`).
    private func decrementRadio(_ fc: UInt8) {
        let m = mem
        let R = Input.RAM.self
        var x = fc &- 4
        var c = 6                                           // the item index
        if x == 0 {
            // COM MHz: 118 wraps to 135, otherwise the units step down with a borrow.
            var a = m[R.comDigits], units = m[R.comDigits + 1]
            c += 12
            if a == 0x31 && units == 0x38 {
                c += 13
                a = 0x33
                units = 0x35
            } else {
                c += a != 0x31 ? 3 : 7
                units &-= 1
                c += 4
                if units == 0x2F { c += 8; units = 0x39; a &-= 1 } else { c += 3 }
            }
            m[R.comDigits] = a
            m[R.comDigits + 1] = units
            charge(c + 17)                                  // through the shared store to the COM redraw
            drawComFrequency()
            return
        }
        c += 3
        x &-= 1
        c += 2
        if x == 0 {
            // COM kHz.
            let r = Self.kHzDown(m[R.comDigits + 2], m[R.comDigits + 3])
            m[R.comDigits + 2] = r.a
            m[R.comDigits + 3] = r.x
            charge(c + 16 + r.cycles + 14)
            drawComFrequency()
            return
        }
        c += 3
        x &-= 1
        c += 2
        if x == 0 {
            // NAV MHz, on the receiver `$0AB7` picks.
            c += 8
            let nav2 = m[R.navSelect] == 2
            c += nav2 ? 3 : 2
            let digits = nav2 ? R.nav2Digits : R.nav1Digits
            let r = Self.navMHzDown(m[digits], m[digits + 1])
            m[digits] = r.a
            m[digits + 1] = r.x
            charge(c + 14 + r.cycles + 14)
            if nav2 { drawNav2Frequency() } else { drawNav1Frequency() }
            return
        }
        c += 3
        x &-= 1
        c += 2
        if x == 0 {
            // NAV kHz.
            c += 8
            let nav2 = m[R.navSelect] == 2
            c += nav2 ? 3 : 2
            let digits = (nav2 ? R.nav2Digits : R.nav1Digits) + 2
            let r = Self.kHzDown(m[digits], m[digits + 1])
            m[digits] = r.a
            m[digits + 1] = r.x
            charge(c + 14 + r.cycles + 14)
            if nav2 { drawNav2Frequency() } else { drawNav1Frequency() }
            return
        }
        c += 4                                              // the branch crosses a page ($28EC → $290B)
        x &-= 1
        c += 4
        if x < 4 {
            // Transponder digit X, octal: '0' wraps to '7'.
            var digit = m[R.transponderDigits + Int(x)]
            c += 8
            if digit != 0x30 { c += 3 } else { c += 4; digit = 0x38 }
            m[R.transponderDigits + Int(x)] = digit &- 1
            charge(c + 12)
            drawTransponder()
            return
        }
        c += 3
        x &-= 4
        c += 8
        if x == 0 {
            // OBS1 or OBS2 by `$0ACB`: 0 wraps to $B3.
            c += 8
            let second = m[R.obsSelect] == 2
            c += second ? 3 : 2
            let obs = second ? R.obs2 : R.obs1
            var value = m[obs] &- 1
            m[obs] = value
            c += 12
            if value != 0xFF { c += 3 } else { c += 8; value = 0xB3; m[obs] = value }
            charge(c + 3)                                   // on to the OBS redraw
            if second { drawObs2() } else { drawObs1() }
            return
        }
        c += 5
        guard x == 4 else { charge(c + 9); return }         // no adjustment for this item
        c += 6
        guard m[R.fuelTankSelect] != 0 else { charge(c + 9); return }   // already tank 0
        m[R.fuelTankSelect] &-= 1
        charge(c + 11)
        drawFuelSelectorMarker()
    }

    /// $298E ('.'): first `tuneIncrementPre` ($E9F6: the ADF digit, or the mixture with
    /// `$FC` = 3), then the window `$091C` = 0. In war mode or with `$FC` = 2 the radar eye height
    /// zooms in: `$088B-$0889` shift right with a 0 in, then `$0889 |= $1F`. Otherwise the
    /// counterparts of `decrementSelected`: COM MHz up (135 → 118), kHz up (.95 → .00 without a
    /// carry), NAV MHz up (117 → 108), transponder digit up (7 → 0), OBS up ($B3 → 0), fuel tank
    /// 0 → 1. Clobbers A, X, Y.
    public func incrementSelected() {
        let m = mem
        let R = Input.RAM.self
        charge(6)
        let fc = tuneIncrementPre()
        m[R.quickRepeatWindow] = 0
        var c = 10                                          // close the window, test war mode
        if m[R.europe1917] != 0 { c += 3 } else {
            c += 6                                          // is it the radar zoom?
            guard fc == 2 else { charge(c + 3); incrementRadio(fc); return }
            c += 2
        }
        // $29A0: zoom in: the 24-bit height shifts right with a 0 in, then the low five bits are set.
        let b1 = m[R.radarEyeHeight + 1], b2 = m[R.radarEyeHeight + 2], b3 = m[R.radarEyeHeight + 3]
        m[R.radarEyeHeight + 3] = b3 >> 1
        m[R.radarEyeHeight + 2] = b2 >> 1 | b3 << 7
        m[R.radarEyeHeight + 1] = (b1 >> 1 | b2 << 7) | 0x1F
        charge(c + 36)
    }

    /// $29B3-$2AA8: the '.' adjustments of the items 4-$10 (A = `$FC`).
    private func incrementRadio(_ fc: UInt8) {
        let m = mem
        let R = Input.RAM.self
        var x = fc &- 4
        var c = 6                                           // the item index
        if x == 0 {
            // COM MHz: 135 wraps to 118, otherwise the units step up with a carry.
            var a = m[R.comDigits], units = m[R.comDigits + 1]
            c += 12
            if a == 0x33 && units == 0x35 {
                c += 13
                a = 0x31
                units = 0x38
            } else {
                c += a != 0x33 ? 3 : 7
                units &+= 1
                c += 4
                if units == 0x3A { c += 8; units = 0x30; a &+= 1 } else { c += 3 }
            }
            m[R.comDigits] = a
            m[R.comDigits + 1] = units
            charge(c + 14)                                  // through the shared store to the COM redraw
            drawComFrequency()
            return
        }
        c += 3
        x &-= 1
        c += 2
        if x == 0 {
            // COM kHz.
            let r = Self.kHzUp(m[R.comDigits + 2], m[R.comDigits + 3])
            m[R.comDigits + 2] = r.a
            m[R.comDigits + 3] = r.x
            charge(c + 16 + r.cycles + 11)
            drawComFrequency()
            return
        }
        c += 3
        x &-= 1
        c += 2
        if x == 0 {
            // NAV MHz, on the receiver `$0AB7` picks (the NAV2 branch crosses a page to $2A11).
            c += 8
            let nav2 = m[R.navSelect] == 2
            c += nav2 ? 4 : 2
            let digits = nav2 ? R.nav2Digits : R.nav1Digits
            let r = Self.navMHzUp(m[digits], m[digits + 1])
            m[digits] = r.a
            m[digits + 1] = r.x
            charge(c + 14 + r.cycles + 11)
            if nav2 { drawNav2Frequency() } else { drawNav1Frequency() }
            return
        }
        c += 4                                              // the branch crosses a page ($29F8 → $2A23)
        x &-= 1
        c += 2
        if x == 0 {
            // NAV kHz.
            c += 8
            let nav2 = m[R.navSelect] == 2
            c += nav2 ? 3 : 2
            let digits = (nav2 ? R.nav2Digits : R.nav1Digits) + 2
            let r = Self.kHzUp(m[digits], m[digits + 1])
            m[digits] = r.a
            m[digits + 1] = r.x
            charge(c + 14 + r.cycles + 11)
            if nav2 { drawNav2Frequency() } else { drawNav1Frequency() }
            return
        }
        c += 3
        x &-= 1
        c += 4
        if x < 4 {
            // Transponder digit X, octal: '7' wraps to '0'.
            var digit = m[R.transponderDigits + Int(x)]
            c += 8
            if digit != 0x37 { c += 3 } else { c += 4; digit = 0x2F }
            m[R.transponderDigits + Int(x)] = digit &+ 1
            charge(c + 12)
            drawTransponder()
            return
        }
        c += 3
        x &-= 4
        c += 8
        if x == 0 {
            // OBS1 or OBS2 by `$0ACB`: $B3 wraps to 0.
            c += 8
            let second = m[R.obsSelect] == 2
            c += second ? 3 : 2
            let obs = second ? R.obs2 : R.obs1
            let value = m[obs] &+ 1
            m[obs] = value
            c += 12
            if value != 0xB4 { c += 3 } else { c += 8; m[obs] = 0 }
            charge(c + 3)
            if second { drawObs2() } else { drawObs1() }
            return
        }
        c += 5
        guard x == 4 else { charge(c + 9); return }
        c += 6
        guard m[R.fuelTankSelect] == 0 else { charge(c + 9); return }   // already tank 1
        m[R.fuelTankSelect] &+= 1
        charge(c + 11)
        drawFuelSelectorMarker()
    }

    // MARK: Digit-pair helpers ($2963, $2977, $2AA9, $2ABE)

    /// $2963: kHz down on the (tenths A, hundredths X) digits: .x5 → .x0; .x0 → .(x-1)5, with
    /// .00 → .95. Cycles through its return.
    static func kHzDown(_ a: UInt8, _ x: UInt8) -> (a: UInt8, x: UInt8, cycles: Int) {
        guard x == 0x30 else { return (a, 0x30, 13) }       // .x5 → .x0
        if a == 0x30 { return (0x39, 0x35, 18) }            // .00 → .95
        return (a &- 1, 0x35, 21)                           // .x0 → .(x-1)5
    }

    /// $2977: NAV MHz down on the (tens A, units X) digits after the painted '1': 108 → 117,
    /// otherwise units - 1 with a borrow into the tens.
    static func navMHzDown(_ a: UInt8, _ x: UInt8) -> (a: UInt8, x: UInt8, cycles: Int) {
        var c = 2
        if a == 0x30 {
            c += 4
            if x == 0x38 { return (0x31, 0x37, c + 12) }    // 108 → 117
            c += 3
        } else {
            c += 3
        }
        let units = x &- 1
        c += 4
        if units == 0x2F { return (0x30, 0x39, c + 12) }    // the borrow: 110 → 109
        return (a, units, c + 9)
    }

    /// $2AA9: kHz up: .x0 → .x5; .x5 → .(x+1)0, with .95 → .00.
    static func kHzUp(_ a: UInt8, _ x: UInt8) -> (a: UInt8, x: UInt8, cycles: Int) {
        guard x == 0x35 else { return (a, 0x35, 13) }       // .x0 → .x5
        if a == 0x39 { return (0x30, 0x30, 18) }            // .95 → .00
        return (a &+ 1, 0x30, 23)                           // .x5 → .(x+1)0
    }

    /// $2ABE: NAV MHz up: 117 → 108, otherwise units + 1 with a carry into the tens.
    static func navMHzUp(_ a: UInt8, _ x: UInt8) -> (a: UInt8, x: UInt8, cycles: Int) {
        var c = 2
        if a == 0x31 {
            c += 4
            if x == 0x37 { return (0x30, 0x38, c + 12) }    // 117 → 108
            c += 3
        } else {
            c += 3
        }
        let units = x &+ 1
        c += 4
        if units == 0x3A { return (a &+ 1, 0x30, c + 14) }  // the carry into the tens
        return (a, units, c + 9)
    }
}
