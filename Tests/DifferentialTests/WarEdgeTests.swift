import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Exact placements for the war tests: the aircraft and an enemy put at given meters (bytes 1-3
/// of the aircraft's 32-bit axes, the enemy's 24-bit fields), so the deltas, the range and the
/// projected position take the values a compare is about.
private enum WarPlace {
    static let axes = [0x5A, 0x5E, 0x62]
    static let fields = [War.Field.east, War.Field.altitude, War.Field.north]

    /// The aircraft's east, altitude and north meters.
    static func aircraft(_ rig: DiffRig) -> [Int] {
        axes.map { Int(rig.machine.u24($0 + 1)) }
    }

    static func setAircraft(_ rig: DiffRig, _ meters: [Int]) {
        for (axis, v) in zip(axes, meters) {
            for b in 0..<3 { rig.poke(axis + 1 + b, UInt8(truncatingIfNeeded: v >> (8 * b))) }
        }
    }

    /// Enemy `k` at `meters` (east, altitude, north; wrapped to 24 bits), attacking with the
    /// aircraft inside its zone, no cooldown and no steps (it stays where it is put).
    static func enemy(_ rig: DiffRig, _ k: Int, at meters: [Int], state: UInt8 = 2) {
        let r = War.enemyRecords + k * War.recordSize
        for (field, v) in zip(fields, meters) {
            for b in 0..<3 { rig.poke(r + field + b, UInt8(truncatingIfNeeded: v >> (8 * b))) }
        }
        let east = Int(rig.machine.u16(0x5C)), north = Int(rig.machine.u16(0x64))
        rig.poke16(r + War.Field.zoneEast, UInt16(truncatingIfNeeded: east + 0x20))
        rig.poke16(r + War.Field.zoneNorth, UInt16(truncatingIfNeeded: north - 0x20))
        for f in [War.Field.stepEast, War.Field.stepAltitude, War.Field.stepNorth, War.Field.cooldown] {
            rig.poke(r + f, 0)
        }
        rig.poke(r + War.Field.state, state)
    }
}

/// Boundary cases of the war overlay that random inputs rarely reach, and a pursuit from the
/// enemy bases. The compares of `enemyUpdate` ($AA84) and `plotEnemyScope` ($AD21) are driven to
/// both sides of their exact edges (the placements give exact deltas, ranges and screen
/// positions), and every call is compared with the original (whole memory, cycles). Part of the
/// serialized `WarTests` suite.
extension WarTests {
    /// The trigger (dormant) and zone (attacking) compares look only at the sign of the high
    /// bytes' difference, taken with the borrow of the low bytes' compare: the aircraft's high
    /// words `$5C/$5D` and `$64/$65` one below, at and above each record's values, with equal low
    /// bytes and the signed overflow cases ($7FFF/$8000 apart).
    @Test func triggerAndZoneEdges() throws {
        let rig = try WarFixtures.rig("d3-war-closing")
        let offsets = [-0x8001, -0x8000, -0x7FFF, -0x101, -0x100, -0xFF, -1, 0, 1, 0xFF, 0x100, 0x101, 0x7FFF, 0x8000]
        var outcomes = Set<UInt8>()
        for k in 0..<War.enemyCount {
            let x = UInt8(k * War.recordSize), r = War.enemyRecords + k * War.recordSize
            for state: UInt8 in [1, 2] {
                let east = state == 1 ? War.Field.triggerEast : War.Field.zoneEast
                let north = state == 1 ? War.Field.triggerNorth : War.Field.zoneNorth
                for de in offsets {
                    for dn in offsets {
                        rig.poke(r + War.Field.state, state)
                        rig.poke(r + War.Field.cooldown, 0)
                        rig.poke16(0x5C, UInt16(truncatingIfNeeded: Int(rig.machine.u16(r + east)) + de))
                        rig.poke16(0x64, UInt16(truncatingIfNeeded: Int(rig.machine.u16(r + north)) + dn))
                        rig.poke(0x0E6B, 0)
                        rig.run(0xAA84, .init(x: x), "enemy \(k) state \(state) east \(de) north \(dn)") {
                            $0.enemyUpdate(x); return .init()
                        }
                        outcomes.insert(state << 4 | rig.machine[r + War.Field.state])
                    }
                }
            }
        }
        rig.expectClean("trigger and zone edges")
        // Dormant ones stay dormant or attack; attacking ones go dormant or stay.
        #expect(outcomes == [0x11, 0x12, 0x21, 0x22], "\(outcomes.sorted())")
    }

    /// The range thresholds of the shape choice ($40, $80, $100, $200, $400) on both sides, with
    /// the enemy straight ahead at the aircraft's altitude (the range is then exactly the
    /// distance); and `rangeOverflow`: an enemy on the scope within its fire range fires only
    /// when the three delta top bytes XOR to 0 or $FF.
    @Test func rangeEdgesAndOverflow() throws {
        let rig = try WarFixtures.rig("d3-war-sight")
        let k = 4, x = UInt8(k * War.recordSize), r = War.enemyRecords + k * War.recordSize
        let at = WarPlace.aircraft(rig)
        var shapes: [Int: UInt8] = [:]
        for d in [0x3F, 0x40, 0x41, 0x7F, 0x80, 0x81, 0xFF, 0x100, 0x101, 0x1FF, 0x200, 0x201, 0x3FF, 0x400, 0x401] {
            WarPlace.enemy(rig, k, at: [at[0], at[1], at[2] + d])
            rig.poke(r + War.Field.onScope, 0)
            rig.poke(War.shapeIndex, 0xEE)
            rig.poke(0x0E6B, 0)
            rig.run(0xAA84, .init(x: x), "range \(d)") { $0.enemyUpdate(x); return .init() }
            #expect(rig.machine.u16(War.range) == UInt16(d), "range \(d)")
            shapes[d] = rig.machine[War.shapeIndex]
        }
        let expected: [Int: UInt8] = [0x3F: 4, 0x40: 3, 0x41: 3, 0x7F: 3, 0x80: 2, 0x81: 2, 0xFF: 2, 0x100: 1,
                                      0x101: 1, 0x1FF: 1, 0x200: 0, 0x201: 0, 0x3FF: 0, 0x400: 0, 0x401: 0]
        #expect(shapes == expected, "\(shapes.sorted { $0.key < $1.key })")

        // Fire: the delta top bytes (east, altitude, north) with small low words.
        var fired: [String] = []
        for tops: (Int, Int, Int) in [(0, 0, 0), (0, 1, 0), (0, 0xFF, 0), (0xFF, 0xFF, 0xFF), (0xFF, 0, 0), (1, 1, 0),
                                      (0, 0, 0xFF), (2, 0, 0), (0xFF, 0xFF, 0), (1, 0, 1), (0x80, 0x7F, 0)] {
            let delta = [tops.0 << 16 | 0x10, tops.1 << 16 | 0x05, tops.2 << 16 | 0x28]
            WarPlace.enemy(rig, k, at: (0..<3).map { at[$0] - delta[$0] })
            rig.poke(r + War.Field.onScope, 0x90)
            rig.poke(r + War.Field.fireRange, 0xFF)
            rig.poke(War.hitsTaken, 0)
            rig.poke(0x0E6B, 0)
            rig.run(0xAA84, .init(x: x), "fire tops \(tops)") { $0.enemyUpdate(x); return .init() }
            if rig.machine[War.hitsTaken] != 0 { fired.append("\(tops)") }
        }
        rig.expectClean("range edges and overflow")
        #expect(fired == ["(0, 0, 0)", "(0, 255, 0)", "(255, 255, 255)", "(255, 0, 0)", "(1, 1, 0)", "(0, 0, 255)",
                          "(255, 255, 0)", "(1, 0, 1)", "(128, 127, 0)"], "\(fired)")
    }

    /// The gunsight box (x $46-$5A, y $2A-$46): the enemy 300 m ahead swept up in 1 m steps
    /// (straight ahead), then across at the height of the box's middle row, so its projected
    /// position takes every value at and around the box edges.
    @Test func gunsightBoxEdges() throws {
        let rig = try WarFixtures.rig("d3-war-sight")
        let k = 4, x = UInt8(k * War.recordSize), r = War.enemyRecords + k * War.recordSize
        let at = WarPlace.aircraft(rig)
        var columns = Set<UInt8>(), rows = Set<UInt8>()
        var middle: Int?
        func sweep(_ axis: Int, _ offsets: ClosedRange<Int>, up: Int) {
            for offset in offsets {
                var p = [at[0], at[1] + up, at[2] + 300]
                p[axis] += offset
                WarPlace.enemy(rig, k, at: p)
                rig.poke(0x0E6B, 0)
                rig.run(0xAA84, .init(x: x), "box axis \(axis) offset \(offset)") { $0.enemyUpdate(x); return .init() }
                let m = rig.machine, sx = m[War.enemyScreenX], sy = m[War.enemyScreenY]
                guard m[0xCC] & 0x0F == 0 else { continue }
                if (0x2A...0x46).contains(sy) { columns.insert(sx) }
                if (0x46...0x5A).contains(sx) { rows.insert(sy) }
                if axis == 1, sy == 0x38 { middle = middle ?? offset }
                let inBox = (0x46...0x5A).contains(sx) && (0x2A...0x46).contains(sy)
                #expect((m[r + War.Field.inSight] == 3) == inBox, "offset \(offset) on axis \(axis): (\(sx), \(sy))")
            }
        }
        sweep(1, -150...250, up: 0)
        let up = try #require(middle, "no height puts the enemy on the box's middle row")
        sweep(0, -150...150, up: up)
        rig.expectClean("gunsight box edges")
        #expect(columns.isSuperset(of: [0x45, 0x46, 0x5A, 0x5B]), "columns \(columns.sorted())")
        #expect(rows.isSuperset(of: [0x29, 0x2A, 0x46, 0x47]), "rows \(rows.sorted())")
    }

    /// A dormant enemy in view cannot be hit while `$61` = 0 and `$60` − 1 is negative (a compare
    /// with 1 tested only for its sign): the aircraft's altitude at the edges of that test, the
    /// enemy 300 m ahead at the height that puts it in the gunsight.
    @Test func dormantAltitudeEdges() throws {
        let rig = try WarFixtures.rig("d3-war-sight")
        let k = 4, x = UInt8(k * War.recordSize), r = War.enemyRecords + k * War.recordSize
        // First the height above the aircraft that puts the enemy (attacking) in the box.
        var up: Int?
        for offset in 0...150 where up == nil {
            let at = WarPlace.aircraft(rig)
            WarPlace.enemy(rig, k, at: [at[0], at[1] + offset, at[2] + 300])
            rig.poke(0x0E6B, 0)
            rig.run(0xAA84, .init(x: x), "box search \(offset)") { $0.enemyUpdate(x); return .init() }
            if rig.machine[r + War.Field.inSight] == 3 { up = offset + 10 }
        }
        let above = try #require(up, "no height puts the enemy in the gunsight")
        var flags: [UInt8] = []
        for (high, mid) in [(0, 0), (0, 1), (0, 0x7F), (0, 0x80), (0, 0x81), (0, 0xFF), (1, 0), (2, 0), (0x80, 0x81)] {
            var at = WarPlace.aircraft(rig)
            at[1] = high << 16 | mid << 8 | 0x40
            WarPlace.setAircraft(rig, at)
            // Dormant: the aircraft east of the trigger, so it stays dormant.
            WarPlace.enemy(rig, k, at: [at[0], at[1] + above, at[2] + 300], state: 1)
            rig.poke16(r + War.Field.triggerEast, rig.machine.u16(0x5C) &- 0x1000)
            rig.poke(War.shapeIndex, 0xEE)
            rig.poke(0x0E6B, 0)
            rig.run(0xAA84, .init(x: x), "altitude \(high) \(mid)") { $0.enemyUpdate(x); return .init() }
            #expect(rig.machine[War.shapeIndex] == 1 && rig.machine[r + War.Field.state] == 1, "altitude \(high) \(mid)")
            flags.append(rig.machine[r + War.Field.inSight])
        }
        rig.expectClean("dormant altitude edges")
        #expect(flags == [0, 3, 3, 3, 0, 0, 3, 3, 3], "\(flags)")
    }

    /// `plotEnemyScope` at the scope's edges: v = across × $176 from −23 to 21 and w = along ×
    /// $1A3 from −26 to 25 in 1 m steps of the east and north deltas, heading north and south.
    @Test func scopeEdges() throws {
        let rig = try WarFixtures.rig("d3-war-hit")
        var columns = Set<UInt8>(), rows = Set<UInt8>()
        let eastSweep = Array(-2100 ... -1680) + Array(1680...2100)
        let northSweep = Array(-2100 ... -1800) + Array(1800...2100)
        for heading: UInt8 in [0, 0x80] {
            for (axis, sweep) in [(0, eastSweep), (6, northSweep)] {
                for v in sweep {
                    rig.poke(War.enemyOffset, 0x38)
                    for k in 0..<9 { rig.poke(War.delta + k, 0) }
                    for b in 0..<3 { rig.poke(War.delta + axis + b, UInt8(truncatingIfNeeded: v >> (8 * b))) }
                    rig.poke(0x71, heading)
                    rig.run(0xAD21, .init(), "heading \(heading) axis \(axis) delta \(v)") {
                        $0.plotEnemyScope(); return .init(x: 0x38)
                    }
                    let row = rig.machine[War.enemyRecords + 0x38 + War.Field.onScope]
                    guard row != 0 else { continue }
                    if axis == 0 { columns.insert(rig.machine[0xA5]) } else { rows.insert(row) }
                }
            }
        }
        rig.expectClean("scope edges")
        // x = $8A − v for v < 0 (v = −22 → $A0), $89 − v otherwise (v = 20 → $75); row = w + $92.
        #expect(columns.min() == 0x75 && columns.max() == 0xA0, "columns \(columns.sorted())")
        #expect(rows.min() == 0x79 && rows.max() == 0xAA, "rows \(rows.sorted())")
    }

    /// A pursuit from the bases: the aircraft is put inside every enemy's trigger corner, about
    /// 500 m east and 860 m north of base A (enemies 0-2; base B, of enemies 3-5, is 1.4 km west
    /// and 7 km south), and circles there. The six enemies attack from their bases and step
    /// toward it; those of base A come onto the scope and into view and fire, and the guns fire
    /// back whenever one is in the sight. 150 war passes, each compared with the original.
    @Test func pursuitFromTheBases() throws {
        let rig = try WarFixtures.rig("d3-war-airborne")
        var rng = TestRandom(seed: 0xBA5E)
        // About 500 m east and 860 m north of base A, inside every trigger and zone.
        var at = WarPlace.aircraft(rig)
        at = [0xDCEC00, max(at[1], 0x90), 0x040600]
        WarPlace.setAircraft(rig, at)
        rig.poke(War.declared, 3)
        rig.poke(War.ammo, 100); rig.poke(War.ammo + 1, 0)
        var problems: [String] = []
        var attacking = 0, onScope = 0, inView = 0, hits = 0, kills = 0
        let start = (0..<War.enemyCount).map { rig.machine.u24(War.enemyRecords + $0 * War.recordSize) }
        for pass in 0..<150 {
            // A slow circle around the start point, the pass counter, now and then a 10 Hz tick.
            let angle = Double(pass) / 12
            WarPlace.setAircraft(rig, [at[0] + Int(60 * cos(angle)), at[1] + pass % 7, at[2] + Int(60 * sin(angle))])
            rig.poke(0x71, UInt8(truncatingIfNeeded: Int(angle / (2 * .pi) * 256) + 0x40))
            rig.poke(0x22, rig.machine[0x22] &+ 1)
            rig.poke(0x0E6B, rng.next() % 8 == 0 ? 6 : UInt8(rng.next() % 6))
            if (0..<War.enemyCount).contains(where: { rig.machine[War.enemyRecords + $0 * War.recordSize + War.Field.inSight] == 3 }) {
                rig.poke(War.gunBurst, 3)
            }
            let before = rig.harness.bus.ram
            problems += C3Fixtures.compareLong(rig, War.mainEntry) { $0.warMain() }.map { "pass \(pass): \($0)" }
            let m = rig.machine
            for k in 0..<War.enemyCount {
                let r = War.enemyRecords + k * War.recordSize
                if m[r + War.Field.state] == 2 { attacking += 1 }
                if m[r + War.Field.onScope] != 0 { onScope += 1 }
                if m[r + War.Field.inSight] != 0 { inView += 1 }
            }
            hits += Int(m[War.hitsTaken] &- before[War.hitsTaken])
            kills += Int(m[War.killCount] &- before[War.killCount])
            if problems.count > 6 { break }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
        let moved = (0..<War.enemyCount).filter { rig.machine.u24(War.enemyRecords + $0 * War.recordSize) != start[$0] }
        #expect(moved.count == War.enemyCount && attacking > 100 && onScope > 50 && inView > 0 && hits > 0,
                "moved \(moved), attacking \(attacking), on scope \(onScope), in view \(inView), hits \(hits), kills \(kills)")
    }
}
