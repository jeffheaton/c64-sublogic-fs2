import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Keys for the wait-for-key routine $2250: on the original, a trap at $226B (after each poll of
/// the key loop) stores the next scripted key | $80 into `promptKey` $08C4 whenever bit 7 is
/// clear, as the dispatch of a typed key in prompt mode would. Once the script is used up it
/// answers 'E', so a menu always ends. The same script type drives the original (`attach`, on the
/// rig's harness) and the port's own `waitForKey` (`installPollHandler`), so both see the same
/// keys.
final class ScriptedKeys {
    private var keys: [UInt8]
    private(set) var delivered = 0

    init(_ keys: String) { self.keys = Array(keys.utf8) }

    func attach(to harness: RoutineHarness) {
        let bus = harness.bus
        harness.cpu.traps[0x226B] = true
        harness.cpu.trapHandler = { [self, bus] _ in
            if bus.ram[0x08C4] & 0x80 == 0 {
                bus.ram[0x08C4] = (keys.isEmpty ? 0x45 : keys.removeFirst()) | 0x80
                delivered += 1
            }
            return false
        }
    }

    /// Delivers the script to the port: its wait-for-key ($2250) polls through `pollTick`, whose
    /// first step is the poll hook, so the keys are stored there, as the trap at $226B does for
    /// the original. (Only inside wait-for-key, text-input mode $08BA = 1 with the pause count
    /// $08CC set, not from the scenery interpreter's polls during the plot display.)
    func installPollHandler(on machine: Machine) {
        machine.pollHandler = { [self] m in
            if m[0x08BA] == 1, m[0x08CC] != 0, m[0x08C4] & 0x80 == 0 {
                m[0x08C4] = (keys.isEmpty ? 0x45 : keys.removeFirst()) | 0x80
                delivered += 1
            }
        }
    }
}

/// Differential tests of the course plotter ($F627-$F7DA) and the database info screen (overlay
/// 4, $A86A). The states come from lab sessions: the Q menu before and after a recording, normal
/// and precision recording during a takeoff and turn, the plot displayed in the front and radar
/// views, plotter off; and the CTRL-E screen with overlay 4 loaded. The port runs its own
/// wait-for-key ($2250, keys from `ScriptedKeys`) and scenery interpreter ($8006). Every run
/// compares the whole memory image (stack page excluded) and the exact cycle count with the
/// original.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct CoursePlotterTests {
    static let names = ["c3-cp-menu", "c3-cp-rec1", "c3-cp-rec2", "c3-cp-prec", "c3-cp-menu2", "c3-cp-display",
                        "c3-cp-radar", "c3-cp-off"]

    /// As re/sessions/plotter.txt, stopping at the menu entry and at the plotter's every-pass call.
    static let session = C3Fixtures.prefix + """

        # Q: the menu (no recording yet); A: normal recording; E: back to flight.
        key:Q:6 pc:F627:100 snap:c3-cp-menu
        pc:2250:100 wait:30 key:A:6 wait:30 key:E:6 wait:120
        # Take off and climb, then a right turn.
        key:;:150 wait:550 key:B:6 wait:20 key:B:6 wait:20 key:B:6 wait:900
        pc:F6E2:100 snap:c3-cp-rec1
        key:H:6 wait:20 key:H:6 wait:20 key:H:6 wait:1500
        pc:F6E2:100 snap:c3-cp-rec2
        key:G:6 wait:600
        # C: precision recording.
        key:Q:6 pc:2250:600 wait:30 key:C:6 wait:30 key:E:6 wait:600
        pc:F6E2:100 snap:c3-cp-prec
        # B: display the plot in the front view, then in the radar view.
        key:Q:6 pc:F627:100 snap:c3-cp-menu2
        pc:2250:100 wait:30 key:B:6 wait:30 key:E:6 wait:200
        pc:F6E2:100 snap:c3-cp-display
        key:4:6 wait:200 pc:F6E2:100 snap:c3-cp-radar
        key:5:6 wait:60
        # D: off.
        key:Q:6 pc:2250:600 wait:30 key:D:6 wait:30 key:E:6 wait:200
        pc:F6E2:100 snap:c3-cp-off
        """

    static let states: [String: [UInt8]] = (try? C3Fixtures.load(names, session: session)) ?? [:]

    static func state(_ name: String) throws -> [UInt8] {
        try #require(states[name], "missing lab state \(name)")
    }

    // MARK: Fixtures

    @Test func sessionRecordsAndDisplays() throws {
        #expect(Self.states.count == Self.names.count)
        let menu = try Self.state("c3-cp-menu"), rec2 = try Self.state("c3-cp-rec2")
        #expect(menu[0x0E86] == 0 && menu[0x0E82] == 0)
        // A recording at scale 6 has grown past the header.
        #expect(rec2[0x0E82] == 1 && rec2[0xD000] == 0x07 && rec2[0xD001] == 6 && rec2[0x0E84] == 0xD0
                && rec2[0x0E83] > 0x16)
        #expect(try Self.state("c3-cp-prec")[0xD001] == 4)
        #expect(try Self.state("c3-cp-menu2")[0x0E86] == 1)
        #expect(try Self.state("c3-cp-display")[0x0E82] == 2)
        #expect(try Self.state("c3-cp-radar")[0x0836] == 1)
        #expect(try Self.state("c3-cp-off")[0x0E82] == 0)
    }

    // MARK: coursePlotterMenu ($F627)

    /// The menu with key scripts: each option, invalid keys, and several options in one visit;
    /// before any recording (B does nothing) and with a recording (B displays).
    @Test func menuKeyScripts() throws {
        let scripts = ["E", "AE", "CE", "BE", "DE", "XQ5E", "ABCDBE", "CAE"]
        for state in ["c3-cp-menu", "c3-cp-menu2"] {
            for script in scripts {
                let rig = DiffRig(try Self.state(state))
                let original = ScriptedKeys(script), port = ScriptedKeys(script)
                original.attach(to: rig.harness)
                port.installPollHandler(on: rig.machine)
                let problems = C3Fixtures.compareLong(rig, 0xF627, maxCycles: 100_000_000) { $0.coursePlotterMenu() }
                #expect(problems.isEmpty, "\(state) keys \(script): \(problems.joined(separator: ", "))")
                #expect(original.delivered == script.count && port.delivered == script.count)
            }
        }
    }

    /// What the menu leaves: A writes the list header at $D000 from the position.
    @Test func menuRecordingHeader() throws {
        let m = Machine(memory: try Self.state("c3-cp-menu"))
        ScriptedKeys("AE").installPollHandler(on: m)
        m.coursePlotterMenu()
        #expect(m[0xD000] == 0x07 && m[0xD001] == 6 && m[0x0E80] == 0x0A && m[0x0E82] == 1 && m[0x0E86] == 1)
        #expect((0..<12).allSatisfy { m[0xD002 + $0] == m[0x5A + $0] })
        #expect(Array((0xD00E...0xD016).map { m[$0] }) == [0x1C, 0x01, 0, 0, 0, 0, 0, 0, 0x79])
        #expect(m.u16(0x0E83) == 0xD016 && m[0x08BC] == 2 && m[0x01] == 0x35 && m[0x4B] == 0x35)
    }

    // MARK: plotterDisplay ($F6E2)

    /// Recording passes from the lab states, with random positions, countdowns, intervals, scales
    /// and record pointers around the $DFE0 limit; twin images keep their state from call to call.
    @Test func recordingPasses() throws {
        var rng = TestRandom(seed: 0xF703)
        var appended = 0, full = 0, unscaled = 0
        for name in ["c3-cp-rec1", "c3-cp-rec2", "c3-cp-prec"] {
            let rig = DiffRig(try Self.state(name))
            for i in 0..<600 {
                if i % 5 == 0 { rig.poke(0x0E81, [1, 1, 2, 0, rng.byte()][Int(rng.next() % 5)]) }
                if i % 7 == 0 { rig.poke(0x0E80, [10, 2, 1, 0, rng.byte()][Int(rng.next() % 5)]) }
                if i % 11 == 0 { rig.poke(0x0E85, [6, 4, 4, 5, rng.byte()][Int(rng.next() % 5)]) }
                if i % 13 == 0 {
                    let pointers: [UInt16] = [0xD016, 0xD0F9, 0xD1FE, 0xDFD9, 0xDFDF, 0xDFE0, 0xDFE1, 0xDFFF, 0xE000,
                                              0x5FE0, 0x5FE1]
                    rig.poke16(0x0E83, pointers[Int(rng.next() % UInt64(pointers.count))])
                }
                // Move: small steps, and now and then a jump of the whole 32-bit coordinate.
                for axis in 0..<3 {
                    let a = 0x5A + 4 * axis
                    if rng.next() % 9 == 0 {
                        for k in 0..<4 { rig.poke(a + k, rng.byte()) }
                    } else {
                        let v = UInt32(rig.harness.bus.ram[a]) | UInt32(rig.harness.bus.ram[a + 1]) << 8
                            | UInt32(rig.harness.bus.ram[a + 2]) << 16 | UInt32(rig.harness.bus.ram[a + 3]) << 24
                        let n = v &+ UInt32(truncatingIfNeeded: Int32(Int(rng.next() % 0x4000) - 0x2000))
                        for k in 0..<4 { rig.poke(a + k, UInt8(truncatingIfNeeded: n >> (8 * k))) }
                    }
                }
                rig.poke(0x0E82, 1)
                let ram = rig.harness.bus.ram
                let due = ram[0x0E81] == 1, pointer = Int(ram[0x0E83]) | Int(ram[0x0E84]) << 8
                rig.run(0xF6E2, .init(), "\(name) pass \(i)") { $0.plotterDisplay(); return .init() }
                if due {
                    if rig.harness.bus.ram[0x0E83] != ram[0x0E83] {
                        appended += 1
                        if ram[0x0E85] == 4 { unscaled += 1 }
                    } else if pointer > 0xDFE0 {
                        full += 1
                    }
                }
            }
            rig.expectClean("recording passes, \(name)")
        }
        #expect(appended > 100 && unscaled > 20 && full > 10, "appended \(appended), at scale 4 \(unscaled), list full \(full)")
    }

    /// A recording from the header to the full list with a point on every pass (interval 1),
    /// half of it at each scale, while the position wanders on all three axes (deltas of both
    /// signs): the list holds 578 points (the last at $DFDD, the end marker at $DFE4), then the
    /// room test stops the recorder for good.
    @Test func recordingFillsTheList() throws {
        var rng = TestRandom(seed: 0xDFE4)
        let rig = DiffRig(try Self.state("c3-cp-rec1"))
        rig.poke16(0x0E83, 0xD016)
        rig.poke(0x0E80, 1)
        rig.poke(0x0E81, 1)
        rig.poke(0x0E82, 1)
        var points = 0
        for i in 0..<640 {
            if i % 290 == 0 { rig.poke(0x0E85, i == 0 ? 6 : 4) }
            for axis in 0..<3 {
                let a = 0x5B + 4 * axis
                let v = UInt32(rig.harness.bus.ram[a]) | UInt32(rig.harness.bus.ram[a + 1]) << 8
                    | UInt32(rig.harness.bus.ram[a + 2]) << 16
                let n = v &+ UInt32(truncatingIfNeeded: Int32(Int(rng.next() % 0x2000) - 0x1000))
                for k in 0..<3 { rig.poke(a + k, UInt8(truncatingIfNeeded: n >> (8 * k))) }
            }
            let before = rig.harness.bus.ram[0x0E83]
            rig.run(0xF6E2, .init(), "pass \(i)") { $0.plotterDisplay(); return .init() }
            if rig.harness.bus.ram[0x0E83] != before { points += 1 }
        }
        rig.expectClean("filling the list")
        let ram = rig.harness.bus.ram
        #expect(points == 578 && ram[0x0E83] == 0xE4 && ram[0x0E84] == 0xDF && ram[0xDFE4] == 0x79,
                "\(points) points, end $\(hex16(Int(ram[0x0E83]) | Int(ram[0x0E84]) << 8))")
        #expect(ram[0xDFDD] == 0x02 && ram[0x0E81] == 1)
    }

    /// The plot run through the scenery interpreter (ported) in the front and radar views, and
    /// the other modes.
    @Test func displayAndIdleModes() throws {
        for name in ["c3-cp-display", "c3-cp-radar", "c3-cp-rec2", "c3-cp-off"] {
            let rig = DiffRig(try Self.state(name))
            for mode: UInt8 in [2, 0, 3, 0x80, 0xFF, 2] {
                rig.poke(0x0E82, mode)
                rig.run(0xF6E2, .init(), "\(name) mode \(mode)") { $0.plotterDisplay(); return .init() }
                if mode == 2 {
                    // The interpreter ran the whole list from $D000: it stopped at the end marker.
                    let ram = rig.harness.bus.ram
                    #expect(ram[0x8B] == ram[0x0E83] && ram[0x8C] == ram[0x0E84] && ram[0x01] == 0x35,
                            "\(name): the interpreter stopped at $\(hex16(Int(ram[0x8B]) | Int(ram[0x8C]) << 8))")
                }
            }
            rig.expectClean("display modes, \(name)")
        }
    }

    /// The bank switches.
    @Test func bankSwitches() throws {
        let rig = DiffRig(try Self.state("c3-cp-rec1"))
        for _ in 0..<3 {
            rig.run(0xF7B0, .init(), "$F7B0") { $0.bankOutIo(); return .init() }
            rig.run(0xF7B4, .init(), "$F7B4") { $0.bankInIo(); return .init() }
        }
        rig.expectClean("bank switches")
    }
}

/// The database info screen (CTRL-E): overlay 4 at $A7E0, entry $A86A.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct DatabaseInfoTests {
    static let names = ["c3-db-screen", "c3-db-key"]

    /// As re/sessions/database.txt: CTRL-E, stop at $A86A once overlay 4 is in, then hold SPACE
    /// and stop where the screen returns.
    static let session = C3Fixtures.prefix + """

        down:CTRL wait:8 key:E:6 up:CTRL wait:4
        pc:A86A:600 snap:c3-db-screen
        pc:2250:100 wait:30 down:SPACE pc:A877:100 snap:c3-db-key up:SPACE
        """

    static let states: [String: [UInt8]] = (try? C3Fixtures.load(names, session: session)) ?? [:]

    @Test func screenAgainstTheOriginal() throws {
        let screen = try #require(Self.states["c3-db-screen"])
        #expect(screen[0xA7E0] == 0x78 && screen[0xA7E1] == 0xA8, "overlay 4 is resident")
        for key in [" ", "E", "Q"] {
            let rig = DiffRig(screen)
            let original = ScriptedKeys(key), port = ScriptedKeys(key)
            original.attach(to: rig.harness)
            port.installPollHandler(on: rig.machine)
            let problems = C3Fixtures.compareLong(rig, 0xA86A, maxCycles: 50_000_000) { $0.databaseInfoScreen() }
            #expect(problems.isEmpty, "key \(key): \(problems.joined(separator: ", "))")
        }
    }

    /// The port's screen matches the running game's window once the key was read.
    @Test func screenMatchesTheRunningGame() throws {
        let screen = try #require(Self.states["c3-db-screen"]), done = try #require(Self.states["c3-db-key"])
        let m = Machine(memory: screen)
        ScriptedKeys(" ").installPollHandler(on: m)
        m.databaseInfoScreen()
        let bitmap = (0x4000..<0x8000).filter { m.mem[$0] != done[$0] }
        #expect(bitmap.isEmpty, "\(bitmap.count) bitmap bytes differ, first $\(hex16(bitmap.first ?? 0))")
        // The record list was drawn: the first record's row and x.
        #expect(screen[0xA802] == 0x0A && screen[0xA803] == 0x0A)
    }
}
