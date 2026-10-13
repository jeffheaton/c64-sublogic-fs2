import FS2Data

/// The cold start: the state SubLogic's stage 2 hands over, and the init chain of overlay 0
/// ($A946-$ABBA) that ends in the main loop. The disk layer is not ported (the boot loads are
/// direct copies with the loader's memory effects, `Scenery.Loader`), nor is anything a modified
/// copy adds or SubLogic's protection (the stubs $AAF7/$AAF9 and the drive-status check $7848).
extension MainLoop {
    /// The loop count of the TOD calibration ($AB3B-$AB45) in one TOD tenth on an NTSC machine,
    /// as the lab measures it after the boot (`$A5/$A6`). The port does not run the loop: it
    /// waits the time and stores this count, whose outcome is the NTSC one (below $1ABD: the TOD
    /// stays on 60 Hz).
    public static let ntscCalibrationCount: UInt16 = 0x18CB
    /// The calibration's threshold: a count of $1ABD or more means a PAL machine (`$DC0E` = $80).
    public static let palCalibrationThreshold: UInt16 = 0x1ABD
    /// `$A800`: the boot load list of overlay 0 ((first block, count) pairs).
    public static let bootLoadTable = 0xA800
    /// The destinations `bootLoads` gives the five loads, in order.
    public static let bootLoadDestinations: [UInt16] = [0x0200, 0x5000, 0x77E0, 0xC000, 0xE000]
    /// `$A80C` / `$A8F4`: the title and the operating-mode prompt (text record lists in overlay 0).
    public static let titleRecordList: UInt16 = 0xA80C
    public static let modePromptList: UInt16 = 0xA8F4
}

extension Machine {
    // MARK: The stage-2 handoff

    /// The 64 KB image as SubLogic's stage 2 ($78A2) leaves it when it hands over to $A7E2, built
    /// from the disk's logical blocks: stage 2 (blocks 0-1) at $7300 and stage 3 = overlay 0
    /// (blocks 2-4) at $A7E0, with the title records a modified copy adds blanked
    /// (`ColdImage.scrubCrack`); the NMI and IRQ vectors at the loader's do-nothing interrupt
    /// return $790A; `$01` = $35 (KERNAL out, I/O in); the drive number offset `$731B` = 0 and the
    /// drive-status result `$7326` = 0 (the check itself is SubLogic's protection and is not
    /// ported). Everything else is zero. This is the state the lab boots from (`Lab.boot`).
    public static func bootMemory(blocks: [[UInt8]]) -> [UInt8] {
        var mem = [UInt8](repeating: 0, count: memorySize)
        for load in [FS2Layout.stage2, FS2Layout.stage3] {
            for i in 0..<load.count {
                let block = blocks[load.block + i]
                for j in 0..<SubLogicDisk.blockSize {
                    let a = load.address + i * SubLogicDisk.blockSize + j
                    if a < memorySize { mem[a] = block[j] }
                }
            }
        }
        ColdImage.scrubCrack(&mem)
        for vector in [0xFFFA, 0xFFFE] {
            mem[vector] = 0x0A
            mem[vector + 1] = 0x79
        }
        mem[0x01] = 0x35
        mem[0x731B] = 0
        mem[0x7326] = 0
        return mem
    }

    /// The hardware as stage 2 leaves it: color RAM white, the VIC as the KERNAL set it up
    /// (`$D011` $1B, `$D016` $C8, `$D018` $14, border $0E, background $06, no raster IRQ), CIA2
    /// port A $97 (VIC bank 0) with direction $3F, the main program's interrupt flag set.
    public func stage2Handoff() {
        io.colorRAM = [UInt8](repeating: 0x01, count: 1024)
        io.writeVIC(0x11, 0x1B)
        io.writeVIC(0x16, 0xC8)
        io.writeVIC(0x18, 0x14)
        io.writeVIC(0x20, 0x0E)
        io.writeVIC(0x21, 0x06)
        io.writeCIA2(0x02, 0x3F)
        io.writeCIA2(0x00, 0x97)
        interruptDisable = true
    }

    /// A machine at the stage-2 handoff, ready for `coldStart` (the disk blocks are also what
    /// every later load reads).
    public static func booting(blocks: [[UInt8]]) -> Machine {
        let m = Machine(memory: bootMemory(blocks: blocks))
        m.diskBlocks = blocks
        m.stage2Handoff()
        return m
    }

    // MARK: $A7E2 / $A946: the cold start

    /// The entry $A7E2 (stage 2's handoff, the RESTORE restart, the war exit): the slot (overlay
    /// 0's own slot goes straight to $A946; another overlay's first reloads overlay 0 through the
    /// vector $2015), the init chain `coldInit`, and the main loop from $2048. Returns only when
    /// `mainLoopHook` stops the loop (or a display list faults).
    @discardableResult
    public func coldStart() -> MainLoop.Exit {
        coldStartSlot()
        return runMainLoop(fromEntry: true)
    }

    /// $A946 `coldInit`: the init chain up to its jump into the main loop at $2048. It resets the
    /// stack to $3F with interrupts masked, turns the sprites off, opens the loader ($7306), runs
    /// the five boot loads (`bootLoads`), the protection stub $AAF7 (not ported: its time only),
    /// the close ($E6D2) and the zero-page copy (`copyZeroPage`); then at $A970 (where the lab
    /// blanks the added bytes the loads brought back, and so does the port):
    /// `interruptAndTimingSetup`, the stub $AAF9 (time only), `titleScreen` (with the mode prompt),
    /// `initPanelState`, `patchRadioHooks`, `copyPanelRow`, `initUserLibrary`.
    public func coldInit() {
        sei()
        charge(10)                           // the stack reset, interrupts masked
        io.writeVIC(0x15, 0x00)
        charge(10)                                     // sprites off, the call of the loader's open
        loaderOpen()
        charge(8)                                       // the error check, the call of bootLoads
        bootLoads()
        // The protection stub $AAF7 (it only reports success; not ported, its time kept), the error
        // checks and the call of the close $E6D2.
        charge(24)
        cacheHelper()
        charge(8)                                       // the error check, the call of copyZeroPage
        copyZeroPage()
        charge(3)                                           // on to $A970
        // $A970: nothing a modified copy added may show; the reloaded blocks carry it again. Only
        // those added bytes are blanked: a clean disk keeps SubLogic's title lines.
        ColdImage.scrubCrack(memory: mem)
        charge(6)
        interruptAndTimingSetup()
        charge(12)                                 // the stub $AAF9 (it returns at once: time only)
        charge(6)
        titleScreen()
        charge(6)
        initPanelState()
        charge(6)
        patchRadioHooks()
        charge(6)
        copyPanelRow()
        charge(6)
        initUserLibrary()
        charge(3)                                           // on into the main loop at $2048
    }

    /// $A988 `bootLoads`: the five loads of the table $A800 (main code $0200, panel $5000, the 3D
    /// engine $77E0, $C000, $E000): per load `$731E/$731F` = the destination, `$731C` = the first
    /// block, `$A4` = the count; per block the loader's read ($7309, `loaderRead`) and the border =
    /// `$731C` (the next block). Charges from $A988 through its return.
    public func bootLoads() {
        let m = mem
        for (k, destination) in MainLoop.bootLoadDestinations.enumerated() {
            m[Scenery.Loader.destination] = UInt8(destination & 0xFF)
            m[Scenery.Loader.destination + 1] = UInt8(destination >> 8)
            let first = m[MainLoop.bootLoadTable + 2 * k], count = m[MainLoop.bootLoadTable + 2 * k + 1]
            // The destination, the table pair, the call of $A9F2.
            charge(26)
            // $A9F2: the first block and the count into place.
            m[Scenery.Loader.block] = first
            m[0xA4] = count
            charge(7)
            repeat {
                charge(6)
                loaderRead()
                io.writeVIC(0x20, m[Scenery.Loader.block])
                m[0xA4] &-= 1
                // The error check, the next block number as the border color, the count down.
                charge(15 + (m[0xA4] != 0 ? 3 : 2))
            } while m[0xA4] != 0
            charge(8)                                   // the return, the error check
        }
        charge(6)                                           // the return
    }

    /// $ABB0 `copyZeroPage`: $AC02-$ACFF to $02-$FF. Charges through its return.
    public func copyZeroPage() {
        let m = mem
        for a in 0x02...0xFF { m[a] = m[0xAC00 + a] }
        charge(2 + 0xFE * 13 - 1 + 6)
    }

    // MARK: $AAFA: interrupts and the TOD calibration

    /// $AAFA `interruptAndTimingSetup`: `maskInterrupts`, the held-key slots `$089B-$089E` = $80,
    /// `displayInit` (the raster IRQ $2285), the NMI vector `$FFFA/$FFFB` = $2700 (a memory write),
    /// `$DC0E` = `$DC0F` = 0 and the TOD tenths = 0 (which starts the clock), `$A5/$A6` = 0; then,
    /// with interrupts masked, the 50/60 Hz calibration: it waits for two TOD tenth edges and
    /// counts loop passes during the next tenth into `$A5/$A6`; interrupts unmasked; a count of
    /// $1ABD or more would set `$DC0E` = $80 (PAL). The port is NTSC only: it waits the same time
    /// on the virtual TOD and stores the NTSC count (`MainLoop.ntscCalibrationCount`), so `$DC0E`
    /// stays 0. Charges through its return (the wait at the loop's pace is about 0.2-0.3 s).
    public func interruptAndTimingSetup() {
        let m = mem
        charge(6)
        maskInterrupts()
        for k in 0..<4 { m[Input.RAM.heldKeySlots + k] = 0x80 }
        charge(2 + 4 * 4 + 6)                             // the four slots, the call of displayInit
        displayInit()
        m[0xFFFA] = 0x00
        m[0xFFFB] = 0x27
        charge(14)                           // the NMI vector
        io.writeCIA1(0x0E, 0x00, at: clock.cycles)
        charge(4)
        io.writeCIA1(0x0F, 0x00, at: clock.cycles)
        charge(4)
        io.writeCIA1(0x08, 0x00, at: clock.cycles)
        charge(4)
        m[0xA5] = 0
        m[0xA6] = 0
        charge(8)                                   // the count cleared, interrupts masked
        sei()
        // The calibration loop (it syncs to two tenth-second edges of the TOD clock, then counts
        // 16-bit loop passes until the tenths change again): its time, a wait for the third TOD
        // tenth edge (wall time: the VIC's DMA slows the loop, not the edges), then the NTSC count.
        io.timeOfDay.advance(to: clock.cycles)
        let tenth = UInt64(TimeOfDayClock.cyclesPerMainsTick * 6)
        let end = io.timeOfDay.nextTenthCycle() + 2 * tenth
        if clock.cycles < end { elapse(Int(end - clock.cycles)) }
        let count = MainLoop.ntscCalibrationCount
        m[0xA5] = UInt8(count & 0xFF)
        m[0xA6] = UInt8(count >> 8)
        cli()
        // Interrupts unmasked; the count compared with $1ABD (below it for the NTSC count, so the
        // TOD stays at 60 Hz); the return.
        precondition(count < MainLoop.palCalibrationThreshold)
        charge(23)
    }

    /// $AB78 `maskInterrupts`: masks interrupts; `$DC0D` = `$DD0D` = $1F (all CIA interrupt sources
    /// off); both ICRs read (clearing them). Charges through its return.
    public func maskInterrupts() {
        sei()
        charge(4)                                       // interrupts masked, the source mask
        io.writeCIA1(0x0D, 0x1F, at: clock.cycles)
        charge(4)
        io.writeCIA2(0x0D, 0x1F)
        charge(4)
        _ = readIO(0xDC0D)
        charge(4)
        _ = readIO(0xDD0D)
        charge(10)
    }

    // MARK: $AA1C / $AA71: the title and the prompts

    /// $AA1C `titleScreen`: clears the window, draws the title list at $A80C (SubLogic's title
    /// and version; the two records a modified copy overwrites are blank) with the display prompt,
    /// and waits for A or B (`waitForKey`; other keys are ignored). A: the color palette (`$0E61` =
    /// $65, `$0E63` = $6C, `$0E65` = $EA, `$D021` value `$0E69` = $0B); B: black and white ($FC,
    /// $CB, $CB, $00). Both: the borders `$0E62/$0E64/$0E66` = $0E/$06/$00, `$083C` = 0 and
    /// `selectTimeOfDay`; then falls into `modePromptScreen`.
    public func titleScreen() {
        let m = mem
        charge(6)
        clearWindow()
        charge(10)                                   // the list address, the call
        drawTextList(MainLoop.titleRecordList)
        while true {
            charge(6)
            let key = waitForKey()
            if key == 0x41 {
                m[0x0E61] = 0x65
                m[0x0E63] = 0x6C
                m[0x0E65] = 0xEA
                m[0x0E69] = 0x0B
                charge(2 + 3 + 4 * 6 + 3)          // the key test, four palette stores, on to $AA5C
                break
            }
            if key == 0x42 {
                m[0x0E61] = 0xFC
                m[0x0E63] = 0xCB
                m[0x0E65] = 0xCB
                m[0x0E69] = 0x00
                charge(31)
                break
            }
            charge(11)                       // neither key: both tests, wait again
        }
        // $AA5C
        m[0x0E62] = 0x0E
        m[0x0E64] = 0x06
        m[0x0E66] = 0x00
        m[0x083C] = 0x00
        charge(28)               // the borders, `$083C`, the call of selectTimeOfDay
        selectTimeOfDay()
        modePromptScreen()
    }

    /// $AA71 `modePromptScreen`: clears the window, draws the operating-mode prompt with its two
    /// choices, A demo mode and B regular flight ($A8F4), waits for A or B; A counts up the demo
    /// request `$095B`. Then `$08BA` = 0. Charges through its return.
    public func modePromptScreen() {
        let m = mem
        charge(6)
        clearWindow()
        charge(10)                                   // the list address, the call
        drawTextList(MainLoop.modePromptList)
        while true {
            charge(6)
            let key = waitForKey()
            if key == 0x41 {
                m[MainLoop.RAM.demoRequest] &+= 1
                charge(11)                           // the key test, the demo request
                break
            }
            if key == 0x42 {
                charge(9)
                break
            }
            charge(11)
        }
        m[MainLoop.RAM.editorRequest] = 0
        charge(12)                                   // the editor request cleared, the return
    }

    // MARK: $AA91: the panel's initial state

    /// $AA91 `initPanelState`: `$08CF` = 1; draws every panel indicator at its starting value
    /// through the second halves of the indicator routines (store the value, draw it): the
    /// altimeter hands at `$20`/`$1F` ($1A20), the airspeed needle at `$21` ($1A5C, with A from
    /// `$21`), the VSI needle at 0 ($1A82), the turn-coordinator wings at 8 (through the vector
    /// $8027), the elevator marker $0A ($1B9A), ailerons and rudder $0F ($1BB4, $1BD5), throttle,
    /// flaps 0, trim 5, mixture, slip ball, fuel and oil bars 0 ($1BE9-$1CD1); then the OBS
    /// readouts, the radio and clock readouts (`panelRedraw`), the magneto label and `sidInit`.
    public func initPanelState() {
        let m = mem
        m[0x08CF] = 1
        charge(16)                              // `$08CF` set, on into the altimeter hands at $1A20
        storeAltimeterHands()
        charge(9)                                       // the airspeed angle, the call of $1A5C
        storeAirspeedNeedle(m[Gauges.vsiNeedle])
        charge(8)                                       // the VSI at zero, the call of $1A82
        // $1A82 selects gauge 3 and shares the store-and-draw tail at $1A2B.
        m[Gauges.needleAngles + 3] = 0
        charge(16)
        drawNeedle(angle: 0, gauge: 3)
        charge(6)
        charge(11)                          // wings level (8), through the vector $8027 on to $A558
        turnCoordinatorHelper(8)
        let S = Gauges.IndicatorState.self
        // $1B9A: the elevator state stored, then its marker drawn at the value.
        charge(8)
        storeIndicator(S.elevatorMarker, 0x0A) { v in
            self.mem[Gauges.markerShapePtr] = 0x10
            return 18 + self.plotMarkerShapeBody(0x6C, v &+ 0xA9, 0x0F)
        }
        // $1BB4 ailerons, $1BD5 rudder: the control pointer ($1BBD).
        charge(8)
        storeIndicator(S.aileronMarker, 0x0F) { v in 8 + self.controlPointerBody(v &+ 0x5D, 0x9E) }
        charge(8)
        storeIndicator(S.rudderMarker, 0x0F) { v in 11 + self.controlPointerBody(v &+ 0x5D, 0xC4) }
        // $1BE9 throttle
        charge(8)
        storeIndicator(S.throttleMarker, 0x00) { v in
            self.mem[Gauges.markerShapePtr] = 0x12
            return 20 + self.plotMarkerShapeBody(0xE1, ~v &+ 0xC7, 0x16)
        }
        // $1C05 flaps, $1C18 trim, $1C2B mixture: the slider marker ($1C33).
        charge(8)
        storeIndicator(S.flapsMarker, 0x00) { v in 9 + self.sliderMarkerBody(0xE1, v &+ 0x73) }
        charge(8)
        storeIndicator(S.trimMarker, 0x05) { v in 9 + self.sliderMarkerBody(0xE1, v &+ 0x94) }
        charge(8)
        storeIndicator(S.mixture, 0x00) { v in 6 + self.sliderMarkerBody(0xE8, v &+ 0xB9) }
        // $1C4B slip ball
        charge(8)
        storeIndicator(S.turnBall, 0x00) { v in
            self.mem[Gauges.markerShapePtr] = 0x30
            return 18 + self.plotMarkerShapeBody(v &+ 0x0E, 0xBE, 0x0F)
        }
        // $1C6F left fuel and $1C89 right fuel share the bar body $1C8F; $1CB8 oil temperature and
        // $1CD1 oil pressure share $1CD7; the right-hand bars of each pair sit $23 pixels further
        // right.
        charge(8)
        storeIndicator(S.leftFuelBar, 0x00) { v in 3 + self.engineBarBody(v, row: 0xB2) }
        charge(8)
        storeIndicator(S.rightFuelBar, 0x00) { v in 4 + self.engineBarBody(v &+ 0x23, row: 0xB2) }
        charge(8)
        storeIndicator(S.oilTempBar, 0x00) { v in 3 + self.engineBarBody(v, row: 0xBA) }
        charge(8)
        storeIndicator(S.oilPressureBar, 0x00) { v in 4 + self.engineBarBody(v &+ 0x23, row: 0xBA) }
        charge(6)
        drawObs1()
        charge(6)
        drawObs2()
        charge(6)
        panelRedraw()
        charge(6)
        drawMagnetoLabel()
        charge(6)
        sidInit()
        charge(6)                                           // the return
    }

    /// $1A20 (inside `updateAltimeterNeedles`): stores and draws the short hand (gauge 1, from
    /// `$20`) through the shared tail $1A2B, then falls into $1A27 for the long hand (gauge 0, from
    /// `$1F`); the tail records the angle in the table at $0F62 and draws the needle. Charges
    /// through its return.
    private func storeAltimeterHands() {
        let m = mem
        let short = m[Gauges.altimeterShortHand]
        m[Gauges.needleAngles + 1] = short
        charge(22)
        drawNeedle(angle: short, gauge: 1)
        charge(6)                                           // the return of $1A2B
        let long = m[Gauges.altimeterLongHand]
        m[Gauges.needleAngles] = long
        charge(16)
        drawNeedle(angle: long, gauge: 0)
        charge(6)
    }

    /// $1A5C (inside `updateAirspeedNeedle`): records the angle for gauge 2 in the table at $0F62,
    /// then $1A61 wraps it below 88 ($58) and goes on to the needle drawing $1A86. Charges through
    /// its return.
    private func storeAirspeedNeedle(_ angle: UInt8) {
        mem[Gauges.needleAngles + 2] = angle
        let wrapped = angle >= 0x58 ? angle &- 0x58 : angle
        charge(9 + (angle >= 0x58 ? 4 : 3) + 3)
        drawNeedle(angle: wrapped, gauge: 2)
    }

    /// The second half of a linear indicator (the state byte stored, then the drawing at the value,
    /// which ends in the plotter's return). Charges through that return.
    private func storeIndicator(_ state: Int, _ value: UInt8, _ draw: (UInt8) -> Int) {
        mem[state] = value
        charge(4 + draw(value))
    }

    /// $1BBD: shape $0F1D at (x, row), through the shared plot at $1BC3.
    private func controlPointerBody(_ x: UInt8, _ y: UInt8) -> Int {
        mem[Gauges.markerShapePtr] = 0x1D
        return 7 + plotMarkerShapeBody(x, y, 0x0F)
    }

    /// $1C33: shape $161B at (x, row), with the row taken from A, through the shared plot at $1BC3.
    private func sliderMarkerBody(_ x: UInt8, _ y: UInt8) -> Int {
        mem[Gauges.markerShapePtr] = 0x1B
        return 12 + plotMarkerShapeBody(x, y, 0x16)
    }

    /// $1C8F (row $B2) / $1CD7 (row $BA): the bar's x is the value plus 4, with the carry giving
    /// the x high byte `$0A90` (1 or 2), and the row is set (the oil bars rejoin the fuel bars'
    /// code at $1C9C); then the bar shape $0F49 through $1D01.
    private func engineBarBody(_ a: UInt8, row: UInt8) -> Int {
        let (x, carry) = a.addingReportingOverflow(4)
        mem[Gauges.markerXHigh] = carry ? 2 : 1
        mem[Gauges.markerShapePtr] = 0x49
        mem[Gauges.markerShapePtr + 1] = 0x0F
        let jump = row == 0xB2 ? 0 : 3
        return 16 + jump + 13 + plotPointListBody(x, row)
    }

    // MARK: $AA07, $AB66, $AB88

    /// $AA07 `patchRadioHooks`: the hooks in the renderer's vector table get their targets: the
    /// operand $802E/$802F = $F16A (the ATIS composer, op 1E) and $802B/$802C = $E956 (the NDB
    /// hook, op 05). Charges through its return.
    public func patchRadioHooks() {
        let m = mem
        m[0x802E] = 0x6A
        m[0x802F] = 0xF1
        m[0x802B] = 0x56
        m[0x802C] = 0xE9
        charge(4 * 6 + 6)
    }

    /// $AB66 `copyPanelRow`: copies the panel's first character row ($5180-$52BF) into bitmap B at
    /// $7180-$72BF, so the split line 112 shows the panel whichever buffer is displayed. Charges
    /// through its return.
    public func copyPanelRow() {
        let m = mem
        // X counts down from 0 through $FF to 1, copying both halves per pass; the reads from $5180
        // and $51C0 cross a page (one more cycle) for X >= $80 and X >= $40.
        var x: UInt8 = 0
        repeat {
            m[0x7180 + Int(x)] = m[0x5180 + Int(x)]
            m[0x71C0 + Int(x)] = m[0x51C0 + Int(x)]
            x &-= 1
        } while x != 0
        charge(2 + 256 * 23 + 0x80 + 0xC0 - 1 + 6)
    }

    /// $AB88 `initUserLibrary`: fills the 15 user-mode records (65 bytes each, from `[$0961]` =
    /// $C800) with their numbers $0A-$18, through the pointer `$BA/$BB`. Charges through its
    /// return.
    public func initUserLibrary() {
        let m = mem
        m[0xBA] = m[0x0961]
        m[0xBB] = m[0x0962]
        var c = 16                           // the pointer from `[$0961]`, the first number
        var value: UInt8 = 0x0A
        repeat {
            let base = zpPointer(0xBA)
            for y in stride(from: 0x40, through: 0, by: -1) { m[(base + y) & 0xFFFF] = value }
            c += 2 + 65 * 11 - 1                   // 65 stores down the record
            value &+= 1
            let (lo, carry) = m[0xBA].addingReportingOverflow(0x41)
            m[0xBA] = lo
            c += 17                  // the next number kept, the pointer 65 bytes on
            if carry {
                m[0xBB] &+= 1
                c += 7
            } else {
                c += 3
            }
            c += 6 + (value != 0x19 ? 3 : 2)            // until the number reaches $19
        } while value != 0x19
        charge(c + 6)
    }
}
