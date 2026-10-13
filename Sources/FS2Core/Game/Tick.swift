/// The 10 Hz tick body $2348-$2417, run by the poll `pollTick` ($2330) once per 6 frames (with
/// catch-up): one queued key, the engine pitch, the key repeat of slots 3 and 2, the bomb whistle;
/// on even ticks (5 Hz, not paused) the aerodynamics, the airspeed and VSI needles, the joysticks
/// and the auto-centering; on a CIA1 time-of-day second (not paused) the sound state machine and
/// the clock, with the trim creep on even seconds.
extension Machine {
    /// $2348 `tick10Hz`: the 10 Hz work (see the type comment and `re/docs/main-loop.md`). Reads
    /// the TOD seconds `$DC09` through `readIO`. Charges from $2348 through its return. Clobbers A,
    /// X, Y.
    public func tick10Hz() {
        let m = mem
        let R = MainLoop.RAM.self
        let I = Input.RAM.self
        // One queued key, unless the queue is empty or key dispatch is inhibited (`$08C3`).
        if m[I.keyQueueRead] == m[I.keyQueueWrite] {
            charge(11)
        } else if m[I.keyDispatchInhibit] != 0 {
            charge(17)
        } else {
            charge(22)
            dispatchKey()
        }
        charge(6)
        engineSoundSlew()
        // The key repeat: slot 3 then slot 2. An occupied slot whose counter is 0 requeues its key
        // ($24EB, with the matrix index); a nonzero counter counts down. The counter stays 0, so a
        // held key repeats every tick.
        for slot in [3, 2] {
            let index = m[I.heldKeySlots + slot]
            let counter = 0x0E71 + slot
            if index & 0x80 != 0 {
                charge(7)
            } else if m[counter] == 0 {
                charge(18)
                requeueKey(index)
                charge(3)                                   // past the countdown
            } else {
                m[counter] &-= 1
                charge(19)
            }
        }
        bombWhistleSweep()                                  // $2381, falls into $239B
        // $239B: the tick counted; odd ticks skip the 5 Hz work (to $23CD).
        m[R.tickCounter] &+= 1
        if m[R.tickCounter] & 1 == 0 {
            // Paused: out through the return at $2347.
            if m[R.pauseCount] != 0 {
                charge(27)
                return
            }
            charge(20)
            // The quick-repeat window counts down.
            if m[R.quickRepeatWindow] != 0 {
                m[R.quickRepeatWindow] &-= 1
                charge(12)
            } else {
                charge(7)
            }
            charge(6)
            aeroUpdate()
            charge(6)
            updateAirspeedNeedle()
            charge(6)
            updateVsiNeedle()
            // Either joystick moved: the joystick action.
            if m[I.joyPort1] | m[I.joyPort2] != 0 {
                charge(16)
                joystickAction()
            } else {
                charge(11)
            }
            // A joystick in use: the auto-centering.
            if m[I.joystickUsed] != 0 {
                charge(12)
                autoCenter()
            } else {
                charge(7)
            }
        } else {
            charge(15)
        }
        // $23CD: a new TOD second? (the skip to $2413 crosses a page)
        let seconds = readIO(0xDC09)
        guard seconds != m[R.lastTodSeconds] else {
            charge(18)                           // the same second: the return
            return
        }
        m[R.lastTodSeconds] = seconds
        // The second remembered; paused: out (again across a page to $2413).
        guard m[R.pauseCount] == 0 else {
            charge(28)
            return
        }
        charge(26)                   // the sound state machine
        soundTick()
        // The clock: the seconds roll over at 60 into the minutes, the minutes at 60 into the
        // hours, the hours at 24 to 0 (the seconds test's branch crosses a page). A rollover sets
        // the field to $FF first, so every path shares the same increment and store.
        var c = 6
        var x = m[R.clockSeconds]
        if x != 59 {
            c += 4
        } else {
            c += 8
            var y = m[R.clockMinutes]
            if y != 59 {
                c += 3
            } else {
                c += 2
                m[R.clockHours] &+= 1
                c += 12
                if m[R.clockHours] != 24 {
                    c += 3
                } else {
                    m[R.clockHours] = 0
                    c += 8
                }
                y = 0xFF
                c += 2                                      // the minutes wrap
            }
            y &+= 1
            m[R.clockMinutes] = y
            x = 0xFF
            c += 8                                  // the minutes stored, the seconds wrap
        }
        x &+= 1
        m[R.clockSeconds] = x
        charge(c + 12)                               // the seconds stored, the readout call
        drawClockSeconds()
        // The trim creep on even seconds ($2414), then the return.
        if m[R.lastTodSeconds] & 1 != 0 {
            charge(14)
        } else {
            charge(15)
            trimCreep()
            charge(6)
        }
    }
}
