import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Lab fixtures for the ATIS, course-plotter and database-info tests: one session per feature,
/// whose `snap:` steps cache every state in build/testdata (see `C3Fixtures.load`).
enum C3Fixtures {
    /// Regular flight at Meigs, after the Chicago area and the Meigs detail block have loaded.
    static let prefix = """
        pc:2250:9000 key:A:12
        pc:2250:600 key:B:12
        pc:204B:3000
        until:0901:4E:3000 pc:204B:3000 wait:60
        """

    /// Runs `session` once (unless every name is cached) and returns the named states; the last
    /// name is the session's final snapshot, the others come from its `snap:` steps.
    static func load(_ names: [String], session: String) throws -> [String: [UInt8]] {
        let dir = Original.repoRoot.appendingPathComponent("build/testdata", isDirectory: true)
        let cached = names.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).snap").path)
        }
        if !cached {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(names.last!).snap"))
        }
        _ = try Original.snapshot(names.last!, session: session)
        var out: [String: [UInt8]] = [:]
        for name in names { out[name] = try Original.snapshot(name, session: session) }
        return out
    }

    /// Runs the original routine at `address` on the rig's harness with a large cycle budget (the
    /// teletype and the delays run for millions of cycles) and `port` on the rig's machine; returns
    /// what differs (memory outside the stack page, the cycle count, completion), resynchronizing
    /// the machine on a memory difference.
    @discardableResult
    static func compareLong(_ rig: DiffRig, _ address: UInt16, _ regs: RoutineHarness.Registers = .init(),
                            maxCycles: UInt64 = 200_000_000, port: (Machine) -> Void) -> [String] {
        let o = rig.harness.call(address, regs, maxCycles: maxCycles)
        let start = rig.machine.clock.cycles
        let mark = rig.ioMark()
        port(rig.machine)
        rig.mirrorIO(since: mark)
        let cycles = rig.machine.clock.cycles - start
        var problems: [String] = []
        if !o.completed { problems.append("original did not return") }
        if cycles != o.cycles { problems.append("cycles \(cycles) want \(o.cycles)") }
        if let d = rig.firstDifference() {
            let count = Original.differences(rig.machine.memoryImage, rig.harness.bus.ram).count
            problems.append("memory $\(hex16(d)) = \(hex(rig.machine.mem[d])) want \(hex(rig.harness.bus.ram[d]))"
                            + " (\(count) bytes differ)")
            rig.machine.load(memory: rig.harness.bus.ram)
        }
        return problems
    }
}

/// Differential tests of the ATIS unit: the value composer $F16A, the teletype $E713/$F239-$F2E5
/// and the busy delay $F25B. The states come from a lab session that tunes four Chicago ATIS
/// broadcasts (Meigs 121.30 with the keys; Midway 128.05, O'Hare 135.15 and Midway again by
/// poking the COM frequency and search request) at different seasons, hours, winds, cloud bases,
/// temperature offsets and communication rates. Every run compares the whole memory image
/// (stack page excluded) and the exact cycle count with the original on the lab's flat bus.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct AtisTests {
    /// The four broadcasts, each with its composer entry (`-compose`), teletype entry (`-tty`)
    /// and the state after the teletype returned to the main loop (`-done`, IRQs included).
    static let stations = ["meigs", "midway", "ohare", "midway2"]
    static let names = stations.flatMap { ["c3-atis-\($0)-compose", "c3-atis-\($0)-tty", "c3-atis-\($0)-done"] }

    static func stage(_ name: String, timeout: String = "800") -> String {
        "pc:F16A:200 snap:c3-atis-\(name)-compose pc:F239:200 snap:c3-atis-\(name)-tty pc:20A6:\(timeout) snap:c3-atis-\(name)-done"
    }

    static let session = C3Fixtures.prefix + """

        # Meigs 121.30 with the keys: COM MHz 124 -> 121, kHz .85 -> .30 (as re/sessions/atis.txt).
        down:CTRL wait:8 key:C:6 up:CTRL wait:20
        key:,:6 wait:20 key:,:6 wait:20 key:,:6 wait:30
        down:CTRL wait:8 key:C:6 wait:6 key:C:6 up:CTRL wait:12
        key:.:6 wait:20 key:.:6 wait:20 key:.:6 wait:20 key:.:6 wait:20 key:.:6 wait:20
        key:.:6 wait:20 key:.:6 wait:20 key:.:6 wait:20 key:.:6
        \(stage("meigs"))
        # Midway 128.05: winter, 22:00, temperature offset -16, wind 315 at 27, cloud base 183 m,
        # fast typing.
        poke:0985:01 poke:0983:16 poke:095F:F0 poke:09A0:1B poke:09A2:00 poke:09A3:E0 poke:0856:B7 poke:0857:00
        poke:096A:F8
        poke:08B3:05 poke:08B4:28 poke:0937:01 poke:0941:01
        \(stage("midway"))
        # O'Hare 135.15: summer, 03:00, +5, wind 135 at 5, cloud base 8192 m (a ceiling above
        # 65535 ft x 100: the high byte of the product is set).
        poke:0985:03 poke:0983:03 poke:095F:05 poke:09A0:05 poke:09A2:00 poke:09A3:60 poke:0856:00 poke:0857:20
        poke:096A:E0
        poke:08B3:15 poke:08B4:35 poke:0937:01 poke:0941:01
        \(stage("ohare", timeout: "1000"))
        # Midway again: spring, 23:00 (Zulu wraps), +100 (a 3-digit temperature), wind exactly 90
        # at 100, cloud base 31 m (a ceiling of 100 ft).
        poke:0985:02 poke:0983:17 poke:095F:64 poke:09A0:64 poke:09A2:00 poke:09A3:40 poke:0856:1F poke:0857:00
        poke:096A:C0
        poke:08B3:05 poke:08B4:28 poke:0937:01 poke:0941:01
        \(stage("midway2", timeout: "1000"))
        """

    static let states: [String: [UInt8]] = (try? C3Fixtures.load(names, session: session)) ?? [:]

    static func state(_ name: String) throws -> [UInt8] {
        try #require(states[name], "missing lab state \(name)")
    }

    /// The text of a phrase as the composer left it.
    static func phrase(_ ram: [UInt8], _ address: Int) -> String {
        var s = ""
        var a = address
        while ram[a] != 0 { s.append(Character(UnicodeScalar(ram[a]))); a += 1 }
        return s
    }

    /// `count` characters of a phrase from `address`.
    static func field(_ ram: [UInt8], _ address: Int, _ count: Int) -> String {
        String((address..<address + count).map { Character(UnicodeScalar(ram[$0])) })
    }

    // MARK: Fixtures

    @Test func sessionReachesEveryBroadcast() throws {
        #expect(Self.states.count == Self.names.count)
        for station in Self.stations {
            let compose = try Self.state("c3-atis-\(station)-compose")
            let tty = try Self.state("c3-atis-\(station)-tty")
            #expect(compose[0x0941] == 0 && tty[0x0941] == 0, "\(station): the record match clears the one-shot")
            #expect(try Self.state("c3-atis-\(station)-done")[0x0941] == 1)
        }
        // The four records: Meigs (runways 36/18/18/36), Midway (4/13/22/31), O'Hare (4/14/22/32).
        #expect(try Self.state("c3-atis-meigs-compose")[0x0939] == 0x24)
        #expect(try Self.state("c3-atis-midway-compose")[0x093A] == 0x0D)
        #expect(try Self.state("c3-atis-ohare-compose")[0x093B] == 0x16)
    }

    // MARK: composeAtis ($F16A)

    /// The composer at the four record matches, and what it writes.
    @Test func composerAtTheRecordMatches() throws {
        var outputs: [String: [UInt8]] = [:]
        for station in Self.stations {
            let rig = DiffRig(try Self.state("c3-atis-\(station)-compose"))
            rig.run(0xF16A, .init(), station) { $0.composeAtis(); return .init() }
            rig.expectClean("composeAtis \(station)")
            outputs[station] = rig.machine.memoryImage
        }
        let meigs = try #require(outputs["meigs"]), midway = try #require(outputs["midway"])
        let ohare = try #require(outputs["ohare"]), midway2 = try #require(outputs["midway2"])
        // The live parts of the phrases (the rest is the disk's text, compared by the rig): the
        // Zulu hour, temperature, wind, ceiling (the switch $F133 and the hundreds of feet) and runway.
        // Meigs, season 4 (fall 56), 08:00 local, calm, no cloud layer.
        #expect(Self.phrase(meigs, 0xF09E) == "13:00 ZULU")
        #expect(Self.field(meigs, Atis.temperatureDigits, 2) == "56")
        #expect(Self.phrase(meigs, 0xF120) == "WIND  00 AT  0 - ")
        #expect(Self.phrase(meigs, 0xF132) == " ")
        #expect(Self.field(meigs, Atis.runwayDigits, 2) == "36")
        // Midway, winter 20 - 16, 22:00 local, NW wind, 183 m.
        #expect(Self.phrase(midway, 0xF09E) == "03:00 ZULU")
        #expect(Self.field(midway, Atis.temperatureDigits, 2) == "04")
        #expect(Self.phrase(midway, 0xF120) == "WIND 315 AT 27 - ")
        #expect(midway[Atis.ceilingSwitch] == 0x20 && Self.field(midway, Atis.ceilingDigits, 3) == "  6")
        #expect(Self.field(midway, Atis.runwayDigits, 2) == "31")
        // O'Hare: summer 80 + 5, 03:00 local, SE wind, 8192 m = 26,800 ft.
        #expect(Self.phrase(ohare, 0xF09E) == "08:00 ZULU")
        #expect(Self.field(ohare, Atis.temperatureDigits, 2) == "85")
        #expect(Self.phrase(ohare, 0xF120) == "WIND 135 AT  5 - ")
        #expect(ohare[Atis.ceilingSwitch] == 0x20 && Self.field(ohare, Atis.ceilingDigits, 3) == "268")
        #expect(Self.field(ohare, Atis.runwayDigits, 2) == "14")
        // Midway at 23:00 (04 Zulu), 51 + 100 = 151 (tens and units only), 90 degrees, 31 m.
        #expect(Self.phrase(midway2, 0xF09E) == "04:00 ZULU")
        #expect(Self.field(midway2, Atis.temperatureDigits, 2) == "51")
        #expect(Self.phrase(midway2, 0xF120) == "WIND  90 AT  0 - ")
        #expect(midway2[Atis.ceilingSwitch] == 0x20 && Self.field(midway2, Atis.ceilingDigits, 3) == "  1")
        #expect(Self.field(midway2, Atis.runwayDigits, 2) == "13")
    }

    /// Random inputs: any season index (page crossings of $093C,X included), temperatures,
    /// offsets, winds, hours, Zulu offsets, cloud bases and parameter bytes, on twin images that
    /// keep their state from call to call.
    @Test func composerRandomized() throws {
        var rng = TestRandom(seed: 0xF16A)
        for station in ["meigs", "ohare"] {
            let rig = DiffRig(try Self.state("c3-atis-\(station)-compose"))
            for i in 0..<1500 {
                let season: UInt8 = i % 3 == 0 ? rng.byte() : UInt8(1 + rng.next() % 4)
                rig.poke(0x0985, season)
                rig.poke(0x093C &+ Int(season), rng.byte())
                for k in 0..<8 where rng.next() % 3 == 0 { rig.poke(0x0939 + k, rng.byte()) }
                rig.poke(0x095F, [0, 0xF0, 0x05, rng.byte()][Int(rng.next() % 4)])
                rig.poke(0x09A0, [0, 9, 10, 99, 100, rng.byte()][Int(rng.next() % 6)])
                rig.poke16(0x09A2, [0, 0x4000, 0x8000, 0xC000, 0xFFFF, UInt16(truncatingIfNeeded: rng.next())][Int(rng.next() % 6)])
                rig.poke(0x0983, UInt8(rng.next() % 24))
                rig.poke(0x0854, [5, 6, 7, 8, rng.byte()][Int(rng.next() % 5)])
                // Cloud bases around the ceiling's zero and leading-zero edges and the high byte.
                let bases: [UInt16] = [0, 1, 30, 31, 183, 304, 305, 3048, 3049, 7804, 7805, 0x2000, 0xFFFF,
                                       UInt16(truncatingIfNeeded: rng.next())]
                rig.poke16(0x0856, bases[Int(rng.next() % UInt64(bases.count))])
                rig.run(0xF16A, .init(), "\(station) #\(i) season \(season)") { $0.composeAtis(); return .init() }
            }
            rig.expectClean("composeAtis randomized, \(station)")
        }
    }

    // MARK: atisTeletype ($F239)

    /// The whole teletype run of each broadcast: clear, typing with the token expansion, the
    /// per-character delays and the final delay, memory and cycles.
    @Test func teletypeRunsOfTheBroadcasts() throws {
        for station in Self.stations {
            let rig = DiffRig(try Self.state("c3-atis-\(station)-tty"))
            let problems = C3Fixtures.compareLong(rig, 0xF239) { $0.atisTeletype() }
            #expect(problems.isEmpty, "atisTeletype \(station): \(problems.joined(separator: ", "))")
            #expect(rig.machine[0x0941] == 1)
        }
    }

    /// The $E713 entry (a jump to $F239) at a broadcast with a different communication rate.
    @Test func teletypeThroughTheJump() throws {
        let rig = DiffRig(try Self.state("c3-atis-midway-tty"))
        rig.poke(0x096A, 0xFE)
        let problems = C3Fixtures.compareLong(rig, 0xE713) { $0.atisTeletypeJump() }
        #expect(problems.isEmpty, "$E713: \(problems.joined(separator: ", "))")
    }

    /// The port's teletype on the entry state leaves the window as the original did in the
    /// running game (with its raster IRQs during the delays): the bitmaps and the teletype's
    /// zero-page cursor match the lab's state once $E713 returned.
    @Test func teletypeMatchesTheRunningGame() throws {
        for station in Self.stations {
            let m = Machine(memory: try Self.state("c3-atis-\(station)-tty"))
            m.atisTeletype()
            let done = try Self.state("c3-atis-\(station)-done")
            let bitmap = (0x4000..<0x8000).filter { m.mem[$0] != done[$0] }
            #expect(bitmap.isEmpty, "\(station): \(bitmap.count) bitmap bytes differ, first $\(hex16(bitmap.first ?? 0))")
            for a in [0x0941, 0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD] {
                #expect(m.mem[a] == done[a], "\(station): $\(hex16(a)) = \(hex(m.mem[a])) want \(hex(done[a]))")
            }
        }
    }

    /// With the one-shot set the teletype returns at once (13 cycles).
    @Test func teletypeOncePerTune() throws {
        let rig = DiffRig(try Self.state("c3-atis-meigs-done"))
        for v: UInt8 in [1, 2, 0x80, 0xFF] {
            rig.poke(0x0941, v)
            rig.run(0xF239, .init(), "one-shot \(v)") { $0.atisTeletype(); return .init() }
            rig.run(0xE713, .init(), "one-shot \(v) via $E713") { $0.atisTeletypeJump(); return .init() }
        }
        rig.expectClean("teletype one-shot")
        let m = Machine(memory: try Self.state("c3-atis-meigs-done"))
        let start = m.clock.cycles
        m.atisTeletype()
        #expect(m.clock.cycles - start == 13)
    }

    /// Synthetic broadcasts: random letters, digits, spaces and tokens $80-$8C at random places
    /// (including texts that cross pages and fill more than one window page), random
    /// communication rates, a text in zero page (the token path's restored cursor high byte is 0,
    /// so the original falls through into the character path with A = 0), and composer outputs
    /// with and without the ceiling phrase.
    @Test func teletypeSyntheticTexts() throws {
        var rng = TestRandom(seed: 0xF239)
        let base = try Self.state("c3-atis-meigs-tty")
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,-:/ ".utf8)
        // Paths the original took: tokens ($F281), new pages ($F2D3), empty cells ($F2A3, A = 0).
        var tokens = 0, pages = 0, emptyCells = 0
        for i in 0..<14 {
            let rig = DiffRig(base)
            let cpu = rig.harness.cpu
            for pc in [0xF281, 0xF2D3, 0xF2A3] { cpu.traps[pc] = true }
            cpu.trapHandler = { [unowned cpu] pc in
                switch pc {
                case 0xF281: tokens += 1
                case 0xF2D3: pages += 1
                default: if cpu.a == 0 { emptyCells += 1 }
                }
                return false
            }
            let length = i == 13 ? 36 : (i < 4 ? 20 + Int(rng.next() % 40)
                                         : (i < 8 ? 300 + Int(rng.next() % 200) : 60 + Int(rng.next() % 120)))
            var text: [UInt8] = []
            for _ in 0..<length {
                switch rng.next() % 10 {
                case 0: text.append(UInt8(0x80 + rng.next() % 13))
                case 1, 2: text.append(0x20)
                default: text.append(alphabet[Int(rng.next() % UInt64(alphabet.count))])
                }
            }
            text.append(0)
            let at = i == 13 ? 0x0002 : 0xC800 + (i % 2 == 0 ? 0xF0 : Int(rng.next() % 0x100))
            for (k, b) in text.enumerated() { rig.poke(at + k, b) }
            if i == 13 {
                // The zero-page text ($02-$26, clear of the teletype's and the glyph renderer's
                // temporaries) starts with a token, so its restore reads $B9 = 0.
                rig.poke(at, 0x83)
            }
            rig.poke16(0x0958, UInt16(at))
            rig.poke(0x0941, 0)
            rig.poke(0x096A, i == 1 ? 0x00 : 0xF0 + rng.byte() % 0x10)   // 0: 256 passes per character
            if i % 3 == 1 { rig.poke(0xF133, 0) }           // the ceiling phrase cut to ' '
            let problems = C3Fixtures.compareLong(rig, 0xF239) { $0.atisTeletype() }
            #expect(problems.isEmpty, "synthetic text \(i) (\(length) bytes at $\(hex16(at))): \(problems.joined(separator: ", "))")
        }
        #expect(tokens > 100 && pages >= 4 && emptyCells >= 1, "tokens \(tokens), pages \(pages), empty cells \(emptyCells)")
    }

    /// Any byte in a text: tokens past $8C (their offsets are phrase bytes read through $EFFA + n,
    /// so they start mid-phrase), the control bytes $01-$1F and the codes $5B-$7F (drawn as
    /// one-character records whose character is the record's terminator or past the font), on
    /// the fastest rates and in a text that starts one byte before a page boundary.
    @Test func teletypeAnyByte() throws {
        var rng = TestRandom(seed: 0x8D8D)
        let base = try Self.state("c3-atis-ohare-tty")
        var highTokens = 0, controls = 0
        for i in 0..<6 {
            let rig = DiffRig(base)
            let cpu = rig.harness.cpu
            for pc in [0xF281, 0xF2A3] { cpu.traps[pc] = true }
            cpu.trapHandler = { [unowned cpu] pc in
                if pc == 0xF281 { if cpu.y > 0x8C { highTokens += 1 } } else if cpu.a < 0x20 { controls += 1 }
                return false
            }
            var text: [UInt8] = []
            for _ in 0..<(80 + Int(rng.next() % 80)) {
                let b = rng.byte()
                text.append(b == 0 ? 0x20 : b)
            }
            text.append(0)
            let at = i == 0 ? 0xC8FF : 0xC900 + Int(rng.next() % 0x80)
            for (k, b) in text.enumerated() { rig.poke(at + k, b) }
            rig.poke16(0x0958, UInt16(at))
            rig.poke(0x0941, 0)
            rig.poke(0x096A, 0xFC + rng.byte() % 4)
            let problems = C3Fixtures.compareLong(rig, 0xF239) { $0.atisTeletype() }
            #expect(problems.isEmpty, "text \(i) (\(text.count) bytes at $\(hex16(at))): \(problems.joined(separator: ", "))")
            #expect(rig.machine.u16(0xB8) == UInt16(at + text.count), "text \(i): the cursor ends past the 0")
        }
        #expect(highTokens > 100 && controls > 20, "tokens past $8C \(highTokens), control bytes \(controls)")
    }

    /// The typing is charged one delay pass at a time: with a frame-boundary event schedule, no
    /// event fires more than one pass (606 cycles, or 1,791 in the final delay; more only inside
    /// `clearWindow` and a glyph) after it was due, and every frame of the run gets its event.
    @Test func teletypeChargesInSteps() throws {
        let m = Machine(memory: try Self.state("c3-atis-meigs-tty"))
        let frame = 17_095 as UInt64
        m.nextEventCycle = frame
        var lateness: [UInt64] = []
        m.eventHandler = { m in
            lateness.append(m.clock.cycles - m.nextEventCycle)
            m.nextEventCycle += frame
        }
        m.atisTeletype()
        #expect(UInt64(lateness.count) == m.clock.cycles / frame)
        let late = lateness.sorted()
        // clearWindow (about 72,000 cycles) is charged at once by the raster unit.
        #expect(late[late.count * 9 / 10] <= 1_791, "90th percentile lateness \(late[late.count * 9 / 10])")
    }

    // MARK: busyDelay ($F25B)

    /// Y = 1, 2, 3 and 5 against the original: no memory change, A = X = Y = 0, carry set, and the
    /// cycles Y × 456,711 + 5.
    @Test func busyDelayCycles() throws {
        let rig = DiffRig(try Self.state("c3-atis-meigs-done"))
        for y: UInt8 in [1, 2, 3, 5] {
            let o = rig.harness.call(0xF25B, .init(y: y), maxCycles: 10_000_000)
            #expect(o.completed && o.registers.a == 0 && o.registers.x == 0 && o.registers.y == 0 && o.registers.carry)
            let start = rig.machine.clock.cycles
            rig.machine.busyDelay(y: y)
            let cycles = rig.machine.clock.cycles - start
            #expect(cycles == o.cycles && cycles == UInt64(y) * 456_711 + 5, "Y = \(y): \(cycles) want \(o.cycles)")
            #expect(rig.firstDifference() == nil)
        }
        // Y = 0 is 256 passes (not run in the lab: 117 million cycles).
        let m = Machine(memory: [UInt8](repeating: 0, count: Machine.memorySize))
        m.busyDelay(y: 0)
        #expect(m.clock.cycles == 256 * 456_711 + 5)
    }

    /// The delay keeps the event schedule running: every event fires within one X pass.
    @Test func busyDelayChargesInSteps() {
        let m = Machine(memory: [UInt8](repeating: 0, count: Machine.memorySize))
        let frame = 17_095 as UInt64
        m.nextEventCycle = frame
        var worst: UInt64 = 0, count = 0
        m.eventHandler = { m in
            worst = max(worst, m.clock.cycles - m.nextEventCycle)
            count += 1
            m.nextEventCycle += frame
        }
        m.busyDelay(y: 5)
        #expect(m.clock.cycles == 2_283_560)
        #expect(count == Int(2_283_560 / frame) && worst < 1_791)
    }
}
