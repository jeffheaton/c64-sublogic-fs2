/// The 5 Hz aerodynamics update $2F45-$32DE (called from the 10 Hz tick at $23B1 on even ticks
/// while not paused).
extension Machine {
    /// $2F45 `aeroUpdate`: one aerodynamic step of airspeed and flight-path angle. Does nothing in
    /// slew mode (13 cycles). Otherwise, with every product a `mulQ15` (Q15) unless noted:
    ///
    /// 1. `sinGamma` `$0A3E` = sin16(γ), `cosGamma` = cos8(γ_hi), `sinPhi` `$0A40` = sin16(φ),
    ///    `cosPhi` = cos8(φ_hi), `cosPhiSquaredSigned` = cosφ·cosφ, negated when cosφ < 0.
    /// 2. `rudderGainResult` `$0A04` = mul8Half(interp($0E42)_hi, rudder_hi) (never read).
    /// 3. `aoaProxy` `$09DC` = interp($0E10) × elevator; `wingLift` `$0A1F` = aoaProxy × `$0A78`.
    /// 4. Wing totals `$0A56` = wingLift + CL_L (0 when `damageLevel` is set), `$0A58` = wingLift + CL_R.
    /// 5. Stall: aoa_hi ≥ 0 writes the lamp cells `$7E3D/$7E3E` ($12 and stall-horn state
    ///    `$0E59 = 1` when aoa_hi ≥ $21, else $1B); aoa_hi ≥ $24 or ≤ $E6 sets `stallTimer` = 15
    ///    and `maneuverTimer` = 6.
    /// 6. q = V·V `$0A4E`; `liftLeft`/`liftRight` = 4·(q × wing total) (16-bit shifts).
    /// 7. `liftTotal` = ((liftLeft + liftRight) × density) × (`liftScale` with its high byte + $0B
    ///    below 20 m); while `stallTimer` counts down it is 0.
    /// 8. `weightSinGamma` `$0A44` = sinγ × W, `weightCosGamma` `$09F0` = cosγ × W,
    ///    `normalForce` = L × cosφ|cosφ| − W·cosγ.
    /// 9. `liftLeftSquared`/`liftRightSquared` (`$0A5A`/`$0A5C`) = the wing totals squared;
    ///    drag = ((CD0 + k × (sum of squares + slip drag + flap drag·256, with the quirky carry
    ///    handling of $314B-$3164)) × q) × density + W·sinγ, plus the low byte of `$0A74` when
    ///    V ≠ 0.
    /// 10. `netForce` `$0A08` = thrust − drag; `acceleration` = netForce × `inverseMass`.
    /// 11. `turnRate` = `mulQ15Times4`((interp($0E24) × sinφ) × L) + slipYaw (airborne), or the
    ///     product alone on the ground, replaced by rudder ASR 3 on the ground when V ≠ 0.
    /// 12. `gammaRate` = interp($0E1A) × normalForce (halved unless `maneuverTimer`), and 0 when
    ///     negative on the ground.
    /// 13. V += acceleration; signed overflow forces the high byte to $64, a negative result 0.
    /// 14. γ += gammaRate; past ±90° it is reflected and bank and heading flip by 180°.
    ///
    /// Cycles are counted exactly per path (the math routines charge their own).
    public func aeroUpdate() {
        let R = FlightModel.RAM.self
        // $2F45: slew mode skips the whole update.
        if self[R.slewMode] != 0 { charge(13); return }
        // $2F4A-$2F87: the four trig values and cos φ squared.
        charge(20)
        var t = sin16(a: self[R.flightPathAngle + 1], x: self[R.flightPathAngle])
        self[R.sinGamma] = t.a; self[R.sinGamma + 1] = t.x
        charge(18)
        t = cos8(a: self[R.flightPathAngle + 1])
        self[R.cosGamma] = t.a; self[R.cosGamma + 1] = t.x
        charge(22)
        t = sin16(a: self[R.bankAngle + 1], x: self[R.bankAngle])
        self[R.sinPhi] = t.a; self[R.sinPhi + 1] = t.x
        charge(18)
        t = cos8(a: self[R.bankAngle + 1])
        self[R.cosPhi] = t.a; self[R.cosPhi + 1] = t.x
        self[R.mathResult] = t.a; self[R.mathResult + 1] = t.x
        charge(20)
        var p = mulQ15AX(a: t.a, x: t.x)
        var lo = p.a, hi = p.x
        // $2F87: the square takes the sign of cos φ.
        if FlightModel.negative(self[R.cosPhi + 1]) {
            charge(12)
            let n = negate16(a: lo, x: hi)
            lo = n.a; hi = n.x
        } else {
            charge(7)
        }
        self[R.cosPhiSquaredSigned] = lo; self[R.cosPhiSquaredSigned + 1] = hi
        // $2F95: the rudder gain (table $0E42); the result is never read.
        self[R.tablePtr] = 0x42; self[R.tablePtr + 1] = 0x0E
        charge(24)
        let g = interpBySpeed()
        charge(12)
        let rg = mul8Half(x: g.a, y: self[R.rudder + 1], carry: g.carry)
        self[R.rudderGainResult + 1] = rg.y; self[R.rudderGainResult] = rg.a
        // $2FAD: the AoA proxy (table $0E10) and the wing lift.
        self[R.tablePtr] = 0x10; self[R.tablePtr + 1] = 0x0E
        charge(24)
        interpBySpeed()
        charge(14)
        p = mulQ15AX(a: self[R.elevator], x: self[R.elevator + 1])
        self[R.aoaProxy] = p.a; self[R.mathResult] = p.a
        self[R.aoaProxy + 1] = p.x; self[R.mathResult + 1] = p.x
        charge(30)
        p = mulQ15AX(a: self[R.constant0A78], x: self[R.constant0A78 + 1])
        self[R.wingLift] = p.a; self[R.wingLift + 1] = p.x
        // $2FDB: the wing totals.
        let wing = Machine.word(p.a, p.x)
        setU16(R.liftCoefficientLeftTotal, wing &+ u16(R.liftCoefficientLeft))
        if self[R.damageLevel] != 0 {
            charge(44)
            self[R.liftCoefficientLeftTotal] = 0; self[R.liftCoefficientLeftTotal + 1] = 0
        } else {
            charge(35)
        }
        setU16(R.liftCoefficientRightTotal, u16(R.wingLift) &+ u16(R.liftCoefficientRight))
        // $3009: stall lamps, horn and timers.
        let aoaHigh = self[R.aoaProxy + 1]
        let stall: Bool
        if !FlightModel.negative(aoaHigh) {
            var cycles = 36
            var lamp: UInt8 = 0x1B
            if aoaHigh >= 0x21 {
                self[R.soundState] = 0x01
                lamp = 0x12
                cycles += 10
            } else {
                cycles += 3
            }
            self[R.stallLampCells] = lamp; self[R.stallLampCells + 1] = lamp
            stall = aoaHigh >= 0x24
            cycles += 10 + (stall ? 2 : 3)
            charge(cycles)
        } else {
            stall = aoaHigh < 0xE7
            charge(35 + (stall ? 3 : 2))
        }
        if stall {
            self[R.stallTimer] = 0x0F
            self[R.maneuverTimer] = 0x06
            charge(15)                         // both timers, then on to $3037
        } else {
            charge(2)                              // $3035: no stall
        }
        // $3037: q = V², then the lift of each wing, ×4.
        self[R.mathResult] = self[R.airspeed]; self[R.mathResult + 1] = self[R.airspeed + 1]
        charge(20)
        p = mulQ15AX(a: self[R.airspeed], x: self[R.airspeed + 1])
        self[R.dynamicPressure] = p.a; self[R.dynamicPressure + 1] = p.x
        self[R.mathResult] = p.a; self[R.mathResult + 1] = p.x
        charge(28)
        p = mulQ15AX(a: self[R.liftCoefficientLeftTotal], x: self[R.liftCoefficientLeftTotal + 1])
        setU16(R.liftLeft, Machine.word(p.a, p.x) << 2)
        self[R.mathResult] = self[R.dynamicPressure]; self[R.mathResult + 1] = self[R.dynamicPressure + 1]
        charge(52)
        p = mulQ15AX(a: self[R.liftCoefficientRightTotal], x: self[R.liftCoefficientRightTotal + 1])
        setU16(R.liftRight, Machine.word(p.a, p.x) << 2)
        // $3086: ground effect below 20 m: (altitude+1 − $14) with borrow into altitude+2 < 0.
        var c = self[R.altitude + 1] >= 0x14
        let below20 = FlightModel.negative(FlightModel.sbc(self[R.altitude + 2], 0, &c))
        let groundEffect: UInt8 = below20 ? 0x0B : 0
        charge(36 + (below20 ? 4 : 3))
        // $3094: (liftLeft + liftRight) × density, chained into × liftScale.
        setU16(R.mathResult, u16(R.liftRight) &+ u16(R.liftLeft))
        charge(43)
        mulQ15Chain(a: self[R.airDensity], x: self[R.airDensity + 1])
        charge(22)
        p = mulQ15AX(a: self[R.liftScale], x: self[R.liftScale + 1] &+ groundEffect)
        self[R.liftTotal] = p.a; self[R.liftTotal + 1] = p.x
        // $30C2: the stall timer cuts the lift.
        if self[R.stallTimer] != 0 {
            self[R.stallTimer] &-= 1
            self[R.liftTotal] = 0; self[R.liftTotal + 1] = 0
            charge(30)
        } else {
            charge(15)
        }
        // $30D2: weight components and the normal force.
        self[R.mathResult] = self[R.sinGamma]; self[R.mathResult + 1] = self[R.sinGamma + 1]
        charge(28)
        p = mulQ15AX(a: self[R.weight], x: self[R.weight + 1])
        self[R.weightSinGamma] = p.a; self[R.weightSinGamma + 1] = p.x
        self[R.mathResult] = self[R.cosGamma]; self[R.mathResult + 1] = self[R.cosGamma + 1]
        charge(36)
        p = mulQ15AX(a: self[R.weight], x: self[R.weight + 1])
        self[R.weightCosGamma] = p.a; self[R.weightCosGamma + 1] = p.x
        self[R.mathResult] = self[R.liftTotal]; self[R.mathResult + 1] = self[R.liftTotal + 1]
        charge(36)
        p = mulQ15AX(a: self[R.cosPhiSquaredSigned], x: self[R.cosPhiSquaredSigned + 1])
        setU16(R.normalForce, Machine.word(p.a, p.x) &- u16(R.weightCosGamma))
        // $3125: the squares of the wing totals.
        self[R.mathResult] = self[R.liftCoefficientLeftTotal]
        self[R.mathResult + 1] = self[R.liftCoefficientLeftTotal + 1]
        charge(40)
        p = mulQ15AX(a: self[R.liftCoefficientLeftTotal], x: self[R.liftCoefficientLeftTotal + 1])
        self[R.liftLeftSquared] = p.a; self[R.liftLeftSquared + 1] = p.x
        self[R.mathResult] = self[R.liftCoefficientRightTotal]
        self[R.mathResult + 1] = self[R.liftCoefficientRightTotal + 1]
        charge(28)
        p = mulQ15AX(a: self[R.liftCoefficientRightTotal], x: self[R.liftCoefficientRightTotal + 1])
        self[R.liftRightSquared] = p.a; self[R.liftRightSquared + 1] = p.x
        // $314B: low = sqR + sqL (a carry increments X), + slip drag; high = X + sqL_hi + carry,
        // then + slipDrag_hi and + flapDrag with the carries dropped (cleared before each add).
        c = false
        var a = FlightModel.adc(p.a, self[R.liftLeftSquared], &c)
        var x = p.x
        if c {
            x &+= 1
            c = false
            charge(20)
        } else {
            charge(17)
        }
        a = FlightModel.adc(a, self[R.slipDrag], &c)
        self[R.mathResult] = a
        a = FlightModel.adc(x, self[R.liftLeftSquared + 1], &c)
        a = a &+ self[R.slipDrag + 1] &+ self[R.flapDrag]
        self[R.mathResult + 1] = a
        charge(42)
        p = mulQ15AX(a: self[R.inducedDragFactor], x: self[R.inducedDragFactor + 1])
        // $316F: + CD0, × q (chained), × density, + W·sinγ.
        setU16(R.mathResult, Machine.word(p.a, p.x) &+ u16(R.dragCoefficient0))
        charge(32)
        mulQ15Chain(a: self[R.dynamicPressure], x: self[R.dynamicPressure + 1])
        charge(14)
        p = mulQ15AX(a: self[R.airDensity], x: self[R.airDensity + 1])
        setU16(R.drag, Machine.word(p.a, p.x) &+ u16(R.weightSinGamma))
        // $319B: the drag bias (low byte of $0A74 only) when moving.
        if self[R.airspeed] | self[R.airspeed + 1] == 0 {
            charge(31)
        } else {
            c = false
            self[R.drag] = FlightModel.adc(self[R.drag], self[R.parasiteDragBias], &c)
            if c {
                self[R.drag + 1] &+= 1
                charge(52)
            } else {
                charge(47)
            }
        }
        // $31B2: net force and acceleration.
        let net = u16(R.thrust) &- u16(R.drag)
        setU16(R.netForce, net)
        setU16(R.mathResult, net)
        charge(46)
        p = mulQ15AX(a: self[R.inverseMass], x: self[R.inverseMass + 1])
        self[R.acceleration] = p.a; self[R.acceleration + 1] = p.x
        // $31D8: turn rate = 4·((interp($0E24) × sinφ) × L) (+ slip yaw when airborne).
        self[R.tablePtr] = 0x24; self[R.tablePtr + 1] = 0x0E
        charge(24)
        interpBySpeed()
        charge(14)
        mulQ15Chain(a: self[R.sinPhi], x: self[R.sinPhi + 1])
        charge(14)
        let turn = mulQ15Times4(a: self[R.liftTotal], x: self[R.liftTotal + 1])
        if self[R.onGround] != 0 {
            charge(13)
            self[R.turnRate] = turn.a; self[R.turnRate + 1] = turn.x
        } else {
            charge(21)
            setU16(R.turnRate, Machine.word(turn.a, turn.x) &+ u16(R.slipYaw))
        }
        // $320E: on the ground and moving, the rudder steers: turnRate = rudder ASR 3.
        if self[R.onGround] == 0 {
            charge(15)
        } else if self[R.airspeed] | self[R.airspeed + 1] == 0 {
            charge(25)
        } else {
            charge(38)
            var s = asr16(a: self[R.rudder], x: self[R.rudder + 1])
            charge(6)
            s = asr16(a: s.a, x: s.x)
            charge(6)
            s = asr16(a: s.a, x: s.x)
            self[R.turnRate] = s.a; self[R.turnRate + 1] = s.x
            charge(8)
        }
        // $3230: γ rate = interp($0E1A) × normal force (halved by an ASR unless maneuvering).
        self[R.tablePtr] = 0x1A; self[R.tablePtr + 1] = 0x0E
        charge(16)
        interpBySpeed()
        var nLo = self[R.normalForce], nHi = self[R.normalForce + 1]
        if self[R.maneuverTimer] != 0 {
            charge(17)
        } else {
            let half = Machine.asr16(a: nLo, x: nHi)    // the same shift as asr16, done inline
            nLo = half.a; nHi = half.x
            charge(23)
        }
        charge(6)
        p = mulQ15AX(a: nLo, x: nHi)
        self[R.gammaRate] = p.a; self[R.gammaRate + 1] = p.x
        if self[R.onGround] == 0 {
            charge(17)
        } else if !FlightModel.negative(p.x) {
            charge(21)
        } else {
            self[R.gammaRate] = 0; self[R.gammaRate + 1] = 0
            charge(30)
        }
        // $326E: V += acceleration (signed overflow → $64, negative → 0).
        c = false
        self[R.airspeed] = FlightModel.adc(self[R.acceleration], self[R.airspeed], &c)
        let sum = FlightModel.adcV(self[R.acceleration + 1], self[R.airspeed + 1], &c)
        var speedHigh = sum.0
        var cycles = 24
        if sum.overflow {
            speedHigh = 0x64
            cycles += 4
        } else {
            cycles += 3
        }
        if FlightModel.negative(speedHigh) {
            speedHigh = 0
            self[R.airspeed] = 0
            cycles += 8
        } else {
            cycles += 3
        }
        self[R.airspeed + 1] = speedHigh
        // $328D: γ += γ rate, then the reflection past ±90°.
        let gamma = u16(R.flightPathAngle) &+ u16(R.gammaRate)
        setU16(R.flightPathAngle, gamma)
        let gammaHigh = UInt8(gamma >> 8)
        if !FlightModel.negative(gammaHigh) {
            charge(cycles + 33)
            reflectFlightPath(gammaHigh)
        } else {
            charge(cycles + 38)
            negateFlightPath()
            charge(6)
            reflectFlightPath(self[R.flightPathAngle + 1])
            negateFlightPath()                   // falls into $32A8, whose return ends the routine
        }
    }

    /// $32A8: γ = −γ (16-bit), as a subroutine and as the tail of `aeroUpdate`. 28 cycles.
    private func negateFlightPath() {
        let R = FlightModel.RAM.self
        setU16(R.flightPathAngle, 0 &- u16(R.flightPathAngle))
        charge(28)
    }

    /// $32BA: with A = γ_hi ≥ $40 (past +90°): γ = $8000 − γ (`negate16`, then the high byte's
    /// top bit flipped), and the bank and heading high bytes flip by 180°. 17 cycles when nothing
    /// happens, else 54 + `negate16`, both including the return (the caller charges its call).
    private func reflectFlightPath(_ high: UInt8) {
        let R = FlightModel.RAM.self
        guard high >= 0x40 else { charge(17); return }
        charge(16)
        let n = negate16(a: self[R.flightPathAngle], x: high)
        self[R.flightPathAngle] = n.a
        self[R.flightPathAngle + 1] = n.x ^ 0x80
        self[R.bankAngle + 1] ^= 0x80
        self[R.heading + 1] ^= 0x80
        charge(38)
    }

    /// $32DF `mulQ15Times4`: `mulQ15AX`(A, X), then the 16-bit product shifted left twice
    /// (exactly, the bits of the low byte carried into the high byte). Returns A = low, X = high
    /// (Y = low << 1, carry = bit 6 of the product's low byte; no caller uses them).
    /// 6 + `mulQ15AX` + 25 or 26 cycles (the caller charges its call).
    func mulQ15Times4(a: UInt8, x: UInt8) -> (a: UInt8, x: UInt8) {
        charge(6)
        let p = mulQ15AX(a: a, x: x)
        let shifted = Machine.word(p.a, p.x) << 2
        charge(16 + (p.a & 0x40 != 0 ? 4 : 3) + 6)
        return (UInt8(truncatingIfNeeded: shifted), UInt8(shifted >> 8))
    }
}
