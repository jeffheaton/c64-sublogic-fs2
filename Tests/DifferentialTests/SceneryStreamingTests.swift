import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Block streaming and overlay loads against SubLogic's own loader running on the full lab
/// machine (the virtual 1541): the port's direct copies must leave the same memory — the
/// destination with the $C000 guard, the slot tags, the border counter and every byte the
/// loader leaves in zero page and its variables — and take about the same time.
@Suite(.serialized, .enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct SceneryStreamingTests {
    /// The lab machine in regular flight, shared by the tests of this suite (each call
    /// substitutes the RAM image; the suite is serialized).
    nonisolated(unsafe) static let harness = Result { try Original.machineHarness() }

    /// The port's machine on `ram`, with the VIC registers the lab machine has.
    static func machine(_ ram: [UInt8], _ h: MachineHarness) -> Machine {
        let m = Machine(memory: ram)
        m.diskBlocks = Original.diskBlocks
        for r in 0..<0x2F { m.io.vic[r] = h.machine.bus.vicRegs[r] }
        return m
    }

    /// Compares the port with the original after one call: memory (stack page excluded), the
    /// VIC registers the routine writes, and the cycles (within `tolerance`, a fraction).
    static func compare(_ label: String, _ h: MachineHarness, _ r: RoutineHarness.Result, _ m: Machine,
                        cycles: UInt64, tolerance: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.completed, "\(label): the original did not return", sourceLocation: sourceLocation)
        let diffs = Original.differences(m.memoryImage, h.machine.bus.ram)
        let listed = diffs.prefix(16).map {
            String(format: "$%04X port %02X original %02X", $0, m.mem[$0], h.machine.bus.ram[$0])
        }.joined(separator: ", ")
        #expect(diffs.isEmpty, "\(label): \(diffs.count) bytes differ: \(listed)", sourceLocation: sourceLocation)
        for reg in [0x15, 0x16, 0x18, 0x20] {
            #expect(m.io.vic[reg] == h.machine.bus.vicRegs[reg],
                    "\(label): $D0\(String(format: "%02X", reg)) port \(hex(m.io.vic[reg])) original \(hex(h.machine.bus.vicRegs[reg]))",
                    sourceLocation: sourceLocation)
        }
        let ratio = Double(cycles) / Double(max(r.cycles, 1))
        #expect(abs(ratio - 1) <= tolerance, "\(label): \(cycles) cycles, the original \(r.cycles)",
                sourceLocation: sourceLocation)
    }

    /// Block cache loads ($E58F) of every scenery area and detail block group: the six-block
    /// areas run into the $C000 guard, the WWI area and detail slots, destinations at and above
    /// $C000 (nothing stored), the higher slots zeroed, and various states of the loader's serial
    /// flags `$BA`/`$BC` before the load. A request for the block already in its slot reads
    /// nothing (exact cycles).
    @Test func blockLoads() throws {
        let h = try Self.harness.get()
        let base = h.machine.bus.ram
        var rng = TestRandom(seed: 0xE58F)
        let cases: [(block: Int, count: Int, destination: Int, slot: Int)] = [
            (68, 6, 0xA887, 0), (52, 6, 0xA887, 0), (80, 6, 0xA887, 0), (112, 6, 0xA887, 0), (92, 6, 0xA887, 0),
            (102, 5, 0xA887, 0), (118, 5, 0xA887, 0), (58, 6, 0xA887, 0), (48, 4, 0xA887, 0),
            (74, 2, 0xBA2F, 1), (76, 1, 0xBA2F, 1), (78, 1, 0xBA2F, 1), (86, 2, 0xBB2A, 1), (89, 1, 0xBB2A, 1),
            (98, 1, 0xBC0E, 1), (110, 1, 0xBC0E, 1), (123, 2, 0xBA0F, 1), (126, 2, 0xBA0F, 1),
            (0, 1, 0xBF00, 2), (163, 1, 0xC000, 3), (66, 1, 0xD800, 0), (40, 3, 0x6000, 1),
        ]
        for (n, c) in cases.enumerated() {
            var ram = base
            ram[0x08FB] = UInt8(c.block); ram[0x08FC] = UInt8(c.count)
            ram[0x08FD] = UInt8(c.destination & 0xFF); ram[0x08FE] = UInt8(c.destination >> 8)
            ram[0x08FF] = UInt8(c.slot)
            for k in 0..<4 { ram[0x0900 + k] = UInt8(1 + rng.scnBelow(200)) }
            ram[0x0900 + c.slot] = UInt8(c.block) &+ 1
            ram[0xBA] = [0x55, 0xAA, 0x80, 0x00, 0xFF, 0x2A][n % 6]
            ram[0xBC] = [0x55, 0xFF, 0x7F, 0x00, 0x80, 0x13][(n / 2) % 6]
            ram[0x0E88] = UInt8(rng.scnBelow(256))
            let m = Self.machine(ram, h)
            let r = h.call(0xE58F, ram: ram)
            let start = m.clock.cycles
            m.loadBlockCached()
            Self.compare("block \(c.block) x\(c.count) to \(hex16(c.destination))", h, r, m,
                         cycles: m.clock.cycles - start, tolerance: 0.01)
        }
        // The block already in its slot.
        var ram = base
        ram[0x08FB] = ram[0x0901]; ram[0x08FF] = 1
        let m = Self.machine(ram, h)
        let r = h.call(0xE58F, ram: ram)
        m.loadBlockCached()
        Self.compare("cached block", h, r, m, cycles: m.clock.cycles, tolerance: 0)
    }

    /// The loader's parts one by one, for the cycle model: `loaderOpen`, `loaderRead` and
    /// `loaderClose` against $7306, $7309 and $730F (sprites off as the game has them).
    @Test func loaderTiming() throws {
        let h = try Self.harness.get()
        for block in [2, 40, 66, 68, 100, 130, 160] {
            var ram = h.machine.bus.ram
            ram[0x731C] = UInt8(block); ram[0x731E] = 0x00; ram[0x731F] = 0x60; ram[0x7327] = 1
            h.machine.bus.vicRegs[0x15] = 0
            var m = Self.machine(ram, h)
            var r = h.call(0x7306, ram: ram)
            var start = m.clock.cycles
            m.loaderOpen()
            // The open varies with the raster phase (badlines) by a few percent.
            Self.compare("open (block \(block))", h, r, m, cycles: m.clock.cycles - start, tolerance: 0.03)
            ram = h.machine.bus.ram
            m = Self.machine(ram, h)
            r = h.call(0x7309)
            start = m.clock.cycles
            m.loaderRead()
            print("loaderTiming: block \(block) read: port \(m.clock.cycles - start), lab \(r.cycles)")
            Self.compare("read block \(block)", h, r, m, cycles: m.clock.cycles - start, tolerance: 0.005)
            ram = h.machine.bus.ram
            m = Self.machine(ram, h)
            r = h.call(0x730F)
            start = m.clock.cycles
            m.loaderClose()
            Self.compare("close (block \(block))", h, r, m, cycles: m.clock.cycles - start, tolerance: 0.005)
            ram = h.machine.bus.ram
            m = Self.machine(ram, h)
            r = h.call(0xE6D2)
            start = m.clock.cycles
            m.cacheHelper()
            Self.compare("cacheHelper (block \(block))", h, r, m, cycles: m.clock.cycles - start, tolerance: 0.005)
        }
        h.machine.bus.vicRegs[0x15] = 0x0F
    }

    /// The data stores of a read as time passes: SubLogic's loader on the lab's 1541 stores each
    /// byte as it comes from the drive (about every 1,296 cycles, after some 50,000 for the "U1"
    /// command and the status), and so does the port (`Scenery.Loader.sector*Cycles`), with the
    /// VIC's DMA on both sides (the lab's in flight, the port's `vicDMA` with the same registers):
    /// every byte lands within 3,000 cycles of the lab's store (measured: at most about 2,300, the
    /// sector constant being fitted over blocks 2-160 drifts a few hundred cycles a sector), and
    /// the read takes the lab's time within 0.5%. With the drive's part as wall time (`elapse`),
    /// the DMA does not count twice.
    @Test func loaderByteSchedule() throws {
        let h = try Self.harness.get()
        for block in [2, 66, 130] {
            var ram = h.machine.bus.ram
            ram[0x731C] = UInt8(block); ram[0x731E] = 0x00; ram[0x731F] = 0x60; ram[0x7327] = 1
            h.machine.bus.vicRegs[0x15] = 0
            _ = h.call(0x7306, ram: ram)
            ram = h.machine.bus.ram
            // The cycle of every step of the pointer `$C2/$C3` that stores a data byte: one up, or
            // the low byte wrapping (the status reads move it to $7579 and back, the read's start
            // loads it).
            func stored(_ p: Int, after last: Int) -> Bool {
                (0x6000...0x6400).contains(p) && (p == last + 1 || (last & 0xFF == 0xFF && p == last - 0xFF))
            }
            var labStores: [UInt64] = []
            var last = Int(ram[0xC2]) | Int(ram[0xC3]) << 8
            let cpu = h.machine.cpu
            var start: UInt64?
            h.machine.onInstruction = { [unowned h] _ in
                if start == nil { start = cpu.cycles }
                let p = Int(h.machine.bus.ram[0xC2]) | Int(h.machine.bus.ram[0xC3]) << 8
                guard p != last else { return }
                if stored(p, after: last) { labStores.append(cpu.cycles - start!) }
                last = p
            }
            let r = h.call(0x7309)
            h.machine.onInstruction = nil
            // The port, sampled every cycle by an event handler.
            let m = Self.machine(ram, h)
            m.clock.cycles = 10 * VirtualClock.cyclesPerFrame
            m.vicDMA = true
            var portStores: [UInt64] = []
            let portStart = m.clock.cycles
            var portLast = Int(ram[0xC2]) | Int(ram[0xC3]) << 8
            m.nextEventCycle = portStart + 1
            m.eventHandler = { mm in
                // The port moves the pointer and stores between two cycles: a wrap shows as $xx00
                // of the next page.
                let p = Int(mm[0xC2]) | Int(mm[0xC3]) << 8
                if p != portLast {
                    if stored(p, after: portLast) || (portLast & 0xFF == 0xFF && p == portLast + 1) {
                        portStores.append(mm.clock.cycles - 1 - portStart)
                    }
                    portLast = p
                }
                mm.nextEventCycle = mm.clock.cycles + 1
            }
            m.loaderRead()
            m.eventHandler = nil
            let portCycles = m.clock.cycles - portStart
            #expect(labStores.count == 1024 && portStores.count == 1024,
                    "block \(block): \(labStores.count) stores in the lab, \(portStores.count) in the port")
            let deviations = zip(portStores, labStores).map { abs(Int($0) - Int($1)) }
            let worst = deviations.enumerated().max { $0.element < $1.element }
            print("loaderByteSchedule: block \(block): read \(portCycles) cycles (lab \(r.cycles)), "
                  + "worst byte \(worst?.offset ?? -1) off by \(worst?.element ?? -1)")
            #expect((worst?.element ?? .max) <= 3_000, "block \(block): byte \(worst?.offset ?? -1) stored \(worst?.element ?? -1) cycles away from the lab's")
            #expect(abs(Double(portCycles) / Double(r.cycles) - 1) <= 0.005,
                    "block \(block): \(portCycles) cycles, the lab \(r.cycles)")
        }
        h.machine.bus.vicRegs[0x15] = 0x0F
    }

    /// The serial flags `$BA`/`$BC` the loader rotates on every transfer, from random states
    /// (both bytes are also other routines' scratch: `$BA` a table pointer, `$BC` the windmill
    /// RPM): the open and the close, the close flushing a byte still buffered (`$BA` bit 7) as
    /// after the editor's library load. Memory exact; the time within 10% (a set `$BC` bit 7
    /// sends the first bytes with the EOI handshake, a few thousand cycles more). A read always
    /// follows an open, which leaves the flags settled (`blockLoads`).
    @Test func serialFlagStates() throws {
        let h = try Self.harness.get()
        var rng = TestRandom(seed: 0x7688)
        h.machine.bus.vicRegs[0x15] = 0
        for round in 0..<64 {
            var ram = h.machine.bus.ram
            ram[0xBA] = UInt8(rng.scnBelow(256)); ram[0xBC] = UInt8(rng.scnBelow(256))
            ram[0x731C] = UInt8(rng.scnBelow(164)); ram[0x731E] = 0x00; ram[0x731F] = 0x60; ram[0x7327] = 1
            let entry: UInt16 = round % 2 == 0 ? 0x7306 : 0x730F
            let m = Self.machine(ram, h)
            let r = h.call(entry, ram: ram)
            if entry == 0x7306 { m.loaderOpen() } else { m.loaderClose() }
            Self.compare("\(hex16(Int(entry))) with $BA \(hex(ram[0xBA])) $BC \(hex(ram[0xBC]))", h, r, m,
                         cycles: m.clock.cycles, tolerance: 0.10)
        }
        h.machine.bus.vicRegs[0x15] = 0x0F
    }

    /// Overlay loads through the trampolines: each overlay, then the root block 66 at its end
    /// address (with the editor at $BC6B, the guard drops the part from $C000), the slot tags
    /// cleared. The editor with an invalid cache (`$08BC` = 2) loads without the cache copy.
    @Test func overlayLoads() throws {
        let h = try Self.harness.get()
        let base = h.machine.bus.ram
        for overlay in Machine.Overlay.allCases {
            var ram = base
            if overlay == .editor { ram[0x08BC] = 2 }
            let entry: UInt16 = [0xE5C0, 0xE5C9, 0xE5DB, 0xE5E4, 0xE5ED][overlay.rawValue]
            let m = Self.machine(ram, h)
            let r = h.call(entry, ram: ram)
            m.loadOverlay(overlay)
            Self.compare("overlay \(overlay)", h, r, m, cycles: m.clock.cycles, tolerance: 0.01)
        }
    }

    /// The editor's first entry (`$08BC` = 0): blocks 42-47 to $A7E0, the copy to the cache at
    /// $D000 ($E6D8, `$01` = $30: RAM under the I/O), then the root block at $BC6B (the part from
    /// $C000 dropped). The RAM image's byte 0 is set to the CPU port's direction register as the
    /// lab boots it ($2F): `MachineHarness.call` takes the port registers from the image, and
    /// with the image's 0 there every port bit reads high and the copy would land in the I/O.
    @Test func editorFirstLoad() throws {
        let h = try Self.harness.get()
        var ram = h.machine.bus.ram
        ram[0x08BC] = 0
        ram[0x0000] = 0x2F
        let m = Self.machine(ram, h)
        let r = h.call(0xE5C9, ram: ram, maxCycles: 40_000_000)
        m.loadOverlay(.editor)
        Self.compare("editor first load", h, r, m, cycles: m.clock.cycles, tolerance: 0.01)
        #expect(m.mem[0xBC6B] == Original.diskBlocks[66][0], "the root block at the editor's end")
        #expect(m.mem[0xD000] == Original.diskBlocks[42][0], "the editor's copy in the cache")
    }

    /// Whole scenery passes ($8006) that stream: from Meigs the eye moves into another area, so
    /// the root list loads the area (slot 0, the higher slots invalidated) and the area list its
    /// detail block (slot 1), all inside the pass; then a second pass with everything cached.
    @Test func passesThatStream() throws {
        let h = try Self.harness.get()
        for (north, east) in [(-982, -10585), (650, 4681), (859, 194), (1000, -9000)] {
            var ram = try SCN.regular()
            ram[0x8B] = ram[0xA7E0]; ram[0x8C] = ram[0xA7E1]      // as $E565 leaves it
            ram[0x64] = UInt8(north & 0xFF); ram[0x65] = UInt8((north >> 8) & 0xFF)
            ram[0x5C] = UInt8(east & 0xFF); ram[0x5D] = UInt8((east >> 8) & 0xFF)
            ram[0x60] = 2; ram[0x61] = 0
            for k in 0..<2 {
                ram[0x8B] = ram[0xA7E0]; ram[0x8C] = ram[0xA7E1]
                let m = Self.machine(ram, h)
                let r = h.call(0x8006, ram: ram)
                m.charge(3)
                do { try m.runScenery() } catch { Issue.record("\(error)") }
                // The full lab machine adds the badline and sprite DMA stalls to the drawing (the
                // port's routines charge the instructions' cycles; `SceneryPassTests` compares
                // those exactly), so the whole pass is compared within 8%.
                Self.compare("pass \(k) at (\(north), \(east))", h, r, m, cycles: m.clock.cycles, tolerance: 0.08)
                ram = h.machine.bus.ram
            }
        }
    }

    /// The loader's walk over the sector-usage mask ($74DC: the first sector of a block; $7542:
    /// the next one), exact in memory and cycles for every block (no I/O: the flat harness).
    @Test func sectorWalk() throws {
        let rig = SCN.rig(try SCN.regular())
        for block in 0..<164 {
            rig.poke(0x731C, UInt8(block))
            rig.run(0x74DC, .init(), "first sector of block \(block)") { m in
                m.charge(m.loaderFindFirstSector()); return .init(carry: false)
            }
            for k in 1..<4 {
                rig.run(0x7542, .init(), "sector \(k) of block \(block)") { m in
                    m.charge(m.loaderNextSector()); return .init(carry: false)
                }
            }
        }
        rig.expectCleanSCN("sector walk")
    }

    /// The editor cache: the copy $E6D8 and the swap $E6DB (no I/O: the flat harness), with the
    /// window and the cache holding different data; the editor trampoline with `$08BC` = 1
    /// swaps instead of loading.
    @Test func editorCache() throws {
        var ram = try SCN.regular()
        var rng = TestRandom(seed: 0xE6DB)
        for a in 0xD000..<0xE500 { ram[a] = UInt8(rng.scnBelow(256)) }
        let rig = SCN.rig(ram)
        rig.run(0xE6D8, .init(), "copy") { m in m.swapEditorCacheIn(); return .init() }
        for a in 0xA7E0..<0xBCE0 where rng.scnBelow(3) == 0 { rig.poke(a, UInt8(rng.scnBelow(256))) }
        rig.run(0xE6DB, .init(), "swap") { m in m.swapEditorCache(); return .init() }
        rig.run(0xE6DB, .init(), "swap back") { m in m.swapEditorCache(); return .init() }
        rig.poke(0x08BC, 1)
        rig.run(0xE5C9, .init(), "editor from the cache") { m in m.loadOverlay(.editor); return .init() }
        rig.expectCleanSCN("editor cache")
    }

    /// `setSceneryRoot` ($E565): the PC from the overlay's end word; the protection check that
    /// follows it in the original is not ported, but its pass-through time is kept.
    @Test func sceneryRoot() throws {
        let rig = SCN.rig(try SCN.regular())
        for end in [0xA800, 0xBC6B, 0xB1EA, 0xA878, 0xAD00] {
            rig.poke16(0xA7E0, UInt16(end))
            rig.run(0xE565, .init(), "root \(hex16(end))") { m in m.setSceneryRoot(); return .init() }
        }
        rig.expectCleanSCN("scenery root")
    }
}
