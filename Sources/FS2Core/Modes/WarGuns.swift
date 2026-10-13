/// The war overlay's guns, tracers and bombs ($AEED-$AFED). See `re/docs/war.md`.
extension Machine {
    // MARK: gunsAndTracers ($AEED)

    /// $AEED (every pass): the guns.
    ///
    /// 1. While a burst runs (`$0AB2` ≠ 0, 3 passes per `fireGuns`): `$0AB2` − 1, a round is
    ///    spent (`spendRound`), the tracer timer `$A836` = 25 and a tracer starts in the next
    ///    record (`$A834` + 6, wrapping from $54 to 0): age = its start age (byte 0), x = $27 or
    ///    $77 by bit 0 of the incremented `$A837` (left or right gun), y = $6F.
    /// 2. The tracer timer `$A836` counts down; at 0 it is put back to 1 and nothing more
    ///    happens (the tracers are no longer drawn 25 passes after the last shot).
    /// 3. Each record with a nonzero age, up to the age $FF ending the list at $A914: age − 1;
    ///    when the age was below $0B, the first enemy with its in-sight flag (rec+10) set is shot
    ///    down (state and flag 0, `addWarScore(1)`, `$08B2` + 1); then x and y move a quarter of
    ///    the way toward the record's targets (an arithmetic shift of the 8-bit difference) and,
    ///    in the front view outside the radar, the tracer is plotted with pen 3.
    ///
    /// Clobbers A, X, Y.
    public func gunsAndTracers() {
        let m = mem
        let T = War.tracers
        var c = 4                                           // the burst counter
        if m[War.gunBurst] != 0 {
            m[War.gunBurst] &-= 1
            charge(c + 14)                           // a burst pass used; spend a round
            spendRound()
            m[War.tracerTimer] = 0x19
            var slot = m[War.tracerSlot] &+ 6
            c = 16                       // the timer reloaded, the next tracer slot
            if slot == 0x54 { slot = 0; c += 4 } else { c += 3 }
            m[War.tracerSlot] = slot
            var y = slot
            c += 10 + Machine.pageCrossing(T, y)     // the slot stored; its start age
            let age = m[T + Int(y)]
            y &+= 1
            m[T + Int(y)] = age
            y &+= 2
            m[War.gunSide] &+= 1
            let right = m[War.gunSide] & 1 != 0
            c += 25              // the age copied, the shot counted, its bit 0 tested
            c += right ? 4 : 3                          // the left or right gun's x
            m[T + Int(y)] = right ? 0x77 : 0x27
            y &+= 2
            c += 11                              // x stored; on to y
            c += right ? 4 : 3                          // a second side test: both sides load the same y
            m[T + Int(y)] = 0x6F
            c += 5
        } else {
            c += 4                                          // no burst (the skip crosses a page)
        }
        // $AF31
        m[War.tracerTimer] &-= 1
        c += 6
        if m[War.tracerTimer] == 0 {
            m[War.tracerTimer] = 1
            charge(c + 14)                           // expired: held at 1, done
            return
        }
        c += 5                                          // still running: walk the records
        var x: UInt8 = 0
        while true {
            // $AF3C: the next record with a nonzero age.
            x &+= 1
            c += 6 + Machine.pageCrossing(T, x)         // the record's age
            var age = m[T + Int(x)]
            if age == 0 {
                x &+= 5
                c += 10                      // an idle record: skip it
                if x != 0 { c += 3; continue }
                c += 2
                age = 0                                     // falls into $AF49 with A = X = 0
            } else {
                c += 3
            }
            // $AF49
            c += 2                                          // the list end?
            if age == 0xFF { charge(c + 8); return }
            m[T + Int(x)] = m[T + Int(x)] &- 1
            c += 12                                  // age − 1; young enough to hit?
            if age >= 0x0B {
                c += 3
            } else {
                c += 4                                  // scan the enemies
                var y: UInt8 = 0
                var hit = false
                while true {
                    c += 4 + Machine.pageCrossing(War.enemyRecords + War.Field.inSight, y)
                    if m[War.enemyRecords + War.Field.inSight + Int(y)] != 0 { c += 3; hit = true; break }
                    y &+= 0x1C
                    c += 12              // the next enemy record
                    if y >= 0x8D { c += 5; break }      // none in sight
                    c += 3
                }
                if hit {
                    m[War.enemyRecords + War.Field.state + Int(y)] = 0
                    m[War.enemyRecords + War.Field.inSight + Int(y)] = 0
                    charge(c + 25)   // shot down (the record index kept on the stack): one point
                    addWarScore(1)
                    m[War.killCount] &+= 1
                    c = 12                           // the kill counted, the index back
                }
            }
            // $AF7B: x and y a quarter of the way toward the targets.
            c += 2                                          // two axes
            var moved: (x: UInt8, y: UInt8) = (0, 0)
            for axis in 0..<2 {
                x &+= 1
                let target = m[T + Int(x)]
                c += 6 + Machine.pageCrossing(T, x)     // the target
                x &+= 1
                let current = m[T + Int(x)]
                let step = UInt8(bitPattern: Int8(bitPattern: target &- current) >> 2)
                let value = current &+ step
                m[T + Int(x)] = value
                // The quarter step: the difference shifted right twice with its sign kept by
                // saving and restoring the flags on the stack, added back and stored; the new
                // value is also pushed for the plot.
                c += 8 + Machine.pageCrossing(T, x) + 24
                c += 4 + Machine.pageCrossing(T, x) + 10
                c += axis == 0 ? 3 : 2                      // the axis loop
                if axis == 0 { moved.x = value } else { moved.y = value }
            }
            x &+= 1
            m[War.tracerCursor] = x
            charge(c + 17)                       // the cursor saved; pen 3
            setPen(3)
            c = 16                           // the new x and y off the stack; the view
            if m[0x0ACA] != 0 {
                c += 3                                      // not the front view
            } else {
                c += 6                                  // front view: the radar?
                if m[0x0836] != 0 {
                    c += 3
                } else {
                    charge(c + 11)                       // the plot
                    plot(x: moved.x, row: moved.y)
                    c = 0
                }
            }
            x = m[War.tracerCursor]
            c += 7                                      // on to the next record
        }
    }

    // MARK: bombImpact ($AFB9)

    /// $AFB9 (every pass): the bomb countdown `$0AA7/$0AA8` (never started in this image; see
    /// `War.bombCountdown`). While
    /// it is nonzero: `$0AA7` = (`$0AA8` | `$0AA7`) − $32 and `$0AA8` − 1 on a borrow; when
    /// `$0AA8` reaches $FF the bomb lands: with a target under it (`$0872` ≠ 0) the score gains
    /// `$0872` (`addWarScore`), `$A81B` + 1 and war is declared (`$0ACC` |= 1); the countdown
    /// becomes 0. `$0872` is cleared on every countdown pass. Clobbers A, X, Y.
    public func bombImpact() {
        let m = mem
        var y = m[War.bombCountdown + 1]
        var a = y | m[War.bombCountdown]
        var c = 10                                   // both countdown bytes
        if a == 0 { charge(c + 9); return }             // not running
        let (r, k) = War.sbc(a, 0x32, true)
        a = r
        c += 6                                      // the low byte less $32
        if k { c += 3 } else { y &-= 1; c += 4 }        // a borrow from the high byte
        c += 2                                              // run out?
        if y != 0xFF {
            c += 3
        } else {
            c += 6                                      // landed: the target's points
            let points = m[War.bombTargetScore]
            if points == 0 {
                c += 3                                      // no target under it
            } else {
                charge(c + 8)
                addWarScore(points)
                m[War.targetsBombed] &+= 1
                m[War.declared] |= 1
                c = 16                           // a target bombed; war declared
            }
            a = 0
            y = 0
            c += 4                                      // the countdown over
        }
        m[War.bombCountdown] = a
        m[War.bombCountdown + 1] = y
        m[War.bombTargetScore] = 0
        charge(c + 20)                       // stored back; the target points cleared
    }
}
