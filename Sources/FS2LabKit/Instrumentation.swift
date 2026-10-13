import Foundation
import M6502

/// Execution and data-access coverage for reverse engineering: which bytes ran as instruction
/// starts, and which were read or written as data. Stored per address as flag bits.
public final class Coverage {
    public static let executed: UInt8 = 0x04
    public static let read: UInt8 = 0x01
    public static let written: UInt8 = 0x02

    public let flags: UnsafeMutablePointer<UInt8>

    public init() {
        flags = .allocate(capacity: 0x10000)
        flags.initialize(repeating: 0, count: 0x10000)
    }

    deinit { flags.deallocate() }

    /// Starts recording on a machine (replaces its onInstruction hook).
    public func attach(to m: C64Machine) {
        m.bus.accessMap = flags
        let f = flags
        let previous = m.onInstruction
        m.onInstruction = { pc in
            f[Int(pc)] |= Coverage.executed
            previous?(pc)
        }
    }

    public func merge(_ other: Coverage) {
        for i in 0..<0x10000 { flags[i] |= other.flags[i] }
    }

    /// Run-length summary: [(start, end, flags)] over addresses with the same flags.
    public func ranges(in range: ClosedRange<Int> = 0...0xFFFF) -> [(start: Int, end: Int, flags: UInt8)] {
        var out: [(Int, Int, UInt8)] = []
        var start = range.lowerBound
        var cur = flags[start]
        for a in (range.lowerBound + 1)...range.upperBound {
            if flags[a] != cur {
                out.append((start, a - 1, cur))
                start = a; cur = flags[a]
            }
        }
        out.append((start, range.upperBound, cur))
        return out
    }

    public func write(to url: URL) throws {
        try Data(bytes: flags, count: 0x10000).write(to: url)
    }

    public func load(from url: URL) throws {
        let d = try Data(contentsOf: url)
        d.withUnsafeBytes { raw in
            for i in 0..<min(0x10000, raw.count) { flags[i] |= raw[i] }
        }
    }
}

/// Measures main-loop iterations: cycles and frames between successive visits to an address
/// (by default $204B, the top of Flight Simulator II's main loop).
public final class LoopTimer {
    public struct Iteration: Codable, Sendable {
        public let startCycle: UInt64
        public let cycles: UInt64
        public let frames: Int
    }

    public private(set) var iterations: [Iteration] = []
    private var lastCycle: UInt64?
    private var lastFrame = 0
    public let address: UInt16

    public init(address: UInt16 = 0x204B) { self.address = address }

    public func attach(to m: C64Machine) {
        let previous = m.onInstruction
        m.onInstruction = { [unowned self, unowned m] pc in
            if pc == self.address {
                if let last = self.lastCycle {
                    self.iterations.append(Iteration(startCycle: last, cycles: m.cpu.cycles - last,
                                                     frames: m.frameCount - self.lastFrame))
                }
                self.lastCycle = m.cpu.cycles
                self.lastFrame = m.frameCount
            }
            previous?(pc)
        }
    }
}

/// Calls original routines on a flat 64 KB RAM image (no I/O), for routine-level differential tests.
public final class RoutineHarness {
    public final class FlatBus: MemoryBus {
        public var ram: [UInt8]
        /// Writes into $D000-$DFFF (where I/O would be), in order, for routines that drive the SID/VIC.
        public var ioWrites: [(address: UInt16, value: UInt8)] = []
        public init(ram: [UInt8]) { self.ram = ram }
        public func read(_ address: UInt16) -> UInt8 { ram[Int(address)] }
        public func write(_ address: UInt16, _ value: UInt8) {
            if address >= 0xD000 && address < 0xE000 { ioWrites.append((address, value)) }
            ram[Int(address)] = value
        }
    }

    public struct Registers: Equatable, Sendable {
        public var a: UInt8 = 0, x: UInt8 = 0, y: UInt8 = 0
        public var carry = false, zero = false, negative = false, overflow = false, decimal = false
        public init(a: UInt8 = 0, x: UInt8 = 0, y: UInt8 = 0, carry: Bool = false) {
            self.a = a; self.x = x; self.y = y; self.carry = carry
        }
    }

    public struct Result: Sendable {
        public var registers: Registers
        public var cycles: UInt64
        public var completed: Bool
    }

    /// Sentinel return address: a JSR from here returns to $FFF0+1, which is trapped.
    static let sentinel: UInt16 = 0xFFF0

    public let bus: FlatBus
    public let cpu: CPU6502<FlatBus>

    public init(ram: [UInt8]) {
        bus = FlatBus(ram: ram)
        cpu = CPU6502(bus: bus)
    }

    /// Runs the routine at `address` until it returns (RTS to the sentinel) or `maxCycles` pass.
    public func call(_ address: UInt16, _ regs: Registers, maxCycles: UInt64 = 5_000_000) -> Result {
        cpu.a = regs.a; cpu.x = regs.x; cpu.y = regs.y
        cpu.carry = regs.carry; cpu.zero = regs.zero; cpu.negative = regs.negative
        cpu.overflow = regs.overflow; cpu.decimal = regs.decimal
        cpu.interruptDisable = true
        cpu.irqLine = false
        cpu.sp = 0xFF
        // Return address on the stack is sentinel-1 (RTS adds one).
        let ret = Self.sentinel &- 1
        bus.ram[0x01FF] = UInt8(ret >> 8); bus.ram[0x01FE] = UInt8(ret & 0xFF)
        cpu.sp = 0xFD
        cpu.pc = address
        let start = cpu.cycles
        while cpu.pc != Self.sentinel && cpu.cycles - start < maxCycles {
            if cpu.step() == 0 { break }
        }
        var out = Registers(a: cpu.a, x: cpu.x, y: cpu.y, carry: cpu.carry)
        out.zero = cpu.zero; out.negative = cpu.negative; out.overflow = cpu.overflow; out.decimal = cpu.decimal
        return Result(registers: out, cycles: cpu.cycles - start, completed: cpu.pc == Self.sentinel)
    }
}
