/// Ground elevation tracking $F8AF, the maneuver-regime timer $F916, the crash and splash
/// message $F95D, splash detection $F996 and the altitude set $F9C1.
extension Machine {
    /// $F8AF `trackGroundElevation` (every pass, in the draw sequence): below V_hi $0A the field
    /// elevation `$0A87` jumps to the target `$0843`. Then, twice, a step: if the target differs
    /// (unsigned 16-bit compare), `fieldElevation` moves 1 m toward it and the altitude meters
    /// `$5F:$60` move 1 m the other way (MSL stays), with a floor of 3 m.
    public func trackGroundElevation() {
        let R = FlightModel.RAM.self
        if self[R.airspeed + 1] < 0x0A {
            self[R.fieldElevation] = self[R.terrainElevationTarget]
            self[R.fieldElevation + 1] = self[R.terrainElevationTarget + 1]
            charge(30)
        } else {
            charge(23)
        }
        stepFieldElevation()       // $F8C5 as a subroutine
        stepFieldElevation()       // then falls into $F8C5, whose return ends the routine
    }

    /// $F8C5: one step of `trackGroundElevation`, including its return.
    private func stepFieldElevation() {
        let R = FlightModel.RAM.self
        let target = u16(R.terrainElevationTarget), field = u16(R.fieldElevation)
        let targetHi = UInt8(target >> 8), fieldHi = UInt8(field >> 8)
        var cycles = 14
        let down: Bool
        if targetHi < fieldHi {
            down = true
            cycles += 5
        } else if targetHi != fieldHi {
            down = false
            cycles += 5
        } else if UInt8(target & 0xFF) < UInt8(field & 0xFF) {
            down = true
            cycles += 13
        } else if target == field {
            charge(cycles + 20)
            return
        } else {
            down = false
            cycles += 15
        }
        // $F8DE: field += ±1, then the altitude meters −= ±1 (Y = ~Y).
        setU16(R.fieldElevation, field &+ (down ? 0xFFFF : 0x0001))
        cycles += 2 + (down ? 3 : 4) + 26 + (down ? 4 : 3)
        let meters = Machine.word(self[R.altitude + 1], self[R.altitude + 2]) &+ (down ? 0x0001 : 0xFFFF)
        self[R.altitude + 1] = UInt8(meters & 0xFF)
        self[R.altitude + 2] = UInt8(meters >> 8)
        cycles += 16
        if meters & 0x8000 != 0 {
            cycles += 3
        } else if meters >> 8 != 0 {
            charge(cycles + 11)
            return
        } else if meters & 0xFF >= 3 {
            charge(cycles + 18)
            return
        } else {
            cycles += 11
        }
        // $F90D: the 3 m floor.
        self[R.altitude + 1] = 3
        self[R.altitude + 2] = 0
        charge(cycles + 16)
    }

    /// $F916 `maneuverRegimeTimer` (even phases): counts `maneuverTimer` down; once it would go
    /// negative it is reloaded with 6 instead while |γ_hi| ≥ $0F (~21°), |bank_hi| ≥ $16 (~31°)
    /// or V_hi ≥ $49 (~73 m/s) (each test is (v + k) mod 256 ≥ 2k).
    public func maneuverRegimeTimer() {
        let R = FlightModel.RAM.self
        let next = self[R.maneuverTimer] &- 1
        if !FlightModel.negative(next) {
            self[R.maneuverTimer] = next
            charge(18)
            return
        }
        var cycles = 9
        var reload = true
        if self[R.flightPathAngle + 1] &+ 0x0F >= 0x1E {
            cycles += 13
        } else if self[R.bankAngle + 1] &+ 0x16 >= 0x2C {
            cycles += 25
        } else if self[R.airspeed + 1] &+ 0x49 >= 0x92 {
            cycles += 36
        } else {
            reload = false
            cycles += 37
        }
        if reload {
            self[R.maneuverTimer] = 6
            cycles += 6
        }
        charge(cycles + 6)
    }

    /// $F95D `crashMessage` (alternate passes while `crashCode` is set; A = `crashCode`): the
    /// text pointer `$BA/$BB` = 'SPLASH !!!' ($F950) for code 8, else 'CRASH !!!' ($F944);
    /// sound state 2 and `sfxCrash`, `crashCode` = 0, `clearWindow`, the text at (50, 20), the
    /// `busyDelay` with Y = 5 (2,283,560 cycles, about 2.2 s), then `modeRequest` = 1 (reload the
    /// mode).
    public func crashMessage(code: UInt8) {
        let R = FlightModel.RAM.self
        let record = code == 0x08 ? R.splashRecord : R.crashRecord
        self[R.tablePtr] = UInt8(record & 0xFF)
        self[R.tablePtr + 1] = UInt8(record >> 8)
        self[R.soundState] = 2
        charge((code == 0x08 ? 17 : 15) + 12)
        sfxCrash()
        self[R.crashCode] = 0
        charge(12)
        clearWindow()
        charge(12)
        drawTextRecord(Machine.word(self[R.tablePtr], self[R.tablePtr + 1]))
        charge(8)
        busyDelay(y: 5)
        self[R.modeRequest] = 1
        charge(12)
    }

    /// $F996 `splashDetect` (even phases): on the ground, with the window bitmap byte `$50DE`
    /// (y 110, x 152-159) showing the water pattern $55, in the front view, not in radar view and
    /// not repositioning, `splashCounter` `$0E7F` counts down; when it reaches 0, `crashCode` = 8.
    /// Any other pass reloads the counter with 3. It reads the rendered frame, so the bitmap must
    /// be the original's layout.
    public func splashDetect() {
        let R = FlightModel.RAM.self
        var cycles = 4
        var reset = true
        if self[R.onGround] == 0 {
            cycles += 3
        } else if self[R.splashProbe] != 0x55 {
            cycles += 11
        } else if self[R.viewDirection] != 0 {
            cycles += 17
        } else if self[R.radarMode] != 0 {
            cycles += 23
        } else if self[R.repositionCounter] != 0 {
            cycles += 29
        } else {
            cycles += 34
            self[R.splashCounter] &-= 1
            if self[R.splashCounter] != 0 {
                reset = false
                cycles += 3
            } else {
                self[R.crashCode] = 8
                cycles += 8
            }
        }
        if reset {
            self[R.splashCounter] = 3
            cycles += 6
        }
        charge(cycles + 6)
    }

    /// $F9C1 `setAltitudeFromEditor` (also vector $2006; every pass while `repositionCounter`
    /// runs): altitude meters = (`settingAltitude` + 9) × $4E0C >> 16 (feet to meters, through
    /// `mulU16`) − `fieldElevation`, at least 3; `$5E` and `$61` = 0.
    public func setAltitudeFromEditor() {
        let R = FlightModel.RAM.self
        setU16(R.mathResult, u16(R.settingAltitude) &+ 9)
        charge(30)
        let p = mulU16(a: 0x0C, x: 0x4E)
        var c = true
        var y = FlightModel.sbc(p.x, self[R.fieldElevation], &c)
        var a = FlightModel.sbc(self[R.product32 + 3], self[R.fieldElevation + 1], &c)
        var cycles = 17
        if FlightModel.negative(a) {
            cycles += 7
            a = 0; y = 3
        } else if a != 0 {
            cycles += 5
        } else if y >= 3 {
            cycles += 9
        } else {
            cycles += 12
            a = 0; y = 3
        }
        self[R.altitude + 1] = y
        self[R.altitude + 2] = a
        self[R.altitude + 3] = 0
        self[R.altitude] = 0
        charge(cycles + 20)
    }
}
