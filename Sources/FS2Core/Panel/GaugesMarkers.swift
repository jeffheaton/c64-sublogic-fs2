/// The XOR point-list plotter $1D01 and the panel's linear indicators ($1B92-$1D00): control
/// position markers, slip ball, fuel and oil gauges and the fuel-selector marker.
///
/// A point list is `[count][dx, dy] × count`; each point XORs one hi-res pixel. Each indicator
/// keeps the value it was drawn at, and moves by drawing the old value again (erasing it) and
/// then the new one. Literal translation, exact cycles (see `GaugesNeedles.swift`).
extension Gauges {
    /// $9C/$9D: the point list `plotPointList` draws.
    public static let markerShapePtr = 0x9C
    /// $0A90: x bit 8 of the plotter. Each point's `x + dx` carry is added to it and never
    /// cleared, so it accumulates over the points of a list (any nonzero value adds one page).
    public static let markerXHigh = 0x0A90
    /// $0A9F / $0AA0: the plotter's x (low byte) and row origin.
    public static let markerX = 0x0A9F
    public static let markerY = 0x0AA0
    /// $0AA1: the plotter's index into the list.
    public static let markerIndex = 0x0AA1

    /// The value each linear indicator was last drawn at.
    public enum IndicatorState {
        /// $0A93: elevator, drawn at x 108, row 169 + v (shape $0F10).
        public static let elevatorMarker = 0x0A93
        /// $0A94: ailerons, x 93 + v, row 158 (shape $0F1D).
        public static let aileronMarker = 0x0A94
        /// $0A95: the slip ball, x 14 + v, row 190 (shape $0F30).
        public static let turnBall = 0x0A95
        /// $0A96: rudder, x 93 + v, row 196 (shape $0F1D).
        public static let rudderMarker = 0x0A96
        /// $0A97: throttle, x 225, row 198 - v (shape $1612).
        public static let throttleMarker = 0x0A97
        /// $0A98: flaps, x 225, row 115 + v (shape $161B).
        public static let flapsMarker = 0x0A98
        /// $0A99: elevator trim, x 225, row 148 + v (shape $161B).
        public static let trimMarker = 0x0A99
        /// $0A9A: the mixture value itself (the indicator stores it), x 232, row 185 + v.
        public static let mixture = 0x0A9A
        /// $0A9B / $0A9C: left / right fuel, x 260 / 295 + v, row 178 (shape $0F49).
        public static let leftFuelBar = 0x0A9B
        public static let rightFuelBar = 0x0A9C
        /// $0A9D / $0A9E: oil temperature / pressure, x 260 / 295 + v, row 186 (shape $0F49).
        public static let oilTempBar = 0x0A9D
        public static let oilPressureBar = 0x0A9E
    }
}

extension Machine {
    // MARK: plotPointList ($1D01)

    /// $1D01: XORs the point list at ($9C) at x = X (bit 8 in `$0A90`), row = Y.
    ///
    /// `$F3` = count (0 means 256). Per point: x = X + dx with the carry added into `$0A90`
    /// (an add with carry that is never cleared), row = Y + dy (8-bit, through the row tables, so
    /// rows from 200 on read past them); `$8E/$8F` = row base, +$100 when `$0A90` is nonzero; byte
    /// `x & $F8` ^= `$0F08[x & 7]`. Memory: `$0A9F` = X, `$0AA0` = Y, `$0AA1` = list index,
    /// `$F3` = 0, `$0A90`, `$8E/$8F` = the last point's row pointer. Clobbers A, X, Y.
    public func plotPointList(x: UInt8, y: UInt8) {
        charge(plotPointListBody(x, y))
    }

    @usableFromInline
    func plotPointListBody(_ x: UInt8, _ y: UInt8) -> Int {
        let m = mem
        m[Gauges.markerX] = x
        m[Gauges.markerY] = y
        m[0xF3] = m[zpPointer(Gauges.markerShapePtr)]
        m[Gauges.markerIndex] = 1
        // Save the origin, take the point count from the list's first byte, start at pair one.
        var cycles = 24
        while true {
            // x = origin + dx; the carry piles up in $0A90 (see `markerXHigh`).
            let i = m[Gauges.markerIndex]
            var list = zpPointer(Gauges.markerShapePtr)
            let (px, carry) = m[(list + Int(i)) & 0xFFFF].addingReportingOverflow(m[Gauges.markerX])
            m[Gauges.markerXHigh] = m[Gauges.markerXHigh] &+ (carry ? 1 : 0)
            cycles += 9 + Machine.pageCrossing(list, i) + 18
            // row = origin + dy; the index moves on to the next pair.
            let i1 = i &+ 1
            list = zpPointer(Gauges.markerShapePtr)
            let dy = m[(list + Int(i1)) & 0xFFFF]
            m[Gauges.markerIndex] = i1 &+ 1
            let row = dy &+ m[Gauges.markerY]
            cycles += 7 + Machine.pageCrossing(list, i1) + 14
            // The row's bitmap address from the row tables, one page further when x is past 255.
            m[0x8F] = m[Machine.rowAddressHi + Int(row)]
            m[0x8E] = m[Machine.rowAddressLo + Int(row)]
            cycles += 11 + Machine.pageCrossing(Machine.rowAddressLo, row) + 7
            if m[Gauges.markerXHigh] == 0 {
                cycles += 3
            } else {
                m[0x8F] &+= 1
                cycles += 7
            }
            // Flip the pixel: the 8-pixel cell that holds x, and x's bit within it.
            let column = px & 0xF8
            let base = zpPointer(0x8E)
            let address = (base + Int(column)) & 0xFFFF
            m[address] = m[address] ^ m[Gauges.bitMasksMSBFirst + Int(px & 7)]
            cycles += 17 + Machine.pageCrossing(base, column) + 10
            // Count the point off; done after the last one.
            m[0xF3] &-= 1
            cycles += 5
            if m[0xF3] == 0 { return cycles + 8 }      // with the return
            cycles += 3
        }
    }

    /// $1BC3: `$9D` = `shapeHigh` (the caller has put the low byte in `$9C`), `$0A90` = 0, then
    /// `plotPointList` at (x, row). The 10,000-ft marker ($F8AC) and the localizer needles
    /// ($3D80) enter here too. Clobbers A, X, Y.
    public func plotMarkerShape(x: UInt8, y: UInt8, shapeHigh: UInt8) {
        charge(plotMarkerShapeBody(x, y, shapeHigh))
    }

    @usableFromInline
    func plotMarkerShapeBody(_ x: UInt8, _ y: UInt8, _ shapeHigh: UInt8) -> Int {
        mem[Gauges.markerShapePtr + 1] = shapeHigh
        return 5 + plotMarkerShapeXHighBody(x, y, 0)    // store the high byte, x bit 8 = 0
    }

    /// $1BC7: `$0A90` = A, then on into `plotPointList` ($1D01).
    private func plotMarkerShapeXHighBody(_ x: UInt8, _ y: UInt8, _ xHigh: UInt8) -> Int {
        mem[Gauges.markerXHigh] = xHigh
        return 7 + plotPointListBody(x, y)
    }

    // MARK: Linear indicators

    /// The shared frame of the indicators: the new value waits on the stack while the old one is
    /// drawn, then is stored, and the code falls through into `draw` again. Draws the old value
    /// (erasing it), stores `value`, draws it.
    private func moveIndicator(_ state: Int, _ value: UInt8, _ draw: (UInt8) -> Int) -> Int {
        var cycles = 13 + draw(mem[state])           // set the new value aside, draw the old one
        mem[state] = value
        cycles += 8                                     // store the new value
        return cycles + draw(value)
    }

    /// $1B92: moves the elevator marker (shape $0F10 at x 108, row $A9 + A) to A, from `$0A93`.
    /// The caller ($2D69) passes ($50 - elevator high byte) >> 3. Clobbers A, X, Y.
    public func drawElevatorIndicator(_ value: UInt8) {
        charge(moveIndicator(Gauges.IndicatorState.elevatorMarker, value) { v in
            // $1B9D: shape $0F10 at x 108, row $A9 + v.
            self.mem[Gauges.markerShapePtr] = 0x10
            return 18 + self.plotMarkerShapeBody(0x6C, v &+ 0xA9, 0x0F)
        })
    }

    /// $1BBD: selects shape $0F1D and falls into $1BC3, which plots it at (x, row).
    private func drawControlPointerBody(_ x: UInt8, _ y: UInt8) -> Int {
        mem[Gauges.markerShapePtr] = 0x1D
        return 7 + plotMarkerShapeBody(x, y, 0x0F)
    }

    /// $1BAC: moves the aileron marker (shape $0F1D at x $5D + A, row 158) to A, from `$0A94`.
    /// The caller ($2DF7) passes (aileron high byte + $7F) >> 3. Clobbers A, X, Y.
    public func drawAileronIndicator(_ value: UInt8) {
        charge(moveIndicator(Gauges.IndicatorState.aileronMarker, value) { v in
            // $1BB7: x $5D + v, row 158; falls into the shared pointer drawer at $1BBD.
            8 + self.drawControlPointerBody(v &+ 0x5D, 0x9E)
        })
    }

    /// $1BCD: moves the rudder marker (shape $0F1D at x $5D + A, row 196) to A, from `$0A96`.
    /// The caller ($2E55) passes (rudder high byte + $7F) >> 3. Clobbers A, X, Y.
    public func drawRudderIndicator(_ value: UInt8) {
        charge(moveIndicator(Gauges.IndicatorState.rudderMarker, value) { v in
            // $1BD8: x $5D + v, row 196; this one has to jump to $1BBD.
            11 + self.drawControlPointerBody(v &+ 0x5D, 0xC4)
        })
    }

    /// $1BE1: moves the throttle marker (shape $1612 at x 225, row $C6 - A) to A, from `$0A97`.
    /// The caller ($2C4C) passes throttle >> 3. Clobbers A, X, Y.
    public func drawThrottleIndicator(_ value: UInt8) {
        charge(moveIndicator(Gauges.IndicatorState.throttleMarker, value) { v in
            // $1BEC: shape $1612 at x 225, row $C6 - v (more throttle draws higher up).
            self.mem[Gauges.markerShapePtr] = 0x12
            return 20 + self.plotMarkerShapeBody(0xE1, ~v &+ 0xC7, 0x16)
        })
    }

    /// $1C33: plots shape $161B at (x, row) through $1BC3; shared by flaps, trim and mixture.
    private func drawSliderMarkerBody(_ x: UInt8, _ y: UInt8) -> Int {
        mem[Gauges.markerShapePtr] = 0x1B
        return 12 + plotMarkerShapeBody(x, y, 0x16)
    }

    /// $1BFD: moves the flaps marker (shape $161B at x 225, row $73 + A) to A, from `$0A98`.
    /// The caller ($2CDB) passes the flaps high byte >> 4. Clobbers A, X, Y.
    public func drawFlapsIndicator(_ value: UInt8) {
        charge(moveIndicator(Gauges.IndicatorState.flapsMarker, value) { v in
            // $1C08: x 225, row $73 + v.
            9 + self.drawSliderMarkerBody(0xE1, v &+ 0x73)
        })
    }

    /// $1C10: moves the trim marker (shape $161B at x 225, row $94 + A) to A, from `$0A99`.
    /// The caller ($2CBE) passes ($50 - trim) >> 4. Clobbers A, X, Y.
    public func drawTrimIndicator(_ value: UInt8) {
        charge(moveIndicator(Gauges.IndicatorState.trimMarker, value) { v in
            // $1C1B: x 225, row $94 + v.
            9 + self.drawSliderMarkerBody(0xE1, v &+ 0x94)
        })
    }

    /// $1C23: sets the mixture `$0A9A` to A and moves its marker (shape $161B at x 232, row
    /// $B9 + A). Callers ($E9F0, $EA25) step it by one within 0-7. Clobbers A, X, Y.
    public func drawMixtureIndicator(_ value: UInt8) {
        charge(moveIndicator(Gauges.IndicatorState.mixture, value) { v in
            // $1C2E: x 232, row $B9 + v; falls straight into $1C33.
            6 + self.drawSliderMarkerBody(0xE8, v &+ 0xB9)
        })
    }

    /// $1C3D: moves the slip ball (shape $0F30 at x $0E + A, row 190) to A when it differs from
    /// `$0A95`. Entered by a jump (not a call) from `slipBallUpdate` with A = 1-17. Clobbers A,
    /// X, Y.
    public func drawTurnBall(_ value: UInt8) {
        charge(drawTurnBallBody(value))
    }

    @usableFromInline
    func drawTurnBallBody(_ value: UInt8) -> Int {
        // Nothing to do when the ball has not moved.
        if value == mem[Gauges.IndicatorState.turnBall] { return 12 }
        return 7 + moveIndicator(Gauges.IndicatorState.turnBall, value) { v in
            // $1C4E: shape $0F30 at x $0E + v, row 190.
            self.mem[Gauges.markerShapePtr] = 0x30
            return 18 + self.plotMarkerShapeBody(v &+ 0x0E, 0xBE, 0x0F)
        }
    }

    // MARK: Fuel and oil gauges

    /// $1C8F (row 178) / $1CD7 (row 186): the bar shape $0F49 at x = 256 + A + 4. `$0A90` starts
    /// at 1 for the right half of the screen, and the carry of A + 4 makes it 2.
    private func drawEngineBarBody(_ a: UInt8, row: UInt8) -> Int {
        let (x, carry) = a.addingReportingOverflow(4)
        mem[Gauges.markerXHigh] = carry ? 2 : 1
        // $1C9C: point at the bar shape and plot it.
        mem[Gauges.markerShapePtr] = 0x49
        mem[Gauges.markerShapePtr + 1] = 0x0F
        let jump = row == 0xB2 ? 0 : 3                      // $1CD7 jumps to the shared tail
        return 16 + jump + 13 + plotPointListBody(x, row)
    }

    /// $1C5D (phase 0): moves the left fuel bar to `$09C2` >> 1 when it differs from `$0A9B`
    /// (x 260 + v, row 178). Clobbers A, X, Y.
    public func drawLeftFuelGauge() {
        let value = mem[0x09C2] >> 1
        var cycles = 10                              // fetch, halve, compare
        if value == mem[Gauges.IndicatorState.leftFuelBar] {
            cycles += 8
        } else {
            cycles += 6                                 // the branch; the jump to $1C8F later
            cycles += moveIndicator(Gauges.IndicatorState.leftFuelBar, value) { v in
                self.drawEngineBarBody(v, row: 0xB2)
            }
        }
        charge(cycles)
    }

    /// $1C75 (phase 1): moves the right fuel bar to `$09C5` >> 1 when it differs from `$0A9C`
    /// (x 295 + v: the stored value plus $23, row 178). Clobbers A, X, Y.
    public func drawRightFuelGauge() {
        charge(drawRightEngineBar(mem[0x09C5] >> 1, extraLoad: 2, state: Gauges.IndicatorState.rightFuelBar,
                                  row: 0xB2))
    }

    /// $1CA7 (phase 2): moves the oil temperature bar to `$09CB` when it differs from `$0A9D`
    /// (x 260 + v, row 186). Clobbers A, X, Y.
    public func drawOilTempGauge() {
        let value = mem[0x09CB]
        var cycles = 8                                  // fetch, compare
        if value == mem[Gauges.IndicatorState.oilTempBar] {
            cycles += 8
        } else {
            cycles += 6                                 // the branch; the jump to $1CD7 later
            cycles += moveIndicator(Gauges.IndicatorState.oilTempBar, value) { v in
                self.drawEngineBarBody(v, row: 0xBA)
            }
        }
        charge(cycles)
    }

    /// $1CBE (phase 3): moves the oil pressure bar to `$09CD` when it differs from `$0A9E`
    /// (x 295 + v, row 186). Clobbers A, X, Y.
    public func drawOilPressureGauge() {
        charge(drawRightEngineBar(mem[0x09CD], extraLoad: 0, state: Gauges.IndicatorState.oilPressureBar,
                                  row: 0xBA))
    }

    /// The right-hand bars ($1C75, $1CBE): their own copy of the indicator frame that adds $23
    /// to both the old and the new value to reach the right-hand column; the second draw falls
    /// into the bar. `extraLoad` is the fuel gauge's halving shift.
    private func drawRightEngineBar(_ value: UInt8, extraLoad: Int, state: Int, row: UInt8) -> Int {
        let m = mem
        var cycles = 4 + extraLoad + 4                      // fetch, (halve), compare
        if value == m[state] { return cycles + 9 }      // unchanged: return
        cycles += 19                     // set the new value aside, offset the old one, draw
        cycles += drawEngineBarBody(m[state] &+ 0x23, row: row)
        m[state] = value
        cycles += 12                             // store the new value and offset it
        return cycles + drawEngineBarBody(value &+ 0x23, row: row)
    }

    /// $1CF0: XORs the fuel-selector marker (shape $1CE7) at x 287, row 179. The tank-select keys
    /// ($295F, $2AA5) call it once per change: it toggles, with no state of its own.
    /// Clobbers A, X, Y.
    public func drawFuelSelectorMarker() {
        // Shape $1CE7 at x 256 + $1F, row $B3, through the entry at $1BC7 that takes x bit 8.
        mem[Gauges.markerShapePtr] = 0xE7
        mem[Gauges.markerShapePtr + 1] = 0x1C
        charge(19 + plotMarkerShapeXHighBody(0x1F, 0xB3, 1))
    }
}
