import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// One SID store of an input-unit call: register, value and the cycle offset (from the start of
/// the call) of the store instruction.
struct InputSIDStore: Equatable, CustomStringConvertible {
    var offset: UInt64
    var reg: Int
    var value: UInt8
    var description: String { String(format: "+%llu $D4%02X=$%02X", offset, reg, value) }
}

/// Differential rig for the input unit on the flat bus (no I/O reads): the original runs in a
/// `RoutineHarness` (stepped so its SID stores can be timestamped), the port on a twin `Machine`.
/// After every call it compares memory (stack page and $D000-$DFFF excluded: the flat bus stores
/// SID values into RAM, the port sends them to `io`), the cycles, the registers the port returns
/// and the SID stores. Both sides keep their state; a mismatch resynchronizes the port.
///
/// The port's `waitForKey` loops through its own 10 Hz poll ($2330, `pollTick`) and tick body
/// ($2348, `tick10Hz`), exactly like the original's.
final class InputRig {
    let harness: RoutineHarness
    let machine: Machine
    private(set) var failures: [String] = []
    private(set) var failureCount = 0
    private(set) var calls = 0
    static let ignored: [ClosedRange<Int>] = [0x0100...0x01FF, 0xD000...0xDFFF]

    init(_ ram: [UInt8]) {
        harness = RoutineHarness(ram: ram)
        machine = Machine(memory: ram)
        machine.clock.cycles = 1_000_000
        // waitForKey's loop runs the ported $2330 (pollTick) and tick body $2348 (tick10Hz). The
        // flat bus has no I/O: the port reads the TOD seconds ($DC09) from the same RAM byte.
        machine.ioReadHook = { [unowned machine] address, _ in machine.mem[address] }
    }

    func peek(_ address: Int) -> UInt8 { machine.mem[address] }

    func poke(_ address: Int, _ value: UInt8) {
        harness.bus.ram[address] = value
        machine.mem[address] = value
    }

    func poke16(_ address: Int, _ value: UInt16) {
        poke(address, UInt8(value & 0xFF))
        poke(address + 1, UInt8(value >> 8))
    }

    /// Queues `code` in the key ring on both sides (as `enqueueKey` does).
    func enqueue(_ code: UInt8) {
        let write = peek(Input.RAM.keyQueueWrite) &+ 1
        poke(Input.RAM.keyQueueWrite, write)
        poke(Input.RAM.keyQueue + Int(write & 7), code)
    }

    struct Out {
        var a: UInt8?
        var x: UInt8?
        var y: UInt8?
        var carry: Bool?
    }

    /// Runs the original at `address` from the given registers until it returns (or, with
    /// `stopAt`, until the PC reaches one of those addresses) and the port; records a failure on
    /// any difference. Returns the original's registers.
    @discardableResult
    func run(_ address: UInt16, _ label: @autoclosure () -> String, regs: RoutineHarness.Registers = .init(),
             stopAt: Set<UInt16> = [], extraOriginalCycles: (UInt16) -> UInt64 = { _ in 0 },
             port: (Machine) -> Out) -> (registers: RoutineHarness.Registers, stoppedAt: UInt16) {
        calls += 1
        let cpu = harness.cpu, bus = harness.bus
        cpu.a = regs.a; cpu.x = regs.x; cpu.y = regs.y
        cpu.carry = regs.carry; cpu.zero = regs.zero; cpu.negative = regs.negative
        cpu.overflow = regs.overflow; cpu.decimal = false
        cpu.interruptDisable = true
        cpu.irqLine = false
        bus.ram[0x01FF] = 0xFF
        bus.ram[0x01FE] = 0xEF                      // the return lands on the sentinel $FFF0
        cpu.sp = 0xFD
        cpu.pc = address
        bus.ioWrites.removeAll(keepingCapacity: true)
        let start = cpu.cycles
        var stores: [InputSIDStore] = []
        while cpu.pc != 0xFFF0 && !stopAt.contains(cpu.pc) && cpu.cycles - start < 20_000_000 {
            let before = cpu.cycles, seen = bus.ioWrites.count
            if cpu.step() == 0 { break }
            for w in bus.ioWrites[seen...] where (0xD400...0xD41F).contains(Int(w.address)) {
                stores.append(InputSIDStore(offset: before - start, reg: Int(w.address) - 0xD400, value: w.value))
            }
        }
        let stoppedAt = cpu.pc
        let originalCycles = cpu.cycles - start + extraOriginalCycles(stoppedAt)
        let completed = cpu.pc == 0xFFF0 || stopAt.contains(cpu.pc)

        let portStart = machine.clock.cycles
        let sidStart = machine.io.sidWrites.count
        let p = port(machine)
        let portCycles = machine.clock.cycles - portStart
        let portStores = machine.io.sidWrites[sidStart...].map {
            InputSIDStore(offset: $0.cycle - portStart, reg: Int($0.reg), value: $0.value)
        }

        var problems: [String] = []
        if !completed { problems.append("original did not return") }
        if let a = p.a, a != cpu.a { problems.append("A=\(hex(a)) want \(hex(cpu.a))") }
        if let x = p.x, x != cpu.x { problems.append("X=\(hex(x)) want \(hex(cpu.x))") }
        if let y = p.y, y != cpu.y { problems.append("Y=\(hex(y)) want \(hex(cpu.y))") }
        if let c = p.carry, c != cpu.carry { problems.append("C=\(c) want \(cpu.carry)") }
        if portCycles != originalCycles { problems.append("cycles \(portCycles) want \(originalCycles)") }
        if portStores != stores { problems.append("SID \(portStores.prefix(6)) want \(stores.prefix(6))") }
        if let d = firstDifference() {
            let count = Original.differences(machine.memoryImage, bus.ram, ignoring: Self.ignored).count
            problems.append("memory $\(hex16(d)) = \(hex(machine.mem[d])) want \(hex(bus.ram[d])) (\(count) bytes differ)")
            machine.load(memory: bus.ram)
        }
        if !problems.isEmpty {
            failureCount += 1
            if failures.count < 16 { failures.append("\(label()): " + problems.joined(separator: ", ")) }
        }
        var out = RoutineHarness.Registers(a: cpu.a, x: cpu.x, y: cpu.y, carry: cpu.carry)
        out.zero = cpu.zero; out.negative = cpu.negative
        return (out, stoppedAt)
    }

    /// First address (outside the stack page and $D000-$DFFF) where the two images differ.
    func firstDifference() -> Int? {
        harness.bus.ram.withUnsafeBufferPointer { o in
            let p = UnsafeRawPointer(machine.mem), q = UnsafeRawPointer(o.baseAddress!)
            for range in [0..<0x100, 0x200..<0xD000, 0xE000..<0x10000]
            where memcmp(p + range.lowerBound, q + range.lowerBound, range.count) != 0 {
                return range.first { machine.mem[$0] != o[$0] }
            }
            return nil
        }
    }

    func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let report = "\(what): \(failureCount) of \(calls) calls differ\n" + failures.joined(separator: "\n")
        #expect(failureCount == 0, "\(report)", sourceLocation: sourceLocation)
    }
}

/// Recorded game states for the input tests (lab sessions, cached in build/testdata). Each
/// starts like re/sessions/regular.txt and waits until the Meigs scenery has loaded.
enum InputStates {
    static let boot = """
        pc:2250:9000 key:A:12
        pc:2250:600 key:B:12
        pc:204B:3000
        until:0901:4E:3000 pc:204B:3000 wait:60
        """

    /// Radios tuned (COM, NAV1, OBS1, transponder), the ADF enabled with a digit changed.
    static let tuned = boot + """

        down:CTRL wait:8 key:C:6 up:CTRL wait:20 key:.:6 wait:20 key:.:6 wait:20
        down:CTRL wait:8 key:N:6 up:CTRL wait:20 key:,:6 wait:20
        down:CTRL wait:8 key:V:6 up:CTRL wait:20 key:.:6 wait:20 key:.:6 wait:20
        down:CTRL wait:8 key:X:6 up:CTRL wait:20 key:.:6 wait:20
        poke:09AA:01 wait:60 key:A:6 wait:20 key:.:6 wait:60 pc:204B:3000
        """

    /// Europe 1917 (editor page 0 line 6 = 1), war declared, taking off north.
    static let war = boot + """

        key:E:6 pc:2250:1500 wait:10 key:RETURN:6 wait:24 key:RETURN:6 wait:24 key:RETURN:6 wait:24
        key:RETURN:6 wait:24 key:RETURN:6 wait:24 key:1:6 wait:24
        key:E:6 pc:204B:3000 pc:204B:3000 wait:600
        key:W:6 wait:150
        key:;:150 wait:650 key:B:6 wait:20 key:B:6 wait:20 key:B:6 wait:600 pc:204B:3000
        """

    /// Slew on (editor page 0 line 4 = 1), climbing.
    static let slew = boot + """

        key:E:6 pc:2250:1500 wait:10 key:RETURN:6 wait:24 key:RETURN:6 wait:24 key:RETURN:6 wait:24
        key:1:6 wait:24 key:E:6 pc:204B:3000 pc:204B:3000 wait:120
        key:;:6 wait:20 key:;:6 wait:20 key:H:6 wait:60 pc:204B:3000
        """

    /// The radar view, zoomed out once.
    static let radar = boot + """

        key:4:6 wait:30 key:,:6 wait:60 pc:204B:3000
        """

    private static let cache = Result<[String: [UInt8]], Error> {
        var out: [String: [UInt8]] = [:]
        out["regular"] = try Original.regularFlight()
        out["demo"] = try Original.demoFlight()
        for (name, session) in [("in-tuned", tuned), ("in-war", war), ("in-slew", slew), ("in-radar", radar)] {
            out[name] = try Original.snapshot(name, session: session)
        }
        return out
    }

    static let names = ["regular", "demo", "in-tuned", "in-war", "in-slew", "in-radar"]

    static func ram(_ name: String) throws -> [UInt8] {
        guard let r = try cache.get()[name] else { throw CocoaError(.fileNoSuchFile) }
        return r
    }
}
