import C64Kit
import Foundation
import FS2Core
import FS2Data
@testable import FS2LabKit
import Testing

/// The cold start: the stage-2 handoff state, the init chain $A946-$ABBA with the title and the
/// prompts, against the lab booting the original (`Lab.boot`, which runs SubLogic's own init
/// with the loader against its virtual 1541).
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct ColdInitTests {
    /// The port's boot image is the lab's starting RAM (the lab leaves the RAM under the CPU port
    /// at 0 until the first store to $01; the port has stage 2's $35 there), and the hardware the
    /// handoff sets up is the lab's.
    @Test func bootStateMatchesLab() throws {
        let data = try #require(Original.data)
        let lab = Lab.boot(data)
        let port = Machine.booting(blocks: data.disk.blocks)
        let d = Original.differences(port.memoryImage, lab.bus.ram, ignoring: [0x0001...0x0001])
        #expect(d.isEmpty, "\(d.count) bytes differ, first \(d.prefix(8).map { hex16($0) })")
        #expect(port.mem[0x01] == lab.bus.portData)
        #expect(Array(lab.bus.vicRegs[0..<0x2F]) == port.io.vic)
        #expect(lab.bus.colorRAM == port.io.colorRAM)
        #expect(lab.bus.vicBank == port.io.vicState().bank)
        #expect(port.mem[0x7326] == 0 && port.mem[0xFFFE] == 0x0A && port.mem[0xFFFF] == 0x79)
    }

    /// The whole cold start replayed: the boot loads, the TOD calibration (its NTSC outcome),
    /// the title and the display prompt (A), the mode prompt (B), the panel's initial state, the
    /// first load of the flight overlay at $2048, and ten seconds of flight. Every $204B must
    /// match the lab.
    @Test func coldBootReplay() throws {
        let data = try #require(Original.data)
        let session = try ReplaySessions.text("replay-coldboot")
        let r = try ReplayLab.record("coldboot", prefix: nil, session: session)
        let port = Machine.booting(blocks: data.disk.blocks)
        let report = ReplayLab.replay(r, on: port, from: .coldStart, frames: 2)
        ReplayLab.expectClean(r, report, minCheckpoints: 3)
    }

    /// The TOD calibration's count the port stores (`MainLoop.ntscCalibrationCount`) is the one
    /// the original measures on the lab's NTSC machine where it unmasks interrupts ($AB46), and
    /// it keeps the TOD on 60 Hz (`$DC0E` stays 0).
    @Test func todCalibrationCount() throws {
        let data = try #require(Original.data)
        let lab = Lab.boot(data)
        _ = lab.run(maxCycles: 200_000_000) { $0.cpu.pc == 0xAB46 }
        try #require(lab.cpu.pc == 0xAB46)
        let count = UInt16(lab.bus.ram[0xA5]) | UInt16(lab.bus.ram[0xA6]) << 8
        #expect(count == MainLoop.ntscCalibrationCount, "the lab counts \(hex16(Int(count)))")
        #expect(count < MainLoop.palCalibrationThreshold)
    }

    /// The prompts' other answers replayed from the handoff: a key the display prompt ignores,
    /// B (black and white), A at the mode prompt (demo, which the main loop's demo check then
    /// hands to the editor overlay).
    @Test func coldBootBlackAndWhiteDemo() throws {
        let data = try #require(Original.data)
        let session = try ReplaySessions.text("replay-coldboot-bw")
        let r = try ReplayLab.record("coldboot-bw", prefix: nil, session: session)
        let port = Machine.booting(blocks: data.disk.blocks)
        let report = ReplayLab.replay(r, on: port, from: .coldStart, frames: 2)
        ReplayLab.expectClean(r, report, minCheckpoints: 3)
        #expect(port.mem[0x0E69] == 0x00 && port.mem[0x0E61] == 0xFC, "the black-and-white palette")
        #expect(port.mem[MainLoop.RAM.demoRequest] != 0 || port.mem[MainLoop.RAM.currentMode] == 2, "demo mode")
    }

    /// The title screen as the port draws it (up to the display prompt's key wait) is the lab's:
    /// the window and panel bitmaps, and the frame presented with the game's split.
    @Test func titleScreen() throws {
        let data = try #require(Original.data)
        let lab = Lab.boot(data)
        _ = lab.run(maxCycles: 400_000_000) { $0.cpu.pc == 0x2268 }
        try #require(lab.cpu.pc == 0x2268)
        let original = lab.bus.ram
        let port = Machine.booting(blocks: data.disk.blocks)
        var image: [UInt8] = []
        port.pollHandler = { m in
            image = m.memoryImage
            m.abandonStack?(nil)
        }
        let ending = ProgramThread.run(port) { m in m.coldStart() }
        #expect(ending == .abandoned(nil))
        try #require(image.count == 0x10000)
        let d = (0x4000..<0x6000).filter { image[$0] != original[$0] }
        #expect(d.isEmpty, "\(d.count) bitmap bytes differ, first \(d.prefix(8).map { hex16($0) })")
        let fixedOriginal = ReplayLab.fixedSplit(original), fixedPort = ReplayLab.fixedSplit(image)
        let a = ReplayLab.present(original, colorRAM: lab.bus.colorRAM, view: fixedOriginal.view, panel: fixedOriginal.panel)
        let b = ReplayLab.present(image, colorRAM: port.io.colorRAM, view: fixedPort.view, panel: fixedPort.panel)
        #expect(zip(a, b).filter { $0 != $1 }.isEmpty)
        // The two rows the crack overwrote stay blank: nothing but the title, the version and the
        // prompt is drawn (rows 28-43 of the window are background).
        for row in 28..<44 {
            let base = Int(original[0x0200 + row]) << 8 | Int(original[0x02C8 + row])
            for column in 0..<40 { #expect(image[base + 8 * column] == 0, "row \(row) column \(column) is drawn") }
        }
        let url = Original.repoRoot.appendingPathComponent("build/testdata/coldinit-title.png")
        try? ImageWriter.writePNG(indices: b, width: VICPresenter.width, height: VICPresenter.height, scaleX: 2,
                                  scaleY: 2, to: url)
    }

    /// The init routines that do no waiting, on the flat bus: memory, cycles and the I/O stores.
    @Test func initRoutines() throws {
        let data = try #require(Original.data)
        let rig = FlatIORig(data.coldMemory)
        rig.run(0xABB0, "copyZeroPage") { $0.copyZeroPage() }
        rig.run(0xAB66, "copyPanelRow") { $0.copyPanelRow() }
        rig.run(0xAB88, "initUserLibrary") { $0.initUserLibrary() }
        rig.run(0xAA07, "patchRadioHooks") { $0.patchRadioHooks() }
        // $AA91 on the state after the display prompt (a color display chosen).
        rig.poke(0x0E69, 0x0B)
        rig.run(0xAA91, "initPanelState") { $0.initPanelState() }
        rig.run(0x25EB, "displayInit") { $0.displayInit() }
        rig.run(0xAB78, "maskInterrupts") { $0.maskInterrupts() }
        // The panel state from other values (the needles and markers at other places).
        var rng = TestRandom(seed: 0xAA91)
        for round in 0..<12 {
            for a in [0x1F, 0x20, 0x21, 0x0A84] { rig.poke(a, rng.byte() % 88) }
            for a in 0x0A93...0x0A9E { rig.poke(a, rng.byte() & 0x0F) }
            rig.poke(0x09A7, rng.byte() | 0x80)
            rig.run(0xAA91, "initPanelState \(round)") { $0.initPanelState() }
        }
        rig.expectClean("init routines")
    }
}

/// Original routines on the flat bus (`RoutineHarness`) against their ports on a twin image:
/// memory (stack and $D000-$DFFF aside), cycles, and the I/O stores, whose final values must be
/// the port's `io` registers (VIC, SID, color RAM, CIA2 port A).
final class FlatIORig {
    let harness: RoutineHarness
    let machine: Machine
    private(set) var failures: [String] = []
    private(set) var failureCount = 0
    private(set) var calls = 0
    private var vic = [UInt8](repeating: 0, count: 0x2F)
    private var sid = [UInt8](repeating: 0, count: 0x19)
    private var colorRAM = [UInt8](repeating: 0, count: 1024)

    init(_ ram: [UInt8]) {
        harness = RoutineHarness(ram: ram)
        machine = Machine(memory: ram)
        machine.diskBlocks = Original.diskBlocks
        machine.clock.cycles = 1_000_000
        // The flat bus reads I/O as RAM: the port reads the same bytes.
        machine.ioReadHook = { [unowned machine] address, _ in machine.mem[address] }
        colorRAM = machine.io.colorRAM
    }

    func poke(_ address: Int, _ value: UInt8) {
        harness.bus.ram[address] = value
        machine.mem[address] = value
    }

    func run(_ address: UInt16, _ label: @autoclosure () -> String, regs: RoutineHarness.Registers = .init(),
             port: (Machine) -> Void) {
        calls += 1
        harness.bus.ioWrites.removeAll(keepingCapacity: true)
        let o = harness.call(address, regs, maxCycles: 50_000_000)
        for w in harness.bus.ioWrites {
            let a = Int(w.address)
            switch a {
            case 0xD000..<0xD02F: if a != 0xD019 { vic[a - 0xD000] = w.value }
            case 0xD400..<0xD419: sid[a - 0xD400] = w.value
            case 0xD800..<0xDC00: colorRAM[a - 0xD800] = w.value & 0x0F
            default: break
            }
        }
        let start = machine.clock.cycles
        port(machine)
        let cycles = machine.clock.cycles - start
        var problems: [String] = []
        if !o.completed { problems.append("original did not return") }
        if cycles != o.cycles { problems.append("cycles \(cycles) want \(o.cycles)") }
        let regs = (0..<0x2F).filter { machine.io.vic[$0] != vic[$0] }
        if !regs.isEmpty { problems.append("VIC " + regs.prefix(4).map { String(format: "$D0%02X", $0) }.joined(separator: " ")) }
        if Array(machine.io.sid[0..<0x19]) != sid { problems.append("SID registers") }
        if machine.io.colorRAM != colorRAM { problems.append("color RAM") }
        let d = (0..<0x10000).filter { a in
            machine.mem[a] != harness.bus.ram[a] && !(0x100...0x1FF).contains(a) && !(0xD000...0xDFFF).contains(a)
        }
        if let first = d.first {
            problems.append("memory $\(hex16(first)) = \(hex(machine.mem[first])) want \(hex(harness.bus.ram[first])) (\(d.count) bytes)")
            for a in d { machine.mem[a] = harness.bus.ram[a] }
        }
        if !problems.isEmpty {
            failureCount += 1
            if failures.count < 12 { failures.append("\(label()): " + problems.joined(separator: ", ")) }
        }
    }

    func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let report = "\(what): \(failureCount) of \(calls) calls differ\n" + failures.joined(separator: "\n")
        #expect(failureCount == 0, "\(report)", sourceLocation: sourceLocation)
    }
}
