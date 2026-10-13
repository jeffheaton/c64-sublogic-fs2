import FS2Core
import FS2LabKit
import Foundation
import Testing

extension TestRandom {
    mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func nextWord() -> UInt16 { UInt16(truncatingIfNeeded: next() >> 24) }
}

/// Lab snapshots for the readout and nav tests: the running game with the radios tuned to
/// Chicago stations, at night, with the ADF tuned to an NDB, and on the Champaign ILS (localizer
/// 109.10) between and inside the marker boxes. One lab session produces all of them in order
/// (`snap:` steps); each name's own session is the prefix up to it, so any one can be rebuilt
/// alone and gives the same state.
///
/// The sessions hold CTRL by poking the game's CTRL flag `$0E67` around the key (this lab's
/// `key:CTRL+N` presses both keys in the same scan, and the scan meets N first).
enum ReadoutFixtures {
    static let prefix = """
        pc:2250:9000 key:A:12
        pc:2250:600 key:B:12
        pc:204B:3000
        wait:1500 pc:204B:3000
        """

    static func repeated(_ step: String, _ n: Int) -> String { Array(repeating: step, count: n).joined(separator: " ") }
    static func ctrl(_ key: String, twice: Bool = false) -> String {
        "poke:0E67:01 key:\(key):6 " + (twice ? "wait:6 key:\(key):6 wait:12" : "wait:20") + " poke:0E67:00"
    }
    static let dot = "key:.:6 wait:20", comma = "key:,:6 wait:20"

    /// (name, steps) in session order.
    static let segments: [(String, String)] = [
        ("b3-radios", [
            // NAV1 110.00 -> 114.20 (the VOR 38 km south of Meigs).
            ctrl("N"), "key:1:6 wait:20", repeated(dot, 4), ctrl("N", twice: true), repeated(dot, 4),
            // NAV2 111.35 -> 113.90 (the VOR 28 km north-west): kHz first, then MHz.
            "key:2:6 wait:20", repeated(dot, 11), ctrl("N"), repeated(dot, 2),
            // OBS2: held '.' auto-repeats; COM 124.85 -> 126.85; transponder 1200 -> 2200.
            ctrl("V"), "key:2:6 wait:20 key:.:390 wait:20",
            ctrl("C"), repeated(dot, 2), ctrl("X"), dot,
            "wait:400 pc:204B:3000",
        ].joined(separator: "\n")),
        // 22:00: night palette; the lights are on.
        ("b3-night", "poke:0983:16 wait:400 pc:204B:3000"),
        // Back to day, ADF enabled (as the editor's ADF ENABLE) and tuned 287 -> 332, the NDB
        // 24 km south-west of Meigs.
        ("b3-adf", [
            "poke:0983:0C wait:300 poke:09AA:01 poke:E7F2:01",
            "key:A:6 wait:20", dot,
            "key:A:6 wait:6 key:A:6 wait:12", repeated(dot, 5),
            "key:A:6 wait:6 key:A:6 wait:6 key:A:6 wait:12", repeated(dot, 5),
            "wait:400 pc:204B:3000",
        ].joined(separator: "\n")),
        // ADF off; NAV1 109.10 (Champaign localizer), OBS1 314; slew, 5 km south-east of the middle
        // marker on the extended centerline at 300 m.
        ("b3-ils-approach", [
            "poke:09AA:00",
            ctrl("N"), "key:1:6 wait:20", repeated(comma, 5), ctrl("N", twice: true), repeated(comma, 2),
            ctrl("V"), "key:1:6 wait:20", repeated(comma, 23),
            "poke:0966:01",
            "poke:5A:00 poke:5B:00 poke:5C:64 poke:5D:00 poke:62:00 poke:63:00 poke:64:FD poke:65:FF",
            "poke:5E:00 poke:5F:2C poke:60:01 poke:61:00 poke:0A13:00 poke:0A14:DF poke:70:00 poke:71:DF",
            "wait:2500 pc:204B:3000",
        ].joined(separator: "\n")),
        // In the outer marker box at 500 m (east 28.7 km, north -3.8 km).
        ("b3-ils-outer", "poke:5C:70 poke:64:F1 poke:5F:F4 poke:60:01 wait:900 pc:204B:3000"),
        // In the middle marker box at 60 m (east 22.0 km, north +2.6 km: the north high byte $65
        // must go from $FF back to $00, or the aircraft lands 63 km south, out of every box).
        ("b3-ils-middle", "poke:5C:56 poke:64:0A poke:65:00 poke:5F:3C poke:60:00 wait:900 pc:204B:3000"),
    ]

    /// The session that ends at segment `k`, with `snap:` steps for the earlier ones.
    static func session(upTo k: Int) -> String {
        var parts = [prefix]
        for i in 0...k {
            parts.append(segments[i].1)
            if i < k { parts.append("snap:\(segments[i].0)") }
        }
        return parts.joined(separator: "\n")
    }

    /// Generates (or loads) every fixture once per test process: the last one's session writes
    /// all the others on the way.
    private static let all = Result<[String: [UInt8]], Error>(catching: build)

    private static func build() throws -> [String: [UInt8]] {
        var out: [String: [UInt8]] = [:]
        for k in stride(from: segments.count - 1, through: 0, by: -1) {
            out[segments[k].0] = try Original.snapshot(segments[k].0, session: session(upTo: k))
        }
        out["regular"] = try Original.regularFlight()
        let demo = try String(contentsOf: Original.repoRoot.appendingPathComponent("re/sessions/demo.txt"),
                              encoding: .utf8)
        out["demo"] = try Original.snapshot("demo", session: demo)
        return out
    }

    static func ram(_ name: String) throws -> [UInt8] {
        guard let r = try all.get()[name] else { throw CocoaError(.fileNoSuchFile) }
        return r
    }

    static let names = ["regular", "demo", "b3-radios", "b3-night", "b3-adf", "b3-ils-approach",
                        "b3-ils-outer", "b3-ils-middle"]

    static func everything() throws -> [(String, [UInt8])] { try names.map { ($0, try ram($0)) } }

    /// `DiffRig.expectClean`, plus: the original wrote no I/O (the unit touches none).
    static func expectClean(_ rig: DiffRig, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        rig.expectClean(what, sourceLocation: sourceLocation)
        let io = rig.harness.bus.ioWrites.prefix(4).map { "$\(hex16(Int($0.address)))" }
        #expect(io.isEmpty, "\(what): the original wrote I/O at \(io)", sourceLocation: sourceLocation)
    }

    /// Compares the low part of the stack page after every call, which `DiffRig` skips because
    /// the original pushes there and the port does not. The unit can write it as data: the
    /// glideslope bar's rows past the 200-row tables resolve to bases $0000 and $0100 (positions
    /// 74/106 and 75/107), so its XORs land at $01B8-$01C8. A check at the end of a
    /// test cannot see a skipped write there, because the erase repeats the draw. `range` must stay
    /// below the deepest push of the routines under test (the nav chains $3B32 → $3B61 → $3C8F →
    /// $3E46 → … → $17EF reach about $01EA from the harness's $01FD). Resynchronizes after a
    /// mismatch.
    final class StackWatch {
        let range: Range<Int>
        private(set) var mismatches: [String] = []
        private(set) var count = 0

        init(_ range: Range<Int> = 0x0100..<0x01E0) { self.range = range }

        func check(_ rig: DiffRig, _ label: @autoclosure () -> String) {
            let differ = range.filter { rig.machine.mem[$0] != rig.harness.bus.ram[$0] }
            guard let first = differ.first else { return }
            count += 1
            if mismatches.count < 12 {
                mismatches.append("\(label()): $\(hex16(first)) = \(hex(rig.machine.mem[first]))"
                                  + " want \(hex(rig.harness.bus.ram[first])) (\(differ.count) bytes differ)")
            }
            for a in differ { rig.machine.mem[a] = rig.harness.bus.ram[a] }
        }

        func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let report = "\(what): \(count) calls left the stack page $\(hex16(range.lowerBound))-"
                + "$\(hex16(range.upperBound - 1)) different\n" + mismatches.joined(separator: "\n")
            #expect(count == 0, "\(report)", sourceLocation: sourceLocation)
        }
    }
}

/// Differential tests of the readouts ($2240, $3773-$3AF0, $EB82), the radio displays
/// ($3896-$3922, $3A5C), the ADF tuning helpers ($E9A7-$EA5B) and the time-of-day palette
/// ($EBA5-$EC98): the original routine in the lab and the port on twin images of the running
/// game, comparing the whole image (stack page excluded), the modeled registers and the exact
/// cycles after every call.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct ReadoutTests {
    // MARK: Fixtures sanity

    /// The sessions reached the states they are meant for.
    @Test func fixturesReachTheirStates() throws {
        let radios = try ReadoutFixtures.ram("b3-radios")
        #expect(Array(radios[0x21B7...0x21BA]) == Array("1420".utf8), "NAV1 tuned to 114.20")
        #expect(Array(radios[0x21BE...0x21C1]) == Array("1390".utf8), "NAV2 tuned to 113.90")
        #expect(radios[0x0922] & 1 != 0, "NAV1 station found")
        #expect(radios[0x2199] > 20, "OBS2 moved")
        let night = try ReadoutFixtures.ram("b3-night")
        #expect(night[0x083C] == 4, "night")
        let adf = try ReadoutFixtures.ram("b3-adf")
        #expect(Array(adf[0xE7FA...0xE7FC]) == Array("332".utf8), "ADF tuned to 332")
        #expect(adf[0xE7F3] == 1, "NDB found")
        #expect(adf[0x09AA] != 0, "ADF enabled")
        let approach = try ReadoutFixtures.ram("b3-ils-approach")
        #expect(Array(approach[0x21B7...0x21BA]) == Array("0910".utf8), "NAV1 tuned to 109.10")
        #expect(approach[0x0922] & 1 != 0, "NAV1 localizer found on the approach")
        #expect(approach[0x0933] != 0, "NAV1 station is a localizer")
        #expect(approach[0x2196] == 157, "OBS1 = 314 degrees")
        let outer = try ReadoutFixtures.ram("b3-ils-outer")
        #expect(Array(outer[0x7E7B...0x7E7D]) == [0xEB, 0xBB, 0xBB], "outer marker lit")
        let middle = try ReadoutFixtures.ram("b3-ils-middle")
        #expect(Array(middle[0x7E7B...0x7E7D]) == [0xBB, 0xAB, 0xBB], "middle marker lit")
        // (The snapshot falls on a renewal pass: `$0922` is clear and `$0920` raised again.)
        #expect(middle[0x0933] != 0, "station B is still the localizer at the middle marker")
        #expect(middle[0x0850] != 0, "glideslope reference stored at the middle marker")
        #expect(middle[0x09AB] == 0 && middle[0x09AE] == 0, "DME under 1 nm at the middle marker")
    }

    // MARK: DG, compass, format ($377C, $3823, $3804, $37EA)

    /// The DG over random headings, DG offsets and area offsets, with the drawn byte $2197 often
    /// equal (no redraw), the $8000 case, and the mask off.
    @Test func dgDigits() throws {
        for (name, ram) in try ReadoutFixtures.everything() {
            let rig = DiffRig(ram)
            var rng = TestRandom(seed: 0x377C)
            for i in 0..<300 {
                rig.poke(0xFD, rng.pick(8) == 0 ? 0xFB : 0xFF)
                rig.poke16(0x70, rng.nextWord())
                rig.poke16(0x08C0, rng.pick(3) == 0 ? 0 : rng.nextWord())
                rig.poke16(0x0846, rng.pick(2) == 0 ? 0 : rng.nextWord())
                rig.poke16(0x0848, rng.pick(2) == 0 ? 0 : rng.nextWord())
                if i % 50 == 7 {
                    // heading + offsets = $8000 exactly (turned into $8001).
                    let sum = rig.machine.u16(0x70) &+ rig.machine.u16(0x08C0) &- rig.machine.u16(0x0848)
                    rig.poke16(0x0846, sum &- 0x8000)
                }
                for step in 0..<2 {
                    rig.run(0x377C, .init(), "\(name) case \(i) step \(step)") { $0.drawDgDigits(); return .init() }
                }
            }
            ReadoutFixtures.expectClean(rig, "drawDgDigits \(name)")
        }
    }

    /// The compass hunting toward random headings from every side.
    @Test func compass() throws {
        for (name, ram) in try ReadoutFixtures.everything() {
            let rig = DiffRig(ram)
            var rng = TestRandom(seed: 0x3823)
            for i in 0..<200 {
                rig.poke(0xFE, rng.pick(8) == 0 ? 0xEF : 0xFF)
                rig.poke16(0x70, rng.nextWord())
                rig.poke16(0x08C5, rng.nextWord())
                rig.poke16(0x0846, rng.pick(2) == 0 ? 0 : rng.nextWord())
                rig.poke16(0x0848, rng.pick(2) == 0 ? 0 : rng.nextWord())
                for step in 0..<3 {
                    rig.run(0x3823, .init(), "\(name) case \(i) step \(step)") { $0.updateCompass(); return .init() }
                }
            }
            // Near the heading: differences around the ±$0A00 limits.
            for d in stride(from: -0x0C00, through: 0x0C00, by: 0x00A7) {
                rig.poke16(0x08C5, UInt16(truncatingIfNeeded: 0x4000 + d))
                rig.poke16(0x70, 0x4000)
                rig.poke16(0x0846, 0)
                rig.poke16(0x0848, 0)
                rig.run(0x3823, .init(), "\(name) difference \(d)") { $0.updateCompass(); return .init() }
            }
            ReadoutFixtures.expectClean(rig, "updateCompass \(name)")
        }
    }

    /// $3804 on values 0-65535 (digits past '9' from 1000 up) into records and free memory.
    @Test func format3DigitsValues() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("b3-radios"))
        var rng = TestRandom(seed: 0x3804)
        let fields: [UInt16] = [0x219E, 0x21AA, 0xE932, 0x03A0, 0x03FE, 0xC0FF]
        for i in 0..<600 {
            let field = fields[rng.pick(fields.count)]
            rig.poke16(0xB8, i < 300 ? UInt16(i) : (i < 400 ? UInt16(i * 97) : rng.nextWord()))
            rig.run(0x3804, .init(a: UInt8(field & 0xFF), x: UInt8(field >> 8)), "value \(i) at $\(hex16(Int(field)))") {
                $0.format3Digits(field: field); return .init()
            }
        }
        ReadoutFixtures.expectClean(rig, "format3Digits")
    }

    /// $37EA and $37F5 directly over the whole circle.
    @Test func headingToDegrees() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("regular"))
        var rng = TestRandom(seed: 0x37EA)
        for i in 0..<512 {
            let angle = i < 256 ? UInt16(i) << 8 | UInt16(i) : rng.nextWord()
            rig.run(0x37EA, .init(a: UInt8(angle & 0xFF), x: UInt8(angle >> 8)), "angle \(angle)") {
                let r = $0.headingToDegrees(UInt8(angle & 0xFF), UInt8(angle >> 8)); return .init(a: r.lo, x: r.hi)
            }
            let v = rng.nextWord() % 720 &- 360
            rig.run(0x37F5, .init(a: UInt8(v & 0xFF), x: UInt8(v >> 8)), "wrap \(Int16(bitPattern: v))") {
                let r = $0.wrapDegrees(UInt8(v & 0xFF), UInt8(v >> 8)); return .init(a: r.lo, x: r.hi)
            }
        }
        ReadoutFixtures.expectClean(rig, "headingToDegrees")
    }

    // MARK: OBS, clock, DME, labels, tach ($3923, $3976, $39B6, $39D9, $3A13, $3A71, $3AB9)

    @Test func obsReadouts() throws {
        for (name, ram) in try ReadoutFixtures.everything() {
            let rig = DiffRig(ram)
            for v in 0...255 {
                let obs = UInt8(v)
                rig.poke(0x2196, obs)
                rig.poke(0x2199, obs &+ 77)
                rig.poke(0xFD, v % 9 == 0 ? 0xDF : 0xFF)
                rig.poke(0xFF, v % 11 == 0 ? 0x07 : 0x0F)
                rig.poke(0x09AA, v % 7 == 0 ? 1 : 0)
                rig.run(0x3923, .init(), "\(name) OBS1 \(v)") { $0.drawObs1(); return .init() }
                rig.run(0x3976, .init(), "\(name) OBS2 \(v)") { $0.drawObs2(); return .init() }
            }
            ReadoutFixtures.expectClean(rig, "OBS \(name)")
        }
    }

    @Test func clock() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("b3-radios"))
        for hours in 0..<32 {
            for minutes in stride(from: 0, to: 64, by: 7) {
                rig.poke(0x0983, UInt8(hours))
                rig.poke(0x0984, UInt8(minutes))
                rig.poke(0xFE, hours % 10 == 9 ? 0x7F : 0xFF)
                rig.run(0x39D9, .init(), "\(hours):\(minutes)") { $0.drawClock(); return .init() }
                for seconds in [0, 1, 9, 10, 59, UInt8(hours * 2 + minutes)] {
                    rig.poke(0x091A, UInt8(seconds))
                    rig.run(0x39B6, .init(), "\(hours):\(minutes):\(seconds)") { $0.drawClockSeconds(); return .init() }
                }
            }
        }
        // Large values: tens digits past '9'.
        for v: UInt8 in [99, 100, 127, 200, 255] {
            rig.poke(0x0983, v); rig.poke(0x0984, v); rig.poke(0x091A, v)
            rig.run(0x39D9, .init(), "clock \(v)") { $0.drawClock(); return .init() }
            rig.run(0x39B6, .init(), "seconds \(v)") { $0.drawClockSeconds(); return .init() }
        }
        ReadoutFixtures.expectClean(rig, "clock")
    }

    @Test func dmeReadout() throws {
        for name in ["b3-radios", "b3-ils-approach", "regular"] {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0x3A13)
            for i in 0..<300 {
                rig.poke(0xFE, rng.pick(10) == 0 ? 0x7F : 0xFF)
                rig.poke(0x09AB, rng.pick(4) == 0 ? UInt8(1 + rng.pick(255)) : 0)
                rig.poke(0x09AC, UInt8(rng.pick(4)))
                rig.poke(0x09AD, UInt8(rng.pick(i < 200 ? 10 : 256)))
                rig.poke(0x09AE, UInt8(rng.pick(i < 200 ? 100 : 256)))
                rig.run(0x3A13, .init(), "\(name) case \(i)") { $0.drawDme(); return .init() }
            }
            ReadoutFixtures.expectClean(rig, "drawDme \(name)")
        }
    }

    @Test func engineLabels() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("b3-radios"))
        for carb: UInt8 in [0, 1, 0x80] {
            for lights: UInt8 in [0, 1, 0xFF] {
                for label: UInt8 in 0...4 {
                    for gate: UInt8 in [0xFF, 0x7F] {
                        rig.poke(0x0AA9, carb)
                        rig.poke(0x0AB5, lights)
                        rig.poke(0x0AB6, label)
                        rig.poke(0xFE, gate)
                        rig.run(0x3A71, .init(), "carb \(carb) lights \(lights) label \(label) gate \(gate)") {
                            $0.drawMagnetoLabel(); return .init()
                        }
                    }
                }
            }
        }
        // Every engine value, up and down, with the mask and the equal case.
        for pass in 0..<2 {
            for v in 0...255 {
                let rpm = UInt8(pass == 0 ? v : 255 - v)
                rig.poke(0x09BE, rpm)
                rig.poke(0xFD, v % 13 == 0 ? 0xBF : 0xFF)
                for step in 0..<2 {
                    rig.run(0x3AB9, .init(), "tach \(rpm) pass \(pass) step \(step)") { $0.drawTach(); return .init() }
                }
            }
        }
        ReadoutFixtures.expectClean(rig, "magneto label and tach")
        // The label index is not checked: 5-255 take pointers from the code after the table (some
        // read across a page; the index doubling wraps 128 up) and draw whatever they point at;
        // each on a fresh image.
        let ram = try ReadoutFixtures.ram("b3-radios")
        for label in 5...255 {
            let wild = DiffRig(ram)
            let stack = ReadoutFixtures.StackWatch()
            wild.poke(0x0AB6, UInt8(label))
            wild.run(0x3A71, .init(), "label \(label)") { $0.drawMagnetoLabel(); return .init() }
            stack.check(wild, "label \(label)")
            ReadoutFixtures.expectClean(wild, "magneto label \(label)")
            stack.expectClean("magneto label \(label)")
        }
    }

    // MARK: Slew readout, panel redraw ($3773, $EB82, $2240)

    @Test func slewAndRedraw() throws {
        for (name, ram) in try ReadoutFixtures.everything() {
            let rig = DiffRig(ram)
            var rng = TestRandom(seed: 0xEB82)
            for i in 0..<60 {
                rig.poke(0x0966, rng.pick(3) == 0 ? 0 : UInt8(1 + rng.pick(255)))
                rig.poke16(0x096B, i == 0 ? 0x8000 : rng.nextWord())
                rig.poke16(0x096D, i == 1 ? 0x8000 : rng.nextWord())
                rig.run(0x3773, .init(), "\(name) slew \(i)") { $0.headingReadout(); return .init() }
            }
            for gate: UInt8 in [0xFF, 0x7F, 0x80] {
                rig.poke(0xFE, gate)
                rig.poke(0x09AA, gate == 0x80 ? 1 : 0)
                rig.run(0x2240, .init(), "\(name) redraw gate \(gate)") { $0.panelRedraw(); return .init() }
            }
            ReadoutFixtures.expectClean(rig, "slew readout and panel redraw \(name)")
        }
    }

    // MARK: Radio displays ($3896-$3922, $3A5C, $38D4, $38F5)

    /// Random digit strings (mostly '0'-'9', some other characters) in the four radio records.
    @Test func radioDisplays() throws {
        for name in ["b3-radios", "b3-ils-approach", "demo"] {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0x38BD)
            for i in 0..<250 {
                for field in [0x21B0, 0x21B7, 0x21BE, 0x21DD] {
                    for k in 0..<4 {
                        rig.poke(field + k, rng.pick(12) == 0 ? rng.byte() & 0x5F | 0x20 : 0x30 + UInt8(rng.pick(10)))
                    }
                }
                rig.poke(0xFE, rng.pick(8) == 0 ? 0x7F : 0xFF)
                rig.poke(0x09AA, rng.pick(5) == 0 ? 1 : 0)
                rig.poke(0x0922, rng.byte())
                switch i % 6 {
                case 0: rig.run(0x38BD, .init(), "\(name) NAV1 \(i)") { $0.drawNav1Frequency(); return .init() }
                case 1: rig.run(0x38D9, .init(), "\(name) NAV2 \(i)") { $0.drawNav2Frequency(); return .init() }
                case 2: rig.run(0x3903, .init(), "\(name) COM \(i)") { $0.drawComFrequency(); return .init() }
                case 3: rig.run(0x3A5C, .init(), "\(name) XPDR \(i)") { $0.drawTransponder(); return .init() }
                case 4: rig.run(0x38D4, .init(), "\(name) renew NAV1 \(i)") { $0.renewNav1Search(); return .init() }
                default: rig.run(0x38F5, .init(), "\(name) renew NAV2 \(i)") { $0.renewNav2Search(); return .init() }
                }
            }
            // $3896 on its own across page ends.
            for field: UInt16 in [0x21B0, 0x03FC, 0x03FD, 0x03FE, 0x03FF] {
                rig.run(0x3896, .init(a: UInt8(field & 0xFF), x: UInt8(field >> 8)), "\(name) parse $\(hex16(Int(field)))") {
                    let r = $0.parseFrequencyDigits(field); return .init(a: r.lo, x: r.hi)
                }
            }
            ReadoutFixtures.expectClean(rig, "radio displays \(name)")
        }
    }

    // MARK: ADF tuning ($E9A7, $E9BF, $E9F6, $EA50)

    @Test func adfTuning() throws {
        for name in ["b3-adf", "b3-radios"] {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0xE9BF)
            for i in 0..<400 {
                let fc = UInt8(rng.pick(4) == 0 ? rng.pick(256) : [3, 3, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 1][rng.pick(8)])
                rig.poke(0xFC, fc)
                rig.poke(0x09AA, rng.pick(4) == 0 ? 0 : 1)
                rig.poke(0x0A9A, UInt8(rng.pick(8)))
                rig.poke(0x091C, rng.pick(2) == 0 ? 0 : UInt8(1 + rng.pick(3)))
                if rng.pick(5) == 0 {
                    for k in 0..<3 { rig.poke(0xE7FA + k, 0x30 + UInt8(rng.pick(10))) }
                }
                switch i % 5 {
                case 0, 1:
                    rig.run(0xE9BF, .init(), "\(name) ',' FC \(fc) case \(i)") { .init(a: $0.tuneDecrementPre()) }
                case 2, 3:
                    rig.run(0xE9F6, .init(), "\(name) '.' FC \(fc) case \(i)") { .init(a: $0.tuneIncrementPre()) }
                default:
                    rig.run(0xE9A7, .init(), "\(name) select FC \(fc) case \(i)") { $0.selectAdfDigit(); return .init() }
                }
            }
            for i in 0..<4 {
                rig.run(0xEA50, .init(), "\(name) renew \(i)") { .init(a: $0.renewAdfSearch()) }
            }
            ReadoutFixtures.expectClean(rig, "ADF tuning \(name)")
        }
    }

    // MARK: Time of day ($EBF2, $EC41, $EC7C, $EBA5)

    /// Every hour, the minutes around the thresholds and every season (and season bytes up to 9,
    /// which drive the $0884 loop), with the snapshot's palette and a random one (so every pair
    /// differs); then the state repeated (no repaint) and random states into $EC41 directly.
    @Test func timeOfDay() throws {
        for name in ["regular", "b3-night"] {
            let rig = DiffRig(try ReadoutFixtures.ram(name))
            var rng = TestRandom(seed: 0xEBF2)
            let palettes: [[UInt8]] = [Array(rig.machine.memoryImage[0x0E61...0x0E66]), (0..<6).map { _ in rng.byte() }]
            for season: UInt8 in [0, 1, 2, 3, 4, 7, 9, 0xFF] {
                let palette = palettes[Int(season) & 1]
                for (k, v) in palette.enumerated() { rig.poke(0x0E61 + k, v) }
                rig.poke(0x0985, season)
                for hour: UInt8 in 0..<25 {
                    for minute: UInt8 in [0, 29, 30, 59] {
                        rig.poke(0x0983, hour)
                        rig.poke(0x0984, minute)
                        rig.run(0xEBF2, .init(), "\(name) season \(season) \(hour):\(minute)") {
                            $0.selectTimeOfDay(); return .init()
                        }
                    }
                }
            }
            // Clock bytes out of range: the "before" test is the sign of an 8-bit difference.
            for i in 0..<60 {
                let hour = rng.byte(), minute = rng.byte()
                rig.poke(0x0983, hour)
                rig.poke(0x0984, minute)
                rig.poke(0x0985, rng.byte())
                rig.run(0xEBF2, .init(), "\(name) wild clock \(hour):\(minute) case \(i)") {
                    $0.selectTimeOfDay(); return .init()
                }
            }
            for i in 0..<40 {
                let state = UInt8(rng.pick(4) == 0 ? rng.pick(256) : [1, 2, 4][rng.pick(3)])
                rig.poke(0x0985, UInt8(rng.pick(5)))
                for k in 0..<6 { rig.poke(0x0E61 + k, rng.byte()) }
                rig.run(0xEC41, .init(a: state), "\(name) apply \(state) case \(i)") { $0.applyPalette(state); return .init() }
            }
            for byte: UInt8 in [0, 0x65, 0xFF] {
                rig.run(0xEC7C, .init(a: byte), "\(name) fill \(byte)") { $0.fillWindowColors(byte); return .init() }
            }
            ReadoutFixtures.expectClean(rig, "time of day \(name)")
        }
    }

    @Test func lightingMasks() throws {
        let rig = DiffRig(try ReadoutFixtures.ram("b3-night"))
        var rng = TestRandom(seed: 0xEBA5)
        for state: UInt8 in 0..<8 {
            for lights: UInt8 in [0, 1, 0xFF] {
                rig.poke(0x083C, state)
                rig.poke(0x0AB5, lights)
                for k in 0..<3 { rig.poke(0x08DC + k, rng.byte()) }
                rig.run(0xEBA5, .init(), "state \(state) lights \(lights)") { $0.updateLightingMasks(); return .init() }
            }
        }
        ReadoutFixtures.expectClean(rig, "updateLightingMasks")
    }
}
