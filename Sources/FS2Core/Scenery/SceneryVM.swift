/// The scenery display-list interpreter ($8730-$8FE7): the bytecode that draws the world, finds
/// radio stations and streams scenery blocks. See `re/docs/scenery-3d.md` for the opcode
/// reference.
///
/// The interpreter is memory-faithful: the display-list PC is `$8B/$8C`, handlers are dispatched
/// through the 70-word table at $86A4 (read from memory, so `$A5/$A6` hold the handler address
/// as in the original), and every operand, temporary and self-modified code byte is read and
/// written at its original address. The original's 6502-stack recursion (ops 18/09/0A, the
/// runway's nested pass) becomes Swift recursion; the stack page itself is not modeled.
///
/// Cycle convention: every routine charges from its first instruction through its return; the
/// caller charges its call (and a vector's 3-cycle jump).
public enum Scenery {
    /// $8B/$8C: the display-list PC.
    public static let displayListPc = 0x8B
    /// $86A4: 70 handler addresses for opcodes $00-$45.
    public static let opcodeHandlers = 0x86A4
    /// Opcodes from $46 up end the current list (END, normally $79).
    public static let firstEndOpcode: UInt8 = 0x46
    /// $0904: display-list call depth (ops 18/09/0A).
    public static let callDepth = 0x0904
    /// $0916: set by the line driver when point A was clipped (re-project A).
    public static let pointAClipped = 0x0916
    /// $8A: set by the line driver when point B was clipped (re-project B).
    public static let pointBClipped = 0x8A
    /// $23: $FF while a polygon is being collected (op 2F .. op 29).
    public static let polygonOpen = 0x23
    /// $B7: polygon vertex count (index of the next vertex).
    public static let polygonCount = 0xB7
    /// $0920/$0921, $0937/$0938, $08BD/$08BE: NAV, COM and ADF search request / per-pass flag.
    public static let navSearchRequest = 0x0920
    public static let navSearchActive = 0x0921
    public static let comSearchRequest = 0x0937
    public static let comSearchActive = 0x0938
    public static let adfSearchRequest = 0x08BD
    public static let adfSearchActive = 0x08BE

    /// Self-modified code bytes the interpreter reads back.
    /// $8862: the call to the point-B transform, $9FD0 or $A1CE (target operand $8863/$8864).
    public static let pointBTransformOperand = 0x8863
    /// $88A3: the call to the point-A transform, $9FD0 or $A1CE (target operand $88A4/$88A5).
    public static let pointATransformOperand = 0x88A4
    /// $8B89: the opcode byte of the line driver's call to $9A1D (line drawn); the horizon pass
    /// patches it to $0D, which turns the call into a harmless read.
    public static let lineDrawOpcode = 0x8B89
    /// $8BAC: the opcode byte of the jump back to $8752 that ends the line driver; the dashed
    /// line patches it to a return ($60).
    public static let lineDriverExitOpcode = 0x8BAC
    /// $880B: op 0A's call instruction, its target operand $880C/$880D set to the native target.
    public static let nativeCallOperand = 0x880C

    /// Entry points of the transform routines selected by the self-modified operands.
    static let transform3DEntry: UInt16 = 0xA1CE
    static let transformGroundEntry: UInt16 = 0x9FD0

    /// A display list the original cannot run.
    public enum Fault: Error, Equatable, Sendable {
        /// An opcode whose handler is the invalid-opcode routine $8778 (the original calls the
        /// fatal error $7303 with A = $90, the system-error screen).
        case invalidOpcode(UInt8, at: UInt16)
    }

    /// What an opcode handler does when it is done.
    enum Flow {
        /// On to $8749: advance the PC by n and fetch the next opcode.
        case advance(UInt8)
        /// Back to $8752: fetch the next opcode at the PC as it is.
        case loop
        /// Return: leave the current interpreter invocation (op 19, or a jump into an exit patched
        /// to return).
        case ret
    }
}

extension Machine {
    // MARK: Entries ($8006 = $8730, $8742, $8749, $8752)

    /// $8730 (vector $8006): runs the scenery display list at `$8B/$8C` (set from `[$A7E0]` by
    /// `setSceneryRoot`). First copies the radio search requests to their per-pass flags
    /// (`$0920` → `$0921`, `$0937` → `$0938`, `$08BD` → `$08BE`), then interprets until the list
    /// returns (END or op 19). Charges from $8730 through the final return.
    public func runScenery() throws(Scenery.Fault) {
        let m = mem
        m[Scenery.navSearchActive] = m[Scenery.navSearchRequest]
        m[Scenery.comSearchActive] = m[Scenery.comSearchRequest]
        m[Scenery.adfSearchActive] = m[Scenery.adfSearchRequest]
        charge(6 * 4)
        try dlInterpreter()
    }

    /// $8742: clears `$0916` and `$8A` (the line driver's clip flags), then runs the list at the
    /// PC (`dlAdvance` by A = 0 falls into `dlLoop`). The horizon pass enters here.
    public func dlInterpreter() throws(Scenery.Fault) {
        dlResetClipFlags()
        dlAdvance(0)
        try dlLoop()
    }

    /// $8742's body: both clip flags cleared (9 cycles).
    @inline(__always)
    func dlResetClipFlags() {
        mem[Scenery.pointAClipped] = 0
        mem[Scenery.pointBClipped] = 0
        charge(9)
    }

    /// $8749: PC += n (an 8-bit add into the low byte, the high byte bumped on a carry), 11 or 15
    /// cycles; the caller then continues at `dlLoop`.
    @inline(__always)
    public func dlAdvance(_ n: UInt8) {
        let m = mem
        let sum = Int(m[0x8B]) + Int(n)
        m[0x8B] = UInt8(truncatingIfNeeded: sum)
        if sum > 0xFF {
            m[0x8C] &+= 1
            charge(15)
        } else {
            charge(11)
        }
    }

    /// $8851: PC += A, the same add as $8749 but as a subroutine, 17 or 21 cycles with the
    /// return. Used by the handlers and by the point transforms (steps of 7 and 5).
    public func dlStep(_ n: UInt8) {
        let m = mem
        let sum = Int(m[0x8B]) + Int(n)
        m[0x8B] = UInt8(truncatingIfNeeded: sum)
        if sum > 0xFF {
            m[0x8C] &+= 1
            charge(21)
        } else {
            charge(17)
        }
    }

    /// $8752: the interpreter loop. Per opcode: the 10 Hz poll at $2012 (`pollTick`), fetch
    /// the opcode at the PC (with Y = 0); $46 and above end the list: the per-pass search flags
    /// `$0938`, `$0921` and `$08BE` are cleared and the loop returns. Otherwise the handler
    /// address `$86A4[2·op]` goes to `$A5/$A6` and the handler runs (entered with Y = 0).
    /// Returns when a handler returns (op 19 or END).
    public func dlLoop() throws(Scenery.Fault) {
        let m = mem
        while true {
            charge(9)                                   // the poll call, vectored to $2330
            pollTick()
            let pc = zpPointer(0x8B)
            let op = m[pc]
            if op >= Scenery.firstEndOpcode {
                m[Scenery.comSearchActive] = 0
                m[Scenery.navSearchActive] = 0
                m[Scenery.adfSearchActive] = 0
                // The fetch, the END test, the three flags cleared and the return.
                charge(32)
                return
            }
            let x = Int(op) << 1
            let lo = m[Scenery.opcodeHandlers + x], hi = m[Scenery.opcodeHandlers + x + 1]
            m[0xA5] = lo
            m[0xA6] = hi
            // The fetch, the END test, the table lookup into $A5/$A6 (both reads cross a page
            // from entry $2E on) and the indirect jump.
            let cross = x >= 0x5C ? 2 : 0
            charge(34 + cross)
            let handler = UInt16(hi) << 8 | UInt16(lo)
            switch try dlDispatch(handler, opcode: op, at: pc) {
            case .advance(let n): dlAdvance(n)
            case .loop: break
            case .ret: return
            }
        }
    }

    /// Runs the handler at `handler` (the original's indirect jump through `$A5/$A6`).
    private func dlDispatch(_ handler: UInt16, opcode: UInt8, at pc: Int) throws(Scenery.Fault) -> Scenery.Flow {
        switch handler {
        case 0x8A25: return opPoint3D()                     // 00
        case 0x88E5: return opMove3D()                      // 01
        case 0x88FC: return opLine3D()                      // 02
        case 0xA5C8: return try opRunway()                  // 03
        case 0x8E0C: return opCull()                        // 04
        case 0x802A: return opNdbRecord()                   // 05 (hook patched to $E956)
        case 0x8BAF: return opScreenLine()                  // 06
        case 0x8BFD: return opOrigin()                      // 07
        case 0x87AB: return try opCallIndirect()            // 09
        case 0x87E1: return try opCallNative()              // 0A
        case 0x8DA5: return opJump()                        // 0B
        case 0x80E2: return opLoadBlocks()                  // 0D
        case 0x8823: return opNop()                         // 11
        case 0x9BE6: return .advance(opPen())               // 12
        case 0x8E4A: return opRangeJump()                   // 13
        case 0x8E50: return opRangeAltitudeJump()           // 14
        case 0x877E: return try opCall()                    // 18
        case 0x881A: charge(6); return .ret                 // 19: return
        case 0x8DC3: return opCopyWord()                    // 1A
        case 0x9B91: return .advance(opPen3())              // 1B
        case 0x9B9B: return .advance(opDottedPen())         // 1C
        case 0x8030: return opNavRecord()                   // 1D
        case 0x8084: return opAtisRecord()                  // 1E
        case 0x8EDB: return opBoxJump(1)                    // 20
        case 0x8EE6: return opBoxJump(2)                    // 21
        case 0x8EF4: return opBoxJump(3)                    // 22
        case 0x8F4E: return opBitTestJump()                 // 23
        case 0x8BC1: return opOriginHigh()                  // 24
        case 0x8DEB: return opStoreWord()                   // 25
        case 0x8F7A: return opCompareJump()                 // 28
        case 0x8828: return opEndPolygon()                  // 29
        case 0x8A43: return opDashedLine()                  // 2B
        case 0x881B: return opBeginPolygon()                // 2F
        case 0x89A4: return opCachePoint3D()                // 31
        case 0x8917: return opCacheMove()                   // 32
        case 0x8946: return opCacheLine()                   // 33
        case 0x8A04: return opCacheDot()                    // 35
        case 0x88EC: return opMoveGround()                  // 40
        case 0x8903: return opLineGround()                  // 41
        case 0x89AB: return opCachePointGround()            // 42
        case 0xA731: return opJumpAbsolute()                // (no table entry)
        case 0x8778:
            // dlInvalidOpcode: the fatal error $7303 with code $90. The port reports the fault
            // instead of the system-error screen.
            charge(8)
            throw .invalidOpcode(opcode, at: UInt16(pc))
        default:
            preconditionFailure(String(format: "display-list handler $%04X (opcode $%02X) is not a known entry",
                                       handler, opcode))
        }
    }

    // MARK: Operand access

    /// The display-list byte at PC + y (an indexed read through the PC pointer).
    @inline(__always)
    func dlByte(_ pc: Int, _ y: Int) -> UInt8 { mem[(pc + y) & 0xFFFF] }

    /// The page-crossing cycle of that indexed read with Y = y.
    @inline(__always)
    static func dlCross(_ pc: Int, _ y: Int) -> Int { (pc & 0xFF) + y > 0xFF ? 1 : 0 }

    /// $8DB3: `$A5/$A6` = PC + the rel16 at PC + y + 1 (Y advances by 2). Returns the cycles with
    /// the return (34 + page crossings); the caller charges the call.
    @inline(__always)
    func dlRelativeTarget(_ pc: Int, y: Int) -> Int {
        let m = mem
        let target = (pc + Int(UInt16(dlByte(pc, y + 1)) | UInt16(dlByte(pc, y + 2)) << 8)) & 0xFFFF
        m[0xA5] = UInt8(target & 0xFF)
        m[0xA6] = UInt8(target >> 8)
        return 34 + Self.dlCross(pc, y + 1) + Self.dlCross(pc, y + 2)
    }

    /// $8DA8 / $8F43: PC = `$A5/$A6`, back to $8752 (15 cycles).
    @inline(__always)
    func dlTakeJump() -> Scenery.Flow {
        mem[0x8B] = mem[0xA5]
        mem[0x8C] = mem[0xA6]
        charge(15)
        return .loop
    }

    // MARK: Control flow (ops 0B, 11, 18, 09, 0A; $A731)

    /// $8823 (op 11, also the tail of op 2F): advance by 1 through $8749.
    func opNop() -> Scenery.Flow {
        charge(5)
        return .advance(1)
    }

    /// $8DA5 (op 0B rel16): PC += rel16 (relative to the opcode).
    func opJump() -> Scenery.Flow {
        let pc = zpPointer(0x8B)
        charge(6 + dlRelativeTarget(pc, y: 0))
        return dlTakeJump()
    }

    /// $A731 (no opcode table entry; a handler-style continuation that loads an absolute PC):
    /// PC = the abs16 at PC + y + 1..2 (y = the Y it is entered with: 0 as a handler, 1 as an op 0A
    /// target), then on to $8DA8 (PC = `$A5/$A6`, back to $8752).
    func opJumpAbsolute(y: Int = 0) -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        m[0xA5] = dlByte(pc, y + 1)
        m[0xA6] = dlByte(pc, y + 2)
        charge(7 + Self.dlCross(pc, y + 1) + 10 + Self.dlCross(pc, y + 2) + 6)   // up to $8DA8
        return dlTakeJump()
    }

    /// The call prologue of ops 18/09/0A: pushes PC + 3 (kept here as the return PC) and
    /// increments `$0904`. 28 cycles.
    @inline(__always)
    private func dlCallPrologue(_ pc: Int) -> Int {
        mem[Scenery.callDepth] &+= 1
        charge(24)              // push PC + 3, count the depth up
        return (pc + 3) & 0xFFFF
    }

    /// The call epilogue: `$0904` counts down, PC = the pushed PC + 3, back to $8752 (23 cycles).
    @inline(__always)
    private func dlCallEpilogue(_ returnPc: Int) -> Scenery.Flow {
        mem[Scenery.callDepth] &-= 1
        mem[0x8B] = UInt8(returnPc & 0xFF)
        mem[0x8C] = UInt8(returnPc >> 8)
        charge(23)
        return .loop
    }

    /// $877E (op 18 rel16): calls the display list at PC + rel16 (a nested run of $8752), then
    /// continues after the op.
    func opCall() throws(Scenery.Fault) -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        let ret = dlCallPrologue(pc)
        let target = (pc + Int(UInt16(dlByte(pc, 1)) | UInt16(dlByte(pc, 2)) << 8)) & 0xFFFF
        m[0x8C] = UInt8(target >> 8)
        m[0x8B] = UInt8(target & 0xFF)
        // The target into the PC, then the nested loop.
        charge(7 + Self.dlCross(pc, 1) + 14 + Self.dlCross(pc, 2) + 15)
        try dlLoop()
        return dlCallEpilogue(ret)
    }

    /// $87AB (op 09 abs16): calls the display list whose address is the word at abs16, unless
    /// that word is 0 (op 09 on `$0890` draws the horizon line list).
    func opCallIndirect() throws(Scenery.Fault) -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        let ret = dlCallPrologue(pc)
        let pointerLo = dlByte(pc, 1), pointerHi = dlByte(pc, 2)
        m[0xA5] = pointerLo
        m[0xA6] = pointerHi
        let pointer = Int(pointerHi) << 8 | Int(pointerLo)
        let lo = m[pointer]
        m[0x8B] = lo
        let hi = m[(pointer + 1) & 0xFFFF]
        m[0x8C] = hi
        // The pointer into $A5/$A6, the word it points to into the PC (its second byte read
        // crosses a page when the pointer ends in $FF), and the zero test.
        var c = 7 + Self.dlCross(pc, 1) + 10 + Self.dlCross(pc, 2) + 3
        c += 17 + (pointerLo == 0xFF ? 1 : 0) + 6
        if lo | hi == 0 {
            charge(c + 3)
        } else {
            charge(c + 8)
            try dlLoop()
        }
        return dlCallEpilogue(ret)
    }

    /// $87E1 (op 0A abs16): calls native code at the address stored in the word at abs16
    /// (a call whose target operand $880C/$880D is patched), unless that word is 0. The target
    /// is entered with A = high | low byte of the address, X = $14, Y = 1.
    func opCallNative() throws(Scenery.Fault) -> Scenery.Flow {
        let m = mem
        let pc = zpPointer(0x8B)
        let ret = dlCallPrologue(pc)
        let pointerLo = dlByte(pc, 1), pointerHi = dlByte(pc, 2)
        m[0xA5] = pointerLo
        m[0xA6] = pointerHi
        let pointer = Int(pointerHi) << 8 | Int(pointerLo)
        let lo = m[pointer]
        m[Scenery.nativeCallOperand] = lo
        let hi = m[(pointer + 1) & 0xFFFF]
        m[Scenery.nativeCallOperand + 1] = hi
        // As op 09, but the word goes into the call's operand, and the zero test reads it back.
        var c = 7 + Self.dlCross(pc, 1) + 10 + Self.dlCross(pc, 2) + 3
        c += 18 + (pointerLo == 0xFF ? 1 : 0) + 8
        if lo | hi == 0 {
            charge(c + 3)
        } else {
            charge(c + 8)
            try nativeCall(UInt16(hi) << 8 | UInt16(lo), a: lo | hi, x: 0x14, y: 1)
        }
        return dlCallEpilogue(ret)
    }

    /// The native-call ABI of op 0A: the address goes to its Swift port (charging what the
    /// original target charges from its first instruction through its return, plus 3 for a
    /// `$80xx` vector's jump): every vector of the table $8000-$8027 and its target, the
    /// interpreter entries, $A731 and $80D1. No display list on the disk calls anything else (none
    /// uses op 0A at all), so any other target stops the program with its address.
    func nativeCall(_ target: UInt16, a: UInt8, x: UInt8, y: UInt8) throws(Scenery.Fault) {
        // A vector of the table at $8000 is a jump (3 cycles) to its target.
        let vectors: [UInt16: UInt16] = [
            0x8000: 0x8111, 0x8003: 0x83A4, 0x8006: 0x8730, 0x8009: 0x9A1D, 0x800C: 0x99FD,
            0x800F: 0x9BF5, 0x8012: 0xA532, 0x8015: 0xA558, 0x8018: 0x8749, 0x801B: 0x9996,
            0x801E: 0x9C93, 0x8021: 0xA378, 0x8024: 0x9C9C, 0x8027: 0xA558,
        ]
        var entry = target
        if let jump = vectors[target], u16(Int(target) + 1) == jump, mem[Int(target)] == 0x4C {
            charge(3)
            entry = jump
        }
        switch entry {
        case 0x8111: buildViewMatrix()
        case 0x83A4: try horizonPass()
        case 0x8730: try runScenery()
        case 0x8742: try dlInterpreter()
        case 0x8749: dlAdvance(a); try dlLoop()
        case 0x8752: try dlLoop()
        case 0xA731: _ = opJumpAbsolute(y: Int(y)); try dlLoop()
        case 0x9A1D: drawLine()
        case 0x99FD: plot(x: x, row: y)
        case 0x9BF5: setPen(a)
        case 0xA532: drawTurnCoordinator()
        case 0xA558: turnCoordinatorHelper(a)
        case 0x9996: span(a)
        case 0x9C93: setSpanColorFromPalette()
        case 0xA378: drawAttitudeIndicator()
        case 0x9C9C: setSpanColor(x)
        case 0x80D1: copyOperandBytes(y: y)
        default:
            // `entry` is the original target, or a vector's when its jump was charged. The disk's
            // data never gets here; shipping code has no way to run unported 6502 code. `fatalError`
            // (not `preconditionFailure`, whose message an optimized build drops) names the address
            // in every build.
            fatalError(String(format: "op 0A: native call to $%04X (target $%04X), which has no port",
                              entry, target))
        }
    }

    /// $80D1 (no caller in the resident code; a native-call target): copies the four display-list
    /// bytes at PC + Y + 1 .. Y + 4 to `$A5-$A8` (`$39` counts them down to 0). Returns Y + 4.
    @discardableResult
    public func copyOperandBytes(y: UInt8) -> UInt8 {
        let m = mem
        let pc = zpPointer(0x8B)
        var yy = Int(y)
        var c = 7                                   // the count of 4 and the destination
        for k in 0..<4 {
            yy = (yy + 1) & 0xFF
            m[0xA5 + k] = dlByte(pc, yy)
            c += 7 + Self.dlCross(pc, yy) + 11 + (k == 3 ? 2 : 3)   // one byte copied and counted
        }
        m[0x39] = 0
        charge(c + 6)
        return UInt8(yy)
    }
}
