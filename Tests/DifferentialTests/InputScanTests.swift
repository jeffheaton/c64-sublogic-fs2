import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Differential tests of the keyboard matrix scan, the held-key slots, the key ring, the repeat
/// timing and the joystick sampling ($2418-$25EA) on the full lab machine (`MachineHarness`), so
/// the original reads the lab's CIA1 with its own column selects while the port reads
/// `io.keyboard`. Scripted key and joystick sequences drive both through the frame IRQ's keyboard
/// phase and the 10 Hz tick's key part (replicated by the test driver for both sides); the
/// dispatched handlers, the joystick actions and the auto-centering run too.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct InputScanTests {
    typealias R = Input.RAM

    /// The lab machine (booted once) and a twin port image. Raster IRQs are never taken during
    /// a call, and badlines and sprites are switched off so the original's cycle counts contain
    /// no DMA stalls.
    final class ScanRig {
        let harness: MachineHarness
        let machine: Machine
        private(set) var failures: [String] = []
        private(set) var failureCount = 0
        private(set) var calls = 0
        /// Codes dispatched by the driver (for checks of the sequences' meaning), and the tick
        /// number of each dispatch.
        var dispatched: [UInt8] = []
        var dispatchTicks: [Int] = []
        var frame = 0
        var ticks = 0
        /// When false the driver's 10 Hz part does not dispatch (for keys whose handler waits).
        var dispatching = true

        /// One booted lab machine for the whole suite (booting plays re/sessions/regular.txt).
        nonisolated(unsafe) static let shared = Result<MachineHarness, Error> { try Original.machineHarness() }

        init(_ ram: [UInt8]) throws {
            harness = try Self.shared.get()
            let bus = harness.machine.bus
            bus.vicRegs[0x11] &= ~0x10
            bus.vicRegs[0x15] = 0
            var ram = ram
            ram[0] = 0x2F
            ram[1] = 0x35
            bus.ram = ram
            bus.portDDR = 0x2F
            bus.portData = 0x35
            harness.machine.keyboard.releaseAll()
            machine = Machine(memory: ram)
            machine.clock.cycles = 1_000_000
        }

        func peek(_ a: Int) -> UInt8 { machine.mem[a] }

        func poke(_ a: Int, _ v: UInt8) {
            harness.machine.bus.ram[a] = v
            machine.mem[a] = v
        }

        func setInput(_ k: KeyMatrix) {
            harness.machine.keyboard = k
            machine.io.keyboard = k
        }

        @discardableResult
        func run(_ address: UInt16, _ label: @autoclosure () -> String, regs: RoutineHarness.Registers = .init(),
                 port: (Machine) -> Void) -> RoutineHarness.Result {
            run(address, label(), regs: regs, registers: { port($0); return .init() })
        }

        /// As `run(_:_:regs:port:)`, and the registers the port returns (`InputRig.Out`) must
        /// match the original's.
        @discardableResult
        func run(_ address: UInt16, _ label: @autoclosure () -> String, regs: RoutineHarness.Registers = .init(),
                 registers port: (Machine) -> InputRig.Out) -> RoutineHarness.Result {
            calls += 1
            let bus = harness.machine.bus
            let o = harness.call(address, ram: nil, regs, maxCycles: 5_000_000)
            let originalStart = harness.machine.cpu.cycles - o.cycles
            let stores = bus.sidWrites.map { InputSIDStore(offset: $0.cycle - originalStart, reg: Int($0.reg), value: $0.value) }
            let start = machine.clock.cycles, sidStart = machine.io.sidWrites.count
            let p = port(machine)
            let cycles = machine.clock.cycles - start
            let portStores = machine.io.sidWrites[sidStart...].map {
                InputSIDStore(offset: $0.cycle - start, reg: Int($0.reg), value: $0.value)
            }
            var problems: [String] = []
            if !o.completed { problems.append("original did not return") }
            let r = o.registers
            if let a = p.a, a != r.a { problems.append("A=\(hex(a)) want \(hex(r.a))") }
            if let x = p.x, x != r.x { problems.append("X=\(hex(x)) want \(hex(r.x))") }
            if let y = p.y, y != r.y { problems.append("Y=\(hex(y)) want \(hex(r.y))") }
            if let c = p.carry, c != r.carry { problems.append("C=\(c) want \(r.carry)") }
            if cycles != o.cycles { problems.append("cycles \(cycles) want \(o.cycles)") }
            if portStores != stores { problems.append("SID \(portStores.prefix(4)) want \(stores.prefix(4))") }
            if let d = firstDifference() {
                let count = Original.differences(machine.memoryImage, bus.ram).count
                problems.append("memory $\(hex16(d)) = \(hex(machine.mem[d])) want \(hex(bus.ram[d])) (\(count) bytes differ)")
                machine.load(memory: bus.ram)
            }
            if !problems.isEmpty {
                failureCount += 1
                if failures.count < 16 { failures.append("frame \(frame) \(label()): " + problems.joined(separator: ", ")) }
            }
            return o
        }

        /// First address outside the stack page where the two images differ.
        func firstDifference() -> Int? {
            harness.machine.bus.ram.withUnsafeBufferPointer { o in
                let p = UnsafeRawPointer(machine.mem), q = UnsafeRawPointer(o.baseAddress!)
                for range in [0..<0x100, 0x200..<0x10000]
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

        // MARK: The driver

        /// One frame of the IRQ's keyboard phase ($22CD-$22F2): `$08A6` counts down; negative →
        /// release check and `$08A6` = 3; zero → scan. Every 6th frame the 10 Hz tick's key part
        /// ($2348-$2380: one dispatch, the slot 3/2 repeats) and, on every other tick when not
        /// paused, its 5 Hz part ($23A4-$23CA: `$091C`, joystick, auto-center).
        func step(_ input: KeyMatrix) {
            setInput(input)
            frame += 1
            let phase = peek(R.scanPhase) &- 1
            poke(R.scanPhase, phase)
            if phase & 0x80 != 0 {
                run(0x2505, "release") { $0.keyReleaseCheck() }
                poke(R.scanPhase, 3)
            } else if phase == 0 {
                run(0x2418, "scan") { $0.keyScan() }
            }
            guard frame % 6 == 0 else { return }
            ticks += 1
            if dispatching && peek(R.keyQueueRead) != peek(R.keyQueueWrite) && peek(R.keyDispatchInhibit) == 0 {
                dispatched.append(peek(R.keyQueue + Int((peek(R.keyQueueRead) &+ 1) & 7)))
                dispatchTicks.append(ticks)
                run(0x27D8, "dispatch \(hex(dispatched.last!))") { $0.dispatchKey() }
            }
            for slot in [3, 2] {
                let y = peek(R.heldKeySlots + slot)
                guard y & 0x80 == 0 else { continue }
                let counter = peek(R.repeatCounters + slot)
                if counter == 0 {
                    run(0x24EB, "repeat slot \(slot)", regs: RoutineHarness.Registers(y: y)) { $0.requeueKey(y) }
                } else {
                    poke(R.repeatCounters + slot, counter - 1)
                }
            }
            guard ticks % 2 == 0, peek(R.pauseCount) == 0 else { return }
            let window = peek(R.quickRepeatWindow)
            if window != 0 { poke(R.quickRepeatWindow, window - 1) }
            if peek(R.joyPort1) | peek(R.joyPort2) != 0 { run(0x2688, "joystick") { $0.joystickAction() } }
            if peek(R.joystickUsed) != 0 { run(0x26EC, "autoCenter") { $0.autoCenter() } }
        }

        func hold(_ keys: [C64Key], joy1: JoystickState = [], joy2: JoystickState = [], frames: Int) {
            var k = KeyMatrix()
            for key in keys { k.set(key, pressed: true) }
            k.joystick1 = joy1
            k.joystick2 = joy2
            for _ in 0..<frames { step(k) }
        }

        func idle(_ frames: Int) { hold([], frames: frames) }

        /// Idles until the next frame is a scan frame (keyboard phase 1 before the countdown).
        func alignToScan() { while peek(R.scanPhase) != 1 { idle(1) } }

        /// Whether one of the next `frames` frames scans the matrix.
        func scanWithin(_ frames: Int) -> Bool {
            var phase = peek(R.scanPhase)
            for _ in 0..<frames {
                phase &-= 1
                if phase == 0 { return true }
                if phase & 0x80 != 0 { phase = 3 }
            }
            return false
        }
    }

    static func regular() throws -> [UInt8] { try Original.regularFlight() }

    // MARK: Random matrix states

    /// `keyScan` and `keyReleaseCheck` against random matrices (0-6 keys, joysticks on either
    /// port), slot contents (free, held keys, indices past the table), CTRL and ring states.
    @Test func scanAndReleaseRandomStates() throws {
        let rig = try ScanRig(try Self.regular())
        var rng = TestRandom(seed: 0x2418_2505)
        for i in 0..<1500 {
            var k = KeyMatrix()
            let keyCount = Int(rng.next() % 7)
            var pressed: [C64Key] = []
            for _ in 0..<keyCount {
                let key = C64Key(rawValue: Int(rng.next() % 64))!
                k.set(key, pressed: true)
                pressed.append(key)
            }
            if rng.next() % 4 == 0 { k.joystick1 = JoystickState(rawValue: rng.byte() & 0x1F) }
            if rng.next() % 4 == 0 { k.joystick2 = JoystickState(rawValue: rng.byte() & 0x1F) }
            rig.setInput(k)
            for slot in 0..<4 {
                let choice = rng.next() % 6
                let value: UInt8
                switch choice {
                case 0, 1: value = 0x80
                case 2: value = pressed.isEmpty ? 0x80 : UInt8(pressed[Int(rng.next() % UInt64(pressed.count))].rawValue)
                case 3: value = rng.byte() & 0x3F
                case 4: value = 0x3A                         // CTRL
                default: value = rng.next() % 8 == 0 ? (0x78 | rng.byte() & 7) : rng.byte() & 0x3F
                }
                rig.poke(R.heldKeySlots + slot, value)
                rig.poke(R.repeatCounters + slot, rng.byte() & 7)
            }
            rig.poke(R.ctrlHeld, [0, 0, 1][Int(rng.next() % 3)])
            rig.poke(R.joystickLatched, [0, 1][Int(rng.next() % 2)])
            rig.poke(R.keyQueueWrite, rng.byte())
            rig.poke(R.keyQueueRead, rng.byte())
            rig.poke(R.joyPort1, 0)
            rig.poke(R.joyPort2, 0)
            if i % 2 == 0 {
                rig.run(0x2418, "scan \(i)") { $0.keyScan() }
            } else {
                rig.run(0x2505, "release \(i)") { $0.keyReleaseCheck() }
            }
            // sampleCia1 on its own, with every column select and a random one; its C, X (the
            // row read) and Y outputs too.
            let select = i % 3 == 0 ? rng.byte() : ~(UInt8(1) << (i % 8))
            rig.run(0x2574, "sample \(i)", regs: RoutineHarness.Registers(x: select)) {
                let s = $0.sampleCia1(column: select)
                return .init(x: s.x, y: s.y, carry: s.joystick)
            }
        }
        rig.expectClean("random scans")
    }

    /// Joystick bits on both ports: each single bit and some combinations, with and without keys,
    /// through the scan and the release check (the latches `$0E6E/$0E6F`, `$0E6A`).
    @Test func joystickSampling() throws {
        let rig = try ScanRig(try Self.regular())
        for port in [1, 2] {
            for bits in [0x01, 0x02, 0x04, 0x08, 0x10, 0x05, 0x0A, 0x11, 0x1F] as [UInt8] {
                for keys in [[], [C64Key.l], [.b, .control], [.digit1, .q, .space]] {
                    var k = KeyMatrix()
                    for key in keys { k.set(key, pressed: true) }
                    if port == 1 { k.joystick1 = JoystickState(rawValue: bits) } else { k.joystick2 = JoystickState(rawValue: bits) }
                    rig.setInput(k)
                    rig.poke(R.heldKeySlots + 3, keys.isEmpty ? 0x80 : UInt8(keys[0].rawValue))
                    rig.run(0x2418, "scan port \(port) bits \(hex(bits)) keys \(keys.count)") { $0.keyScan() }
                    #expect(rig.peek(port == 1 ? R.joyPort1 : R.joyPort2) == bits)
                    #expect(rig.peek(R.joystickLatched) == 1)
                    rig.run(0x2505, "release port \(port) bits \(hex(bits)) keys \(keys.count)") { $0.keyReleaseCheck() }
                    for column in 0..<8 {
                        let select = ~(UInt8(1) << column)
                        let label = "sample port \(port) bits \(hex(bits)) keys \(keys.count) column \(column)"
                        rig.run(0x2574, label, regs: RoutineHarness.Registers(x: select)) {
                            let s = $0.sampleCia1(column: select)
                            return .init(x: s.x, y: s.y, carry: s.joystick)
                        }
                    }
                    rig.poke(R.joyPort1, 0)
                    rig.poke(R.joyPort2, 0)
                }
            }
        }
        rig.expectClean("joystick sampling")
    }

    // MARK: Scripted sequences

    /// One key held past the repeat delay, then released: the first press, then a repeat per tick
    /// (B: elevator +4, then +16 in the window). The slot counter starts at 5 and each tick
    /// decrements it; the tick that finds it 0 re-queues the key after its own dispatch, so the
    /// first repeat is dispatched 6 ticks after the press, then one per tick.
    @Test func heldKeyRepeats() throws {
        let rig = try ScanRig(try Self.regular())
        rig.idle(8)
        rig.hold([.b], frames: 70)
        rig.idle(20)
        rig.hold([.semicolon], frames: 6)
        rig.idle(20)
        let count = rig.dispatched.filter { $0 == 0x42 }.count
        #expect(count >= 5, "B held 70 frames dispatched \(count) times")
        #expect(rig.dispatched.last == 0x15)
        let ticks = zip(rig.dispatched, rig.dispatchTicks).filter { $0.0 == 0x42 }.map(\.1)
        let gaps = zip(ticks.dropFirst(), ticks).map { $0 - $1 }
        #expect(gaps.first == 6 && gaps.dropFirst().allSatisfy { $0 == 1 }, "B dispatch gaps \(gaps)")
        rig.expectClean("held key")
    }

    /// Keys are seen only by the scan (every 4th frame): a press of 1-4 frames is queued once when
    /// it covers a scan frame and lost otherwise, for every phase of the keyboard cycle.
    @Test func pressesNeedAScanFrame() throws {
        let rig = try ScanRig(try Self.regular())
        rig.idle(8)
        var lost = 0
        for length in 1...4 {
            for offset in 0..<4 {
                rig.alignToScan()
                rig.idle(offset)
                let coversScan = rig.scanWithin(length)
                if !coversScan { lost += 1 }
                rig.dispatched.removeAll()
                rig.hold([.v], frames: length)
                rig.idle(24)
                let seen = rig.dispatched.filter { $0 == 0x56 }.count
                #expect(seen == (coversScan ? 1 : 0), "V held \(length) frames at offset \(offset): seen \(seen) times")
            }
        }
        #expect(lost == 6, "presses that miss every scan: \(lost)")
        rig.expectClean("brief presses")
    }

    /// The Mac key mapper's CTRL rule: CTRL in the matrix 4 frames (one keyboard cycle) before
    /// the letter always gives the CTRL code ($03), whatever the scan phase. With a 1-frame lead
    /// the letter comes first ($43, rudder) unless the scan falls on the CTRL-only frame.
    @Test func ctrlLeadNeedsOneScan() throws {
        let rig = try ScanRig(try Self.regular())
        rig.idle(8)
        for lead in [1, 4] {
            var plain = 0
            for offset in 0..<4 {
                rig.alignToScan()
                rig.idle(offset)
                let ctrlSeenAlone = rig.scanWithin(lead)
                rig.dispatched.removeAll()
                rig.hold([.control], frames: lead)
                rig.hold([.control, .c], frames: 6)
                rig.hold([.control], frames: 4)
                rig.idle(24)
                let first = rig.dispatched.first
                #expect(first == (ctrlSeenAlone ? 0x03 : 0x43), "lead \(lead) offset \(offset): \(rig.dispatched.map(hex))")
                if first == 0x43 { plain += 1 }
            }
            #expect(lead == 4 ? plain == 0 : plain == 3, "lead \(lead): \(plain) of 4 phases gave plain C")
        }
        rig.expectClean("CTRL lead")
    }

    /// Two keys held (slots 3 and 2 both repeat), then a third and fourth (no repeat), then a
    /// fifth (no slot: lost). Two repeating keys queue two codes per tick while one is dispatched,
    /// so a backlog builds up (and the 8-entry ring wraps over unread codes); it drains one code
    /// per tick after the keys are released.
    @Test func severalKeys() throws {
        let rig = try ScanRig(try Self.regular())
        rig.idle(8)
        rig.hold([.semicolon], frames: 8)
        rig.hold([.semicolon, .v], frames: 60)
        let backlog = rig.peek(R.keyQueueWrite) &- rig.peek(R.keyQueueRead)
        #expect(backlog > 1, "backlog \(backlog)")
        rig.hold([.semicolon, .v, .h, .c], frames: 40)
        rig.hold([.semicolon, .v, .h, .c, .m], frames: 30)
        #expect(!rig.dispatched.contains(0x4D), "M had no free slot")
        rig.hold([.h], frames: 20)
        rig.idle(200)
        #expect(rig.dispatched.contains(0x56))
        #expect(rig.peek(R.keyQueueWrite) == rig.peek(R.keyQueueRead), "the backlog drained")
        rig.expectClean("several keys")
    }

    /// CTRL timing: CTRL and C in the same scan queue plain C first (rudder), CTRL held one scan
    /// before gives CTRL-C ($03); CTRL released while C repeats gives plain C again. Then CTRL
    /// with digits (codes ≥ $C0, dropped) and CTRL-I/CTRL-L.
    @Test func ctrlTiming() throws {
        let rig = try ScanRig(try Self.regular())
        rig.idle(8)
        rig.hold([.control, .c], frames: 8)
        rig.idle(30)
        #expect(rig.dispatched.first == 0x43, "CTRL+C together: \(rig.dispatched.map(hex))")
        rig.dispatched.removeAll()
        rig.hold([.control], frames: 8)
        rig.hold([.control, .c], frames: 6)
        rig.idle(30)
        #expect(rig.dispatched.first == 0x03, "CTRL then C: \(rig.dispatched.map(hex))")
        rig.hold([.control], frames: 8)
        rig.hold([.control, .c], frames: 30)
        rig.hold([.c], frames: 50)
        rig.idle(20)
        rig.hold([.control], frames: 8)
        rig.hold([.control, .digit1], frames: 8)
        rig.hold([.control, .i], frames: 8)
        rig.hold([.control], frames: 4)
        rig.hold([.control, .l], frames: 8)
        rig.idle(30)
        rig.expectClean("CTRL timing")
    }

    /// A deflected joystick suspends the keyboard: a key held before it stays in its slot until
    /// the stick is released (the release check aborts too), keys pressed during it are lost; the
    /// latches drive the 5 Hz actions; then the auto-centering.
    @Test func joystickSuspendsKeyboard() throws {
        let rig = try ScanRig(try Self.regular())
        rig.idle(8)
        rig.hold([.l], frames: 8)
        rig.hold([.l], joy1: .down, frames: 30)
        rig.hold([], joy1: .down, frames: 12)
        #expect(rig.peek(R.heldKeySlots + 3) == UInt8(C64Key.l.rawValue), "L stays held during the deflection")
        rig.hold([.n], joy1: .down, frames: 12)
        rig.idle(30)
        #expect(!rig.dispatched.contains(0x4E), "N pressed during the deflection is lost")
        #expect(rig.peek(R.heldKeySlots + 3) == 0x80)
        rig.hold([], joy1: .right, frames: 12)
        rig.idle(60)
        rig.hold([], joy1: [.left, .fire], frames: 12)
        rig.hold([.h], frames: 6)
        rig.idle(30)
        rig.hold([], joy2: .up, frames: 40)
        rig.hold([], joy2: [.down, .fire], frames: 30)
        rig.hold([], joy1: .up, joy2: .down, frames: 20)
        rig.idle(40)
        rig.expectClean("joystick suspension")
    }

    /// The ring overflows when nothing is dispatched (`$08C3` set): more than 8 pending codes
    /// overwrite the oldest; dispatching then resumes from the read index.
    @Test func ringOverflow() throws {
        let rig = try ScanRig(try Self.regular())
        rig.idle(8)
        rig.poke(R.keyDispatchInhibit, 1)
        for keys: [C64Key] in [[.h, .f], [.c, .m], [.v, .r], [.y, .n], [.g, .h], [.f, .c], [.semicolon, .colon]] {
            rig.hold(keys, frames: 8)
            rig.idle(4)
        }
        rig.hold([.h, .v], frames: 40)
        rig.idle(8)
        rig.poke(R.keyDispatchInhibit, 0)
        rig.idle(120)
        rig.expectClean("ring overflow")
    }

    /// RUN/STOP held first lands in slot 3 ($089E = $3F, the RESTORE condition); held second it
    /// does not. (Not dispatched: its code $50 is the pause.)
    @Test func runStopSlot() throws {
        let rig = try ScanRig(try Self.regular())
        rig.dispatching = false
        rig.idle(8)
        rig.hold([.runStop], frames: 8)
        #expect(rig.peek(R.heldKeySlots + 3) == Input.runStopIndex)
        rig.hold([.runStop, .l], frames: 8)
        rig.idle(12)
        rig.hold([.l], frames: 8)
        rig.hold([.l, .runStop], frames: 8)
        #expect(rig.peek(R.heldKeySlots + 3) != Input.runStopIndex)
        #expect(rig.peek(R.heldKeySlots + 2) == Input.runStopIndex)
        rig.idle(12)
        rig.expectClean("RUN/STOP slot")
    }
}
