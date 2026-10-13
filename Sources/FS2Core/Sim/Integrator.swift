/// The per-pass integrator $32EE (with its ground-contact section $3515), the density and
/// auto-level task $35BD with the service check $3614, and refuel/repair/rearm $3638.
extension Machine {
    /// $32EE `integrateFlight`: one main-loop pass of the flight model (called at $2074 when not
    /// slewing).
    ///
    /// 1. `slewResetRequest` `$0A80` = 1.
    /// 2. dt: jiffies = `$34` − `lastJiffy` (8-bit wrap; `lastJiffy` = `$34`), then
    ///    `mulU16` of (`$C5` = jiffies, `$C4` = **stale**, whatever the last math call left)
    ///    × $0222 → `frameDt` = product bits 8-23, with the high byte forced to $7F when bit 7
    ///    of it is set. The stale `$C4` adds about 2·`$C4`/256 jiffies' worth; it is emulated.
    /// 3. `heading` += turnRate × dt; `stepDistance` d = V × dt.
    /// 4. Track = high byte of (heading + `slipTrackOffset`, the offset only when airborne):
    ///    `$B9` = track, `sinTrack`/`cosTrack` = sin8/cos8 (1.406° steps).
    /// 5. `horizontalStep` `$09EA` = cosγ × d; `eastDelta` = that × sin(track);
    ///    `verticalDelta` = sinγ × d; `northDelta` = cos(track) × horizontal.
    /// 6. `liftDifference` `$0A34` = 4·(liftLeft − liftRight); `rollTerm` = that × rollScale −
    ///    `rollCancel` (then, if `rollCancel` was nonzero, it is cleared and `skipFlip` = 1);
    ///    bank += 2·(d × rollTerm).
    /// 7. North and east += the sign-extended deltas (32-bit); altitude bytes `$5E-$60` += the
    ///    vertical delta (24-bit; `$61` untouched), and a negative result becomes $000300.
    /// 8. While `repositionCounter` is set: `setAltitudeFromEditor`, and the counter counts down.
    /// 9. View angles: pitch = aoaProxy × aoaToPitch − γ (+ `viewPitchOffset` when airborne),
    ///    plus `viewPitchBump` on the high byte (then the bump is cleared); bank = −φ;
    ///    heading = ψ.
    /// 10. Ground contact ($3515, see `groundContact`), then `verticalSpeed` = V × sinγ.
    public func integrateFlight() {
        let R = FlightModel.RAM.self
        // $32EE: dt from the jiffy counter.
        self[R.slewResetRequest] = 1
        let now = self[R.jiffyCounter]
        let jiffies = now &- self[R.lastJiffy]
        self[R.lastJiffy] = now
        self[R.mathResult + 1] = jiffies
        charge(34)
        let product = mulU16(a: 0x22, x: 0x02)
        self[R.frameDt] = product.a
        var dtHigh = product.x
        if FlightModel.negative(dtHigh) {
            dtHigh = 0x7F
            charge(8)
        } else {
            charge(7)
        }
        self[R.frameDt + 1] = dtHigh
        // $330D: heading += turnRate × dt; d = V × dt.
        self[R.mathResult] = product.a; self[R.mathResult + 1] = dtHigh
        charge(24)
        var p = mulQ15AX(a: self[R.turnRate], x: self[R.turnRate + 1])
        setU16(R.heading, u16(R.heading) &+ Machine.word(p.a, p.x))
        self[R.mathResult] = self[R.frameDt]; self[R.mathResult + 1] = self[R.frameDt + 1]
        charge(48)
        p = mulQ15AX(a: self[R.airspeed], x: self[R.airspeed + 1])
        self[R.stepDistance] = p.a; self[R.stepDistance + 1] = p.x
        // $3344: the track, quantized to the high byte.
        var offset = u16(R.slipTrackOffset)
        if self[R.onGround] != 0 {
            offset = 0
            charge(26)
        } else {
            charge(23)
        }
        let track = UInt8((offset &+ u16(R.heading)) >> 8)
        self[R.printValue + 1] = track
        charge(21)
        var t = sin8(a: track)
        self[R.sinTrack] = t.a; self[R.sinTrack + 1] = t.x
        charge(17)
        t = cos8(a: self[R.printValue + 1])
        self[R.cosTrack] = t.a; self[R.cosTrack + 1] = t.x
        // $3371: the step components.
        self[R.mathResult] = self[R.cosGamma]; self[R.mathResult + 1] = self[R.cosGamma + 1]
        charge(36)
        p = mulQ15AX(a: self[R.stepDistance], x: self[R.stepDistance + 1])
        self[R.horizontalStep] = p.a; self[R.horizontalStep + 1] = p.x
        self[R.mathResult] = p.a; self[R.mathResult + 1] = p.x
        charge(28)
        p = mulQ15AX(a: self[R.sinTrack], x: self[R.sinTrack + 1])
        self[R.eastDelta] = p.a; self[R.eastDelta + 1] = p.x
        self[R.mathResult] = self[R.sinGamma]; self[R.mathResult + 1] = self[R.sinGamma + 1]
        charge(36)
        p = mulQ15AX(a: self[R.stepDistance], x: self[R.stepDistance + 1])
        self[R.verticalDelta] = p.a; self[R.verticalDelta + 1] = p.x
        self[R.mathResult] = self[R.cosTrack]; self[R.mathResult + 1] = self[R.cosTrack + 1]
        charge(36)
        p = mulQ15AX(a: self[R.horizontalStep], x: self[R.horizontalStep + 1])
        self[R.northDelta] = p.a; self[R.northDelta + 1] = p.x
        // $33CF: the roll term.
        let difference = (u16(R.liftLeft) &- u16(R.liftRight)) << 2
        setU16(R.liftDifference, difference)
        setU16(R.mathResult, difference)
        charge(74)
        p = mulQ15AX(a: self[R.rollScale], x: self[R.rollScale + 1])
        setU16(R.rollTerm, Machine.word(p.a, p.x) &- u16(R.rollCancel))
        if self[R.rollCancel] | self[R.rollCancel + 1] != 0 {
            self[R.rollCancel] = 0; self[R.rollCancel + 1] = 0
            self[R.skipFlip] = 1
            charge(60)
        } else {
            charge(45)
        }
        // $3427: bank += 2·(d × rollTerm).
        self[R.mathResult] = self[R.stepDistance]; self[R.mathResult + 1] = self[R.stepDistance + 1]
        charge(28)
        p = mulQ15AX(a: self[R.rollTerm], x: self[R.rollTerm + 1])
        setU16(R.bankAngle, u16(R.bankAngle) &+ (Machine.word(p.a, p.x) << 1))
        // $344E: north, east (32-bit) and altitude (24-bit) += the sign-extended deltas.
        let north = s16(R.northDelta), east = s16(R.eastDelta), up = s16(R.verticalDelta)
        setS32(R.northPosition, s32(R.northPosition) &+ Int32(north))
        setS32(R.eastPosition, s32(R.eastPosition) &+ Int32(east))
        let altitude = u24(R.altitude) &+ UInt32(bitPattern: Int32(up))
        setU24(R.altitude, altitude & 0xFF_FFFF)
        var cycles = 50 + (north < 0 ? 4 : 3) + 40 + (east < 0 ? 4 : 3) + 40 + (up < 0 ? 4 : 3) + 14
        if altitude & 0x80_0000 != 0 {
            setU24(R.altitude, 0x00_0300)
            cycles += 15
        } else {
            cycles += 3
        }
        // $34AF: a reposition re-applies the editor altitude.
        if self[R.repositionCounter] != 0 {
            charge(cycles + 12)
            setAltitudeFromEditor()
            self[R.repositionCounter] &-= 1
            charge(6)
        } else {
            charge(cycles + 7)
        }
        // $34BA: the view angles.
        self[R.mathResult] = self[R.aoaProxy]; self[R.mathResult + 1] = self[R.aoaProxy + 1]
        charge(28)
        p = mulQ15AX(a: self[R.aoaToPitch], x: self[R.aoaToPitch + 1])
        var pitch = Machine.word(p.a, p.x) &- u16(R.flightPathAngle)
        cycles = 19 + (self[R.viewDirection] != 0 ? 3 : 6) + 10   // with a no-op add of 0
        if self[R.onGround] == 0 {
            pitch = pitch &+ u16(R.viewPitchOffset)
            cycles += 20
        } else {
            cycles += 3
        }
        self[R.viewPitch] = UInt8(truncatingIfNeeded: pitch)
        self[R.viewPitch + 1] = UInt8(pitch >> 8) &+ self[R.viewPitchBump]
        self[R.viewPitchBump] = 0
        setU16(R.viewBank, 0 &- u16(R.bankAngle))
        self[R.viewHeading] = self[R.heading]; self[R.viewHeading + 1] = self[R.heading + 1]
        charge(cycles + 52)
        groundContact()
    }

    /// $3515 `groundContact`, the fall-through tail of `integrateFlight`.
    ///
    /// - `onGround` `$0A12` = $FF when altitude `$5E-$60` < $000301, else 0.
    /// - On the ground: bank and `rollTerm` = 0, γ = 0 if negative. If `repositionCounter` is
    ///   set, `keySpace` (brakes) and no crash check. Otherwise, descending
    ///   (`verticalSpeed` high < 0) with VS_hi + 8 < 0 (≤ −9 m/s) or (viewBank_hi + 10) mod 256
    ///   ≥ 20 (|bank| ≥ 10 high-byte units, 14°): `crashCode` = 4, airspeed high = 0,
    ///   `sfxCrash`. On first contact (`wasOnGround` = 0): sound state 8 (touchdown),
    ///   `wasOnGround` = $FF, and `viewPitchBump` = VS high byte; otherwise the bump is 0.
    /// - Airborne after being on the ground: `wasOnGround` = 0, and when (north+1 & 3) = 0 the
    ///   altimeter drift target `$09D0` = sign-extended (mainLoopCounter + carry), the carry
    ///   being clear here.
    /// - Then `verticalSpeed` = V × sinγ.
    func groundContact() {
        let R = FlightModel.RAM.self
        var c = self[R.altitude] >= 0x01
        _ = FlightModel.sbc(self[R.altitude + 1], 0x03, &c)
        let below = FlightModel.negative(FlightModel.sbc(self[R.altitude + 2], 0x00, &c))
        let flag: UInt8 = below ? 0xFF : 0x00
        self[R.onGround] = flag
        var cycles = 17 + (below ? 4 : 3) + 6
        if below {
            cycles += 2
            self[R.bankAngle] = 0; self[R.bankAngle + 1] = 0
            self[R.rollTerm] = 0; self[R.rollTerm + 1] = 0
            if FlightModel.negative(self[R.flightPathAngle + 1]) {
                self[R.flightPathAngle] = 0; self[R.flightPathAngle + 1] = 0
                cycles += 32
            } else {
                cycles += 25
            }
            if self[R.repositionCounter] != 0 {
                // $354A: `keySpace` (brakes while repositioning). Its ground path reads no
                // registers or flags.
                charge(cycles + 12)
                keySpace()
                cycles = 3
            } else {
                cycles += 13
                let vsHigh = self[R.verticalSpeed + 1]
                var crash = false
                if !FlightModel.negative(vsHigh) {
                    cycles += 3
                } else if FlightModel.negative(vsHigh &+ 8) {
                    crash = true
                    cycles += 9
                } else {
                    let bankTest = self[R.viewBank + 1] &+ 0x0A
                    crash = bankTest >= 0x14
                    cycles += 17 + (crash ? 2 : 3)
                }
                if crash {
                    self[R.crashCode] = 4
                    self[R.airspeed + 1] = 0
                    charge(cycles + 16)
                    sfxCrash()
                    cycles = 0
                }
            }
            // $3570: the first contact.
            var bump: UInt8 = 0
            if self[R.wasOnGround] != 0 {
                cycles += 9
            } else {
                self[R.soundState] = 8
                self[R.wasOnGround] &-= 1
                bump = self[R.verticalSpeed + 1]
                cycles += 24
            }
            self[R.viewPitchBump] = bump
            cycles += 7
        } else {
            // $3588: comparing 0 with `wasOnGround` leaves the carry clear unless it is 0 too.
            let was = self[R.wasOnGround]
            if was == 0 {
                cycles += 10
            } else {
                self[R.wasOnGround] = 0
                if self[R.northPosition + 1] & 0x03 != 0 {
                    cycles += 21
                } else {
                    var carry = false
                    let drift = FlightModel.adc(0, self[R.mainLoopCounter], &carry)
                    let negative = FlightModel.negative(drift)
                    self[R.altimeterDrift] = drift
                    self[R.altimeterDrift + 1] = negative ? 0xFF : 0x00
                    cycles += 25 + (negative ? 4 : 3) + 8
                }
            }
        }
        // $35A3: vertical speed.
        self[R.mathResult] = self[R.airspeed]; self[R.mathResult + 1] = self[R.airspeed + 1]
        charge(cycles + 28)
        let p = mulQ15AX(a: self[R.sinGamma], x: self[R.sinGamma + 1])
        self[R.verticalSpeed] = p.a; self[R.verticalSpeed + 1] = p.x
        charge(14)
    }

    /// $35BD `densityAndAutoLevel` (phase 2; nothing in slew mode, 13 cycles).
    ///
    /// - Density: `$C4:$C5` = 2·MSL (`$0830`), then + MSL >> 1 (logical) + the carry of bit 0;
    ///   `airDensity` = $7FFE − that − borrow, where the borrow is the inverse of the last add's
    ///   carry (so normally $7FFD − 2.5·MSL).
    /// - Auto-level when `rudder_hi` = 0: bank + $FFB0 + C (positive bank) or + $0050 + C
    ///   (negative bank), C being the density subtraction's carry; a result that crosses 0
    ///   becomes 0.
    /// - Then `serviceCheck` ($3614).
    public func densityAndAutoLevel() {
        let R = FlightModel.RAM.self
        if self[R.slewMode] != 0 { charge(13); return }
        // $35C2: the density. MSL is doubled into $C4:$C5, then halved again from the same
        // bytes; the carry left by the halving (MSL's bit 0) goes into the add.
        let lo = self[R.mslAltitude], hi = self[R.mslAltitude + 1]
        var c = lo & 0x80 != 0
        self[R.mathResult] = lo << 1
        var a = hi << 1 | (c ? 1 : 0)
        c = hi & 0x80 != 0
        self[R.mathResult + 1] = a
        let restored = (c ? 0x80 : 0) | a >> 1        // the high byte again
        c = restored & 1 != 0
        let y = restored >> 1
        a = (c ? 0x80 : 0) | lo >> 1
        c = lo & 1 != 0
        a = FlightModel.adc(a, self[R.mathResult], &c)
        self[R.mathResult] = a
        a = FlightModel.adc(y, self[R.mathResult + 1], &c)
        self[R.mathResult + 1] = a
        self[R.airDensity] = FlightModel.sbc(0xFE, self[R.mathResult], &c)
        self[R.airDensity + 1] = FlightModel.sbc(0x7F, self[R.mathResult + 1], &c)
        // $35EB: auto-level.
        var cycles = 72
        if self[R.rudder + 1] != 0 {
            charge(cycles + 4)                        // the skip branch crosses a page
            serviceCheck()
            return
        }
        cycles += 10
        var bankLo = self[R.bankAngle], bankHi = self[R.bankAngle + 1]
        if !FlightModel.negative(bankHi) {
            cycles += 4
            bankLo = FlightModel.adc(bankLo, 0xB0, &c)
            if c { bankHi &+= 1; cycles += 4 } else { cycles += 3 }
            bankHi &-= 1                               // the $FF high byte; negative = crossed 0
            if FlightModel.negative(bankHi) {
                bankLo = 0; bankHi = 0
                cycles += 9
            } else {
                cycles += 7
            }
        } else {
            cycles += 6
            bankLo = FlightModel.adc(bankLo, 0x50, &c)
            if c { bankHi &+= 1; cycles += 4 } else { cycles += 3 }
            if FlightModel.negative(bankHi) {          // still negative: not crossed 0
                cycles += 7
            } else {
                bankLo = 0; bankHi = 0
                cycles += 10
            }
        }
        self[R.bankAngle] = bankLo; self[R.bankAngle + 1] = bankHi
        charge(cycles + 8)
        serviceCheck()
    }

    /// $3614 `serviceCheck`, the tail of `densityAndAutoLevel`: when `serviceRequest` is set and
    /// the airspeed high byte is 0, `serviceAircraft`, and with `serviceRequest` = 2 (war) also
    /// ammo = 100 and bombs = '5'. A set request is always cleared.
    func serviceCheck() {
        let R = FlightModel.RAM.self
        let request = self[R.serviceRequest]
        guard request != 0 else { charge(13); return }
        if self[R.airspeed + 1] != 0 {
            charge(13)
        } else {
            charge(18)
            serviceAircraft()
            if self[R.serviceRequest] == 2 {
                self[R.ammo] = 0x64
                self[R.bombCount] = 0x35
                charge(20)
            } else {
                charge(9)
            }
        }
        self[R.serviceRequest] = 0
        charge(12)
    }

    /// $3638 `serviceAircraft` (also vector $200F): refuel, repair and rearm. Tanks = $20, the
    /// failure masks `$0942/$0943` and `$08DC/$08DD` = $FF, `hitsTaken` and `engineFailureBits`
    /// = 0, `fuelFlags` = 1, 1, and `serviceCount` + 1. 60 cycles.
    public func serviceAircraft() {
        let R = FlightModel.RAM.self
        self[R.leftFuel] = 0x20
        self[R.rightFuel] = 0x20
        self[R.failureMasks] = 0xFF; self[R.failureMasks + 1] = 0xFF
        self[R.lightsColorSet] = 0xFF; self[R.lightsColorSet + 1] = 0xFF
        self[R.hitsTaken] = 0
        self[R.engineFailureBits] = 0
        self[R.fuelFlags + 1] = 1
        self[R.fuelFlags] = 1
        self[R.serviceCount] &+= 1
        charge(60)
    }
}
