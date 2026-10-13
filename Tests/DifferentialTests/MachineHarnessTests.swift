import FS2Core
import FS2LabKit
import Testing

@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct MachineHarnessTests {
    /// SubLogic's own loader ($7309) reads a logical block through the virtual 1541 inside the
    /// full-machine harness; the bytes must equal the disk block, and the zero-page side effects
    /// are reported for the streaming port.
    @Test func originalLoaderReadsABlock() throws {
        let h = try Original.machineHarness()
        var ram = h.machine.bus.ram
        ram[0x731C] = 0x42                      // block 66 (scenery root)
        ram[0x731E] = 0x00; ram[0x731F] = 0x60  // to $6000 ($7327 guards $C000 and up)
        // Like the game's streaming path ($E63C/$E657): sprites off during disk I/O (their DMA plus
        // badlines would outlast the serial bit window, on real hardware too), channels opened ($7306).
        h.machine.bus.vicRegs[0x15] = 0
        let open = h.call(0x7306, ram: ram)
        #expect(open.completed && !open.registers.carry)
        let before = h.machine.bus.ram
        let r = h.call(0x7309, maxCycles: 20_000_000)
        #expect(r.completed)
        #expect(!r.registers.carry, "loader reported an error")
        let block = Original.diskBlocks[0x42]
        #expect(Array(h.machine.bus.ram[0x6000..<0x6400]) == block)
        let zp = (0..<0x100).filter { before[$0] != h.machine.bus.ram[$0] }
        print("loader cycles:", r.cycles, "zero-page bytes changed:",
              zp.map { "$" + String($0, radix: 16) }.joined(separator: " "))
    }
}
