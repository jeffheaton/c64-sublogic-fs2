import C64Kit
import Foundation
import FS2Core
@testable import FS2LabKit
import M6502
import Testing

/// The game program's routines against the original: the raster IRQ $2285 (both phases) and the
/// alternate IRQ $2304 on the full lab machine (keyboard scan, pattern player, VIC writes), the 10
/// Hz tick $2348 and the poll $2330 on the flat bus, and whole main-loop passes $204B → $204B on
/// the full lab machine (memory, cycles and the VIC/SID state after every pass).
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct MainLoopTests {
    typealias R = MainLoop.RAM

    /// The lab machine (booted into regular flight) and a twin port, both without DMA stalls
    /// (no badlines, no sprites) so the cycle counts are the instructions' own.
    final class FullRig {
        let lab: C64Machine
        let machine: Machine
        private(set) var failures: [String] = []
        private(set) var failureCount = 0
        private(set) var calls = 0

        init(_ ram: [UInt8]) throws {
            lab = try Original.machineHarness().machine
            lab.captureFrames = false
            let bus = lab.bus
            bus.vicRegs[0x11] &= ~0x10
            bus.vicRegs[0x15] = 0
            var ram = ram
            ram[0] = 0x2F
            ram[1] = 0x35
            bus.ram = ram
            bus.portDDR = 0x2F
            bus.portData = 0x35
            lab.keyboard.releaseAll()
            machine = Machine(memory: ram)
            machine.diskBlocks = Original.diskBlocks
            machine.clock.cycles = 1_000_000
            machine.io.vic = Array(bus.vicRegs[0..<0x2F])
            machine.io.sid = Array(bus.sidRegs[0..<0x19])
            machine.io.colorRAM = bus.colorRAM
            machine.io.cia2PortA = bus.cia2.pra
            machine.io.cia2DataDirectionA = bus.cia2.ddra
        }

        func peek(_ a: Int) -> UInt8 { machine.mem[a] }

        func poke(_ a: Int, _ v: UInt8) {
            lab.bus.ram[a] = v
            machine.mem[a] = v
        }

        func setInput(_ k: KeyMatrix) {
            lab.keyboard = k
            machine.io.keyboard = k
        }

        /// Runs the original from `address` until the PC reaches `stop` (an interrupt frame or a
        /// return address is set up by `prepare`), and the port; compares everything.
        func run(_ label: @autoclosure () -> String, from address: UInt16, prepare: (CPU6502<C64Bus>) -> Void,
                 until stop: @escaping (C64Machine) -> Bool, port: (Machine) -> Void) {
            calls += 1
            let cpu = lab.cpu, bus = lab.bus
            bus.sidWrites.removeAll(keepingCapacity: true)
            prepare(cpu)
            cpu.pc = address
            cpu.irqLine = false
            let start = cpu.cycles
            var first = true
            while (first || !stop(lab)) && cpu.cycles - start < 300_000_000 {
                first = false
                if !lab.step() { break }
            }
            let originalCycles = cpu.cycles - start
            let stores = bus.sidWrites.map { InputSIDStore(offset: $0.cycle - start, reg: Int($0.reg), value: $0.value) }
            let portStart = machine.clock.cycles, sidStart = machine.io.sidWrites.count
            port(machine)
            let portCycles = machine.clock.cycles - portStart
            let portStores = machine.io.sidWrites[sidStart...].map {
                InputSIDStore(offset: $0.cycle - portStart, reg: Int($0.reg), value: $0.value)
            }
            var problems: [String] = []
            if !stop(lab) { problems.append("original did not reach its end") }
            if portCycles != originalCycles { problems.append("cycles \(portCycles) want \(originalCycles)") }
            if portStores.map({ [$0.reg, Int($0.value)] }) != stores.map({ [$0.reg, Int($0.value)] }) {
                problems.append("SID \(portStores.prefix(4)) want \(stores.prefix(4))")
            }
            let vic = Array(bus.vicRegs[0..<0x2F])
            if machine.io.vic != vic {
                let regs = (0..<0x2F).filter { machine.io.vic[$0] != vic[$0] }
                problems.append("VIC " + regs.prefix(4).map { String(format: "$D0%02X=%02X want %02X", $0, machine.io.vic[$0], vic[$0]) }
                    .joined(separator: " "))
                machine.io.vic = vic
            }
            if machine.io.colorRAM != bus.colorRAM { problems.append("color RAM"); machine.io.colorRAM = bus.colorRAM }
            let d = Original.differences(machine.memoryImage, bus.ram)
            if let a = d.first {
                problems.append("memory $\(hex16(a)) = \(hex(machine.mem[a])) want \(hex(bus.ram[a])) (\(d.count) bytes)")
                machine.load(memory: bus.ram)
            }
            if !problems.isEmpty {
                failureCount += 1
                if failures.count < 12 { failures.append("\(label()): " + problems.joined(separator: ", ")) }
            }
        }

        /// An interrupt handler: an interrupt frame on the stack that returns to $FFF0.
        func interrupt(_ label: @autoclosure () -> String, _ address: UInt16, port: (Machine) -> Void) {
            let bus = lab.bus
            run(label(), from: address, prepare: { cpu in
                cpu.sp = 0xFC
                bus.ram[0x01FF] = 0xFF
                bus.ram[0x01FE] = 0xF0
                bus.ram[0x01FD] = 0x24
                cpu.interruptDisable = true
            }, until: { $0.cpu.pc == 0xFFF0 }, port: port)
        }

        /// One main-loop pass: from $204B back to $204B.
        func pass(_ label: @autoclosure () -> String) {
            run(label(), from: 0x204B, prepare: { cpu in
                cpu.sp = 0xF0
                cpu.interruptDisable = false
            }, until: { $0.cpu.pc == 0x204B }, port: { m in
                switch try? m.mainLoopPass() {
                case .next: break
                default: Issue.record("pass did not return to $204B")
                }
            })
        }

        func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let report = "\(what): \(failureCount) of \(calls) calls differ\n" + failures.joined(separator: "\n")
            #expect(failureCount == 0, "\(report)", sourceLocation: sourceLocation)
        }
    }

    /// $2285 in both phases and $2304, over every keyboard phase and pattern-player state, with
    /// random keys and joysticks (the scan, the release check, the joystick latch).
    @Test func interruptHandlers() throws {
        let rig = try FullRig(try Original.regularFlight())
        var rng = TestRandom(seed: 0x2285)
        let keys = C64Key.allCases
        for i in 0..<400 {
            var k = KeyMatrix()
            for _ in 0..<Int(rng.byte() % 4) { k.set(keys[Int(rng.byte()) % keys.count], pressed: true) }
            if rng.byte() < 24 { k.joystick1 = JoystickState(rawValue: rng.byte() & 0x1F) }
            if rng.byte() < 24 { k.joystick2 = JoystickState(rawValue: rng.byte() & 0x1F) }
            rig.setInput(k)
            rig.poke(R.scanPhase, rng.byte() % 4)
            rig.poke(R.irqPhase, rng.byte() & 0x03)
            rig.poke(0x0E5B, [1, 2, rng.byte()][Int(rng.byte() % 3)])
            rig.poke(0x0E5A, rng.byte())
            rig.poke(0x2308, rng.byte())
            rig.poke(0x0E5E, rng.byte())
            rig.poke(0x0E60, rng.byte())
            rig.poke(R.flipOperand, rng.byte() & 1 == 0 ? 0xF0 : 0xF8)
            rig.poke(R.borderOperand, rng.byte() & 0x0F)
            rig.poke(R.savedCpuPort, rng.byte() & 1 == 0 ? 0x35 : 0x36)
            if i % 50 == 0 { for s in 0..<4 { rig.poke(Input.RAM.heldKeySlots + s, 0x80) } }
            if i % 5 == 4 {
                rig.interrupt("altIrq \(i)", 0x2304) { $0.altIrq() }
            } else {
                rig.interrupt("rasterIrq \(i)", 0x2285) { $0.rasterIrq() }
            }
        }
        rig.expectClean("interrupt handlers")
    }

    /// Whole passes at Meigs: every phase of `$22` (the 1-in-8 tasks and the demo check
    /// included), the skipped flip, slew, the views, the crash and splash messages. Phase 3 runs
    /// in reality mode with the failure countdown expiring and the sum `$63` + `$5B` one below the
    /// reliability, so whether a failure triggers depends on the carry the oil-pressure gauge
    /// hands `realityFailures`: 1 when the gauge did not change, else the carry of its last row add.
    @Test func passesAtMeigs() throws {
        let rig = try FullRig(try Original.regularFlight())
        var rng = TestRandom(seed: 0x204B)
        var triggered: [Bool] = []
        let handlers = Set((0..<8).map { k in rig.lab.bus.ram[0xEA5C + 2 * k] })
        for i in 0..<20 {
            let phase3 = i % 4 == 3
            rig.poke(0x0967, phase3 ? 1 : 0)                // reality mode
            if phase3 {
                rig.poke(0x08CD, 0)                         // the failure countdown expires
                rig.poke(0x09A4, 0x40)                      // reliability
                rig.poke(0x63, 0x20)
                rig.poke(0x5B, 0x1F)                        // $20 + $1F + carry: a failure only with the carry
                let bar = rig.peek(0x0A9E)
                rig.poke(0x09CD, i % 8 == 3 ? bar : bar &+ 1)
                rig.poke(0xBC, 0)
                rig.poke(0xBD, 0)
            }
            rig.poke(R.frameDivider, 0)
            rig.poke(R.mainLoopCounter, UInt8(i % 8) | (i >= 8 ? 0x40 : 0))
            rig.poke(R.skipFlip, i == 5 || i == 13 ? 1 : 0)
            rig.poke(R.slewMode, i >= 14 && i < 17 ? 1 : 0)
            rig.poke(Input.RAM.viewDirection, i >= 9 ? [0, 2, 4, 6, 8, 0x0A, 0x0C, 0x0E, 0xFF][Int(rng.byte()) % 9] : 0)
            rig.poke(R.demoRequest, i == 4 ? 1 : 0)
            rig.poke(R.modeRequest, 0)
            // Crash and splash messages on two flip passes (with the message delay).
            if i == 10 || i == 18 { rig.poke(R.crashCode, i == 10 ? 4 : 8) }
            rig.pass("pass \(i) phase \(i % 8)")
            if i == 4 { #expect(rig.peek(R.modeRequest) == 3, "the demo check sets $08BB = 3") }
            // The failure handler pointer $BC (the low byte) is set only by triggerFailure.
            if phase3 { triggered.append(handlers.contains(rig.lab.bus.ram[0xBC]) && rig.lab.bus.ram[0xBD] != 0) }
        }
        rig.expectClean("passes at Meigs")
        #expect(triggered.contains(true) && triggered.contains(false), "the carry decided both ways: \(triggered)")
        #expect(triggered.enumerated().allSatisfy { $0.offset % 2 == 1 || $0.element },
                "an unchanged gauge (carry 1) always triggers: \(triggered)")
    }

    /// Whole passes in Europe 1917 (the war overlay resident): the draw sequence's slot $A7EE
    /// every pass (its entry $AA03, the ported `warMain`, runs the scenery VM for the enemies),
    /// every phase of `$22`, the flip skipped once, the 1-in-8 war-exit check in mode 7 (no
    /// restart), and the `$08D7` request without war mode (the `$FD00` hook is reached only in war
    /// mode; there it is a documented no-op that cannot match this image, so that combination is
    /// not compared).
    @Test func passesInEurope1917() throws {
        let ram = try Original.snapshot("replay-europe1917", session: ReplaySessions.europe1917)
        try #require(ram[R.europe1917] == 1 && ram[R.currentMode] == 7 && ram[0xA7E0] == 0xEA && ram[0xA7E1] == 0xB1,
                     "the prefix reached war mode with the war overlay resident")
        let rig = try FullRig(ram)
        for i in 0..<10 {
            rig.poke(R.frameDivider, 0)
            rig.poke(R.mainLoopCounter, UInt8(i % 8))
            rig.poke(R.skipFlip, i == 6 ? 1 : 0)
            rig.poke(R.fd00HookRequest, 0)
            rig.pass("war pass \(i) phase \(i % 8)")
            #expect(rig.peek(0xA7E0) == 0xEA && rig.peek(0xA7E1) == 0xB1, "the war overlay stays resident")
        }
        // Out of war mode, the $08D7 request stays set (the shift that consumes it is skipped).
        rig.poke(R.europe1917, 0)
        rig.poke(R.fd00HookRequest, 1)
        for i in 0..<2 {
            rig.poke(R.frameDivider, 0)
            rig.pass("pass \(i) with $08D7 out of war mode")
        }
        #expect(rig.peek(R.fd00HookRequest) == 1)
        rig.expectClean("passes in Europe 1917")
    }

    /// The 10 Hz tick on random states (flat bus): the dispatch of a queued key, the engine
    /// pitch, the repeats of slots 3 and 2, the bomb whistle, the 5 Hz half (paused or not), the
    /// joysticks and auto-centering, the TOD second (sound tick, the clock's carries into minutes,
    /// hours and midnight, the trim creep on even seconds). The port reads `$DC09` from the same
    /// RAM byte the flat bus reads.
    @Test func tick10Hz() throws {
        let ram = try Original.regularFlight()
        let rig = InputRig(ram)
        rig.machine.ioReadHook = { [unowned machine = rig.machine] address, _ in machine.mem[address] }
        var rng = TestRandom(seed: 0x2348)
        // Codes that do not wait for a key (P, CTRL-P and RUN/STOP pause).
        let codes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0C, 0x0D, 0x0E, 0x14, 0x15, 0x16,
                              0x18, 0x1B, 0x20, 0x2B, 0x2C, 0x2E, 0x2F, 0x31, 0x32, 0x33, 0x34, 0x35, 0x38, 0x39,
                              0x42, 0x43, 0x46, 0x47, 0x48, 0x4D, 0x4E, 0x51, 0x52, 0x53, 0x54, 0x56, 0x57, 0x58,
                              0x59, 0x5A, 0x60, 0x80, 0xC5]
        let I = Input.RAM.self
        for i in 0..<600 {
            if rng.byte() < 160 {
                rig.enqueue(codes[Int(rng.byte()) % codes.count])
            } else {
                rig.poke(I.keyQueueRead, rig.peek(I.keyQueueWrite))
            }
            rig.poke(I.keyDispatchInhibit, rng.byte() < 20 ? 1 : 0)
            for slot in 0..<4 {
                let v = rng.byte()
                rig.poke(I.heldKeySlots + slot, v < 100 ? v & 0x3F : 0x80)
                rig.poke(I.repeatCounters + slot, rng.byte() % 3)
            }
            rig.poke(0x0E7E, rng.byte() < 60 ? rng.byte() & 0x7F : 0xFF)
            rig.poke(0x0E7D, rng.byte())
            rig.poke(R.tickCounter, rng.byte())
            rig.poke(R.pauseCount, rng.byte() < 30 ? 1 : 0)
            rig.poke(R.quickRepeatWindow, rng.byte() % 4)
            rig.poke(I.joyPort1, rng.byte() < 50 ? rng.byte() & 0x1F : 0)
            rig.poke(I.joyPort2, rng.byte() < 30 ? rng.byte() & 0x1B : 0)
            rig.poke(I.joystickUsed, rng.byte() & 1)
            rig.poke(I.autoCenterCounter, rng.byte() & 3)
            let seconds = rng.byte() % 0x60
            rig.poke(0xDC09, seconds)
            rig.poke(R.lastTodSeconds, rng.byte() < 128 ? seconds : seconds &+ 1)
            rig.poke(R.clockSeconds, [59, rng.byte() % 60][Int(rng.byte() & 1)])
            rig.poke(R.clockMinutes, [59, rng.byte() % 60][Int(rng.byte() & 1)])
            rig.poke(R.clockHours, [23, rng.byte() % 24][Int(rng.byte() & 1)])
            rig.poke(0x0967, rng.byte() & 1)                // reality mode (the trim creep)
            rig.poke(I.soundEnable, rng.byte() < 200 ? 1 : 0)
            rig.run(0x2348, "tick \(i)") { $0.tick10Hz(); return .init() }
            // The poll $2330, due or not.
            rig.poke(R.frameDivider, rng.byte() % 12)
            rig.poke(I.keyQueueRead, rig.peek(I.keyQueueWrite))
            rig.run(0x2330, "poll \(i)") { $0.pollTick(); return .init() }
        }
        rig.expectClean("10 Hz tick")
    }

    /// The core vectors that neither wait for a key nor load from disk, called through
    /// `callCoreVector` against calls into the $20xx vectors on the flat bus (memory, cycles, I/O
    /// stores).
    @Test func coreVectors() throws {
        let ram = try Original.regularFlight()
        let rig = FlatIORig(ram)
        var rng = TestRandom(seed: 0x2000)
        for round in 0..<6 {
            for vector: UInt16 in [0x2000, 0x2006, 0x200C, 0x200F, 0x2024, 0x2027, 0x202A, 0x202D, 0x2030, 0x2042] {
                rig.run(vector, "vector \(hex16(Int(vector))) \(round)") { #expect($0.callCoreVector(vector) != nil) }
            }
            let code = rng.byte() % 5, label = rng.byte() % 5
            rig.run(0x2009, "vector $2009 \(round)", regs: .init(a: code, x: label)) {
                _ = $0.callCoreVector(0x2009, CPURegisters(a: code, x: label))
            }
            rig.poke(0xB8, rng.byte())
            rig.poke(0xB9, rng.byte() & 0x03)
            rig.run(0x2033, "vector $2033 \(round)", regs: .init(a: 0xF8, x: 0x21)) {
                _ = $0.callCoreVector(0x2033, CPURegisters(a: 0xF8, x: 0x21))
            }
            let flaps = rng.byte() & 0x60
            rig.run(0x2045, "vector $2045 \(round)", regs: .init(a: flaps)) {
                _ = $0.callCoreVector(0x2045, CPURegisters(a: flaps))
            }
            rig.poke(MainLoop.RAM.frameDivider, rng.byte() % 6)
            rig.run(0x2012, "vector $2012 \(round)") { _ = $0.callCoreVector(0x2012) }
            rig.run(0x203C, "vector $203C \(round)") { _ = $0.callCoreVector(0x203C) }
            // A block request the cache already holds (no disk read).
            rig.poke(Machine.blockRequest, rig.machine.mem[Machine.blockCacheSlots])
            rig.poke(Machine.blockRequest + 4, 0)
            rig.run(0x2036, "vector $2036 \(round)") { _ = $0.callCoreVector(0x2036) }
        }
        rig.expectClean("core vectors")
        let m = Machine(memory: ram)
        #expect(m.callCoreVector(0x203F) == nil, "text mode is the editor unit's")
        #expect(m.callCoreVector(0x2048) == nil)
    }
}
