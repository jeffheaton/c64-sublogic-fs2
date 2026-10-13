/// The slew-mode integrator $3660-$3772 (run by the main loop at $206E instead of
/// `integrateFlight` while `slewMode` is set). Slew moves the eye directly: the control
/// positions and the slew rates are rates, mapped through an exponential step.
extension Machine {
    /// $3660 `slewIntegrate`.
    ///
    /// 1. If `slewResetRequest` `$0A80` is set (an `integrateFlight` pass ran since): clear it and
    ///    zero the elevator, rudder, ailerons and the slew pitch and altitude rates.
    /// 2. East bytes `$5B-$5D` += `slewRateStep`(ailerons_hi) (24-bit); north `$63-$65` +=
    ///    `slewRateStep`(−elevator_hi). The low bytes `$5A`/`$62` are untouched.
    /// 3. Altitude `$5F-$61` += the sign-extended `slewAltitudeRate`; a negative result zeroes
    ///    `$5F-$61` (`$5E` is untouched). Then `$60` is rewritten with its own value (no effect).
    /// 4. View pitch high += 2·`slewPitchRate`, negated when (viewBank_hi + $40) is negative
    ///    (upside down). If the new pitch high byte leaves $C0..$40, the view flips over: pitch
    ///    = −pitch with the top bit of its high byte flipped, and the bank and heading high bytes
    ///    turn by 180° (top bit flipped).
    /// 5. View bank high += `slewBankRate`; view heading high −= `slewHeadingRate`.
    /// 6. Falls into `slewAux` ($372B).
    public func slewIntegrate() {
        let R = FlightModel.RAM.self
        var cycles: Int
        if self[R.slewResetRequest] != 0 {
            for address in [R.slewResetRequest, R.elevator, R.elevator + 1, R.rudder, R.rudder + 1,
                            R.ailerons, R.ailerons + 1, R.slewPitchRate, R.slewAltitudeRate] {
                self[address] = 0
            }
            cycles = 44
        } else {
            cycles = 7
        }
        // $3682: east += step(ailerons), north += step(−elevator).
        charge(cycles + 10)
        var step = slewRateStep(self[R.ailerons + 1])
        addSlewStep(R.eastPosition + 1, step.a, step.x)
        charge(39)
        step = slewRateStep(0 &- self[R.elevator + 1])
        addSlewStep(R.northPosition + 1, step.a, step.x)
        // $36B1: altitude += rate (sign-extended into $60/$61).
        let rate = self[R.slewAltitudeRate]
        let sign: UInt8 = FlightModel.negative(rate) ? 0xFF : 0x00
        cycles = 31 + (sign != 0 ? 3 : 4)
        var c = false
        self[R.altitude + 1] = FlightModel.adc(rate, self[R.altitude + 1], &c)
        self[R.altitude + 2] = FlightModel.adc(sign, self[R.altitude + 2], &c)
        self[R.altitude + 3] = FlightModel.adc(sign, self[R.altitude + 3], &c)
        if FlightModel.negative(self[R.altitude + 3]) {
            self[R.altitude + 1] = 0; self[R.altitude + 2] = 0; self[R.altitude + 3] = 0
            cycles += 37
        } else {
            cycles += 27
        }
        // $36D2: the no-op rewrite of $60, then the pitch rate (inverted when upside down).
        var pitchStep = self[R.slewPitchRate] << 1
        if FlightModel.negative(self[R.viewBank + 1] &+ 0x40) {
            pitchStep = 0 &- pitchStep
            cycles += 33
        } else {
            cycles += 24
        }
        let pitchHigh = pitchStep &+ self[R.viewPitch + 1]
        self[R.viewPitch + 1] = pitchHigh
        let flip: Bool
        if FlightModel.negative(pitchHigh) {
            flip = pitchHigh < 0xC0
            cycles += 15 + (flip ? 2 : 4)
        } else {
            flip = pitchHigh >= 0x41
            cycles += 14 + (flip ? 5 : 4)
        }
        if flip {
            let negated = 0 &- u16(R.viewPitch)
            self[R.viewPitch] = UInt8(truncatingIfNeeded: negated)
            self[R.viewPitch + 1] = UInt8(negated >> 8) ^ 0x80
            self[R.viewBank + 1] ^= 0x80
            self[R.viewHeading + 1] ^= 0x80
            cycles += 42
        }
        // $371B: bank and heading rates.
        self[R.viewBank + 1] &+= self[R.slewBankRate]
        self[R.viewHeading + 1] &-= self[R.slewHeadingRate]
        charge(cycles + 24)
        slewAux()
    }

    /// $372B `slewAux` (also vector $200C, used by the editor before reading the state): the
    /// display position `settingNorth` = north bytes 2-3 with $40 added to the high byte, and
    /// `settingEast` likewise from east. 42 cycles.
    public func slewAux() {
        let R = FlightModel.RAM.self
        self[R.settingNorth + 1] = self[R.northPosition + 3] &+ 0x40
        self[R.settingNorth] = self[R.northPosition + 2]
        self[R.settingEast + 1] = self[R.eastPosition + 3] &+ 0x40
        self[R.settingEast] = self[R.eastPosition + 2]
        charge(42)
    }

    /// $3746 `slewRateStep`: maps a signed rate byte r to a 24-bit step `$BE`:X:A.
    /// - r ≥ 0: 2^k − 1 with k = r / 4 (a 1 is shifted in k times), cycles 35 + 27k.
    /// - r < 0: $FFFFFF shifted left n = ⌈−r / 4⌉ times (at least once), so −2^n, cycles 22 + 23n.
    /// `$B9` = A = the low byte. Cycles include the return; the caller charges its call.
    func slewRateStep(_ rate: UInt8) -> (a: UInt8, x: UInt8) {
        let R = FlightModel.RAM.self
        var x = rate
        var low: UInt8, middle: UInt8, high: UInt8
        if FlightModel.negative(rate) {
            low = 0xFF; middle = 0xFF; high = 0xFF
            var iterations = 0
            repeat {
                let c1 = low & 0x80 != 0
                low <<= 1
                let c2 = middle & 0x80 != 0
                middle = middle << 1 | (c1 ? 1 : 0)
                high = high << 1 | (c2 ? 1 : 0)
                x &+= 4
                iterations += 1
            } while FlightModel.negative(x)
            charge(12 + 23 * iterations - 1 + 11)
        } else {
            low = 0; middle = 0; high = 0
            var iterations = 0
            while true {
                x &-= 4
                if FlightModel.negative(x) { break }
                let c1 = low & 0x80 != 0
                low = low << 1 | 1
                let c2 = middle & 0x80 != 0
                middle = middle << 1 | (c1 ? 1 : 0)
                high = high << 1 | (c2 ? 1 : 0)
                iterations += 1
            }
            charge(35 + 27 * iterations)
        }
        self[R.scratchBE] = high
        self[R.printValue + 1] = low
        return (low, middle)
    }

    /// $3688-$3696 (and $36A1-$36AF): bytes 1-3 of a position += the 24-bit step `$BE`:X:A.
    private func addSlewStep(_ address: Int, _ low: UInt8, _ middle: UInt8) {
        var c = false
        self[address] = FlightModel.adc(low, self[address], &c)
        self[address + 1] = FlightModel.adc(middle, self[address + 1], &c)
        self[address + 2] = FlightModel.adc(self[FlightModel.RAM.scratchBE], self[address + 2], &c)
    }
}
