/// The flight-control keys ($2C1E-$2E91): throttle, trim, flaps, elevator, ailerons, rudder,
/// centering, the auto-coordination copies and the view-key capture. Each control key also
/// steps a slew rate (`$0AC1/$0ABF/$0AC5`), which only the slew integrator reads.
///
/// Five entry points are also called through the `$2000` vectors (the editor exit redraws the
/// controls with them): `updateElevatorIndicator` ($2024 → $2D58), `updateThrottleIndicator`
/// ($2027 → $2C46), `updateRudderIndicator` ($202A → $2E4C), `updateAileronIndicator`
/// ($202D → $2DE6) and `updateFlaps` ($2045 → $2CD7). A call through a vector costs the
/// vector's jump (3 cycles) on top, which the caller charges.
extension Machine {
    // MARK: captureViewKey ($2E84)

    /// $2E84 (first thing the view keys T/Y/H/N/B/V/F/R/G do, with X = view code): when `$FC` =
    /// 1 (after '5'), `$FC` = 0, `$0ACA` = X and the original discards its caller's return
    /// address, so the key only picks the view. View codes: T 0, Y 2, H 4, N 6, B 8, V $0A,
    /// F $0C, R $0E, G $FF (down).
    ///
    /// - Returns: true when the key was captured (the handler must return at once; the caller
    ///   has already charged loading the view code and the call).
    func captureViewKey(_ code: UInt8) -> Bool {
        let m = mem
        guard m[Input.RAM.selectedItem] == 1 else { charge(14); return false }
        m[Input.RAM.selectedItem] = 0
        m[Input.RAM.viewDirection] = code
        charge(30)                                          // captured: returns past the key handler
        return true
    }

    // MARK: Elevator ($2D2B-$2D6C, $2E5C-$2E83)

    /// $2D2B (T, push: nose down; joystick port 1 up): elevator high byte `$0AAC` - 4, or - 16
    /// when the quick-repeat window `$091C` is open and not slewing; a negative result below $B0
    /// is clamped to $B0. Then `$091C` = 3 and the indicator ($2D58). In slew the elevator is the
    /// north rate. Clobbers A, X, Y.
    public func keyElevatorDown() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0x00) else { return }
        var a = m[R.elevator + 1] &- 4
        var c = 12                                          // step 4, then the slew test
        if m[R.slewMode] != 0 { c += 3 } else {
            c += 6                                          // not slewing: is the window open?
            if m[R.quickRepeatWindow] == 0 { c += 3 } else { c += 6; a &-= 0x0C }
        }
        m[R.elevator + 1] = a
        c += 6                                              // store, test the sign
        if a & 0x80 == 0 { c += 3 } else {
            c += 4                                          // negative: clamp at $B0
            if a >= 0xB0 { c += 3 } else { c += 4; a = 0xB0 }
        }
        charge(c)
        storeElevator(a)
    }

    /// $2E5C (B, pull: nose up; joystick port 1 down): elevator high byte + 4, or + 16 in the
    /// quick-repeat window when not slewing; a positive result of $50 or more is clamped to $50.
    /// Then as `keyElevatorDown` from $2D50. Clobbers A, X, Y.
    public func keyElevatorUp() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0x08) else { return }
        var a = m[R.elevator + 1] &+ 4
        var c = 12                                          // step 4, then the slew test
        if m[R.slewMode] != 0 { c += 3 } else {
            c += 6                                          // not slewing: is the window open?
            if m[R.quickRepeatWindow] == 0 { c += 3 } else { c += 6; a &+= 0x0C }
        }
        m[R.elevator + 1] = a
        c += 6                                              // store, test the sign
        if a & 0x80 != 0 { c += 3 } else {
            c += 4                                          // positive: clamp at $50
            if a < 0x50 { c += 3 } else { c += 4; a = 0x50 }
        }
        charge(c + 3)                                       // joins the store at $2D50
        storeElevator(a)
    }

    /// $2D50: `$0AAC` = A, opens the quick-repeat window (`$091C` = 3), then $2D58.
    private func storeElevator(_ a: UInt8) {
        mem[Input.RAM.elevator + 1] = a
        mem[Input.RAM.quickRepeatWindow] = 3
        charge(10)
        updateElevatorIndicator()
    }

    /// $2D58 (vector $2024; also the reality-mode trim creep $EB08): the elevator marker
    /// position ($50 - `$0AAC`) >> 3; when it differs from `$2715`, stores it and moves the
    /// marker (`drawElevatorIndicator`). Clobbers A, X, Y.
    public func updateElevatorIndicator() {
        let m = mem
        let R = Input.RAM.self
        let position = (0x50 &- m[R.elevator + 1]) >> 3
        let c = 18                                          // the marker position, compared
        guard position != m[R.elevatorIndicator] else { charge(c + 9); return }
        m[R.elevatorIndicator] = position
        charge(c + 12)                                      // changed: remember it and redraw
        drawElevatorIndicator(position)
        charge(6)
    }

    // MARK: Ailerons and rudder ($2D6D-$2E5B)

    /// $2D6D (F; joystick port 1 left): aileron high byte `$0AA4` - 4, refused when the result
    /// would be $80 (so the range ends at $84 = -124); then `coordinateRudder`. In slew the
    /// ailerons are the east rate. Clobbers A, X, Y.
    public func keyAileronLeft() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0x0C) else { return }
        let a = m[R.ailerons + 1] &- 4
        guard a != 0x80 else { charge(19); return }         // would reach $80: refused
        m[R.ailerons + 1] = a
        charge(19)                                          // store, tail jump to $2DD2
        coordinateRudder()
    }

    /// $2DC2 (H; joystick port 1 right): aileron high byte + 4, refused on signed overflow
    /// (the range ends at $7C = 124); then falls into `coordinateRudder`. Clobbers A, X, Y.
    public func keyAileronRight() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0x04) else { return }
        let old = m[R.ailerons + 1]
        let a = old &+ 4
        guard (old ^ a) & (0x04 ^ a) & 0x80 == 0 else { charge(18); return }   // overflow: refused (the branch crosses a page)
        m[R.ailerons + 1] = a
        charge(14)                                          // store, falls into $2DD2
        coordinateRudder()
    }

    /// $2DD2: with auto-coordination (`$0965`), rudder `$0ABC/$0ABD` = ailerons and
    /// `updateRudderIndicator` ($2E4C); then falls into `updateAileronIndicator` ($2DE6).
    /// Clobbers A, X, Y.
    public func coordinateRudder() {
        let m = mem
        let R = Input.RAM.self
        if m[R.autoCoordination] == 0 {
            charge(7)                                       // no auto-coordination
        } else {
            m[R.rudder] = m[R.ailerons]
            m[R.rudder + 1] = m[R.ailerons + 1]
            charge(28)                                      // copy the ailerons to the rudder
            updateRudderIndicator()
        }
        updateAileronIndicator()
    }

    /// $2DE6 (vector $202D): the aileron marker position (`$0AA4` + $7F) >> 3 into `$2716`,
    /// moved (`drawAileronIndicator`) when it changed; then the aileron coefficient `$0A1D` =
    /// ailerons × gain (`$0A7A`, or `$0A7C` while the maneuver timer `$0E75` runs; Q15,
    /// `mulQ15AX` from `$C4/$C5`) and `controlCoefficients`. Clobbers A, X, Y.
    public func updateAileronIndicator() {
        let m = mem
        let R = Input.RAM.self
        let position = (m[R.ailerons + 1] &+ 0x7F) >> 3
        let same = position == m[R.aileronIndicator]
        m[R.aileronIndicator] = position
        var c = 22                                          // the position, compared and stored
        if same { c += 3 } else {
            charge(c + 8)                                   // changed: redraw
            drawAileronIndicator(position)
            c = 0
        }
        // $2DFA: the ailerons into the multiplicand, and the gain picked by the maneuver timer.
        m[R.mathResult] = m[R.ailerons]
        m[R.mathResult + 1] = m[R.ailerons + 1]
        c += 26
        var gain = R.aileronGain
        if m[R.maneuverTimer] == 0 { c += 3 } else { c += 10; gain = R.aileronGainManeuver }
        charge(c + 6)
        let p = mulQ15AX(a: m[gain], x: m[gain + 1])
        m[R.aileronCoefficient] = p.a
        m[R.aileronCoefficient + 1] = p.x
        charge(14)                                          // store the coefficient
        controlCoefficients()
        charge(6)
    }

    /// $2E22 (C): rudder high byte `$0ABD` - 4, refused when the result would be $80; then the
    /// rudder store at $2E35. Clobbers A, X, Y.
    public func keyRudderLeft() {
        let a = mem[Input.RAM.rudder + 1] &- 4
        guard a != 0x80 else { charge(18); return }         // would reach $80: refused
        charge(13)
        storeRudder(a)
    }

    /// $2E2D (M): rudder high byte + 4, refused on signed overflow. Clobbers A, X, Y.
    public func keyRudderRight() {
        let old = mem[Input.RAM.rudder + 1]
        let a = old &+ 4
        guard (old ^ a) & (0x04 ^ a) & 0x80 == 0 else { charge(17); return }   // overflow: refused
        charge(10)
        storeRudder(a)
    }

    /// $2E35: `$0ABD` = A, then $2E38.
    private func storeRudder(_ a: UInt8) {
        mem[Input.RAM.rudder + 1] = a
        charge(4)
        coordinateAilerons()
    }

    /// $2E38: with auto-coordination, ailerons = rudder and `updateAileronIndicator`; then falls
    /// into `updateRudderIndicator`.
    private func coordinateAilerons() {
        let m = mem
        let R = Input.RAM.self
        if m[R.autoCoordination] == 0 {
            charge(7)                                       // no auto-coordination
        } else {
            m[R.ailerons] = m[R.rudder]
            m[R.ailerons + 1] = m[R.rudder + 1]
            charge(28)                                      // copy the rudder to the ailerons
            updateAileronIndicator()
        }
        updateRudderIndicator()
    }

    /// $2E4C (vector $202A): moves the rudder marker to (`$0ABD` + $7F) >> 3
    /// (`drawRudderIndicator`, always), then `controlCoefficients`. Clobbers A, X, Y.
    public func updateRudderIndicator() {
        let position = (mem[Input.RAM.rudder + 1] &+ 0x7F) >> 3
        charge(20)                                          // the position, then the redraw
        drawRudderIndicator(position)
        charge(6)
        controlCoefficients()
        charge(6)
    }

    /// $2D82 (G): centers the controls. In slew it first zeroes the elevator high byte and the
    /// four slew rates (`$0AC3`, `$0ABF`, `$0AC1`, `$0AC5`). Clobbers A, X, Y.
    public func keyCenter() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0xFF) else { return }
        var c = 6                                           // A = 0, then the slew test
        if m[R.slewMode] == 0 { c += 3 } else {
            m[R.elevator + 1] = 0
            m[R.slewPitchRate] = 0
            m[R.slewBankRate] = 0
            m[R.slewHeadingRate] = 0
            m[R.slewAltitudeRate] = 0
            c += 22
        }
        charge(c)
        centerControls()
    }

    /// $2D9D (from G and `autoCenter`, both with A = 0): aileron and rudder high bytes = 0.
    /// When half the over-control limiter `$09A9` plus the roll term high byte `$09FD` (8-bit
    /// sum) reaches the limiter, the roll term `$09FC/$09FD` is copied to the roll cancel
    /// `$0E76/$0E77` (the integrator subtracts it). Then `coordinateRudder` and $2E38.
    /// Clobbers A, X, Y.
    public func centerControls() {
        let m = mem
        let R = Input.RAM.self
        m[R.ailerons + 1] = 0
        m[R.rudder + 1] = 0
        let limiter = m[R.overControlLimiter]
        var c = 24                                          // zero both, then the limiter test
        if (limiter >> 1) &+ m[R.rollTerm + 1] < limiter { c += 3 } else {
            m[R.rollCancel] = m[R.rollTerm]
            m[R.rollCancel + 1] = m[R.rollTerm + 1]
            c += 18
        }
        charge(c + 6)
        coordinateRudder()
        charge(3)                                           // tail jump to $2E38
        coordinateAilerons()
    }

    // MARK: Trim ($2C87-$2CC1)

    /// $2C87 (V): trim `$0AAE` + 4 unless that makes $54 (so at most $50 = 80), the trim marker;
    /// also increments `$0AC1` (the slew heading rate). Clobbers A, X, Y.
    public func keyTrimUp() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0x0A) else { return }
        m[R.slewHeadingRate] &+= 1
        let a = m[R.elevatorTrim] &+ 4
        charge(19)                                          // slew rate, trim step, limit test
        storeTrim(a, limit: 0x54)
    }

    /// $2C9A (R): sets the war-mode `$FD00` request `$08D7` = 1, increments `$0ABF` (the slew
    /// bank rate), trim - 4 unless that makes $AC (so at least -80), the trim marker.
    /// Clobbers A, X, Y.
    public func keyTrimDown() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0x0E) else { return }
        m[R.fd00HookRequest] = 1
        m[R.slewBankRate] &+= 1
        let a = m[R.elevatorTrim] &- 4
        charge(22)                                          // request, slew rate, trim step, limit test
        storeTrim(a, limit: 0xAC)
    }

    /// $2CAF: stores the trim unless it equals the limit, then moves the trim marker to
    /// ($50 - trim) >> 4 (`drawTrimIndicator`), and leaves through the return at $2CC1.
    private func storeTrim(_ a: UInt8, limit: UInt8) {
        let m = mem
        var c = 3                                           // at the limit: not stored
        if a != limit { m[Input.RAM.elevatorTrim] = a; c = 6 }
        let position = (0x50 &- m[Input.RAM.elevatorTrim]) >> 4
        charge(c + 22)                                      // the marker position
        drawTrimIndicator(position)
        charge(6)                                           // the return at $2CC1
    }

    // MARK: Flaps ($2CC2-$2D2A)

    /// $2CC2 (Y): flaps high byte `$0AB0` - $20, floored at 0; decrements `$0ABF` (slew bank
    /// rate); then $2CD4. Clobbers A, X, Y.
    public func keyFlapsUp() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0x02) else { return }
        m[R.slewBankRate] &-= 1
        var a = m[R.flaps + 1] &- 0x20
        var c = 14                                          // slew rate, flaps step
        if a & 0x80 == 0 { c += 3 } else { c += 4; a = 0 }
        charge(c)
        storeFlaps(a)
    }

    /// $2D11 (N): decrements `$0AC1` (slew heading rate); unless slewing, flaps high byte + $20,
    /// at most $60 (a negative sum becomes $60); then $2CD4. Clobbers A, X, Y.
    public func keyFlapsDown() {
        let m = mem
        let R = Input.RAM.self
        charge(8)                                           // the view capture check
        guard !captureViewKey(0x06) else { return }
        m[R.slewHeadingRate] &-= 1
        guard m[R.slewMode] == 0 else { charge(19); return }   // slewing: the flaps stay
        var a = m[R.flaps + 1] &+ 0x20
        var c = 20                                          // slew rate, slew test, flaps step
        if a & 0x80 == 0 { c += 4 } else { c += 8; a = 0x60 }   // the in-range branch crosses a page
        charge(c)
        storeFlaps(a)
    }

    /// $2CD4: `$0AB0` = A, then $2CD7.
    private func storeFlaps(_ a: UInt8) {
        mem[Input.RAM.flaps + 1] = a
        charge(4)
        updateFlaps(a)
    }

    /// $2CD7 (vector $2045; the editor exit calls it with A = `$0AB0`): moves the flaps marker to
    /// A >> 4 (`drawFlapsIndicator`), then flap lift `$0A25` = flaps × `$0A7E`,
    /// `rebuildWingCoefficients`, and the flap drag `$0A0A` = high byte of flaps × `$0A6C` (Q15,
    /// `mulQ15AX` from `$C4/$C5`). Clobbers A, X, Y.
    public func updateFlaps(_ flapsHigh: UInt8) {
        let m = mem
        let R = Input.RAM.self
        charge(14)                                          // the marker position
        drawFlapsIndicator(flapsHigh >> 4)
        m[R.mathResult] = m[R.flaps]
        m[R.mathResult + 1] = m[R.flaps + 1]
        charge(28)                                          // flaps into the multiplicand
        var p = mulQ15AX(a: m[R.flapLiftFactor], x: m[R.flapLiftFactor + 1])
        m[R.flapLift] = p.a
        m[R.flapLift + 1] = p.x
        charge(14)                                          // store the flap lift
        rebuildWingCoefficients()
        m[R.mathResult] = m[R.flaps]
        m[R.mathResult + 1] = m[R.flaps + 1]
        charge(28)
        p = mulQ15AX(a: m[R.flapDragFactor], x: m[R.flapDragFactor + 1])
        m[R.flapDrag] = p.x
        charge(10)                                          // only the high byte is kept
    }

    // MARK: Throttle ($2C1E-$2C54)

    /// $2C1E (';', also CTRL-U; joystick port 2 up): increments `$0AC5` (slew altitude rate);
    /// with the '/' prefix armed (halving `$08D5` shifts out a 1) the throttle `$0AC9` jumps to
    /// $78, else it gains 8 unless the sum is negative (so it stops at $78, or wherever an odd
    /// value such as the demo's $7D sits); then the marker ($2C43). Clobbers A, X, Y.
    public func throttleUp() {
        let m = mem
        let R = Input.RAM.self
        m[R.slewAltitudeRate] &+= 1
        let armed = m[R.throttleJumpArmed]
        m[R.throttleJumpArmed] = armed >> 1
        var c = 14                                          // slew rate, consume the prefix
        let a: UInt8
        if armed & 1 != 0 { c += 3; a = 0x78 } else {
            let sum = m[R.throttle] &+ 8
            c += 10
            guard sum & 0x80 == 0 else { charge(c + 8); return }   // past $7F: unchanged
            c += 3
            a = sum
        }
        charge(c)
        storeThrottle(a)
    }

    /// $2C31 (':', DEL, '←'; joystick port 2 down): decrements `$0AC5`; with the '/' prefix the
    /// throttle goes to 0, else it loses 8 unless the difference is negative (so 1-7 stay);
    /// then the marker.
    ///
    /// - Returns: A as the routine leaves it (`joystickAction` tests its bit 2): the negative
    ///   difference when nothing changed, else the last bitmap byte the throttle marker XORed.
    @discardableResult
    public func throttleDown() -> UInt8 {
        let m = mem
        let R = Input.RAM.self
        m[R.slewAltitudeRate] &-= 1
        let armed = m[R.throttleJumpArmed]
        m[R.throttleJumpArmed] = armed >> 1
        var c = 14                                          // slew rate, consume the prefix
        let a: UInt8
        if armed & 1 != 0 { c += 3; a = 0 } else {
            let difference = m[R.throttle] &- 8
            c += 10
            guard difference & 0x80 == 0 else { charge(c + 9); return difference }   // below 0: unchanged
            c += 2
            a = difference
        }
        charge(c)
        return storeThrottle(a)
    }

    /// $2C43: `$0AC9` = A, then $2C46.
    @discardableResult
    private func storeThrottle(_ a: UInt8) -> UInt8 {
        mem[Input.RAM.throttle] = a
        charge(4)
        return updateThrottleIndicator()
    }

    /// $2C46 (vector $2027): moves the throttle marker to `$0AC9` >> 3 (a tail jump to $1BE1).
    ///
    /// - Returns: A as `plotPointList` leaves it (the last bitmap byte the marker XORed).
    @discardableResult
    public func updateThrottleIndicator() -> UInt8 {
        let position = mem[Input.RAM.throttle] >> 3
        charge(13)
        drawThrottleIndicator(position)
        return plotPointListResult()
    }

    /// $2C4F ('/'): arms the throttle jump (`$08D5` = 1) for the next throttle key.
    public func throttleJump() {
        mem[Input.RAM.throttleJumpArmed] = 1
        charge(12)
    }

    /// A as `plotPointList` ($1D01) returns it: the byte its last indirect store through the row
    /// pointer wrote, read back through the state it leaves: the row pointer `$8E/$8F`, the shape
    /// pointer `$9C/$9D`, the x origin `$0A9F` and the index `$0AA1` (two past the last point's dx).
    private func plotPointListResult() -> UInt8 {
        let m = mem
        let R = Input.RAM.self
        let shape = zpPointer(R.markerShapePtr)
        let dx = m[(shape + Int(m[R.markerIndex] &- 2)) & 0xFFFF]
        let x = m[R.markerX] &+ dx
        return m[(zpPointer(R.rowPointer) + Int(x & 0xF8)) & 0xFFFF]
    }
}
