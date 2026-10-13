/// The overlay slots $A7E2/$A7E8/$A7EE/$A7F4/$A7FA, executed from the overlay bytes in memory.
///
/// Every overlay starts with five 6-byte slots. The owning overlay's slot jumps to its entry (the
/// flight overlay's $A7F4 just returns); the others call a loader vector $2015-$2021 (overlay 0
/// calls the trampolines $E5C0-$E5ED directly), which loads the slot's overlay over $A7E0 and
/// returns into the *new* overlay's slot at +3: its jump to the entry, or the flight overlay's
/// return. Running the bytes keeps the original's behavior whichever overlay is resident.
extension Machine {
    /// Runs the overlay slot at `slot` (the caller charges its call, or the jump that reaches
    /// $A7E2). Returns `.coldInit` when the slot jumps to the cold-start entry $A946 (the caller
    /// then runs `coldInit`, which never returns to it).
    @discardableResult
    func runOverlaySlot(_ slot: Int) -> MainLoop.SlotOutcome {
        var pc = slot
        while true {
            let op = mem[pc]
            let target = Int(u16(pc + 1))
            switch op {
            case 0x60:                       // the return opcode (the flight overlay's $A7F4/$A7F7)
                charge(6)
                return .returned
            case 0x20:                                   // the call opcode: load the slot's overlay
                charge(6)
                loadOverlay(through: target)
                pc += 3                                     // the trampoline returns into the new overlay
            case 0x4C:                              // the jump opcode: the resident overlay's entry
                charge(3)
                switch target {
                case 0xA946:
                    return .coldInit
                case 0xB09A:
                    editorOverlayEntry()
                case 0xAA03:
                    warOverlayEntry()
                case Int(DatabaseInfo.entry):
                    databaseInfoScreen()
                default:
                    preconditionFailure(String(format: "overlay slot $%04X: JMP $%04X is no overlay entry", slot, target))
                }
                return .returned
            default:
                preconditionFailure(String(format: "overlay slot $%04X: opcode $%02X at $%04X", slot, op, pc))
            }
        }
    }

    /// A slot's call of an overlay trampoline: through the `$20xx` vector (a 3-cycle jump) or the
    /// trampoline itself, then the overlay manager (`loadOverlay`, which charges through the return
    /// into the slot).
    private func loadOverlay(through target: Int) {
        let overlay: Overlay
        switch target {
        case 0x2015, 0xE5C0: overlay = .coldStart
        case 0x2018, 0xE5C9: overlay = .editor
        case 0x201B, 0xE5DB: overlay = .war
        case 0x201E, 0xE5E4: overlay = .flight
        case 0x2021, 0xE5ED: overlay = .databaseInfo
        default:
            preconditionFailure(String(format: "overlay slot JSR $%04X is no overlay trampoline", target))
        }
        if target < 0xE000 { charge(3) }                    // the vector's jump
        loadOverlay(overlay)
    }

    /// $B09A: the editor overlay's entry (slot $A7E8): `editorEntry` (`Modes/Editor.swift`).
    private func editorOverlayEntry() {
        editorEntry()
    }

    /// $AA03: the war overlay's entry (slot $A7EE, every pass in Europe 1917): `warMain`
    /// (`Modes/War.swift`; the slot's jump is charged here, so not through `slotWar`).
    private func warOverlayEntry() {
        warMain()
    }

    /// The jump to $A7E2 (the war-exit check $2149, the RESTORE restart $2700): the slot reloads
    /// overlay 0 (the flight and war overlays' $A7E2 calls the loader vector $2015; overlay 0's own
    /// jumps to $A946), then the cold init chain runs up to its jump to $2048. The caller continues
    /// with `mainLoopEntry`.
    func coldStartSlot() {
        let outcome = runOverlaySlot(0xA7E2)
        precondition(outcome == .coldInit, "slot $A7E2 did not reach the cold start")
        coldInit()
    }
}
