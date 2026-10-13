import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Lab states and rigs for the editor tests (unit D2).
enum D2 {
    /// Regular flight at Meigs (`C3Fixtures.prefix`), then: E (the first entry loads overlay 1
    /// from disk) stopped at $B09A and at its first key wait; E again; 'S' and '+' in flight
    /// (`$08BB` = 2 and 1, the editor from its cache); E from the cache.
    static let names = ["d2-ed-entry", "d2-ed-page0", "d2-ed-exit", "d2-ed-save", "d2-ed-recall", "d2-ed-cached"]
    static let session = C3Fixtures.prefix + """

        key:E:6 pc:B09A:1500 snap:d2-ed-entry
        pc:2250:600 wait:10 snap:d2-ed-page0
        key:E:6 pc:204B:3000 pc:204B:3000 wait:60 snap:d2-ed-exit
        key:S:6 pc:B09A:600 snap:d2-ed-save
        pc:204B:3000 pc:204B:3000 wait:60
        key:PLUS:6 pc:B09A:600 snap:d2-ed-recall
        pc:204B:3000 pc:204B:3000 wait:60
        key:E:6 pc:B09A:600 snap:d2-ed-cached
        """

    /// Demo mode: the main loop's demo check sets `$08BB` = 3 and the editor loads mode 2.
    static let demoNames = ["d2-demo-entry"]
    static let demoSession = """
        pc:2250:9000 key:A:12
        pc:2250:600 key:A:12
        pc:B09A:3000 snap:d2-demo-entry
        """

    static let states: [String: [UInt8]] = {
        var s = (try? C3Fixtures.load(names, session: session)) ?? [:]
        if let demo = try? C3Fixtures.load(demoNames, session: demoSession) { s.merge(demo) { a, _ in a } }
        return s
    }()

    /// A lab state with the 10 Hz divider cleared (no tick runs from the key waits on either side).
    static func state(_ name: String) throws -> [UInt8] {
        var ram = try #require(states[name], "missing lab state \(name)")
        ram[0x0E6B] = 0
        return ram
    }

    // MARK: I/O on the flat bus

    /// Applies stores into $D000-$DFFF (as the flat bus logs them) to `io` the way the real
    /// machine takes them with the I/O mapped: VIC registers, SID registers, color RAM nibbles,
    /// CIA2 port A.
    static func apply(_ writes: [(address: UInt16, value: UInt8)], to io: inout IO) {
        for (a, v) in writes {
            switch Int(a) {
            case 0xD000..<0xD400:
                // A store to $D019 acknowledges the latch and leaves the register shadow, as
                // `IO.acknowledgeVIC` models it (the ported `displayInit` stores $0F there).
                let r = Int(a) & 0x3F
                if r == 0x19 { io.acknowledgeVIC(v) } else if r < 0x2F { io.vic[r] = v }
            case 0xD400..<0xD800:
                let r = Int(a) & 0x1F
                if r < 0x19 { io.sid[r] = v }
            case 0xD800..<0xDC00:
                io.colorRAM[Int(a) - 0xD800] = v & 0x0F
            case 0xDD00:
                io.cia2PortA = v
            default:
                break
            }
        }
    }

    /// The differences between two I/O states (the registers the game writes).
    static func ioDifferences(_ port: IO, _ original: IO) -> [String] {
        var out: [String] = []
        for r in 0..<0x2F where port.vic[r] != original.vic[r] {
            out.append(String(format: "$D0%02X port %02X original %02X", r, port.vic[r], original.vic[r]))
        }
        for r in 0..<0x19 where port.sid[r] != original.sid[r] {
            out.append(String(format: "SID $%02X port %02X original %02X", r, port.sid[r], original.sid[r]))
        }
        let cells = (0..<1024).filter { port.colorRAM[$0] != original.colorRAM[$0] }
        if let first = cells.first {
            out.append(String(format: "color RAM: %d cells differ, first $%04X port %X original %X", cells.count,
                              0xD800 + first, port.colorRAM[first], original.colorRAM[first]))
        }
        if port.cia2PortA != original.cia2PortA {
            out.append(String(format: "$DD00 port %02X original %02X", port.cia2PortA, original.cia2PortA))
        }
        return out
    }

    /// Runs the original at `address` on the rig's flat bus and `port` on its machine, and
    /// returns what differs: memory outside the stack page and $D000-$DFFF, the I/O state (the
    /// original's stores into $D000-$DFFF applied to the machine's state before the call), the
    /// cycles, completion. Resynchronizes the machine on a difference.
    @discardableResult
    static func compareIO(_ rig: DiffRig, _ address: UInt16, _ regs: RoutineHarness.Registers = .init(),
                          maxCycles: UInt64 = 400_000_000, port: (Machine) -> Void) -> [String] {
        rig.harness.bus.ioWrites.removeAll(keepingCapacity: true)
        var expected = rig.machine.io
        let o = rig.harness.call(address, regs, maxCycles: maxCycles)
        apply(rig.harness.bus.ioWrites, to: &expected)
        let start = rig.machine.clock.cycles
        port(rig.machine)
        let cycles = rig.machine.clock.cycles - start
        var problems: [String] = []
        if !o.completed { problems.append("original did not return") }
        if cycles != o.cycles { problems.append("cycles \(cycles) want \(o.cycles)") }
        let diffs = Original.differences(rig.machine.memoryImage, rig.harness.bus.ram,
                                         ignoring: [0x0100...0x01FF, 0xD000...0xDFFF])
        if let d = diffs.first {
            problems.append("memory $\(hex16(d)) = \(hex(rig.machine.mem[d])) want \(hex(rig.harness.bus.ram[d]))"
                            + " (\(diffs.count) bytes differ: "
                            + diffs.prefix(8).map { "$" + hex16($0) }.joined(separator: " ") + ")")
            for a in 0..<0x10000 where !(0xD000...0xDFFF).contains(a) { rig.machine.mem[a] = rig.harness.bus.ram[a] }
        }
        let io = ioDifferences(rig.machine.io, expected)
        if !io.isEmpty {
            problems.append("I/O: " + io.prefix(6).joined(separator: ", "))
            rig.machine.io = expected
        }
        return problems
    }

    /// A rig on `ram` whose machine has the disk blocks and (optionally) the same keys on both
    /// sides.
    static func rig(_ ram: [UInt8], keys: String? = nil) -> (DiffRig, ScriptedKeys?, ScriptedKeys?) {
        let rig = DiffRig(ram)
        rig.machine.diskBlocks = Original.diskBlocks
        guard let keys else { return (rig, nil, nil) }
        let original = ScriptedKeys(keys), port = ScriptedKeys(keys)
        original.attach(to: rig.harness)
        port.installPollHandler(on: rig.machine)
        return (rig, original, port)
    }

    /// Runs the whole editor ($B09A) with a key script on both sides (flat bus, exact cycles).
    static func compareEditor(_ ram: [UInt8], keys: String, store: ModeLibrary.InMemoryStore? = nil)
        -> (problems: [String], rig: DiffRig) {
        let (rig, original, port) = rig(ram, keys: keys)
        if let store { rig.machine.modeLibraryIO = store.io }
        var problems = compareIO(rig, Editor.entry) { $0.editorEntry() }
        if let original, let port, original.delivered != port.delivered {
            problems.append("keys used: port \(port.delivered), original \(original.delivered)")
        }
        return (problems, rig)
    }

    /// Key strings: RETURN, DEL, '-' repeated.
    static func returns(_ n: Int) -> String { String(repeating: "\r", count: n) }
    static func ups(_ n: Int) -> String { String(repeating: "-", count: n) }
    static let del = "\u{08}"
}

/// Differential tests of the editor overlay's routines ($B09A-$B9E0) and the text-mode helpers,
/// on the flat bus against the original: memory (stack page excluded; I/O compared as state),
/// registers where they matter, and the exact cycle count. States come from lab sessions
/// (`D2.session`).
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct EditorRoutineTests {
    @Test func fixtures() throws {
        #expect(D2.states.count == D2.names.count + D2.demoNames.count, "lab states: \(D2.states.keys.sorted())")
        let entry = try D2.state("d2-ed-entry")
        #expect(entry[0xA7E0] == 0x6B && entry[0xA7E1] == 0xBC, "the editor overlay is resident")
        #expect(entry[0x08BA] == 1 && entry[0x08BB] == 0)
        #expect(try D2.state("d2-ed-save")[0x08BB] == 2)
        #expect(try D2.state("d2-ed-recall")[0x08BB] == 1)
        #expect(try D2.state("d2-demo-entry")[0x08BB] == 3)
        // At the key wait page 0 is up: the arrow on line 1, the rule on row 23.
        let page = try D2.state("d2-ed-page0")
        #expect(page[0x0442] == 0x40 && page[0x0444] == 0x3E && page[0x0400 + 23 * 40] == 0x40)
    }

    @Test func parseFieldValue() throws {
        let rig = DiffRig(try D2.state("d2-ed-page0"))
        var rng = TestRandom(seed: 0xB29B)
        for i in 0..<600 {
            for k in 0..<6 {
                let digit = UInt8(rng.next() % 10)
                let b: UInt8 = switch rng.next() % 5 {
                case 0: 0x30 + digit
                case 1: 0xB0 + digit
                case 2: 0x30
                case 3: 0x39
                default: rng.byte()
                }
                rig.poke(0x0952 + k, b)
            }
            rig.run(0xB29B, .init(), "parse \(i)") { $0.parseFieldValue(); return .init() }
        }
        rig.expectClean("parseFieldValue $B29B")
    }

    @Test func printFieldValue() throws {
        let rig = DiffRig(try D2.state("d2-ed-page0"))
        var rng = TestRandom(seed: 0xB2D6)
        let values: [UInt32] = [0, 1, 9, 10, 99, 100, 255, 256, 999, 1000, 9999, 10000, 32767, 32768, 65535,
                                65536, 99999, 100000, 999_999, 1_000_000, 0x7FFFFF, 0x800000, 0xFFFFFF]
        for i in 0..<700 {
            let v = i < values.count ? values[i] : (rng.next() % 3 == 0 ? UInt32(rng.next() % 65536)
                                                    : UInt32(truncatingIfNeeded: rng.next()) & 0xFFFFFF)
            rig.poke(0x094A, UInt8(v & 0xFF)); rig.poke(0x094B, UInt8((v >> 8) & 0xFF))
            rig.poke(0x094C, UInt8(v >> 16))
            rig.poke(0x094D, UInt8(2 * (1 + rng.next() % 21)))
            rig.run(0xB2D6, .init(), "print \(v)") { $0.printFieldValue(); return .init() }
        }
        rig.expectClean("printFieldValue $B2D6")
    }

    @Test func pageCopyAndCursor() throws {
        let rig = DiffRig(try D2.state("d2-ed-page0"))
        var rng = TestRandom(seed: 0xB346)
        for (lo, hi) in [(0x04, 0xA8), (0xEC, 0xAB), (0x00, 0x20), (0xFF, 0x50), (0x18, 0xC0)] {
            rig.run(0xB346, .init(a: UInt8(lo), x: UInt8(hi)), "copy page \(hex(UInt8(hi)))\(hex(UInt8(lo)))") {
                $0.copyEditorPage(lo: UInt8(lo), hi: UInt8(hi)); return .init()
            }
        }
        for page: UInt8 in [0, 2] {
            rig.poke(0x094E, page)
            rig.run(0xB803, .init(), "draw page \(page)") { $0.drawPage(); return .init() }
        }
        rig.run(0xB114, .init(), "first page") { $0.editorFirstPage(); return .init() }
        for i in 0..<300 {
            let page: UInt8 = rng.next() % 2 == 0 ? 0 : 2
            let line = UInt8(2 * (1 + rng.next() % 21))
            rig.poke(0x094E, page)
            rig.poke(0x094D, line)
            switch rng.next() % 6 {
            case 0: rig.run(0xB16B, .init(), "line pointer \(i)") { $0.fieldLinePointer(); return .init() }
            case 1: rig.run(0xB15B, .init(), "erase \(i)") { $0.eraseCursor(); return .init() }
            case 2: rig.run(0xB121, .init(a: line), "arrow \(i)") { $0.drawCursorArrow(line); return .init() }
            case 3, 4: rig.run(0xB0FD, .init(), "next line \(i) from \(line) page \(page)") { $0.cursorNextLine(); return .init() }
            default: rig.run(0xB136, .init(), "previous line \(i) from \(line) page \(page)") { $0.cursorPreviousLine(); return .init() }
            }
        }
        // The page switches at both ends.
        for page: UInt8 in [0, 2] {
            rig.poke(0x094E, page); rig.poke(0x094D, 0x2A)
            rig.run(0xB0FD, .init(), "next from line 21 page \(page)") { $0.cursorNextLine(); return .init() }
            rig.poke(0x094E, page); rig.poke(0x094D, 0x02)
            rig.run(0xB136, .init(), "previous from line 1 page \(page)") { $0.cursorPreviousLine(); return .init() }
        }
        rig.expectClean("page copy and cursor")
    }

    /// The field walks: print every field of a page from the record ($B3C0), read them back
    /// from the screen ($B813), the descriptor step ($B7D2), with random records.
    @Test func fieldWalks() throws {
        let rig = DiffRig(try D2.state("d2-ed-page0"))
        var rng = TestRandom(seed: 0xB3C0)
        for i in 0..<60 {
            for a in 0x0964...0x09AA { rig.poke(a, rng.next() % 3 == 0 ? 0 : rng.byte()) }
            let page: UInt8 = i % 2 == 0 ? 0 : 2
            rig.poke(0x094E, page)
            rig.run(0xB3C0, .init(), "print fields \(i)") { $0.printPageFields(); return .init() }
            // Type over some digits on the screen (as the field input does), then read back.
            for _ in 0..<4 {
                let line = Int(2 * (1 + rng.next() % 21))
                let base = Int(rig.harness.bus.ram[0xAFD4 + line]) | Int(rig.harness.bus.ram[0xAFD5 + line]) << 8
                let n = Int(rng.next() % 7)
                for k in 0..<8 { rig.poke(base + 5 + k, k < n ? 0xB0 + UInt8(rng.next() % 10) : 0x20) }
            }
            rig.run(0xB813, .init(), "read fields \(i)") { $0.readPageFields(); return .init() }
            rig.poke16(0xA5, page == 0 ? 0xB020 : 0xB05A)
            for k in 0..<3 {
                rig.run(0xB7D2, .init(), "descriptor \(k) of walk \(i)") { $0.fieldPointers(); return .init() }
            }
        }
        // A descriptor list whose pointer crosses a page, and digit runs at the end of a page.
        rig.poke16(0xA5, 0xB0FE)
        rig.run(0xB7D2, .init(), "descriptor across a page") { $0.fieldPointers(); return .init() }
        rig.expectClean("field walks")
    }

    /// $B371: the USER MODE field after an accepted field: recall, save to n − 100, refusals.
    @Test func acceptField() throws {
        let base = try D2.state("d2-ed-page0")
        let rig = DiffRig(base)
        var rng = TestRandom(seed: 0xB371)
        let entries: [UInt8] = [0, 1, 2, 5, 9, 10, 11, 24, 25, 26, 99, 100, 109, 110, 111, 119, 124, 125, 134, 135,
                                200, 209, 210, 211, 255]
        for (i, entry) in entries.enumerated() {
            for current: UInt8 in [0, 3, 10, entry] {
                rig.poke(0x0963, current)
                rig.poke(0x09A5, entry)
                rig.poke(0x094E, [0, 2][i % 2])
                rig.poke(0x094D, UInt8(2 * (1 + rng.next() % 21)))
                // The USER MODE digits on the screen (page 0, line 1) as typed.
                let digits = Array(String(entry).utf8)
                for k in 0..<8 { rig.poke(0x0442 + 5 + k, k < digits.count ? digits[k] | 0x80 : 0x20) }
                rig.run(0xB371, .init(), "USER MODE \(entry), mode \(current)") { $0.acceptField(); return .init() }
            }
        }
        rig.expectClean("acceptField $B371")
    }

    /// $B998/$B98D: every mode in both directions, odd modes, other library pointers; S ($B7A5)
    /// and '+' ($B7C3).
    @Test func modeRecords() throws {
        let rig = DiffRig(try D2.state("d2-ed-page0"))
        var rng = TestRandom(seed: 0xB998)
        let modes: [UInt8] = Array(0...26) + [99, 128, 138, 139, 140, 200, 255]
        for (i, mode) in modes.enumerated() {
            rig.poke(0x0963, mode)
            if i % 5 == 4 { rig.poke16(0x0961, UInt16(0x3000 + rng.next() % 0x8000)) } else { rig.poke16(0x0961, 0xC800) }
            for a in 0x0964...0x09A4 { rig.poke(a, rng.byte()) }
            rig.run(0xB98D, .init(), "store mode \(mode)") { $0.storeModeRecord(); return .init() }
            rig.run(0xB998, .init(), "load mode \(mode)") { $0.loadModeRecord(); return .init() }
        }
        rig.poke16(0x0961, 0xC800)
        for mode: UInt8 in [0, 2, 7, 9, 10, 17, 24, 25, 30] {
            rig.poke(0x0963, mode)
            rig.poke(0x094E, mode % 2 == 0 ? 0 : 2)
            rig.run(0xB7A5, .init(), "save in mode \(mode)") { $0.saveUserMode(); return .init() }
            rig.poke(0x0963, mode)
            rig.run(0xB7C3, .init(), "recall mode \(mode)") { $0.recallKey(); return .init() }
        }
        rig.expectClean("mode records")
    }

    /// $B3F6 (state → record) and $B865 (the winds and the metric words, both directions) on
    /// random states with extreme values.
    @Test func stateToRecord() throws {
        let rig = DiffRig(try D2.state("d2-ed-entry"))
        var rng = TestRandom(seed: 0xB3F6)
        let extremes: [UInt16] = [0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x00FF, 0xFF00, 0x4000, 0xC000]
        func word() -> UInt16 { rng.next() % 3 == 0 ? extremes[Int(rng.next() % UInt64(extremes.count))] : UInt16(rng.next() & 0xFFFF) }
        for i in 0..<300 {
            for a in [0x5E, 0x60, 0x62, 0x64, 0x5A, 0x5C, 0x0A87, 0x0846, 0x0848, 0x0A13, 0x09E0, 0x09DE, 0x0A4C,
                      0x0AC8, 0x0AAF, 0x0ABC, 0x0AA3, 0x0AAB, 0x098E, 0x0990, 0x0992, 0x0ACD] {
                rig.poke16(a, word())
            }
            for a in stride(from: 0x0994, to: 0x09A4, by: 2) { rig.poke16(a, word()) }
            for a in stride(from: 0x085C, to: 0x086A, by: 2) { rig.poke16(a, word()) }
            rig.poke(0x095A, i % 4 == 0 ? 1 : 0)
            rig.run(0xB3F6, .init(), "state to record \(i)") { $0.stateToRecord(); return .init() }
            rig.run(0xB865, .init(y: 1), "winds to internal \(i)") { $0.windToDisplay(toInternal: true); return .init() }
            rig.run(0xB865, .init(y: 0), "winds to display \(i)") { $0.windToDisplay(toInternal: false); return .init() }
        }
        rig.expectClean("stateToRecord $B3F6 / windToDisplay $B865")
    }

    /// $B559 (record → state, the exit) on random records, with I/O (the ported `displayInit`):
    /// Europe 1917, reality mode with and without throttle, the cache states, the demo flags.
    @Test func recordToState() throws {
        let (rig, _, _) = D2.rig(try D2.state("d2-ed-page0"))
        var rng = TestRandom(seed: 0xB559)
        var failures: [String] = []
        for i in 0..<120 {
            for a in 0x0964...0x09A4 where a != 0x0969 && a != 0x0967 { rig.poke(a, rng.byte()) }
            rig.poke(0x0969, i % 7 == 0 ? 1 : 0)
            rig.poke(0x0967, i % 3 == 0 ? 1 : 0)
            if i % 2 == 0 { rig.poke(0x0979, 0) }
            rig.poke(0x0980, UInt8(rng.next() % 5))                // flaps high byte: the magneto label
            rig.poke(0x0963, UInt8(rng.next() % 25))
            rig.poke(0x08BC, [0, 1, 2, 3][i % 4])
            rig.poke(0x095B, i % 5 == 0 ? 1 : 0)
            rig.poke(0x22, rng.byte())
            let problems = D2.compareIO(rig, 0xB559) { $0.recordToState() }
            if !problems.isEmpty && failures.count < 8 { failures.append("record \(i): " + problems.joined(separator: "; ")) }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// State → record → state, and record → state → record, on both sides: whatever each
    /// conversion loses, the port loses the same (the original's integer math, exactly).
    @Test func roundTrips() throws {
        let (rig, _, _) = D2.rig(try D2.state("d2-ed-page0"))
        var rng = TestRandom(seed: 0x5A5A)
        var failures: [String] = []
        var exactHeadings = 0
        for i in 0..<80 {
            // A random state, through the editor's entry and exit conversions.
            for a in [0x0A13, 0x09E0, 0x09DE, 0x0A4C, 0x0ABC, 0x0AA3, 0x0AAB, 0x098E, 0x0990, 0x0992] {
                rig.poke16(a, UInt16(rng.next() & 0xFFFF))
            }
            for a in stride(from: 0x0994, to: 0x09A4, by: 2) { rig.poke16(a, UInt16(rng.next() & 0xFFFF)) }
            rig.poke(0x0969, 0)
            let heading = UInt16(rig.harness.bus.ram[0x0A13]) | UInt16(rig.harness.bus.ram[0x0A14]) << 8
            var p = D2.compareIO(rig, 0xB3F6) { $0.stateToRecord() }
            p += D2.compareIO(rig, 0xB559) { $0.recordToState() }
            let back = UInt16(rig.machine.mem[0x0A13]) | UInt16(rig.machine.mem[0x0A14]) << 8
            if back == heading { exactHeadings += 1 }
            // And a built-in mode through the exit, then the entry.
            rig.poke(0x0963, UInt8(i % 10))
            p += D2.compareIO(rig, 0xB998) { $0.loadModeRecord() }
            rig.poke(0x0969, 0)
            p += D2.compareIO(rig, 0xB559) { $0.recordToState() }
            p += D2.compareIO(rig, 0xB3F6) { $0.stateToRecord() }
            if !p.isEmpty && failures.count < 8 { failures.append("round trip \(i): " + p.joined(separator: "; ")) }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        // Degrees lose resolution: most headings do not come back bit for bit.
        #expect(exactHeadings < 80)
    }

    /// The text-mode helpers: $2673 (and through it $796C, $794E), $794E alone, $5F40 both ways.
    @Test func textModeHelpers() throws {
        let (rig, _, _) = D2.rig(try D2.state("d2-ed-exit"))
        var problems: [String] = []
        problems += D2.compareIO(rig, 0x2673) { $0.textModeIrqSwap() }
        for color: UInt8 in [0x0B, 0x01, 0xFF] {
            problems += D2.compareIO(rig, 0x794E, .init(a: color)) { $0.fillColorRam(color) }
        }
        problems += D2.compareIO(rig, 0x796C) { $0.setTextMode() }
        problems += D2.compareIO(rig, 0x5F40) { $0.restoreGraphics() }      // $0E89 = $97: nothing
        rig.poke(0x0E89, 0x96)
        problems += D2.compareIO(rig, 0x5F40) { $0.restoreGraphics() }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
        #expect(rig.machine.mem[0xFFFE] == 0x04 && rig.machine.mem[0xFFFF] == 0x23)
        #expect(rig.machine.io.colorRAM[999] == 1 && rig.machine.io.colorRAM[1000] == 0, "$D800-$DBE7 only")
    }

    /// The text-mode swap runs with the IRQ masked (as the original's $2673 does): under
    /// the normal-mode scheduler the raster events inside its ~21,000 cycles only latch, so the
    /// game's split IRQ $2285 never rewrites `$D016`/`$D018` over the new text screen; the one IRQ
    /// held is taken right after the unmasking, through the tick-only vector $2304 the swap stored.
    @Test func textModeSwapUnderEvents() throws {
        let m = Machine(memory: try D2.state("d2-ed-exit"))
        #expect(m[0xFFFE] == 0x85 && m[0xFFFF] == 0x22, "the game's split IRQ before the swap")
        m.io.writeVIC(0x11, 0x3B)
        m.io.writeVIC(0x12, 0x20)
        m.io.writeVIC(0x1A, 0x01)
        m.clock.cycles = 4000 * VirtualClock.cyclesPerFrame + 0x18 * VirtualClock.cyclesPerLine
        let scheduler = InterruptScheduler(machine: m)
        scheduler.install()
        let service = m.eventHandler
        let jiffyAddress = MainLoop.RAM.jiffyCounter
        /// Per outer scheduler service: the flag before it, the IRQ vector, the frame ticks it ran.
        var services: [(masked: Bool, vector: UInt16, ticks: Int)] = []
        var depth = 0
        m.eventHandler = { mm in
            depth += 1
            defer { depth -= 1 }
            guard depth == 1 else { service?(mm); return }
            let masked = mm.interruptDisable, jiffy = mm[jiffyAddress]
            let vector = UInt16(mm[0xFFFE]) | UInt16(mm[0xFFFF]) << 8
            service?(mm)
            services.append((masked, vector, Int(mm[jiffyAddress] &- jiffy)))
        }
        let start = m.clock.cycles
        m.textModeIrqSwap()
        let cycles = m.clock.cycles - start
        scheduler.uninstall()
        #expect(cycles > VirtualClock.cyclesPerFrame, "the swap takes \(cycles) cycles: at least one raster event inside")
        let inside = services.filter(\.masked)
        #expect(inside.count >= 2 && inside.allSatisfy { $0.ticks == 0 }, "events inside the swap: \(inside)")
        let ticked = services.filter { $0.ticks != 0 }
        #expect(ticked.count == 1 && ticked.first?.ticks == 1 && ticked.first?.vector == 0x2304,
                "one IRQ after the CLI, through $2304: \(ticked)")
        #expect(!m.interruptDisable && m.mem[0x0E89] == 0x97)
        #expect(m.io.vic[0x16] == 0x08 && m.io.vic[0x18] == 0x16 && m.io.vic[0x11] == 0x1B, "the text screen stays")
    }
}
