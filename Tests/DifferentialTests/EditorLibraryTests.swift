import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// The mode library on disk against the original's own disk path on the full lab machine (the
/// virtual 1541 holding the game disk): CTRL-X reads logical block 64 (on the master disk the
/// database-info overlay) into $C800; CTRL-Z formats the disk (a DOS "N0:" command) and
/// writes $C800 back as block 64. The port serves both from `ModeLibrary.InMemoryStore` and
/// must leave the same memory — the library, the reloaded mode and the reprinted page, and every
/// byte the loader leaves in zero page and its variables — the same VIC registers and color RAM,
/// and take about the same time (the lab adds badline DMA to everything).
@Suite(.serialized, .enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct EditorLibraryTests {
    /// One lab machine for the whole suite (the format wipes its disk, so the tests run in one
    /// order: loads first, then the format and save, then the loads of the saved block).
    nonisolated(unsafe) static let harness = Result { try Original.machineHarness() }

    /// Keys for the original on the full machine: the trap at $226B stores the next key | $80
    /// into `$08C4` (as `ScriptedKeys` does on the flat bus); an exhausted script answers E.
    final class MachineKeys {
        private var keys: [UInt8]
        private(set) var delivered = 0
        init(_ keys: String) { self.keys = Array(keys.utf8) }

        func attach(to h: MachineHarness) {
            let bus = h.machine.bus
            h.machine.cpu.traps[0x226B] = true
            h.machine.cpu.trapHandler = { [self, bus] pc in
                if pc == 0x226B, bus.ram[0x08C4] & 0x80 == 0 {
                    bus.ram[0x08C4] = (keys.isEmpty ? 0x45 : keys.removeFirst()) | 0x80
                    delivered += 1
                }
                return false
            }
        }

        static func detach(from h: MachineHarness) {
            h.machine.cpu.traps[0x226B] = false
            h.machine.cpu.trapHandler = nil
        }
    }

    /// The port's machine on `ram` with the lab machine's VIC registers, color RAM and VIC bank.
    static func machine(_ ram: [UInt8], _ h: MachineHarness) -> Machine {
        let m = Machine(memory: ram)
        m.diskBlocks = Original.diskBlocks
        for r in 0..<0x2F { m.io.vic[r] = h.machine.bus.vicRegs[r] }
        m.io.colorRAM = h.machine.bus.colorRAM
        m.io.cia2PortA = 0x94 | UInt8(3 - h.machine.bus.vicBank / 0x4000)
        return m
    }

    /// What differs between the port and the lab machine after a call: memory (stack page
    /// excluded), the VIC registers the game writes, the color RAM, the VIC bank, and the time
    /// (within `tolerance`, a fraction).
    static func differences(_ m: Machine, _ h: MachineHarness, _ r: RoutineHarness.Result, cycles: UInt64,
                            tolerance: Double) -> [String] {
        var out: [String] = []
        if !r.completed { out.append("the original did not return") }
        let diffs = Original.differences(m.memoryImage, h.machine.bus.ram)
        if !diffs.isEmpty {
            out.append("\(diffs.count) bytes differ: " + diffs.prefix(12).map {
                String(format: "$%04X port %02X lab %02X", $0, m.mem[$0], h.machine.bus.ram[$0])
            }.joined(separator: ", "))
        }
        for reg in [0x11, 0x15, 0x16, 0x18, 0x20, 0x21] where m.io.vic[reg] != h.machine.bus.vicRegs[reg] {
            out.append(String(format: "$D0%02X port %02X lab %02X", reg, m.io.vic[reg], h.machine.bus.vicRegs[reg]))
        }
        let cells = (0..<1000).filter { m.io.colorRAM[$0] & 0x0F != h.machine.bus.colorRAM[$0] & 0x0F }
        if !cells.isEmpty { out.append("\(cells.count) color RAM cells differ") }
        if VICState.bank(fromDD00: m.io.cia2PortA) != h.machine.bus.vicBank { out.append("VIC bank differs") }
        let ratio = Double(cycles) / Double(max(r.cycles, 1))
        if abs(ratio - 1) > tolerance { out.append("\(cycles) cycles, the lab \(r.cycles)") }
        return out
    }

    /// Runs the editor ($B09A) with `keys` on the lab machine and on the port (library in
    /// `store`), from `ram`. Returns the differences and the port's machine.
    static func runEditor(_ h: MachineHarness, _ ram: [UInt8], keys: String, store: ModeLibrary.InMemoryStore)
        -> (problems: [String], machine: Machine) {
        runEditor(h, ram, keys: keys, io: store.io)
    }

    /// The lab's library disk as the port sees it: CTRL-X reads what is on it; CTRL-Z puts the
    /// block there as the lab's 1541 stores it. SubLogic sends each sector's bytes 1-255 first and
    /// byte 0 last, for a 1541 whose direct-access buffer pointer is 1 after the open; the lab's
    /// drive behaves that way, so the block lands unrotated.
    final class LabDisk {
        private(set) var block: [UInt8]
        init(holding saved: [UInt8]) { block = Self.rotated(saved) }
        static func rotated(_ saved: [UInt8]) -> [UInt8] { saved }
        var io: ModeLibrary.IO {
            ModeLibrary.IO(load: { [self] in block }, formatAndSave: { [self] data in
                block = Self.rotated(data)
                return true
            })
        }
    }

    static func runEditor(_ h: MachineHarness, _ ram: [UInt8], keys: String, io: ModeLibrary.IO)
        -> (problems: [String], machine: Machine) {
        var ram = ram
        ram[0x0E6B] = 0
        let m = machine(ram, h)
        m.modeLibraryIO = io
        let port = ScriptedKeys(keys)
        port.installPollHandler(on: m)
        let original = MachineKeys(keys)
        original.attach(to: h)
        let r = h.call(Editor.entry, ram: ram, maxCycles: 400_000_000)
        MachineKeys.detach(from: h)
        m.editorEntry()
        var problems = differences(m, h, r, cycles: m.clock.cycles, tolerance: 0.10)
        if original.delivered != port.delivered {
            problems.append("keys used: port \(port.delivered), lab \(original.delivered)")
        }
        return (problems, m)
    }

    static let ctrlX = "\u{18}", ctrlZ = "\u{1A}"

    /// The loader's DOS command ($7312) and block write ($730C) as the lab's 1541 answers them,
    /// against the port's model; prints the measured times (`ModeLibrary.Timing`).
    static func measure(_ h: MachineHarness, _ base: [UInt8]) -> [String] {
        var problems: [String] = []
        var ram = base
        ram[0x7327] = 0
        h.machine.bus.vicRegs[0x15] = 0                     // sprites off, as in the editor
        h.machine.bus.vicRegs[0x11] = 0x1B
        // Open, then the DOS command.
        var r = h.call(0x7306, ram: ram)
        var m = machine(h.machine.bus.ram, h)
        let afterOpen = h.machine.bus.ram
        r = h.call(0x7312)
        m.loaderDosCommand()
        let dos = r.cycles
        problems += differences(m, h, r, cycles: m.clock.cycles, tolerance: 0.05).map { "DOS command: \($0)" }
        // The block write of $C800 as block 64.
        ram = h.machine.bus.ram
        ram[0x731C] = 0x40; ram[0x731E] = 0x00; ram[0x731F] = 0xC8
        m = machine(ram, h)
        r = h.call(0x730C, ram: ram)
        m.loaderWriteBlock()
        let write = r.cycles
        problems += differences(m, h, r, cycles: m.clock.cycles, tolerance: 0.05).map { "block write: \($0)" }
        // The close.
        ram = h.machine.bus.ram
        m = machine(ram, h)
        r = h.call(0x730F, ram: ram)
        m.loaderClose()
        problems += differences(m, h, r, cycles: m.clock.cycles, tolerance: 0.05).map { "close: \($0)" }
        print("EditorLibraryTests.measure: open \(afterOpen.count > 0 ? "ok" : "-"), DOS command \(dos), block write \(write)")
        h.machine.bus.vicRegs[0x15] = 0x0F
        h.machine.bus.vicRegs[0x11] = 0x3B
        return problems
    }

    @Test func libraryDisk() throws {
        let h = try Self.harness.get()
        let entry = try D2.state("d2-ed-entry")
        let block64 = Original.diskBlocks[64]
        // 1. CTRL-X with the master disk: block 64 (overlay 4) into $C800; the mode reloads.
        for (mode, keys) in [(UInt8(0), Self.ctrlX + "E"), (12, Self.ctrlX + "E"), (24, "\r\r" + Self.ctrlX + "\r1" + Self.ctrlX + "E"),
                             (10, Self.ctrlX + "+" + "S" + "E")] {
            var ram = entry
            ram[0x0963] = mode
            ram[0x09A5] = mode
            let store = ModeLibrary.InMemoryStore(block: block64)
            let (problems, m) = Self.runEditor(h, ram, keys: keys, store: store)
            #expect(problems.isEmpty, "CTRL-X in mode \(mode): \(problems.joined(separator: "; "))")
            #expect(store.loads == keys.filter { $0 == "\u{18}" }.count && store.saves == 0)
            #expect(Array((0xC800..<0xCC00).map { m.mem[$0] }) == block64 || mode == 10, "the block at $C800")
        }
        // 2. The library session: S, USER MODE 111, '+', CTRL-X, then CTRL-Z (format + save).
        let store = ModeLibrary.InMemoryStore(block: block64)
        let (problems, m) = Self.runEditor(h, entry, keys: "S" + "111\r" + "+" + Self.ctrlX + Self.ctrlZ + "E", store: store)
        #expect(problems.isEmpty, "library session: \(problems.joined(separator: "; "))")
        #expect(store.saves == 1 && store.block == Array((0xC800..<0xCC00).map { m.mem[$0] }), "the saved block")
        // 3. CTRL-X again: the lab reads back the block it wrote to the formatted disk; given what
        // the lab's disk holds, the port's load must leave exactly the lab's memory.
        let saved = try #require(store.block)
        let labDisk = ModeLibrary.InMemoryStore(block: LabDisk.rotated(saved))
        var ram = entry
        ram[0x0963] = 11
        let (again, m2) = Self.runEditor(h, ram, keys: Self.ctrlX + "E", store: labDisk)
        #expect(again.isEmpty, "CTRL-X after the save: \(again.joined(separator: "; "))")
        #expect(Array((0xC800..<0xCC00).map { m2.mem[$0] }) == labDisk.block!)
        // The port's own round trip is exact.
        let roundTrip = Machine(memory: entry)
        roundTrip.diskBlocks = Original.diskBlocks
        roundTrip.modeLibraryIO = store.io
        ScriptedKeys(Self.ctrlX + "E").installPollHandler(on: roundTrip)
        roundTrip.editorEntry()
        #expect(Array((0xC800..<0xCC00).map { roundTrip.mem[$0] }) == saved)
        // 4. CTRL-Z alone, from a state whose library holds random records.
        var rng = TestRandom(seed: 0xB223)
        ram = entry
        for a in 0xC800..<0xCC00 { ram[a] = rng.byte() }
        let store2 = ModeLibrary.InMemoryStore()
        let (save, m3) = Self.runEditor(h, ram, keys: Self.ctrlZ + Self.ctrlZ + "E", store: store2)
        #expect(save.isEmpty, "CTRL-Z twice: \(save.joined(separator: "; "))")
        #expect(store2.saves == 2 && store2.block == Array((0xC800..<0xCC00).map { m3.mem[$0] }))
        // 5. The library keys in the middle of a field and on page 1: CTRL-X reprints the page
        // over typed digits (the typed buffer and `$094F` stay, so the RETURN that follows
        // accepts the screen as reprinted); CTRL-Z with digits typed; CTRL-Z then CTRL-X in one
        // visit. The lab's disk now holds the last block step 4 saved; the port's store stands
        // for that disk.
        let lab = LabDisk(holding: try #require(store2.block))
        for (mode, keys) in [(UInt8(11), String(repeating: "\r", count: 24) + "34" + Self.ctrlX + "\r" + "E"),
                             (12, String(repeating: "\r", count: 22) + Self.ctrlX + "5" + Self.del + "E"),
                             (0, "1" + Self.ctrlZ + "\r" + "E"),
                             (13, "-" + "7" + Self.ctrlZ + Self.ctrlX + "E"),
                             (24, String(repeating: "\r", count: 30) + "9" + Self.ctrlZ + "-" + Self.ctrlX + "E")] {
            ram = entry
            ram[0x0963] = mode
            ram[0x09A5] = mode
            let (problems, _) = Self.runEditor(h, ram, keys: keys, io: lab.io)
            let shown = keys.replacingOccurrences(of: "\r", with: "⏎").replacingOccurrences(of: Self.ctrlX, with: "^X")
                .replacingOccurrences(of: Self.ctrlZ, with: "^Z").replacingOccurrences(of: Self.del, with: "⌫")
            #expect(problems.isEmpty, "mode \(mode) keys \(shown): \(problems.joined(separator: "; "))")
        }
        // 6. The loader's parts on their own (times printed for `ModeLibrary.Timing`).
        let parts = Self.measure(h, entry)
        #expect(parts.isEmpty, "\(parts.joined(separator: "\n"))")
    }

    static let del = "\u{08}"

    /// CTRL-X reads the library block with `loaderRead(data:)`, the loader's read with the block
    /// the drive returns given: the game disk (`diskBlocks`) is never touched, even when it has no
    /// block 64, and the memory is that of the loader reading the same block from the disk.
    @Test func libraryReadLeavesTheGameDiskAlone() throws {
        let entry = try D2.state("d2-ed-entry")
        var rng = TestRandom(seed: 0x4040)
        let library = (0..<ModeLibrary.blockSize).map { _ in rng.byte() }
        // The read of a given block is the read of that block from the disk.
        let given = Machine(memory: entry), fromDisk = Machine(memory: entry)
        fromDisk.diskBlocks = Original.diskBlocks
        fromDisk.diskBlocks[64] = library
        for m in [given, fromDisk] {
            m.mem[Scenery.Loader.block] = ModeLibrary.libraryBlock
            m.setU16(Scenery.Loader.destination, 0xC800)
            m.mem[Scenery.Loader.guardFlag] = 0
        }
        given.loaderRead(data: library)
        fromDisk.loaderRead()
        #expect(given.memoryImage == fromDisk.memoryImage && given.clock.cycles == fromDisk.clock.cycles)
        #expect(given.diskBlocks.isEmpty)
        // CTRL-X with a game disk that ends before block 64, and with the whole disk.
        var images: [[UInt8]] = []
        for blocks in [Array(Original.diskBlocks.prefix(64)), Original.diskBlocks] {
            let m = Machine(memory: entry)
            m.diskBlocks = blocks
            let store = ModeLibrary.InMemoryStore(block: library)
            m.modeLibraryIO = store.io
            ScriptedKeys(Self.ctrlX + "E").installPollHandler(on: m)
            m.editorEntry()
            #expect(store.loads == 1)
            #expect(m.diskBlocks == blocks, "the game disk is untouched")
            #expect(Array((0xC800..<0xCC00).map { m.mem[$0] }) == library, "the library at $C800")
            images.append(m.memoryImage)
        }
        #expect(images[0] == images[1])
    }

    /// The masked-IRQ window: the interrupt flag is set while CTRL-X and CTRL-Z (success and disk
    /// error) run with interrupts masked, scheduler events keep running for pacing during it, and
    /// it is clear once the editor goes back to its key wait.
    @Test func interruptWindow() throws {
        let entry = try D2.state("d2-ed-entry")
        for (keys, failing) in [(Self.ctrlX + "E", false), (Self.ctrlZ + "E", false), (Self.ctrlX + "E", true),
                                (Self.ctrlZ + "E", true)] {
            let m = Machine(memory: entry)
            m.diskBlocks = Original.diskBlocks
            let store = ModeLibrary.InMemoryStore(block: Original.diskBlocks[64])
            store.failing = failing
            m.modeLibraryIO = store.io
            ScriptedKeys(keys).installPollHandler(on: m)
            var masked = 0, unmasked = 0, activeAtWait = false
            let previous = m.pollHandler
            m.pollHandler = { mm in
                if mm.interruptDisable { activeAtWait = true }
                previous?(mm)
            }
            let period: UInt64 = 17_045
            m.nextEventCycle = m.clock.cycles + period
            m.eventHandler = { mm in
                if mm.interruptDisable { masked += 1 } else { unmasked += 1 }
                mm.nextEventCycle += period
            }
            m.editorEntry()
            let label = "\(keys == Self.ctrlX + "E" ? "CTRL-X" : "CTRL-Z")\(failing ? " (no disk)" : "")"
            #expect(masked > (failing ? 2 : 50), "\(label): \(masked) events in the window")
            #expect(unmasked > 0 && !activeAtWait && !m.interruptDisable, "\(label): the window closes")
        }
    }

    /// No library disk (the store fails, or no hook at all): both keys show the disk-error line
    /// on row 24 and the editor goes on; nothing is loaded or saved; the open's status reads
    /// "74,DRIVE NOT READY".
    @Test func noLibraryDisk() throws {
        let entry = try D2.state("d2-ed-entry")
        for keys in [Self.ctrlX + "E", Self.ctrlZ + "E", Self.ctrlX + "\r12E"] {
            for hooked in [true, false] {
                let m = Machine(memory: entry)
                m.diskBlocks = Original.diskBlocks
                let store = ModeLibrary.InMemoryStore()
                store.failing = true
                if hooked { m.modeLibraryIO = store.io }
                ScriptedKeys(keys).installPollHandler(on: m)
                // Stop at the first wait after the library key to look at the screen.
                var rowSeen: [UInt8] = []
                let previous = m.pollHandler
                m.pollHandler = { mm in
                    if rowSeen.isEmpty, mm[0x7325] == 0x74 {
                        rowSeen = (0..<40).map { mm[0x07C0 + $0] }
                    }
                    previous?(mm)
                }
                m.editorEntry()
                let text = String(decoding: rowSeen.map { $0 >= 0x41 && $0 <= 0x5A || $0 == 0x20 || $0 == 0x2A || $0 == 0x2F ? $0 : 0x3F }, as: UTF8.self)
                #expect(text.contains("READ/WRITE"), "row 24: '\(text)'")
                #expect(Array((0xC800..<0xCC00).map { m.mem[$0] }) == Array(entry[0xC800..<0xCC00]), "the library is untouched")
                #expect(m.mem[0x7325] == 0x74 && m.mem[0x7579] == 0x37 && m.mem[0x757A] == 0x34)
                if hooked { #expect(store.loads + store.saves == 1) }
            }
        }
    }
}
