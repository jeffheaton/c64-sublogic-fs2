/// The SID sound driver: a translation of SubLogic's register-level driver (block $29 at
/// $CC00-$CE83) and the three pieces of game code that feed it (the IRQ gate-pattern player
/// $22C8/$230A, the engine pitch slew $E500 and the bomb-whistle sweep $2381). See
/// `re/docs/sound.md`.
///
/// Every SID store goes through `io.writeSID` in the original's order, stamped with the cycle at
/// which the store instruction starts (the lab's convention), and every RAM byte the original
/// writes is written, including the self-modified dispatch operand at $CC44/$CC45.
///
/// Cycle convention: a ported routine charges the cycles from its first instruction through its
/// own return (or, for the fragments that are not subroutines, through their last instruction).
/// The caller charges its own call. Charges are made progressively, so a store's timestamp is
/// exact.
///
/// Entry points for the scheduler:
///
/// | When | Call | Original |
/// |---|---|---|
/// | Every frame IRQ (both $2285 and the alternate $2304), after the frame counters `$34` and `$0E6B` are bumped | `patternPlayerFrame()` | $22C8-$22CC, $230A-$232D |
/// | Every 10 Hz tick ($2348), right after the key dispatch | `engineSoundSlew()` | the call to $E500 at $2358 |
/// | Every 10 Hz tick, after the two key-repeat checks | `bombWhistleSweep()` | $2381-$239A |
/// | 10 Hz tick when the TOD seconds `$DC09` differ from `$0E6D` and `$08CC == 0` | `soundTick()` | the call to $CC16 at $23DD |
/// | Cold init ($AAF3) | `sidInit()` | $AB58 |
public enum SoundDriver {
    /// The driver's RAM, at the original addresses.
    public enum RAM {
        /// `$08D3` SOUND on/off, copied from the editor's `$0964` on exit; 0 silences.
        public static let soundEnable = 0x08D3
        /// `$09BE` current engine value (RPM/50); `$E500` slews it toward `engineTargetRpm`.
        public static let engineRpm = 0x09BE
        /// `$0E52` scratch: high byte of the voice-1 frequency built by `$E500`.
        public static let engineFreqV1Hi = 0x0E52
        /// `$0E54` scratch: high byte of the voice-2 frequency built by `$E500`.
        public static let engineFreqV2Hi = 0x0E54
        /// `$0E58` engine target (RPM/50), written by the engine model ($EF3F-$EF7C).
        public static let engineTargetRpm = 0x0E58
        /// `$0E59` effect state machine state, the index into the handler table at $CC00.
        public static let soundState = 0x0E59
        /// `$0E5A` gate-pattern step period in frames.
        public static let patternPeriod = 0x0E5A
        /// `$0E5B` gate-pattern frame countdown (decremented by the frame IRQ).
        public static let patternCountdown = 0x0E5B
        /// `$0E5C` 1 Hz skip counter, shifted right one bit per tick ($0F = 4 ticks, 3 = 2, 1 = 1).
        public static let soundSkipMask = 0x0E5C
        /// `$0E5E` 8-bit gate rhythm, LSB first, reloaded into `$2309` every 8 steps.
        public static let gatePattern = 0x0E5E
        /// `$0E60` voice-3 control value written to $D412 when the pattern bit is 1.
        public static let voice3Control = 0x0E60
        /// `$0E7D/$0E7E` bomb-whistle frequency; bit 7 of `$0E7E` set means the sweep is off.
        public static let bombWhistleFrequency = 0x0E7D
        /// `$2308` pattern step counter; `($2308 & 7) == 0` reloads the shift register.
        public static let patternStepCounter = 0x2308
        /// `$2309` working shift register of the gate pattern.
        public static let patternShift = 0x2309
        /// `$CC00` handler table: 11 words indexed by `soundState` (read from the loaded image).
        public static let stateHandlers = 0xCC00
        /// `$CC44/$CC45` operand of the self-modified jump at $CC43.
        public static let dispatchOperand = 0xCC44
    }

    /// SID register offsets from $D400, named as in the lab listing.
    enum Reg {
        static let voice1FreqLo = 0x00, voice1FreqHi = 0x01, voice1Control = 0x04
        static let voice1AttackDecay = 0x05, voice1SustainRelease = 0x06
        static let voice2FreqLo = 0x07, voice2FreqHi = 0x08, voice2Control = 0x0B
        static let voice2AttackDecay = 0x0C, voice2SustainRelease = 0x0D
        static let voice3FreqLo = 0x0E, voice3FreqHi = 0x0F, voice3Control = 0x12
        static let voice3AttackDecay = 0x13, voice3SustainRelease = 0x14
        static let cutoffHi = 0x16, resonanceRouting = 0x17, modeVolume = 0x18
        /// $D418 is the last register the clear at $AB58 writes.
        static let lastWritable = 0x18
    }

    /// The effect states (values of `$0E59`), each dispatched through the handler table at $CC00.
    public enum Effect: UInt8, Sendable, CaseIterable {
        /// Engine voices gated on, voice 3 off, normal filter and volume.
        case idle = 0
        /// Stall horn (armed at 5 Hz by $3016 while `$09DD` is $21-$7F).
        case stallHorn = 1
        /// Crash/splash noise on all three voices.
        case crash = 2
        /// Machine gun bursts.
        case gun = 3
        /// Bomb release whistle (called directly; it sets state 10 itself).
        case bombRelease = 4
        /// Outer marker, 400 Hz dashes.
        case outerMarker = 5
        /// Middle marker, 1300 Hz dash-dot.
        case middleMarker = 6
        /// Inner marker, 3000 Hz dots.
        case innerMarker = 7
        /// Touchdown chirp.
        case touchdown = 8
        /// End of an effect; falls into idle.
        case reset = 9
        /// Waits for the falling whistle, then the explosion.
        case bombWait = 10

        /// The effect whose handler starts at `handler` (an address the original's table at $CC00
        /// holds), nil for any other address. The mapping goes from address to effect, never as
        /// a state-indexed list of addresses: the table itself is SubLogic's data, read from memory.
        public init?(handler: UInt16) {
            switch handler {
            case 0xCC46: self = .stallHorn
            case 0xCC68: self = .crash
            case 0xCCD1: self = .gun
            case 0xCD04: self = .bombRelease
            case 0xCD2E: self = .outerMarker
            case 0xCD59: self = .middleMarker
            case 0xCD84: self = .innerMarker
            case 0xCDAF: self = .touchdown
            case 0xCDF9: self = .reset
            case 0xCE07: self = .idle
            case 0xCE37: self = .bombWait
            default: return nil
            }
        }
    }
}

extension Machine {
    /// Charges the cycles of the instructions before a SID store, then performs the store, stamped
    /// with the cycle at which the store instruction starts (the lab logs writes the same way). The
    /// store's own cycles go into the next charge. With I/O banked out (`ioMappedIn`: an IRQ
    /// inside the 10 Hz tick while the course plot is displayed) the store goes to the RAM under
    /// the SID, as on the C64.
    @inline(__always)
    func storeSID(_ reg: Int, _ value: UInt8, after cycles: Int) {
        charge(cycles)
        if ioMappedIn {
            io.writeSID(reg, value, at: clock.cycles)
        } else {
            mem[0xD400 + reg] = value
        }
    }

    /// $CC16 `soundTick`: the 1 Hz effect state machine.
    ///
    /// Called by the 10 Hz tick ($23DD) on the first tick after the CIA1 TOD seconds change, unless
    /// paused (`$08CC`), and by the key wait `$2250`, which zeroes `$08D3` first to silence the SID.
    /// The original reads the TOD in the caller, so this routine needs no I/O input.
    ///
    /// 1. If `$08D3` is 0: $D404 = $D40B = $D412 = 0, `$2309` = `$0E5E` = 0, return.
    /// 2. Shift `$0E5C` right; return if a 1 was shifted out (the skip delay).
    /// 3. Copy the handler word `$CC00[2 × $0E59]` into the jump operand $CC44/$CC45 and jump.
    ///
    /// Charges 34 cycles (sound off), 22 (skipped) or 42 plus the handler.
    public func soundTick() {
        // Sound switched off?
        if self[SoundDriver.RAM.soundEnable] == 0 {
            // Gate all three voices off and clear the gate pattern.
            storeSID(SoundDriver.Reg.voice1Control, 0x00, after: 8)
            storeSID(SoundDriver.Reg.voice2Control, 0x00, after: 4)
            storeSID(SoundDriver.Reg.voice3Control, 0x00, after: 4)
            self[SoundDriver.RAM.patternShift] = 0x00
            self[SoundDriver.RAM.gatePattern] = 0x00
            charge(18)
            return
        }
        // The skip delay.
        let skip = self[SoundDriver.RAM.soundSkipMask]
        self[SoundDriver.RAM.soundSkipMask] = skip >> 1
        if skip & 1 != 0 {
            charge(22)
            return
        }
        // Dispatch through the state's table word. The index (twice the state) wraps at 8 bits as
        // in the original; it is even, so no page is crossed.
        let x = Int(self[SoundDriver.RAM.soundState] << 1)
        let lo = self[SoundDriver.RAM.stateHandlers + x]
        let hi = self[SoundDriver.RAM.stateHandlers + 1 + x]
        self[SoundDriver.RAM.dispatchOperand] = lo
        self[SoundDriver.RAM.dispatchOperand + 1] = hi
        charge(42)
        soundDispatch(to: UInt16(hi) << 8 | UInt16(lo))
    }

    /// The self-modified jump at $CC43: runs the handler whose address the table held.
    func soundDispatch(to handler: UInt16) {
        switch SoundDriver.Effect(handler: handler) {
        case .idle: sfxIdle()
        case .stallHorn: sfxStallHorn()
        case .crash: sfxCrash()
        case .gun: sfxGun()
        case .bombRelease: sfxBombRelease()
        case .outerMarker: sfxOuterMarker()
        case .middleMarker: sfxMiddleMarker()
        case .innerMarker: sfxInnerMarker()
        case .touchdown: sfxTouchdown()
        case .reset: sfxReset()
        case .bombWait: sfxBombWait()
        case nil:
            // A state above 10 would make the original jump through driver code bytes. No game
            // code stores such a state, so the port stops here instead.
            let state = String(self[SoundDriver.RAM.soundState], radix: 16, uppercase: true)
            assertionFailure("sound state $\(state) dispatches to $\(String(handler, radix: 16, uppercase: true))")
        }
    }

    /// Arms an effect the way the game code does.
    ///
    /// | Effect | Original call site | What it does |
    /// |---|---|---|
    /// | stall horn | $3014 in the 5 Hz aero routine $2F45 | `$0E59 = 1`; starts on the next 1 Hz tick |
    /// | outer/middle/inner marker | $3F34 in `markerBeacons` $3EFC | `$0E59 = 5/6/7`; next tick |
    /// | touchdown | $3579 in `groundContact` | `$0E59 = 8`; next tick (up to 1 s late) |
    /// | gun | $2C15 in `fireGuns` $2C03 | `$0E59 = 3`, then calls `sfxGun` |
    /// | bomb release | $2B88 in `keyDropBomb` $2B79 | calls `sfxBombRelease` (it sets state 10 itself) |
    /// | crash | $356D in `groundContact`; $F974 (crash/splash message) | calls `sfxCrash`. $F974 stores `$0E59 = 2` first, which `sfxCrash` overwrites with 9. |
    ///
    /// Other states are plain stores to `$0E59`, which is all the original could do with them.
    /// The caller charges its own instructions at the call site (load, store, call); the routines
    /// called here charge themselves.
    public func triggerEffect(_ effect: SoundDriver.Effect) {
        switch effect {
        case .gun:
            self[SoundDriver.RAM.soundState] = effect.rawValue
            sfxGun()
        case .bombRelease:
            sfxBombRelease()
        case .crash:
            sfxCrash()
        default:
            self[SoundDriver.RAM.soundState] = effect.rawValue
        }
    }

    /// $AB58 `sidInit` (cold-start overlay): clears $D418 down to $D400, then calls $CDF9
    /// (`sfxReset`, which falls into `sfxIdle`). Charges 349 cycles, the reset included.
    public func sidInit() {
        // Start at $D418 with a zero value.
        charge(4)
        // One store per register, counting down to $D400.
        for reg in stride(from: SoundDriver.Reg.lastWritable, through: 0, by: -1) {
            io.writeSID(reg, 0x00, at: clock.cycles)
            charge(7 + (reg == 0 ? 2 : 3))
        }
        charge(6)
        sfxReset()
        charge(6)
    }
}
