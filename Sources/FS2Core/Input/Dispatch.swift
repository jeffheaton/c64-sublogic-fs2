import C64Kit

/// The command dispatcher ($27D8) and the wait-for-key loop ($2250).
extension Machine {
    // MARK: dispatchKey ($27D8)

    /// $27D8 (the 10 Hz tick, once per tick when the ring is not empty and `$08C3` = 0): pops one
    /// code (`dequeueKey`; with an empty ring A is the read index) and clears the demo flag
    /// `$095A`. In text-input mode (`$08BA` != 0: the editor, `waitForKey`) it stores
    /// code | $80 in `$08C4` and returns. Otherwise codes ≥ $60 are dropped, and the rest jump
    /// through the handler table: the pointer $2718 + 2·code goes into the operand `$27FF/$2800`
    /// of the self-modified indirect jump at $27FE, which runs the handler (the handler's return
    /// ends the dispatcher too). Clobbers A, X, Y.
    public func dispatchKey() {
        let m = mem
        let R = Input.RAM.self
        charge(6)
        let a = dequeueKey().code
        m[R.demoActive] = 0
        var c = 10                                          // clear the demo flag, test text-input mode
        if m[R.editorRequest] != 0 {
            m[R.promptKey] = a | 0x80
            charge(c + 14)                                  // hand the key to the waiting prompt
            return
        }
        c += 5
        guard a < 0x60 else { charge(c + 8); return }       // no handler for this code
        // Point the jump's operand at the code's word in the table $2718.
        let sum = Int(a << 1) + 0x18
        let pointer = (0x27 + (sum >> 8)) << 8 | (sum & 0xFF)
        m[R.dispatchOperand] = UInt8(pointer & 0xFF)
        m[R.dispatchOperand + 1] = UInt8(pointer >> 8)
        charge(c + 26)                                      // through the indirect jump
        runKeyHandler(UInt16(m[pointer]) | UInt16(m[pointer + 1]) << 8)
    }

    /// The target of the indirect jump through `$27FF`: every address the table $2718 holds.
    private func runKeyHandler(_ address: UInt16) {
        let H = Input.Handler.self
        switch address {
        case H.keyIgnored: keyIgnored()
        case H.keyAdfSelect: keyAdfSelect()
        case H.keyCtrlB: keyCtrlB()
        case H.keyComSelect: keyComSelect()
        case H.keyCtrlD: keyCtrlD()
        case H.keyDatabaseInfo: keyDatabaseInfo()
        case H.keyFuelTankSelect: keyFuelTankSelect()
        case H.throttleDown: throttleDown()
        case H.keyCarbHeat: keyCarbHeat()
        case H.keyLights: keyLights()
        case H.keyReturn: keyReturn()
        case H.keyNavSelect: keyNavSelect()
        case H.waitForKey: waitForKey()
        case H.keyCtrlT: keyCtrlT()
        case H.throttleUp: throttleUp()
        case H.keyObsSelect: keyObsSelect()
        case H.keyTransponderSelect: keyTransponderSelect()
        case H.keyEditor: keyEditor()
        case H.keySpace: keySpace()
        case H.keyRecallMode: keyRecallMode()
        case H.decrementSelected: decrementSelected()
        case H.incrementSelected: incrementSelected()
        case H.throttleJump: throttleJump()
        case H.key1: key1()
        case H.key2: key2()
        case H.key3: key3()
        case H.keyRadar: keyRadar()
        case H.keyViewSelect: keyViewSelect()
        case H.key8: key8()
        case H.key9: key9()
        case H.keyElevatorUp: keyElevatorUp()
        case H.keyRudderLeft: keyRudderLeft()
        case H.keyAileronLeft: keyAileronLeft()
        case H.keyCenter: keyCenter()
        case H.keyAileronRight: keyAileronRight()
        case H.keyRudderRight: keyRudderRight()
        case H.keyFlapsDown: keyFlapsDown()
        case H.keyCoursePlotter: keyCoursePlotter()
        case H.keyTrimDown: keyTrimDown()
        case H.keySaveMode: keySaveMode()
        case H.keyElevatorDown: keyElevatorDown()
        case H.keyTrimUp: keyTrimUp()
        case H.keyDeclareWar: keyDeclareWar()
        case H.keyDropBomb: keyDropBomb()
        case H.keyFlapsUp: keyFlapsUp()
        case H.keyZeroAttitude: keyZeroAttitude()
        default:
            // The table is never written at run time; any other target means corrupt memory.
            assertionFailure("key dispatch table entry $\(hex(address, width: 4)) is not a handler")
        }
    }

    // MARK: waitForKey ($2250)

    /// $2250 (vector $2003; P, CTRL-P and RUN/STOP through the table; the title prompts, the
    /// course plotter menu and the editor fields): saves `$08BA` and the SOUND setting `$08D3`,
    /// silences the SID (`$08D3` = 0, `soundTick`), pauses (`$08CC` += 1: the 5 Hz work and the
    /// 1 Hz sound/clock tick stop), sets text-input mode (`$08BA` = 1), then polls the 10 Hz
    /// tick ($2330, `pollTick()`) until the dispatcher has stored a key with bit 7 in `$08C4`.
    /// Then `$08C4` &= $7F, restores `$08D3` and `$08BA`, halves `$08CC`, and returns the
    /// code & $7F (no echo). The key that ends a pause is consumed.
    ///
    /// The loop only ends once the 10 Hz tick (run from `pollTick`, $2330) has dispatched a key; the
    /// virtual clock's frame work (the raster-IRQ equivalents, run from `charge`) must keep going.
    @discardableResult
    public func waitForKey() -> UInt8 {
        let m = mem
        let R = Input.RAM.self
        let savedEditorRequest = m[R.editorRequest]
        let savedSound = m[R.soundEnable]
        m[R.soundEnable] = 0
        charge(26)                                          // save both flags on the stack, sound off
        soundTick()
        m[R.pauseCount] &+= 1
        m[R.editorRequest] = 1
        charge(12)                                          // pause, text-input mode
        while true {
            charge(6)
            pollTick()
            if m[R.promptKey] & 0x80 != 0 { break }
            charge(7)                                       // no key yet
        }
        let code = m[R.promptKey] & 0x7F
        m[R.promptKey] = code
        m[R.soundEnable] = savedSound
        m[R.editorRequest] = savedEditorRequest
        m[R.pauseCount] >>= 1
        // Strip the key's flag bit, restore the saved flags and undo the pause.
        charge(46)
        return code
    }
}
