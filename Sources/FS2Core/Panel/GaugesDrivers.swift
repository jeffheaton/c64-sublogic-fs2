/// The gauge drivers of the main loop ($CE84-$CFB3) and the altimeter's 10,000-ft marker
/// ($F86F): they turn flight variables into needle angles and marker positions. Literal
/// translation, exact cycles (see `GaugesNeedles.swift`).
extension Gauges {
    /// $0830: MSL altitude (m) = altitude high word + field elevation, computed by $CE84.
    public static let mslAltitude = 0x0830
    /// $0A8A / $0A8B: the altitude bytes $5F/$60 as $CE84 last read them (the glideslope at
    /// $3DB5 reads them back).
    public static let altimeterAltitude = 0x0A8A
    /// $14C2: the airspeed needle angle per 4 units of airspeed high byte (24 entries).
    public static let asiNeedleTable = 0x14C2
    /// $F7DB: the 10,000-ft marker shape currently drawn ($FF = none), and the 9 shape
    /// pointers at $F7DC.
    public static let tenKMarkerState = 0xF7DB
    public static let tenKMarkerPointers = 0xF7DC
}

extension Machine {
    // MARK: altimeterUpdate ($CE84)

    /// $CE84 (every pass, after the draw sequence): the altimeter, when `$FD` bit 3 is set.
    ///
    /// 1. `$0A8A/$0A8B` = `$5F/$60`; MSL altitude `$0830` = `$5F:$60` + field elevation `$0A87`.
    /// 2. `$C4:$C5` = `$0830` + altimeter offset `$09CE`; times $24F4 through `mulQ15AX` ($17EF)
    ///    gives long-hand steps (88 per 1000 ft; 1 m = 0.2887 step).
    /// 3. Reduced mod 880 by subtracting 880 until the high byte goes negative (a negative
    ///    product is kept as it is) into `$A5/$A6`.
    /// 4. Short hand `$20` = 21 - (that × $0CCC >> 15, i.e. / 10), +88 when negative, at most 87.
    /// 5. Long hand `$1F` = 21 - (that mod 88), +88 when negative, at most 87; the mod 88 is a
    ///    subtract loop over the 16-bit value that stops when the high byte goes negative.
    /// 6. Continues straight into `updateAltimeterNeedles` ($1A0B).
    ///
    /// Also writes `$C4/$C5` (the second multiplicand), `$C6/$C7` and the multiply's scratch.
    /// Clobbers A, X, Y.
    public func altimeterUpdate() {
        let m = mem
        var cycles = 5                                  // test the enable bit
        guard m[Gauges.instrumentMask0] & 0x08 != 0 else { charge(cycles + 8); return }
        cycles += 3
        // Latch the altitude for the glideslope, and add the field elevation for MSL altitude.
        m[Gauges.altimeterAltitude] = m[0x5F]
        let (mslLo, carry) = m[0x5F].addingReportingOverflow(m[0x0A87])
        m[Gauges.mslAltitude] = mslLo
        m[Gauges.altimeterAltitude + 1] = m[0x60]
        m[Gauges.mslAltitude + 1] = m[0x60] &+ m[0x0A88] &+ (carry ? 1 : 0)
        cycles += 32
        // The altimeter setting's offset on top; the sum is the multiplicand at $C4/$C5.
        let corrected = UInt16(m[Gauges.mslAltitude]) | UInt16(m[Gauges.mslAltitude + 1]) << 8
        let offset = UInt16(m[0x09CE]) | UInt16(m[0x09CF]) << 8
        let sum = corrected &+ offset
        m[0xC4] = UInt8(sum & 0xFF)
        m[0xC5] = UInt8(sum >> 8)
        cycles += 24
        cycles += 10                                 // set up and call the scaling multiply
        charge(cycles)
        cycles = 0
        let steps = mulQ15AX(a: 0xF4, x: 0x24)
        // $CEBA: the mod-880 loop. Each pass saves the value in $A5/$A6 before subtracting, so
        // the subtraction that goes negative leaves the remainder behind.
        var lo = steps.a, hi = steps.x
        while true {
            m[0xA5] = lo
            m[0xA6] = hi
            let (l, borrow) = lo.subtractingReportingOverflow(0x70)
            let h = hi &- 3 &- (borrow ? 1 : 0)
            cycles += 16
            if h & 0x80 != 0 { cycles += 3; break }
            cycles += 9
            lo = l
            hi = h
        }
        // $CECC: the remainder times $0CCC divides it by 10 for the short hand.
        m[0xC4] = m[0xA5]
        m[0xC5] = m[0xA6]
        cycles += 22
        charge(cycles)
        cycles = 0
        let tenths = mulQ15AX(a: 0xCC, x: 0x0C)
        // Short hand: 21 minus the tenths, folded onto the 88-position dial.
        m[Gauges.altimeterShortHand] = Machine.handAngle(~tenths.a &+ 0x16, &cycles)
        cycles += 3
        // Long hand: the mod-88 loop at $CEF1 takes 88 off the low byte, borrowing from the high
        // byte, until the high byte goes negative; it overshoots by one step of 88.
        var a = m[0xA5]
        var x = m[0xA6]
        cycles += 6
        while true {
            let (r, borrow) = a.subtractingReportingOverflow(0x58)
            a = r
            cycles += 4
            if !borrow { cycles += 3; continue }
            x &-= 1
            cycles += 4
            if x & 0x80 != 0 { cycles += 2; break }
            cycles += 3
        }
        // 21 minus the remainder (the constant also absorbs the overshoot), then on into the
        // needle redraw at $1A0B.
        m[Gauges.altimeterLongHand] = Machine.handAngle(~a &+ 0xBE, &cycles)
        cycles += 6
        charge(cycles + updateAltimeterNeedlesBody())
    }

    /// The tail shared by both altimeter hands: a negative angle wraps up by 88, then an angle of
    /// 88 or more is pinned at 87. Adds its cycles.
    private static func handAngle(_ a: UInt8, _ cycles: inout Int) -> UInt8 {
        var angle = a
        cycles += 6                                 // the complement and add that formed `a`
        if angle & 0x80 == 0 {
            cycles += 3
        } else {
            angle &+= 0x58
            cycles += 6
        }
        cycles += 2                                         // the range test
        if angle < 0x58 { cycles += 3; return angle }
        cycles += 4
        return 0x57
    }

    // MARK: airspeedUpdate ($CF0E)

    /// $CF0E (every pass): the airspeed needle target `$0A84`, when `$FD` bit 0 is set.
    ///
    /// v = min(`$0A4D`, $5A) (airspeed high byte); i = v >> 2; t0 = `$14C2[i]` (into $B8);
    /// d = `$14C2[i+1]` - t0 (8-bit); f = ((v << 1) | bit 7 of `$0A4C`) & 7, an eighth of the
    /// table step; `$0A84` = t0 + high byte of `mul8Half`(x: f·16, y: d, carry: 0), so the
    /// interpolation covers only half the step. `updateAirspeedNeedle` moves the needle there
    /// on the 5 Hz tick. Clobbers A, X, Y.
    public func airspeedUpdate() {
        let m = mem
        var cycles = 5                                  // test the enable bit
        guard m[Gauges.instrumentMask0] & 0x01 != 0 else { charge(cycles + 8); return }
        cycles += 3
        // Clamp the airspeed high byte at the top of the table.
        var v = m[0x0A4D]
        cycles += 6
        if v < 0x5A { cycles += 3 } else { v = 0x5A; cycles += 4 }
        // The table entry for v / 4, and the step from it to the next entry.
        let i = v >> 2
        m[0xB8] = m[Gauges.asiNeedleTable + Int(i)]
        let difference = m[Gauges.asiNeedleTable + 1 + Int(i)] &- m[0xB8]
        cycles += 13 + Machine.pageCrossing(Gauges.asiNeedleTable, i) + 3
            + 4 + Machine.pageCrossing(Gauges.asiNeedleTable + 1, i) + 7
        // The position within the step (v's low two bits and the low byte's top bit), scaled
        // by 16 for the multiply at $1961.
        let fraction = ((v << 1) | (m[0x0A4C] >> 7)) & 0x07
        let x = fraction << 4
        let carry = (fraction << 3) & 0x80 != 0             // the bit the last shift pushes out
        cycles += 30
        charge(cycles)
        let product = mul8Half(x: x, y: difference, carry: carry)
        // Target = table entry + the interpolated part of the step.
        m[Gauges.asiNeedle] = product.y &+ m[0xB8]
        charge(17)
    }

    // MARK: vsiUpdate ($CF46)

    /// $CF46 (phase 1 and 3): the VSI needle target `$21`, when `$FD` bit 7 is set.
    ///
    /// h = vertical speed high byte `$0A51` clamped to -9..9, then doubled twice: the first
    /// shift brings in the clamp compare's carry (1 for h >= 9 and for -9 <= h < 0, else 0), the
    /// second bit 6 of the low byte `$0A50` (a compare of the doubled low byte against $80). The
    /// angle is $83 - that (8-bit), reduced mod 88: zero at 9 o'clock (43), climbs
    /// counterclockwise toward 4, descents toward 79.
    /// `updateVsiNeedle` moves the needle there one step per 5 Hz tick. Clobbers A, Y.
    public func vsiUpdate() {
        let m = mem
        var cycles = 5                                  // test the enable bit
        guard m[Gauges.instrumentMask0] & 0x80 != 0 else { charge(cycles + 8); return }
        cycles += 3
        // The doubled low byte is set aside for later; the clamp depends on the high byte's sign.
        let bit6 = m[0x0A50] & 0x40 != 0                    // what the later compare against $80 sees
        var a = m[0x0A51]
        let carry: Bool
        cycles += 12
        if a & 0x80 == 0 {
            cycles += 4                                 // climbing: test against the upper limit
            if a < 9 {
                carry = false
                cycles += 3
            } else {
                a = 9
                carry = true
                cycles += 7                         // pin at 9
            }
        } else {
            cycles += 5                                 // descending: test against the lower limit
            if a >= 0xF7 {
                carry = true
                cycles += 3
            } else {
                a = 0xF7
                carry = false
                cycles += 4
            }
        }
        // Shift in the two fraction bits, then turn the value into an angle down from $83.
        a = a << 1 | (carry ? 1 : 0)
        a = a << 1 | (bit6 ? 1 : 0)
        a = ~a &+ 0x84
        cycles += 12
        // $CF6E: reduce mod 88 by repeated subtraction; a result of exactly 0 also stops it.
        while true {
            cycles += 2
            if a < 0x58 { cycles += 3; break }
            a &-= 0x58
            cycles += 4
            if a == 0 { cycles += 2; break }
            cycles += 3
        }
        m[Gauges.vsiNeedle] = a
        charge(cycles + 9)
    }

    // MARK: slipBallUpdate ($CF79)

    /// $CF79 (phase 0 and 2): the slip ball, when `$FD` bit 1 is set. Airborne the input is the
    /// slip high byte `$09F3`; on the ground it is 0 at standstill (`$0A4D` = 0), else -rudder
    /// high byte `$0ABD`. Position = ((input + $7F) >> 2) - $1F clamped to -8..8 (9 and up give
    /// 8), plus 9, so 1-17; then on into `drawTurnBall` ($1C3D). Clobbers A, X, Y.
    public func slipBallUpdate() {
        let m = mem
        var cycles = 5                                  // test the enable bit
        guard m[Gauges.instrumentMask0] & 0x02 != 0 else { charge(cycles + 9); return }
        cycles += 6                                     // read the on-ground flag
        var a: UInt8
        if m[0x0A12] == 0 {
            a = m[0x09F3]
            cycles += 9                             // airborne: the slip
        } else {
            a = 0
            cycles += 9                             // on the ground: 0 unless moving
            if m[0x0A4D] == 0 {
                cycles += 3
            } else {
                a = 0 &- m[0x0ABD]
                cycles += 8                         // rolling: the negated rudder
            }
        }
        // Bias, quarter and recenter the input, then clamp it according to its sign.
        a = ((a &+ 0x7F) >> 2) &- 0x1F
        cycles += 12
        if a & 0x80 == 0 {
            cycles += 4                                 // positive: upper limit
            if a < 9 { cycles += 3 } else { a = 8; cycles += 7 }
        } else {
            cycles += 5                                 // negative: lower limit
            if a >= 0xF8 { cycles += 3 } else { a = 0xF8; cycles += 4 }
        }
        // Offset to the 1-17 ball position and hand off to the ball drawer at $1C3D.
        cycles += 7
        charge(cycles + drawTurnBallBody(a &+ 9))
    }

    // MARK: draw10kMarker ($F86F)

    /// $F86F (phase 1): the altimeter's 10,000-ft marker, when `$FD` bit 3 is set.
    ///
    /// index = min(8, ((`$60` + 2) & $FF) / 6), counted by a subtract-6 loop; when it differs
    /// from `$F7DB`, the old shape is erased (unless `$F7DB` is negative: none drawn yet) and the
    /// new one drawn, both through `plotMarkerShape` at (12, 10) with the pointer `$F7DC[2·i]`
    /// (the shapes hold absolute panel coordinates minus that offset). Clobbers A, X, Y.
    public func draw10kMarker() {
        let m = mem
        var cycles = 5                                  // test the enable bit
        guard m[Gauges.instrumentMask0] & 0x08 != 0 else { charge(cycles + 8); return }
        cycles += 3
        // Count how many sixes fit into the altitude high byte plus 2.
        var a = m[0x60] &+ 2
        var x: UInt8 = 0xFF
        cycles += 9
        while true {
            x &+= 1
            let (r, borrow) = a.subtractingReportingOverflow(6)
            a = r
            cycles += 6
            if borrow { cycles += 2; break }
            cycles += 3
        }
        // Cap the index at 8; nothing to do when that shape is already on screen.
        cycles += 2
        if x < 9 { cycles += 3 } else { x = 8; cycles += 4 }
        cycles += 6
        let old = m[Gauges.tenKMarkerState]
        if x == old { charge(cycles + 8); return }
        // Record the new shape; with none drawn yet there is nothing to erase.
        m[Gauges.tenKMarkerState] = x
        cycles += 14
        if old & 0x80 != 0 {
            cycles += 7                                 // nothing to erase
        } else {
            cycles += 10 + draw10kMarkerShape(old) + 4   // plot the old shape again to erase it
        }
        charge(cycles + draw10kMarkerShape(x))
    }

    /// $F89E: fetches shape `index`'s pointer from the table at `$F7DC` and plots it at (12, 10)
    /// through `plotMarkerShape` ($1BC3). Returns its cycles (the plotter's return included).
    private func draw10kMarkerShape(_ index: UInt8) -> Int {
        let x = index << 1
        mem[Gauges.markerShapePtr] = mem[Gauges.tenKMarkerPointers + Int(x)]
        let high = mem[Gauges.tenKMarkerPointers + 1 + Int(x)]
        return 8 + Machine.pageCrossing(Gauges.tenKMarkerPointers, x) + 3
            + 4 + Machine.pageCrossing(Gauges.tenKMarkerPointers + 1, x) + 7
            + plotMarkerShapeBody(0x0C, 0x0A, high)
    }
}
