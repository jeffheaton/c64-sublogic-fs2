/// The engine model $EE6B-$F079 (even phases of the main loop): engine stop and start, the RPM
/// target, thrust, oil temperature and pressure, and fuel burn.
extension Machine {
    /// Cycles of the starter's busy-wait at $EEC0-$EECA: two nested 255-step countdowns whose
    /// inner loop is padded with idle instructions — about 0.57 s of the virtual clock.
    public static let starterBusyWaitCycles = 2 + 254 * 2301 + 2300

    /// $EE6B `engineModel`.
    ///
    /// 1. **Stop** (`engineRunning` = 0, $F074) when, outside war mode and in reality mode, the
    ///    mixture `$0A9A` is 7 or both magneto/fuel pairs (`$EE14` & `$09C7`, `$EE15` & `$09C8`)
    ///    are 0; or when the selected tank (`$09C6`: 0 left `$09C2`, else right `$09C5`) is empty.
    /// 2. **Start**: outside reality mode the engine simply runs. In reality mode a stopped engine
    ///    restarts by windmilling when V_hi ≥ $25; with the magneto switch on START
    ///    (`magnetoLabel` = 4) the starter busy-waits ~0.57 s (charged in 255 steps so the clock
    ///    and its events advance), then `$2837` with X = 3 sets the label to BOTH.
    /// 3. `$BC` = windmill RPM `$EE37`[min(31, V_hi >> 2)]. Effective throttle: 0 when stopped;
    ///    with carb heat −8 (−$20 while `carbHeatCountdown` runs, which it decrements), 0 if
    ///    negative; capped at $10 with failure bits 0-1; −4 (floor 0) when a magneto/fuel pair
    ///    is 0.
    /// 4. `engineTargetRpm` `$0E58` = `$EE17`[throttle >> 2] (0 when stopped). Thrust `$0A48` =
    ///    ((target < $0E ? 0 : target) : 0) × $07D0, × density (`mulQ15Chain`, `mulQ15AX`).
    ///    Then the target becomes `$BC` unless `$BC` − target is negative (N flag), and outside
    ///    reality mode it is at least $0D.
    /// 5. Oil temperature ramps by $19/256 toward 0 (stopped), 9, or 18 (failure bit 0); oil
    ///    pressure by $FA/256 toward 0 (stopped or failure bit 1) or 10. An increase whose high
    ///    byte carries out falls into the decrease (a quirk kept as is).
    /// 6. Fuel (running, `mainLoopCounter` bit 1 set): burn = mul8Half(−5, throttle), ×8 (−40) in
    ///    war mode, into `$A5/$A6`. Leak bit 2 drains the left tank by 1 (floor 0); the selected
    ///    left tank adds the burn to its 24-bit amount `$09C0`:`$09C1`:`leftFuel` (never below
    ///    0). A non-negative burn high byte returns right there. Then leak bit 3 and the right
    ///    tank likewise.
    public func engineModel() {
        let R = FlightModel.RAM.self
        var cycles = 4
        // $EE6B: the reality-mode stop conditions.
        var stop = false
        if self[R.europe1917] != 0 {
            cycles += 3
        } else if self[R.realityMode] == 0 {
            cycles += 9
        } else if self[R.mixture] == 7 {
            cycles += 17
            stop = true
        } else {
            let pair0 = self[R.magnetoState] & self[R.fuelFlags]
            self[R.printValue + 1] = pair0
            let pairs = (self[R.magnetoState + 1] & self[R.fuelFlags + 1]) | pair0
            cycles += 38
            if pairs == 0 { stop = true; cycles += 2 } else { cycles += 3 }
        }
        // $EE94: the selected tank.
        if !stop {
            if self[R.fuelTankSelect] == 0 {
                cycles += 10
                if self[R.leftFuel] == 0 { stop = true; cycles += 3 } else { cycles += 5 }
            } else {
                cycles += 11
                if self[R.rightFuel] == 0 { stop = true; cycles += 3 } else { cycles += 2 }
            }
        }
        if stop {
            // $EE8E: stop the engine ($F074), then on to $EED6.
            self[R.engineRunning] = 0
            cycles += 21
        } else {
            // $EEA5: start or keep running.
            let reality = self[R.realityMode]
            let running = self[R.engineRunning]
            var start = false
            if reality | running == 0 {
                start = true
                cycles += 11
            } else if running != 0 {
                cycles += 17
            } else if self[R.airspeed + 1] >= 0x25 {
                start = true
                cycles += 25
            } else if self[R.magnetoLabel] != 4 {
                cycles += 33
            } else {
                // $EEC0: the starter busy-wait, charged per outer iteration.
                charge(cycles + 34)
                for i in 0..<255 { charge(i < 254 ? 2301 : 2300) }
                charge(8)
                // $2837: magneto label 3 (BOTH) and the labels redraw.
                setMagnetoLabel(3)
                cycles = 0
                start = true
            }
            if start {
                self[R.engineRunning] = 1
                cycles += 6
            }
        }
        // $EED6: the windmill RPM and the effective throttle.
        let speedQuarter = self[R.airspeed + 1] >> 2
        let index: UInt8
        if speedQuarter < 0x1F { index = speedQuarter; cycles += 13 } else { index = 0x1F; cycles += 14 }
        let windmill = self[R.windmillRpmTable + Int(index)]
        self[R.windmillRpm] = windmill
        cycles += 17 + Machine.pageCrossing(R.windmillRpmTable, index)
        var y = self[R.throttle]
        if self[R.engineRunning] == 0 {
            y = 0
            cycles += 6
        } else if self[R.carbHeat] == 0 {
            cycles += 10
        } else {
            var penalty: UInt8 = 0xF8
            if self[R.carbHeatCountdown] == 0 {
                cycles += 18
            } else {
                penalty = 0xE0
                self[R.carbHeatCountdown] &-= 1
                cycles += 24
            }
            y = penalty &+ self[R.throttle]
            if FlightModel.negative(y) { y = 0; cycles += 12 } else { cycles += 11 }
        }
        // $EF09: failure cap.
        if self[R.engineFailureBits] & 0x03 == 0 {
            cycles += 9
        } else {
            cycles += 12
            if y >= 0x10 { y = 0x10; cycles += 4 } else { cycles += 3 }
            cycles += 2
        }
        // $EF18: a dead magneto/fuel pair costs 4.
        let weak: Bool
        if self[R.magnetoState] & self[R.fuelFlags] == 0 {
            weak = true
            cycles += 11
        } else {
            weak = self[R.magnetoState + 1] & self[R.fuelFlags + 1] == 0
            cycles += 18 + (weak ? 2 : 3)
        }
        if weak {
            y = y &- 4
            if FlightModel.negative(y) { y = 0; cycles += 12 } else { cycles += 11 }
        }
        // $EF31: the RPM target and the thrust.
        let row = y >> 2
        var target = self[R.rpmTargetTable + Int(row)]
        cycles += 16 + Machine.pageCrossing(R.rpmTargetTable, row)
        if self[R.engineRunning] == 0 { target = 0; cycles += 4 } else { cycles += 3 }
        self[R.engineTargetRpm] = target
        var thrustRpm = target
        if target < 0x0E { thrustRpm = 0; cycles += 10 } else { cycles += 9 }
        self[R.mathResult + 1] = thrustRpm
        self[R.mathResult] = 0
        charge(cycles + 18)
        mulQ15Chain(a: 0xD0, x: 0x07)
        charge(14)
        let p = mulQ15AX(a: self[R.airDensity], x: self[R.airDensity + 1])
        self[R.thrust] = p.a; self[R.thrust + 1] = p.x
        // $EF64: the shown RPM is the windmill value unless BC − target is negative.
        cycles = 15
        if FlightModel.negative(windmill &- self[R.engineTargetRpm]) {
            cycles += 3
        } else {
            self[R.engineTargetRpm] = windmill
            cycles += 6
        }
        if self[R.realityMode] != 0 {
            cycles += 7
        } else if self[R.engineTargetRpm] >= 0x0D {
            cycles += 15
        } else {
            self[R.engineTargetRpm] = 0x0D
            cycles += 20
        }
        // $EF7F: oil temperature toward 0, 9 or 18.
        var temperatureTarget: UInt8 = 0
        if self[R.engineRunning] == 0 {
            cycles += 9
        } else if self[R.engineFailureBits] & 0x01 == 0 {
            temperatureTarget = 0x09
            cycles += 19
        } else {
            temperatureTarget = 0x12
            cycles += 20
        }
        _ = rampOil(R.oilTemperature, toward: temperatureTarget, step: 0x19, cycles: &cycles)
        // $EFB9: oil pressure toward 0 or 10.
        var pressureTarget: UInt8 = 0
        if self[R.engineRunning] == 0 {
            cycles += 9
        } else if self[R.engineFailureBits] & 0x02 != 0 {
            cycles += 17
        } else {
            pressureTarget = 0x0A
            cycles += 18
        }
        // The carry it leaves (set when already at the target) reaches mul8Half below; with a
        // negative x the multiply ignores it, but it is passed on as the original does.
        let pressureCarry = rampOil(R.oilPressure, toward: pressureTarget, step: 0xFA, cycles: &cycles) ?? true
        // $EFF1: fuel burn on alternate even passes.
        if self[R.engineRunning] == 0 { charge(cycles + 14); return }
        if self[R.mainLoopCounter] & 0x02 == 0 { charge(cycles + 21); return }
        var x: UInt8 = 0xFB
        var carry = pressureCarry
        if self[R.europe1917] == 0 {
            cycles += 22
        } else {
            carry = x & 0x20 != 0                    // the third doubling shifts out bit 5
            x <<= 3
            cycles += 31
        }
        charge(cycles + 10)
        let burn = mul8Half(x: x, y: self[R.throttle], carry: carry)
        self[R.scratchA5] = burn.a
        self[R.scratchA6] = burn.y
        cycles = 12
        // $F012: left leak, then the left tank.
        if self[R.engineFailureBits] & 0x04 == 0 {
            cycles += 3
        } else {
            cycles += 8
            self[R.leftFuel] &-= 1
            if FlightModel.negative(self[R.leftFuel]) { self[R.leftFuel] &+= 1; cycles += 8 } else { cycles += 3 }
        }
        if self[R.fuelTankSelect] == 0 {
            cycles += 6
            var c2 = false
            self[R.leftFuelFraction] = FlightModel.adc(burn.a, self[R.leftFuelFraction], &c2)
            if !FlightModel.negative(burn.y) { charge(cycles + 24); return }
            self[R.leftFuelFraction + 1] = FlightModel.adc(burn.y, self[R.leftFuelFraction + 1], &c2)
            let tank = FlightModel.adc(0xFF, self[R.leftFuel], &c2)
            if FlightModel.negative(tank) {
                cycles += 34
            } else {
                self[R.leftFuel] = tank
                cycles += 37
            }
        } else {
            cycles += 7
        }
        // $F042: right leak, then the right tank.
        if self[R.engineFailureBits] & 0x08 == 0 {
            cycles += 9
        } else {
            cycles += 14
            self[R.rightFuel] &-= 1
            if FlightModel.negative(self[R.rightFuel]) { self[R.rightFuel] &+= 1; cycles += 8 } else { cycles += 3 }
        }
        if self[R.fuelTankSelect] == 0 { charge(cycles + 13); return }
        cycles += 6
        var c3 = false
        self[R.rightFuelFraction] = FlightModel.adc(self[R.scratchA5], self[R.rightFuelFraction], &c3)
        let high = self[R.scratchA6]
        if !FlightModel.negative(high) { charge(cycles + 25); return }
        self[R.rightFuelFraction + 1] = FlightModel.adc(high, self[R.rightFuelFraction + 1], &c3)
        let tank = FlightModel.adc(0xFF, self[R.rightFuel], &c3)
        if FlightModel.negative(tank) {
            cycles += 35
        } else {
            self[R.rightFuel] = tank
            cycles += 38
        }
        charge(cycles + 6)
    }

    /// $EF91-$EFB8 / $EFC9-$EFF0: ramps the 8.8 value at `address` by `step`/256 toward the whole
    /// number `target` (compared with the high byte). Returns the carry it leaves when it moved
    /// (nil when equal, where the comparison leaves it set).
    private func rampOil(_ address: Int, toward target: UInt8, step: UInt8, cycles: inout Int) -> Bool? {
        let high = self[address + 1]
        if target == high { cycles += 7; return nil }
        var c: Bool
        if target > high {
            c = false
            self[address] = FlightModel.adc(self[address], step, &c)
            let sum = FlightModel.adc(high, 0, &c)
            if !c {
                self[address + 1] = sum
                cycles += 33
                return c
            }
            cycles += 28                // the carry out falls into the decrease
        } else {
            cycles += 9
        }
        c = true
        self[address] = FlightModel.sbc(self[address], step, &c)
        self[address + 1] = FlightModel.sbc(high, 0, &c)
        cycles += 22
        return c
    }
}
