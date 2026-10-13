/// The interrupt equivalents: the raster IRQ $2285 (the screen split and the frame tick), the
/// alternate IRQ $2304 (the frame tick only), the dispatch through the vectors at $FFFE/$FFFA, and
/// the RESTORE NMI's cold restart.
///
/// Whoever delivers an interrupt (the normal-mode `InterruptScheduler` at the raster lines, the
/// `ReplayDriver` at the recorded poll points) calls `irq()` / `nmi()`, which charge the 7-cycle
/// interrupt entry; each handler charges from its first instruction through its interrupt return.
extension Machine {
    // MARK: Dispatch

    /// One IRQ: the 7-cycle entry, then the handler the vector at $FFFE points at (a memory word:
    /// $2285 the raster IRQ, $2304 the text-mode/disk tick installed by $2673, $790A or $E58E a
    /// bare interrupt return). The interrupt flag is set for the handler and restored by its
    /// return.
    public func irq() {
        let flag = interruptDisable
        interruptDisable = true
        charge(7)
        switch u16(0xFFFE) {
        case 0x2285: rasterIrq()
        case 0x2304: altIrq()
        case 0x790A, 0xE58E: charge(6)               // a bare return (the loader's disabled vector)
        case let vector:
            preconditionFailure(String(format: "IRQ vector $%04X is no handler of the game", vector))
        }
        interruptDisable = flag
    }

    /// One NMI (RESTORE): the 7-cycle entry, then the handler at the vector $FFFA: $2700
    /// (`restoreNmi`; with RUN/STOP held first it takes the cold restart), or a bare interrupt
    /// return ($790A, $E58E).
    ///
    /// The cold restart jumps to $A7E2 out of the interrupt: the init chain and the main loop run
    /// from here, inside the interrupted frames, and never return into them. When that run stops
    /// (`mainLoopHook`), the frames are left for good through `abandonStack` (`ProgramThread`).
    ///
    /// The NMI entry sets the interrupt flag too; the interrupt return restores it, the restart
    /// keeps it (its init chain masks interrupts first). A return that clears it lets in a raster
    /// IRQ the VIC latched during the handler, as unmasking does (the scheduler runs at the next
    /// charge).
    public func nmi() {
        let flag = interruptDisable
        interruptDisable = true
        charge(7)
        switch u16(0xFFFA) {
        case 0x2700:
            if restoreNmi() { coldRestartFromInterrupt() }
        case 0x790A, 0xE58E:
            charge(6)
        case let vector:
            preconditionFailure(String(format: "NMI vector $%04X is no handler of the game", vector))
        }
        interruptDisable = flag
        if !flag && eventHandler != nil { nextEventCycle = min(nextEventCycle, clock.cycles) }
    }

    /// The jump to $A7E2 from the NMI handler: the cold start, then the main loop; never returns.
    private func coldRestartFromInterrupt() -> Never {
        let exit = coldStart()
        guard let abandon = abandonStack else {
            fatalError("a cold restart from an interrupt ran to its end without ProgramThread to leave its stack")
        }
        switch exit {
        case .stopped: abandon(nil)
        case .fault(let fault): abandon("\(fault)")
        }
    }

    // MARK: $2285 rasterIrq

    /// $2285 (vector $FFFE): the two-phase raster IRQ. It saves A, banks I/O in (`$01` = $35) and
    /// shifts the phase bit out of `$4A`:
    ///
    /// - bit 0 clear, the **panel** phase (line $A3): border $0C, `$D018` = $F0 (bitmap A),
    ///   `$D016` = $C8 (hi-res), next IRQ at line $20, `$D019` acknowledged, the phase set for the
    ///   window again, `$01` = `$4B`, A restored for the return. The state is latched as
    ///   `io.panelRegion`.
    /// - bit 0 set, the **window** phase (line $20): `$D018` = the operand `$22B0` (the bitmap the
    ///   last flip finished), border = the operand `$22B5`, `$D016` = $D8 (multicolor), next IRQ at
    ///   line $A3; latched as `io.viewRegion`; then the frame tick `frameTick`.
    ///
    /// The charges place every register write on its cycle.
    public func rasterIrq() {
        let m = mem
        let R = MainLoop.RAM.self
        m[0x01] = 0x35
        let phase = m[R.irqPhase]
        m[R.irqPhase] = phase >> 1
        if phase & 1 == 0 {
            charge(17)                   // A saved, I/O banked in, the phase test
            io.writeVIC(0x20, 0x0C)
            charge(6)
            io.writeVIC(0x18, 0xF0)
            charge(6)
            io.writeVIC(0x16, 0xC8)
            charge(6)
            io.writeVIC(0x12, 0x20)
            charge(6)
            io.acknowledgeVIC(0xFF)
            io.panelRegion = io.vicState()
            m[R.irqPhase] &+= 1
            m[0x01] = m[R.savedCpuPort]
            charge(25)            // acknowledge, the phase, the CPU port and A restored, the return
            return
        }
        charge(18)                       // the window phase: A saved, I/O banked in, the phase test
        io.writeVIC(0x18, m[R.flipOperand])
        charge(6)
        io.writeVIC(0x20, m[R.borderOperand])
        charge(6)
        io.writeVIC(0x16, 0xD8)
        charge(6)
        io.writeVIC(0x12, 0xA3)
        charge(4)                                           // the last write
        io.viewRegion = io.vicState()
        frameTick()
    }

    /// $2304 (vector $FFFE in text mode and around the editor's disk I/O, installed by $2673):
    /// saves A and goes straight to the frame tick $22C3: no VIC writes and no `$01` = $35 on
    /// entry.
    public func altIrq() {
        charge(6)
        frameTick()
    }

    /// $22C3 `frameTick` (shared by $2285's window phase and $2304): counts the jiffy `$34` and the
    /// 10 Hz divider `$0E6B`, runs the voice-3 pattern player ($22C8, `patternPlayerFrame`), then
    /// the keyboard phase $22CD counts `$08A6` down; zero: the matrix scan `keyScan` ($2418);
    /// negative: the release check `keyReleaseCheck` ($2505) and `$08A6` = 3 (a 4-frame cycle:
    /// idle, idle, scan, release). X and Y are saved around the scan and the release check. Then
    /// `$D019` is acknowledged, `$01` = `$4B`, and A is restored for the return.
    public func frameTick() {
        let m = mem
        let R = MainLoop.RAM.self
        m[R.jiffyCounter] &+= 1
        m[R.frameDivider] &+= 1
        charge(11)                                       // the two counters
        patternPlayerFrame()                                // it ends by going on to $22CD
        let phase = m[R.scanPhase] &- 1
        m[R.scanPhase] = phase
        if phase & 0x80 != 0 {
            charge(25)               // negative: X and Y saved, the release check
            keyReleaseCheck()
            m[R.scanPhase] = 3
            charge(6)                                   // the 4-frame cycle restarted
        } else if phase == 0 {
            charge(27)           // zero: X and Y saved, the scan
            keyScan()
            charge(3)                                       // on to the shared exit $22F5
        } else {
            charge(16)                       // an idle frame: acknowledge
            io.acknowledgeVIC(0x01)
            m[0x01] = m[R.savedCpuPort]
            charge(16)                           // the CPU port and A restored, the return
            return
        }
        // $22F5: Y and X restored, acknowledge.
        charge(18)
        io.acknowledgeVIC(0x01)
        m[0x01] = m[R.savedCpuPort]
        charge(16)                               // the CPU port and A restored, the return
    }

    // MARK: I/O reads

    /// A read of an I/O register in the main program: the live value (`IO.read`: the CIA1 time of
    /// day run from the virtual clock, the ICRs, the VIC registers), passed through `ioReadHook`
    /// (the replay driver returns the value the lab recorded instead). With I/O banked out
    /// (`ioMappedIn`) the read sees the RAM under I/O, as on the C64 (and the lab logs no I/O
    /// read).
    public func readIO(_ address: Int) -> UInt8 {
        guard ioMappedIn else { return mem[address] }
        let live = io.read(address, at: clock.cycles)
        return ioReadHook?(address, live) ?? live
    }

    /// Whether the CPU port `$01` maps I/O in at $D000-$DFFF (LORAM or HIRAM set, and CHAREN
    /// set; the data direction register keeps its power-on $2F, the game never writes `$00`).
    /// A `$01` of 0 was never written (a bare `Machine`): the port is still at its power-on $37,
    /// which the lab keeps in its port register apart from RAM. The game writes only $35 and $30.
    ///
    /// The course plot runs with `$01` = `$4B` = $30 ($F7B0), and every IRQ ends with `$01` =
    /// `$4B`. The poll banks I/O in around the 10 Hz tick (`pollTick`), but an IRQ taken inside the
    /// tick leaves `$01` = $30 behind, so the rest of that tick reads `$DC09` and stores the SID
    /// registers in the RAM under I/O. In this image that makes the clock run fast while a
    /// course plot is displayed (a RAM `$DC09` that differs from `$0E6D` counts as a new second).
    /// Only normal mode can show it: a replay takes the IRQs at the poll points only.
    var ioMappedIn: Bool {
        let port = mem[0x01]
        return port == 0 || (port & 0x03 != 0 && port & 0x04 != 0)
    }

    // MARK: The interrupt flag

    /// Sets the interrupt flag: the scheduler holds raster IRQs until `cli`.
    func sei() {
        interruptDisable = true
    }

    /// Clears the interrupt flag: an IRQ held while the flag was set is taken at once (the
    /// scheduler runs at the end of the next charge).
    func cli() {
        interruptDisable = false
        if eventHandler != nil { nextEventCycle = min(nextEventCycle, clock.cycles) }
    }
}
