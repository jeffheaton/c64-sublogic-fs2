/// Wind: the drift applied every pass $E716 and the layer selection $E766 (phase 0).
extension Machine {
    /// $E716 `windDrift` (every pass after `integrateFlight`): when airborne, east −=
    /// `windDriftEast` and north −= `windDriftNorth`, each sign-extended to 32 bits through
    /// `$A5` (left holding the north sign byte). 13 cycles on the ground, else 116-118.
    public func windDrift() {
        let R = FlightModel.RAM.self
        guard self[R.onGround] == 0 else { charge(13); return }
        let east = s16(R.windDriftEast), north = s16(R.windDriftNorth)
        self[R.scratchA5] = east < 0 ? 0xFF : 0x00
        setS32(R.eastPosition, s32(R.eastPosition) &- Int32(east))
        self[R.scratchA5] = north < 0 ? 0xFF : 0x00
        setS32(R.northPosition, s32(R.northPosition) &- Int32(north))
        charge(12 + (east < 0 ? 4 : 3) + 49 + (north < 0 ? 4 : 3) + 49)
    }

    /// $E766 `windLayer` (phase 0): picks the wind record by the altitude meters `$5F:$60`
    /// (signed compares): ≥ `shear3` → `wind3` `$0994`, ≥ `shear2` → `wind2` `$0998`,
    /// ≥ `shear1` → `wind1` `$099C`, else `surfaceWind` `$09A0` (which also increments `$09D7`).
    /// `$C0/$C1` = the record. The direction is record[3] + `headingOffsetA`_hi, then `$09D7`
    /// is shifted right; when the bit shifted out is 1 (normally only for the surface layer) the
    /// direction also gets + `headingOffsetB`_hi. With s = sin8(dir)_hi in `$A5`, c = cos8(dir)_hi
    /// in `$A7` and the speed record[0]:
    ///
    ///     windDriftEast  = mul8Half(dt_hi, mul8x8(speed, s)_hi)
    ///     windDriftNorth = mul8Half(dt_hi, mul8x8(speed, c)_hi)
    ///
    /// with the carries chained from `cos8` through the four multiplies, as in the original.
    public func windLayer() {
        let R = FlightModel.RAM.self
        let meters = (lo: self[R.altitude + 1], hi: self[R.altitude + 2])
        func below(_ bound: Int) -> Bool {
            var c = meters.lo >= self[bound]
            return FlightModel.negative(FlightModel.sbc(meters.hi, self[bound + 1], &c))
        }
        let record: UInt16
        var cycles: Int
        if below(R.shear1) {
            record = 0x09A0
            self[R.windSurfaceFlag] &+= 1
            cycles = 27
        } else if below(R.shear2) {
            record = 0x099C
            cycles = 40
        } else if below(R.shear3) {
            record = 0x0998
            cycles = 56
        } else {
            record = 0x0994
            cycles = 55
        }
        self[R.recordPointer] = UInt8(record & 0xFF)
        self[R.recordPointer + 1] = UInt8(record >> 8)
        let base = Int(record)
        // $E7AA: the record's direction byte plus the area's heading offset, then the
        // surface-layer flag is consumed.
        var c = false
        var direction = FlightModel.adc(self[base + 3], self[R.headingOffsetA + 1], &c)
        let flag = self[R.windSurfaceFlag]
        self[R.windSurfaceFlag] = flag >> 1
        cycles += 25 + Machine.pageCrossing(base, 3)
        if flag & 1 != 0 {
            c = false
            direction = FlightModel.adc(direction, self[R.headingOffsetB + 1], &c)
            cycles += 8
        } else {
            cycles += 3
        }
        charge(cycles + 9)
        let s = sin8(a: direction)
        self[R.scratchA5] = s.x
        charge(13)
        let cosine = cos8(a: direction)
        self[R.scratchA7] = cosine.x
        let speed = self[base]
        charge(24 + Machine.pageCrossing(base, 0))
        var m = mul8x8(x: speed, y: self[R.scratchA5], carry: cosine.carry)
        charge(10)
        var h = mul8Half(x: self[R.frameDt + 1], y: m.y, carry: m.carry)
        self[R.windDriftEast] = h.a; self[R.windDriftEast + 1] = h.y
        charge(23)
        m = mul8x8(x: speed, y: self[R.scratchA7], carry: h.carry)
        charge(10)
        h = mul8Half(x: self[R.frameDt + 1], y: m.y, carry: m.carry)
        self[R.windDriftNorth] = h.a; self[R.windDriftNorth + 1] = h.y
        charge(14)
    }
}
