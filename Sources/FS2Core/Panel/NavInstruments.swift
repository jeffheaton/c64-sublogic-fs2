/// The NAV instruments ($3B32-$3F89): the odd-phase CDI tasks that turn the station geometry
/// into needle targets, TO/FROM, glideslope and DME, and the draw-sequence routines that move
/// the XOR localizer needles and glideslope bar one step per pass, redraw the TO/FROM text and
/// run the marker beacons.
///
/// The needles and the glideslope bar are XORed into the panel (erase = draw again); the TO/FROM
/// records are opaque text, so a TO/FROM change erases both needles, draws the text and redraws
/// them. Literal translation with exact cycles (see `Panel/Readouts.swift`).
extension Machine {
    // MARK: CDI tasks ($3B32, $3B9B, $3DA2)

    /// $3B32 (odd passes): NAV1. The course is OBS1, or for a localizer (station B's north
    /// fraction byte `$0933` != 0) the low byte of (`$0852/$0853` × $1555 >> 15): the course the
    /// scenery stored, in 1/3 degrees, turned into OBS units. `courseDeviation` → TO/FROM
    /// `$09B5`, needle target `$09B0` ($3D84), then `updateGlideslopeAndDme`. Clobbers A, X, Y.
    public func updateNav1Cdi() {
        let m = mem
        var course = m[Readouts.obs1]
        var c = 10                                   // NAV1's mask and OBS1; is it a localizer?
        if m[Radio.navStationB + 4] == 0 {
            c += 3
        } else {
            m[0xC4] = m[Nav.localizerCourse]
            m[0xC5] = m[Nav.localizerCourse + 1]
            // Localizer: the stored course times $1555 turns 1/3 degrees into OBS units.
            charge(c + 29)
            course = mulQ15AX(a: 0x55, x: 0x15).a
            c = 6                                       // keep the course, recover the mask
        }
        charge(c + 8)                                   // station B, into $3B61
        m[Nav.nav1ToFrom] = courseDeviation(mask: 1, station: 8, course: course)
        charge(10)                                       // store TO/FROM, on to $3D84
        m[Nav.nav1NeedleTarget] = deviationNeedle()
        charge(7)                                       // store the target, continue at $3DA2
        updateGlideslopeAndDme()
    }

    /// $3B9B (odd passes): NAV2 with OBS2 and station A: TO/FROM `$09B6`, needle target `$09B2`.
    /// Clobbers A, X, Y.
    public func updateNav2Cdi() {
        let m = mem
        charge(14)                               // NAV2's mask, OBS2 and station A
        m[Nav.nav2ToFrom] = courseDeviation(mask: 2, station: 0, course: m[Readouts.obs2])
        charge(10)
        m[Nav.nav2NeedleTarget] = deviationNeedle()
        charge(10)                                       // store the target, return
    }

    /// $3DA2 (the tail of $3B32): the glideslope target and the DME.
    ///
    /// Glideslope, only when the scenery set `$0850/$0851` this pass (only the low byte is
    /// tested, so a reference with a zero low byte is ignored): `$9E/$9F` = that / 2,
    /// distance `$C0/$C1` = `stationDistance` (of the vector $3C8F left in `$09BA-$09BD`), h =
    /// `$0A8A/$0A8B` / 2 (meters). h >= distance: target 18 (full). Otherwise the target is
    /// ((h / distance in Q15 - `$9E/$9F`) >> 8) + 18, clamped: 0..35 halved, above 35 → 18, wrapped
    /// negative → 0. `$09B4` = it; `$98` is scratch. Then `$0850/$0851` = 0 (consumed).
    ///
    /// DME: without a NAV1 station `$09AB` = 1. Otherwise `$09AB` = 0 and distance × 283 (`mulU16`)
    /// gives miles `$09AE` (bits 15-22 of the product) and tenths `$09AD` = 20 × (bits 8-14) >> 8
    /// (`mul8Half`). `$09AC` = 1 (redraw) when there is no station or the tenths changed.
    public func updateGlideslopeAndDme() {
        let m = mem
        var c = 4                                           // test the reference's low byte
        let reference = m[Nav.glideslopeReference]
        if reference == 0 {
            c += 3                                          // none this pass: on to $3DFC
        } else {
            let high = m[Nav.glideslopeReference + 1]
            m[0x9E] = reference
            m[0x9F] = high
            m[0x9F] = high >> 1
            m[0x9E] = reference >> 1 | (high & 1) << 7
            charge(c + 28)          // halve the reference, then the distance at $3F38
            stationDistance()
            let altHigh = m[Gauges.altimeterAltitude + 1]
            let x = altHigh >> 1
            let a = m[Gauges.altimeterAltitude] >> 1 | (altHigh & 1) << 7
            c = 17                       // halve the altitude, compare the high bytes
            let c0 = m[0xC0], c1 = m[0xC1]
            var above: Bool
            if x < c1 {
                c += 3; above = false
            } else {
                c += 2
                if x != c1 { c += 3; above = true } else {
                    c += 5                              // equal: compare the low bytes
                    if a < c0 { c += 3; above = false } else { c += 2; above = true }
                }
            }
            var y: UInt8
            if above {
                y = 0x12
                c += 5                                  // at or above the distance: full scale
            } else {
                // $3DCC: h / distance as a Q15 fraction, through the divide at $1802.
                m[0x98] = a
                m[0xC6] = m[0xC0]
                m[0xC7] = m[0xC1]
                charge(c + 26)
                divQ15(a: x, x: m[0x98])
                // Take off the reference, keep the high byte, center it on 18 and range-check it.
                let (_, k) = Readouts.sbc(m[0xC4], m[0x9E], true)
                let (d, _) = Readouts.sbc(m[0xC5], m[0x9F], k)
                let v = d &+ 0x12
                c = 22
                if v < 0x24 {
                    c += 5; y = v                       // in range
                } else if v & 0x80 == 0 {
                    c += 9; y = 0x24            // too high: 36, which halves to 18
                } else {
                    c += 12; y = 0       // wrapped negative: 0
                }
                y >>= 1
                c += 6                              // halve it
            }
            m[Nav.glideslopeTarget] = y
            c += 4
        }
        // $3DFC: the reference is consumed; the DME needs a NAV1 station (found bit 0).
        m[Nav.glideslopeReference] = 0
        m[Nav.glideslopeReference + 1] = 0
        c += 16
        guard m[Radio.navFoundBits] & 1 != 0 else {
            m[Readouts.Dme.noStation] = 1
            m[Readouts.Dme.redraw] = 1
            // No station: flag it and ask for a redraw.
            charge(c + 23)
            return
        }
        m[Readouts.Dme.noStation] = 0
        charge(c + 15)                           // a station: clear the flag, get the distance
        stationDistance()
        m[0xC4] = m[0xC0]
        m[0xC5] = m[0xC1]
        charge(22)                   // the distance times 283 through the multiply at $188A
        let p = mulU16(a: 0x1B, x: 0x01)
        // Miles are bits 15-22 of the product; bits 8-14 times 20 give the tenths ($1961).
        m[Readouts.Dme.miles] = p.x << 1 | p.a >> 7
        charge(26)
        let tenths = mul8Half(x: 0x14, y: p.a & 0x7F, carry: false).y
        // Store the tenths, and ask for a redraw only when they changed.
        let changed = tenths != m[Readouts.Dme.tenths]
        m[Readouts.Dme.tenths] = tenths
        if changed {
            m[Readouts.Dme.redraw] = 1
            charge(24)
        } else {
            charge(19)
        }
    }

    // MARK: OBI drawing ($3BAF, $3C1A, $3C3F)

    /// $3BAF (draw sequence): NAV1, when `$FD` bit 5 is set. A changed TO/FROM (`$09B5` vs
    /// `$09B7`) erases the needle and the glideslope bar, draws the OFF/TO/FR record and redraws
    /// both. Then the needle `$09AF` and the bar `$09B3` each move one step toward their targets
    /// `$09B0`/`$09B4` (erase, step, draw), and the marker beacons run. Clobbers A, X, Y.
    public func drawObi1() {
        let m = mem
        // Gated by `$FD` bit 5 (the branch that skips it all crosses a page).
        guard m[Readouts.instrumentMask0] & 0x20 != 0 else { charge(15); return }
        var c = 19                       // the gate; TO/FROM against the drawn one, recorded
        let toFrom = m[Nav.nav1ToFrom]
        let changed = toFrom != m[Nav.nav1ToFromDrawn]
        m[Nav.nav1ToFromDrawn] = toFrom
        if !changed {
            c += 3
        } else {
            let needle = m[Nav.nav1NeedleDrawn]
            charge(c + 15)                       // changed: keep the needle position, erase it
            drawLocalizer(needle)
            let bar = m[Nav.glideslopeDrawn]
            charge(13)
            drawGlideslope(bar)
            charge(10)
            drawToFrom(m[Nav.nav1ToFrom])
            charge(10)                                   // recover the saved value, redraw the bar
            drawGlideslope(bar)
            charge(10)
            drawLocalizer(needle)
            c = 0
        }
        charge(c)
        stepTowardTarget(Nav.nav1NeedleDrawn, Nav.nav1NeedleTarget) { self.drawLocalizer($0) }
        stepTowardTarget(Nav.glideslopeDrawn, Nav.glideslopeTarget) { self.drawGlideslope($0) }
        charge(6)
        markerBeacons()
        charge(6)                                           // the return
    }

    /// $3C1A (draw sequence): NAV2, when `$FF` bit 3 is set: a changed TO/FROM (`$09B6` vs
    /// `$09B8`) redraws the record (index + 3) around an erase/redraw of the needle, then the
    /// needle step of `stepNav2Needle`. Clobbers A, X, Y.
    public func drawObi2() {
        let m = mem
        guard m[Readouts.instrumentMask2] & 0x08 != 0 else { charge(14); return }
        var c = 19
        let toFrom = m[Nav.nav2ToFrom]
        let changed = toFrom != m[Nav.nav2ToFromDrawn]
        m[Nav.nav2ToFromDrawn] = toFrom
        if !changed {
            c += 3                                          // unchanged: on to the step at $3C3F
        } else {
            let needle = m[Nav.nav2NeedleDrawn]
            charge(c + 15)
            drawLocalizer2(needle)
            charge(14)                           // NAV2's records follow NAV1's three
            drawToFrom(m[Nav.nav2ToFrom] &+ 3)
            charge(10)
            drawLocalizer2(needle)
            c = 0
        }
        charge(c)
        stepNav2Needle()
    }

    /// $3C3F (first in the draw sequence, and the tail of $3C1A): moves the NAV2 needle `$09B1`
    /// one step toward `$09B2`. Not gated by `$FF`. Clobbers A, X, Y.
    public func stepNav2Needle() {
        stepTowardTarget(Nav.nav2NeedleDrawn, Nav.nav2NeedleTarget) { self.drawLocalizer2($0) }
        charge(6)                                           // the return
    }

    /// The step at $3BDC / $3BF9 / $3C3F: nothing when the drawn position equals the target;
    /// otherwise the compare's flags and the position are kept on the stack across the erase,
    /// then the position moves one step toward the target (down when the 8-bit difference is not
    /// negative, up otherwise), is stored and drawn.
    private func stepTowardTarget(_ drawn: Int, _ target: Int, _ draw: (UInt8) -> Void) {
        let m = mem
        let old = m[drawn]
        let goal = m[target]
        guard old != goal else { charge(11); return }
        charge(22)                       // compare, save the flags and the position, erase
        draw(old)
        var c = 8                                       // restore them
        var v = old
        if (old &- goal) & 0x80 == 0 { c += 3 } else { c += 6; v &+= 2 }   // below: +2, net +1
        v &-= 1
        m[drawn] = v
        charge(c + 14)                           // -1, store, draw
        draw(v)
    }

    // MARK: Needles, bar and TO/FROM ($3C5D, $3C81, $3D68, $3D71)

    /// $3C5D: XORs the glideslope bar at row 126 + A: $FF into the bytes at offsets $B8, $C0 and
    /// $C8 of the row (x 184-207). Nothing for a negative A. `$B8/$B9` = the row base.
    /// Clobbers A, X, Y.
    public func drawGlideslope(_ position: UInt8) {
        let m = mem
        guard position & 0x80 == 0 else { charge(11); return }
        let row = position &+ 0x7E
        m[0xB9] = m[Machine.rowAddressHi + Int(row)]
        m[0xB8] = m[Machine.rowAddressLo + Int(row)]
        // The sign test, then the row base from the row tables.
        var c = 21 + Machine.pageCrossing(Machine.rowAddressLo, row) + 3
        for (i, offset) in [UInt8(0xB8), 0xC0, 0xC8].enumerated() {
            // The XOR read's page crossing comes from the pointer as it is before the store: for a
            // row base of $0000 (rows past the tables) the first store hits the pointer $B8 itself.
            let crossing = Machine.pageCrossing(Int(m[0xB8]), offset)
            let address = Machine.indirectY(m[0xB8], m[0xB9], offset)
            m[address] ^= 0xFF
            // The offset, then the XOR tail: called for the first two bytes, fallen into for the
            // third.
            c += 2 + (i < 2 ? 6 : 0) + 7 + crossing + 12
        }
        charge(c)
    }

    /// $3C81: draws TO/FROM record A ($2210 + 8·A: 0-2 NAV1 OFF/TO/FR, 3-5 NAV2). A·8 is 8-bit.
    /// Clobbers A, X, Y.
    public func drawToFrom(_ index: UInt8) {
        let (lo, carry) = (index << 3).addingReportingOverflow(0x10)
        // The record address $2210 + 8·A, then on to the text drawer at $1DDE.
        charge(12 + (carry ? 4 : 3) + 3)
        drawTextRecord(UInt16(carry ? 0x23 : 0x22) << 8 | UInt16(lo))
    }

    /// $3D71: XORs the NAV1 localizer needle (shape $3B13, a 2×7 bar) at x 180 + A, row 126 via
    /// $1BC3. Nothing for a negative A. Clobbers A, X, Y.
    public func drawLocalizer(_ position: UInt8) {
        charge(2)                                           // row 126
        drawLocalizerNeedle(position, row: 0x7E)
    }

    /// $3D68: the NAV2 needle at row 171, unless the ADF is enabled. Clobbers A, X, Y.
    public func drawLocalizer2(_ position: UInt8) {
        guard mem[Readouts.adfEnable] == 0 else { charge(13); return }
        charge(11)                               // the ADF test, row 171
        drawLocalizerNeedle(position, row: 0xAB)
    }

    /// $3D73: nothing for a negative position; otherwise shape $3B13 at x = A + $B4 through
    /// `plotMarkerShape` ($1BC3).
    private func drawLocalizerNeedle(_ position: UInt8, row: UInt8) {
        guard position & 0x80 == 0 else { charge(11); return }
        mem[Gauges.markerShapePtr] = UInt8(Nav.localizerNeedleShape & 0xFF)
        charge(20)
        plotMarkerShape(x: position &+ 0xB4, y: row, shapeHigh: UInt8(Nav.localizerNeedleShape >> 8))
    }

    // MARK: markerBeacons ($3EFC)

    /// $3EFC (end of $3BAF): the marker lamps, except in Europe 1917. All three lamp cells
    /// $7E7B-$7E7D become $BB (unlit); then the first flag that shifts out a 1 (each is shifted
    /// right in turn: `$084C` outer, `$084E` middle, `$084A` inner) lights its lamp ($EB / $AB /
    /// $1B) and sets the sound state `$0E59` to 5 / 6 / 7 (the driver's marker tones). The flags
    /// after the first set one are not shifted. Clobbers A, X.
    public func markerBeacons() {
        let m = mem
        guard m[Nav.europe1917] == 0 else { charge(13); return }
        m[Nav.markerLampCells] = 0xBB
        m[Nav.markerLampCells + 1] = 0xBB
        m[Nav.markerLampCells + 2] = 0xBB
        var c = 26                   // the era test, all three lamps dark, shift the outer flag
        let outer = m[Nav.outerMarkerFlag]
        m[Nav.outerMarkerFlag] = outer >> 1
        if outer & 1 != 0 {
            m[Nav.markerLampCells] = 0xEB
            m[Nav.soundState] = 5
            charge(c + 24)
            return
        }
        c += 8
        let middle = m[Nav.middleMarkerFlag]
        m[Nav.middleMarkerFlag] = middle >> 1
        if middle & 1 != 0 {
            m[Nav.markerLampCells + 1] = 0xAB
            m[Nav.soundState] = 6
            charge(c + 21)
            return
        }
        c += 8
        let inner = m[Nav.innerMarkerFlag]
        m[Nav.innerMarkerFlag] = inner >> 1
        guard inner & 1 != 0 else { charge(c + 9); return }
        m[Nav.markerLampCells + 2] = 0x1B
        m[Nav.soundState] = 7
        charge(c + 23)
    }
}
