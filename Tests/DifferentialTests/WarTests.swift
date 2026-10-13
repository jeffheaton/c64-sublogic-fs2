import FS2Core
import FS2LabKit
import Foundation
import M6502
import Testing

fileprivate extension TestRandom {
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func coin() -> Bool { next() & 0x100 != 0 }
    mutating func pick(_ values: [UInt8]) -> UInt8 { values[below(values.count)] }
}

/// Lab states of the Europe 1917 war game, all taken at the entry of `warMain` ($AA03).
enum WarFixtures {
    /// Europe 1917 = 1 in the editor (page 0, line 6); W; a takeoff north; enemy 4 (record $54)
    /// placed 600 m ahead and about 110 m above (attacking), the guns held until it is shot
    /// down; enemy 4 again 200 m ahead and level, until it has hit the aircraft 7 times; a bomb;
    /// the bombsight (down view), the right view and the radar.
    static let session = C3Fixtures.prefix + """

        key:E:6 pc:2250:1500 wait:10 key:RETURN:6 wait:24 key:RETURN:6 wait:24 key:RETURN:6 wait:24
        key:RETURN:6 wait:24 key:RETURN:6 wait:24 key:1:6 wait:24
        key:E:6 pc:AA03:3000 snap:d3-war-first
        pc:204B:3000 pc:204B:3000 wait:600 pc:AA03:60 snap:d3-war-ground
        key:W:6 until:0ACC:01:120 pc:AA03:120 snap:d3-war-declare
        wait:150 pc:AA03:60 snap:d3-war-declared
        key:;:150 wait:650 key:B:6 wait:20 key:B:6 wait:20 key:B:6 wait:20
        wait:1400 pc:AA03:60 snap:d3-war-airborne
        poke:A9AF:00 poke:A9B0:0A poke:A9B1:DD poke:A9B2:00 poke:A9B3:01 poke:A9B4:00
        poke:A9B5:A8 poke:A9B6:03 poke:A9B7:04 poke:A9C6:02
        down:SPACE
        until:0AB2:03:60 pc:AA03:60 snap:d3-war-fire
        wait:120 pc:AA03:60 snap:d3-war-sight
        until:08B2:01:600 pc:AA03:60 snap:d3-war-kill
        up:SPACE
        pc:AA03:60
        poke:A9AF:00 poke:A9B0:0A poke:A9B1:DD poke:A9B2:AA poke:A9B3:00 poke:A9B4:00
        poke:A9B5:30 poke:A9B6:03 poke:A9B7:04 poke:A9C6:02 poke:A9C7:00
        pc:AA03:60 snap:d3-war-closing
        until:08B7:01:1000 pc:AA03:60 snap:d3-war-hit
        until:08B7:07:2000 pc:AA03:60 snap:d3-war-hits
        key:X:6 wait:10 pc:AA03:60 snap:d3-war-bomb
        key:5:6 wait:20 key:G:6 wait:120 pc:AA03:60 snap:d3-war-bombsight
        key:5:6 wait:20 key:H:6 wait:60 pc:AA03:60 snap:d3-war-side
        key:5:6 wait:20 key:T:6 wait:20 key:4:6 wait:60 pc:AA03:60 snap:d3-war-radar
        """

    static let names = ["d3-war-first", "d3-war-ground", "d3-war-declare", "d3-war-declared", "d3-war-airborne",
                        "d3-war-fire", "d3-war-sight", "d3-war-kill", "d3-war-closing", "d3-war-hit", "d3-war-hits",
                        "d3-war-bomb", "d3-war-bombsight", "d3-war-side", "d3-war-radar", "d3-war-end"]

    static let states: [String: [UInt8]] = (try? C3Fixtures.load(names, session: session)) ?? [:]

    static func state(_ name: String) throws -> [UInt8] {
        try #require(states[name], "missing lab state \(name)")
    }

    /// The states the long runs start from (war declared; on the ground and in the air).
    static let running = ["d3-war-declared", "d3-war-airborne", "d3-war-fire", "d3-war-sight", "d3-war-kill",
                          "d3-war-closing", "d3-war-hit", "d3-war-hits", "d3-war-bomb", "d3-war-bombsight",
                          "d3-war-side", "d3-war-radar"]

    /// A rig on `name` (the scenery interpreter polls the ported 10 Hz tick body $2348 while the
    /// enemy dots are drawn).
    static func rig(_ name: String) throws -> DiffRig {
        let rig = DiffRig(try state(name))
        WarCoverage.current?.attach(to: rig)
        return rig
    }

    static func u32(_ rig: DiffRig, _ a: Int) -> UInt32 {
        let r = rig.harness.bus.ram
        return UInt32(r[a]) | UInt32(r[a + 1]) << 8 | UInt32(r[a + 2]) << 16 | UInt32(r[a + 3]) << 24
    }

    static func poke32(_ rig: DiffRig, _ a: Int, _ v: UInt32) {
        for k in 0..<4 { rig.poke(a + k, UInt8(truncatingIfNeeded: v >> (8 * k))) }
    }

    /// Moves the twin images on as the rest of a main-loop pass would: the aircraft flies about
    /// 30 m north (with some drift, climb and turn), the pass counter `$22` advances, and the
    /// 10 Hz tick is now and then due during the dot lists (`$0E6B` ≥ 6). `events` adds the
    /// player's actions: a gun burst (as `fireGuns`), a bomb countdown with a target (as the
    /// scenery lists store it), W, a view or radar change, and a rearm on the ground through
    /// the original $35BD/$3614 and the ported `densityAndAutoLevel` (compared like the war
    /// pass).
    static func advance(_ rig: DiffRig, _ rng: inout TestRandom, events: Bool, pass: Int) {
        let ram = rig.harness.bus.ram
        poke32(rig, 0x62, u32(rig, 0x62) &+ UInt32(bitPattern: Int32(0x1E00 + rng.below(0x400) - 0x200)))
        poke32(rig, 0x5A, u32(rig, 0x5A) &+ UInt32(bitPattern: Int32(rng.below(0x800) - 0x400)))
        if u32(rig, 0x5E) > 0x1000 || rng.coin() {
            poke32(rig, 0x5E, u32(rig, 0x5E) &+ UInt32(bitPattern: Int32(rng.below(0x600) - 0x200)))
        }
        if rng.below(4) == 0 { rig.poke(0x71, ram[0x71] &+ rng.pick([1, 2, 0xFF, 0xFE, 4])) }
        rig.poke(0x22, ram[0x22] &+ 1)
        rig.poke(0x0E6B, rng.below(8) == 0 ? UInt8(6 + rng.below(8)) : UInt8(rng.below(6)))
        guard events else { return }
        if rng.below(3) == 0, ram[0x0AA5] | ram[0x0AA6] != 0 { rig.poke(0x0AB2, 3) }
        if rng.below(20) == 0 {
            rig.poke(0x0AA7, rng.byte())
            rig.poke(0x0AA8, rng.pick([0, 0, 1, 2]))
            rig.poke(0x0872, rng.pick([0, 1, 5, 10, 25, 0xFF]))
        }
        if rng.below(30) == 0 { rig.poke(0x0ACC, ram[0x0ACC] | 1) }
        if rng.below(12) == 0 {
            rig.poke(0x0ACA, rng.pick([0, 0, 0, 2, 4, 6, 0x0E, 0xFF]))
            rig.poke(0x0836, rng.pick([0, 0, 0, 1, 2]))
        }
        if rng.below(25) == 0 {
            rig.poke(0x0838, 2)
            rig.poke(0x0A4D, 0)
            rig.run(0x35BD, .init(), "rearm before pass \(pass)") { $0.densityAndAutoLevel(); return .init() }
        }
    }

    /// Places enemy `k` relative to the aircraft (meters: east, altitude, north), attacking,
    /// with a zone around the aircraft so it stays in the attack.
    static func place(_ rig: DiffRig, enemy k: Int, east: Int, up: Int, north: Int, rng: inout TestRandom) {
        let r = War.enemyRecords + k * War.recordSize
        func meters(_ axis: Int) -> Int { Int(u32(rig, axis) >> 8) }
        func put(_ field: Int, _ v: Int) {
            for b in 0..<3 { rig.poke(r + field + b, UInt8(truncatingIfNeeded: v >> (8 * b))) }
        }
        put(War.Field.east, meters(0x5A) + east)
        put(War.Field.altitude, max(1, meters(0x5E) + up))
        put(War.Field.north, meters(0x62) + north)
        let eastHigh = Int(u32(rig, 0x5A) >> 16), northHigh = Int(u32(rig, 0x62) >> 16)
        rig.poke16(r + War.Field.zoneEast, UInt16(truncatingIfNeeded: eastHigh + 0x20))
        rig.poke16(r + War.Field.zoneNorth, UInt16(truncatingIfNeeded: northHigh - 0x20))
        rig.poke(r + War.Field.fireRange, rng.pick([0xA0, 0x78, 0xF0, 0xFF]))
        rig.poke(r + War.Field.state, 2)
        rig.poke(r + War.Field.cooldown, rng.pick([0, 0, 0, 0x10, 0x90]))
    }
}

/// Instruction starts of the original war code ($AA03-$B1E9) executed on a rig's harness.
final class WarCoverage {
    /// While set, every rig made by `WarFixtures.rig` records into it (the suite is serialized).
    nonisolated(unsafe) static var current: WarCoverage?

    private(set) var executed = Set<UInt16>()

    func attach(to rig: DiffRig) {
        let cpu = rig.harness.cpu
        for a in War.mainEntry...0xB1E9 { cpu.traps[Int(a)] = true }
        cpu.trapHandler = { [self] pc in executed.insert(pc); return false }
    }

    /// Every instruction start of $AA03-$B1E9 under linear disassembly (the region is all
    /// code) that was not executed.
    func missed(in ram: [UInt8]) -> [UInt16] {
        let d = Disassembler()
        var pc = War.mainEntry, out: [UInt16] = []
        while pc <= 0xB1E9 {
            if !executed.contains(pc) { out.append(pc) }
            pc &+= UInt16(d.decode(at: pc) { ram[Int($0)] }.length)
        }
        return out
    }
}

/// Differential tests of the Europe 1917 war overlay ($AA03-$B1E9): `warMain` from lab states
/// of every phase of a war (first pass, declaration with its busy wait, takeoff, an enemy shot
/// down, an enemy firing, damage, a bomb, the bombsight, other views, the radar), long runs of
/// passes on twin images with the world moving on, dogfights with enemies placed around the
/// aircraft, the rearm through the ported $3614, and every routine on randomized inputs. Every
/// call compares the whole memory image (stack page excluded) and the exact cycle count with
/// the original on the lab's flat bus; the scenery interpreter's 10 Hz poll runs the ported tick
/// body $2348.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct WarTests {
    // MARK: Fixtures

    @Test func sessionReachesEveryPhase() throws {
        #expect(WarFixtures.states.count == WarFixtures.names.count)
        let s = { (n: String) throws -> [UInt8] in try WarFixtures.state(n) }
        #expect(try s("d3-war-first")[War.started] == 0 && s("d3-war-first")[0x0969] == 1)
        #expect(try s("d3-war-first")[0xA7E0] == 0xEA && s("d3-war-first")[0xA7E1] == 0xB1)
        #expect(try s("d3-war-ground")[War.started] == 1 && s("d3-war-ground")[War.declared] == 0)
        #expect(try s("d3-war-declare")[War.declared] == 1)
        #expect(try s("d3-war-declared")[War.declared] == 3)
        #expect(try s("d3-war-airborne")[0x5F] != 0)
        #expect(try s("d3-war-fire")[War.gunBurst] == 3)
        #expect(try s("d3-war-sight")[War.enemyRecords + 0x54 + War.Field.inSight] == 3)
        #expect(try s("d3-war-kill")[War.killCount] == 1 && s("d3-war-kill")[War.score] == 1)
        #expect(try s("d3-war-hit")[War.hitsTaken] == 1)
        #expect(try s("d3-war-hits")[War.hitsTaken] == 7 && s("d3-war-hits")[War.engineFailureBits] & 4 != 0)
        #expect(try s("d3-war-bomb")[0x08E8] == 0x34)
        #expect(try s("d3-war-bombsight")[0x0ACA] == 0xFF)
        #expect(try s("d3-war-side")[0x0ACA] == 4)
        #expect(try s("d3-war-radar")[0x0836] == 1)
    }

    // MARK: warMain ($AA03)

    /// One pass from every state, through the slot $A7EE as the main loop calls it, then a
    /// second pass straight into $AA03.
    @Test func everyStateOnce() throws {
        for name in WarFixtures.names {
            let rig = try WarFixtures.rig(name)
            var problems = C3Fixtures.compareLong(rig, War.slot) { $0.slotWar() }
            problems += C3Fixtures.compareLong(rig, War.mainEntry) { $0.warMain() }
            #expect(problems.isEmpty, "\(name): \(problems.joined(separator: ", "))")
        }
    }

    /// The first pass: the radios off, the black status panel, the counters printed and every
    /// enemy dormant; with the instrument masks and the counters randomized.
    @Test func firstPass() throws {
        var rng = TestRandom(seed: 0xB13E)
        for i in 0..<12 {
            let rig = try WarFixtures.rig("d3-war-first")
            rig.poke(0xFE, rng.byte()); rig.poke(0x09A7, rng.byte())
            rig.poke(War.score, rng.byte()); rig.poke(War.score + 1, rng.pick([0, 1, 3, 4]))
            rig.poke(War.ammo, rng.byte()); rig.poke(War.ammo + 1, rng.pick([0, 0, 1, 0xFF]))
            rig.poke(War.hitsTaken, rng.byte())
            let problems = C3Fixtures.compareLong(rig, War.mainEntry) { $0.warMain() }
            #expect(problems.isEmpty, "first pass \(i): \(problems.joined(separator: ", "))")
            let m = rig.machine
            #expect(m[War.started] == 1 && m[0xFE] & 0x80 == 0 && m[0x09A7] & 0x80 == 0 && m[War.serviceCount] == 0)
            #expect((0..<6).allSatisfy { m[War.enemyRecords + $0 * War.recordSize + War.Field.state] == 1 })
            #expect(m[0x7E4D] == 0x10 && m[0x7E4D + 7 * 40 + 10] == 0x10)
        }
    }

    /// W: the pass after `$0ACC` = 1 shows 'WAR !!!!' and spends 328,707 cycles in its busy
    /// wait; from the ground and in the air, and a bomb on a target declaring war.
    @Test func declareWar() throws {
        for name in ["d3-war-declare", "d3-war-ground", "d3-war-airborne"] {
            let rig = try WarFixtures.rig(name)
            rig.poke(War.declared, 1)
            let start = rig.machine.clock.cycles
            var problems = C3Fixtures.compareLong(rig, War.mainEntry) { $0.warMain() }
            #expect(rig.machine.clock.cycles - start > 328_707)
            #expect(rig.machine[War.declared] == 3)
            // A bomb landing on a target: war is declared (if it was not) and the score grows.
            rig.poke(War.declared, 0)
            rig.poke(War.bombCountdown, 0x10); rig.poke(War.bombCountdown + 1, 0)
            rig.poke(War.bombTargetScore, 7)
            problems += C3Fixtures.compareLong(rig, War.mainEntry) { $0.warMain() }
            #expect(rig.machine[War.declared] == 3 && rig.machine[War.targetsBombed] == 1)
            #expect(problems.isEmpty, "\(name): \(problems.joined(separator: ", "))")
        }
    }

    /// Long runs: 30 passes from each running state on twin images, the aircraft moving on
    /// between passes, with gun bursts, bombs, W, view and radar changes and rearms.
    @Test func longRuns() throws {
        var rng = TestRandom(seed: 0xAA03)
        var fired = 0, hits = 0, kills = 0
        for name in WarFixtures.running {
            let rig = try WarFixtures.rig(name)
            var problems: [String] = []
            for pass in 0..<30 {
                WarFixtures.advance(rig, &rng, events: true, pass: pass)
                let before = rig.harness.bus.ram
                problems += C3Fixtures.compareLong(rig, War.mainEntry) { $0.warMain() }.map { "pass \(pass): \($0)" }
                let after = rig.harness.bus.ram
                if after[War.ammo] != before[War.ammo] { fired += 1 }
                if after[War.hitsTaken] != before[War.hitsTaken] { hits += 1 }
                if after[War.killCount] != before[War.killCount] { kills += 1 }
                if problems.count > 6 { break }
            }
            #expect(problems.isEmpty, "\(name): \(problems.joined(separator: "; "))")
            rig.expectClean("rearms from \(name)")
        }
        #expect(fired > 50, "rounds spent on \(fired) passes")
        _ = (hits, kills)
    }

    /// Dogfights: from the airborne and later states, enemies placed around the aircraft
    /// (ahead, above, below, behind, to the sides; attacking, some with a cooldown) while the
    /// guns fire on most passes; 40 passes each. Enemies come into the sight and are shot down,
    /// fire and hit, climb and sink after firing, and fly the step pursuit.
    @Test func dogfights() throws {
        var rng = TestRandom(seed: 0xD06F)
        var kills = 0, hits = 0, inSight = 0, damaged = 0
        for (i, name) in ["d3-war-airborne", "d3-war-sight", "d3-war-closing", "d3-war-hits", "d3-war-side",
                          "d3-war-airborne", "d3-war-kill"].enumerated() {
            let rig = try WarFixtures.rig(name)
            for k in 0..<War.enemyCount where rng.below(3) != 0 || k == 3 {
                let ahead = rng.pick([0, 1, 2, 3, 4, 5, 6])
                WarFixtures.place(rig, enemy: k, east: rng.below(160) - 80, up: rng.below(240) - 60,
                                  north: Int(ahead) * 120 + rng.below(100) - (i == 4 ? 300 : 0), rng: &rng)
            }
            if i == 6 { rig.poke(War.killCount, 4) }       // the lower damage thresholds
            var problems: [String] = []
            for pass in 0..<40 {
                WarFixtures.advance(rig, &rng, events: false, pass: pass)
                if rng.below(5) != 0 { rig.poke(War.gunBurst, 3) }
                let before = rig.harness.bus.ram
                problems += C3Fixtures.compareLong(rig, War.mainEntry) { $0.warMain() }.map { "pass \(pass): \($0)" }
                let after = rig.harness.bus.ram
                kills += Int(after[War.killCount] &- before[War.killCount])
                hits += Int(after[War.hitsTaken] &- before[War.hitsTaken])
                if after[War.engineFailureBits] != before[War.engineFailureBits] { damaged += 1 }
                inSight += (0..<6).filter { after[War.enemyRecords + $0 * War.recordSize + War.Field.inSight] == 3 }.count
                if problems.count > 6 { break }
            }
            #expect(problems.isEmpty, "\(name) #\(i): \(problems.joined(separator: "; "))")
        }
        #expect(kills > 0 && hits > 3 && inSight > 3 && damaged > 0,
                "kills \(kills), hits \(hits), in-sight passes \(inSight), damage changes \(damaged)")
    }

    /// The rearm at the base: $3614 (through $35BD) with `$0838` = 2 on the ground after a
    /// dogfight refills the ammunition and the bombs and clears the hits and the damage; the
    /// next war pass reprints AMMO and HITS and sends every enemy home (dormant).
    @Test func rearmAtBase() throws {
        for name in ["d3-war-hits", "d3-war-kill", "d3-war-bomb"] {
            let rig = try WarFixtures.rig(name)
            rig.poke(War.ammo, 7)
            rig.poke(War.gunBurst, 0)                       // no burst in this pass
            rig.poke(0x0838, 2)
            rig.poke(0x0A4D, 0)
            rig.run(0x35BD, .init(), "\(name) $35BD") { $0.densityAndAutoLevel(); return .init() }
            let problems = C3Fixtures.compareLong(rig, War.mainEntry) { $0.warMain() }
            #expect(problems.isEmpty, "\(name): \(problems.joined(separator: ", "))")
            rig.expectClean("\(name) rearm")
            let m = rig.machine
            #expect(m[War.ammo] == 100 && m[0x08E8] == 0x35 && m[War.hitsTaken] == 0 && m[War.engineFailureBits] == 0,
                    "\(name)")
            #expect(m[War.serviceCount] == 0 && m[0xA87B] == 0x31 && m[0xA87C] == 0x30 && m[0xA88B] == 0x30, "\(name)")
            #expect((0..<6).allSatisfy { m[War.enemyRecords + $0 * War.recordSize + War.Field.state] == 1 }, "\(name)")
        }
    }

    // MARK: The routines on randomized inputs

    /// `enemyUpdate` ($AA84) for each record offset on random records and aircraft positions:
    /// every state (0, 1, 2 and others), triggers and zones on both sides, cooldowns (climb,
    /// sink on odd and even passes, the altitude floor), steps of both signs and carries,
    /// the scope and the fire range, views and radar.
    @Test func enemyUpdateRandom() throws {
        var rng = TestRandom(seed: 0xAA84)
        for name in ["d3-war-sight", "d3-war-closing", "d3-war-hit", "d3-war-bombsight"] {
            let rig = try WarFixtures.rig(name)
            for i in 0..<120 {
                let k = rng.below(War.enemyCount)
                let x = UInt8(k * War.recordSize)
                let r = War.enemyRecords + k * War.recordSize
                if rng.below(3) == 0 {
                    WarFixtures.place(rig, enemy: k, east: rng.below(600) - 300, up: rng.below(400) - 200,
                                      north: rng.below(1200) - 200, rng: &rng)
                }
                if rng.below(4) == 0 { rig.poke(r + War.Field.state, rng.pick([0, 1, 1, 2, 2, 3, 0xFF])) }
                if rng.below(4) == 0 {
                    for f in [War.Field.triggerEast, War.Field.triggerNorth, War.Field.zoneEast, War.Field.zoneNorth] {
                        rig.poke16(r + f, UInt16(truncatingIfNeeded: rng.next()))
                    }
                }
                if rng.below(3) == 0 { rig.poke(r + War.Field.cooldown, rng.pick([0, 1, 2, 0x40, 0x80, 0x81, 0xFF])) }
                if rng.below(4) == 0 {
                    // East and north low words at the 64 K edges: the steps carry or borrow
                    // into the top byte.
                    for f in [War.Field.east, War.Field.north] where rng.coin() {
                        let up = rng.coin()
                        rig.poke(r + f, up ? rng.pick([0xF8, 0xFE, 0xFF]) : rng.pick([0, 1, 4]))
                        rig.poke(r + f + 1, up ? 0xFF : 0)
                    }
                }
                if rng.below(5) == 0 {
                    // Altitude near the floor, to reach the hold at 1.
                    rig.poke(r + War.Field.altitude, rng.pick([0, 1, 2]))
                    rig.poke(r + War.Field.altitude + 1, rng.pick([0, 0, 1]))
                    rig.poke(r + War.Field.altitude + 2, rng.pick([0, 0, 1, 0xFF]))
                }
                if rng.below(4) == 0 {
                    for f in [War.Field.stepEast, War.Field.stepAltitude, War.Field.stepNorth] {
                        rig.poke(r + f, rng.pick([1, 2, 5, 9, 0x80, 0xFF, rng.byte()]))
                    }
                }
                if rng.below(4) == 0 { rig.poke(r + War.Field.onScope, rng.pick([0, 0x80, 0x9C])) }
                if rng.below(6) == 0 { rig.poke(r + War.Field.fireRange, rng.byte()) }
                if rng.below(6) == 0 {
                    rig.poke(0x0ACA, rng.pick([0, 0, 2, 0xFF])); rig.poke(0x0836, rng.pick([0, 0, 1]))
                }
                rig.poke(0x22, rng.byte())
                rig.poke(0x71, rng.byte())
                rig.poke(0x0E6B, UInt8(rng.below(6)))
                rig.poke(War.hitsTaken, rng.pick([0, 6, 19, 34, 39, 59, 0xFE, rng.byte()]))
                rig.poke(War.killCount, rng.pick([0, 3, 4, 9]))
                WarFixtures.advance(rig, &rng, events: false, pass: i)
                rig.run(0xAA84, .init(x: x), "\(name) enemy \(k) #\(i)") { $0.enemyUpdate(x); return .init() }
            }
            rig.expectClean("enemyUpdate on \(name)")
        }
    }

    /// The motion of `enemyUpdate` at its edges, for every record: each axis stepping up and
    /// down across 64 K boundaries (the carry and borrow into the top byte), and the cooldown's
    /// climb (carries through all three bytes) and sink (borrows, the hold at 1) on odd and even
    /// passes, with attacking enemies chasing the aircraft placed around them.
    @Test func enemyMotionEdges() throws {
        var rng = TestRandom(seed: 0xAB12)
        let rig = try WarFixtures.rig("d3-war-closing")
        func put24(_ a: Int, _ v: Int) {
            for b in 0..<3 { rig.poke(a + b, UInt8(truncatingIfNeeded: v >> (8 * b))) }
        }
        let fields = [War.Field.east, War.Field.altitude, War.Field.north]
        let aircraft = [0x5A, 0x5E, 0x62]
        var cases = 0
        for k in 0..<War.enemyCount {
            let x = UInt8(k * War.recordSize), r = War.enemyRecords + k * War.recordSize
            for moving in 0..<3 {
                for up in [true, false] {
                    for edge in [0xFFF8, 0xFFFF, 0x10000, 0x10004, 0x1FFFE, 0x7F, 0xFF0000] {
                        for cooldown: UInt8 in [0, 0, 1, 0x80, 0x81, 0xFF] {
                            var at = [Int](repeating: 0, count: 3)
                            for axis in 0..<3 {
                                let e = axis == moving ? edge : Int(rng.next() & 0xFFFFFF)
                                let d = axis == moving ? (up ? 0x300 : -0x300) : rng.below(0x200) - 0x100
                                put24(r + fields[axis], e)
                                at[axis] = (e + d) & 0xFFFFFF
                                rig.poke(aircraft[axis], rng.byte())
                                put24(aircraft[axis] + 1, at[axis])
                            }
                            if cooldown != 0 {
                                let low: [(UInt8, UInt8, UInt8)] = [(0xFF, 0xFF, 0), (0xFF, 0xFF, 0xFF), (1, 0, 0),
                                                                    (0, 0, 0), (0, 0, 1), (0, 1, 0), (5, 0, 0)]
                                let v = low[rng.below(low.count)]
                                rig.poke(r + War.Field.altitude, v.0)
                                rig.poke(r + War.Field.altitude + 1, v.1)
                                rig.poke(r + War.Field.altitude + 2, v.2)
                            }
                            rig.poke16(r + War.Field.zoneEast, UInt16(truncatingIfNeeded: (at[0] >> 8) + 0x20))
                            rig.poke16(r + War.Field.zoneNorth, UInt16(truncatingIfNeeded: (at[2] >> 8) - 0x20))
                            for f in [War.Field.stepEast, War.Field.stepAltitude, War.Field.stepNorth] {
                                rig.poke(r + f, rng.pick([1, 2, 9, 0x10, 0xFF]))
                            }
                            rig.poke(r + War.Field.state, 2)
                            rig.poke(r + War.Field.cooldown, cooldown)
                            rig.poke(r + War.Field.onScope, rng.pick([0, 0, 0x90]))
                            rig.poke(0x22, rng.byte())
                            rig.poke(0x0E6B, 0)
                            cases += 1
                            rig.run(0xAA84, .init(x: x), "enemy \(k) axis \(moving) up \(up) edge \(edge) cooldown \(cooldown)") {
                                $0.enemyUpdate(x); return .init()
                            }
                        }
                    }
                }
            }
        }
        rig.expectClean("enemy motion edges (\(cases) cases)")
    }

    /// `enemyDelta` ($B0A3) with any record offset and pointer (page crossings of both
    /// indexed reads), returning the carry; `enemyDistance` ($B04C) on random deltas (all sign
    /// patterns of the high bytes), returning the carry of its last `stationDistance`.
    @Test func deltaAndDistance() throws {
        var rng = TestRandom(seed: 0xB0A3)
        let rig = try WarFixtures.rig("d3-war-sight")
        for i in 0..<400 {
            // Any offset and pointer is read (page crossings, wrap at $FFFF); random bytes go
            // only into the records and the three real targets.
            let x = rng.pick([0, 0x1C, 0x38, 0x54, 0x70, 0x8C, 0xA0, 0xA4, 0xFF, rng.byte()])
            let pointer: UInt16 = [0x005A, 0xA81C, 0xA828, 0x00F8, 0x00FC, 0xFFFA,
                                   UInt16(truncatingIfNeeded: rng.next())][rng.below(7)]
            rig.poke16(0xA5, pointer)
            if [0x005A, 0xA81C, 0xA828].contains(pointer) {
                for k in 1..<12 where rng.coin() { rig.poke(Int(pointer) + k, rng.byte()) }
            }
            if x <= 0x8C {
                for k in 0..<9 where rng.coin() { rig.poke(War.enemyRecords + Int(x) + k, rng.byte()) }
            }
            rig.run(0xB0A3, .init(x: x, carry: rng.coin()), "delta #\(i)") { .init(carry: $0.enemyDelta(x)) }
            for k in 0..<9 where rng.below(3) == 0 {
                rig.poke(War.delta + k, rng.pick([0, 0xFF, 0x80, 0x7F, rng.byte()]))
            }
            rig.poke(War.enemyOffset, x)
            rig.run(0xB04C, .init(), "distance #\(i)") { .init(x: x, carry: $0.enemyDistance()) }
        }
        rig.expectClean("enemyDelta / enemyDistance")
    }

    /// `plotEnemyScope` ($AD21): random deltas around the scope's edges, all headings.
    @Test func scopeDot() throws {
        var rng = TestRandom(seed: 0xAD21)
        let rig = try WarFixtures.rig("d3-war-hit")
        for i in 0..<600 {
            let x = UInt8(rng.below(War.enemyCount) * War.recordSize)
            rig.poke(War.enemyOffset, x)
            for axis in [0, 6] {
                let v = Int32(rng.below(rng.coin() ? 0x200 : 0x8000) * (rng.coin() ? 1 : -1))
                rig.poke(War.delta + axis, UInt8(truncatingIfNeeded: v))
                rig.poke(War.delta + axis + 1, UInt8(truncatingIfNeeded: v >> 8))
                rig.poke(War.delta + axis + 2, rng.below(8) == 0 ? rng.byte() : UInt8(truncatingIfNeeded: v >> 16))
            }
            for k in 3..<6 { rig.poke(War.delta + k, rng.pick([0, 0xFF, 0x1D, 0x1E, 0xE1, 0xE2, rng.byte()])) }
            rig.poke(0x71, rng.byte())
            rig.run(0xAD21, .init(), "scope #\(i)") { $0.plotEnemyScope(); return .init(x: x) }
        }
        rig.expectClean("plotEnemyScope")
    }

    /// `drawEnemyShape` ($ACC5): every shape at positions across and beyond its window.
    @Test func enemyShapes() throws {
        var rng = TestRandom(seed: 0xACC5)
        for name in ["d3-war-sight", "d3-war-side"] {
            let rig = try WarFixtures.rig(name)
            for i in 0..<300 {
                rig.poke(War.shapeIndex, UInt8(rng.below(5)))
                rig.poke(War.enemyScreenX, rng.pick([0, 3, 4, 0x50, 0x9A, 0x9B, 0xFF, rng.byte()]))
                rig.poke(War.enemyScreenY, rng.pick([0, 3, 4, 0x37, 0x6A, 0x6B, 0xFF, rng.byte()]))
                rig.run(0xACC5, .init(), "\(name) shape #\(i)") { $0.drawEnemyShape(); return .init() }
            }
            rig.expectClean("drawEnemyShape on \(name)")
        }
    }

    /// `gunsAndTracers` ($AEED): bursts, the slot wrap at $54, random ages (some below $0B),
    /// in-sight flags (shot down, scored), every view and the radar, the tracer timer running
    /// out; random tracer positions and targets.
    @Test func gunsAndTracers() throws {
        var rng = TestRandom(seed: 0xAEED)
        for name in ["d3-war-fire", "d3-war-sight", "d3-war-radar"] {
            let rig = try WarFixtures.rig(name)
            for i in 0..<300 {
                if rng.below(3) == 0 { rig.poke(War.gunBurst, rng.pick([0, 1, 3])) }
                if rng.below(8) == 0 { rig.poke(War.tracerSlot, rng.pick([0, 0x48, 0x4E, 0x54, rng.byte() % 0x50])) }
                if rng.below(8) == 0 { rig.poke(War.tracerTimer, rng.pick([0, 1, 2, 0x19])) }
                if rng.below(6) == 0 {
                    for t in 0..<14 {
                        let a = War.tracers + 6 * t
                        rig.poke(a + 1, rng.pick([0, 0, 1, 0x0A, 0x0B, 0x0C, 0x0F]))
                        rig.poke(a + 2, UInt8(rng.below(0xA0))); rig.poke(a + 3, UInt8(rng.below(0xA0)))
                        rig.poke(a + 4, UInt8(rng.below(0x70))); rig.poke(a + 5, UInt8(rng.below(0x70)))
                    }
                }
                if rng.below(5) == 0 {
                    let k = rng.below(War.enemyCount)
                    rig.poke(War.enemyRecords + k * War.recordSize + War.Field.inSight, rng.pick([0, 3, 2]))
                    rig.poke(War.enemyRecords + k * War.recordSize + War.Field.state, 2)
                }
                if rng.below(10) == 0 {
                    rig.poke(War.ammo, rng.pick([0, 1, 2, 100])); rig.poke(War.ammo + 1, rng.pick([0, 0, 1]))
                }
                if rng.below(10) == 0 {
                    rig.poke(War.score, rng.pick([0, 0xE6, 0xE7, 0xE8, rng.byte()])); rig.poke(War.score + 1, rng.pick([0, 3]))
                }
                if rng.below(10) == 0 {
                    rig.poke(0x0ACA, rng.pick([0, 0, 4, 0xFF])); rig.poke(0x0836, rng.pick([0, 0, 1]))
                }
                rig.run(0xAEED, .init(), "\(name) guns #\(i)") { $0.gunsAndTracers(); return .init() }
            }
            rig.expectClean("gunsAndTracers on \(name)")
        }
    }

    /// The counters: `bombImpact` ($AFB9) over countdowns at the borrow and impact edges with
    /// and without a target; `addWarScore` ($AFEE) at the 1000 wrap; `spendRound` ($B01D) at 0,
    /// 1 and $100; `printHitsTaken` ($AE63, X = `$A800`); `warServiceCheck` ($AE44);
    /// `drawWarScope` ($B0FC).
    @Test func counters() throws {
        var rng = TestRandom(seed: 0xAFB9)
        let rig = try WarFixtures.rig("d3-war-bomb")
        for i in 0..<300 {
            rig.poke(War.bombCountdown, rng.pick([0, 0x31, 0x32, 0x33, 0xFF, rng.byte()]))
            rig.poke(War.bombCountdown + 1, rng.pick([0, 0, 1, 0xFF, rng.byte()]))
            rig.poke(War.bombTargetScore, rng.pick([0, 0, 1, 0x64, 0xFF]))
            rig.poke(War.declared, rng.pick([0, 1, 3]))
            rig.poke(War.score, rng.pick([0, 0xE7, 0xE8, 0xFF, rng.byte()]))
            rig.poke(War.score + 1, rng.pick([0, 2, 3, 4, rng.byte()]))
            rig.run(0xAFB9, .init(), "bomb #\(i)") { $0.bombImpact(); return .init() }
            let points = rng.pick([0, 1, 0x19, 0xFF, rng.byte()])
            rig.run(0xAFEE, .init(a: points), "score #\(i)") { $0.addWarScore(points); return .init() }
            rig.poke(War.ammo, rng.pick([0, 1, 2, 100, 0xFF, rng.byte()]))
            rig.poke(War.ammo + 1, rng.pick([0, 0, 1, 0xFF]))
            rig.run(0xB01D, .init(), "round #\(i)") { $0.spendRound(); return .init() }
            rig.poke(War.hitsTaken, rng.byte())
            let x = UInt8(rng.below(War.enemyCount) * War.recordSize)
            rig.poke(War.enemyOffset, x)
            rig.run(0xAE63, .init(), "hits #\(i)") { $0.printHitsTaken(); return .init(x: x) }
            rig.poke(War.serviceCount, rng.pick([0, 0, 1, 2]))
            rig.run(0xAE44, .init(), "service #\(i)") { $0.warServiceCheck(); return .init() }
            if i % 20 == 0 { rig.run(0xB0FC, .init(), "scope #\(i)") { $0.drawWarScope(); return .init() } }
        }
        rig.expectClean("counters")
    }

    /// `warDamage` ($B19E) for every hit count with 0-9 kills and both sides of `$22` = $3F,
    /// returning the carry.
    @Test func damage() throws {
        let rig = try WarFixtures.rig("d3-war-hits")
        for kills: UInt8 in [0, 3, 4, 9] {
            for counter: UInt8 in [0, 0x3E, 0x3F, 0xFF] {
                for hits in 0...255 {
                    rig.poke(War.hitsTaken, UInt8(hits))
                    rig.poke(War.killCount, kills)
                    rig.poke(0x22, counter)
                    rig.poke(War.engineFailureBits, 0)
                    rig.run(0xB19E, .init(), "kills \(kills) $22 \(counter) hits \(hits)") { .init(carry: $0.warDamage()) }
                }
            }
        }
        rig.expectClean("warDamage")
    }

    /// `warStatusLines` ($AE77): every combination of the in-range, fire and shown flags and
    /// the rotation timer, with the declaration (and its busy wait) now and then.
    @Test func statusLines() throws {
        var rng = TestRandom(seed: 0xAE77)
        let rig = try WarFixtures.rig("d3-war-hit")
        for i in 0..<200 {
            rig.poke(War.inRange, rng.pick([0, 1, 2, 3, 0xFF]))
            rig.poke(War.enemyFired, rng.pick([0, 1, 2, 3]))
            rig.poke(War.statusShown, rng.pick([0, 1, 2, 3]))
            rig.poke(War.rotationTimer, rng.pick([1, 1, 2, 4, 0]))
            rig.poke(War.rotationIndex, rng.byte())
            rig.poke(War.declared, i % 25 == 0 ? 1 : rng.pick([0, 3, 2]))
            let problems = C3Fixtures.compareLong(rig, 0xAE77) { $0.warStatusLines() }
            #expect(problems.isEmpty, "status #\(i): \(problems.joined(separator: ", "))")
        }
    }

    // MARK: Coverage

    /// The tests above together execute every instruction of the original war code ($AA03-$B1E9),
    /// each compared with the port. (Two branches are never taken in any state: the equality
    /// branch at $ADEC, which follows a compare with the other value, and the tracer walk's
    /// fall-through into $AF49 with X wrapped to 0, which needs a list without its $FF end.)
    @Test func everyInstructionIsCompared() throws {
        let coverage = WarCoverage()
        WarCoverage.current = coverage
        defer { WarCoverage.current = nil }
        try everyStateOnce()
        try firstPass()
        try declareWar()
        try longRuns()
        try dogfights()
        try rearmAtBase()
        try enemyUpdateRandom()
        try enemyMotionEdges()
        try deltaAndDistance()
        try scopeDot()
        try enemyShapes()
        try gunsAndTracers()
        try counters()
        try damage()
        try statusLines()
        let missed = coverage.missed(in: try WarFixtures.state("d3-war-first"))
        #expect(missed.isEmpty, "not executed: \(missed.map { String(format: "$%04X", $0) }.joined(separator: " "))")
    }
}
