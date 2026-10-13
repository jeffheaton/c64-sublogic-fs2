/// The voice-3 gate-pattern player: the part of the frame IRQ ($22C8-$22CC) that counts down
/// `$0E5B`, and the step at $230A. It is the only writer of $D412 outside the effect handlers.
extension Machine {
    /// $22C8-$22CC plus $230A-$232D `patternPlayerFrame`: the pattern player's share of the frame
    /// tick. Counts `$0E5B` down; at zero, runs `patternStep()`. The original then continues with
    /// the keyboard phase at $22CD, which is not part of the sound driver.
    ///
    /// Runs once per video frame inside the raster IRQ $2285 (window phase, after the frame
    /// counters `$34` and `$0E6B` are bumped) and inside the alternate IRQ $2304 used during text
    /// mode and disk I/O, so it keeps running while the main loop is busy or paused. A countdown
    /// that wraps from 0 waits 256 frames. Charges 8 cycles, or 10 plus the step (the branch to
    /// $230A crosses a page).
    public func patternPlayerFrame() {
        // The frame countdown.
        let countdown = self[SoundDriver.RAM.patternCountdown] &- 1
        self[SoundDriver.RAM.patternCountdown] = countdown
        if countdown != 0 {
            charge(8)
            return
        }
        charge(10)
        patternStep()
    }

    /// $230A `patternStep`: one step of the 8-bit gate rhythm.
    ///
    /// 1. `$0E5B = $0E5A` (the step period in frames).
    /// 2. If `$2308 & 7 == 0`, reload the shift register: `$2309 = $0E5E`.
    /// 3. `$2308` += 1.
    /// 4. Shift `$2309` right: $D412 = `$0E60` if a 1 was shifted out, else $00 (written every step).
    ///
    /// Charges 43 to 51 cycles, including the jump back into the frame tick at $22CD.
    public func patternStep() {
        // Reload the countdown; every eighth step reloads the rhythm too.
        self[SoundDriver.RAM.patternCountdown] = self[SoundDriver.RAM.patternPeriod]
        var cycles = 14
        if self[SoundDriver.RAM.patternStepCounter] & 0x07 == 0 {
            self[SoundDriver.RAM.patternShift] = self[SoundDriver.RAM.gatePattern]
            cycles += 10
        } else {
            cycles += 3
        }
        // Count the step and gate voice 3 by the bit shifted out.
        self[SoundDriver.RAM.patternStepCounter] &+= 1
        var control = self[SoundDriver.RAM.voice3Control]
        let shift = self[SoundDriver.RAM.patternShift]
        self[SoundDriver.RAM.patternShift] = shift >> 1
        cycles += 16
        if shift & 1 != 0 {
            cycles += 3
        } else {
            control = 0x00
            cycles += 4
        }
        // Written every step, then back to the frame tick.
        storeSID(SoundDriver.Reg.voice3Control, control, after: cycles)
        charge(7)
    }
}
