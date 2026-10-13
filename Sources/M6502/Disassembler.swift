/// One decoded instruction: what the listing needs besides the text.
public struct DecodedInstruction: Sendable, Equatable {
    public let address: UInt16
    public let opcode: UInt8
    public let info: OpcodeInfo
    /// Raw operand (0 for implied/accumulator; the signed offset byte for branches).
    public let operand: UInt16
    /// Effective address named by the operand: memory operand, jump/branch target or pointer.
    /// Nil for implied, accumulator and immediate modes, and for undocumented opcodes.
    public let target: UInt16?
    /// Instruction length in bytes (1 for undocumented opcodes, which render as `.byte`).
    public var length: Int { info.documented ? info.length : 1 }
    /// True for JSR, absolute JMP and branches: the target is code. `jmp ($xxxx)` is not: its
    /// target is the pointer, and the code it reaches is only known at run time.
    public var isControlTransfer: Bool {
        info.mode == .relative || info.mnemonic == "JSR" || (info.mnemonic == "JMP" && info.mode == .absolute)
    }
    /// True when execution never falls through to the next instruction (JMP, RTS, RTI, BRK).
    public var endsFlow: Bool { ["JMP", "RTS", "RTI", "BRK"].contains(info.mnemonic) }

    public static func == (a: DecodedInstruction, b: DecodedInstruction) -> Bool {
        a.address == b.address && a.opcode == b.opcode && a.operand == b.operand
    }
}

/// ca65-flavored 6502 disassembler over `Opcodes.table`: lowercase mnemonics, `$hex` operands,
/// `a:` on absolute operands below $0100 (named or not), branch targets as labels or `$addr`, and
/// `.byte $xx` for undocumented opcodes.
public struct Disassembler: Sendable {
    public init() {}

    /// Decodes the instruction at `pc` without formatting it.
    public func decode(at pc: UInt16, read: (UInt16) -> UInt8) -> DecodedInstruction {
        let op = read(pc)
        let info = Opcodes.table[Int(op)]
        guard info.documented else {
            return DecodedInstruction(address: pc, opcode: op, info: info, operand: 0, target: nil)
        }
        let lo = UInt16(read(pc &+ 1)), hi = UInt16(read(pc &+ 2))
        let operand: UInt16
        switch info.length {
        case 2: operand = lo
        case 3: operand = lo | hi << 8
        default: operand = 0
        }
        let target: UInt16?
        switch info.mode {
        case .implied, .accumulator, .immediate: target = nil
        case .relative: target = pc &+ 2 &+ UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(operand))))
        default: target = operand
        }
        return DecodedInstruction(address: pc, opcode: op, info: info, operand: operand, target: target)
    }

    /// Formats the instruction at `pc`. `labels` names an address (any string ca65 accepts as an
    /// expression, e.g. `drawLine` or `airspeed+1`); unnamed addresses print as hex.
    public func line(at pc: UInt16, read: (UInt16) -> UInt8, labels: (UInt16) -> String?) -> (text: String, length: Int) {
        let d = decode(at: pc, read: read)
        return (format(d, labels: labels), d.length)
    }

    /// Formats a decoded instruction.
    public func format(_ d: DecodedInstruction, labels: (UInt16) -> String?) -> String {
        guard d.info.documented else { return ".byte $" + Self.hex2(d.opcode) }
        let m = d.info.mnemonic.lowercased()
        func zp(_ v: UInt16) -> String { labels(v) ?? "$" + Self.hex2(UInt8(v)) }
        // A named absolute operand below $0100 keeps `a:` too; otherwise it reads (and assembles) as zero page.
        func abs(_ v: UInt16) -> String { (v < 0x100 ? "a:" : "") + (labels(v) ?? "$" + Self.hex4(v)) }
        switch d.info.mode {
        case .implied: return m
        case .accumulator: return m + " a"
        case .immediate: return m + " #$" + Self.hex2(UInt8(d.operand))
        case .zeroPage: return m + " " + zp(d.operand)
        case .zeroPageX: return m + " " + zp(d.operand) + ",x"
        case .zeroPageY: return m + " " + zp(d.operand) + ",y"
        case .indexedIndirect: return m + " (" + zp(d.operand) + ",x)"
        case .indirectIndexed: return m + " (" + zp(d.operand) + "),y"
        case .relative: return m + " " + (labels(d.target!) ?? "$" + Self.hex4(d.target!))
        case .absolute: return m + " " + abs(d.operand)
        case .absoluteX: return m + " " + abs(d.operand) + ",x"
        case .absoluteY: return m + " " + abs(d.operand) + ",y"
        case .indirect: return m + " (" + (labels(d.operand) ?? "$" + Self.hex4(d.operand)) + ")"
        }
    }

    static let digits = Array("0123456789ABCDEF")
    public static func hex2(_ v: UInt8) -> String { String([digits[Int(v >> 4)], digits[Int(v & 15)]]) }
    public static func hex4(_ v: UInt16) -> String { hex2(UInt8(v >> 8)) + hex2(UInt8(v & 0xFF)) }
}
