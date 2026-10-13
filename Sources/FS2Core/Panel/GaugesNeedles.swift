/// The XOR needles of the round gauges ($1A0B-$1B91): the drawer $1A86 and the three drivers that
/// erase the old needle and draw the new one (altimeter $1A0B, airspeed $1A32, VSI $1A6A).
///
/// A needle is drawn by XOR into the hi-res panel bitmap through the row tables, so drawing the
/// same needle twice erases it, and two needles that overlap (the altimeter hands) cancel where
/// they cross. The drivers keep the angle each needle was last drawn at in `needleAngles` ($0F62)
/// and erase by redrawing that angle.
///
/// The port is a literal translation: every byte the original reads is read from `mem` at the
/// moment the original reads it (registers become locals), and it charges the original's exact
/// cycle count, including the routine's own return but not the caller's subroutine call.
public enum Gauges {
    /// $0F62: the angle (0-87, the airspeed needle also beyond) each of the five needles was last
    /// drawn at: altimeter long hand, altimeter short hand, airspeed, VSI, ADF.
    public static let needleAngles = 0x0F62
    /// $0F67 / $0F6C: needle center x / row per gauge (hi-res pixels; rows through the row tables).
    public static let needleCenterX = 0x0F67
    public static let needleCenterY = 0x0F6C
    /// $0F71: needle type per gauge: 0 = long (shape table $0F76), otherwise short ($0FA6).
    public static let needleType = 0x0F71
    /// $0F76 / $0FA6: 23 run-length shape pointers per needle type, one per angle of a quadrant.
    public static let longNeedleShapes: UInt16 = 0x0F76
    public static let shortNeedleShapes: UInt16 = 0x0FA6
    /// $0F08: MSB-first bit masks 80..01 (hi-res pixel x & 7 -> bit), used by every XOR plot here.
    public static let bitMasksMSBFirst = 0x0F08
    /// $0A8C / $0A8D: the angle and gauge `drawNeedle` was called with.
    public static let needleAngleArg = 0x0A8C
    public static let needleGaugeArg = 0x0A8D
    /// $0A8E: pixels left in the current run of a needle scanline.
    public static let needleRunCount = 0x0A8E
    /// $0A84: the airspeed needle's target angle, written by `airspeedUpdate` ($CF0E).
    public static let asiNeedle = 0x0A84
    /// $1F / $20 / $21: altimeter long hand, short hand and VSI target angles.
    public static let altimeterLongHand = 0x1F
    public static let altimeterShortHand = 0x20
    public static let vsiNeedle = 0x21
    /// $FD / $FE / $FF: the instrument enable masks (see `updateInstrumentMasks`).
    public static let instrumentMask0 = 0xFD

    /// The self-modified code bytes of the needle scanline loop ($1B4B-$1B91).
    public enum NeedlePatch {
        /// $1B56: the carry setup before the x offset: the clear-carry opcode $18 on the right
        /// half, the set-carry opcode $38 on the left.
        public static let carryOpcode = 0x1B56
        /// $1B59: the opcode that applies the shape's x offset to the center: an add ($71) or a
        /// subtract ($F1), both reading the shape through ($96) indexed by Y.
        public static let offsetOpcode = 0x1B59
        /// $1B87: the X increment ($E8) or decrement ($CA) opcode: the direction a run is drawn in.
        public static let stepOpcode = 0x1B87
        /// $1B8D: the opcode that steps the row counter `$A7`: a decrement ($C6, upper half) or
        /// an increment ($E6, lower half).
        public static let rowStepOpcode = 0x1B8D
    }

    /// The quadrant a needle angle falls in, which selects the mirroring the drawer patches into
    /// its scanline loop. Angles run counterclockwise from 3 o'clock, 88 per turn.
    public enum NeedleQuadrant: Sendable, Equatable {
        /// 0-21: right and up, shape index = angle.
        case rightUp
        /// 22-43: left and up, shape index = 44 - angle.
        case leftUp
        /// 44-65: left and down, shape index = angle - 44.
        case leftDown
        /// 66-87 (and anything larger): right and down, shape index = 88 - angle (8-bit).
        case rightDown

        public init(angle: UInt8) {
            switch angle {
            case 0x42...: self = .rightDown
            case 0x2C...: self = .leftDown
            case 0x16...: self = .leftUp
            default: self = .rightUp
            }
        }

        /// Runs are drawn rightwards (x counts up, x = center - 1 + offset) on the right half.
        public var rightward: Bool { self == .rightUp || self == .rightDown }
        /// Rows step upwards (`$A7` counts down, first row = center + 1) on the upper half.
        public var upward: Bool { self == .rightUp || self == .leftUp }

        /// The shape index for `angle` (the original's 8-bit arithmetic, so it wraps for angles
        /// of 88 and up).
        public func shapeIndex(_ angle: UInt8) -> UInt8 {
            switch self {
            case .rightUp: return angle
            case .leftUp: return 0x2C &- angle
            case .leftDown: return angle &- 0x2C
            case .rightDown: return 0x58 &- angle
            }
        }
    }
}

extension Machine {
    // MARK: drawNeedle ($1A86)

    /// $1A86: XORs needle `gauge` (0-4) at `angle` into the panel bitmap.
    ///
    /// The shape table is $0F76 (long) or $0FA6 (short) by `$0F71[gauge]` (pointer in $94/$95);
    /// the center comes from $0F67/$0F6C into $A5/$A7. The quadrant (see `NeedleQuadrant`) patches
    /// the scanline loop: on the right half x = ($A5 - 1) + offset with runs drawn rightwards
    /// (the loop adds the offset and counts x up; `$E8 = $A5 + $FE`), on the left
    /// x = ($A5 + 1) - offset drawn leftwards (it subtracts and counts x down;
    /// `$E8 = $A5 + $EC`); the upper half starts on row $A7 + 1 and steps up (`$A7` counts down;
    /// `$E9 = $A7 + $EC`), the lower half starts on $A7 - 1 and steps down (`$A7` counts up;
    /// `$E9` = that row). The shape pointer `[$94 + 2·index]` goes to $96/$97; each scanline is
    /// (x offset, run length) and a byte with bit 7 set ends the shape. A run XORs `$0F08[x & 7]`
    /// into byte `x & $F8` of the row (x is 8 bits: the needles live left of x = 256); a run
    /// length of 0 means 256.
    ///
    /// Memory: $0A8C = angle, $0A8D = gauge, $94-$97, $9A/$9B = row base, $A5/$A7, $E8 = last x,
    /// $E9 = shape index of the end byte, $0A8E = 0, the four patched opcodes. Does not write
    /// `needleAngles`. Clobbers A, X, Y.
    public func drawNeedle(angle: UInt8, gauge: UInt8) {
        charge(drawNeedleBody(angle, gauge))
    }

    /// `drawNeedle` without the charge; returns its cycles (the return included).
    @usableFromInline
    func drawNeedleBody(_ angle: UInt8, _ gauge: UInt8) -> Int {
        let m = mem
        let x = Int(gauge)
        m[Gauges.needleAngleArg] = angle
        m[Gauges.needleGaugeArg] = gauge
        m[0x94] = 0x76
        m[0x95] = 0x0F
        // Save the arguments, assume the long shape table, then check the gauge's needle type.
        var cycles = 22 + Machine.pageCrossing(Gauges.needleType, gauge)
        if m[Gauges.needleType + x] == 0 {
            cycles += 3                                     // long needle: keep the default
        } else {
            m[0x94] = 0xA6
            m[0x95] = 0x0F
            cycles += 12
        }
        m[0xA5] = m[Gauges.needleCenterX + x]
        m[0xA7] = m[Gauges.needleCenterY + x]
        cycles += 4 + Machine.pageCrossing(Gauges.needleCenterX, gauge) + 3
            + 4 + Machine.pageCrossing(Gauges.needleCenterY, gauge) + 3
        // The quadrant: the angle is tested against each quadrant's start, highest first.
        let a = m[Gauges.needleAngleArg]
        let quadrant = Gauges.NeedleQuadrant(angle: a)
        cycles += 6
        switch quadrant {
        case .rightDown:
            cycles += 3                                     // the first test hits
            cycles += 6 + needleRightHalf() + 6 + needleLowerHalf()
            cycles += 8                             // index = 88 - angle
        case .leftDown:
            cycles += 7
            cycles += 6 + needleLeftHalf() + 6 + needleLowerHalf()
            cycles += 11                         // index = angle - 44, on to the lookup
        case .leftUp:
            cycles += 11
            cycles += 6 + needleLeftHalf() + 6 + needleUpperHalf()
            cycles += 11                         // index = 44 - angle, on to the lookup
        case .rightUp:
            cycles += 10
            cycles += 6 + needleRightHalf() + 6 + needleUpperHalf()
            cycles += 7                                 // index = angle, on to the lookup
        }
        let index = quadrant.shapeIndex(m[Gauges.needleAngleArg])
        // $1AF0: the shape pointer for the index into $96/$97, then on to the loop at $1B4B.
        let y = index << 1
        let table = zpPointer(0x94)
        m[0x96] = m[(table + Int(y)) & 0xFFFF]
        cycles += 9 + Machine.pageCrossing(table, y) + 3
        let y1 = y &+ 1
        let table1 = zpPointer(0x94)
        m[0x97] = m[(table1 + Int(y1)) & 0xFFFF]
        cycles += 7 + Machine.pageCrossing(table1, y1) + 6
        return cycles + drawNeedleScanlines(quadrant)
    }

    /// $1AFE: the right half: patches the loop to add the offset and step x up, sets
    /// `$E8 = $A5 + $FE`, and moves the center one pixel left. Returns its cycles (the return
    /// included).
    private func needleRightHalf() -> Int {
        let m = mem
        m[Gauges.NeedlePatch.stepOpcode] = 0xE8
        m[0xE8] = m[0xA5] &+ 0xFE
        m[Gauges.NeedlePatch.carryOpcode] = 0x18
        m[Gauges.NeedlePatch.offsetOpcode] = 0x71
        m[0xA5] &-= 1
        return 39
    }

    /// $1B17: the left half: patches the loop to subtract the offset and step x down, sets
    /// `$E8 = $A5 + $EC`, and moves the center one pixel right. Returns its cycles (the return
    /// included).
    private func needleLeftHalf() -> Int {
        let m = mem
        m[Gauges.NeedlePatch.stepOpcode] = 0xCA
        m[0xE8] = m[0xA5] &+ 0xEC
        m[Gauges.NeedlePatch.carryOpcode] = 0x38
        m[Gauges.NeedlePatch.offsetOpcode] = 0xF1
        m[0xA5] &+= 1
        return 39
    }

    /// $1B30: the upper half: patches the row step to count `$A7` down, sets `$E9 = $A7 + $EC`,
    /// and starts one row past the center. Returns its cycles (the return included).
    private func needleUpperHalf() -> Int {
        let m = mem
        m[Gauges.NeedlePatch.rowStepOpcode] = 0xC6
        m[0xE9] = m[0xA7] &+ 0xEC
        m[0xA7] &+= 1
        return 27
    }

    /// $1B3F: the lower half: patches the row step to count `$A7` up, starts one row before the
    /// center, and sets `$E9` to that row. Returns its cycles (the return included).
    private func needleLowerHalf() -> Int {
        let m = mem
        m[Gauges.NeedlePatch.rowStepOpcode] = 0xE6
        m[0xA7] &-= 1
        m[0xE9] = m[0xA7]
        return 23
    }

    /// $1B4B: the scanline loop of the shape at ($96), with the mirroring the quadrant patched in.
    /// Returns its cycles up to and including the return on the end byte.
    private func drawNeedleScanlines(_ quadrant: Gauges.NeedleQuadrant) -> Int {
        let m = mem
        let rightward = quadrant.rightward
        let upward = quadrant.upward
        m[0xE9] = 0
        var cycles = 5                                  // start at the shape's first byte
        /// A read of the shape at ($96) + y: the byte and the read's cycles (5, +1 across a page).
        func shapeByte(_ y: UInt8) -> (value: UInt8, cycles: Int) {
            let shape = zpPointer(0x96)
            return (m[(shape + Int(y)) & 0xFFFF], 5 + Machine.pageCrossing(shape, y))
        }
        while true {
            // $1B4F: a byte with bit 7 set ends the shape.
            let y = m[0xE9]
            let first = shapeByte(y)
            cycles += 3 + first.cycles
            if first.value & 0x80 != 0 { return cycles + 8 }    // end byte: return
            cycles += 3
            // $1B56: the patched start x, the center plus or minus the offset.
            let offset = shapeByte(y)
            m[0xE8] = rightward ? m[0xA5] &+ offset.value : m[0xA5] &- offset.value
            cycles += 5 + offset.cycles + 3
            // The run length, and the index of the next scanline.
            let y1 = y &+ 1
            let run = shapeByte(y1)
            m[Gauges.needleRunCount] = run.value
            m[0xE9] = y1 &+ 1
            cycles += 2 + run.cycles + 9
            // The current row's bitmap address from the row tables.
            let row = m[0xA7]
            m[0x9A] = m[Machine.rowAddressLo + Int(row)]
            m[0x9B] = m[Machine.rowAddressHi + Int(row)]
            cycles += 7 + Machine.pageCrossing(Machine.rowAddressLo, row) + 13
            var px = m[0xE8]
            while true {
                // $1B74: flip one pixel, step x in the patched direction, count the run down.
                m[0xE8] = px
                let column = px & 0xF8
                let base = zpPointer(0x9A)
                let address = (base + Int(column)) & 0xFFFF
                m[address] = m[address] ^ m[Gauges.bitMasksMSBFirst + Int(px & 7)]
                cycles += 20 + Machine.pageCrossing(base, column) + 10
                px = m[0xE8]
                px = rightward ? px &+ 1 : px &- 1
                m[Gauges.needleRunCount] &-= 1
                cycles += 11
                if m[Gauges.needleRunCount] == 0 { cycles += 2; break }
                cycles += 3
            }
            // The patched row step, then back for the next scanline.
            if upward { m[0xA7] &-= 1 } else { m[0xA7] &+= 1 }
            cycles += 8
        }
    }

    // MARK: Needle drivers

    /// $1A0B: redraws the altimeter hands when the long hand's target `$1F` differs from the angle
    /// it was drawn at (`$0F62`; the short hand is not compared). Erases the long hand, then the
    /// short hand, then draws the short hand at `$20` and the long hand at `$1F`, storing each
    /// new angle into `needleAngles` first. Entered by a jump from `altimeterUpdate`.
    /// Clobbers A, X, Y.
    public func updateAltimeterNeedles() {
        charge(updateAltimeterNeedlesBody())
    }

    @usableFromInline
    func updateAltimeterNeedlesBody() -> Int {
        let m = mem
        let long = Gauges.needleAngles, short = Gauges.needleAngles + 1
        var cycles = 9                              // the long hand's drawn angle against its target
        let old = m[long]
        if old == m[Gauges.altimeterLongHand] { return cycles + 8 }
        cycles += 3
        cycles += 6 + drawNeedleBody(old, 0)
        cycles += 6                                     // the short hand's drawn angle
        cycles += 6 + drawNeedleBody(m[short], 1)
        // Short hand: store the new angle and draw it, calling the helper at $1A2B.
        let newShort = m[Gauges.altimeterShortHand]
        m[short] = newShort
        cycles += 22 + drawNeedleBody(newShort, 1) + 6
        // Long hand: the same, but falling into $1A2B instead of calling it.
        let newLong = m[Gauges.altimeterLongHand]
        m[long] = newLong
        cycles += 16 + drawNeedleBody(newLong, 0) + 6
        return cycles
    }

    /// $1A32 (5 Hz tick, $23B4): moves the airspeed needle a quarter of the way toward its target.
    ///
    /// Only when `$FD` bit 0 is set and `$0F64` differs from the target `$0A84`. The old angle
    /// (kept in $B8) is erased, then the new angle is old + (target - old) >> 2 (8-bit difference,
    /// arithmetic shift) + 1 when that quotient is not negative, so the needle always reaches the
    /// target. The stored angle is not wrapped (the targets from $14C2 exceed 87); only the drawn
    /// one is: angles of 88 and more are drawn at angle - 88 ($1A61). Clobbers A, X, Y.
    public func updateAirspeedNeedle() {
        charge(updateAirspeedNeedleBody())
    }

    @usableFromInline
    func updateAirspeedNeedleBody() -> Int {
        let m = mem
        let state = Gauges.needleAngles + 2
        var cycles = 5                                  // test the enable bit
        if m[Gauges.instrumentMask0] & 1 == 0 { return cycles + 9 }
        cycles += 12                             // the drawn angle against the target
        let old = m[state]
        if old == m[Gauges.asiNeedle] { return cycles + 9 }
        cycles += 2
        m[0xB8] = old
        cycles += 9 + drawAirspeedNeedleWrapped(old)    // keep the old angle in $B8, erase it
        // A quarter of the signed difference: each halving copies the sign back in by
        // comparing the difference with $80 first.
        let difference = m[Gauges.asiNeedle] &- m[0xB8]
        var step = UInt8(bitPattern: Int8(bitPattern: difference) >> 2)
        cycles += 21
        if step & 0x80 == 0 {
            cycles += 3                                     // not negative: as it is
        } else {
            step &-= 1
            cycles += 4                                 // negative: one less, canceling the +1
        }
        step &+= 1
        // The new angle = old + step + 1, stored unwrapped.
        let angle = step &+ m[0xB8]
        m[state] = angle
        cycles += 16
        return cycles + drawAirspeedNeedleWrapped(angle)
    }

    /// $1A61: draws needle 2 (X = 2 at both callers) at A, less 88 when A >= 88, by jumping into
    /// the drawer. Returns its cycles, the drawer's return included.
    private func drawAirspeedNeedleWrapped(_ a: UInt8) -> Int {
        if a < 0x58 { return 8 + drawNeedleBody(a, 2) }   // in range: straight to the drawer
        return 9 + drawNeedleBody(a &- 0x58, 2)       // wrap it first
    }

    /// $1A6A (5 Hz tick, $23B7): moves the VSI needle one step toward its target `$21`.
    ///
    /// When `$0F65` differs from `$21`, the old needle is erased and the angle moves by one:
    /// down when it was above the target, up otherwise (an unsigned compare: the VSI's targets
    /// stay in 4..79, so it never takes the long way round). Stores the new angle and draws it.
    /// Clobbers A, X, Y.
    public func updateVsiNeedle() {
        charge(updateVsiNeedleBody())
    }

    @usableFromInline
    func updateVsiNeedleBody() -> Int {
        let m = mem
        let state = Gauges.needleAngles + 3
        var cycles = 9                              // the drawn angle against the target
        let old = m[state]
        let target = m[Gauges.vsiNeedle]
        if old == target { return cycles + 9 }
        let above = old >= target                           // the compare's carry, kept on the stack
        cycles += 8                                 // save the flags and the angle
        cycles += 6 + drawNeedleBody(old, 3)
        cycles += 8                                     // restore them
        var angle = old
        if above {
            angle &-= 2
            cycles += 6                             // above: -2, so the +1 below nets -1
        } else {
            cycles += 3
        }
        angle &+= 1
        cycles += 9                             // +1, then a branch to the helper at $1A2B
        m[state] = angle
        return cycles + 11 + drawNeedleBody(angle, 3) + 6     // the helper's store, draw, return
    }
}
