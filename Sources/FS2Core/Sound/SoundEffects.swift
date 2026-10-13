/// The effect handlers of the 1 Hz state machine ($CC46-$CE83), in the order of the original.
/// Each one is a straight list of stores; the port keeps the order, the values and the stores the
/// original leaves out (for example the stall horn writes only the frequency high byte).
extension Machine {
    /// $CC46 `sfxStallHorn` (state 1): voice 3 sawtooth with only $D40F = $18 written, so the low
    /// byte left by an earlier effect stays (0 after the clear: 374.5 Hz). AD $00, SR $A0, pattern
    /// $FF, gated at once. Exits to state 9, so the horn stops on the next tick unless $3016 re-arms
    /// state 1 in between. Charges 53 cycles.
    public func sfxStallHorn() {
        storeSID(SoundDriver.Reg.voice3FreqHi, 0x18, after: 2)
        storeSID(SoundDriver.Reg.voice3AttackDecay, 0x00, after: 6)
        storeSID(SoundDriver.Reg.voice3SustainRelease, 0xA0, after: 6)
        // The pattern all on, and the sawtooth gated now rather than at the next pattern step.
        self[SoundDriver.RAM.gatePattern] = 0xFF
        self[SoundDriver.RAM.patternShift] = 0xFF
        self[SoundDriver.RAM.voice3Control] = 0x21
        storeSID(SoundDriver.Reg.voice3Control, 0x21, after: 20)
        charge(7)   // to the common exit
        sfxExit()
    }

    /// $CC68 `sfxCrash` (state 2; called directly at $356D and $F979): noise on all voices. V3 $0080
    /// AD $2D, V2 $0200 AD $2C, V1 $4000 AD $08, all SR 0; resonance 7 with the filter on V2/V3
    /// ($D417 = $76), volume 15 ($D418 = $1F), cutoff $D416 = $80, then the three controls $81.
    /// V1/V2 are normally gated already, so they decay from sustain without a new attack; the AD
    /// values persist and shape the next engine retrigger. Pattern $FF, `$0E5C = $0F` (4 skipped
    /// ticks). Charges 139 cycles.
    public func sfxCrash() {
        // Voice 3.
        storeSID(SoundDriver.Reg.voice3FreqLo, 0x80, after: 4)
        storeSID(SoundDriver.Reg.voice3FreqHi, 0x00, after: 4)
        storeSID(SoundDriver.Reg.voice3AttackDecay, 0x2D, after: 6)
        storeSID(SoundDriver.Reg.voice3SustainRelease, 0x00, after: 6)
        // Voice 2.
        storeSID(SoundDriver.Reg.voice2FreqLo, 0x00, after: 8)
        storeSID(SoundDriver.Reg.voice2FreqHi, 0x02, after: 4)
        storeSID(SoundDriver.Reg.voice2AttackDecay, 0x2C, after: 6)
        storeSID(SoundDriver.Reg.voice2SustainRelease, 0x00, after: 6)
        // Voice 1, then the filter routing, the volume and the cutoff.
        storeSID(SoundDriver.Reg.voice1FreqLo, 0x00, after: 8)
        storeSID(SoundDriver.Reg.voice1FreqHi, 0x40, after: 4)
        storeSID(SoundDriver.Reg.voice1AttackDecay, 0x08, after: 6)
        storeSID(SoundDriver.Reg.voice1SustainRelease, 0x00, after: 6)
        storeSID(SoundDriver.Reg.resonanceRouting, 0x76, after: 6)
        storeSID(SoundDriver.Reg.modeVolume, 0x1F, after: 6)
        storeSID(SoundDriver.Reg.cutoffHi, 0x80, after: 6)
        // Noise with the gate on, on all three voices; the pattern player gets the same value.
        storeSID(SoundDriver.Reg.voice1Control, 0x81, after: 6)
        storeSID(SoundDriver.Reg.voice2Control, 0x81, after: 4)
        storeSID(SoundDriver.Reg.voice3Control, 0x81, after: 4)
        self[SoundDriver.RAM.voice3Control] = 0x81
        // The pattern all on, four ticks skipped.
        self[SoundDriver.RAM.patternShift] = 0xFF
        self[SoundDriver.RAM.gatePattern] = 0xFF
        self[SoundDriver.RAM.soundSkipMask] = 0x0F
        charge(27)   // ... to the common exit
        sfxExit()
    }

    /// $CCD1 `sfxGun` (state 3; called directly at $2C1A after `$0E59 = 3`): voice 3 noise $1770,
    /// AD $00, SR $90, period 2 frames, pattern $55 (15 bursts per second through the pattern
    /// player, which does the gating), `$0E60 = $81`, `$0E5C = 1`.
    ///
    /// Quirk kept: the restart test compares the pattern $55 with the period `$0E5A` that was just
    /// set to 2 (probably meant to be `$0E5E`), so the pattern is always restarted. Charges 73
    /// cycles.
    public func sfxGun() {
        // Voice 3 frequency and envelope.
        storeSID(SoundDriver.Reg.voice3FreqLo, 0x70, after: 4)
        storeSID(SoundDriver.Reg.voice3FreqHi, 0x17, after: 4)
        storeSID(SoundDriver.Reg.voice3AttackDecay, 0x00, after: 6)
        storeSID(SoundDriver.Reg.voice3SustainRelease, 0x90, after: 6)
        // The period, then the restart test that reads it instead of the pattern (never equal).
        self[SoundDriver.RAM.patternPeriod] = 0x02
        if self[SoundDriver.RAM.patternPeriod] == 0x55 {
            charge(19)
        } else {
            // Restart the pattern.
            self[SoundDriver.RAM.patternShift] = 0x55
            self[SoundDriver.RAM.gatePattern] = 0x55
            charge(26)
        }
        // Noise for the pattern player, one tick skipped, then the common exit.
        self[SoundDriver.RAM.voice3Control] = 0x81
        self[SoundDriver.RAM.soundSkipMask] = 0x01
        charge(15)
        sfxExit()
    }

    /// $CD04 `sfxBombRelease` (called directly at $2B88): whistle frequency `$0E7D/$0E7E = $4A38`
    /// (the 10 Hz sweep writes it to the SID, starting one step lower), voice 3 AD $00, SR $60,
    /// pattern $FF, sawtooth gated at once, then state 10 (`sfxBombWait`). It returns on its own
    /// instead of through the common exit, and sets no skip delay. Charges 56 cycles.
    public func sfxBombRelease() {
        // The whistle's start frequency; only the sweep writes it to the SID.
        self[SoundDriver.RAM.bombWhistleFrequency] = 0x38
        self[SoundDriver.RAM.bombWhistleFrequency + 1] = 0x4A
        storeSID(SoundDriver.Reg.voice3AttackDecay, 0x00, after: 14)
        storeSID(SoundDriver.Reg.voice3SustainRelease, 0x60, after: 6)
        // The pattern all on, and the sawtooth gated now.
        self[SoundDriver.RAM.gatePattern] = 0xFF
        self[SoundDriver.RAM.patternShift] = 0xFF
        self[SoundDriver.RAM.voice3Control] = 0x21
        storeSID(SoundDriver.Reg.voice3Control, 0x21, after: 20)
        // Next: wait for the whistle to fall.
        self[SoundDriver.RAM.soundState] = SoundDriver.Effect.bombWait.rawValue
        charge(16)
    }

    /// $CD2E `sfxOuterMarker` (state 5): 400 Hz ($19A1), AD $00, SR $60, period 15 frames,
    /// pattern $55 (two dashes per second). Charges 63 cycles.
    public func sfxOuterMarker() {
        sfxMarker(frequencyLo: 0xA1, frequencyHi: 0x19, attackDecay: 0x00, sustainRelease: 0x60,
                  period: 0x0F, pattern: 0x55)
    }

    /// $CD59 `sfxMiddleMarker` (state 6): 1300 Hz ($534B), AD $00, SR $60, period 5 frames,
    /// pattern $27 (dash-dot). Charges 63 cycles.
    public func sfxMiddleMarker() {
        sfxMarker(frequencyLo: 0x4B, frequencyHi: 0x53, attackDecay: 0x00, sustainRelease: 0x60,
                  period: 0x05, pattern: 0x27)
    }

    /// $CD84 `sfxInnerMarker` (state 7): 3000 Hz ($C037), AD $20, SR $62, period 5 frames,
    /// pattern $55 (six dots per second). Charges 63 cycles.
    public func sfxInnerMarker() {
        sfxMarker(frequencyLo: 0x37, frequencyHi: 0xC0, attackDecay: 0x20, sustainRelease: 0x62,
                  period: 0x05, pattern: 0x55)
    }

    /// The common shape of the three marker handlers. They set the pattern but not `$2309`, so a
    /// new rhythm starts at the next 8-step reload, and they leave the gating to the pattern
    /// player (`$0E60 = $21`). `$0E5C = 3`, then the common exit.
    private func sfxMarker(frequencyLo: UInt8, frequencyHi: UInt8, attackDecay: UInt8, sustainRelease: UInt8,
                           period: UInt8, pattern: UInt8) {
        // Voice 3 frequency and envelope.
        storeSID(SoundDriver.Reg.voice3FreqLo, frequencyLo, after: 4)
        storeSID(SoundDriver.Reg.voice3FreqHi, frequencyHi, after: 4)
        storeSID(SoundDriver.Reg.voice3AttackDecay, attackDecay, after: 6)
        storeSID(SoundDriver.Reg.voice3SustainRelease, sustainRelease, after: 6)
        // The rhythm and the sawtooth the player gates with it, two ticks skipped, then the
        // common exit.
        self[SoundDriver.RAM.patternPeriod] = period
        self[SoundDriver.RAM.gatePattern] = pattern
        self[SoundDriver.RAM.voice3Control] = 0x21
        self[SoundDriver.RAM.soundSkipMask] = 0x03
        charge(31)
        sfxExit()
    }

    /// $CDAF `sfxTouchdown` (state 8, armed at $3579): voice 3 noise with only $D40F = $FF written,
    /// AD $44, SR 0, gated at once; voice 2 with only $D408 = $FF written (about 3.98 kHz), AD $72,
    /// SR 0, retriggered with $00 then $21 (sawtooth); $D417 = $81 (filter on V1 only, resonance 8).
    /// Pattern $FF, `$0E5C = 3`. Charges 95 cycles.
    public func sfxTouchdown() {
        storeSID(SoundDriver.Reg.voice3FreqHi, 0xFF, after: 2)
        storeSID(SoundDriver.Reg.voice3AttackDecay, 0x44, after: 6)
        storeSID(SoundDriver.Reg.voice3SustainRelease, 0x00, after: 6)
        // Noise, kept for the pattern player and gated now.
        self[SoundDriver.RAM.voice3Control] = 0x81
        storeSID(SoundDriver.Reg.voice3Control, 0x81, after: 10)
        // The pattern all on, two ticks skipped.
        self[SoundDriver.RAM.patternShift] = 0xFF
        self[SoundDriver.RAM.gatePattern] = 0xFF
        self[SoundDriver.RAM.soundSkipMask] = 0x03
        // Voice 2: only its high frequency byte, then a retriggered sawtooth and the filter routing.
        storeSID(SoundDriver.Reg.voice2FreqHi, 0xFF, after: 22)
        storeSID(SoundDriver.Reg.voice2AttackDecay, 0x72, after: 6)
        storeSID(SoundDriver.Reg.voice2SustainRelease, 0x00, after: 6)
        storeSID(SoundDriver.Reg.voice2Control, 0x00, after: 6)
        storeSID(SoundDriver.Reg.voice2Control, 0x21, after: 6)
        storeSID(SoundDriver.Reg.resonanceRouting, 0x81, after: 6)
        charge(7)   // an always-taken branch to the common exit
        sfxExit()
    }

    /// $CDF3 `sfxExit`: the common effect exit, `$0E59 = 9` (reset on the next tick). Charges 12
    /// cycles.
    public func sfxExit() {
        self[SoundDriver.RAM.soundState] = SoundDriver.Effect.reset.rawValue
        charge(12)
    }

    /// $CDF9 `sfxReset` (state 9): gates V1/V2 off ($D404 = $D40B = 0), `$0E59 = 0`, increments
    /// `$09BE` (so the next `$E500` call rewrites the engine frequencies), then falls into
    /// `sfxIdle`, which gates V1/V2 on again: an envelope retrigger with whatever AD values are in
    /// the SID. Charges 84 cycles, the idle handler included.
    public func sfxReset() {
        storeSID(SoundDriver.Reg.voice1Control, 0x00, after: 2)
        storeSID(SoundDriver.Reg.voice2Control, 0x00, after: 4)
        // Idle next, and force an engine retune.
        self[SoundDriver.RAM.soundState] = SoundDriver.Effect.idle.rawValue
        self[SoundDriver.RAM.engineRpm] &+= 1
        charge(14)
        sfxIdle()
    }

    /// $CE07 `sfxIdle` (state 0, every idle tick): V1/V2 control $21 (sawtooth, gate on), V3 off
    /// ($D412 = 0, `$0E60` = 0), $D417 = $83 (resonance 8, filter V1+V2), $D416 = $70 (FC = $380),
    /// $D418 = $1B (low-pass, volume 11), `$0E5A = $28`, SR $B2 on all voices. It never sets the
    /// engine AD values. Charges 64 cycles.
    public func sfxIdle() {
        storeSID(SoundDriver.Reg.voice1Control, 0x21, after: 2)
        storeSID(SoundDriver.Reg.voice2Control, 0x21, after: 4)
        storeSID(SoundDriver.Reg.voice3Control, 0x00, after: 6)
        // The pattern player's voice-3 value too.
        self[SoundDriver.RAM.voice3Control] = 0x00
        storeSID(SoundDriver.Reg.resonanceRouting, 0x83, after: 10)
        storeSID(SoundDriver.Reg.cutoffHi, 0x70, after: 6)
        storeSID(SoundDriver.Reg.modeVolume, 0x1B, after: 6)
        // The pattern period.
        self[SoundDriver.RAM.patternPeriod] = 0x28
        // The same sustain/release on all three voices.
        storeSID(SoundDriver.Reg.voice1SustainRelease, 0xB2, after: 12)
        storeSID(SoundDriver.Reg.voice2SustainRelease, 0xB2, after: 4)
        storeSID(SoundDriver.Reg.voice3SustainRelease, 0xB2, after: 4)
        charge(10)
    }

    /// $CE37 `sfxBombWait` (state 10): returns until the whistle high byte `$0E7E` is below $30
    /// (unsigned, so a sweep that already stopped at $FFxx never explodes). Then the explosion:
    /// `$0E7E = $FF` (sweep off), voice 3 noise $0380, AD $2D, SR 0; $D417 = $77 (resonance 7,
    /// filter on all voices), $D418 = $1F (volume 15), $D416 = $80; voice 3 retriggered with $80
    /// then $81; pattern $FF, `$0E5C = 3`, then the common exit. Charges 14 or 104 cycles.
    public func sfxBombWait() {
        // Keep waiting while the whistle is still high.
        if self[SoundDriver.RAM.bombWhistleFrequency + 1] >= 0x30 {
            charge(14)
            return
        }
        // The sweep off.
        self[SoundDriver.RAM.bombWhistleFrequency + 1] = 0xFF
        // The explosion on voice 3, the filter routing, volume and cutoff, then the retrigger.
        storeSID(SoundDriver.Reg.voice3FreqLo, 0x80, after: 19)
        storeSID(SoundDriver.Reg.voice3FreqHi, 0x03, after: 4)
        storeSID(SoundDriver.Reg.voice3AttackDecay, 0x2D, after: 6)
        storeSID(SoundDriver.Reg.voice3SustainRelease, 0x00, after: 6)
        storeSID(SoundDriver.Reg.resonanceRouting, 0x77, after: 6)
        storeSID(SoundDriver.Reg.modeVolume, 0x1F, after: 6)
        storeSID(SoundDriver.Reg.cutoffHi, 0x80, after: 6)
        storeSID(SoundDriver.Reg.voice3Control, 0x80, after: 6)
        storeSID(SoundDriver.Reg.voice3Control, 0x81, after: 6)
        // Noise for the pattern player, the pattern all on, two ticks skipped, then the common exit.
        self[SoundDriver.RAM.voice3Control] = 0x81
        self[SoundDriver.RAM.patternShift] = 0xFF
        self[SoundDriver.RAM.gatePattern] = 0xFF
        self[SoundDriver.RAM.soundSkipMask] = 0x03
        charge(27)
        sfxExit()
    }
}
