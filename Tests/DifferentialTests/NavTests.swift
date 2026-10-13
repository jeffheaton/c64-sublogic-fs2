import FS2Core
import FS2LabKit
import Foundation
import Testing

/// Differential tests of the nav instruments ($3B32-$3F89) and the ADF ($E7F3-$EA5B): the
/// station geometry (bearing, arctangent, distance), the CDI tasks, the XOR needles and
/// glideslope bar, TO/FROM, marker beacons, the ADF needle and readout and the NDB hook of
/// display-list op 05. The station data comes from lab snapshots tuned to Chicago VORs, the
/// Champaign ILS and a Chicago NDB (see `ReadoutFixtures`), with the aircraft moved around the
/// stations at random.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct NavTests {
    /// Puts the aircraft at a random offset from station `offset` (0 = A $0927, 8 = B $092F):
    /// mostly within ±16 km, sometimes far, sometimes on top of it.
    static func placeAircraft(_ rig: DiffRig, station offset: Int, _ rng: inout TestRandom) {
        let m = rig.machine
        let base = Radio.navStationA + offset
        let east = Int32(bitPattern: m.u32(base))
        let north = Int32(bitPattern: m.u32(base + 4))
        func jitter(_ r: inout TestRandom) -> Int32 {
            switch r.pick(8) {
            case 0: return 0
            case 1: return Int32(r.pick(0x200)) - 0x100
            case 2: return Int32(bitPattern: UInt32(truncatingIfNeeded: r.next()))
            default: return Int32(r.pick(0x80_0000)) - 0x40_0000
            }
        }
        let e = east &+ jitter(&rng), n = north &+ jitter(&rng)
        for k in 0..<4 {
            rig.poke(0x5A + k, UInt8(truncatingIfNeeded: e >> (8 * k)))
            rig.poke(0x62 + k, UInt8(truncatingIfNeeded: n >> (8 * k)))
        }
    }

    /// Random heading and area offsets (the offsets are 0 half of the time).
    static func randomHeading(_ rig: DiffRig, _ rng: inout TestRandom) {
        rig.poke16(0x70, rng.nextWord())
        rig.poke16(0x0846, rng.pick(2) == 0 ? 0 : rng.nextWord())
        rig.poke16(0x0848, rng.pick(2) == 0 ? 0 : rng.nextWord())
    }

    static let stationSnapshots = ["b3-radios", "b3-ils-approach", "b3-ils-outer", "b3-ils-middle", "b3-adf", "demo"]

    /// The Champaign ILS values the scenery stores, read from the outer-marker snapshot (taken
    /// right after the scenery ran in the glideslope box): the localizer course `$0852/$0853`
    /// and the glideslope reference `$0850/$0851`.
    static func champaign() throws -> (course: UInt16, reference: UInt16) {
        let ram = try ReadoutFixtures.ram("b3-ils-outer")
        let course = UInt16(ram[0x0852]) | UInt16(ram[0x0853]) << 8
        let reference = UInt16(ram[0x0850]) | UInt16(ram[0x0851]) << 8
        #expect(course != 0 && reference != 0, "the outer-marker snapshot holds the ILS values")
        return (course, reference)
    }

    // MARK: Geometry ($3C8F, $3E46, $3F38)

    /// $3E46 on random vectors and the edge cases: zero, equal components (the increment at $3E7B),
    /// $8000 components, one component zero, tiny and huge values.
    @Test func vectorAngle() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("regular"))
        var rng = TestRandom(seed: 0x3E46)
        let edges: [UInt16] = [0, 1, 2, 0x00FF, 0x0100, 0x7FFF, 0x8000, 0x8001, 0xFFFF, 0xFFFE, 0x1000, 0xF000]
        var cases: [(UInt16, UInt16)] = []
        for e in edges { for n in edges { cases.append((e, n)) } }
        for v in edges { cases.append((v, v)) }
        for _ in 0..<1500 {
            let e = rng.pick(3) == 0 ? UInt16(rng.pick(0x400)) &- 0x200 : rng.nextWord()
            let n = rng.pick(4) == 0 ? e &+ UInt16(rng.pick(5)) &- 2 : rng.nextWord()
            cases.append((e, n))
        }
        for (i, (e, n)) in cases.enumerated() {
            rig.poke16(0xBA, e)
            rig.poke16(0xBC, n)
            rig.run(0x3E46, .init(), "east \(Int16(bitPattern: e)) north \(Int16(bitPattern: n)) case \(i)") {
                let r = $0.vectorAngle(); return .init(a: r.lo, x: r.hi)
            }
        }
        ReadoutFixtures.expectClean(rig, "vectorAngle")
    }

    /// $3C8F for both station records around the stations of every snapshot, with the final
    /// carry (the ADF code depends on it).
    @Test func stationBearing() throws {
        for name in Self.stationSnapshots {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0x3C8F)
            for i in 0..<300 {
                let station: UInt8 = rng.pick(2) == 0 ? 0 : 8
                Self.placeAircraft(rig, station: Int(station), &rng)
                Self.randomHeading(rig, &rng)
                rig.run(0x3C8F, .init(x: station), "\(name) station \(station) case \(i)") {
                    .init(carry: $0.stationBearing(station: station))
                }
            }
            ReadoutFixtures.expectClean(rig, "stationBearing \(name)")
        }
    }

    /// $3F38 on random vectors and edges (equal components, $8000, zero).
    @Test func stationDistance() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("b3-radios"))
        var rng = TestRandom(seed: 0x3F38)
        let edges: [UInt16] = [0, 1, 0x7FFF, 0x8000, 0x8001, 0xFFFF, 0x0100, 0x00FF, 0x4000, 0xC000]
        var cases: [(UInt16, UInt16)] = []
        for a in edges { for b in edges { cases.append((a, b)) } }
        for _ in 0..<800 {
            let n = rng.pick(2) == 0 ? UInt16(rng.pick(0x1000)) &- 0x800 : rng.nextWord()
            let e = rng.pick(5) == 0 ? n : (rng.pick(2) == 0 ? UInt16(rng.pick(0x1000)) &- 0x800 : rng.nextWord())
            cases.append((n, e))
        }
        for (i, (n, e)) in cases.enumerated() {
            rig.poke16(0x09BA, n)
            rig.poke16(0x09BC, e)
            rig.run(0x3F38, .init(), "north \(Int16(bitPattern: n)) east \(Int16(bitPattern: e)) case \(i)") {
                $0.stationDistance(); return .init()
            }
        }
        ReadoutFixtures.expectClean(rig, "stationDistance")
    }

    // MARK: Course deviation ($3B61, $3D2B, $3D84)

    @Test func courseDeviation() throws {
        for name in Self.stationSnapshots {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0x3B61)
            for i in 0..<250 {
                let nav2 = rng.pick(2) == 0
                Self.placeAircraft(rig, station: nav2 ? 0 : 8, &rng)
                Self.randomHeading(rig, &rng)
                rig.poke(0x0922, rng.pick(6) == 0 ? rng.byte() : 3)
                let course = UInt8(rng.pick(5) == 0 ? rng.pick(256) : rng.pick(180))
                let mask: UInt8 = nav2 ? 2 : 1, station: UInt8 = nav2 ? 0 : 8
                rig.run(0x3B61, .init(a: mask, x: station, y: course), "\(name) NAV\(nav2 ? 2 : 1) course \(course) case \(i)") {
                    .init(a: $0.courseDeviation(mask: mask, station: station, course: course))
                }
                rig.run(0x3D84, .init(), "\(name) needle case \(i)") { .init(a: $0.deviationNeedle()) }
            }
            ReadoutFixtures.expectClean(rig, "courseDeviation \(name)")
        }
    }

    /// $3D2B and $3D84 over the boundaries (|d| around 256 and 300, the needle clamp at ±30).
    @Test func toFromAndNeedle() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("regular"))
        var values: [UInt16] = []
        for base in [0, 30, 256, 300, 540] {
            for d in -3...3 { values.append(UInt16(truncatingIfNeeded: base + d)); values.append(UInt16(truncatingIfNeeded: -base + d)) }
        }
        var rng = TestRandom(seed: 0x3D2B)
        for _ in 0..<600 { values.append(rng.pick(2) == 0 ? UInt16(rng.pick(1200)) &- 600 : rng.nextWord()) }
        for v in values {
            let lo = UInt8(v & 0xFF), hi = UInt8(v >> 8)
            rig.poke16(0xB8, v)
            rig.run(0x3D2B, .init(a: lo, x: hi), "classify \(Int16(bitPattern: v))") { .init(a: $0.classifyToFrom(lo, hi)) }
            rig.poke16(0xB8, v)
            rig.run(0x3D84, .init(), "needle \(Int16(bitPattern: v))") { .init(a: $0.deviationNeedle()) }
        }
        ReadoutFixtures.expectClean(rig, "classifyToFrom and deviationNeedle")
    }

    // MARK: CDI tasks ($3B32, $3B9B, $3DA2)

    /// The odd-pass tasks around the stations: localizer course and glideslope reference as the
    /// Champaign data sets them (or random, or with a zero low byte, which $3DA2 treats as
    /// absent), random altitudes, OBS and found bits.
    @Test func cdiTasks() throws {
        let ils = try Self.champaign()
        for name in Self.stationSnapshots {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0x3B32)
            for i in 0..<250 {
                Self.placeAircraft(rig, station: rng.pick(3) == 0 ? 0 : 8, &rng)
                Self.randomHeading(rig, &rng)
                rig.poke(0x0922, rng.pick(5) == 0 ? rng.byte() : 3)
                rig.poke(0x2196, UInt8(rng.pick(180)))
                rig.poke(0x2199, UInt8(rng.pick(180)))
                if rng.pick(4) == 0 { rig.poke(0x0933, rng.pick(2) == 0 ? 0 : rng.byte()) }
                rig.poke16(0x0852, rng.pick(2) == 0 ? ils.course : rng.nextWord())
                switch rng.pick(5) {
                case 0: rig.poke16(0x0850, 0)
                case 1: rig.poke16(0x0850, rng.nextWord())
                case 2: rig.poke16(0x0850, ils.reference & 0xFF00 | 0x0100)
                default: rig.poke16(0x0850, ils.reference)
                }
                rig.poke16(0x0A8A, UInt16(rng.pick(rng.pick(4) == 0 ? 0x10000 : 2000)))
                rig.poke(0x09AD, UInt8(rng.pick(10)))
                rig.run(0x3B32, .init(), "\(name) NAV1 case \(i)") { $0.updateNav1Cdi(); return .init() }
                rig.run(0x3B9B, .init(), "\(name) NAV2 case \(i)") { $0.updateNav2Cdi(); return .init() }
            }
            // $3DA2 on its own with random station vectors.
            for i in 0..<150 {
                rig.poke16(0x09BA, rng.pick(2) == 0 ? UInt16(rng.pick(0x400)) &- 0x200 : rng.nextWord())
                rig.poke16(0x09BC, rng.pick(2) == 0 ? UInt16(rng.pick(0x400)) &- 0x200 : rng.nextWord())
                rig.poke16(0x0850, rng.pick(3) == 0 ? 0 : (rng.pick(2) == 0 ? ils.reference : rng.nextWord()))
                rig.poke16(0x0A8A, UInt16(rng.pick(0x1000)))
                rig.poke(0x0922, rng.byte())
                rig.run(0x3DA2, .init(), "\(name) glideslope/DME case \(i)") { $0.updateGlideslopeAndDme(); return .init() }
            }
            ReadoutFixtures.expectClean(rig, "CDI tasks \(name)")
        }
    }

    // MARK: Drawing ($3BAF, $3C1A, $3C3F, $3C5D, $3C81, $3D68, $3D71, $3EFC)

    /// The OBI routines over random sequences of targets and TO/FROM states: the needles and the
    /// bar must step, erase and redraw exactly as the original's XORs.
    @Test func obiDrawing() throws {
        for name in Self.stationSnapshots + ["regular", "b3-night"] {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0x3BAF)
            let stack = ReadoutFixtures.StackWatch()
            for i in 0..<400 {
                if rng.pick(3) == 0 { rig.poke(0x09B0, UInt8(rng.pick(31))) }
                if rng.pick(3) == 0 { rig.poke(0x09B2, UInt8(rng.pick(31))) }
                if rng.pick(3) == 0 { rig.poke(0x09B4, UInt8(rng.pick(19))) }
                if rng.pick(6) == 0 { rig.poke(0x09B5, UInt8(rng.pick(3))) }
                if rng.pick(6) == 0 { rig.poke(0x09B6, UInt8(rng.pick(3))) }
                if rng.pick(25) == 0 { rig.poke(0xFD, rig.machine[0xFD] ^ 0x20) }
                if rng.pick(25) == 0 { rig.poke(0xFF, rig.machine[0xFF] ^ 0x08) }
                if rng.pick(30) == 0 { rig.poke(0x09AA, rig.machine[0x09AA] ^ 1) }
                for k in 0..<3 { rig.poke(0x084A + 2 * k, UInt8(rng.pick(5) == 0 ? rng.pick(4) : 0)) }
                rig.run(0x3C3F, .init(), "\(name) NAV2 step \(i)") { $0.stepNav2Needle(); return .init() }
                stack.check(rig, "\(name) NAV2 step \(i)")
                rig.run(0x3BAF, .init(), "\(name) OBI1 \(i)") { $0.drawObi1(); return .init() }
                stack.check(rig, "\(name) OBI1 \(i)")
                rig.run(0x3C1A, .init(), "\(name) OBI2 \(i)") { $0.drawObi2(); return .init() }
                stack.check(rig, "\(name) OBI2 \(i)")
            }
            ReadoutFixtures.expectClean(rig, "OBI drawing \(name)")
            stack.expectClean("OBI drawing \(name)")
        }
    }

    /// The single draws: every needle and bar position (including "none"), drawn twice (which
    /// must restore the panel), and every TO/FROM record, plus the indexes that carry or wrap.
    @Test func needlesBarAndToFrom() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("b3-radios"))
        let panel = { (m: Machine) in Array(UnsafeBufferPointer(start: m.mem + 0x5180, count: 0xDC0)) }
        let start = panel(rig.machine)
        for v in Array(0...40) + [0x7F, 0x80, 0xFF] {
            let p = UInt8(v)
            for step in 0..<2 {
                rig.run(0x3D71, .init(a: p), "NAV1 needle \(v) step \(step)") { $0.drawLocalizer(p); return .init() }
                rig.poke(0x09AA, 0)
                rig.run(0x3D68, .init(a: p), "NAV2 needle \(v) step \(step)") { $0.drawLocalizer2(p); return .init() }
                rig.poke(0x09AA, 1)
                rig.run(0x3D68, .init(a: p), "NAV2 needle \(v) step \(step), ADF on") { $0.drawLocalizer2(p); return .init() }
                rig.run(0x3C5D, .init(a: p), "glideslope \(v) step \(step)") { $0.drawGlideslope(p); return .init() }
            }
            rig.poke(0x09AA, 0)
        }
        #expect(panel(rig.machine) == start, "every needle and bar drawn twice must restore the panel")
        // Every position, also those past the row tables (in this snapshot the bar's rows 200+
        // resolve to bases in pages 0-7, $40-$47, $80-$87 and $C0-$C7: page 1 for positions 75
        // and 107, and page 0 for 74 and 106, whose first XOR hits the pointer $B8 itself and
        // sends the next two to $01BF/$01C7), with the stack page compared after every call.
        let stack = ReadoutFixtures.StackWatch()
        for v in 0...255 {
            let p = UInt8(v)
            for step in 0..<2 {
                rig.run(0x3C5D, .init(a: p), "glideslope \(v) (every position) step \(step)") { $0.drawGlideslope(p); return .init() }
                stack.check(rig, "glideslope \(v) step \(step)")
                rig.run(0x3D71, .init(a: p), "NAV1 needle \(v) (every position) step \(step)") { $0.drawLocalizer(p); return .init() }
                stack.check(rig, "NAV1 needle \(v) step \(step)")
                rig.run(0x3D68, .init(a: p), "NAV2 needle \(v) (every position) step \(step)") { $0.drawLocalizer2(p); return .init() }
                stack.check(rig, "NAV2 needle \(v) step \(step)")
            }
        }
        stack.expectClean("needles and bar at every position")
        // The six records, then A × 8 + $10 carrying into $23xx (30, 31) and wrapping (32).
        for index: UInt8 in [0, 1, 2, 3, 4, 5, 30, 31, 32] {
            rig.run(0x3C81, .init(a: index), "TO/FROM \(index)") { $0.drawToFrom(index); return .init() }
        }
        ReadoutFixtures.expectClean(rig, "needles, bar and TO/FROM")
    }

    @Test func markerBeacons() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("b3-ils-outer"))
        for war: UInt8 in [0, 1] {
            for outer: UInt8 in 0..<4 {
                for middle: UInt8 in 0..<4 {
                    for inner: UInt8 in 0..<4 {
                        rig.poke(0x0969, war)
                        rig.poke(0x084C, outer)
                        rig.poke(0x084E, middle)
                        rig.poke(0x084A, inner)
                        rig.poke(0x0E59, 0)
                        rig.run(0x3EFC, .init(), "war \(war) flags \(outer)/\(middle)/\(inner)") {
                            $0.markerBeacons(); return .init()
                        }
                    }
                }
            }
        }
        ReadoutFixtures.expectClean(rig, "markerBeacons")
    }

    // MARK: ADF ($E7FE, $E860, $E936, $E956)

    @Test func adfUpdate() throws {
        for name in ["b3-adf", "b3-radios"] {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0xE7FE)
            for i in 0..<300 {
                Self.placeAircraft(rig, station: 0, &rng)
                Self.randomHeading(rig, &rng)
                rig.poke(0x09AA, rng.pick(8) == 0 ? 0 : 1)
                rig.poke(0xE7F3, rng.pick(8) == 0 ? 0 : 1)
                if rng.pick(30) == 0 { rig.poke(0xE7F2, UInt8(rng.pick(4))) }
                if rng.pick(20) == 0 { rig.poke(0xE7F6, rig.machine[0xE7F6] | 0x80) }
                if rng.pick(20) == 0 { rig.poke(0xE7F6, UInt8(rng.pick(88))) }
                rig.run(0xE7FE, .init(), "\(name) ADF case \(i)") { $0.updateAdf(); return .init() }
            }
            for i in 0..<100 {
                rig.poke16(0xC0, rng.nextWord())
                rig.run(0xE860, .init(), "\(name) bearing readout \(i)") { $0.drawAdfBearing(); return .init() }
            }
            for i in 0..<2 {
                rig.run(0xE936, .init(), "\(name) face \(i)") { $0.drawAdfPanel(); return .init() }
            }
            ReadoutFixtures.expectClean(rig, "ADF \(name)")
        }
    }

    /// Op 05 records at display-list PCs that cross pages, matching and not, search on and off.
    /// The original ends with a jump to $8018 (the interpreter); a return opcode planted there
    /// ends the call, and the port side adds its 6 cycles.
    @Test func ndbHook() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("b3-adf"))
        rig.poke(0x8018, 0x60)
        var rng = TestRandom(seed: 0xE956)
        for i in 0..<300 {
            let pc = [0x03A0, 0x03F8, 0x03F9, 0x03FD, 0x03FE, 0x03FF][rng.pick(6)]
            rig.poke16(0x8B, UInt16(pc))
            let match = rng.pick(3) != 0
            let freq: (UInt8, UInt8) = match ? (rig.machine[0xE7F4], rig.machine[0xE7F5]) : (rng.byte(), rng.byte())
            let record = [0x05, freq.0, rng.pick(4) == 0 ? rng.byte() : freq.1] + (0..<6).map { _ in rng.byte() }
            for (k, b) in record.enumerated() { rig.poke(pc + k, b) }
            rig.poke(0x08BE, rng.pick(4) == 0 ? 0 : 1)
            rig.poke(0x08BD, 1)
            rig.poke(0xE7F3, 0)
            rig.run(0xE956, .init(), "record at $\(hex16(pc)) case \(i)") {
                let a = $0.ndbHook(); $0.charge(6); return .init(a: a)
            }
        }
        ReadoutFixtures.expectClean(rig, "ndbHook")
    }

    // MARK: Interleaving

    /// The unit's work in the main loop's order, pass after pass, while the aircraft flies past
    /// the stations and turns: the draw sequence ($3C3F, $3AB9, $3BAF, $3C1A, $3773, $377C,
    /// $3823, $EBA5), phase 0 ($EBF2, $3A13, and once per 8 passes $38D4/$38F5/$EA50), the odd
    /// passes ($3B32, $3B9B, $E7FE) and the 1 Hz clock ($39B6). The scenery's station lookups
    /// are imitated: requests are answered (found bits set again), the glideslope reference is
    /// stored each pass on the ILS, and marker flags come and go.
    @Test func mainLoopPasses() throws {
        let reference = try Self.champaign().reference
        for name in Self.stationSnapshots + ["regular", "b3-night"] {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0x20D5)
            // The nav chains push down to about $01EA; below that the stack page is data.
            let stack = ReadoutFixtures.StackWatch(0x0100..<0x01C0)
            func call(_ address: UInt16, _ label: String, _ port: (Machine) -> Void) {
                rig.run(address, .init(), "\(name) \(label)") { port($0); return .init() }
                stack.check(rig, "\(name) \(label)")
            }
            let ils = name.hasPrefix("b3-ils")
            var east = Int32(bitPattern: rig.machine.u32(0x5A)), north = Int32(bitPattern: rig.machine.u32(0x62))
            var heading = rig.machine.u16(0x70)
            let velocity = (Int32(rng.pick(0x6000)) - 0x3000, Int32(rng.pick(0x6000)) - 0x3000)
            for pass in 0..<240 {
                east &+= velocity.0
                north &+= velocity.1
                heading &+= UInt16(rng.pick(0x300)) &- 0x180
                for k in 0..<4 {
                    rig.poke(0x5A + k, UInt8(truncatingIfNeeded: east >> (8 * k)))
                    rig.poke(0x62 + k, UInt8(truncatingIfNeeded: north >> (8 * k)))
                }
                rig.poke16(0x70, heading)
                rig.poke16(0x0A8A, UInt16(clamping: max(0, 300 - pass)))
                rig.poke(0x09BE, UInt8(0x20 + rng.pick(0x30)))
                // The scenery: answer search requests, glideslope reference, marker flags.
                if rig.machine[0x0920] != 0 { rig.poke(0x0922, rig.machine[0x0922] | 3); rig.poke(0x0920, 0) }
                if rig.machine[0x08BD] != 0 { rig.poke(0xE7F3, 1); rig.poke(0x08BD, 0) }
                if ils { rig.poke16(0x0850, reference) }
                if rng.pick(10) == 0 { rig.poke([0x084A, 0x084C, 0x084E][rng.pick(3)], 1) }
                call(0x3C3F, "pass \(pass) NAV2 step") { $0.stepNav2Needle() }
                call(0x3AB9, "pass \(pass) tach") { $0.drawTach() }
                call(0x3BAF, "pass \(pass) OBI1") { $0.drawObi1() }
                call(0x3C1A, "pass \(pass) OBI2") { $0.drawObi2() }
                call(0x3773, "pass \(pass) heading") { $0.headingReadout() }
                call(0x377C, "pass \(pass) DG") { $0.drawDgDigits() }
                call(0x3823, "pass \(pass) compass") { $0.updateCompass() }
                call(0xEBA5, "pass \(pass) lights") { $0.updateLightingMasks() }
                if pass & 3 == 0 {
                    call(0xEBF2, "pass \(pass) time of day") { $0.selectTimeOfDay() }
                    call(0x3A13, "pass \(pass) DME") { $0.drawDme() }
                    if pass & 4 != 0 {
                        call(0x38D4, "pass \(pass) renew NAV1") { $0.renewNav1Search() }
                        call(0x38F5, "pass \(pass) renew NAV2") { $0.renewNav2Search() }
                        call(0xEA50, "pass \(pass) renew ADF") { _ = $0.renewAdfSearch() }
                    }
                }
                if pass & 1 != 0 {
                    call(0x3B32, "pass \(pass) NAV1 CDI") { $0.updateNav1Cdi() }
                    call(0x3B9B, "pass \(pass) NAV2 CDI") { $0.updateNav2Cdi() }
                    call(0xE7FE, "pass \(pass) ADF") { $0.updateAdf() }
                }
                if pass % 5 == 0 {
                    rig.poke(0x091A, UInt8((pass / 5) % 60))
                    call(0x39B6, "pass \(pass) seconds") { $0.drawClockSeconds() }
                }
            }
            ReadoutFixtures.expectClean(rig, "main-loop passes \(name)")
            stack.expectClean("main-loop passes \(name)")
        }
    }
}
