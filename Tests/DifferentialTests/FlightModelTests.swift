import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Differential tests of the flight model and engine ($2E92-$3772, $E716-$E7F1, $EA84-$EB62,
/// $EE6B-$F079, $F8AF-$F9F8): every call runs the original routine in the lab and its port on twin
/// memory images (`DiffRig`) and compares the whole image (stack page excluded), the cycle count
/// and the SID stores. The states come from three recorded flights (ground roll, braking, climb,
/// cruise, a stall series, a steep spiral into a crash, slew, splash, reality mode with failures
/// and wind) plus random perturbations of the state variables. The routines of other units these
/// call are the ports too.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct FlightModelTests {
    // MARK: Recorded states

    /// Lab sessions whose `snap:` steps cache the states in build/testdata. Each starts like
    /// re/sessions/regular.txt (color display, regular flight at Meigs).
    static let boot = """
        pc:2250:9000 key:A:12
        pc:2250:600 key:B:12
        pc:204B:3000
        """

    /// Take-off roll, braking, lift-off, climb, cruise, then throttle off and full up elevator:
    /// a stall series (horn, stall timer, porpoising) ending in a crash.
    static let flightSession = boot + """

        wait:300 snap:fm-idle
        poke:0AC9:78 wait:300 poke:0AC9:78
        wait:240 snap:fm-roll1
        wait:600 snap:fm-roll2
        key:SPACE:6 wait:40 key:SPACE:6 wait:40 snap:fm-brake
        key:B:6 wait:60 key:B:6 wait:60
        wait:600 snap:fm-liftoff
        wait:3600 snap:fm-climb
        key:T:6 wait:60
        wait:600 snap:fm-cruise
        poke:0AC9:00
        key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60
        key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60 key:B:6 wait:60
        wait:100 snap:fm-stall1
        wait:100 snap:fm-stall2
        wait:100 snap:fm-stall3
        wait:100 snap:fm-stall4
        wait:100 snap:fm-stall5
        wait:100 snap:fm-stall6
        wait:100 snap:fm-stall7
        wait:100 snap:fm-stall8
        wait:1500 snap:fm-reload
        """
    static let flightStates = ["fm-idle", "fm-roll1", "fm-roll2", "fm-brake", "fm-liftoff", "fm-climb", "fm-cruise",
                               "fm-stall1", "fm-stall2", "fm-stall3", "fm-stall4", "fm-stall5", "fm-stall6",
                               "fm-stall7", "fm-stall8", "fm-reload"]

    /// Climb, then a steep right spiral (bank through 180°, γ to −67°, 115 m/s) into a crash
    /// (crash code pending, then the message's delay).
    static let bankSession = boot + """

        wait:300
        poke:0AC9:78
        wait:1200
        key:B:6 wait:60 key:B:6 wait:60
        wait:4800 snap:fm-bank0
        key:T:6 wait:60
        key:H:6 wait:60 key:H:6 wait:60 key:H:6 wait:60 key:H:6 wait:60 key:H:6 wait:60
        wait:60 snap:fm-bank1
        wait:60 snap:fm-bank2
        wait:60 snap:fm-bank3
        wait:60 snap:fm-bank4
        wait:60 snap:fm-bank5
        wait:60 snap:fm-bank6
        wait:60 snap:fm-bank7
        wait:60 snap:fm-bank8
        wait:60 snap:fm-bank9
        wait:60 snap:fm-bank10
        wait:60 snap:fm-bank11
        wait:60 snap:fm-bank12
        """
    static let bankStates = (0...12).map { "fm-bank\($0)" }

    /// Moved into the lake on the ground (splash), the reload; wind layers poked in; slew mode
    /// with every rate; out of slew in mid-air (a crash); then reality mode (reliability 0) with
    /// the wind, flying low over the water with a failure.
    static let miscSession = boot + """

        wait:300
        poke:5C:24
        wait:60 snap:fm-water0
        wait:60 snap:fm-water1
        wait:60 snap:fm-water2
        wait:60 snap:fm-water3
        wait:60 snap:fm-water4
        wait:60 snap:fm-water5
        wait:6000 snap:fm-reloaded
        poke:098E:64 poke:098F:00 poke:0990:C8 poke:0991:00 poke:0992:2C poke:0993:01
        poke:0994:28 poke:0997:C0 poke:0998:1E poke:099B:80 poke:099C:14 poke:099F:40 poke:09A0:0A poke:09A3:20
        poke:0966:01
        wait:120 snap:fm-slew0
        key:;:6 wait:60 key:;:6 wait:60 key:;:6 wait:60
        wait:200 snap:fm-slew1
        key:F:6 wait:60 key:F:6 wait:60 key:B:6 wait:60 key:B:6 wait:60
        wait:200 snap:fm-slew2
        key:9:6 wait:60 key:9:6 wait:60 key:R:6 wait:60 key:V:6 wait:60
        wait:200 snap:fm-slew3
        key:8:6 wait:60 key:8:6 wait:60 key:8:6 wait:60 key:8:6 wait:60 key:8:6 wait:60 key:Y:6 wait:60 key:N:6 wait:60 key:N:6 wait:60
        wait:300 snap:fm-slew4
        key:G:6 wait:60 key:Z:6 wait:60
        wait:200 snap:fm-slew5
        poke:0966:00
        wait:60 snap:fm-unslew1
        wait:200 snap:fm-unslew2
        wait:6000 snap:fm-reloaded2
        poke:098E:64 poke:098F:00 poke:0990:C8 poke:0991:00 poke:0992:2C poke:0993:01
        poke:0994:28 poke:0997:C0 poke:0998:1E poke:099B:80 poke:099C:14 poke:099F:40 poke:09A0:0A poke:09A3:20
        poke:0967:01 poke:09A4:00 poke:0AC9:78
        wait:900
        poke:0AAC:0C poke:0AAE:0C
        wait:600 snap:fm-real1
        wait:600 snap:fm-real2
        wait:600 snap:fm-real3
        wait:600 snap:fm-real4
        wait:600 snap:fm-real5
        wait:600 snap:fm-real6
        wait:600 snap:fm-real7
        wait:600 snap:fm-real8
        """
    static let miscStates = (0...5).map { "fm-water\($0)" } + ["fm-reloaded"] + (0...5).map { "fm-slew\($0)" }
        + ["fm-unslew1", "fm-unslew2", "fm-reloaded2"] + (1...8).map { "fm-real\($0)" }

    /// Runs a session once (if its states are not cached yet) and returns its named states. The
    /// last name is the session's final snapshot; the others come from its `snap:` steps.
    static func load(_ names: [String], session: String) throws -> [(String, [UInt8])] {
        let dir = Original.repoRoot.appendingPathComponent("build/testdata", isDirectory: true)
        let cached = names.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).snap").path)
        }
        if !cached {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(names.last!).snap"))
        }
        _ = try Original.snapshot(names.last!, session: session)
        return try names.map { ($0, try Original.snapshot($0, session: session)) }
    }

    /// Every recorded state, plus the regular-flight snapshot.
    static let states: [(String, [UInt8])] = {
        var all: [(String, [UInt8])] = []
        if let r = try? Original.regularFlight() { all.append(("regular", r)) }
        for (names, session) in [(flightStates, flightSession), (bankStates, bankSession), (miscStates, miscSession)] {
            if let s = try? load(names, session: session) { all += s }
        }
        return all
    }()

    @Test func recordedStatesCoverTheFlightRegimes() throws {
        let byName = Dictionary(uniqueKeysWithValues: Self.states)
        func value(_ name: String, _ address: Int) -> UInt8 { byName[name]?[address] ?? 0 }
        #expect(Self.states.count == 1 + Self.flightStates.count + Self.bankStates.count + Self.miscStates.count)
        // Airborne climb, a stall with the horn and timer, a spiral past 90° of bank, slew,
        // reality mode with a failure, and water in front.
        #expect(value("fm-climb", 0x0A12) == 0 && Int(value("fm-climb", 0x5F)) | Int(value("fm-climb", 0x60)) << 8 > 100)
        #expect(Self.states.contains { $0.1[0x09DD] >= 0x24 && $0.1[0x09DD] < 0x80 && $0.1[0x0E7B] != 0 })
        #expect(Self.states.contains { $0.1[0x09E1] >= 0x40 && $0.1[0x09E1] < 0xC0 })
        #expect(value("fm-slew3", 0x0966) == 1)
        #expect(Self.states.contains { $0.1[0x0967] == 1 && $0.1[0x0942] != 0xFF })
        #expect(Self.states.contains { $0.1[0x50DE] == 0x55 })               // water under the probe
    }

    // MARK: Rig

    /// `DiffRig` with the SID stores mirrored into the port's I/O page (the flat bus stores them
    /// in RAM) and compared in order.
    final class FlightRig {
        let rig: DiffRig
        private(set) var sidFailures: [String] = []

        init(_ ram: [UInt8]) {
            rig = DiffRig(ram)
        }

        var machine: Machine { rig.machine }
        func poke(_ a: Int, _ v: UInt8) { rig.poke(a, v) }
        func poke16(_ a: Int, _ v: UInt16) { rig.poke16(a, v) }
        func peek(_ a: Int) -> UInt8 { rig.harness.bus.ram[a] }

        func run(_ address: UInt16, _ regs: RoutineHarness.Registers = .init(),
                 _ label: @autoclosure () -> String, port: (Machine) -> Void) {
            rig.harness.bus.ioWrites.removeAll()
            let before = rig.machine.io.sidWrites.count
            rig.run(address, regs, label()) { m in
                port(m)
                for w in m.io.sidWrites[before...] { m.mem[0xD400 + Int(w.reg)] = w.value }
                return .init()
            }
            let original = rig.harness.bus.ioWrites
                .filter { (0xD400...0xD41F).contains(Int($0.address)) }
                .map { "\(Int($0.address) - 0xD400):\($0.value)" }
            let ported = rig.machine.io.sidWrites[before...].map { "\($0.reg):\($0.value)" }
            if original != ported && sidFailures.count < 8 {
                sidFailures.append("\(label()): SID \(ported) want \(original)")
            }
        }

        func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            rig.expectClean(what, sourceLocation: sourceLocation)
            #expect(sidFailures.isEmpty, "\(what): \(sidFailures.joined(separator: "\n"))",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: Perturbation helpers

    /// Pokes a random byte, an edge byte, or leaves the address alone.
    static func perturb(_ rig: FlightRig, _ rng: inout TestRandom, _ address: Int, chance: UInt64 = 2) {
        guard rng.next() % chance == 0 else { return }
        rig.poke(address, rng.edgeOrRandomByte())
    }

    static func perturb16(_ rig: FlightRig, _ rng: inout TestRandom, _ address: Int, chance: UInt64 = 2) {
        guard rng.next() % chance == 0 else { return }
        rig.poke16(address, rng.edgeOrRandomWord())
    }

    // MARK: $2E92 / $2F07 control coefficients

    @Test func controlCoefficientsMatchOriginal() throws {
        var rng = TestRandom(seed: 0x2E92)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            rig.run(0x2E92, .init(a: rng.byte()), "\(name) $2E92") { $0.controlCoefficients() }
            rig.run(0x2F07, .init(), "\(name) $2F07") { $0.rebuildWingCoefficients() }
            for i in 0..<300 {
                for a in [0x0ABD, 0x0AA4, 0x09F2] { Self.perturb(rig, &rng, a) }
                for a in [0x0A70, 0x0A68, 0x0A6A, 0x0A66, 0x0A25, 0x09E2, 0x0A1D, 0x09F6] {
                    Self.perturb16(rig, &rng, a, chance: 4)
                }
                if rng.bool() {
                    rig.run(0x2E92, .init(a: rng.byte()), "\(name) $2E92 #\(i)") { $0.controlCoefficients() }
                } else {
                    rig.run(0x2F07, .init(), "\(name) $2F07 #\(i)") { $0.rebuildWingCoefficients() }
                }
            }
            rig.expectClean("control coefficients, \(name)")
        }
    }

    // MARK: $2F45 aerodynamics

    /// The aerodynamic inputs: flight state, controls, coefficients, and the constants.
    static let aeroWords = [0x09DE, 0x09E0, 0x0A4C, 0x0AAB, 0x0A21, 0x0A23, 0x0A48, 0x09DA, 0x0A15, 0x09F4,
                            0x0ABC, 0x0A1D, 0x0A25]
    static let aeroConstants = [0x0A78, 0x0A27, 0x0A52, 0x09E6, 0x09E4, 0x0A30, 0x0A74]
    static let aeroBytes = [0x08D4, 0x5F, 0x60, 0x0E7B, 0x0E75, 0x0A12, 0x0A0A, 0x0966]

    static func perturbAero(_ rig: FlightRig, _ rng: inout TestRandom) {
        for a in aeroWords { perturb16(rig, &rng, a, chance: 3) }
        for a in aeroConstants { perturb16(rig, &rng, a, chance: 12) }
        for a in aeroBytes { perturb(rig, &rng, a, chance: 4) }
        if rng.next() % 4 == 0 { rig.poke(0x0966, 0) }                 // mostly not slewing
        if rng.next() % 3 == 0 { rig.poke(0x09DD, rng.pick([0x20, 0x21, 0x23, 0x24, 0x25, 0xE6, 0xE7, 0xE8, 0x7F, 0x80])) }
        if rng.next() % 3 == 0 { rig.poke(0x0A4D, rng.byte() & 0x7F) }  // airspeeds the game produces
    }

    @Test func aeroUpdateMatchesOriginal() throws {
        var rng = TestRandom(seed: 0x2F45)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            rig.run(0x2F45, .init(), "\(name) $2F45") { $0.aeroUpdate() }
            for i in 0..<120 {
                Self.perturbAero(rig, &rng)
                rig.run(0x2F45, .init(), "\(name) $2F45 #\(i)") { $0.aeroUpdate() }
            }
            rig.expectClean("aeroUpdate, \(name)")
        }
    }

    /// γ across every high byte (the ±90° reflection), with the rate pushing it over.
    @Test func aeroUpdateFlightPathReflection() throws {
        var rng = TestRandom(seed: 0x32A8)
        let rig = FlightRig(try #require(Self.states.first { $0.0 == "fm-bank6" }?.1 ?? Self.states.first?.1))
        for high in 0...255 {
            for _ in 0..<6 {
                rig.poke(0x0966, 0)
                rig.poke16(0x09DE, UInt16(high) << 8 | UInt16(rng.byte()))
                rig.poke16(0x09E0, rng.word())
                rig.poke16(0x0A4A, rng.word())
                rig.poke(0x0E75, rng.bool() ? 0 : 3)
                rig.poke(0x0A12, rng.bool() ? 0 : 0xFF)
                rig.run(0x2F45, .init(), "γ $\(String(high, radix: 16))xx") { $0.aeroUpdate() }
            }
        }
        rig.expectClean("aeroUpdate reflection")
    }

    /// Exact flight-path angles at the reflection edges ($4000, $8000, $C000 and their
    /// neighbors). The γ gain table is zeroed on both sides and V_hi is a multiple of 16, so the
    /// γ rate is exactly 0 and γ reaches the reflection unchanged.
    @Test func aeroUpdateFlightPathEdges() throws {
        var rng = TestRandom(seed: 0x32BA)
        let rig = FlightRig(try #require(Self.states.first { $0.0 == "fm-bank6" }?.1 ?? Self.states.first?.1))
        for a in 0x0E1A...0x0E2A { rig.poke(a, 0) }          // t[i] and t[i+1] for every i
        let edges: [UInt16] = [0x0000, 0x0001, 0x00FF, 0x3F00, 0x3FFF, 0x4000, 0x4001, 0x40FF, 0x7F00, 0x7FFF,
                               0x8000, 0x8001, 0x80FF, 0xBF00, 0xBFFF, 0xC000, 0xC001, 0xC0FF, 0xFF00, 0xFFFF]
        for gamma in edges {
            for _ in 0..<4 {
                rig.poke(0x0966, 0)
                rig.poke16(0x09DE, gamma)
                rig.poke16(0x09E0, rng.word())
                rig.poke16(0x0A13, rng.word())
                rig.poke(0x0A4C, rng.byte()); rig.poke(0x0A4D, rng.pick([0x00, 0x10, 0x20, 0x30, 0x40]))
                rig.poke(0x0E75, rng.bool() ? 0 : 3)
                rig.poke(0x0A12, rng.bool() ? 0 : 0xFF)
                rig.run(0x2F45, .init(), "γ $\(String(gamma, radix: 16))") { $0.aeroUpdate() }
                #expect(rig.peek(0x09FA) == 0 && rig.peek(0x09FB) == 0, "γ rate not zeroed")
            }
        }
        rig.expectClean("aeroUpdate γ edges")
    }

    // MARK: $32EE integrator and ground contact

    static func perturbIntegrator(_ rig: FlightRig, _ rng: inout TestRandom) {
        for a in [0x34, 0x08CA, 0xC4, 0x0A11, 0x0A12, 0x0ACA, 0x0A2F, 0x22, 0x63, 0x0A51, 0x6F, 0x09DF] {
            perturb(rig, &rng, a, chance: 3)
        }
        for a in [0x09FE, 0x0A4C, 0x0A46, 0x0A13, 0x09E8, 0x0A3E, 0x0A2B, 0x0A2D, 0x09DC, 0x0A0B, 0x09E0, 0x09DE] {
            perturb16(rig, &rng, a, chance: 3)
        }
        for a in [0x0A32, 0x0A64] { perturb16(rig, &rng, a, chance: 10) }
        if rng.next() % 5 == 0 { rig.poke16(0x0E76, rng.edgeOrRandomWord()) } else if rng.bool() { rig.poke16(0x0E76, 0) }
        // Positions near the wraps and the ground.
        for base in [0x5A, 0x62] where rng.next() % 4 == 0 {
            for k in 0..<4 { rig.poke(base + k, rng.edgeOrRandomByte()) }
        }
        if rng.next() % 3 == 0 {
            rig.poke(0x5E, rng.byte())
            rig.poke(0x5F, rng.pick([0, 1, 2, 3, 4, 0xFF, rng.byte()]))
            rig.poke(0x60, rng.pick([0, 0, 0xFF, 0x7F, 0x80, rng.byte()]))
        }
        // A reposition re-applies the editor altitude and brakes on the ground.
        if rng.next() % 6 == 0 {
            rig.poke(0x0A83, rng.pick([1, 2, 0x0C, 0xFF]))
            rig.poke16(0x096F, rng.edgeOrRandomWord())
            rig.poke16(0x0A87, rng.pick([0, 1, 180, 0xFFFF, 0x8000, rng.word()]))
        } else {
            rig.poke(0x0A83, 0)
        }
    }

    @Test func integrateFlightMatchesOriginal() throws {
        var rng = TestRandom(seed: 0x32EE)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            rig.run(0x32EE, .init(), "\(name) $32EE") { $0.integrateFlight() }
            for i in 0..<100 {
                Self.perturbIntegrator(rig, &rng)
                rig.run(0x32EE, .init(), "\(name) $32EE #\(i)") { $0.integrateFlight() }
            }
            rig.expectClean("integrateFlight, \(name)")
        }
    }

    /// Ground contact at every vertical-speed and bank high byte: crashes ($356D with the crash
    /// sound), touchdowns, and leaving the ground.
    @Test func groundContactCrashAndTouchdown() throws {
        var rng = TestRandom(seed: 0x3515)
        let rig = FlightRig(try #require(Self.states.first { $0.0 == "fm-liftoff" }?.1 ?? Self.states.first?.1))
        for vs in stride(from: 0, through: 255, by: 3) {
            for bank in stride(from: 0, through: 255, by: 17) {
                rig.poke(0x0A83, 0)
                rig.poke(0x0A51, UInt8(vs))
                rig.poke16(0x09E0, UInt16(bank) << 8 | UInt16(rng.byte()))
                rig.poke16(0x09FE, 0); rig.poke16(0x0A2B, 0); rig.poke16(0x0A2D, 0)
                rig.poke(0x5E, rng.byte()); rig.poke(0x5F, rng.pick([0, 1, 2, 3, 4])); rig.poke(0x60, 0)
                rig.poke16(0x09D8, 0); rig.poke16(0x0A4C, rng.word() & 0x3FFF)
                rig.poke(0x0A11, rng.bool() ? 0 : 0xFF)
                rig.poke(0x34, rig.peek(0x08CA) &+ UInt8(rng.next() % 40))
                rig.run(0x32EE, .init(), "vs $\(String(vs, radix: 16)) bank $\(String(bank, radix: 16))") {
                    $0.integrateFlight()
                }
            }
        }
        rig.expectClean("ground contact")
    }

    /// dt at every jiffy gap with several stale `$C4` values: the linear range, the $7Fxx
    /// saturation and the 16-bit wrap every 120 jiffies. Each gap starts from the same state.
    @Test func integrateFlightEveryJiffyGap() throws {
        var rng = TestRandom(seed: 0x3303)
        let base = try #require(Self.states.first { $0.0 == "fm-climb" }?.1 ?? Self.states.first?.1)
        for gap in 0...255 {
            let rig = FlightRig(base)
            for stale in [UInt8(0), 1, 0x80, 0xFF, rng.byte()] {
                rig.poke(0x34, rig.peek(0x08CA) &+ UInt8(gap))
                rig.poke(0xC4, stale)
                rig.run(0x32EE, .init(), "gap \(gap) $C4 $\(String(stale, radix: 16))") { $0.integrateFlight() }
            }
            rig.expectClean("jiffy gap \(gap)")
        }
    }

    // MARK: $35BD density, auto-level, service

    @Test func densityAutoLevelAndServiceMatchOriginal() throws {
        var rng = TestRandom(seed: 0x35BD)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            rig.run(0x35BD, .init(), "\(name) $35BD") { $0.densityAndAutoLevel() }
            for i in 0..<200 {
                Self.perturb16(rig, &rng, 0x0830)
                Self.perturb16(rig, &rng, 0x09E0)
                rig.poke(0x0ABD, rng.next() % 3 == 0 ? rng.byte() : 0)
                rig.poke(0x0838, rng.pick([0, 0, 1, 2, 3, rng.byte()]))
                rig.poke(0x0A4D, rng.next() % 3 == 0 ? rng.byte() : 0)
                rig.poke(0x0966, rng.next() % 8 == 0 ? 1 : 0)
                rig.run(0x35BD, .init(carry: rng.bool()), "\(name) $35BD #\(i)") { $0.densityAndAutoLevel() }
            }
            rig.run(0x3638, .init(), "\(name) $3638") { $0.serviceAircraft() }
            rig.expectClean("density/auto-level/service, \(name)")
        }
    }

    /// Every bank angle high byte (with random low bytes), both carries out of the density.
    @Test func autoLevelEveryBank() throws {
        var rng = TestRandom(seed: 0x35F0)
        let rig = FlightRig(try #require(Self.states.first?.1))
        for bank in 0...0xFFFF where bank % 7 == 0 {
            rig.poke(0x0ABD, 0); rig.poke(0x0966, 0); rig.poke(0x0838, 0)
            rig.poke16(0x09E0, UInt16(bank))
            rig.poke16(0x0830, rng.pick([0, 1, 100, 0x3333, 0x3334, 0x7FFF, 0xFFFF, rng.word()]))
            rig.run(0x35BD, .init(), "bank $\(String(bank, radix: 16))") { $0.densityAndAutoLevel() }
        }
        rig.expectClean("auto-level")
    }

    // MARK: $3660 slew

    @Test func slewMatchesOriginal() throws {
        var rng = TestRandom(seed: 0x3660)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            rig.run(0x3660, .init(), "\(name) $3660") { $0.slewIntegrate() }
            rig.run(0x372B, .init(), "\(name) $372B") { $0.slewAux() }
            for i in 0..<100 {
                for a in [0x0A80, 0x0AA4, 0x0AAC, 0x0AC5, 0x0AC3, 0x0ABF, 0x0AC1, 0x6D, 0x6F, 0x71] {
                    Self.perturb(rig, &rng, a, chance: 3)
                }
                for a in [0x5A, 0x5E, 0x62, 0x6C] where rng.next() % 4 == 0 {
                    for k in 0..<(a == 0x6C ? 2 : 4) { rig.poke(a + k, rng.edgeOrRandomByte()) }
                }
                rig.run(0x3660, .init(), "\(name) $3660 #\(i)") { $0.slewIntegrate() }
            }
            rig.expectClean("slew, \(name)")
        }
    }

    /// The exponential step of every rate byte, on both axes.
    @Test func slewRateStepEveryRate() throws {
        var rng = TestRandom(seed: 0x3746)
        let rig = FlightRig(try #require(Self.states.first?.1))
        for rate in 0...255 {
            rig.poke(0x0A80, 0)
            rig.poke(0x0AA4, UInt8(rate)); rig.poke(0x0AAC, UInt8(255 - rate))
            rig.poke(0x0AC5, rng.byte()); rig.poke(0x0AC3, rng.byte())
            rig.run(0x3660, .init(), "rate $\(String(rate, radix: 16))") { $0.slewIntegrate() }
        }
        rig.expectClean("slew rate step")
    }

    // MARK: $E716 / $E766 wind

    @Test func windMatchesOriginal() throws {
        var rng = TestRandom(seed: 0xE766)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            rig.run(0xE766, .init(), "\(name) $E766") { $0.windLayer() }
            rig.run(0xE716, .init(), "\(name) $E716") { $0.windDrift() }
            for i in 0..<120 {
                for a in 0x098E..<0x09A4 { Self.perturb(rig, &rng, a, chance: 6) }
                for a in [0x5F, 0x60, 0x0847, 0x0849, 0x09D7, 0x0A0E, 0x0A12] { Self.perturb(rig, &rng, a, chance: 3) }
                for a in [0x09D3, 0x09D5] { Self.perturb16(rig, &rng, a, chance: 3) }
                for base in [0x5A, 0x62] where rng.next() % 4 == 0 {
                    for k in 0..<4 { rig.poke(base + k, rng.edgeOrRandomByte()) }
                }
                if rng.bool() {
                    rig.run(0xE766, .init(carry: rng.bool()), "\(name) $E766 #\(i)") { $0.windLayer() }
                } else {
                    rig.run(0xE716, .init(), "\(name) $E716 #\(i)") { $0.windDrift() }
                }
            }
            rig.expectClean("wind, \(name)")
        }
    }

    // MARK: $EA84 / $EAE2 failures and trim

    @Test func realityFailuresMatchOriginal() throws {
        var rng = TestRandom(seed: 0xEA84)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            for i in 0..<60 {
                rig.poke(0x0967, rng.next() % 6 == 0 ? 0 : rng.pick([1, 1, rng.byte()]))
                rig.poke(0x08CD, rng.pick([0, 0, 1, 0x80, 0xFF, rng.byte()]))
                rig.poke(0x09A4, rng.pick([0, 0, 50, 99, 100, rng.byte()]))
                for a in [0x63, 0x5B, 0x22, 0x5F] { Self.perturb(rig, &rng, a) }
                for a in [0x09CE, 0x09D0, 0x08C0] { Self.perturb16(rig, &rng, a) }
                let carry = rng.bool()
                rig.run(0xEA84, .init(carry: carry), "\(name) $EA84 #\(i)") { $0.realityFailures(carry: carry) }
            }
            rig.expectClean("reality failures, \(name)")
        }
    }

    /// Every failure handler, chosen through the table by ($22 + altitude+1 + C) & $0E.
    @Test func everyFailureHandler() throws {
        let rig = FlightRig(try #require(Self.states.first?.1))
        for index in 0..<8 {
            for masks in [UInt8(0xFF), 0x00, 0x5A] {
                rig.poke(0x0967, 1); rig.poke(0x08CD, 0); rig.poke(0x09A4, 0)
                rig.poke(0x63, 10); rig.poke(0x5B, 20)
                rig.poke(0x22, UInt8(index * 2)); rig.poke(0x5F, 0)
                rig.poke(0x0942, masks); rig.poke(0x09BF, ~masks)
                rig.run(0xEA84, .init(carry: false), "handler \(index) masks $\(String(masks, radix: 16))") {
                    $0.realityFailures(carry: false)
                }
            }
        }
        rig.expectClean("failure handlers")
    }

    @Test func trimCreepMatchesOriginal() throws {
        var rng = TestRandom(seed: 0xEAE2)
        let rig = FlightRig(try #require(Self.states.first?.1))
        let values: [UInt8] = [0, 1, 2, 3, 4, 0x7E, 0x7F, 0x80, 0x81, 0xB0, 0xFE, 0xFF, 0x50, 0x4C, 0xB4]
        for elevator in values {
            for trim in values {
                rig.poke(0x0967, 1); rig.poke(0x0AAC, elevator); rig.poke(0x0AAE, trim)
                rig.run(0xEAE2, .init(), "elevator $\(String(elevator, radix: 16)) trim $\(String(trim, radix: 16))") {
                    $0.trimCreep()
                }
            }
        }
        for i in 0..<400 {
            rig.poke(0x0967, rng.next() % 5 == 0 ? 0 : 1)
            rig.poke(0x0AAC, rng.byte()); rig.poke(0x0AAE, rng.byte())
            rig.run(0xEAE2, .init(), "trim #\(i)") { $0.trimCreep() }
        }
        rig.expectClean("trim creep")
    }

    // MARK: $EE6B engine

    static func perturbEngine(_ rig: FlightRig, _ rng: inout TestRandom, starter: Bool) {
        rig.poke(0x0969, rng.next() % 5 == 0 ? rng.pick([1, rng.byte()]) : 0)
        rig.poke(0x0967, rng.next() % 2 == 0 ? rng.pick([1, rng.byte()]) : 0)
        rig.poke(0x0A9A, rng.pick([0, 3, 6, 7, 7, rng.byte()]))
        for a in [0xEE14, 0xEE15, 0x09C7, 0x09C8] { rig.poke(a, rng.pick([0, 1, 1, 1, rng.byte()])) }
        rig.poke(0x09C6, rng.pick([0, 0, 1, rng.byte()]))
        for a in [0x09C2, 0x09C5] { rig.poke(a, rng.pick([0, 1, 0x20, 0x80, 0xFF, rng.byte()])) }
        for a in [0x09C0, 0x09C1, 0x09C3, 0x09C4] { perturb(rig, &rng, a, chance: 3) }
        rig.poke(0x09C9, rng.pick([0, 1, 1, rng.byte()]))
        rig.poke(0x0A4D, rng.pick([0, 0x10, 0x24, 0x25, 0x7C, 0x80, 0xFF, rng.byte()]))
        rig.poke(0x0AB6, starter ? 4 : rng.pick([0, 1, 2, 3, rng.byte()]))
        rig.poke(0x0AC9, rng.pick([0, 8, 0x40, 0x78, 0x7F, 0x80, rng.byte()]))
        rig.poke(0x0AA9, rng.pick([0, 0, 1, rng.byte()]))
        rig.poke(0xEE16, rng.pick([0, 0, 1, 5, rng.byte()]))
        rig.poke(0x09BF, rng.pick([0, 0, 1, 2, 3, 4, 8, 0x0F, rng.byte()]))
        perturb16(rig, &rng, 0x09DA, chance: 3)
        for a in [0x09CA, 0x09CC] where rng.bool() {
            rig.poke(a, rng.byte())
            rig.poke(a + 1, rng.pick([0, 9, 10, 0x12, 0x11, 0xFF, 0xFE, rng.byte()]))
        }
        rig.poke(0x22, rng.byte())
        rig.poke(0x0E58, rng.byte())
    }

    @Test func engineModelMatchesOriginal() throws {
        var rng = TestRandom(seed: 0xEE6B)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            rig.run(0xEE6B, .init(), "\(name) $EE6B") { $0.engineModel() }
            for i in 0..<150 {
                Self.perturbEngine(rig, &rng, starter: false)
                if rng.next() % 4 == 0 { rig.poke(0x0AB6, 3) }
                rig.run(0xEE6B, .init(carry: rng.bool()), "\(name) $EE6B #\(i)") { $0.engineModel() }
            }
            rig.expectClean("engine, \(name)")
        }
    }

    /// The starter: reality mode, engine stopped, slow, magneto switch on START. The busy-wait
    /// (586,756 cycles) and the label redraw (the ported `setMagnetoLabel`).
    @Test func engineStarter() throws {
        var rng = TestRandom(seed: 0xEEC0)
        let rig = FlightRig(try #require(Self.states.first?.1))
        for i in 0..<12 {
            Self.perturbEngine(rig, &rng, starter: true)
            rig.poke(0x0969, 0); rig.poke(0x0967, 1); rig.poke(0x0A9A, 0)
            rig.poke(0xEE14, 1); rig.poke(0x09C7, 1); rig.poke(0x09C6, 0); rig.poke(0x09C2, 0x20)
            rig.poke(0x09C9, 0); rig.poke(0x0A4D, UInt8(rng.next() % 0x25))
            rig.run(0xEE6B, .init(), "starter #\(i)") { $0.engineModel() }
            #expect(rig.machine[0x09C9] == 1 && rig.machine[0x0AB6] == 3)
        }
        rig.expectClean("starter")
    }

    // MARK: $F8AF-$F9C1 ground, regime timer, crash, splash, altitude

    @Test func groundElevationAndTimersMatchOriginal() throws {
        var rng = TestRandom(seed: 0xF8AF)
        for (name, ram) in Self.states {
            let rig = FlightRig(ram)
            rig.run(0xF8AF, .init(), "\(name) $F8AF") { $0.trackGroundElevation() }
            rig.run(0xF916, .init(), "\(name) $F916") { $0.maneuverRegimeTimer() }
            rig.run(0xF996, .init(), "\(name) $F996") { $0.splashDetect() }
            for i in 0..<150 {
                switch rng.next() % 4 {
                case 0:
                    let field = rng.pick([0, 1, 2, 180, 181, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, rng.word()])
                    rig.poke16(0x0A87, field)
                    rig.poke16(0x0843, rng.pick([field, field &+ 1, field &- 1, field &+ 2, field &- 2, field ^ 0x100, rng.word()]))
                    rig.poke(0x0A4D, rng.pick([0, 9, 0x0A, 0x0B, rng.byte()]))
                    rig.poke(0x5F, rng.pick([0, 2, 3, 4, 5, 0xFF, rng.byte()]))
                    rig.poke(0x60, rng.pick([0, 0, 1, 0x7F, 0x80, 0xFF]))
                    rig.run(0xF8AF, .init(), "\(name) $F8AF #\(i)") { $0.trackGroundElevation() }
                case 1:
                    rig.poke(0x0E75, rng.pick([0, 1, 2, 6, 0x80, 0x81, 0xFF, rng.byte()]))
                    rig.poke(0x09DF, rng.byte()); rig.poke(0x09E1, rng.byte()); rig.poke(0x0A4D, rng.byte())
                    rig.run(0xF916, .init(), "\(name) $F916 #\(i)") { $0.maneuverRegimeTimer() }
                case 2:
                    rig.poke(0x0A12, rng.pick([0, 0xFF, 0xFF, 1]))
                    rig.poke(0x50DE, rng.pick([0x55, 0x55, 0xAA, 0, rng.byte()]))
                    rig.poke(0x0ACA, rng.pick([0, 0, 0, 2, 0xFF]))
                    rig.poke(0x0836, rng.pick([0, 0, 0, 1]))
                    rig.poke(0x0A83, rng.pick([0, 0, 0, 3]))
                    rig.poke(0x0E7F, rng.pick([0, 1, 2, 3, 0xFF, rng.byte()]))
                    rig.run(0xF996, .init(), "\(name) $F996 #\(i)") { $0.splashDetect() }
                default:
                    rig.poke16(0x096F, rng.edgeOrRandomWord())
                    rig.poke16(0x0A87, rng.pick([0, 1, 180, 0x7FFF, 0x8000, 0xFFFF, rng.word()]))
                    rig.poke(0xC4, rng.byte()); rig.poke(0xC8, rng.byte())
                    rig.run(0xF9C1, .init(), "\(name) $F9C1 #\(i)") { $0.setAltitudeFromEditor() }
                }
            }
            rig.expectClean("ground/timers, \(name)")
        }
    }

    /// Every combination of the regime timer's inputs on a grid.
    @Test func maneuverRegimeTimerGrid() throws {
        let rig = FlightRig(try #require(Self.states.first?.1))
        let bytes: [UInt8] = [0, 1, 0x0E, 0x0F, 0x10, 0x15, 0x16, 0x17, 0x48, 0x49, 0x4A, 0x7F, 0x80, 0xB6, 0xB7,
                              0xB8, 0xD4, 0xD5, 0xEA, 0xEB, 0xF0, 0xF1, 0xF2, 0xFF]
        for timer: UInt8 in [0, 1, 6, 0x80, 0x81] {
            for g in bytes { for b in bytes { for v in [UInt8(0), 0x48, 0x49, 0xB6, 0xB7, 0xFF] {
                rig.poke(0x0E75, timer); rig.poke(0x09DF, g); rig.poke(0x09E1, b); rig.poke(0x0A4D, v)
                rig.run(0xF916, .init(), "timer \(timer) γ \(g) φ \(b) V \(v)") { $0.maneuverRegimeTimer() }
            } } }
        }
        rig.expectClean("regime timer grid")
    }

    /// The crash and splash message, with its sound, text and the delay (the ported `busyDelay`).
    @Test func crashAndSplashMessage() throws {
        let base = try #require(Self.states.first { $0.0 == "fm-bank2" }?.1 ?? Self.states.first?.1)
        for code: UInt8 in [4, 8, 1] {
            let rig = FlightRig(base)
            rig.poke(0x0834, code)
            rig.run(0xF95D, .init(a: code), "code \(code)") { $0.crashMessage(code: code) }
            #expect(rig.machine[0x08BB] == 1 && rig.machine[0x0834] == 0)
            rig.expectClean("crash message \(code)")
        }
    }

    // MARK: Multi-step runs

    /// The 5 Hz aerodynamics, the per-pass integrator, wind, ground tracking and the phase tasks
    /// (engine, density, regime timer, splash, wind layer, failures) run alternately for hundreds
    /// of steps on twin images, the jiffy clock advancing between passes. Both sides keep their
    /// state; any divergence shows up at the call that causes it.
    @Test func multiStepFlight() throws {
        var rng = TestRandom(seed: 0x204B)
        let starts = Self.states.filter {
            ["fm-roll2", "fm-liftoff", "fm-climb", "fm-stall1", "fm-stall6", "fm-bank1", "fm-bank4", "fm-real3",
             "fm-unslew1", "regular"].contains($0.0)
        }
        #expect(starts.count >= 8)
        for (name, ram) in starts {
            let rig = FlightRig(ram)
            rig.poke(0x0966, 0)
            var pass = rig.peek(0x22)
            for step in 0..<300 {
                let label = "\(name) step \(step)"
                // Two to six frames per pass, as the original loop runs.
                rig.poke(0x34, rig.peek(0x34) &+ UInt8(2 + rng.next() % 5))
                if step % 2 == 0 {
                    rig.run(0x2F45, .init(), "\(label) $2F45") { $0.aeroUpdate() }
                }
                if step % 9 == 4 {
                    // A control input, as the key handlers do it.
                    rig.poke(0x0AAC, rig.peek(0x0AAC) &+ rng.pick([0xFC, 4, 0]))
                    rig.poke(0x0AA4, rng.pick([0, 0, 4, 0xFC, 0x10, 0xF0]))
                    rig.run(0x2E92, .init(), "\(label) $2E92") { $0.controlCoefficients() }
                }
                rig.run(0x32EE, .init(), "\(label) $32EE") { $0.integrateFlight() }
                rig.run(0xE716, .init(), "\(label) $E716") { $0.windDrift() }
                rig.run(0xF8AF, .init(), "\(label) $F8AF") { $0.trackGroundElevation() }
                switch pass & 3 {
                case 0:
                    rig.run(0xE766, .init(), "\(label) $E766") { $0.windLayer() }
                case 2:
                    rig.run(0x35BD, .init(), "\(label) $35BD") { $0.densityAndAutoLevel() }
                case 3:
                    let carry = rng.bool()
                    rig.run(0xEA84, .init(carry: carry), "\(label) $EA84") { $0.realityFailures(carry: carry) }
                default:
                    break
                }
                if pass & 1 == 0 {
                    rig.run(0xF996, .init(), "\(label) $F996") { $0.splashDetect() }
                    rig.run(0xF916, .init(), "\(label) $F916") { $0.maneuverRegimeTimer() }
                    rig.run(0xEE6B, .init(), "\(label) $EE6B") { $0.engineModel() }
                }
                if step % 20 == 19 { rig.run(0xEAE2, .init(), "\(label) $EAE2") { $0.trimCreep() } }
                pass &+= 1
                rig.poke(0x22, pass)
                if rig.peek(0x0834) != 0 { rig.poke(0x0834, 0) }   // keep flying after a crash
            }
            rig.expectClean("multi-step, \(name)")
        }
    }

    /// The main loop's physics step across slew transitions: slew mode toggles every 25 passes,
    /// so `slewIntegrate` sees the `$0A80` reset request that `integrateFlight` leaves, with the
    /// slew rates and controls moving in between (the 5 Hz aerodynamics returns at once in slew).
    @Test func multiStepSlewTransitions() throws {
        var rng = TestRandom(seed: 0x3660)
        let starts = Self.states.filter { ["fm-climb", "fm-bank3", "fm-slew4", "fm-real2", "regular"].contains($0.0) }
        #expect(starts.count >= 4)
        for (name, ram) in starts {
            let rig = FlightRig(ram)
            var slewing = rig.peek(0x0966) != 0
            for step in 0..<200 {
                let label = "\(name) step \(step)"
                if step % 25 == 0 { slewing.toggle(); rig.poke(0x0966, slewing ? 1 : 0) }
                rig.poke(0x34, rig.peek(0x34) &+ UInt8(2 + rng.next() % 5))
                if step % 7 == 3 {
                    for a in [0x0AA4, 0x0AAC, 0x0AC5, 0x0AC3, 0x0ABF, 0x0AC1] {
                        rig.poke(a, rng.pick([0, 0, 4, 0xFC, 0x10, 0xF0, 0x28]))
                    }
                }
                if step % 2 == 0 { rig.run(0x2F45, .init(), "\(label) $2F45") { $0.aeroUpdate() } }
                if slewing {
                    rig.run(0x3660, .init(), "\(label) $3660") { $0.slewIntegrate() }
                } else {
                    rig.run(0x32EE, .init(), "\(label) $32EE") { $0.integrateFlight() }
                    rig.run(0xE716, .init(), "\(label) $E716") { $0.windDrift() }
                }
                rig.run(0xF8AF, .init(), "\(label) $F8AF") { $0.trackGroundElevation() }
                if rig.peek(0x0834) != 0 { rig.poke(0x0834, 0) }
            }
            rig.expectClean("slew transitions, \(name)")
        }
    }
}

fileprivate extension TestRandom {
    mutating func word() -> UInt16 { UInt16(truncatingIfNeeded: next() >> 24) }
    mutating func bool() -> Bool { next() & 0x100 != 0 }
    mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }
    mutating func edgeOrRandomByte() -> UInt8 {
        next() & 3 == 0 ? pick([0, 1, 2, 0x7F, 0x80, 0x81, 0xFE, 0xFF]) : byte()
    }
    mutating func edgeOrRandomWord() -> UInt16 {
        next() & 3 == 0 ? pick([0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0x3FFF, 0x4000, 0x7FFE, 0x7FFF, 0x8000, 0x8001,
                                0xC000, 0xFF00, 0xFFFE, 0xFFFF]) : word()
    }
}
