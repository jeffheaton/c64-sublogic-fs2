/// The game program's main loop ($2048-$2195): no vsync, one pass after another as fast as the
/// drawing allows. See `re/docs/main-loop.md` for the definitive description.
///
/// Literal translation with exact cycles: each routine charges from its first instruction through
/// its return, and the caller charges the call (and a vector's 3-cycle jump). The overlay slots
/// ($A7E2-$A7FF) are executed from the overlay bytes in memory (`runOverlaySlot`), so the resident
/// overlay decides what a slot does, as on the C64.
public enum MainLoop {
    /// Variables of the main loop, the interrupts and the ticks (names from `re/symbols.json`).
    public enum RAM {
        /// `$22`: main-loop pass counter; `& 3` selects the phase tasks, `& 4` the 1-in-8 tasks.
        public static let mainLoopCounter = 0x22
        /// `$34`: the jiffy counter (one per frame, the window-phase IRQ).
        public static let jiffyCounter = 0x34
        /// `$4A`: the raster IRQ's phase toggle (bit 0 set: the window phase at line $20).
        public static let irqPhase = 0x4A
        /// `$4B`: the `$01` value the IRQ restores on exit.
        public static let savedCpuPort = 0x4B
        /// `$8D`: added to the window row high bytes at each flip ($20 / $E0, toggled by $C0).
        public static let drawBufferDelta = 0x8D
        /// `$0832/$0833`: rotated left by one on odd phases.
        public static let phaseRotor = 0x0832
        /// `$0834`: crash (4) or splash (8); the flip pass shows the message.
        public static let crashCode = 0x0834
        /// `$08A6`: the keyboard phase of the frame IRQ (scan on 0, release check on -1).
        public static let scanPhase = 0x08A6
        /// `$08BA/$08BB`: the editor and mode requests (the editor overlay slot runs while set).
        public static let editorRequest = 0x08BA
        public static let modeRequest = 0x08BB
        /// `$08BC`: the editor cache (0 never loaded, 1 cached at $D000, 2 invalid).
        public static let editorCacheState = 0x08BC
        /// `$08CC`: the pause count (`waitForKey`); the 5 Hz and 1 Hz work stop while set.
        public static let pauseCount = 0x08CC
        /// `$08D7`: R in war mode asks for the `$FD00` hook (a documented no-op).
        public static let fd00HookRequest = 0x08D7
        /// `$08DA`: 1 while a disk load holds the IRQ off (`readBlocks`).
        public static let diskLoading = 0x08DA
        /// `$091A`, `$0984`, `$0983`: the clock's seconds, minutes and hours.
        public static let clockSeconds = 0x091A
        public static let clockMinutes = 0x0984
        public static let clockHours = 0x0983
        /// `$091C`: the quick-repeat window, counted down at 5 Hz.
        public static let quickRepeatWindow = 0x091C
        /// `$095B`: demo mode chosen at the prompt; the 1-in-8 check sets `$08BB` = 3.
        public static let demoRequest = 0x095B
        /// `$0963`: the current mode.
        public static let currentMode = 0x0963
        /// `$0966`: slew mode.
        public static let slewMode = 0x0966
        /// `$0969`: the editor's Europe 1917 switch (war mode).
        public static let europe1917 = 0x0969
        /// `$0E6B`: frames since the last 10 Hz tick (the IRQ increments it).
        public static let frameDivider = 0x0E6B
        /// `$0E6C`: 10 Hz tick count; bit 0 selects the 5 Hz work.
        public static let tickCounter = 0x0E6C
        /// `$0E6D`: the CIA1 TOD seconds last seen; a change runs the 1 Hz work.
        public static let lastTodSeconds = 0x0E6D
        /// `$0E70`: Q asks for the course plotter menu.
        public static let coursePlotterRequest = 0x0E70
        /// `$0E79`: bit 0 skips the next page flip.
        public static let skipFlip = 0x0E79
        /// `$0E7C`: set to 7 when Europe 1917 forces mode 7; leaving mode 7 restarts.
        public static let warModeLatch = 0x0E7C
        /// `$0E87`: CTRL-E asks for the database info screen.
        public static let databaseInfoRequest = 0x0E87
        /// `$22B0`: the immediate operand the window-phase IRQ stores to `$D018` ($F0 bitmap
        /// $4000, $F8 bitmap $6000), written by the flip.
        public static let flipOperand = 0x22B0
        /// `$22B5`: the immediate operand of the window-phase border color (the time-of-day
        /// palette writes it).
        public static let borderOperand = 0x22B5
        /// `$26FF`: the RESTORE restart's one-shot.
        public static let restoreOneShot = 0x26FF
    }

    /// How `runMainLoop` / `coldStart` ended (the game itself never ends).
    public enum Exit: Sendable, Equatable {
        /// `mainLoopHook` returned false at the top of a pass.
        case stopped
        /// A display list the original cannot run (it would show its system-error screen).
        case fault(Scenery.Fault)
    }

    /// How a pass ends: back to the top ($204B), or the cold restart of the war-exit check ($2149),
    /// which jumps to $A7E2.
    public enum PassEnd: Sendable, Equatable { case next, coldRestart }

    /// What an overlay slot did: returned to the caller, or reached the cold-start entry $A946
    /// (through slot $A7E2), which never returns.
    enum SlotOutcome: Equatable { case returned, coldInit }
}

extension Machine {
    // MARK: The loop ($2048 / $204B)

    /// $2048 `mainLoopEntry`: the slot $A7F4 once (with overlay 0 resident after the cold init, the
    /// slot loads the flight overlay), then the loop.
    public func mainLoopEntry() {
        charge(6)
        runOverlaySlot(0xA7F4)
    }

    /// $2048/$204B: runs the main loop, from the entry `mainLoopEntry` when `fromEntry`, else from
    /// the top of a pass. Before every pass `mainLoopHook` decides whether to go on; without a
    /// hook the loop never ends. The war-exit check's cold restart ($2149) re-runs the init chain
    /// and continues at $2048 here.
    @discardableResult
    public func runMainLoop(fromEntry: Bool = true) -> MainLoop.Exit {
        if fromEntry { mainLoopEntry() }
        while mainLoopHook?(self) ?? true {
            do {
                if try mainLoopPass() == .coldRestart {
                    coldStartSlot()
                    mainLoopEntry()
                }
            } catch {
                return .fault(error)
            }
        }
        return .stopped
    }

    /// $204B-$2193: one pass of the main loop. Returns `.coldRestart` when the war-exit check
    /// jumps to $A7E2.
    public func mainLoopPass() throws(Scenery.Fault) -> MainLoop.PassEnd {
        let m = mem
        let R = MainLoop.RAM.self
        // $204B: is the editor or a mode change requested?
        if m[R.editorRequest] | m[R.modeRequest] != 0 {
            charge(16)                           // requested: the editor slot $A7E8
            runOverlaySlot(0xA7E8)
            // The editor cache: a first entry marks it cached (the load itself copied the overlay
            // to the cache); an entry with the cache valid (state 1) swaps it back out through
            // $E6DB.
            let x = m[R.editorCacheState]
            var c = 4
            if x == 0 {
                m[R.editorCacheState] = 1
                c += 8
            } else {
                c += 3
            }
            c += 2                                          // the state test
            if x &- 1 != 0 {
                charge(c + 3)
            } else {
                charge(c + 8)                           // state 1: swap the cache out
                swapEditorCache()
            }
        } else {
            charge(11)
        }
        // $2066: the flight slot $A7F4 again (with the flight overlay resident it returns at once).
        charge(6)
        runOverlaySlot(0xA7F4)
        // Slew mode, or the integrator and the wind drift.
        if m[R.slewMode] != 0 {
            charge(12)                               // slew mode
            slewIntegrate()
            charge(3)                                       // past the flight branch
        } else {
            charge(13)                               // normal flight
            integrateFlight()
            charge(6)
            windDrift()
        }
        charge(6)
        plotterDisplay()
        charge(6)
        setSceneryRoot()
        charge(9)                                       // through the vector $8000
        buildViewMatrix()
        // Bit 0 of `$0E79`, shifted out, skips the flip.
        let skip = m[R.skipFlip]
        m[R.skipFlip] = skip >> 1
        if skip & 1 != 0 {
            charge(11)
        } else {
            charge(9)
            pageFlip()
        }
        try drawSequence()
        if try phaseTasks() == .coldRestart { return .coldRestart }
        // $2191: the pass counted, back to the top $204B.
        m[R.mainLoopCounter] &+= 1
        charge(8)
        return .next
    }

    /// $208B-$20D4: the page flip. Adds `$8D` to the 112 window-row high bytes ($0200-$026F, so
    /// drawing moves to the other bitmap), `$8D` ^= $C0, and stores the bitmap just finished into
    /// the IRQ's `$D018` operand `$22B0`: $F0 when `$8D` turned negative, else $F8 after the
    /// alternate-pass tasks.
    func pageFlip() {
        let m = mem
        let R = MainLoop.RAM.self
        let delta = m[R.drawBufferDelta]
        for row in 0..<0x70 { m[Machine.rowAddressHi + row] &+= delta }
        // 112 passes of 20 cycles (indexed from $01FF, the table read always crosses a page), the
        // last loop test not taken.
        charge(2 + 0x70 * 20 - 1)
        // `$8D` toggled; its sign picks the bitmap operand.
        let flipped = delta ^ 0xC0
        m[R.drawBufferDelta] = flipped
        var operand: UInt8 = 0xF0
        if flipped & 0x80 != 0 {
            charge(13)
        } else {
            charge(12)
            alternatePassTasks()
            operand = 0xF8
            charge(2)                                       // the $F8 operand
        }
        m[R.flipOperand] = operand
        charge(4)                                           // the store into the IRQ's operand
    }

    /// $20A3-$20CF: the tasks of every other flip (when `$8D` turns to $20): the ATIS teletype,
    /// the crash message, the course plotter menu, the war-mode `$FD00` hook (a documented
    /// no-op) and the database info screen.
    func alternatePassTasks() {
        let m = mem
        let R = MainLoop.RAM.self
        charge(6)
        atisTeletypeJump()
        // The crash or splash message when `$0834` is set.
        let crash = m[R.crashCode]
        if crash != 0 {
            charge(12)
            crashMessage(code: crash)
        } else {
            charge(7)
        }
        // The course plotter menu when bit 0 of `$0E70`, shifted out, is set.
        let plotter = m[R.coursePlotterRequest]
        m[R.coursePlotterRequest] = plotter >> 1
        if plotter & 1 != 0 {
            charge(14)
            coursePlotterMenu()
        } else {
            charge(9)
        }
        // In Europe 1917, the `$FD00` hook when bit 0 of `$08D7`, shifted out, is set.
        if m[R.europe1917] != 0 {
            let hook = m[R.fd00HookRequest]
            m[R.fd00HookRequest] = hook >> 1
            if hook & 1 != 0 {
                // $FD00: the war-mode hook is empty in this image (all zero bytes). Decided: a
                // documented no-op (re/docs/excluded.md); its call and a return are charged.
                charge(26)
            } else {
                charge(15)
            }
        } else {
            charge(7)
        }
        // The database info screen when `$0E87` is set: the request cleared, the slot $A7FA.
        if m[R.databaseInfoRequest] != 0 {
            m[R.databaseInfoRequest] = 0
            charge(18)
            runOverlaySlot(0xA7FA)
        } else {
            charge(7)
        }
    }

    /// $20D5-$210C: the draw sequence of every pass.
    func drawSequence() throws(Scenery.Fault) {
        let m = mem
        let R = MainLoop.RAM.self
        charge(9)                                       // through the vector $8003
        try horizonPass()
        charge(9)                                       // through the vector $8006
        try runScenery()
        charge(6)
        stepNav2Needle()
        charge(6)
        drawTach()
        charge(9)                                       // through the vector $8021
        drawAttitudeIndicator()
        charge(6)
        drawObi1()
        charge(6)
        drawObi2()
        charge(6)
        trackGroundElevation()
        charge(6)
        headingReadout()
        charge(6)
        drawDgDigits()
        charge(6)
        updateCompass()
        charge(6)
        updateLightingMasks()
        // In Europe 1917 the war slot $A7EE (skipping it crosses a page: one more cycle).
        if m[R.europe1917] != 0 {
            charge(12)
            runOverlaySlot(0xA7EE)
        } else {
            charge(8)
        }
        charge(6)
        drawViewOverlay()
        charge(6)
        altimeterUpdate()
        charge(6)
        airspeedUpdate()
        charge(6)
        updateInstrumentMasks()
    }

    /// $210D-$2190: the phase tasks on `$22 & 3` (and the 1-in-8 tasks of phase 0 with `$22 & 4`,
    /// among them the demo check and the war-exit check, whose jump to $A7E2 is returned as
    /// `.coldRestart`).
    func phaseTasks() throws(Scenery.Fault) -> MainLoop.PassEnd {
        let m = mem
        let R = MainLoop.RAM.self
        let counter = m[R.mainLoopCounter]
        if counter & 1 == 0 {
            if counter & 2 == 0 {
                // Phase 0: the phase bits tested, then the time-of-day palette.
                charge(17)
                selectTimeOfDay()
                charge(9)                               // through the vector $8012
                drawTurnCoordinator()
                charge(6)
                drawLeftFuelGauge()
                charge(6)
                windLayer()
                charge(6)
                drawDme()
                // The 1-in-8 tasks when bit 2 of `$22` is set.
                if m[R.mainLoopCounter] & 4 != 0 {
                    charge(13)                   // bit 2 set
                    renewNav1Search()
                    charge(6)
                    renewNav2Search()
                    charge(6)
                    _ = renewAdfSearch()
                    // $2133: the demo check: a pending demo request asks for mode 3.
                    if m[R.demoRequest] != 0 {
                        m[R.modeRequest] = 3
                        charge(12)
                    } else {
                        charge(7)
                    }
                    // $213D: the war-exit check: latched in war mode but no longer in mode 7
                    // (Europe 1917 left) restarts cold at $A7E2.
                    if m[R.warModeLatch] != 0 {
                        if m[R.currentMode] != 7 {
                            charge(17)
                            return .coldRestart
                        }
                        charge(15)
                    } else {
                        charge(7)
                    }
                    charge(3)                               // on to the even-phase tasks
                } else {
                    charge(8)
                }
            } else {
                // Phase 2: the phase bits tested, then the oil temperature gauge.
                charge(18)
                drawOilTempGauge()
                charge(6)
                densityAndAutoLevel()
                charge(3)                                   // on to the even-phase tasks
            }
            evenPhaseTasks()
        } else {
            if counter & 2 == 0 {
                // Phase 1: the phase bits tested, then the right fuel gauge.
                charge(18)
                drawRightFuelGauge()
                charge(6)
                draw10kMarker()
                charge(3)                                   // on to the odd-phase tasks
            } else {
                // Phase 3: the phase bits tested, the oil pressure gauge, then the failures ($EA84)
                // with the carry the gauge leaves behind.
                charge(19)
                let unchanged = m[0x09CD] == m[Gauges.IndicatorState.oilPressureBar]
                drawOilPressureGauge()
                charge(6)
                realityFailures(carry: unchanged || plotPointListCarry())
            }
            oddPhaseTasks()
        }
        return .next
    }

    /// $216A-$2184: the odd-phase tasks, then the 16-bit `$0832:$0833` rotated left by one (its top
    /// bit wraps around into bit 0), and on to $2191.
    func oddPhaseTasks() {
        let m = mem
        let R = MainLoop.RAM.self
        charge(6)
        updateNav1Cdi()
        charge(6)
        updateNav2Cdi()
        charge(6)
        vsiUpdate()
        charge(6)
        updateAdf()
        let lo = m[R.phaseRotor], hi = m[R.phaseRotor + 1]
        m[R.phaseRotor + 1] = hi << 1 | lo >> 7
        m[R.phaseRotor] = lo << 1 | hi >> 7
        charge(21)                       // the rotation, on to $2191
    }

    /// $2185-$2190: the even-phase tasks.
    func evenPhaseTasks() {
        charge(6)
        splashDetect()
        charge(6)
        maneuverRegimeTimer()
        charge(6)
        slipBallUpdate()
        charge(6)
        engineModel()
    }

    /// The carry `plotPointList` ($1D01) leaves for its caller: the carry out of the last point's
    /// row addition (with the row offset `$0AA0`); nothing after it in the loop touches the carry.
    /// Phase 3 passes it from the oil-pressure gauge to `realityFailures`.
    func plotPointListCarry() -> Bool {
        let list = zpPointer(Gauges.markerShapePtr)
        let count = Int(mem[list])
        let n = count == 0 ? 256 : count
        let dy = mem[(list + (2 * n) & 0xFF) & 0xFFFF]
        return Int(dy) + Int(mem[Gauges.markerY]) > 0xFF
    }
}
