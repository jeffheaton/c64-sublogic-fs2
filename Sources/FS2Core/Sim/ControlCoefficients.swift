/// The control-derived coefficient builders $2E92-$2F3F, run by the key handlers after a control
/// change (rudder and aileron keys at $2E1E/$2E58, flaps at $2CF7).
extension Machine {
    /// $2E92 `controlCoefficients`: rebuilds the slip terms, then falls into
    /// `rebuildWingCoefficients`.
    ///
    /// - `slip+1` (`$09F3`) = (ailerons_hi ASR 1) − (rudder_hi ASR 1), 8-bit. The low byte `$09F2`
    ///   is never written but is read by the products below.
    /// - `slipDrag` `$0A15` = (0 : slip_hi) × `$0A70`, then `slipYaw` `$09F4` = slip × `$0A68`,
    ///   `slipTrackOffset` `$0A46` = slip × `$0A6A`, `slipRoll` `$09F6` = slip × `$0A66` (Q15).
    /// - `$B9` = rudder_hi ASR 1.
    ///
    /// The incoming A only travels through the two `asr16` calls into Y; nothing stored depends on
    /// it. 172 cycles + 2 × `asr16` (20) + 4 × `mulQ15AX` + `rebuildWingCoefficients` (90).
    public func controlCoefficients() {
        let R = FlightModel.RAM.self
        // $2E92: halve the rudder and aileron high bytes; the halved rudder is kept in $B9.
        charge(10)
        let halfRudder = asr16(a: 0, x: self[R.rudder + 1]).x
        self[R.printValue + 1] = halfRudder
        charge(13)
        let halfAileron = asr16(a: 0, x: self[R.ailerons + 1]).x
        // $2EA0: the slip high byte is the difference of the halves; it is also the first
        // multiplicand, with a zero low byte.
        let slipHigh = halfAileron &- halfRudder
        self[R.slip + 1] = slipHigh
        self[R.mathResult + 1] = slipHigh
        self[R.mathResult] = 0
        charge(33)
        var p = mulQ15AX(a: self[R.slipDragFactor], x: self[R.slipDragFactor + 1])
        self[R.slipDrag] = p.a; self[R.slipDrag + 1] = p.x
        // The three remaining products start from the whole slip word (low byte as found).
        for (factor, destination) in [(R.slipYawFactor, R.slipYaw), (R.slipTrackFactor, R.slipTrackOffset),
                                      (R.slipRollFactor, R.slipRoll)] {
            self[R.mathResult] = self[R.slip]
            self[R.mathResult + 1] = self[R.slip + 1]
            charge(36)
            p = mulQ15AX(a: self[factor], x: self[factor + 1])
            self[destination] = p.a; self[destination + 1] = p.x
        }
        charge(8)   // store slipRoll, then fall into $2F07
        rebuildWingCoefficients()
    }

    /// $2F07 `rebuildWingCoefficients`: with base = `flapLift` + `liftCoefficient0`,
    /// `liftCoefficientRight` `$0A23` = base − `aileronCoefficient` and `liftCoefficientLeft`
    /// `$0A21` = base + `aileronCoefficient` + `slipRoll` (16-bit, wrapping). A positive aileron
    /// (H, roll right) adds lift on the left wing. Leaves A = left high byte, X/Y = the
    /// intermediate base + aileron bytes. 90 cycles.
    public func rebuildWingCoefficients() {
        let R = FlightModel.RAM.self
        let base = u16(R.flapLift) &+ u16(R.liftCoefficient0)
        let aileron = u16(R.aileronCoefficient)
        setU16(R.liftCoefficientRight, base &- aileron)
        setU16(R.liftCoefficientLeft, base &+ aileron &+ u16(R.slipRoll))
        charge(90)
    }
}
