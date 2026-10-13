import C64Kit

/// The keyboard matrix scan, the held-key slots, the key ring and the RESTORE handler
/// ($2418-$25EA, $2700-$2714). The frame IRQ ($22CD) runs `keyScan` on keyboard phase 0 and
/// `keyReleaseCheck` on phase -1 (then reloads `$08A6` = 3); the 10 Hz tick ($2348) dequeues one
/// key (`dispatchKey`) and re-queues the keys held in slots 3 and 2 (`requeueKey`).
extension Machine {
    // MARK: keyScan ($2418)

    /// $2418 (frame IRQ, keyboard phase 0): scans the 8 columns ($DC00 = $FE..$7F, the column
    /// index base `$0899` = 0, 8, ... $38, the rolling select `$089A`). For each column
    /// `sampleCia1` samples both joystick ports around the column drive; a joystick bit low aborts
    /// the whole scan through $2557 (`joystickLatch`), which returns for keyScan. Otherwise a
    /// pending `$0E6A` is cleared, and when the row read is not $FF each row bit that is low
    /// (`$089F` row, `$08A0` mask) calls `keyPress` with the matrix index column·8 + row.
    /// Clobbers A, X, Y.
    public func keyScan() {
        let m = mem
        let R = Input.RAM.self
        m[R.scanColumnIndex] = 0
        var select: UInt8 = 0xFE
        m[R.scanColumnSelect] = select
        var c = 12                                          // column 0, select $FE
        while true {
            charge(c + 6)
            let sample = sampleCia1(column: select)
            if sample.joystick {
                charge(5)                                   // hand off to the latch, which ends the scan
                joystickLatch(y: sample.y)
                return
            }
            c = 7                                           // keyboard only: test the latch flag
            if m[R.joystickLatched] != 0 {
                m[R.joystickLatched] = 0
                c += 12                                     // a stale latch is cleared
            } else {
                c += 2
            }
            c += 2                                          // is any row low?
            if sample.x == 0xFF {
                c += 3                                      // no key down in this column
            } else {
                m[R.scanRow] = 0
                m[R.scanRowMask] = 1
                c += 14                                     // start at row 0, mask $01
                var mask: UInt8 = 1
                while true {
                    c += 4                                  // test this row's bit
                    if mask & m[R.joyPort2Sample] != 0 {
                        c += 3                              // key up
                    } else {
                        let index = m[R.scanColumnIndex] &+ m[R.scanRow]
                        charge(c + 18)                      // key down: index column·8 + row
                        c = 0
                        keyPress(index)
                    }
                    // Next row; the mask bit leaving bit 7 ends the column.
                    m[R.scanRow] &+= 1
                    let shifted = m[R.scanRowMask]
                    mask = shifted << 1
                    m[R.scanRowMask] = mask
                    c += 16
                    if shifted & 0x80 == 0 { c += 3 } else { c += 2; break }
                }
            }
            // $2457: next column. The index steps by 8 and the select rotates left with a 1 in;
            // the scan ends after the $7F column, whose select has bit 7 clear.
            m[R.scanColumnIndex] &+= 8
            let rolled = m[R.scanColumnSelect]
            select = rolled << 1 | 1
            m[R.scanColumnSelect] = select
            c += 26
            if rolled & 0x80 != 0 { c += 3 } else { c += 2; break }
        }
        charge(c + 6)
    }

    // MARK: sampleCia1 ($2574)

    /// $2574: samples CIA1 around a column drive. $DC00 = $FF, then port 2 (`$DC00`) into `$08A1`
    /// and port 1 (`$DC01`) into `$08A2`; $DC00 = X and the row read (`$DC01`) into X; $DC00 =
    /// $FF and both ports again into `$08A3`/`$08A4`. When none of the four samples has a 0 bit
    /// the row read goes to `$08A1` and C = 0. Otherwise a joystick is active: C = 1, and Y = $00
    /// when the two samples of each port agree, $FF when they differ (only possible if the input
    /// changes between the samples, which the deterministic input model never does).
    ///
    /// - Returns: `joystick` (C), `x` (the row read) and `y`.
    public func sampleCia1(column x: UInt8) -> (joystick: Bool, x: UInt8, y: UInt8) {
        let m = mem
        let R = Input.RAM.self
        let k = io.keyboard
        // Both joystick ports with no column driven.
        let port2 = k.readPortA(portAOut: 0xFF, portB: 0xFF)
        m[R.joyPort2Sample] = port2
        let port1 = k.readPortB(portA: 0xFF, portBOut: 0xFF)
        m[R.joyPort1Sample] = port1
        // The column's row read, then both ports again with the column released.
        let rows = k.readPortB(portA: x, portBOut: 0xFF)
        let port2Again = k.readPortA(portAOut: 0xFF, portB: 0xFF)
        let port1Again = k.readPortB(portA: 0xFF, portBOut: 0xFF)
        m[R.joyPort2Sample2] = port2Again
        m[R.joyPort1Sample2] = port1Again
        // A 0 bit in any of the four port samples means a joystick is active.
        let c = 2 + 4 * 15 + 2
        if port1Again & m[R.joyPort2Sample2] & m[R.joyPort2Sample] & m[R.joyPort1Sample] == 0xFF {
            m[R.joyPort2Sample] = rows
            charge(c + 14)                                  // keyboard only: the row read replaces the sample
            return (false, rows, port2Again)
        }
        // $25AC: Y tells whether each port read the same twice.
        if m[R.joyPort2Sample] != m[R.joyPort2Sample2] {
            charge(c + 24)
            return (true, rows, 0xFF)
        }
        if m[R.joyPort1Sample] != m[R.joyPort1Sample2] {
            charge(c + 34)
            return (true, rows, 0xFF)
        }
        charge(c + 33)
        return (true, rows, 0x00)
    }

    /// $2557 (jumped to from `keyScan` and `keyReleaseCheck`, so its return ends them): when
    /// the samples agreed (Y = 0), `$0E6A` = 1 and the latches `$0E6E` = ~port 2 & $1F and
    /// `$0E6F` = ~port 1 & $1F (active-high, consumed by `joystickAction` at 5 Hz). Y = $FF
    /// returns without latching.
    private func joystickLatch(y: UInt8) {
        let m = mem
        let R = Input.RAM.self
        guard y != 0xFF else { charge(11); return }         // the samples disagreed
        m[R.joystickLatched] = 1
        m[R.joyPort2] = ~m[R.joyPort2Sample] & 0x1F
        m[R.joyPort1] = ~m[R.joyPort1Sample] & 0x1F
        charge(40)
    }

    // MARK: Held-key slots ($24C2-$2504)

    /// $24C2: a key seen down by the scan (A = matrix index). Ignored when a slot already holds
    /// it; otherwise it takes the first free slot from 3 down (bit 7 of its `$089B` entry), with
    /// repeat delay `$0E71`[slot] = 5, and falls into `requeueKey`. With all four slots taken the
    /// key is lost. Clobbers A, X, Y.
    public func keyPress(_ index: UInt8) {
        let m = mem
        let R = Input.RAM.self
        var c = 0
        for slot in 0..<4 {
            c += 4
            if index == m[R.heldKeySlots + slot] { charge(c + 9); return }   // already held
            c += 2
        }
        c += 4                                              // look for a free slot from 3 down
        var x = 3
        while true {
            c += 4
            if m[R.heldKeySlots + x] & 0x80 != 0 { c += 3; break }   // free
            c += 4
            x -= 1
            if x < 0 { charge(c + 8); return }              // all four taken: the key is lost
            c += 3
        }
        m[R.heldKeySlots + x] = index
        m[R.repeatCounters + x] = 5
        charge(c + 14)                                      // claim the slot, repeat delay 5
        requeueKey(index)
    }

    /// $24EB (also called from the 10 Hz tick for the slots 3 and 2, Y = slot): queues the code
    /// `$2482`[Y] of matrix index Y, minus $40 while CTRL is held (`$0E67`; a code below $40 then
    /// wraps to $C0-$FF). Codes ≥ $80 are not queued; CTRL ($FB) sets `$0E67` instead.
    /// Clobbers A, X.
    public func requeueKey(_ index: UInt8) {
        let m = mem
        let R = Input.RAM.self
        var code = m[Input.Table.keyCodeTable + Int(index)]
        var c = 4 + Machine.pageCrossing(Input.Table.keyCodeTable, index)
        if code & 0x80 == 0 {
            c += 6                                          // a queueable code: is CTRL held?
            if m[R.ctrlHeld] != 0 { c += 6; code &-= 0x40 } else { c += 3 }   // CTRL shifts it down
            charge(c + 3)                                   // tail jump to enqueueKey
            enqueueKey(code)
            return
        }
        c += 5                                              // never queued: only CTRL matters
        if code == Input.ctrlCode {
            m[R.ctrlHeld] = 1
            c += 8                                          // CTRL pressed
        } else {
            c += 4                                          // the branch to the return crosses a page ($24FF → $2504)
        }
        charge(c + 6)
    }

    // MARK: keyReleaseCheck ($2505)

    /// $2505 (frame IRQ, keyboard phase -1): for each held slot from 3 down, drives the slot's
    /// column (`$247A`[index >> 3]) through `sampleCia1`; a joystick bit low aborts through $2557.
    /// When the key's row bit (`$2472`[index & 7]) reads high the slot is freed ($80), and if the
    /// key's code is CTRL, `$0E67` is cleared. Uses `$0898` (index, then slot) and `$08A5`.
    /// Clobbers A, X, Y.
    public func keyReleaseCheck() {
        let m = mem
        let R = Input.RAM.self
        var c = 2                                           // start at slot 3
        var x = 3
        while true {
            let slot = m[R.heldKeySlots + x]
            c += 4
            if slot & 0x80 != 0 {
                c += 2                                      // a free slot
            } else {
                // $2510: keep the index and the slot, then drive the key's column.
                m[R.releaseIndex] = slot
                m[R.releaseSlot] = UInt8(x)
                let column = slot >> 3
                let select = m[Input.Table.columnSelects + Int(column)]
                charge(c + 23 + Machine.pageCrossing(Input.Table.columnSelects, column) + 6)
                let sample = sampleCia1(column: select)
                if sample.joystick {
                    charge(5)                               // hand off to the latch, which ends the check
                    joystickLatch(y: sample.y)
                    return
                }
                // $2525: restore the slot and test the key's row bit.
                x = Int(m[R.releaseSlot])
                let mask = m[Input.Table.rowBitMasks + Int(m[R.releaseIndex] & 7)]
                c = 23
                if mask & m[R.joyPort2Sample] == 0 {
                    c += 3                                  // still down
                } else {
                    m[R.heldKeySlots + x] = 0x80
                    let index = m[R.releaseIndex]
                    let code = m[Input.Table.keyCodeTable + Int(index)]
                    // Released: free the slot and look up the key's code.
                    c += 17 + Machine.pageCrossing(Input.Table.keyCodeTable, index)
                    if code & 0x80 == 0 {
                        c += 3                              // an ordinary key
                    } else {
                        m[R.releaseIndex] = UInt8(x)
                        c += 8                              // never queued: the slot moves to $0898, is it CTRL?
                        if code == Input.ctrlCode {
                            m[R.ctrlHeld] = 0
                            c += 11                         // CTRL released
                        } else {
                            c += 3
                        }
                        x = Int(m[R.releaseIndex])
                        c += 7                              // back into the loop with the slot
                    }
                }
            }
            // $250C: the next slot down.
            x -= 1
            c += 2
            if x < 0 { c += 2; break }
            c += 3
        }
        charge(c + 6)
    }

    // MARK: The key ring ($25C4-$25EA)

    /// $25C4 (vector $203C): pops one code from the ring `$08A9` (read index `$08A8` += 1, slot
    /// index & 7). With the ring empty (read = write) returns C = 0 and A = the read index.
    @discardableResult
    public func dequeueKey() -> (code: UInt8, carry: Bool) {
        let m = mem
        let R = Input.RAM.self
        let read = m[R.keyQueueRead]
        guard read != m[R.keyQueueWrite] else { charge(18); return (read, false) }
        let next = read &+ 1
        m[R.keyQueueRead] = next
        let code = m[R.keyQueue + Int(next & 7)]
        charge(37)
        return (code, true)
    }

    /// $25DC: pushes A to the ring (write index `$08A7` += 1, slot index & 7). There is no
    /// overflow check: a ninth pending key overwrites the oldest, and the read index then sees
    /// the ring as empty or skips keys.
    public func enqueueKey(_ code: UInt8) {
        let m = mem
        let R = Input.RAM.self
        let write = m[R.keyQueueWrite] &+ 1
        m[R.keyQueueWrite] = write
        m[R.keyQueue + Int(write & 7)] = code
        charge(32)
    }

    // MARK: restoreNmi ($2700)

    /// $2700 (the NMI vector, set at $AB0E; RESTORE): when slot 3 holds RUN/STOP (`$089E` = $3F,
    /// so RUN/STOP must be the first key held) and the one-shot `$26FF` is 0, increments `$26FF`
    /// and the original jumps to the cold restart $A7E2 (which reloads `$26FF` = 0). Otherwise it
    /// returns from the interrupt. Charges from $2700 through that return or the jump to $A7E2;
    /// the 7-cycle interrupt entry belongs to the caller.
    ///
    /// - Returns: true when the cold restart at $A7E2 is due (the caller performs it).
    public func restoreNmi() -> Bool {
        let m = mem
        let R = Input.RAM.self
        // Only RUN/STOP in slot 3 can arm the restart.
        guard m[R.heldKeySlots + 3] == Input.runStopIndex else { charge(22); return false }
        guard m[R.restoreOneShot] == 0 else { charge(28); return false }
        m[R.restoreOneShot] &+= 1
        charge(26)                                          // one-shot taken: off to the cold restart
        return true
    }
}
