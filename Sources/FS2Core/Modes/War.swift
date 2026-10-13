/// The Europe 1917 war game: overlay 2 (disk blocks 158-160) at $A7E0-$B1E9, entered through the
/// overlay slot $A7EE (a jump to $AA03) once per main-loop pass while `$0969` is set.
///
/// Literal translation of $AA03-$B1E9 with exact cycles (see `re/docs/war.md`). The overlay works
/// on its own bytes in memory: its state at $A800-$A83A, the text records $A83B-$A88E, the
/// rotation pointers $A88F, the enemy dot display list $A897, the gunsight lines $A8A7, the tracer
/// records $A8BF, the enemy shapes $A915/$A91A and the six enemy records $A95B. Every byte is read
/// and written at its original address, so the whole image can be compared with the original.
///
/// Cycle convention: every routine charges from its first instruction through its return; the
/// caller charges the call (and the 3-cycle jump of a `$2000`/`$8000` vector).
public enum War {
    /// $A7EE: the overlay slot (a jump to $AA03) the main loop calls in Europe 1917.
    public static let slot: UInt16 = 0xA7EE
    /// $AA03: `warMain`.
    public static let mainEntry: UInt16 = 0xAA03

    // MARK: Resident state the overlay uses

    /// $08D6: 0 until the first `warMain` pass (which sets 1 and runs `warFirstPass`).
    public static let started = 0x08D6
    /// $0ACC: W ORs 1 (`keyDeclareWar`); the status line then shows 'WAR !!!!' and stores 3. A
    /// bomb on a target ORs 1 too.
    public static let declared = 0x0ACC
    /// $0AB2: war passes left in the current gun burst (`fireGuns` stores 3).
    public static let gunBurst = 0x0AB2
    /// $0AA5/$0AA6: rounds left (100 at rearm).
    public static let ammo = 0x0AA5
    /// $0AA7/$0AA8: the bomb-impact countdown. Nothing on the disk stores a nonzero value (the
    /// editor exit clears `$0AA7`), so in this image a bomb never reaches `bombImpact`'s scoring.
    public static let bombCountdown = 0x0AA7
    /// $0872: the points of the target the aircraft is over, stored by the WWI scenery lists
    /// (op 25 behind range boxes, blocks 49-50).
    public static let bombTargetScore = 0x0872
    /// $08B2: enemies shot down.
    public static let killCount = 0x08B2
    /// $08B7: times the player was hit (zeroed by `serviceAircraft`).
    public static let hitsTaken = 0x08B7
    /// $08B8: incremented by `serviceAircraft` ($3638) and by the first pass; consumed by
    /// `warServiceCheck`.
    public static let serviceCount = 0x08B8
    /// $08D1/$08D2: the score (wraps to 0 at 1000).
    public static let score = 0x08D1
    /// $08D4: incremented at the top damage threshold.
    public static let damageLevel = 0x08D4
    /// $08F5: the three score digits inside the SCORE record $08ED.
    public static let scoreDigits = 0x08F5
    /// $09BF: engine failure bits (bits 0-1 cap the RPM, bits 2-3 leak fuel).
    public static let engineFailureBits = 0x09BF

    // MARK: Overlay state ($A800-$A83A)

    /// $A800: the offset of the enemy record being updated (0, $1C, ... $8C).
    public static let enemyOffset = 0xA800
    /// $A801: loop index of the gunsight lines and of the panel fills (a row number).
    public static let loopIndex = 0xA801
    /// $A802-$A80A: target position − enemy position, three 24-bit differences in meters: east
    /// $A802, altitude $A805, north $A808 (`enemyDelta`).
    public static let delta = 0xA802
    /// $A80B/$A80C: the approximate 3D range (`enemyDistance`).
    public static let range = 0xA80B
    /// $A80D: 0 when the three high bytes of the delta XOR to 0 or $FF, else $7F (range too
    /// large to trust).
    public static let rangeOverflow = 0xA80D
    /// $A80E/$A80F, $A810/$A811: the delta rotated into the heading frame and scaled for the
    /// panel scope (across, along); $A812/$A813 sin, $A814/$A815 cos of the heading.
    public static let scopeAcross = 0xA80E
    public static let scopeAlong = 0xA810
    public static let headingSine = 0xA812
    public static let headingCosine = 0xA814
    /// $A816: an enemy fired this pass (bit 0 → 'ENEMYFIRE').
    public static let enemyFired = 0xA816
    /// $A817: an enemy is in the gunsight (3 → 'IN RANGE' and the gunsight pen; halved per
    /// status pass).
    public static let inRange = 0xA817
    /// $A818: passes until the rotating line advances (reloaded with 4).
    public static let rotationTimer = 0xA818
    /// $A819: the rotating line's item counter (taken modulo 4).
    public static let rotationIndex = 0xA819
    /// $A81A: the status record on screen: 0 blank, 1 IN RANGE, 2 ENEMYFIRE.
    public static let statusShown = 0xA81A
    /// $A81B: targets bombed.
    public static let targetsBombed = 0xA81B
    /// $A81C, $A828: the two enemy bases, laid out like the aircraft position $5A-$65 (bytes 1-3
    /// of each 32-bit axis). Dormant enemies fly back to the base their record points at.
    public static let baseA = 0xA81C
    public static let baseB = 0xA828
    /// $A834: the byte offset of the newest tracer record (steps of 6 up to $4E).
    public static let tracerSlot = 0xA834
    /// $A835: the tracer walk's cursor (the next record's offset).
    public static let tracerCursor = 0xA835
    /// $A836: passes the tracers are still drawn after the last burst (25, held at 1).
    public static let tracerTimer = 0xA836
    /// $A837: shots fired; bit 0 picks the left or right gun.
    public static let gunSide = 0xA837
    /// $A838: the enemy shape by range (0 far ... 4 near).
    public static let shapeIndex = 0xA838
    /// $A839/$A83A: the enemy's screen position (the dot list's projected point A).
    public static let enemyScreenX = 0xA839
    public static let enemyScreenY = 0xA83A

    // MARK: Overlay tables

    /// $A83B, $A849, $A857, $A865: the status records at (114, 117): 'WAR !!!!', 'IN RANGE',
    /// 'ENEMYFIRE', blank (each followed by a 00 00 list end).
    public static let warRecord: UInt16 = 0xA83B
    public static let inRangeRecord: UInt16 = 0xA849
    public static let enemyFireRecord: UInt16 = 0xA857
    public static let blankRecord: UInt16 = 0xA865
    /// $A87B, $A889: the three digits of the AMMO ($A873) and HITS ($A881) records.
    public static let ammoDigits: UInt16 = 0xA87B
    public static let hitsDigits: UInt16 = 0xA889
    /// $A88F: four record pointers of the rotating line (AMMO, SCORE, BOMBS, HITS).
    public static let rotationPointers = 0xA88F
    /// $A897: the enemy dot display list: op 24 (origin, scale 4, high words 0), op 00 (dot)
    /// with the point at $A8A0-$A8A5, END.
    public static let enemyDotList: UInt16 = 0xA897
    public static let enemyDotPoint = 0xA8A0
    /// $A8A7: the gunsight, 6 lines of (y1, x1, y2, x2).
    public static let gunsightLines = 0xA8A7
    /// $A8BF: 14 tracer records of 6 bytes (start age, age, target x, x, target y, y), then a
    /// record whose age byte is $FF ($A914) ending the list.
    public static let tracers = 0xA8BF
    /// $A915: the offsets of the five enemy shapes in $A91A.
    public static let shapeOffsets = 0xA915
    /// $A91A: enemy shapes: a line count, then (dx1, dy1, dx2, dy2) per line.
    public static let shapes = 0xA91A
    /// $A95B: six 28-byte enemy records (see `Field`).
    public static let enemyRecords = 0xA95B
    public static let recordSize = 0x1C
    public static let enemyCount = 6

    /// Byte offsets inside an enemy record.
    public enum Field {
        /// 24-bit east, altitude, north (meters; bytes 1-3 of the aircraft's 32-bit axes).
        public static let east = 0, altitude = 3, north = 6
        /// The scope row while the enemy shows on the panel scope (0 off it); it fires only then.
        public static let onScope = 9
        /// Nonzero while the enemy can be shot (3 in the gunsight, or the view number).
        public static let inSight = 10
        /// Dormant → attacking when the aircraft is west of `trigger east` and north of
        /// `trigger north` (high words, $5C/$5D against east, $64/$65 against north).
        public static let triggerEast = 11, triggerNorth = 13
        /// Attacking → dormant when the aircraft is east of `zone east` or south of
        /// `zone north`.
        public static let zoneEast = 15, zoneNorth = 17
        /// Per-axis steps per pass: east, altitude, north.
        public static let stepEast = 19, stepAltitude = 20, stepNorth = 21
        /// It fires when the range is below this.
        public static let fireRange = 22
        /// 0 shot down, 1 dormant, 2 attacking.
        public static let state = 23
        /// Passes of the climb (bit 7 clear) or sink (bit 7 set) after firing; reloaded from
        /// `reload`.
        public static let cooldown = 24, reload = 25
        /// Pointer to the enemy's base ($A81C or $A828).
        public static let base = 26
    }

    /// The 6502's binary subtract with carry: a − b − (1 − carry); the result and the carry out
    /// (set when nothing was borrowed).
    @inline(__always) static func sbc(_ a: UInt8, _ b: UInt8, _ carry: Bool) -> (UInt8, Bool) {
        let r = Int(a) - Int(b) - (carry ? 0 : 1)
        return (UInt8(truncatingIfNeeded: r), r >= 0)
    }
}

extension Machine {
    // MARK: Slot and main pass

    /// $A7EE (overlay slot 2): a jump to $AA03. 3 cycles + `warMain`.
    public func slotWar() {
        charge(3)
        warMain()
    }

    /// $AA03: one war pass, called every main-loop pass in Europe 1917 (through the slot).
    ///
    /// The first pass (`$08D6` = 0) sets `$08D6` = 1, runs `warFirstPass`, prints the score
    /// (`addWarScore(0)`) and increments `$08B8` so the service check below reprints the
    /// counters and makes every enemy dormant. Every pass: `warServiceCheck`, `drawWarScope`,
    /// `gunsAndTracers`, `bombImpact`; once war is declared (`$0ACC` ≠ 0) the six enemies
    /// (`enemyUpdate` with X = 0, $1C, ... $8C); in the front view (`$0ACA` = 0) outside the
    /// radar (`$0836` ≠ 1) the gunsight, six lines from $A8A7 with the pen `$A817`; then
    /// `warStatusLines`. Clobbers A, X, Y.
    public func warMain() {
        let m = mem
        var c = 4                                           // started?
        if m[War.started] == 0 {
            m[War.started] = 1
            charge(c + 14)                       // the first pass
            warFirstPass()
            charge(8)                                   // the score printed
            addWarScore(0)
            m[War.serviceCount] &+= 1
            c = 6                                           // forces the service check
        } else {
            c += 3
        }
        charge(c + 6)
        warServiceCheck()
        charge(6)
        drawWarScope()
        charge(6)
        gunsAndTracers()
        charge(6)
        bombImpact()
        c = 4                                               // war declared?
        if m[War.declared] != 0 {
            charge(c + 2)
            for k in 0..<War.enemyCount {
                charge(8)                               // the record offset, then the call
                enemyUpdate(UInt8(k * War.recordSize))
            }
            c = 0
        } else {
            c += 3
        }
        // $AA47: the gunsight.
        c += 4                                              // the view
        if m[0x0ACA] != 0 {
            c += 3                                          // not the front view
        } else {
            c += 8                                  // the radar?
            if m[0x0836] == 1 {
                c += 3
            } else {
                c += 15                              // the gunsight pen
                charge(c)
                setPen(m[War.inRange])
                c = 2                                       // the first line
                var x: UInt8 = 0
                repeat {
                    let line = War.gunsightLines + Int(x)
                    m[0xEC] = m[line]
                    m[0xEB] = m[line + 1]
                    m[0xEE] = m[line + 2]
                    m[0xED] = m[line + 3]
                    m[War.loopIndex] = x &+ 4
                    for k in 0..<4 { c += 4 + Machine.pageCrossing(War.gunsightLines + k, x) + 3 } // the line's endpoints
                    c += 19                  // the next line's index saved; draw
                    charge(c)
                    drawLine()
                    x = m[War.loopIndex]
                    c = 6                               // six lines done?
                    c += x < 0x18 ? 3 : 2
                } while x < 0x18
            }
        }
        charge(c + 6)
        warStatusLines()
        charge(6)
    }

    /// $B13E: the first pass. Disables the radios (`$FE` and `$09A7` lose bit 7), fills the
    /// rows $71-$AF at x $74-$9F with pen 0 (span color 0 through $8024, spans of 44 pixels,
    /// A = $2B, ending at x $9F) and paints the 8 × 11 cells from $7E4D (rows of 40) with color $10:
    /// the black status panel over the radio stack. Leaves `$A5/$A6` = $7F8D, `$A7` = 0,
    /// `$A801` = $B0. Clobbers A, X, Y.
    public func warFirstPass() {
        let m = mem
        m[0xFE] &= 0x7F
        m[0x09A7] &= 0x7F
        charge(29)              // the radios off; span color 0
        setSpanColor(0)
        m[War.loopIndex] = 0x71
        var c = 6                                       // the first row
        var y: UInt8 = 0x71
        repeat {
            m[0x8F] = m[Machine.rowAddressHi + Int(y)]
            m[0x8E] = m[Machine.rowAddressLo + Int(y)]
            m[0x1E] = 0x9F
            c += 4 + Machine.pageCrossing(Machine.rowAddressHi, y) + 7 + Machine.pageCrossing(Machine.rowAddressLo, y) + 3
            c += 16                              // a span of 44 pixels ending at x $9F
            charge(c)
            span(0x2B)
            m[War.loopIndex] &+= 1
            y = m[War.loopIndex]
            c = 12 + (y < 0xB0 ? 3 : 2)              // the next row, through $AF
        } while y < 0xB0
        m[0xA5] = 0x4D; m[0xA6] = 0x7E; m[0xA7] = 8
        c += 15
        repeat {
            let row = Int(m[0xA5]) | Int(m[0xA6]) << 8
            for k in 0...10 { m[(row + k) & 0xFFFF] = 0x10 }
            c += 2 + 2 + 11 * 8 + 10 * 3 + 2          // the row's 11 color cells
            let next = row + 0x28
            m[0xA5] = UInt8(truncatingIfNeeded: next)
            m[0xA6] = UInt8(truncatingIfNeeded: next >> 8)
            m[0xA7] &-= 1
            c += 31   // the pointer on by 40, the row count
            c += m[0xA7] != 0 ? 3 : 2
        } while m[0xA7] != 0
        charge(c + 6)
    }

    /// $B0FC (every pass): clears the panel scope, rows $78-$AA at x $73-$9F (span color 0,
    /// spans of 45 pixels, A = $2C, ending at x $9F), then draws the aircraft mark at its center
    /// ($5656/$5657, $5790-$5792) and the byte $564F. Leaves `$A801` = $AB. Clobbers A, X, Y.
    public func drawWarScope() {
        let m = mem
        charge(11)                                       // span color 0
        setSpanColor(0)
        m[War.loopIndex] = 0x78
        var c = 6                                       // the first row
        var y: UInt8 = 0x78
        repeat {
            m[0x8E] = m[Machine.rowAddressLo + Int(y)]
            m[0x8F] = m[Machine.rowAddressHi + Int(y)]
            m[0x1E] = 0x9F
            c += 4 + Machine.pageCrossing(Machine.rowAddressLo, y) + 7 + Machine.pageCrossing(Machine.rowAddressHi, y) + 3
            c += 16                              // a span of 45 pixels ending at x $9F
            charge(c)
            span(0x2C)
            m[War.loopIndex] &+= 1
            y = m[War.loopIndex]
            c = 12 + (y < 0xAB ? 3 : 2)              // the next row, through $AA
        } while y < 0xAB
        m[0x5656] = 0x30; m[0x5790] = 0x30; m[0x5791] = 0x30
        m[0x5657] = 0xFF
        m[0x5792] = 0xFC
        m[0x564F] = 0x03
        charge(c + 38)
    }

    // MARK: Status and counters

    /// $AE77 (end of every pass): the status line, the rotating line and the declaration.
    ///
    /// 1. `$A817` is halved: when its bit 0 was set, 'IN RANGE' ($A849); else `$A816` is halved
    ///    the same way: when its bit 0 was set, 'ENEMYFIRE' ($A857); else blank ($A865). The
    ///    record is drawn only when the choice differs from `$A81A` (0 blank, 1 IN RANGE,
    ///    2 ENEMYFIRE), which is then updated.
    /// 2. `$A818` counts down; at 0 it is reloaded with 4, `$A819` is incremented, and the record
    ///    of item `$A819 & 3` in $A88F is drawn (AMMO, SCORE, BOMBS, HITS).
    /// 3. When `$0ACC` = 1 (W was just pressed): `$0ACC` = 3, 'WAR !!!!' ($A83B), and the busy
    ///    wait of 328,707 cycles (charged one outer pass at a time).
    ///
    /// Clobbers A, X, Y.
    public func warStatusLines() {
        let m = mem
        let shown = m[War.statusShown]
        var c = 10                                       // the record shown; the in-range bit out
        let inRange = m[War.inRange]
        m[War.inRange] = inRange >> 1
        var record: UInt16? = nil
        if inRange & 1 != 0 {
            c += 4                                      // in range: already shown?
            if shown == 1 {
                c += 3
            } else {
                c += 15                  // 'IN RANGE'
                m[War.statusShown] = 1
                record = War.inRangeRecord
            }
        } else {
            c += 9                                      // the enemy-fire bit out
            let fired = m[War.enemyFired]
            m[War.enemyFired] = fired >> 1
            if fired & 1 != 0 {
                c += 4                                  // fired: already shown?
                if shown == 2 {
                    c += 3
                } else {
                    c += 15
                    m[War.statusShown] = 2
                    record = War.enemyFireRecord
                }
            } else {
                c += 5                                  // neither: already blank?
                if shown == 0 {
                    c += 3
                } else {
                    c += 12                  // blank
                    m[War.statusShown] = 0
                    record = War.blankRecord
                }
            }
        }
        if let record {
            charge(c + 6)
            drawTextList(record)
            c = 0
        }
        // $AEB2: the rotating line.
        m[War.rotationTimer] &-= 1
        c += 6                                              // the rotation timer
        if m[War.rotationTimer] != 0 {
            c += 3
        } else {
            m[War.rotationTimer] = 4
            m[War.rotationIndex] &+= 1
            let y = (m[War.rotationIndex] & 3) << 1
            let list = UInt16(m[War.rotationPointers + Int(y)]) | UInt16(m[War.rotationPointers + Int(y) + 1]) << 8
            c += 38  // reloaded; the next item's record drawn
            charge(c)
            drawTextList(list)
            c = 0
        }
        // $AECF: the declaration.
        c += 6                                          // just declared?
        if m[War.declared] != 1 {
            charge(c + 9)
            return
        }
        m[War.declared] = 3
        charge(c + 18)                   // marked as shown; 'WAR !!!!'
        drawTextList(War.warRecord)
        // The busy wait ($AEE2-$AEEB): two nested 256-count loops, an inner pass of 1,279 cycles
        // plus 5 to step the outer counter (4 on the last): 328,703 cycles, 328,707 with the two
        // counter loads. Charged one outer pass at a time so the clock's events keep their spacing.
        charge(4)                                       // both counters zeroed
        for pass in 0..<256 {
            charge(1281 + (pass < 255 ? 3 : 2))
        }
        charge(6)
    }

    /// $AE44 (every pass): when `$08B8` ≠ 0 (the aircraft was serviced, or the first pass):
    /// reprints AMMO (`printAmmo`) and HITS (`printHitsTaken`), clears `$08B8` and makes all six
    /// enemies dormant (state 1). Clobbers A, X.
    public func warServiceCheck() {
        let m = mem
        var c = 4
        if m[War.serviceCount] == 0 { charge(c + 9); return }
        charge(c + 8)
        printAmmo()
        charge(6)
        printHitsTaken()
        m[War.serviceCount] = 0
        c = 6                                           // the count cleared; the first record
        var x: UInt8 = 0
        repeat {
            m[War.enemyRecords + War.Field.state + Int(x)] = 1
            x &+= 0x1C
            c += 17 + (x < 0x8D ? 3 : 2)   // dormant; the next record
        } while x < 0x8D
        charge(c + 6)
    }

    /// $AE63: prints the hits taken `$08B7` into the HITS record ($A889, through `$2033`).
    /// Leaves X = `$A800`.
    public func printHitsTaken() {
        let m = mem
        m[0xB8] = m[War.hitsTaken]
        m[0xB9] = 0
        charge(25)                   // the value, the digits' address
        format3Digits(field: War.hitsDigits)
        charge(10)                                       // the record offset back in X
    }

    /// $B03A: prints the ammunition `$0AA5/$0AA6` into the AMMO record ($A87B, through `$2033`).
    public func printAmmo() {
        let m = mem
        m[0xB8] = m[War.ammo]
        m[0xB9] = m[War.ammo + 1]
        charge(27)
        format3Digits(field: War.ammoDigits)
        charge(6)
    }

    /// $B01D: spends a round: `$0AA5/$0AA6` − 1, held at 0; then `printAmmo`.
    public func spendRound() {
        let m = mem
        let (lo, k) = War.sbc(m[War.ammo], 1, true)
        m[War.ammo] = lo
        var c = 12                               // the low byte less 1
        if k {
            c += 3
        } else {
            let (hi, k2) = War.sbc(m[War.ammo + 1], 0, false)
            m[War.ammo + 1] = hi
            c += 12                              // the borrow from the high byte
            if k2 {
                c += 3
            } else {
                m[War.ammo] = 0
                m[War.ammo + 1] = 0
                c += 12
            }
        }
        charge(c)
        printAmmo()
    }

    /// $AFEE: adds A to the score `$08D1/$08D2`; a score of 1000 or more becomes 0; then prints
    /// it into the SCORE record ($08F5, through `$2033`).
    public func addWarScore(_ points: UInt8) {
        let m = mem
        let sum = Int(m[War.score]) + Int(points)
        let lo = UInt8(truncatingIfNeeded: sum)
        m[War.score] = lo
        var c = 10                                   // the low byte
        if sum > 0xFF {
            m[War.score + 1] &+= 1
            c += 8                                      // the carry into the high byte
        } else {
            c += 3
        }
        // The score against 1000 ($03E8): the low byte's compare feeds the carry of the high
        // byte's subtraction.
        let (_, atLeast1000) = War.sbc(m[War.score + 1], 3, lo >= 0xE8)
        c += 8
        if atLeast1000 {
            m[War.score] = 0
            m[War.score + 1] = 0
            c += 12
        } else {
            c += 3
        }
        m[0xB8] = m[War.score]
        m[0xB9] = m[War.score + 1]
        charge(c + 27)               // the value, the digits' address
        format3Digits(field: UInt16(War.scoreDigits))
        charge(6)
    }
}
