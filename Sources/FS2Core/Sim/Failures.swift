import C64Kit

/// Reality-mode failures and drifts $EA84-$EB1B, the trim creep $EAE2, and the eight failure
/// handlers $EB39-$EB62 dispatched through the table at $EA5C.
extension Machine {
    /// $EA84 `realityFailures` (phase 3). Outside reality mode it zeroes `altimeterOffset` and
    /// `dgOffset` (33 cycles). In reality mode:
    ///
    /// 1. `failureCountdown` `$08CD` counts down; when it goes negative it is reloaded with 10, and
    ///    if (north+1 + east+1 + **the caller's carry**) mod 256 is < 100 and ≥ `reliability`, a
    ///    failure triggers ($EB1B): `clearWindow`, the aircraft-problem message at (50, 20), then
    ///    handler ((mainLoopCounter + altitude+1 + C) & $0E) / 2 of the table at $EA5C, C being
    ///    the carry `drawTextRecord` returns. The pointer goes through `$BC/$BD` (indirect jump).
    /// 2. Altimeter drift, comparing quirkily: with h = altimeterOffset_hi − altimeterDrift_lo,
    ///    `altimeterOffset` += 2 when h is negative, −= 2 when h | altimeterOffset_lo ≠ 0, else
    ///    stays (`$B8` = altimeterOffset_lo).
    /// 3. `dgOffset` += 2.
    ///
    /// - Parameter carry: the carry flag at the call (left by the oil pressure gauge $1CBE).
    public func realityFailures(carry: Bool) {
        let R = FlightModel.RAM.self
        guard self[R.realityMode] != 0 else {
            for address in [R.altimeterOffset, R.altimeterOffset + 1, R.dgOffset, R.dgOffset + 1] {
                self[address] = 0
            }
            charge(33)
            return
        }
        let countdown = self[R.failureCountdown] &- 1
        self[R.failureCountdown] = countdown
        if !FlightModel.negative(countdown) {
            charge(16)
        } else {
            self[R.failureCountdown] = 0x0A
            var c = carry
            let sum = FlightModel.adc(self[R.northPosition + 1], self[R.eastPosition + 1], &c)
            if sum >= 0x64 {
                charge(32)
            } else if sum < self[R.reliability] {
                charge(38)
            } else {
                charge(43)
                triggerFailure()
            }
        }
        // $EAA6: the altimeter drift.
        let offsetLo = self[R.altimeterOffset]
        self[R.printValue] = offsetLo
        var c = true
        let h = FlightModel.sbc(self[R.altimeterOffset + 1], self[R.altimeterDrift], &c)
        var cycles = 21
        var step: UInt16? = nil
        if FlightModel.negative(h) {
            step = 0x0002
            cycles += 7
        } else if h | offsetLo == 0 {
            cycles += 8
        } else {
            step = 0xFFFE
            cycles += 14
        }
        if let step {
            setU16(R.altimeterOffset, u16(R.altimeterOffset) &+ step)
            cycles += 20
        }
        // $EAD3: the DG drift.
        let dg = u16(R.dgOffset)
        setU16(R.dgOffset, dg &+ 2)
        cycles += 12 + ((dg & 0xFF) >= 0xFE ? 8 : 3)
        charge(cycles + 6)
    }

    /// $EB1B: the failure trigger (see `realityFailures`). The handler returns to $EAA6.
    private func triggerFailure() {
        let R = FlightModel.RAM.self
        charge(6)
        clearWindow()
        charge(10)
        var c = drawTextRecord(FlightModel.RAM.aircraftProblemRecord)
        let index = FlightModel.adc(self[R.mainLoopCounter], self[R.altitude + 1], &c) & 0x0E
        let table = R.failureHandlers
        let lo = self[table + Int(index)], hi = self[table + 1 + Int(index)]
        self[R.windmillRpm] = lo
        self[R.windmillRpm + 1] = hi
        charge(29 + Machine.pageCrossing(table, index) + Machine.pageCrossing(table + 1, index))
        runFailureHandler(Machine.word(lo, hi))
    }

    /// Runs the failure handler at `address` (one of the eight the table at $EA5C holds), with its
    /// cycles, return included: $EB39/$EB4B/$EB4F/$EB57/$EB5B/$EB5F clear bit 0/2/3/5/6/7 of
    /// `failureMasks` `$0942` (instrument failures), $EB42 sets bits 0-1 and $EB53 bits 2-3 of
    /// `engineFailureBits` `$09BF` (engine; fuel leaks).
    private func runFailureHandler(_ address: UInt16) {
        let R = FlightModel.RAM.self
        switch address {
        case 0xEB39: self[R.failureMasks] &= 0xFE; charge(16)
        case 0xEB42: self[R.engineFailureBits] |= 0x03; charge(16)
        case 0xEB4B: self[R.failureMasks] &= 0xFB; charge(19)
        case 0xEB4F: self[R.failureMasks] &= 0xF7; charge(19)
        case 0xEB53: self[R.engineFailureBits] |= 0x0C; charge(19)
        case 0xEB57: self[R.failureMasks] &= 0xDF; charge(19)
        case 0xEB5B: self[R.failureMasks] &= 0xBF; charge(19)
        case 0xEB5F: self[R.failureMasks] &= 0x7F; charge(19)
        default:
            preconditionFailure("failure handler table entry $\(hex(address, width: 4)) is not a handler")
        }
    }

    /// $EAE2 `trimCreep` (1 Hz tick, even TOD seconds): in reality mode the elevator high byte
    /// moves 2 toward `elevatorTrim` (the signed comparison uses the overflow flag), then the
    /// elevator indicator is refreshed (`$2D58`). 15 cycles outside reality mode.
    public func trimCreep() {
        let R = FlightModel.RAM.self
        guard self[R.realityMode] != 0 else { charge(15); return }
        let elevator = self[R.elevator + 1]
        var c = true
        let d = FlightModel.sbcV(elevator, self[R.elevatorTrim], &c)
        var cycles = 19
        var newValue: UInt8? = nil
        if d.overflow {
            if !FlightModel.negative(d.0) {
                newValue = elevator &+ 2
                cycles += 16
            } else {
                newValue = elevator &- 4 &+ 2
                cycles += 25
            }
        } else if d.0 == 0 {
            cycles += 7
        } else if FlightModel.negative(d.0) {
            newValue = elevator &+ 2
            cycles += 19
        } else {
            newValue = elevator &- 4 &+ 2
            cycles += 25
        }
        if let newValue { self[R.elevator + 1] = newValue }
        charge(cycles + 6)
        updateElevatorIndicator()
        charge(6)
    }
}
