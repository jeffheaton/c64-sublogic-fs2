import Foundation
import M6502
import Testing

final class FlatRAM: MemoryBus {
    var ram: [UInt8]
    init(_ bytes: [UInt8]) { ram = bytes }
    func read(_ address: UInt16) -> UInt8 { ram[Int(address)] }
    func write(_ address: UInt16, _ value: UInt8) { ram[Int(address)] = value }
}

/// Klaus Dormann's 6502 functional test (build/testdata/6502_functional_test.bin, downloaded
/// separately; the test is skipped when the file is absent). Success is the `jmp *` at $3469.
@Test func dormannFunctionalTest() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("build/testdata/6502_functional_test.bin")
    guard let data = try? Data(contentsOf: url) else {
        print("skipping: \(url.path) not present")
        return
    }
    let cpu = CPU6502(bus: FlatRAM([UInt8](data)))
    cpu.pc = 0x0400
    var last: UInt16 = 0
    var steps = 0
    while steps < 200_000_000 {
        last = cpu.pc
        cpu.step()
        steps += 1
        if cpu.pc == last { break }
    }
    #expect(cpu.illegalOpcode == nil)
    #expect(cpu.pc == 0x3469, "trapped at $\(String(cpu.pc, radix: 16)) after \(steps) instructions")
}

@Test func cycleCounts() {
    // LDA $10FF,X with X=1 crosses a page: 5 cycles; taken branch to the same page: 3.
    var mem = [UInt8](repeating: 0xEA, count: 0x10000)
    mem[0x0200] = 0xBD; mem[0x0201] = 0xFF; mem[0x0202] = 0x10   // LDA $10FF,X
    mem[0x0203] = 0xD0; mem[0x0204] = 0x02                       // BNE +2
    let cpu = CPU6502(bus: FlatRAM(mem))
    cpu.pc = 0x0200; cpu.x = 1
    #expect(cpu.step() == 5)
    cpu.zero = false
    #expect(cpu.step() == 3)
    #expect(cpu.pc == 0x0207)
}
