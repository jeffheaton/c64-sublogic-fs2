/// The six enemy planes of the war overlay ($AA84-$AE43, $B04C-$B0FB) and the damage they do
/// ($B19E). See `re/docs/war.md`.
extension Machine {
    // MARK: enemyUpdate ($AA84)

    /// $AA84: one enemy per call, X = its record offset (0, $1C, ... $8C), once war is declared.
    ///
    /// 1. `$A800` = X. State 0 (shot down): return.
    /// 2. State 1 (dormant): becomes 2 when the aircraft is west of the trigger (`$5C/$5D` −
    ///    trigger east negative) and not south of it (`$64/$65` − trigger north not negative);
    ///    the delta goes toward the enemy's base (`[rec+26]`).
    /// 3. State 2 (attacking): back to 1 (and return) when the aircraft leaves the zone (east
    ///    of zone east or south of zone north); else the delta goes toward the aircraft ($5A),
    ///    and when the enemy is on the panel scope (rec+9 ≠ 0), the range is trusted ($A80C,
    ///    $A80D = 0) and below rec+22, it fires: `$A816` = 1, cooldown = reload, `$08B7` + 1,
    ///    `printHitsTaken`, `warDamage`.
    /// 4. Motion: with a cooldown, the enemy climbs 1 m per pass (cooldown bit 7 clear after the
    ///    decrement) or sinks 1 m on odd passes (`$22` bit 0; the borrow chain starts from the
    ///    carry left by the path above, and the altitude is held at 1 when it reaches 0);
    ///    without one it steps each axis by its step toward the delta's sign.
    /// 5. The dot: the low words of east, altitude and north go into the dot list at $A8A0 and
    ///    the list runs ($8006, pen 3); its projected point A is the screen position
    ///    `$A839/$A83A`. Then the delta toward the aircraft, the panel scope dot
    ///    (`plotEnemyScope`) and, when the dot is in the window: the range picks a shape (0 at
    ///    $200+, 1 at $100+, 2 at $80+, 3 at $40+, else 4; nothing at $400+), the shape is drawn
    ///    and the in-sight flag rec+10 is set (3, with `$A817` = 3) when the screen position is
    ///    inside the gunsight box x $46-$5A, y $2A-$46 in the front view, or to the view number in
    ///    another view; dormant enemies cannot be hit while the aircraft is below 256 m.
    ///
    /// Clobbers A, X, Y.
    public func enemyUpdate(_ offset: UInt8) {
        let m = mem
        let R = War.enemyRecords
        typealias F = War.Field
        var x = offset
        @inline(__always) func f(_ k: Int) -> Int { R + k + Int(x) }
        @inline(__always) func cr(_ k: Int) -> Int { Machine.pageCrossing(R + k, x) }

        m[War.enemyOffset] = x
        var c = 8 + cr(F.state)                         // the offset saved; the state
        let state = m[f(F.state)]
        if state == 0 { charge(c + 9); return }         // shot down
        c += 4                                          // dormant or attacking?
        var carry: Bool
        if state == 1 {
            c += 9 + cr(F.triggerEast) + 7 + cr(F.triggerEast + 1)
            let (east, _) = War.sbc(m[0x5D], m[f(F.triggerEast + 1)], m[0x5C] >= m[f(F.triggerEast)])
            if east & 0x80 == 0 {
                c += 3                                      // east of the trigger
            } else {
                c += 9 + cr(F.triggerNorth) + 7 + cr(F.triggerNorth + 1)
                let (north, _) = War.sbc(m[0x65], m[f(F.triggerNorth + 1)], m[0x64] >= m[f(F.triggerNorth)])
                if north & 0x80 != 0 {
                    c += 3                                  // south of the trigger
                } else {
                    m[f(F.state)] = 2
                    c += 9
                }
            }
            // $AAAC: toward the base.
            m[0xA5] = m[f(F.base)]
            m[0xA6] = m[f(F.base + 1)]
            charge(c + 4 + cr(F.base) + 7 + cr(F.base + 1) + 9)
            carry = enemyDelta(x)
            c = 3                                           // on to the motion
        } else {
            c += 10 + cr(F.zoneEast) + 7 + cr(F.zoneEast + 1)   // attacking: east of the zone?
            let (east, _) = War.sbc(m[0x5D], m[f(F.zoneEast + 1)], m[0x5C] >= m[f(F.zoneEast)])
            var leaves = east & 0x80 == 0
            if leaves {
                c += 2
            } else {
                c += 10 + cr(F.zoneNorth) + 7 + cr(F.zoneNorth + 1)
                let (north, _) = War.sbc(m[0x65], m[f(F.zoneNorth + 1)], m[0x64] >= m[f(F.zoneNorth)])
                leaves = north & 0x80 != 0
                c += leaves ? 3 : 2                         // south of the zone?
            }
            if leaves {
                // $AAC8: dormant again.
                m[f(F.state)] = 1
                charge(c + 13)
                return
            }
            // Toward the aircraft.
            m[0xA5] = 0x5A
            m[0xA6] = 0
            charge(c + 16)
            carry = enemyDelta(x)
            c = 4 + cr(F.onScope)                           // on the panel scope?
            if m[f(F.onScope)] == 0 {
                c += 4                                      // no (the branch crosses a page)
            } else {
                charge(c + 8)                           // the range
                carry = enemyDistance()
                c = 8                                   // a trusted range below 256?
                if m[War.range + 1] | m[War.rangeOverflow] != 0 {
                    c += 4                                  // too far (the branch crosses a page)
                } else {
                    c += 12 + cr(F.fireRange)    // within the fire range?
                    if m[War.range] >= m[f(F.fireRange)] {
                        c += 4                              // no (the branch crosses a page)
                        carry = true
                    } else {
                        // The enemy fires.
                        m[War.enemyFired] = 1
                        m[f(F.cooldown)] = m[f(F.reload)]
                        m[War.hitsTaken] &+= 1
                        charge(c + 12 + cr(F.reload) + 17)   // fired, the cooldown, a hit taken
                        printHitsTaken()
                        charge(6)
                        carry = warDamage()
                        c = 0
                    }
                }
            }
        }

        // $AB12: motion.
        c += 4 + cr(F.cooldown)                             // the cooldown
        let cooldown = m[f(F.cooldown)]
        if cooldown != 0 {
            let left = cooldown &- 1
            m[f(F.cooldown)] = left
            c += 9                                      // counted down
            if left & 0x80 == 0 {
                // $AB4A: climb 1 m.
                c += 10
                m[f(F.altitude)] &+= 1
                if m[f(F.altitude)] != 0 {
                    c += 3
                } else {
                    c += 9
                    m[f(F.altitude + 1)] &+= 1
                    if m[f(F.altitude + 1)] != 0 {
                        c += 3
                    } else {
                        c += 9
                        m[f(F.altitude + 2)] &+= 1
                        c += m[f(F.altitude + 2)] != 0 ? 3 : 2
                    }
                }
            } else {
                c += 7                              // sinking: on odd passes only
                if m[0x22] & 1 == 0 {
                    c += 3
                } else {
                    // Sink 1 m (the borrow starts from the carry left above), held at 1.
                    c += 6 + cr(F.altitude) + 7     // the low byte
                    let (low, k) = War.sbc(m[f(F.altitude)], 1, carry)
                    m[f(F.altitude)] = low
                    var a = low
                    var floorCheck: Bool
                    if k {
                        c += 3
                        floorCheck = true
                    } else {
                        c += 6 + cr(F.altitude + 1) + 7
                        let (mid, k2) = War.sbc(m[f(F.altitude + 1)], 0, false)
                        m[f(F.altitude + 1)] = mid
                        a = mid
                        if k2 {
                            c += 3
                            floorCheck = false
                        } else {
                            c += 9                      // the borrow from the high byte
                            m[f(F.altitude + 2)] &-= 1
                            floorCheck = m[f(F.altitude + 2)] == 0
                            c += floorCheck ? 2 : 3
                        }
                    }
                    if floorCheck {
                        // $AB3B
                        c += 4 + cr(F.altitude + 2) + 4 + cr(F.altitude + 1)
                        a |= m[f(F.altitude + 2)] | m[f(F.altitude + 1)]
                        if a != 0 {
                            c += 3
                        } else {
                            m[f(F.altitude)] = 1
                            c += 12
                        }
                    }
                }
            }
            c += 3                                          // on to the dot
        } else {
            c += 3                                          // no cooldown: step toward the target
            c += enemyStep(F.altitude, step: F.stepAltitude, sign: War.delta + 5, x: x)
            c += enemyStep(F.east, step: F.stepEast, sign: War.delta + 2, x: x)
            c += enemyStep(F.north, step: F.stepNorth, sign: War.delta + 8, x: x)
        }

        // $ABF8: the dot.
        x = m[War.enemyOffset]
        let point = War.enemyDotPoint
        m[point] = m[f(F.east)]
        m[point + 1] = m[f(F.east + 1)]
        m[point + 2] = m[f(F.altitude)]
        m[point + 3] = m[f(F.altitude + 1)]
        m[point + 4] = m[f(F.north)]
        m[point + 5] = m[f(F.north + 1)]
        c += 4
        for k in [F.east, F.east + 1, F.altitude, F.altitude + 1, F.north, F.north + 1] { c += 4 + cr(k) + 4 }
        m[Scenery.displayListPc] = UInt8(War.enemyDotList & 0xFF)
        m[Scenery.displayListPc + 1] = UInt8(War.enemyDotList >> 8)
        charge(c + 21)                   // the list PC at the dot list; pen 3
        setPen(3)
        charge(9)                                           // through the $8006 vector
        do { try runScenery() } catch { preconditionFailure("enemy dot display list: \(error)") }
        m[War.enemyScreenX] = m[0xD3]
        m[War.enemyScreenY] = m[0xD4]
        x = m[War.enemyOffset]
        m[0xA5] = 0x5A
        m[0xA6] = 0
        charge(34)      // the screen position kept; the delta toward the aircraft
        _ = enemyDelta(x)
        charge(6)
        plotEnemyScope()

        c = 5                                           // the dot's clip flags
        var sight: UInt8 = 0
        visible: do {
            if m[0xCC] & 0x0F != 0 { c += 3; break visible }   // outside the window
            charge(c + 8)                               // the range
            _ = enemyDistance()
            var y: UInt8 = 0
            m[War.shapeIndex] = 0
            c = 12                               // shape 0; $400 or more?
            let high = m[War.range + 1]
            if high >= 4 { c += 3; break visible }          // too far to draw
            c += 4                                      // $200 or more?
            var inBox = false
            if high >= 2 {
                c += 3                                      // shape 0, no gunsight test
            } else {
                c += 10                              // shape 1; $100 or more?
                m[War.shapeIndex] &+= 1
                if high >= 1 {
                    c += 3
                } else {
                    let low = m[War.range]
                    c += 14                      // shape 2; $80 or more?
                    m[War.shapeIndex] &+= 1
                    if low >= 0x80 {
                        c += 3
                    } else {
                        c += 10                      // shape 3; $40 or more?
                        m[War.shapeIndex] &+= 1
                        if low >= 0x40 {
                            c += 3
                        } else {
                            c += 8                      // shape 4
                            m[War.shapeIndex] &+= 1
                        }
                    }
                }
                inBox = true
            }
            if inBox {
                // $AC7E: the gunsight box.
                let sx = m[War.enemyScreenX], sy = m[War.enemyScreenY]
                c += 6                                  // x below $5B?
                if sx >= 0x5B { c += 3 } else {
                    c += 4                              // x at least $46?
                    if sx < 0x46 { c += 3 } else {
                        c += 8                      // y below $47?
                        if sy >= 0x47 { c += 3 } else {
                            c += 4                      // y at least $2A?
                            if sy < 0x2A { c += 3 } else { c += 4; y = 1 }   // inside the box
                        }
                    }
                }
            }
            // $AC95
            charge(c + 11)                           // the box flag kept on the stack; the shape
            drawEnemyShape()
            x = m[War.enemyOffset]
            c = 14 + cr(F.state) + 2             // the flag back; dormant?
            if m[f(F.state)] == 1 {
                c += 5                                  // dormant: below 256 m?
                if m[0x61] == 0 {
                    c += 7                          // the altitude's low byte
                    if (m[0x60] &- 1) & 0x80 != 0 { c += 3; break visible }   // too low to be hit
                    c += 2
                } else {
                    c += 3
                }
            } else {
                c += 3
            }
            // $ACB0
            c += 4                                          // the view
            let view = m[0x0ACA]
            if view != 0 {
                c += 3                                      // another view: its number
                m[f(F.inSight)] = view
                charge(c + 11)
                return
            }
            c += 4                                      // front view: in the box?
            if y == 0 { c += 2; break visible }             // no: falls into $ACB8
            c += 9                                  // in the gunsight
            m[War.inRange] = 3
            sight = 3
            m[f(F.inSight)] = sight
            charge(c + 11)
            return
        }
        // $ACB8
        m[f(F.inSight)] = sight
        charge(c + 16)                           // not in sight
    }

    /// One axis of the step move ($AB5C-$AB8F altitude, $AB90-$ABC3 east, $ABC4-$ABF7 north):
    /// the 24-bit field at `field` moves by rec[`step`] up when the delta's top byte `sign` is
    /// not negative, else down. Returns its cycles.
    @inline(__always)
    private func enemyStep(_ field: Int, step: Int, sign: Int, x: UInt8) -> Int {
        let m = mem
        let a = War.enemyRecords + field + Int(x)
        let s = War.enemyRecords + step + Int(x)
        let cr0 = Machine.pageCrossing(War.enemyRecords + field, x)
        let cr1 = Machine.pageCrossing(War.enemyRecords + field + 1, x)
        let crs = Machine.pageCrossing(War.enemyRecords + step, x)
        var c = 4                                           // the delta's sign
        if m[sign] & 0x80 == 0 {
            c += 6 + cr0 + 6 + crs + 5              // up: the low byte
            let sum = Int(m[a]) + Int(m[s])
            m[a] = UInt8(truncatingIfNeeded: sum)
            if sum <= 0xFF { return c + 3 }
            c += 9                                      // the carry into the middle byte
            m[a + 1] &+= 1
            if m[a + 1] != 0 { return c + 3 }
            m[a + 2] &+= 1
            return c + 12                            // the high byte; the exit test sees the carry set
        }
        c += 7 + cr0 + 6 + crs + 5                  // down: the low byte
        let (low, k) = War.sbc(m[a], m[s], true)
        m[a] = low
        if k { return c + 3 }
        c += 6 + cr1 + 7                            // the borrow from the middle byte
        let (mid, k2) = War.sbc(m[a + 1], 0, false)
        m[a + 1] = mid
        if k2 { return c + 3 }
        m[a + 2] &-= 1
        return c + 9                                    // and from the high byte
    }

    // MARK: Deltas and range ($B0A3, $B04C)

    /// $B0A3: the delta from enemy X to the position at `[$A5/$A6]` (laid out like $5A-$65:
    /// bytes 1-3, 5-7 and 9-11 are the 24-bit east, altitude and north) into $A802-$A80A, each
    /// axis a 24-bit subtraction. Leaves Y = 12; returns the carry of the last (north high)
    /// subtraction, which `enemyUpdate`'s sink step starts from.
    @discardableResult
    public func enemyDelta(_ x: UInt8) -> Bool {
        let m = mem
        let lo = m[0xA5], base = Int(m[0xA5]) | Int(m[0xA6]) << 8
        var c = 2                                           // byte 1 of the position
        var carry = true
        for axis in 0..<3 {
            c += 2                                          // each axis starts without a borrow
            carry = true
            for k in 0..<3 {
                let y = 1 + 4 * axis + k
                let field = 3 * axis + k
                let (r, kk) = War.sbc(m[(base + y) & 0xFFFF], m[War.enemyRecords + field + Int(x)], carry)
                carry = kk
                m[War.delta + field] = r
                c += 5 + (Int(lo) + y > 0xFF ? 1 : 0) + 4 + Machine.pageCrossing(War.enemyRecords + field, x) + 4 // one byte
                c += 2
            }
            if axis < 2 { c += 2 }                          // past the next axis's low byte
        }
        charge(c + 6)
        return carry
    }

    /// $B04C: the range to the delta: `stationDistance` ($2030) of (east, altitude) low words,
    /// then of (that, north): `$A80B/$A80C`. `$A80D` = 0 when the three delta high bytes XOR to
    /// 0 or $FF, else $7F. `$09BA-$09BD` and the math scratch as `stationDistance` leaves them;
    /// X = `$A800`. Returns the carry of the second `stationDistance` (its final add), which
    /// nothing here changes afterwards.
    @discardableResult
    public func enemyDistance() -> Bool {
        let m = mem
        m[0x09BA] = m[War.delta]
        m[0x09BB] = m[War.delta + 1]
        m[0x09BC] = m[War.delta + 3]
        m[0x09BD] = m[War.delta + 4]
        charge(41)          // the east and altitude low words
        stationDistance()
        m[0x09BA] = m[0xC0]
        m[0x09BB] = m[0xC1]
        m[0x09BC] = m[War.delta + 6]
        m[0x09BD] = m[War.delta + 7]
        charge(39)
        stationDistance()
        // The last step of $3F38 is a 16-bit add of $C2/$C3 into $C0/$C1: it carried exactly
        // when the sum is below the addend.
        let carry = u16(0xC0) < u16(0xC2)
        var a = m[War.delta + 2] ^ m[War.delta + 5] ^ m[War.delta + 8]
        var c = 12                                   // the three high bytes combined
        if a == 0 {
            c += 3
        } else {
            c += 8                              // $FF becomes 0 when incremented
            if a == 0xFF { a = 0; c += 3 } else { a = 0x7F; c += 4 }
        }
        m[War.rangeOverflow] = a
        m[War.range] = m[0xC0]
        m[War.range + 1] = m[0xC1]
        charge(c + 28)               // stored with the range; the record offset back
        return carry
    }

    // MARK: The panel scope ($AD21)

    /// $AD21: the enemy's dot on the panel scope. Only when the east and north delta high bytes
    /// are equal or complementary: the (east, north) low words are rotated by the heading
    /// `$71` (sin/cos through $18BD/$18B8 and `mulQ15AX`): across = e·cos − n·sin ($A80E),
    /// along = n·cos + e·sin ($A810). v = across × $176 (Q15) needs a high byte of 0 or $FF and
    /// a low byte of −22 ... 20 (signed compares of the low byte only) and gives x = $8A − v
    /// for v < 0, $89 − v otherwise (the carry left by the lower-bound compare enters the
    /// addition); w = along × $1A3 needs a low byte of −25 ... 24 (its high byte is never
    /// checked: both outcomes of its test at $ADEC reach the same code) and gives the row
    /// w + $92. The row is stored in rec+9 and the dot is plotted with pen 3. Otherwise
    /// rec+9 = 0. Leaves X = `$A800`.
    public func plotEnemyScope() {
        let m = mem
        @inline(__always) func off() {
            // $AE3B
            let x = m[War.enemyOffset]
            m[War.enemyRecords + War.Field.onScope + Int(x)] = 0
            charge(17)
        }
        var c = 8                                       // east and north high bytes
        let e = m[War.delta + 2] ^ m[War.delta + 8]
        if e == 0 {
            c += 3
        } else {
            c += 4                                      // complementary?
            if e != 0xFF { charge(c + 5); off(); return }   // off the scope
            c += 3
        }
        // $AD30
        charge(c + 9)                                   // sin of the heading
        let sine = sin8(a: m[0x71])
        m[0xC4] = sine.a; m[0xC5] = sine.x
        m[War.headingSine] = sine.a; m[War.headingSine + 1] = sine.x
        charge(28)                   // kept twice; then e·sin
        var p = mulQ15AX(a: m[War.delta], x: m[War.delta + 1])
        m[War.scopeAlong] = p.a; m[War.scopeAlong + 1] = p.x            // e·sin
        m[0xC4] = m[War.headingSine]; m[0xC5] = m[War.headingSine + 1]
        charge(36)
        p = mulQ15AX(a: m[War.delta + 6], x: m[War.delta + 7])
        m[War.scopeAcross] = p.a; m[War.scopeAcross + 1] = p.x          // n·sin
        charge(17)                               // stored; cos of the heading
        let cosine = cos8(a: m[0x71])
        m[War.headingCosine] = cosine.a; m[War.headingCosine + 1] = cosine.x
        m[0xC4] = cosine.a; m[0xC5] = cosine.x
        charge(28)
        p = mulQ15AX(a: m[War.delta], x: m[War.delta + 1])              // e·cos
        var (lo, k) = War.sbc(p.a, m[War.scopeAcross], true)
        m[War.scopeAcross] = lo
        (lo, k) = War.sbc(p.x, m[War.scopeAcross + 1], k)
        m[War.scopeAcross + 1] = lo
        m[0xC4] = m[War.headingCosine]; m[0xC5] = m[War.headingCosine + 1]
        charge(48)
        p = mulQ15AX(a: m[War.delta + 6], x: m[War.delta + 7])          // n·cos
        var sum = Int(p.a) + Int(m[War.scopeAlong])
        m[War.scopeAlong] = UInt8(truncatingIfNeeded: sum)
        sum = Int(p.x) + Int(m[War.scopeAlong + 1]) + (sum > 0xFF ? 1 : 0)
        m[War.scopeAlong + 1] = UInt8(truncatingIfNeeded: sum)
        m[0xC4] = 0x76; m[0xC5] = 0x01
        charge(44)
        p = mulQ15AX(a: m[War.scopeAcross], x: m[War.scopeAcross + 1])
        c = 2                                               // across: high byte 0?
        if p.x == 0 {
            c += 3
        } else {
            c += 4                                      // or $FF?
            if p.x != 0xFF { charge(c + 4); off(); return } // off the scope (the branch crosses a page)
            c += 2
        }
        // $ADC7
        c += 2                                              // low byte below 21 (signed)?
        if (p.a &- 0x15) & 0x80 == 0 { charge(c + 4); off(); return }
        c += 4                                          // and at least −22?
        if (p.a &- 0xEA) & 0x80 != 0 { charge(c + 4); off(); return }
        let column = ~p.a &+ 0x8A &+ (p.a >= 0xEA ? 1 : 0)
        m[0xA5] = column
        m[0xC4] = 0xA3; m[0xC5] = 0x01
        charge(c + 33)   // the column; then along × $1A3
        p = mulQ15AX(a: m[War.scopeAlong], x: m[War.scopeAlong + 1])
        c = 2                                               // along: the high byte test
        c += p.x != 0 ? 3 : 6                       // both outcomes reach $ADEE: the high byte never matters
        // $ADEE
        c += 2                                              // low byte below 25 (signed)?
        if (p.a &- 0x19) & 0x80 == 0 { charge(c + 4); off(); return }
        c += 4                                          // and at least −25?
        if (p.a &- 0xE7) & 0x80 != 0 { charge(c + 4); off(); return }
        let row = p.a &+ 0x92                               // $91 plus the set carry
        m[0xA6] = row
        let x = m[War.enemyOffset]
        m[War.enemyRecords + War.Field.onScope + Int(x)] = row
        c += 26                  // the row, also into the record; the altitude delta
        // $AE01-$AE29: a pen choice by the altitude delta, which the pen 3 loaded at $AE2B overrides.
        let high = m[War.delta + 5], mid = m[War.delta + 4], low = m[War.delta + 3]
        if high & 0x80 != 0 {
            c += 4                                      // below: high byte $FF?
            var below = true
            if high == 0xFF {
                c += 6                                  // middle byte $FF?
                if mid == 0xFF {
                    c += 4                              // low byte at least $E2?
                    if low >= 0xE2 { c += 3; below = false } else { c += 2 }
                } else {
                    c += 3
                }
            } else {
                c += 3
            }
            if below { c += 5 }                         // pen 1
        } else {
            c += 5                                      // above: high byte 0?
            var above = true
            if high == 0 {
                c += 6                                  // middle byte 0?
                if mid == 0 {
                    c += 4                              // low byte below $1E?
                    if low < 0x1E { c += 3; above = false } else { c += 2 }
                } else {
                    c += 3
                }
            } else {
                c += 3
            }
            if above { c += 5 }                         // pen 2
        }
        charge(c + 11)                                   // pen 3 after all
        setPen(3)
        charge(15)                                   // the plot
        plot(x: m[0xA5], row: m[0xA6])
        charge(10)                                       // the record offset back
    }

    // MARK: The enemy shape ($ACC5)

    /// $ACC5: pen 3; when the screen position `$A839/$A83A` lies in x 4-$9A, y 4-$6A, draws
    /// shape `$A838` (offset `$A915[$A838]` into $A91A: a line count, then (dx1, dy1, dx2, dy2)
    /// per line, added to the position with 8-bit wrap) with `drawLine`. Clobbers A, X, Y.
    public func drawEnemyShape() {
        let m = mem
        charge(11)                                       // pen 3
        setPen(3)
        let sx = m[War.enemyScreenX], sy = m[War.enemyScreenY]
        var c = 6                                       // x at least 4?
        if sx < 4 { charge(c + 10); return }             // off the window (the branch crosses a page)
        c += 4
        if sx >= 0x9B { charge(c + 10); return }
        c += 8
        if sy < 4 { charge(c + 10); return }
        c += 4
        if sy >= 0x6B { charge(c + 10); return }
        c += 2
        let shape = m[War.shapeIndex]
        var x = m[War.shapeOffsets + Int(shape)]
        c += 8 + Machine.pageCrossing(War.shapeOffsets, shape) // the shape's offset
        var y = m[War.shapes + Int(x)]
        c += 4 + Machine.pageCrossing(War.shapes, x)        // its line count
        x &+= 1
        c += 2
        repeat {
            for k in 0..<4 {                                // $EB = x1, $EC = y1, $ED = x2, $EE = y2
                let origin = k & 1 == 0 ? sx : sy
                m[0xEB + k] = m[War.shapes + Int(x)] &+ origin
                c += 4 + Machine.pageCrossing(War.shapes, x) + 11 // one coordinate plus the position
                x &+= 1
            }
            charge(c + 19)                   // both indexes on the stack; draw
            drawLine()
            y &-= 1
            c = 14                           // the indexes back; one line fewer
            c += y != 0 ? 4 : 2                             // the loop branch crosses a page
        } while y != 0
        charge(c + 6)
    }

    // MARK: warDamage ($B19E)

    /// $B19E (after each hit): ORs failure bits into `$09BF` by the hits taken `$08B7`. Fewer
    /// than 4 kills: 60+ → `$08D4` + 1 and bits 0-1, 40+ → bits 0-1, 35+ → bit 1, 20+ → nothing
    /// more; from 20 on, bit 3 when `$22` < $3F; from 7 on, bit 2. With 4 kills or more the
    /// thresholds are 20 (`$08D4` + 1, bits 0-1), 7 (bits 0-1) and 1 (bits 3/2 as above).
    /// Returns the carry: `$22` ≥ $3F when bit 2 was set, else clear.
    @discardableResult
    public func warDamage() -> Bool {
        let m = mem
        let hits = m[War.hitsTaken]
        var c = 12                               // the hits; 4 kills or more?
        enum Step { case top, rpm, rpmHigh, leakRight, leakLeft, none }
        var step: Step
        if m[War.killCount] >= 4 {
            c += 5                                      // the thresholds 20, 7 and 1
            if hits >= 0x14 { c += 3; step = .top } else {
                c += 4
                if hits >= 7 { c += 3; step = .rpm } else {
                    c += 4
                    if hits >= 1 { c += 3; step = .leakRight } else { c += 5; step = .none }
                }
            }
        } else {
            c += 4                                      // the thresholds 60, 40, 35, 20 and 7
            if hits >= 0x3C { c += 3; step = .top } else {
                c += 4
                if hits >= 0x28 { c += 3; step = .rpm } else {
                    c += 4
                    if hits >= 0x23 { c += 3; step = .rpmHigh } else {
                        c += 4
                        if hits >= 0x14 { c += 3; step = .leakRight } else {
                            c += 4
                            if hits >= 7 { c += 3; step = .leakLeft } else { c += 5; step = .none }
                        }
                    }
                }
            }
        }
        var a: UInt8 = 0
        var carry = false
        switch step {
        case .top, .rpm, .rpmHigh, .leakRight:
            if step == .top { m[War.damageLevel] &+= 1; c += 6 }
            if step == .top || step == .rpm { a |= 1; c += 2 }
            if step != .leakRight { a |= 2; c += 2 }
            // $B1D5
            c += 5                                      // the pass counter against $3F
            if m[0x22] >= 0x3F { c += 3 } else { a |= 8; c += 4 }
            fallthrough
        case .leakLeft:
            // $B1DD
            carry = m[0x22] >= 0x3F
            a |= 4
            c += 7                                  // the same test leaves the carry; bit 2
        case .none:
            break
        }
        m[War.engineFailureBits] |= a
        charge(c + 14)                               // into the failure bits
        return carry
    }
}
