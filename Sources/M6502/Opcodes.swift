/// 6502 addressing modes.
public enum AddressingMode: Sendable {
    case implied, accumulator, immediate, zeroPage, zeroPageX, zeroPageY
    case indexedIndirect, indirectIndexed, relative, absolute, absoluteX, absoluteY, indirect

    /// Instruction length in bytes, including the opcode.
    public var length: Int {
        switch self {
        case .implied, .accumulator: return 1
        case .absolute, .absoluteX, .absoluteY, .indirect: return 3
        default: return 2
        }
    }
}

/// Static description of one opcode (documented NMOS 6502 set; the rest are marked illegal).
public struct OpcodeInfo: Sendable {
    public let mnemonic: String
    public let mode: AddressingMode
    /// Base cycle count (branches add 1 if taken, 1 more if the target is on another page).
    public let cycles: Int
    /// True when a page crossing on the indexed read adds a cycle.
    public let pageCrossPenalty: Bool
    public let documented: Bool

    public var length: Int { mode.length }
}

public enum Opcodes {
    public static let table: [OpcodeInfo] = [
        OpcodeInfo(mnemonic: "BRK", mode: .implied, cycles: 7, pageCrossPenalty: false, documented: true), // $00
        OpcodeInfo(mnemonic: "ORA", mode: .indexedIndirect, cycles: 6, pageCrossPenalty: false, documented: true), // $01
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $02
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $03
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $04
        OpcodeInfo(mnemonic: "ORA", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $05
        OpcodeInfo(mnemonic: "ASL", mode: .zeroPage, cycles: 5, pageCrossPenalty: false, documented: true), // $06
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $07
        OpcodeInfo(mnemonic: "PHP", mode: .implied, cycles: 3, pageCrossPenalty: false, documented: true), // $08
        OpcodeInfo(mnemonic: "ORA", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $09
        OpcodeInfo(mnemonic: "ASL", mode: .accumulator, cycles: 2, pageCrossPenalty: false, documented: true), // $0A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $0B
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $0C
        OpcodeInfo(mnemonic: "ORA", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $0D
        OpcodeInfo(mnemonic: "ASL", mode: .absolute, cycles: 6, pageCrossPenalty: false, documented: true), // $0E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $0F
        OpcodeInfo(mnemonic: "BPL", mode: .relative, cycles: 2, pageCrossPenalty: false, documented: true), // $10
        OpcodeInfo(mnemonic: "ORA", mode: .indirectIndexed, cycles: 5, pageCrossPenalty: true, documented: true), // $11
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $12
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $13
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $14
        OpcodeInfo(mnemonic: "ORA", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $15
        OpcodeInfo(mnemonic: "ASL", mode: .zeroPageX, cycles: 6, pageCrossPenalty: false, documented: true), // $16
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $17
        OpcodeInfo(mnemonic: "CLC", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $18
        OpcodeInfo(mnemonic: "ORA", mode: .absoluteY, cycles: 4, pageCrossPenalty: true, documented: true), // $19
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $1A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $1B
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $1C
        OpcodeInfo(mnemonic: "ORA", mode: .absoluteX, cycles: 4, pageCrossPenalty: true, documented: true), // $1D
        OpcodeInfo(mnemonic: "ASL", mode: .absoluteX, cycles: 7, pageCrossPenalty: false, documented: true), // $1E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $1F
        OpcodeInfo(mnemonic: "JSR", mode: .absolute, cycles: 6, pageCrossPenalty: false, documented: true), // $20
        OpcodeInfo(mnemonic: "AND", mode: .indexedIndirect, cycles: 6, pageCrossPenalty: false, documented: true), // $21
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $22
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $23
        OpcodeInfo(mnemonic: "BIT", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $24
        OpcodeInfo(mnemonic: "AND", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $25
        OpcodeInfo(mnemonic: "ROL", mode: .zeroPage, cycles: 5, pageCrossPenalty: false, documented: true), // $26
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $27
        OpcodeInfo(mnemonic: "PLP", mode: .implied, cycles: 4, pageCrossPenalty: false, documented: true), // $28
        OpcodeInfo(mnemonic: "AND", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $29
        OpcodeInfo(mnemonic: "ROL", mode: .accumulator, cycles: 2, pageCrossPenalty: false, documented: true), // $2A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $2B
        OpcodeInfo(mnemonic: "BIT", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $2C
        OpcodeInfo(mnemonic: "AND", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $2D
        OpcodeInfo(mnemonic: "ROL", mode: .absolute, cycles: 6, pageCrossPenalty: false, documented: true), // $2E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $2F
        OpcodeInfo(mnemonic: "BMI", mode: .relative, cycles: 2, pageCrossPenalty: false, documented: true), // $30
        OpcodeInfo(mnemonic: "AND", mode: .indirectIndexed, cycles: 5, pageCrossPenalty: true, documented: true), // $31
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $32
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $33
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $34
        OpcodeInfo(mnemonic: "AND", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $35
        OpcodeInfo(mnemonic: "ROL", mode: .zeroPageX, cycles: 6, pageCrossPenalty: false, documented: true), // $36
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $37
        OpcodeInfo(mnemonic: "SEC", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $38
        OpcodeInfo(mnemonic: "AND", mode: .absoluteY, cycles: 4, pageCrossPenalty: true, documented: true), // $39
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $3A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $3B
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $3C
        OpcodeInfo(mnemonic: "AND", mode: .absoluteX, cycles: 4, pageCrossPenalty: true, documented: true), // $3D
        OpcodeInfo(mnemonic: "ROL", mode: .absoluteX, cycles: 7, pageCrossPenalty: false, documented: true), // $3E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $3F
        OpcodeInfo(mnemonic: "RTI", mode: .implied, cycles: 6, pageCrossPenalty: false, documented: true), // $40
        OpcodeInfo(mnemonic: "EOR", mode: .indexedIndirect, cycles: 6, pageCrossPenalty: false, documented: true), // $41
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $42
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $43
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $44
        OpcodeInfo(mnemonic: "EOR", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $45
        OpcodeInfo(mnemonic: "LSR", mode: .zeroPage, cycles: 5, pageCrossPenalty: false, documented: true), // $46
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $47
        OpcodeInfo(mnemonic: "PHA", mode: .implied, cycles: 3, pageCrossPenalty: false, documented: true), // $48
        OpcodeInfo(mnemonic: "EOR", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $49
        OpcodeInfo(mnemonic: "LSR", mode: .accumulator, cycles: 2, pageCrossPenalty: false, documented: true), // $4A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $4B
        OpcodeInfo(mnemonic: "JMP", mode: .absolute, cycles: 3, pageCrossPenalty: false, documented: true), // $4C
        OpcodeInfo(mnemonic: "EOR", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $4D
        OpcodeInfo(mnemonic: "LSR", mode: .absolute, cycles: 6, pageCrossPenalty: false, documented: true), // $4E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $4F
        OpcodeInfo(mnemonic: "BVC", mode: .relative, cycles: 2, pageCrossPenalty: false, documented: true), // $50
        OpcodeInfo(mnemonic: "EOR", mode: .indirectIndexed, cycles: 5, pageCrossPenalty: true, documented: true), // $51
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $52
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $53
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $54
        OpcodeInfo(mnemonic: "EOR", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $55
        OpcodeInfo(mnemonic: "LSR", mode: .zeroPageX, cycles: 6, pageCrossPenalty: false, documented: true), // $56
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $57
        OpcodeInfo(mnemonic: "CLI", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $58
        OpcodeInfo(mnemonic: "EOR", mode: .absoluteY, cycles: 4, pageCrossPenalty: true, documented: true), // $59
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $5A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $5B
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $5C
        OpcodeInfo(mnemonic: "EOR", mode: .absoluteX, cycles: 4, pageCrossPenalty: true, documented: true), // $5D
        OpcodeInfo(mnemonic: "LSR", mode: .absoluteX, cycles: 7, pageCrossPenalty: false, documented: true), // $5E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $5F
        OpcodeInfo(mnemonic: "RTS", mode: .implied, cycles: 6, pageCrossPenalty: false, documented: true), // $60
        OpcodeInfo(mnemonic: "ADC", mode: .indexedIndirect, cycles: 6, pageCrossPenalty: false, documented: true), // $61
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $62
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $63
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $64
        OpcodeInfo(mnemonic: "ADC", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $65
        OpcodeInfo(mnemonic: "ROR", mode: .zeroPage, cycles: 5, pageCrossPenalty: false, documented: true), // $66
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $67
        OpcodeInfo(mnemonic: "PLA", mode: .implied, cycles: 4, pageCrossPenalty: false, documented: true), // $68
        OpcodeInfo(mnemonic: "ADC", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $69
        OpcodeInfo(mnemonic: "ROR", mode: .accumulator, cycles: 2, pageCrossPenalty: false, documented: true), // $6A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $6B
        OpcodeInfo(mnemonic: "JMP", mode: .indirect, cycles: 5, pageCrossPenalty: false, documented: true), // $6C
        OpcodeInfo(mnemonic: "ADC", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $6D
        OpcodeInfo(mnemonic: "ROR", mode: .absolute, cycles: 6, pageCrossPenalty: false, documented: true), // $6E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $6F
        OpcodeInfo(mnemonic: "BVS", mode: .relative, cycles: 2, pageCrossPenalty: false, documented: true), // $70
        OpcodeInfo(mnemonic: "ADC", mode: .indirectIndexed, cycles: 5, pageCrossPenalty: true, documented: true), // $71
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $72
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $73
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $74
        OpcodeInfo(mnemonic: "ADC", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $75
        OpcodeInfo(mnemonic: "ROR", mode: .zeroPageX, cycles: 6, pageCrossPenalty: false, documented: true), // $76
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $77
        OpcodeInfo(mnemonic: "SEI", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $78
        OpcodeInfo(mnemonic: "ADC", mode: .absoluteY, cycles: 4, pageCrossPenalty: true, documented: true), // $79
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $7A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $7B
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $7C
        OpcodeInfo(mnemonic: "ADC", mode: .absoluteX, cycles: 4, pageCrossPenalty: true, documented: true), // $7D
        OpcodeInfo(mnemonic: "ROR", mode: .absoluteX, cycles: 7, pageCrossPenalty: false, documented: true), // $7E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $7F
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $80
        OpcodeInfo(mnemonic: "STA", mode: .indexedIndirect, cycles: 6, pageCrossPenalty: false, documented: true), // $81
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $82
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $83
        OpcodeInfo(mnemonic: "STY", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $84
        OpcodeInfo(mnemonic: "STA", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $85
        OpcodeInfo(mnemonic: "STX", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $86
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $87
        OpcodeInfo(mnemonic: "DEY", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $88
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $89
        OpcodeInfo(mnemonic: "TXA", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $8A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $8B
        OpcodeInfo(mnemonic: "STY", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $8C
        OpcodeInfo(mnemonic: "STA", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $8D
        OpcodeInfo(mnemonic: "STX", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $8E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $8F
        OpcodeInfo(mnemonic: "BCC", mode: .relative, cycles: 2, pageCrossPenalty: false, documented: true), // $90
        OpcodeInfo(mnemonic: "STA", mode: .indirectIndexed, cycles: 6, pageCrossPenalty: false, documented: true), // $91
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $92
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $93
        OpcodeInfo(mnemonic: "STY", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $94
        OpcodeInfo(mnemonic: "STA", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $95
        OpcodeInfo(mnemonic: "STX", mode: .zeroPageY, cycles: 4, pageCrossPenalty: false, documented: true), // $96
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $97
        OpcodeInfo(mnemonic: "TYA", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $98
        OpcodeInfo(mnemonic: "STA", mode: .absoluteY, cycles: 5, pageCrossPenalty: false, documented: true), // $99
        OpcodeInfo(mnemonic: "TXS", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $9A
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $9B
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $9C
        OpcodeInfo(mnemonic: "STA", mode: .absoluteX, cycles: 5, pageCrossPenalty: false, documented: true), // $9D
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $9E
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $9F
        OpcodeInfo(mnemonic: "LDY", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $A0
        OpcodeInfo(mnemonic: "LDA", mode: .indexedIndirect, cycles: 6, pageCrossPenalty: false, documented: true), // $A1
        OpcodeInfo(mnemonic: "LDX", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $A2
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $A3
        OpcodeInfo(mnemonic: "LDY", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $A4
        OpcodeInfo(mnemonic: "LDA", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $A5
        OpcodeInfo(mnemonic: "LDX", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $A6
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $A7
        OpcodeInfo(mnemonic: "TAY", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $A8
        OpcodeInfo(mnemonic: "LDA", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $A9
        OpcodeInfo(mnemonic: "TAX", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $AA
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $AB
        OpcodeInfo(mnemonic: "LDY", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $AC
        OpcodeInfo(mnemonic: "LDA", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $AD
        OpcodeInfo(mnemonic: "LDX", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $AE
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $AF
        OpcodeInfo(mnemonic: "BCS", mode: .relative, cycles: 2, pageCrossPenalty: false, documented: true), // $B0
        OpcodeInfo(mnemonic: "LDA", mode: .indirectIndexed, cycles: 5, pageCrossPenalty: true, documented: true), // $B1
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $B2
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $B3
        OpcodeInfo(mnemonic: "LDY", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $B4
        OpcodeInfo(mnemonic: "LDA", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $B5
        OpcodeInfo(mnemonic: "LDX", mode: .zeroPageY, cycles: 4, pageCrossPenalty: false, documented: true), // $B6
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $B7
        OpcodeInfo(mnemonic: "CLV", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $B8
        OpcodeInfo(mnemonic: "LDA", mode: .absoluteY, cycles: 4, pageCrossPenalty: true, documented: true), // $B9
        OpcodeInfo(mnemonic: "TSX", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $BA
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $BB
        OpcodeInfo(mnemonic: "LDY", mode: .absoluteX, cycles: 4, pageCrossPenalty: true, documented: true), // $BC
        OpcodeInfo(mnemonic: "LDA", mode: .absoluteX, cycles: 4, pageCrossPenalty: true, documented: true), // $BD
        OpcodeInfo(mnemonic: "LDX", mode: .absoluteY, cycles: 4, pageCrossPenalty: true, documented: true), // $BE
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $BF
        OpcodeInfo(mnemonic: "CPY", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $C0
        OpcodeInfo(mnemonic: "CMP", mode: .indexedIndirect, cycles: 6, pageCrossPenalty: false, documented: true), // $C1
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $C2
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $C3
        OpcodeInfo(mnemonic: "CPY", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $C4
        OpcodeInfo(mnemonic: "CMP", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $C5
        OpcodeInfo(mnemonic: "DEC", mode: .zeroPage, cycles: 5, pageCrossPenalty: false, documented: true), // $C6
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $C7
        OpcodeInfo(mnemonic: "INY", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $C8
        OpcodeInfo(mnemonic: "CMP", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $C9
        OpcodeInfo(mnemonic: "DEX", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $CA
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $CB
        OpcodeInfo(mnemonic: "CPY", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $CC
        OpcodeInfo(mnemonic: "CMP", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $CD
        OpcodeInfo(mnemonic: "DEC", mode: .absolute, cycles: 6, pageCrossPenalty: false, documented: true), // $CE
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $CF
        OpcodeInfo(mnemonic: "BNE", mode: .relative, cycles: 2, pageCrossPenalty: false, documented: true), // $D0
        OpcodeInfo(mnemonic: "CMP", mode: .indirectIndexed, cycles: 5, pageCrossPenalty: true, documented: true), // $D1
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $D2
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $D3
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $D4
        OpcodeInfo(mnemonic: "CMP", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $D5
        OpcodeInfo(mnemonic: "DEC", mode: .zeroPageX, cycles: 6, pageCrossPenalty: false, documented: true), // $D6
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $D7
        OpcodeInfo(mnemonic: "CLD", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $D8
        OpcodeInfo(mnemonic: "CMP", mode: .absoluteY, cycles: 4, pageCrossPenalty: true, documented: true), // $D9
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $DA
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $DB
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $DC
        OpcodeInfo(mnemonic: "CMP", mode: .absoluteX, cycles: 4, pageCrossPenalty: true, documented: true), // $DD
        OpcodeInfo(mnemonic: "DEC", mode: .absoluteX, cycles: 7, pageCrossPenalty: false, documented: true), // $DE
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $DF
        OpcodeInfo(mnemonic: "CPX", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $E0
        OpcodeInfo(mnemonic: "SBC", mode: .indexedIndirect, cycles: 6, pageCrossPenalty: false, documented: true), // $E1
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $E2
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $E3
        OpcodeInfo(mnemonic: "CPX", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $E4
        OpcodeInfo(mnemonic: "SBC", mode: .zeroPage, cycles: 3, pageCrossPenalty: false, documented: true), // $E5
        OpcodeInfo(mnemonic: "INC", mode: .zeroPage, cycles: 5, pageCrossPenalty: false, documented: true), // $E6
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $E7
        OpcodeInfo(mnemonic: "INX", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $E8
        OpcodeInfo(mnemonic: "SBC", mode: .immediate, cycles: 2, pageCrossPenalty: false, documented: true), // $E9
        OpcodeInfo(mnemonic: "NOP", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $EA
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $EB
        OpcodeInfo(mnemonic: "CPX", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $EC
        OpcodeInfo(mnemonic: "SBC", mode: .absolute, cycles: 4, pageCrossPenalty: false, documented: true), // $ED
        OpcodeInfo(mnemonic: "INC", mode: .absolute, cycles: 6, pageCrossPenalty: false, documented: true), // $EE
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $EF
        OpcodeInfo(mnemonic: "BEQ", mode: .relative, cycles: 2, pageCrossPenalty: false, documented: true), // $F0
        OpcodeInfo(mnemonic: "SBC", mode: .indirectIndexed, cycles: 5, pageCrossPenalty: true, documented: true), // $F1
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $F2
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $F3
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $F4
        OpcodeInfo(mnemonic: "SBC", mode: .zeroPageX, cycles: 4, pageCrossPenalty: false, documented: true), // $F5
        OpcodeInfo(mnemonic: "INC", mode: .zeroPageX, cycles: 6, pageCrossPenalty: false, documented: true), // $F6
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $F7
        OpcodeInfo(mnemonic: "SED", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: true), // $F8
        OpcodeInfo(mnemonic: "SBC", mode: .absoluteY, cycles: 4, pageCrossPenalty: true, documented: true), // $F9
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $FA
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $FB
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $FC
        OpcodeInfo(mnemonic: "SBC", mode: .absoluteX, cycles: 4, pageCrossPenalty: true, documented: true), // $FD
        OpcodeInfo(mnemonic: "INC", mode: .absoluteX, cycles: 7, pageCrossPenalty: false, documented: true), // $FE
        OpcodeInfo(mnemonic: "???", mode: .implied, cycles: 2, pageCrossPenalty: false, documented: false), // $FF
    ]
}
