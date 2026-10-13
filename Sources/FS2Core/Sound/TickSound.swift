/// The sound work of the 10 Hz tick ($2348): the engine drone pitch slew ($E500) and the bomb
/// whistle sweep ($2381). Both run on every tick, paused or not, and whether sound is on or off.
extension Machine {
    /// $E500 `engineSoundSlew`: moves the engine value E = `$09BE` (RPM/50) toward the target
    /// T = `$0E58` by 2 and retunes the drone. Called from the 10 Hz tick at $2358.
    ///
    /// - E == T: returns without touching the SID (`sfxReset` bumps `$09BE` to force a rewrite).
    /// - E > T: E − 2, but T if that is below T or (unsigned) at least $F0, which also catches
    ///   E ≥ $F2 snapping straight to T.
    /// - E < T: E + 2 (8-bit wrap kept), but T if that reaches T.
    ///
    /// Then V1 = (E >> 1) × 16 → $D400/$D401 and V2 = 2 × V1 + 1 → $D407/$D408, built in the scratch
    /// bytes `$0E52` and `$0E54` (an octave up, detuned by one step). Charges 17 cycles when
    /// E == T, otherwise 114 to 119.
    public func engineSoundSlew() {
        // Already on target: nothing to do.
        let current = self[SoundDriver.RAM.engineRpm]
        let target = self[SoundDriver.RAM.engineTargetRpm]
        if current == target {
            charge(17)
            return
        }
        var cycles = 10
        var a: UInt8
        if current > target {
            // Slewing down: a wrap below zero (at least $F0) or an overshoot snaps to the target.
            a = current &- 2
            cycles += 6
            if a >= 0xF0 {
                cycles += 3
                a = target                      // $E515: the target
                cycles += 4
            } else {
                cycles += 6
                if a >= target {
                    cycles += 3
                } else {
                    cycles += 2
                    a = target
                    cycles += 4
                }
            }
        } else {
            // Slewing up (the branch to $E550 is taken): reaching the target snaps to it.
            a = current &+ 2
            cycles += 9
            if a >= target {
                cycles += 3
                a = target
                cycles += 4
            } else {
                cycles += 5
            }
        }
        // $E518: store E, then V1 = (E >> 1) × 16, shifted as a 16-bit value through `$0E52`.
        self[SoundDriver.RAM.engineRpm] = a
        var lo = a >> 1
        var hi: UInt8 = 0
        for _ in 0..<4 {
            hi = hi << 1 | lo >> 7
            lo <<= 1
        }
        self[SoundDriver.RAM.engineFreqV1Hi] = hi
        cycles += 4 + 2 + 2 + 4 + 4 * 8
        // The V1 frequency, low byte first.
        storeSID(SoundDriver.Reg.voice1FreqLo, lo, after: cycles)
        storeSID(SoundDriver.Reg.voice1FreqHi, hi, after: 8)
        // V2 = 2 × V1 + 1, built through `$0E54`. The carry into the add is bit 7 of the V1 high
        // byte, which is never set (at most 7), but the port keeps the chain.
        let aslCarry = lo >> 7
        let v2Lo = lo << 1
        let rolCarry = hi >> 7
        let v2Hi = hi << 1 | aslCarry
        self[SoundDriver.RAM.engineFreqV2Hi] = v2Hi
        let sum = UInt16(v2Lo) + 1 + UInt16(rolCarry)
        storeSID(SoundDriver.Reg.voice2FreqLo, UInt8(truncatingIfNeeded: sum), after: 18)
        // The V2 high byte takes the add's carry.
        var x = self[SoundDriver.RAM.engineFreqV2Hi]
        cycles = 8
        if sum > 0xFF {
            x &+= 1
            cycles += 4
        } else {
            cycles += 3
        }
        storeSID(SoundDriver.Reg.voice2FreqHi, x, after: cycles)
        charge(10)
    }

    /// $2381-$239A `bombWhistleSweep`: the bomb-whistle part of the 10 Hz tick (a fragment of
    /// $2348, not a subroutine; the tick continues at $239B). While bit 7 of `$0E7E` is clear,
    /// `$0E7D/$0E7E -= $F0` and the new value goes to $D40E/$D40F, low byte first: about 14.6 Hz
    /// lower every 6 frames, starting at $4948 (1143.6 Hz) after a release. The sweep stops when
    /// `sfxBombWait` sets `$0E7E = $FF` for the explosion, or by itself once the value wraps below
    /// zero (with sound off the explosion never comes). Charges 7 or 34 cycles.
    public func bombWhistleSweep() {
        // The sweep is off while bit 7 is set: on to $239B.
        let hi = self[SoundDriver.RAM.bombWhistleFrequency + 1]
        if hi & 0x80 != 0 {
            charge(7)
            return
        }
        // The low byte down by $F0, to the SID.
        let lo = self[SoundDriver.RAM.bombWhistleFrequency]
        let newLo = lo &- 0xF0
        let borrow: UInt8 = lo < 0xF0 ? 1 : 0
        self[SoundDriver.RAM.bombWhistleFrequency] = newLo
        storeSID(SoundDriver.Reg.voice3FreqLo, newLo, after: 18)
        // The borrow taken from the high byte, to the SID.
        let newHi = hi &- borrow
        self[SoundDriver.RAM.bombWhistleFrequency + 1] = newHi
        storeSID(SoundDriver.Reg.voice3FreqHi, newHi, after: 12)
        charge(4)
    }
}
