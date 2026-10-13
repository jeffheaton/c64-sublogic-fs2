import FS2Core
import FS2LabKit
import Foundation
import Testing

func hex(_ v: UInt8) -> String { String(format: "$%02X", v) }
func hex16(_ v: Int) -> String { String(format: "%04X", v) }

/// Shared differential-test rig. Runs original routines in the lab and their ports on twin copies of one memory image, and
/// after every call compares the whole image (stack page excluded), the returned registers and the
/// cycle count. Both sides keep their state between calls, so any divergence shows up at once.
final class DiffRig {
    let harness: RoutineHarness
    let machine: Machine
    private(set) var failures: [String] = []
    private(set) var failureCount = 0
    private(set) var calls = 0

    init(_ ram: [UInt8]) {
        harness = RoutineHarness(ram: ram)
        machine = Machine(memory: ram)
        // The original runs on a flat bus, where an I/O read (the TOD seconds $DC09 in the 10 Hz
        // tick, the ICRs, ...) returns the RAM byte at that address; give the port the same view.
        machine.ioReadHook = { [unowned machine] address, _ in machine.mem[address & 0xFFFF] }
    }

    /// Where the port's I/O stood before a call (see `mirrorIO`).
    struct IOMark {
        let sidWrites: Int
        let vic: [UInt8]
        let colorRAM: [UInt8]
    }

    func ioMark() -> IOMark {
        IOMark(sidWrites: machine.io.sidWrites.count, vic: machine.io.vic, colorRAM: machine.io.colorRAM)
    }

    /// The original runs on a flat bus, where its stores to $D000-$DFFF land in RAM; the port's
    /// go to `machine.io`. After a port call, copy the port's I/O writes since `mark` into its RAM
    /// image (SID writes in order, VIC registers and color RAM cells that changed), so the twin
    /// images stay comparable byte for byte.
    func mirrorIO(since mark: IOMark) {
        let io = machine.io
        for w in io.sidWrites[mark.sidWrites...] { machine.mem[0xD400 + Int(w.reg)] = w.value }
        for r in 0..<io.vic.count where io.vic[r] != mark.vic[r] { machine.mem[0xD000 + r] = io.vic[r] }
        for i in 0..<io.colorRAM.count where io.colorRAM[i] != mark.colorRAM[i] {
            machine.mem[0xD800 + i] = io.colorRAM[i]
        }
    }

    /// The registers a port returns; nil means "not modeled / unchanged" and is not compared.
    struct Out {
        var a: UInt8?, x: UInt8?, y: UInt8?, carry: Bool? = nil
    }

    func poke(_ address: Int, _ value: UInt8) {
        harness.bus.ram[address] = value
        machine.mem[address] = value
    }

    func poke16(_ address: Int, _ value: UInt16) {
        poke(address, UInt8(value & 0xFF)); poke(address + 1, UInt8(value >> 8))
    }

    /// Runs the original routine at `address` with `regs`, and `port` on the machine; records a
    /// failure (with `label`) if anything differs. Returns the original's result.
    @discardableResult
    func run(_ address: UInt16, _ regs: RoutineHarness.Registers, _ label: @autoclosure () -> String,
             port: (Machine) -> Out) -> RoutineHarness.Result {
        calls += 1
        let o = harness.call(address, regs)
        let start = machine.clock.cycles
        let mark = ioMark()
        let p = port(machine)
        mirrorIO(since: mark)
        let cycles = machine.clock.cycles - start
        var problems: [String] = []
        if !o.completed { problems.append("original did not return") }
        let r = o.registers
        if let a = p.a, a != r.a { problems.append("A=\(hex(a)) want \(hex(r.a))") }
        if let x = p.x, x != r.x { problems.append("X=\(hex(x)) want \(hex(r.x))") }
        if let y = p.y, y != r.y { problems.append("Y=\(hex(y)) want \(hex(r.y))") }
        if let c = p.carry, c != r.carry { problems.append("C=\(c) want \(r.carry)") }
        if cycles != o.cycles { problems.append("cycles \(cycles) want \(o.cycles)") }
        if let d = firstDifference() {
            if failures.count < 12 {
                problems.append("memory $\(hex16(d)) = \(hex(machine.mem[d])) want \(hex(harness.bus.ram[d]))"
                                + " (\(differenceCount()) bytes differ)")
            } else {
                problems.append("memory")
            }
            machine.load(memory: harness.bus.ram)          // resynchronize and keep going
        }
        if !problems.isEmpty {
            failureCount += 1
            if failures.count < 12 { failures.append("\(label()): " + problems.joined(separator: ", ")) }
        }
        return o
    }

    /// First address (outside the stack page) where the two images differ.
    func firstDifference() -> Int? {
        harness.bus.ram.withUnsafeBufferPointer { o in
            let p = UnsafeRawPointer(machine.mem), q = UnsafeRawPointer(o.baseAddress!)
            for range in [0..<0x100, 0x200..<0x10000]
            where memcmp(p + range.lowerBound, q + range.lowerBound, range.count) != 0 {
                return range.first { machine.mem[$0] != o[$0] }
            }
            return nil
        }
    }

    private func differenceCount() -> Int {
        Original.differences(machine.memoryImage, harness.bus.ram).count
    }

    /// Fails the current test with the collected mismatches, if any.
    func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let report = "\(what): \(failureCount) of \(calls) calls differ\n" + failures.joined(separator: "\n")
        #expect(failureCount == 0, "\(report)", sourceLocation: sourceLocation)
    }
}
