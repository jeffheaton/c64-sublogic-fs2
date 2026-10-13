import C64Kit
import M6502

/// Calls original routines on a full lab machine — real VIC/CIA/SID registers and the virtual 1541
/// — for routines that do I/O or disk loads (the flat `RoutineHarness` has no I/O). Built from a
/// booted machine (typically after a session), so the hardware is configured the way the game set
/// it up; each call can substitute the 64 KB RAM image. Raster IRQs are never taken during a call
/// (quantized mode with no deliveries), so results are deterministic.
public final class MachineHarness {
    public let machine: C64Machine
    static let sentinel: UInt16 = 0xFFF0

    public init(machine: C64Machine) {
        self.machine = machine
        machine.quantizedIRQs = true
    }

    /// Runs the routine at `address` until it returns, optionally on a replacement RAM image.
    public func call(_ address: UInt16, ram: [UInt8]? = nil, _ regs: RoutineHarness.Registers = .init(),
                     maxCycles: UInt64 = 200_000_000) -> RoutineHarness.Result {
        let cpu = machine.cpu
        let bus = machine.bus
        if let ram {
            bus.ram = ram
            bus.portData = ram[1]
            // Snapshots hold 0 at $00 (the CPU port direction register is not RAM); keep the
            // booted direction ($2F) then, or every port bit reads high.
            if ram[0] != 0 { bus.portDDR = ram[0] }
        }
        bus.sidWrites.removeAll(keepingCapacity: true)
        cpu.a = regs.a; cpu.x = regs.x; cpu.y = regs.y
        cpu.carry = regs.carry; cpu.zero = regs.zero; cpu.negative = regs.negative
        cpu.overflow = regs.overflow; cpu.decimal = regs.decimal
        cpu.interruptDisable = true
        let ret = Self.sentinel &- 1
        cpu.sp = 0xFF
        bus.ram[0x01FF] = UInt8(ret >> 8); bus.ram[0x01FE] = UInt8(ret & 0xFF)
        cpu.sp = 0xFD
        cpu.pc = address
        let start = cpu.cycles
        while cpu.pc != Self.sentinel && cpu.cycles - start < maxCycles {
            if !machine.step() { break }
        }
        var out = RoutineHarness.Registers(a: cpu.a, x: cpu.x, y: cpu.y, carry: cpu.carry)
        out.zero = cpu.zero; out.negative = cpu.negative; out.overflow = cpu.overflow; out.decimal = cpu.decimal
        return RoutineHarness.Result(registers: out, cycles: cpu.cycles - start, completed: cpu.pc == Self.sentinel)
    }
}
