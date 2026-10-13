/// The navigation geometry of $3B32-$3F89: the vector from a station to the aircraft, its
/// direction (an octant arctangent through the table at $3AF1) and length (max + min²/2max),
/// the course deflection and its TO/FROM classification, and the needle positions.
///
/// Units: positions are the 32-bit 1/256 m coordinates; the station-to-aircraft vector is kept
/// in 16 m units (bytes 1-3 of the difference shifted left by 4, upper 16 bits); angles are
/// binary ($10000 = 360°). Literal translation with exact cycles (see `Panel/Readouts.swift`).
public enum Nav {
    /// $09BA/$09BB: north (Z) distance from the station to the aircraft, in 16 m units (s16).
    public static let stationDeltaNorth = 0x09BA
    /// $09BC/$09BD: east (X) distance, 16 m units (s16).
    public static let stationDeltaEast = 0x09BC
    /// $3AF1: arctangent table, 17 words: atan(i/16) as a binary angle (0..$2000 = 45°).
    public static let arcTable = 0x3AF1
    /// $3B13: the localizer needle point list (a 2-pixel-wide vertical bar).
    public static let localizerNeedleShape: UInt16 = 0x3B13
    /// $0850/$0851: glideslope reference, written by the scenery (op 25 in the ILS boxes) and
    /// cleared by $3DA2 every odd pass after use.
    public static let glideslopeReference = 0x0850
    /// $0852/$0853: localizer course (binary angle), written by the scenery with the localizer.
    public static let localizerCourse = 0x0852
    /// $09AF / $09B0: NAV1 localizer needle as drawn / its target (0-30; drawn = negative: none).
    public static let nav1NeedleDrawn = 0x09AF
    public static let nav1NeedleTarget = 0x09B0
    /// $09B1 / $09B2: NAV2 needle as drawn / target.
    public static let nav2NeedleDrawn = 0x09B1
    public static let nav2NeedleTarget = 0x09B2
    /// $09B3 / $09B4: glideslope bar as drawn / target (0-18).
    public static let glideslopeDrawn = 0x09B3
    public static let glideslopeTarget = 0x09B4
    /// $09B5 / $09B6: NAV1 / NAV2 TO/FROM state (0 OFF, 1 TO, 2 FR); $09B7 / $09B8 as drawn.
    public static let nav1ToFrom = 0x09B5
    public static let nav2ToFrom = 0x09B6
    public static let nav1ToFromDrawn = 0x09B7
    public static let nav2ToFromDrawn = 0x09B8
    /// $084C / $084E / $084A: outer / middle / inner marker flags (set by scenery boxes,
    /// consumed by $3EFC, which shifts them right).
    public static let outerMarkerFlag = 0x084C
    public static let middleMarkerFlag = 0x084E
    public static let innerMarkerFlag = 0x084A
    /// $7E7B-$7E7D: the O/M/I lamp color cells.
    public static let markerLampCells = 0x7E7B
    /// $0969: Europe 1917 (no marker beacons in war mode).
    public static let europe1917 = 0x0969
    /// $0E59: the sound driver's effect state (5/6/7 = outer/middle/inner marker).
    public static let soundState = 0x0E59
}

extension Machine {
    // MARK: stationBearing ($3C8F)

    /// $3C8F: the direction from station `X` (0 = record A $0927, 8 = record B $092F) to the
    /// aircraft.
    ///
    /// 1. dN = north bytes 1-3 (`$63-$65`) - station +5..+7, shifted left 4 (24-bit, $3D18):
    ///    `$09BA/$09BB` = its upper 16 bits (16 m units), also `$BC/$BD`, low byte `$B9`.
    ///    dE likewise from `$5B-$5D` and +1..+3: `$09BC/$09BD`, `$BA/$BB`, `$BF`. `$C0` and `$C2`
    ///    are scratch.
    /// 2. Normalization ($3CDB): while both high bytes are within -16..16, both 24-bit values
    ///    shift left once; north shifts in a 1 at the bottom, east a 0.
    /// 3. angle = `vectorAngle` ($3E46) of (east `$BA/$BB`, north `$BC/$BD`); `$B8/$B9` = angle -
    ///    `$0848` - `$0846` (the area offsets, so the result is in the panel's frame).
    ///
    /// Returns the carry of the final subtraction (the ADF code at $E817 subtracts the heading
    /// without setting the carry first, so it depends on this one).
    @discardableResult
    public func stationBearing(station x: UInt8) -> Bool {
        let m = mem
        let s = Int(x)
        // North: aircraft minus station over bytes 1-3 (the fraction byte is left out).
        let (n0, k0) = Readouts.sbc(m[0x63], m[Radio.navStationA + 5 + s], true)
        let (n1, k1) = Readouts.sbc(m[0x64], m[Radio.navStationA + 6 + s], k0)
        m[0xC0] = n1
        let (n2, _) = Readouts.sbc(m[0x65], m[Radio.navStationA + 7 + s], k1)
        var c = 9 + Machine.pageCrossing(Radio.navStationA + 5, x) + 2
            + 7 + Machine.pageCrossing(Radio.navStationA + 6, x) + 3
            + 7 + Machine.pageCrossing(Radio.navStationA + 7, x)
        m[0xC2] = x
        let north = Machine.shiftLeft4(lo: n0, mid: m[0xC0], hi: n2)
        c += 138                                // keep the station index, shift by 4 ($3D18)
        m[Nav.stationDeltaNorth + 1] = north.hi
        m[Nav.stationDeltaNorth] = north.mid
        m[0xBD] = north.hi
        m[0xBC] = north.mid
        m[0xB9] = north.lo
        c += 17
        // East: the same with the east bytes.
        let t = Int(m[0xC2])
        let (e0, j0) = Readouts.sbc(m[0x5B], m[Radio.navStationA + 1 + t], true)
        let (e1, j1) = Readouts.sbc(m[0x5C], m[Radio.navStationA + 2 + t], j0)
        m[0xC0] = e1
        let (e2, _) = Readouts.sbc(m[0x5D], m[Radio.navStationA + 3 + t], j1)
        c += 12 + Machine.pageCrossing(Radio.navStationA + 1, m[0xC2]) + 2
            + 7 + Machine.pageCrossing(Radio.navStationA + 2, m[0xC2]) + 3
            + 7 + Machine.pageCrossing(Radio.navStationA + 3, m[0xC2])
        let east = Machine.shiftLeft4(lo: e0, mid: m[0xC0], hi: e2)
        c += 135
        m[Nav.stationDeltaEast + 1] = east.hi
        m[Nav.stationDeltaEast] = east.mid
        m[0xBB] = east.hi
        m[0xBA] = east.mid
        m[0xBF] = east.lo
        c += 17
        // $3CDB: normalize while both high bytes are in -16..16.
        while true {
            c += 9                              // north's high byte + 16, tested against 33
            if m[0xBD] &+ 0x10 >= 0x21 { c += 3; break }
            c += 11
            if m[0xBB] &+ 0x10 >= 0x21 { c += 3; break }
            c += 2
            let nl = m[0xB9], nm = m[0xBC], nh = m[0xBD]
            m[0xB9] = nl << 1 | 1
            m[0xBC] = nm << 1 | nl >> 7
            m[0xBD] = nh << 1 | nm >> 7
            let el = m[0xBF], em = m[0xBA], eh = m[0xBB]
            m[0xBF] = el << 1
            m[0xBA] = em << 1 | el >> 7
            m[0xBB] = eh << 1 | em >> 7
            c += 2 + 5 * 6 + 3                              // set the carry, six shifts, loop
        }
        charge(c + 6)                                       // call the angle routine
        let angle = vectorAngle()
        // Into the panel's frame: take off both area offsets.
        let (a0, b0) = Readouts.sbc(angle.lo, m[Readouts.headingOffsetB], true)
        let (a1, _) = Readouts.sbc(angle.hi, m[Readouts.headingOffsetB + 1], b0)
        let (r0, b2) = Readouts.sbc(a0, m[Readouts.headingOffsetA], true)
        m[0xB8] = r0
        let (r1, carry) = Readouts.sbc(a1, m[Readouts.headingOffsetA + 1], b2)
        m[0xB9] = r1
        charge(42)
        return carry
    }

    /// $3D18: shifts the 24-bit value A:X:Y (A high) left by 4 (the one-bit shift at $3D21 is
    /// called three times, then run a fourth time by falling into it): 126 cycles, the return
    /// included.
    @inline(__always)
    static func shiftLeft4(lo: UInt8, mid: UInt8, hi: UInt8) -> (lo: UInt8, mid: UInt8, hi: UInt8) {
        let v = (UInt32(hi) << 16 | UInt32(mid) << 8 | UInt32(lo)) << 4
        return (UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF))
    }

    // MARK: vectorAngle ($3E46-$3EFB)

    /// $3E46: the binary angle of the vector (east `$BA/$BB`, north `$BC/$BD`), clockwise from
    /// north. A negative east is negated in place ($3EEE) and the result negated; a negative
    /// north likewise, with the result negated and turned by 180°; then $3E6B works in the first
    /// quadrant. Returns A = low, X = high.
    public func vectorAngle() -> (lo: UInt8, hi: UInt8) {
        guard mem[0xBB] & 0x80 != 0 else { charge(6); return vectorAngleNorth() }
        charge(13)                               // east negative: negate it in place ($3EEE)
        negateZeroPageWord(0xBA)
        charge(6)                                           // call the north stage
        let r = vectorAngleNorth()
        charge(3)                                           // jump on into the negation at $19D5
        let n = negate16(a: r.lo, x: r.hi)
        return (n.a, n.x)
    }

    /// $3E55: the north sign (see `vectorAngle`).
    private func vectorAngleNorth() -> (lo: UInt8, hi: UInt8) {
        guard mem[0xBD] & 0x80 != 0 else { charge(6); return vectorAngleQuadrant() }
        charge(13)                               // north negative: negate it in place
        negateZeroPageWord(0xBC)
        charge(6)                                           // call the quadrant stage
        let r = vectorAngleQuadrant()
        charge(6)                                           // negate the result ($19D5)
        let n = negate16(a: r.lo, x: r.hi)
        charge(16)                       // turn it by 180°: flip the high byte's top bit
        return (n.a, n.x ^ 0x80)
    }

    /// $3E6B: first quadrant. When east < north (unsigned 16-bit): atan(east/north) by $3E9F.
    /// Otherwise (equal: east is first incremented) the two are swapped in memory and the angle
    /// is $4000 - atan(north/east) (`negate16`, + $40 on the high byte).
    private func vectorAngleQuadrant() -> (lo: UInt8, hi: UInt8) {
        let m = mem
        let a = m[0xBA], x = m[0xBB]
        var c = 9                                   // compare the high bytes
        var direct: Bool
        if x < m[0xBD] {
            c += 3; direct = true                           // east smaller: straight to $3E9F
        } else {
            c += 2
            if x != m[0xBD] {
                c += 3; direct = false                      // east larger: swap first ($3E81)
            } else {
                c += 5                                  // equal: compare the low bytes
                if a < m[0xBC] {
                    c += 3; direct = true
                } else {
                    c += 2
                    if a != m[0xBC] {
                        c += 3; direct = false
                    } else {
                        // Equal: bump east, so the swapped ratio stays below 1.
                        c += 7
                        m[0xBA] &+= 1
                        if m[0xBA] != 0 { c += 3 } else { c += 7; m[0xBB] &+= 1 }
                        direct = false
                    }
                }
            }
        }
        if direct {
            charge(c)
            return arctanRatio()                            // reached by a branch, so its return is ours
        }
        // $3E81: swap the words.
        let ba = m[0xBA], bc = m[0xBC]
        m[0xBC] = ba
        m[0xBA] = bc
        let bb = m[0xBB], bd = m[0xBD]
        m[0xBD] = bb
        m[0xBB] = bd
        charge(c + 8 * 3 + 6)                               // the swap, then the call to $3E9F
        let r = arctanRatio()
        charge(6)                                           // negate ($19D5)
        let n = negate16(a: r.lo, x: r.hi)
        charge(18)                   // add 90° on the high byte
        return (n.a, n.x &+ 0x40)
    }

    /// $3E9F: atan(`$BA/$BB` / `$BC/$BD`) for a ratio below 1, as a binary angle (0..$2000).
    ///
    /// q = `divQ15` (Q15). The table index is bits 11-14 of q (`$C5` >> 2 & $FE, a word offset);
    /// the interpolation fraction is built as `$C4` = q low >> 3 and `$C5` = (q high bits 1-2) << 4
    /// + that, which drops bit 8 of q (bit 0 of `$C5`). result = t[i] - frac × (t[i] - t[i+1])
    /// computed as ~((frac × (t[i] - t[i+1]) through `mulQ15AX`) - t[i]). `$C0/$C1` = t[i].
    private func arctanRatio() -> (lo: UInt8, hi: UInt8) {
        let m = mem
        m[0xC6] = m[0xBC]
        m[0xC7] = m[0xBD]
        charge(24)                   // north is the divisor, east the dividend
        divQ15(a: m[0xBB], x: m[0xBA])
        let y = (m[0xC5] >> 2) & 0xFE
        m[0xC4] = m[0xC4] >> 3
        m[0xC5] = ((m[0xC5] << 4) & 0x60) &+ m[0xC4]
        let t = Nav.arcTable
        let t0lo = m[t + Int(y)]
        m[0xC0] = t0lo
        let (dlo, k) = Readouts.sbc(t0lo, m[t + 2 + Int(y)], true)
        let t0hi = m[t + 1 + Int(y)]
        m[0xC1] = t0hi
        let (dhi, _) = Readouts.sbc(t0hi, m[t + 3 + Int(y)], k)
        // The table index and the fraction from the quotient, then t[i] (kept in $C0/$C1) and
        // the step t[i] - t[i+1] for the multiply.
        charge(44
               + 4 + Machine.pageCrossing(t, y) + 9 + Machine.pageCrossing(t + 2, y) + 3
               + 4 + Machine.pageCrossing(t + 1, y) + 7 + Machine.pageCrossing(t + 3, y) + 12)
        let p = mulQ15AX(a: dlo, x: dhi)
        // t[i] - product, formed as the complement of (product - t[i]).
        let (r0, k2) = Readouts.sbc(p.a, m[0xC0], true)
        let (r1, _) = Readouts.sbc(p.x, m[0xC1], k2)
        charge(26)
        return (r0 ^ 0xFF, r1 ^ 0xFF)
    }

    /// $3EEE: negates the zero-page word at X (`$00,X` / `$01,X`, wrapping in page zero). 28 cycles.
    private func negateZeroPageWord(_ x: UInt8) {
        let m = mem
        let (lo, k) = Readouts.sbc(0, m[Int(x)], true)
        m[Int(x)] = lo
        let hiAddress = Machine.zp(1, x)
        let (hi, _) = Readouts.sbc(0, m[hiAddress], k)
        m[hiAddress] = hi
        charge(28)
    }

    // MARK: stationDistance ($3F38)

    /// $3F38 (vector $2030): approximate length of the vector `$09BA/$09BB`, `$09BC/$09BD`:
    /// with L = the larger and S = the smaller absolute value (unsigned 16-bit compare; |-32768|
    /// stays $8000), `$C0/$C1` = L + S × (S / 2L) (`divQ15` then `mulQ15AX`). `$C2/$C3` = L,
    /// `$C6/$C7` and the math scratch as those leave them. The war overlay uses it for 3D
    /// distances. Clobbers A, X, Y.
    public func stationDistance() {
        let m = mem
        var a = m[Nav.stationDeltaNorth], x = m[Nav.stationDeltaNorth + 1]
        var c = 8
        if x & 0x80 == 0 { c += 3 } else {
            charge(c + 8); c = 0
            let n = negate16(a: a, x: x); a = n.a; x = n.x
        }
        m[0xC0] = a
        m[0xC1] = x
        a = m[Nav.stationDeltaEast]
        x = m[Nav.stationDeltaEast + 1]
        c += 14
        if x & 0x80 == 0 { c += 3 } else {
            charge(c + 8); c = 0
            let n = negate16(a: a, x: x); a = n.a; x = n.x
        }
        // Is |east| smaller than |north| (unsigned 16-bit)?
        let c0 = m[0xC0], c1 = m[0xC1]
        c += 3
        var smaller: Bool
        if x < c1 {
            c += 3; smaller = true
        } else {
            c += 2
            if x != c1 { c += 3; smaller = false } else {
                c += 5
                if a >= c0 { c += 3; smaller = false } else { c += 2; smaller = true }
            }
        }
        if smaller {
            // $3F5C: swap, so A:X is the larger and $C0/$C1 the smaller.
            m[0xC1] = x
            m[0xC0] = a
            a = c0
            x = c1
            c += 16
        }
        // $3F66: keep L in $C2/$C3 and divide S by 2L ($1802).
        m[0xC2] = a
        m[0xC3] = x
        m[0xC6] = a << 1
        m[0xC7] = x << 1 | a >> 7
        charge(c + 30)
        divQ15(a: m[0xC1], x: m[0xC0])
        charge(12)                                   // S times that quotient ($17EF)
        let p = mulQ15AX(a: m[0xC0], x: m[0xC1])
        let (lo, k) = Readouts.adc(p.a, m[0xC2], false)
        m[0xC0] = lo
        let (hi, _) = Readouts.adc(p.x, m[0xC3], k)
        m[0xC1] = hi
        charge(22)                   // plus L, and return
    }

    // MARK: Course deviation ($3B61, $3D2B, $3D84)

    /// $3B61: the course deviation of NAV `mask` (1 = NAV1 with station X = 8, 2 = NAV2 with
    /// X = 0) for the course Y (2-degree units).
    ///
    /// When `$0922 & mask` = 0 (no station): `$B8/$B9` = 0 and A = 0 (OFF). Otherwise `$3A` =
    /// course, `stationBearing`, then course16 = course × 364 (`mulU16`; 180 units → $FFF0),
    /// d = (course16 - bearing) × 540 >> 15 (`mulQ15AX`: 3 units per degree), stored in `$B8/$B9`
    /// and classified by $3D2B. Returns A: 0 OFF, 1 TO, 2 FR.
    public func courseDeviation(mask: UInt8, station: UInt8, course: UInt8) -> UInt8 {
        let m = mem
        guard mask & m[Radio.navFoundBits] != 0 else {
            m[0xB9] = 0
            m[0xB8] = 0
            charge(18)
            return 0
        }
        m[0x3A] = course
        charge(16)                               // station found: keep the course, get the bearing
        stationBearing(station: station)
        m[0xC4] = m[0x3A]
        m[0xC5] = 0
        charge(21)                   // the course times 364
        let course16 = mulU16(a: 0x6C, x: 0x01)
        // The course as a binary angle (the product's upper bytes) minus the bearing, times 540.
        let (d0, k) = Readouts.sbc(m[0xC8], m[0xB8], true)
        m[0xC4] = d0
        let (d1, _) = Readouts.sbc(course16.a, m[0xB9], k)
        m[0xC5] = d1
        charge(33)
        let p = mulQ15AX(a: 0x1C, x: 0x02)
        m[0xB8] = p.a
        m[0xB9] = p.x
        charge(9)                                   // store d, on to $3D2B
        return classifyToFrom(p.a, p.x)
    }

    /// $3D2B: TO/FROM from the deviation d (A = low, X = high; also in `$B8/$B9`), 540 = 180°.
    /// |d| < 256 (85°): FR (2), `$B8/$B9` kept. 256 <= |d| < 300 (100°): OFF (0), `$B8/$B9` = 0.
    /// Otherwise TO (1) with `$B8/$B9` = 540 - d (d > 0) or -540 - d (d < 0), i.e. the deviation
    /// seen from the reciprocal course.
    public func classifyToFrom(_ a: UInt8, _ x: UInt8) -> UInt8 {
        enum Exit { case fromCourse, reciprocalPlus, reciprocalMinus, off }
        var c = 4                                       // flags from the high byte
        let exit: Exit
        if x & 0x80 == 0 {
            c += 4                                      // positive: high byte below 1?
            if x < 1 {
                c += 3; exit = .fromCourse
            } else {
                c += 2
                if x != 1 { c += 3; exit = .reciprocalPlus } else {
                    c += 4                              // high byte 1: low byte against 300
                    if a < 0x2C { c += 3; exit = .off } else { c += 5; exit = .reciprocalPlus }
                }
            }
        } else {
            c += 5                                      // negative: high byte against $FE
            if x < 0xFE {
                c += 3; exit = .reciprocalMinus
            } else {
                c += 2
                if x != 0xFE { c += 3; exit = .fromCourse } else {
                    c += 4                              // high byte $FE: low byte against -300
                    if a < 0xD4 { c += 3; exit = .reciprocalMinus } else { c += 5; exit = .off }
                }
            }
        }
        let m = mem
        switch exit {
        case .fromCourse:
            charge(c + 8)                               // FR
            return 2
        case .off:
            m[0xB9] = 0
            m[0xB8] = 0
            charge(c + 14)
            return 0
        case .reciprocalPlus, .reciprocalMinus:
            let plus = exit == .reciprocalPlus
            c += plus ? 7 : 4                   // 540 or -540 (the positive side branches over)
            let (lo, k) = Readouts.sbc(plus ? 0x1C : 0xE4, m[0xB8], true)
            m[0xB8] = lo
            let (hi, _) = Readouts.sbc(plus ? 0x02 : 0xFD, m[0xB9], k)
            m[0xB9] = hi
            charge(c + 24)
            return 1
        }
    }

    /// $3D84: the needle position for the deviation in `$B8/$B9`: clamped to -30..30 (`$E2`..
    /// `$1E` as a low byte), then (v + 30) >> 1 (8-bit): 0-30, 15 = centered.
    public func deviationNeedle() -> UInt8 {
        let m = mem
        let lo = m[0xB8], hi = m[0xB9]
        var a = lo
        var c = 6                                       // fetch the deviation
        if hi & 0x80 == 0 {
            c += 2                                          // not negative
            if hi != 0 {
                c += 8; a = 0x1E                    // 256 or more: pin at 30
            } else {
                c += 4                                  // below 256: against 30
                if lo < 0x1E { c += 3 } else { c += 7; a = 0x1E }
            }
        } else {
            c += 5                                      // negative: is the high byte $FF?
            if hi &+ 1 != 0 {
                c += 5; a = 0xE2                        // below -256: pin at -30
            } else {
                c += 4                                  // against -30
                if lo >= 0xE2 { c += 3 } else { c += 4; a = 0xE2 }
            }
        }
        charge(c + 12)                           // offset by 30, halve, return
        return (a &+ 0x1E) >> 1
    }
}
