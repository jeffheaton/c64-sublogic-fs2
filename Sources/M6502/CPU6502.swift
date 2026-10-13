/// Memory as seen by the CPU.
public protocol MemoryBus: AnyObject {
    func read(_ address: UInt16) -> UInt8
    func write(_ address: UInt16, _ value: UInt8)
}

/// A cycle-counted NMOS 6502 (documented opcodes, NMOS decimal mode). Undocumented opcodes stop
/// execution and report through `illegalOpcode`. `traps` lets a host intercept execution at given
/// addresses (the lab uses it to serve SubLogic's disk API without emulating a 1541).
public final class CPU6502<Bus: MemoryBus> {
    public var a: UInt8 = 0
    public var x: UInt8 = 0
    public var y: UInt8 = 0
    public var sp: UInt8 = 0xFD
    public var pc: UInt16 = 0

    // Status flags, kept unpacked.
    public var carry = false
    public var zero = false
    public var interruptDisable = true
    public var decimal = false
    public var overflow = false
    public var negative = false

    /// Total cycles executed (including interrupt entry).
    public var cycles: UInt64 = 0
    /// Level-triggered IRQ input (taken when the I flag is clear).
    public var irqLine = false
    /// Set by the host to request an NMI (edge; cleared when taken).
    public var nmiPending = false
    /// Set when an undocumented opcode is fetched; execution stops at it.
    public var illegalOpcode: (pc: UInt16, opcode: UInt8)?

    /// Addresses at which `trapHandler` is called before the instruction there executes.
    public var traps = [Bool](repeating: false, count: 0x10000)
    /// Return true if the handler changed PC or otherwise handled the instruction (the CPU then
    /// re-checks traps at the new PC on the next step); false to execute the instruction normally.
    public var trapHandler: ((UInt16) -> Bool)?

    public let bus: Bus

    public init(bus: Bus) {
        self.bus = bus
    }

    public var status: UInt8 {
        get {
            (negative ? 0x80 : 0) | (overflow ? 0x40 : 0) | 0x20 | (decimal ? 0x08 : 0)
                | (interruptDisable ? 0x04 : 0) | (zero ? 0x02 : 0) | (carry ? 0x01 : 0)
        }
        set {
            negative = newValue & 0x80 != 0; overflow = newValue & 0x40 != 0
            decimal = newValue & 0x08 != 0; interruptDisable = newValue & 0x04 != 0
            zero = newValue & 0x02 != 0; carry = newValue & 0x01 != 0
        }
    }

    public func reset() {
        sp = 0xFD
        interruptDisable = true
        pc = read16(0xFFFC)
        cycles += 7
    }

    // MARK: - Memory helpers

    @inline(__always) func read(_ a: UInt16) -> UInt8 { bus.read(a) }
    @inline(__always) func write(_ a: UInt16, _ v: UInt8) { bus.write(a, v) }
    @inline(__always) func read16(_ a: UInt16) -> UInt16 { UInt16(read(a)) | UInt16(read(a &+ 1)) << 8 }
    /// 16-bit read with the page wrap of JMP ($xxFF) and zero-page pointers.
    @inline(__always) func read16Wrapped(_ a: UInt16) -> UInt16 {
        UInt16(read(a)) | UInt16(read((a & 0xFF00) | UInt16(UInt8(a & 0xFF) &+ 1))) << 8
    }
    @inline(__always) func fetch() -> UInt8 { let v = read(pc); pc &+= 1; return v }
    @inline(__always) func fetch16() -> UInt16 { let v = read16(pc); pc &+= 2; return v }
    @inline(__always) func push(_ v: UInt8) { write(0x0100 | UInt16(sp), v); sp &-= 1 }
    @inline(__always) func pull() -> UInt8 { sp &+= 1; return read(0x0100 | UInt16(sp)) }
    @inline(__always) func setNZ(_ v: UInt8) { zero = v == 0; negative = v & 0x80 != 0 }

    // MARK: - Interrupts

    func interrupt(vector: UInt16, brk: Bool) {
        push(UInt8(pc >> 8)); push(UInt8(pc & 0xFF))
        push(status & ~0x10 | (brk ? 0x10 : 0))
        interruptDisable = true
        pc = read16(vector)
        cycles += 7
    }

    // MARK: - Execution

    /// Executes one instruction (or takes a pending interrupt). Returns the cycles used, or 0 when
    /// stopped on an illegal opcode.
    @discardableResult
    public func step() -> Int {
        let start = cycles
        if nmiPending {
            nmiPending = false
            interrupt(vector: 0xFFFA, brk: false)
            return Int(cycles - start)
        }
        if irqLine && !interruptDisable {
            interrupt(vector: 0xFFFE, brk: false)
            return Int(cycles - start)
        }
        if traps[Int(pc)], let handler = trapHandler, handler(pc) {
            return Int(cycles - start)
        }
        let opPC = pc
        let op = fetch()
        let info = Opcodes.table[Int(op)]
        guard info.documented else {
            pc = opPC
            illegalOpcode = (opPC, op)
            return 0
        }
        cycles += UInt64(info.cycles)
        execute(op, info)
        return Int(cycles - start)
    }

    /// Effective address for memory-operand modes; adds the page-cross cycle when the opcode has one.
    @inline(__always) func address(_ mode: AddressingMode, penalty: Bool) -> UInt16 {
        switch mode {
        case .zeroPage: return UInt16(fetch())
        case .zeroPageX: return UInt16(fetch() &+ x)
        case .zeroPageY: return UInt16(fetch() &+ y)
        case .absolute: return fetch16()
        case .absoluteX:
            let base = fetch16(), ea = base &+ UInt16(x)
            if penalty && (base ^ ea) & 0xFF00 != 0 { cycles += 1 }
            return ea
        case .absoluteY:
            let base = fetch16(), ea = base &+ UInt16(y)
            if penalty && (base ^ ea) & 0xFF00 != 0 { cycles += 1 }
            return ea
        case .indexedIndirect:
            let zp = fetch() &+ x
            return read16Wrapped(UInt16(zp))
        case .indirectIndexed:
            let base = read16Wrapped(UInt16(fetch())), ea = base &+ UInt16(y)
            if penalty && (base ^ ea) & 0xFF00 != 0 { cycles += 1 }
            return ea
        case .indirect: return read16Wrapped(fetch16())
        case .immediate: let a = pc; pc &+= 1; return a
        default: return 0
        }
    }

    @inline(__always) func operand(_ info: OpcodeInfo) -> UInt8 {
        read(address(info.mode, penalty: info.pageCrossPenalty))
    }

    @inline(__always) func branch(_ taken: Bool) {
        let off = Int8(bitPattern: fetch())
        guard taken else { return }
        let target = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(off))
        cycles += (target ^ pc) & 0xFF00 != 0 ? 2 : 1
        pc = target
    }

    @inline(__always) func compare(_ r: UInt8, _ m: UInt8) {
        carry = r >= m
        setNZ(r &- m)
    }

    func adc(_ m: UInt8) {
        let c: UInt16 = carry ? 1 : 0
        if decimal {
            // NMOS: Z from the binary result, N and V from the intermediate result.
            let bin = UInt16(a) + UInt16(m) + c
            zero = bin & 0xFF == 0
            var lo = UInt16(a & 0x0F) + UInt16(m & 0x0F) + c
            var hi = UInt16(a >> 4) + UInt16(m >> 4)
            if lo > 9 { lo += 6; hi += 1 }
            negative = hi & 0x08 != 0
            overflow = ~(UInt16(a) ^ UInt16(m)) & (UInt16(a) ^ (hi << 4)) & 0x80 != 0
            if hi > 9 { hi += 6 }
            carry = hi > 15
            a = UInt8(((hi << 4) | (lo & 0x0F)) & 0xFF)
        } else {
            let sum = UInt16(a) + UInt16(m) + c
            overflow = ~(UInt16(a) ^ UInt16(m)) & (UInt16(a) ^ sum) & 0x80 != 0
            carry = sum > 0xFF
            a = UInt8(sum & 0xFF)
            setNZ(a)
        }
    }

    func sbc(_ m: UInt8) {
        let borrow: Int = carry ? 0 : 1
        let diff = Int(a) - Int(m) - borrow
        overflow = (Int(a) ^ Int(m)) & (Int(a) ^ diff) & 0x80 != 0
        if decimal {
            var lo = Int(a & 0x0F) - Int(m & 0x0F) - borrow
            var hi = Int(a >> 4) - Int(m >> 4)
            if lo < 0 { lo -= 6; hi -= 1 }
            if hi < 0 { hi -= 6 }
            carry = diff >= 0
            setNZ(UInt8(diff & 0xFF))
            a = UInt8(((hi << 4) | (lo & 0x0F)) & 0xFF)
        } else {
            carry = diff >= 0
            a = UInt8(diff & 0xFF)
            setNZ(a)
        }
    }

    /// Read-modify-write on memory or the accumulator.
    @inline(__always) func rmw(_ info: OpcodeInfo, _ f: (UInt8) -> UInt8) {
        if info.mode == .accumulator {
            a = f(a)
            setNZ(a)
        } else {
            let ea = address(info.mode, penalty: false)
            let v = f(read(ea))
            write(ea, v)
            setNZ(v)
        }
    }

    func execute(_ op: UInt8, _ info: OpcodeInfo) {
        switch instructionKinds[Int(op)] {
        case .lda: a = operand(info); setNZ(a)
        case .ldx: x = operand(info); setNZ(x)
        case .ldy: y = operand(info); setNZ(y)
        case .sta: write(address(info.mode, penalty: false), a)
        case .stx: write(address(info.mode, penalty: false), x)
        case .sty: write(address(info.mode, penalty: false), y)
        case .adc: adc(operand(info))
        case .sbc: sbc(operand(info))
        case .and: a &= operand(info); setNZ(a)
        case .ora: a |= operand(info); setNZ(a)
        case .eor: a ^= operand(info); setNZ(a)
        case .cmp: compare(a, operand(info))
        case .cpx: compare(x, operand(info))
        case .cpy: compare(y, operand(info))
        case .bit:
            let m = operand(info)
            zero = a & m == 0; negative = m & 0x80 != 0; overflow = m & 0x40 != 0
        case .asl: rmw(info) { v in carry = v & 0x80 != 0; return v << 1 }
        case .lsr: rmw(info) { v in carry = v & 1 != 0; return v >> 1 }
        case .rol: rmw(info) { v in let c: UInt8 = carry ? 1 : 0; carry = v & 0x80 != 0; return v << 1 | c }
        case .ror: rmw(info) { v in let c: UInt8 = carry ? 0x80 : 0; carry = v & 1 != 0; return v >> 1 | c }
        case .inc: rmw(info) { $0 &+ 1 }
        case .dec: rmw(info) { $0 &- 1 }
        case .inx: x &+= 1; setNZ(x)
        case .iny: y &+= 1; setNZ(y)
        case .dex: x &-= 1; setNZ(x)
        case .dey: y &-= 1; setNZ(y)
        case .tax: x = a; setNZ(x)
        case .tay: y = a; setNZ(y)
        case .txa: a = x; setNZ(a)
        case .tya: a = y; setNZ(a)
        case .tsx: x = sp; setNZ(x)
        case .txs: sp = x
        case .pha: push(a)
        case .php: push(status | 0x10)
        case .pla: a = pull(); setNZ(a)
        case .plp: status = pull()
        case .clc: carry = false
        case .sec: carry = true
        case .cli: interruptDisable = false
        case .sei: interruptDisable = true
        case .cld: decimal = false
        case .sed: decimal = true
        case .clv: overflow = false
        case .bpl: branch(!negative)
        case .bmi: branch(negative)
        case .bvc: branch(!overflow)
        case .bvs: branch(overflow)
        case .bcc: branch(!carry)
        case .bcs: branch(carry)
        case .bne: branch(!zero)
        case .beq: branch(zero)
        case .jmp: pc = address(info.mode, penalty: false)
        case .jsr:
            let target = fetch16()
            let ret = pc &- 1
            push(UInt8(ret >> 8)); push(UInt8(ret & 0xFF))
            pc = target
        case .rts:
            let lo = UInt16(pull()), hi = UInt16(pull())
            pc = (hi << 8 | lo) &+ 1
        case .rti:
            status = pull()
            let lo = UInt16(pull()), hi = UInt16(pull())
            pc = hi << 8 | lo
        case .brk:
            pc &+= 1
            cycles -= 7
            interrupt(vector: 0xFFFE, brk: true)
        case .nop: break
        case .illegal:
            preconditionFailure("unhandled opcode \(op)")
        }
    }
}

/// Instruction kind per opcode, so execution dispatches on an enum rather than a string.
enum InstructionKind: UInt8 {
    case lda, ldx, ldy, sta, stx, sty, adc, sbc, and, ora, eor, cmp, cpx, cpy, bit, asl, lsr, rol, ror, inc, dec, inx, iny, dex, dey, tax, tay, txa, tya, tsx, txs, pha, php, pla, plp, clc, sec, cli, sei, cld, sed, clv, bpl, bmi, bvc, bvs, bcc, bcs, bne, beq, jmp, jsr, rts, rti, brk, nop, illegal
}

let instructionKinds: [InstructionKind] = Opcodes.table.map { info in
    info.documented ? InstructionKind(rawValue: UInt8(instructionNames.firstIndex(of: info.mnemonic)!))! : .illegal
}

private let instructionNames = ["LDA", "LDX", "LDY", "STA", "STX", "STY", "ADC", "SBC", "AND", "ORA", "EOR", "CMP", "CPX", "CPY", "BIT", "ASL", "LSR", "ROL", "ROR", "INC", "DEC", "INX", "INY", "DEX", "DEY", "TAX", "TAY", "TXA", "TYA", "TSX", "TXS", "PHA", "PHP", "PLA", "PLP", "CLC", "SEC", "CLI", "SEI", "CLD", "SED", "CLV", "BPL", "BMI", "BVC", "BVS", "BCC", "BCS", "BNE", "BEQ", "JMP", "JSR", "RTS", "RTI", "BRK", "NOP"]
