import FS2Core
import FS2LabKit
import Foundation
import Testing

fileprivate extension TestRandom {
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func coin() -> Bool { next() & 0x100 != 0 }
}

/// Differential tests of the panel gauges and indicators ($1A0B-$1D53, $CE84-$CFB3, $F2E6-$F521,
/// $F7DB-$F8AE): each case runs the original routine in the lab and the port on twin images of
/// the running game (regular flight and demo snapshots) and compares the whole 64 KB image (stack
/// page excluded), the modeled registers and the exact cycle count after every call. Both images
/// keep their state between calls, so the XOR erase/redraw sequences are checked step by step.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct GaugeTests {
    // MARK: Fixtures

    /// Loaded once per test process (the tests run in parallel, and a cold cache boots the lab).
    private static let regularRAM: Result<[UInt8], Error> = Result { try Original.regularFlight() }
    private static let demoRAM: Result<[UInt8], Error> = Result {
        let text = try String(contentsOf: Original.repoRoot.appendingPathComponent("re/sessions/demo.txt"),
                              encoding: .utf8)
        return try Original.snapshot("demo", session: text)
    }

    /// Regular flight at Meigs (re/sessions/regular.txt), early in the first main-loop pass.
    static func regular() throws -> [UInt8] { try regularRAM.get() }

    /// The demo flight (re/sessions/demo.txt): every gauge has been driven for a while.
    static func demo() throws -> [UInt8] { try demoRAM.get() }

    static func snapshots() throws -> [(String, [UInt8])] {
        [("regular", try regular()), ("demo", try demo())]
    }

    /// The panel bitmap ($5180-$5F3F).
    static func panel(_ m: Machine) -> [UInt8] { Array(UnsafeBufferPointer(start: m.mem + 0x5180, count: 0xDC0)) }

    /// The part of the stack page `DiffRig` cannot compare but these routines can write as data:
    /// `DiffRig` skips the whole page because the original pushes there and the port does not,
    /// but no routine here nests deeper than $01F5, and the elevator marker's rows past the row
    /// tables (positions over 28) XOR into $0168.
    static let lowStack = 0x0100..<0x01F0

    /// `DiffRig.expectClean` plus two checks it leaves out: the low stack page (`lowStack`) at
    /// the end, and no write by the original to $D000-$DFFF (the unit touches no I/O, so the
    /// port must not need `machine.io`).
    static func expectClean(_ rig: DiffRig, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        rig.expectClean(what, sourceLocation: sourceLocation)
        let stack = lowStack.filter { rig.machine.mem[$0] != rig.harness.bus.ram[$0] }
        #expect(stack.isEmpty, "\(what): stack page differs at \(stack.prefix(8).map { "$" + hex16($0) })",
                sourceLocation: sourceLocation)
        let io = rig.harness.bus.ioWrites.prefix(4).map { "$\(hex16(Int($0.address)))" }
        #expect(io.isEmpty, "\(what): the original wrote I/O at \(io)", sourceLocation: sourceLocation)
    }

    /// Compares `lowStack` after every call. An end-of-test check is not enough there: a marker
    /// that is drawn and later erased XORs the same bytes twice, so a port that skipped both
    /// writes would end up equal. Resynchronizes the port's bytes after a mismatch.
    final class StackWatch {
        private(set) var mismatches: [String] = []
        private(set) var count = 0

        func check(_ rig: DiffRig, _ label: @autoclosure () -> String) {
            let differ = GaugeTests.lowStack.filter { rig.machine.mem[$0] != rig.harness.bus.ram[$0] }
            guard let first = differ.first else { return }
            count += 1
            if mismatches.count < 12 {
                mismatches.append("\(label()): $\(hex16(first)) = \(hex(rig.machine.mem[first]))"
                                  + " want \(hex(rig.harness.bus.ram[first])) (\(differ.count) bytes differ)")
            }
            for a in differ { rig.machine.mem[a] = rig.harness.bus.ram[a] }
        }

        func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let report = "\(what): \(count) calls left the low stack page different\n"
                + mismatches.joined(separator: "\n")
            #expect(count == 0, "\(report)", sourceLocation: sourceLocation)
        }
    }

    // MARK: drawNeedle ($1A86)

    /// Every gauge at every angle, then every angle again (which must erase it exactly).
    @Test func needleEveryAngle() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            let start = Self.panel(rig.machine)
            for pass in 0..<2 {
                for gauge: UInt8 in 0...4 {
                    for angle: UInt8 in 0..<88 {
                        rig.run(0x1A86, .init(a: angle, x: gauge), "\(name) pass \(pass) gauge \(gauge) angle \(angle)") {
                            $0.drawNeedle(angle: angle, gauge: gauge); return .init()
                        }
                    }
                }
            }
            #expect(Self.panel(rig.machine) == start, "\(name): drawing every needle twice must restore the panel")
            Self.expectClean(rig, "drawNeedle \(name)")
        }
    }

    /// Each needle drawn and erased at once, so the panel returns to its start after each pair.
    @Test func needleDrawThenErase() throws {
        let rig = DiffRig(try Self.demo())
        let start = Self.panel(rig.machine)
        var clean = true
        for gauge: UInt8 in 0...4 {
            for angle: UInt8 in 0..<88 {
                for step in 0..<2 {
                    rig.run(0x1A86, .init(a: angle, x: gauge), "gauge \(gauge) angle \(angle) step \(step)") {
                        $0.drawNeedle(angle: angle, gauge: gauge); return .init()
                    }
                }
                if Self.panel(rig.machine) != start { clean = false }
            }
        }
        #expect(clean, "a needle drawn twice must leave no trace")
        Self.expectClean(rig, "drawNeedle pairs")
    }

    /// Angle 88 (shape index 0 drawn in the lower right quadrant: the 8-bit index arithmetic) and
    /// every needle type at every center. Larger angles read pointers out of the shape data and
    /// draw wherever those point, so they are not exercised.
    @Test func needleUnusualAngles() throws {
        let rig = DiffRig(try Self.demo())
        for gauge: UInt8 in 0...4 {
            for angle: UInt8 in [88] {
                for _ in 0..<2 {
                    rig.run(0x1A86, .init(a: angle, x: gauge), "gauge \(gauge) angle \(angle)") {
                        $0.drawNeedle(angle: angle, gauge: gauge); return .init()
                    }
                }
            }
        }
        // Swap the needle types so each center draws the other shape set.
        for gauge in 0..<5 { rig.poke(Gauges.needleType + gauge, rig.machine[Gauges.needleType + gauge] ^ 1) }
        for gauge: UInt8 in 0...4 {
            for angle in stride(from: 0, to: 88, by: 3).map(UInt8.init) {
                rig.run(0x1A86, .init(a: angle, x: gauge), "swapped type gauge \(gauge) angle \(angle)") {
                    $0.drawNeedle(angle: angle, gauge: gauge); return .init()
                }
            }
        }
        Self.expectClean(rig, "drawNeedle unusual")
    }

    // MARK: Altimeter ($CE84, $1A0B)

    /// The altitude swept up through several 1000-ft and 10,000-ft wraps of both hands and back
    /// down, with field elevation and altimeter offset varied, negatives included.
    @Test func altimeterSweep() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            rig.poke(Gauges.instrumentMask0, 0xFF)
            var rng = TestRandom(seed: 0xA171)
            func update(_ label: String) {
                rig.run(0xCE84, .init(), label) { $0.altimeterUpdate(); return .init() }
            }
            func setAltitude(_ meters: Int) {
                rig.poke16(0x5F, UInt16(truncatingIfNeeded: meters))
            }
            // Up to 12,500 m in 9-m steps: every long-hand step, both hands wrapping.
            rig.poke16(0x0A87, 0)
            rig.poke16(0x09CE, 0)
            for meters in stride(from: 0, through: 12_500, by: 9) {
                setAltitude(meters)
                rig.poke(0x5E, rng.byte())
                update("\(name) up \(meters) m")
            }
            // Back down with a field elevation and offset, through zero to negative MSL values.
            rig.poke16(0x0A87, 180)
            rig.poke16(0x09CE, 0xFFF0)
            for meters in stride(from: 3500, through: -400, by: -13) {
                setAltitude(meters)
                update("\(name) down \(meters) m")
            }
            // Random: full 16-bit altitude, field elevation and offset (the product is signed).
            for i in 0..<1500 {
                rig.poke16(0x5F, UInt16(truncatingIfNeeded: rng.next()))
                if rng.below(4) == 0 { rig.poke16(0x0A87, UInt16(truncatingIfNeeded: rng.next())) }
                if rng.below(4) == 0 { rig.poke16(0x09CE, UInt16(truncatingIfNeeded: rng.next() >> 50)) }
                update("\(name) random \(i)")
            }
            // Disabled: only the mask test runs.
            rig.poke(Gauges.instrumentMask0, 0xF7)
            for meters in [0, 1000, 5000] {
                setAltitude(meters)
                update("\(name) disabled \(meters)")
            }
            Self.expectClean(rig, "altimeterUpdate \(name)")
        }
    }

    /// $1A0B with chosen hand targets: the long hand unchanged (no redraw even when the short
    /// hand moved), both hands on the same angle (the needles overlap and cancel), random pairs.
    @Test func altimeterNeedlePairs() throws {
        let rig = DiffRig(try Self.demo())
        var rng = TestRandom(seed: 0x1A0B)
        func update(_ long: UInt8, _ short: UInt8, _ label: String) {
            rig.poke(Gauges.altimeterLongHand, long)
            rig.poke(Gauges.altimeterShortHand, short)
            rig.run(0x1A0B, .init(), label) { $0.updateAltimeterNeedles(); return .init() }
        }
        for angle: UInt8 in 0..<88 { update(angle, angle, "overlap \(angle)") }
        let long = rig.machine[Gauges.needleAngles]
        for short: UInt8 in stride(from: 0, to: 88, by: 7) { update(long, short, "long unchanged, short \(short)") }
        for i in 0..<600 { update(UInt8(rng.below(88)), UInt8(rng.below(88)), "random \(i)") }
        Self.expectClean(rig, "updateAltimeterNeedles")
    }

    // MARK: Airspeed ($CF0E, $1A32)

    /// Every airspeed high byte with low bytes around the bit that picks the half step, then the
    /// needle stepping toward each target with the 1/4 smoothing.
    @Test func airspeedTargets() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            rig.poke(Gauges.instrumentMask0, 0xFF)
            for hi in 0..<256 {
                for lo: UInt8 in [0x00, 0x7F, 0x80, 0xFF] {
                    rig.poke(0x0A4D, UInt8(hi))
                    rig.poke(0x0A4C, lo)
                    rig.run(0xCF0E, .init(carry: lo & 1 != 0), "\(name) airspeed $\(hex16(hi << 8 | Int(lo)))") {
                        $0.airspeedUpdate(); return .init()
                    }
                }
            }
            rig.poke(Gauges.instrumentMask0, 0xFE)
            rig.run(0xCF0E, .init(), "\(name) disabled") { $0.airspeedUpdate(); return .init() }
            Self.expectClean(rig, "airspeedUpdate \(name)")
        }
    }

    @Test func airspeedNeedleSmoothing() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            rig.poke(Gauges.instrumentMask0, 0xFF)
            var rng = TestRandom(seed: 0x1A32)
            func tick(_ label: String) {
                rig.run(0x1A32, .init(), label) { $0.updateAirspeedNeedle(); return .init() }
            }
            // Targets across the table's range (26-110, so the stored angle passes 88) and a
            // little beyond. They stay within 127 of each other: a larger 8-bit difference turns
            // round and walks the stored angle past 175, which draws from outside the shape
            // tables.
            var targets: [UInt8] = [110, 26, 88, 87, 0, 120, 60, 1, 100, 44, 89]
            for _ in 0..<40 { targets.append(UInt8(rng.below(121))) }
            for (k, target) in targets.enumerated() {
                rig.poke(Gauges.asiNeedle, target)
                for step in 0..<40 {
                    tick("\(name) target \(k)=\(target) step \(step)")
                    if rig.machine[Gauges.needleAngles + 2] == target { break }
                }
                tick("\(name) target \(k) settled")
            }
            // The full driver chain: the target from the airspeed, then the 5 Hz step.
            for i in 0..<300 {
                rig.poke16(0x0A4C, UInt16(truncatingIfNeeded: rng.next()) & 0x7FFF)
                rig.run(0xCF0E, .init(), "\(name) chain target \(i)") { $0.airspeedUpdate(); return .init() }
                tick("\(name) chain step \(i)")
            }
            rig.poke(Gauges.instrumentMask0, 0xFE)
            rig.poke(Gauges.asiNeedle, 3)
            tick("\(name) disabled")
            Self.expectClean(rig, "updateAirspeedNeedle \(name)")
        }
    }

    // MARK: VSI ($CF46, $1A6A)

    @Test func vsiTargets() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            rig.poke(Gauges.instrumentMask0, 0xFF)
            for hi in 0..<256 {
                for lo: UInt8 in [0x00, 0x3F, 0x40, 0x7F, 0x80, 0xBF, 0xC0, 0xFF] {
                    for carry in [false, true] {
                        rig.poke(0x0A51, UInt8(hi))
                        rig.poke(0x0A50, lo)
                        rig.run(0xCF46, .init(carry: carry), "\(name) vs $\(hex16(hi << 8 | Int(lo))) C=\(carry)") {
                            $0.vsiUpdate(); return .init()
                        }
                    }
                }
            }
            rig.poke(Gauges.instrumentMask0, 0x7F)
            rig.run(0xCF46, .init(), "\(name) disabled") { $0.vsiUpdate(); return .init() }
            Self.expectClean(rig, "vsiUpdate \(name)")
        }
    }

    @Test func vsiNeedleSteps() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            rig.poke(Gauges.instrumentMask0, 0xFF)
            var rng = TestRandom(seed: 0x1A6A)
            func tick(_ label: String) {
                rig.run(0x1A6A, .init(), label) { $0.updateVsiNeedle(); return .init() }
            }
            // Full deflections both ways (the needle walks the whole scale), then random targets.
            var targets: [UInt8] = [43, 4, 79, 43, 0, 87, 43]
            for _ in 0..<25 { targets.append(UInt8(4 + rng.below(76))) }
            for (k, target) in targets.enumerated() {
                rig.poke(Gauges.vsiNeedle, target)
                for step in 0..<100 {
                    tick("\(name) target \(k)=\(target) step \(step)")
                    if rig.machine[Gauges.needleAngles + 3] == target { break }
                }
                tick("\(name) target \(k) settled")
            }
            // The chain: target from the vertical speed, then one step.
            for i in 0..<300 {
                rig.poke16(0x0A50, UInt16(truncatingIfNeeded: rng.next()))
                rig.run(0xCF46, .init(), "\(name) chain target \(i)") { $0.vsiUpdate(); return .init() }
                tick("\(name) chain step \(i)")
            }
            Self.expectClean(rig, "updateVsiNeedle \(name)")
        }
    }

    // MARK: Slip ball ($CF79, $1C3D)

    @Test func slipBall() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            rig.poke(Gauges.instrumentMask0, 0xFF)
            func update(_ label: String) {
                rig.run(0xCF79, .init(), label) { $0.slipBallUpdate(); return .init() }
            }
            rig.poke(0x0A12, 0)
            for slip in Array(0..<256) + Array((0..<256).reversed()) {
                rig.poke(0x09F3, UInt8(slip))
                update("\(name) airborne slip \(slip)")
            }
            rig.poke(0x0A12, 0xFF)
            for speed: UInt8 in [0, 1, 0x40] {
                rig.poke(0x0A4D, speed)
                for rudder in stride(from: 0, to: 256, by: 3) {
                    rig.poke(0x0ABD, UInt8(rudder))
                    update("\(name) ground speed \(speed) rudder \(rudder)")
                }
            }
            rig.poke(Gauges.instrumentMask0, 0xFD)
            update("\(name) disabled")
            // $1C3D directly, every ball position from every other.
            for from: UInt8 in [1, 9, 17] {
                for to: UInt8 in 0...20 {
                    for value in [from, to] {
                        rig.run(0x1C3D, .init(a: value), "\(name) ball \(from)->\(to)") {
                            $0.drawTurnBall(value); return .init()
                        }
                    }
                }
            }
            Self.expectClean(rig, "slipBallUpdate \(name)")
        }
    }

    // MARK: Linear indicators ($1B92-$1C2E)

    /// Each control indicator swept over its range up and down, then random moves. The ranges
    /// are what the callers can pass (the elevator up to 31 reaches rows 200-202, past the row
    /// tables: the original's XOR lands in low memory there, and so must the port's).
    @Test func controlIndicators() throws {
        typealias Indicator = (name: String, address: UInt16, range: ClosedRange<Int>, port: (Machine, UInt8) -> Void)
        let indicators: [Indicator] = [
            ("elevator", 0x1B92, 0...31, { $0.drawElevatorIndicator($1) }),
            ("ailerons", 0x1BAC, 0...31, { $0.drawAileronIndicator($1) }),
            ("rudder", 0x1BCD, 0...31, { $0.drawRudderIndicator($1) }),
            ("throttle", 0x1BE1, 0...31, { $0.drawThrottleIndicator($1) }),
            ("flaps", 0x1BFD, 0...15, { $0.drawFlapsIndicator($1) }),
            ("trim", 0x1C10, 0...15, { $0.drawTrimIndicator($1) }),
            ("mixture", 0x1C23, 0...7, { $0.drawMixtureIndicator($1) }),
        ]
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            let stack = StackWatch()
            var rng = TestRandom(seed: 0x1B92)
            for indicator in indicators {
                let values = Array(indicator.range) + Array(indicator.range.reversed())
                    + (0..<60).map { _ in indicator.range.lowerBound + rng.below(indicator.range.count) }
                for (i, v) in values.enumerated() {
                    let value = UInt8(v)
                    let label = "\(name) \(indicator.name) #\(i) = \(value)"
                    rig.run(indicator.address, .init(a: value), label) {
                        indicator.port($0, value); return .init()
                    }
                    stack.check(rig, label)
                }
            }
            Self.expectClean(rig, "control indicators \(name)")
            stack.expectClean("control indicators \(name)")
        }
    }

    /// Fuel and oil bars (phases 0-3) over and beyond their ranges, and the fuel-selector toggle.
    @Test func engineGauges() throws {
        typealias Gauge = (name: String, address: UInt16, source: Int, shift: Bool, port: (Machine) -> Void)
        let gauges: [Gauge] = [
            ("left fuel", 0x1C5D, 0x09C2, true, { $0.drawLeftFuelGauge() }),
            ("right fuel", 0x1C75, 0x09C5, true, { $0.drawRightFuelGauge() }),
            ("oil temperature", 0x1CA7, 0x09CB, false, { $0.drawOilTempGauge() }),
            ("oil pressure", 0x1CBE, 0x09CD, false, { $0.drawOilPressureGauge() }),
        ]
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            var rng = TestRandom(seed: 0x1C5D)
            for gauge in gauges {
                // Values whose bar x + 4 carries ($0A90 = 2) included: 252-255.
                var values = Array(0...40) + Array((0...40).reversed()) + [0, 60, 120, 0]
                values += gauge.shift ? [126, 127, 0] : [251, 252, 255, 0]
                values += (0..<40).map { _ in rng.below(gauge.shift ? 80 : 40) }
                for (i, v) in values.enumerated() {
                    let raw = gauge.shift ? UInt8(v) << 1 | UInt8(i & 1) : UInt8(v)
                    rig.poke(gauge.source, raw)
                    rig.run(gauge.address, .init(), "\(name) \(gauge.name) #\(i) = \(raw)") {
                        gauge.port($0); return .init()
                    }
                    // Same value again: no redraw.
                    if i % 7 == 0 {
                        rig.run(gauge.address, .init(), "\(name) \(gauge.name) #\(i) again") {
                            gauge.port($0); return .init()
                        }
                    }
                }
            }
            let start = Self.panel(rig.machine)
            for i in 0..<4 {
                rig.run(0x1CF0, .init(), "\(name) fuel selector \(i)") { $0.drawFuelSelectorMarker(); return .init() }
            }
            #expect(Self.panel(rig.machine) == start, "the fuel-selector marker toggles")
            Self.expectClean(rig, "engine gauges \(name)")
        }
    }

    // MARK: Point lists ($1D01, $1BC3)

    /// The plotter on every marker shape at random panel positions, with the x-high carry
    /// accumulating (x near 255), and through the $1BC3 entry. The 10,000-ft shapes hold
    /// absolute coordinates, so they get small origins around the (12, 10) their driver uses.
    @Test func pointLists() throws {
        let ram = try Self.demo()
        let rig = DiffRig(ram)
        var rng = TestRandom(seed: 0x1D01)
        let small: [UInt16] = [0x0F10, 0x0F1D, 0x0F30, 0x0F49, 0x1612, 0x161B, 0x1CE7, 0x3B13]
        // The nine 10,000-ft shapes ($F7EE-$F86E), through the marker's own pointer table.
        let table = Gauges.tenKMarkerPointers
        let absolute = (0..<9).map { UInt16(ram[table + 2 * $0]) | UInt16(ram[table + 2 * $0 + 1]) << 8 }
        #expect(absolute.allSatisfy { (0xF7EE...0xF86E).contains($0) })
        for (k, shape) in (small + absolute).enumerated() {
            let isAbsolute = k >= small.count
            for i in 0..<30 {
                let x = UInt8(isAbsolute ? rng.below(24) : i < 10 ? 250 + rng.below(6) : rng.below(256))
                let y = UInt8(isAbsolute ? rng.below(20) : 112 + rng.below(74))
                let xHigh = UInt8(rng.below(2))
                rig.poke16(Gauges.markerShapePtr, shape)
                rig.poke(Gauges.markerXHigh, xHigh)
                rig.run(0x1D01, .init(x: x, y: y), "shape \(k) at (\(x), \(y)) high \(xHigh)") {
                    $0.plotPointList(x: x, y: y); return .init()
                }
                let lo = UInt8(shape & 0xFF), hi = UInt8(shape >> 8)
                rig.poke(Gauges.markerShapePtr, lo)
                let x2 = UInt8(isAbsolute ? rng.below(24) : rng.below(200))
                let y2 = UInt8(isAbsolute ? rng.below(20) : 112 + rng.below(70))
                rig.run(0x1BC3, .init(a: hi, x: x2, y: y2), "shape \(k) via $1BC3 at (\(x2), \(y2))") {
                    $0.plotMarkerShape(x: x2, y: y2, shapeHigh: hi); return .init()
                }
            }
        }
        Self.expectClean(rig, "plotPointList")
    }

    // MARK: 10,000-ft marker ($F86F)

    @Test func tenKMarker() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            rig.poke(Gauges.instrumentMask0, 0xFF)
            func update(_ label: String) {
                rig.run(0xF86F, .init(), label) { $0.draw10kMarker(); return .init() }
            }
            for state: UInt8 in [0xFF, 0, 8] {
                rig.poke(Gauges.tenKMarkerState, state)
                for high in Array(0..<256) + Array((0..<256).reversed()) {
                    rig.poke(0x60, UInt8(high))
                    update("\(name) start \(state) altitude high \(high)")
                }
            }
            var rng = TestRandom(seed: 0xF86F)
            for i in 0..<200 {
                rig.poke(0x60, rng.byte())
                update("\(name) random \(i)")
            }
            rig.poke(Gauges.instrumentMask0, 0xF7)
            rig.poke(0x60, 40)
            update("\(name) disabled")
            Self.expectClean(rig, "draw10kMarker \(name)")
        }
    }

    // MARK: Instrument masks and failure graphics ($F35E-$F521)

    /// Every bit of every mask failed (cleared in $0942+) and repaired, alone and in groups, and
    /// through the other two factors. `$FF` has only 4 table entries; bit 4 is tested on its own
    /// below, bits 5-7 not at all: their entries are the code after $F346, whose save buffers
    /// would overwrite the running $F35E code and the stack.
    @Test func failureMasks() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            // Every factor fully on, and the masks in sync (so only the bits we change move).
            for k in 0..<3 {
                rig.poke(Instruments.instrumentSettings + k, k == 2 ? 0x0F : 0xFF)
                rig.poke(Instruments.failureMasks + k, 0xFF)
                rig.poke(Instruments.lightingMasks + k, 0xFF)
            }
            func update(_ label: String) {
                rig.run(0xF35E, .init(), label) { $0.updateInstrumentMasks(); return .init() }
            }
            update("\(name) sync")
            let start = Self.panel(rig.machine)
            for k in 0..<3 {
                for bit in 0..<(k == 2 ? 4 : 8) {
                    let mask = UInt8(1 << bit)
                    rig.poke(Instruments.failureMasks + k, 0xFF & ~mask)
                    update("\(name) fail mask \(k) bit \(bit)")
                    update("\(name) fail mask \(k) bit \(bit) (no change)")
                    rig.poke(Instruments.failureMasks + k, 0xFF)
                    update("\(name) repair mask \(k) bit \(bit)")
                }
            }
            #expect(Self.panel(rig.machine) == start, "\(name): fail + repair of every bit restores the panel")
            // Groups, and the settings and lighting factors.
            var rng = TestRandom(seed: 0xF35E)
            for i in 0..<40 {
                for k in 0..<3 {
                    let factor = [Instruments.instrumentSettings, Instruments.failureMasks, Instruments.lightingMasks][rng.below(3)]
                    rig.poke(factor + k, rng.byte() & (k == 2 ? 0x0F : 0xFF))
                }
                update("\(name) group \(i)")
                for k in 0..<3 {
                    rig.poke(Instruments.instrumentSettings + k, k == 2 ? 0x0F : 0xFF)
                    rig.poke(Instruments.failureMasks + k, 0xFF)
                    rig.poke(Instruments.lightingMasks + k, 0xFF)
                }
                update("\(name) group \(i) repaired")
            }
            #expect(Self.panel(rig.machine) == start, "\(name): group failures and repairs restore the panel")
            Self.expectClean(rig, "updateInstrumentMasks \(name)")
        }
    }

    /// `$FF` bit 4: its entry is the first 6 code bytes of $F35E (an 83-row area of the window at
    /// x 173, saved into $0942-$0B15, over the masks' own factors). The original does it if the
    /// settings byte `$09A8` ever gets bit 4; the port must follow.
    ///
    /// One call per direction, each from a fresh image: a restore rotates $0942-$0B15 to $80s, so
    /// the next call would see every mask change, including `$FF` bit 7, whose area wraps past
    /// row 255 into the stack page.
    @Test func failureMaskOutsideTable() throws {
        for (restore, label) in [(true, "bit 4 on (restore from $0942)"), (false, "bit 4 off (save into $0942)")] {
            let rig = DiffRig(try Self.demo())
            rig.poke(Instruments.instrumentMask0 + 2, restore ? 0x0F : 0x1F)
            rig.poke(Instruments.instrumentSettings + 2, 0x1F)
            rig.poke(Instruments.failureMasks + 2, restore ? 0xFF : 0x0F)
            rig.poke(Instruments.lightingMasks + 2, 0xFF)
            rig.run(0xF35E, .init(), label) { $0.updateInstrumentMasks(); return .init() }
            Self.expectClean(rig, "updateInstrumentMasks $FF bit 4")
        }
    }

    /// A failed gauge whose needle still moves (the 5 Hz needle steps do not test the mask) or
    /// whose driver is skipped, then repaired: the saved bits come back over whatever is there.
    @Test func failureWhileGaugesMove() throws {
        let rig = DiffRig(try Self.demo())
        for k in 0..<3 {
            rig.poke(Instruments.instrumentSettings + k, 0xFF)
            rig.poke(Instruments.failureMasks + k, 0xFF)
            rig.poke(Instruments.lightingMasks + k, 0xFF)
        }
        rig.poke(Instruments.instrumentSettings + 2, 0x0F)
        func masks(_ label: String) {
            rig.run(0xF35E, .init(), label) { $0.updateInstrumentMasks(); return .init() }
        }
        masks("sync")
        // VSI (bit 7) and airspeed (bit 0) fail; their 5 Hz needle steps keep drawing.
        rig.poke(Instruments.failureMasks, 0x7E)
        masks("fail VSI + ASI")
        rig.poke(Gauges.vsiNeedle, 10)
        rig.poke(Gauges.asiNeedle, 70)
        for i in 0..<30 {
            rig.run(0x1A6A, .init(), "VSI step \(i)") { $0.updateVsiNeedle(); return .init() }
            rig.run(0x1A32, .init(), "ASI step \(i)") { $0.updateAirspeedNeedle(); return .init() }
        }
        rig.poke(Instruments.failureMasks, 0xFF)
        masks("repair VSI + ASI")
        // Altimeter (bit 3) fails: the driver and the 10,000-ft marker stop; repair.
        rig.poke(Instruments.failureMasks, 0xF7)
        masks("fail altimeter")
        rig.poke16(0x5F, 2500)
        rig.run(0xCE84, .init(), "altimeter while failed") { $0.altimeterUpdate(); return .init() }
        rig.run(0xF86F, .init(), "marker while failed") { $0.draw10kMarker(); return .init() }
        rig.poke(Instruments.failureMasks, 0xFF)
        masks("repair altimeter")
        rig.run(0xCE84, .init(), "altimeter after repair") { $0.altimeterUpdate(); return .init() }
        rig.run(0xF86F, .init(), "marker after repair") { $0.draw10kMarker(); return .init() }
        Self.expectClean(rig, "failure while gauges move")
    }

    /// $F3F0 on synthetic areas: random rectangles of the panel (x across 255/256, widths that
    /// end mid-byte) saved into a free buffer and restored, the buffer crossing pages.
    @Test func instrumentAreas() throws {
        // Entries live in the free page $0390-$03F7; buffers in the dead debug monitor $C000.
        let entry = 0x03A0
        let rig = DiffRig(try Self.demo())
        var rng = TestRandom(seed: 0xF3F0)
        for i in 0..<120 {
            let x = rng.below(300), width = 1 + rng.below(min(64, 320 - x))
            let rows = 1 + rng.below(20), row = 112 + rng.below(88 - rows)
            let buffer = 0xC000 + rng.below(0x700)
            let bytes: [UInt8] = [UInt8(x & 0xFF), UInt8(rows << 1 | x >> 8), UInt8(row), UInt8(width),
                                  UInt8(buffer & 0xFF), UInt8(buffer >> 8)]
            for (j, b) in bytes.enumerated() { rig.poke(entry + j, b) }
            let panelBefore = Self.panel(rig.machine)
            for (step, bits) in [(0, (1, 0)), (1, (0, 1))] {
                rig.poke16(0xBA, UInt16(entry))
                rig.poke(0xB8, UInt8(bits.0))
                rig.poke(0xB9, UInt8(bits.1))
                rig.run(0xF3F0, .init(), "area \(i) (\(x), \(row)) \(width)x\(rows) step \(step)") {
                    $0.toggleInstrumentArea(); return .init()
                }
            }
            #expect(Self.panel(rig.machine) == panelBefore, "area \(i): save then restore")
            // Equal bits: nothing happens.
            rig.poke(0xB8, 1)
            rig.poke(0xB9, 1)
            rig.run(0xF3F0, .init(), "area \(i) unchanged") { $0.toggleInstrumentArea(); return .init() }
        }
        Self.expectClean(rig, "toggleInstrumentArea")
    }

    /// The bit helpers on their own: the address helper for every x and panel row, and push/pop
    /// sequences across the byte counter's wrap and the buffer pointer's page crossing.
    @Test func bitHelpers() throws {
        let rig = DiffRig(try Self.regular())
        var rng = TestRandom(seed: 0xF4C5)
        for row in stride(from: 0, to: 200, by: 7) {
            for x in 0..<256 where x % 3 == 0 || row == 112 {
                let high = UInt8(rng.below(2))
                rig.poke(0xA5, high)
                rig.run(0xF4C5, .init(x: UInt8(x), y: UInt8(row)), "address x \(x) row \(row) high \(high)") {
                    let mask = $0.bitmapBitAddress(x: UInt8(x), row: UInt8(row))
                    return .init(a: mask, x: mask, y: 0)
                }
            }
        }
        for start: UInt16 in [0xC000, 0xC0FE, 0xC0FF] {
            for counter: UInt8 in [0, 7, 8, 9, 12] {
                rig.poke16(Instruments.bufferPointer, start)
                rig.poke(Instruments.Scratch.savedBitCounter, counter)
                for i in 0..<20 {
                    let bit = rng.byte()
                    rig.run(0xF4E0, .init(a: bit), "push \(i) from $\(hex16(Int(start))) counter \(counter)") {
                        $0.pushSavedBit(bit); return .init()
                    }
                }
                rig.poke16(Instruments.bufferPointer, start)
                rig.poke(Instruments.Scratch.savedBitCounter, counter)
                for i in 0..<20 {
                    rig.run(0xF502, .init(), "pop \(i) from $\(hex16(Int(start))) counter \(counter)") {
                        let a = $0.popSavedBit(); return .init(a: a)
                    }
                }
            }
        }
        Self.expectClean(rig, "bit helpers")
    }

    /// $F3B3 directly on each table with random old/new masks.
    @Test func maskChangeTables() throws {
        let rig = DiffRig(try Self.demo())
        var rng = TestRandom(seed: 0xF3B3)
        for (k, table) in Instruments.areaTables.enumerated() {
            let usable: UInt8 = k == 2 ? 0x1F : 0xFF
            var state = usable
            for i in 0..<12 {
                let next = rng.byte() & usable
                rig.poke(0x9E, next)
                rig.poke(0xA0, state)
                rig.run(0xF3B3, .init(a: UInt8(table & 0xFF), x: UInt8(table >> 8)), "table \(k) change \(i)") {
                    $0.applyMaskChanges(table: table); return .init()
                }
                state = next
            }
        }
        Self.expectClean(rig, "applyMaskChanges")
    }

    // MARK: Interleaving

    /// The panel work of the main loop in the original's order, pass after pass, while the
    /// flight drifts and instruments fail and come back at random. Every pass runs $CE84, $CF0E
    /// and $F35E, then the phase task ($22 & 3: left fuel / right fuel + 10,000-ft marker / oil
    /// temperature / oil pressure) and the VSI target (odd passes) or the slip ball (even); the
    /// 5 Hz needle steps ($1A32, $1A6A) come every other pass, and the controls move now and then.
    /// So saves and restores of the failure areas meet every gauge's XOR state at arbitrary
    /// points, including needles moving inside a failed area and the 10,000-ft marker changing
    /// while the altimeter is out.
    @Test func mainLoopPasses() throws {
        for (name, ram) in try Self.snapshots() {
            let rig = DiffRig(ram)
            var rng = TestRandom(seed: 0x204B)
            for k in 0..<3 {
                rig.poke(Instruments.instrumentSettings + k, k == 2 ? 0x0F : 0xFF)
                rig.poke(Instruments.failureMasks + k, 0xFF)
                rig.poke(Instruments.lightingMasks + k, 0xFF)
            }
            let stack = StackWatch()
            func call(_ address: UInt16, _ label: String, a: UInt8 = 0, _ port: (Machine) -> Void) {
                rig.run(address, .init(a: a), "\(name) \(label)") { port($0); return .init() }
                stack.check(rig, "\(name) \(label)")
            }
            var altitude = 200, airspeed = 0x1800, verticalSpeed = 0, slip = 0
            var fuel = (left: 0x50, right: 0x48), oil = (temperature: 20, pressure: 30)
            for pass in 0..<240 {
                // Drift: a climb to about 4,000 m and back, with noise.
                altitude += (pass < 120 ? 30 : -30) + rng.below(41) - 20
                airspeed = max(0, min(0x7FFF, airspeed + rng.below(0x301) - 0x180))
                verticalSpeed = max(-0x0C00, min(0x0C00, verticalSpeed + rng.below(0x201) - 0x100))
                slip = max(-128, min(127, slip + rng.below(31) - 15))
                if pass % 9 == 0 { fuel.left = max(0, fuel.left - 1); fuel.right = max(0, fuel.right - 1) }
                oil.temperature = max(0, min(39, oil.temperature + rng.below(3) - 1))
                oil.pressure = max(0, min(39, oil.pressure + rng.below(3) - 1))
                rig.poke16(0x5F, UInt16(truncatingIfNeeded: altitude))
                rig.poke16(0x0A4C, UInt16(airspeed))
                rig.poke16(0x0A50, UInt16(truncatingIfNeeded: verticalSpeed))
                rig.poke(0x09F3, UInt8(truncatingIfNeeded: slip))
                rig.poke(0x0A12, altitude < 10 ? 0xFF : 0)
                rig.poke(0x09C2, UInt8(fuel.left))
                rig.poke(0x09C5, UInt8(fuel.right))
                rig.poke(0x09CB, UInt8(oil.temperature))
                rig.poke(0x09CD, UInt8(oil.pressure))
                // A failure or a repair now and then: one bit of one factor.
                if rng.below(30) == 0 {
                    let k = rng.below(3)
                    let bit = UInt8(1 << rng.below(k == 2 ? 4 : 8))
                    let factor = rng.coin() ? Instruments.failureMasks : Instruments.lightingMasks
                    rig.poke(factor + k, rig.machine[factor + k] ^ bit)
                }
                call(0xCE84, "pass \(pass) altimeter") { $0.altimeterUpdate() }
                call(0xCF0E, "pass \(pass) airspeed") { $0.airspeedUpdate() }
                call(0xF35E, "pass \(pass) masks") { $0.updateInstrumentMasks() }
                switch pass & 3 {
                case 0: call(0x1C5D, "pass \(pass) left fuel") { $0.drawLeftFuelGauge() }
                case 1:
                    call(0x1C75, "pass \(pass) right fuel") { $0.drawRightFuelGauge() }
                    call(0xF86F, "pass \(pass) 10,000-ft marker") { $0.draw10kMarker() }
                case 2: call(0x1CA7, "pass \(pass) oil temperature") { $0.drawOilTempGauge() }
                default: call(0x1CBE, "pass \(pass) oil pressure") { $0.drawOilPressureGauge() }
                }
                if pass & 1 == 0 {
                    call(0xCF79, "pass \(pass) slip ball") { $0.slipBallUpdate() }
                    call(0x1A32, "pass \(pass) airspeed needle") { $0.updateAirspeedNeedle() }
                    call(0x1A6A, "pass \(pass) VSI needle") { $0.updateVsiNeedle() }
                } else {
                    call(0xCF46, "pass \(pass) VSI target") { $0.vsiUpdate() }
                }
                if rng.below(4) == 0 {
                    let v = UInt8(rng.below(32))
                    switch rng.below(4) {
                    case 0: call(0x1B92, "pass \(pass) elevator \(v)", a: v) { $0.drawElevatorIndicator(v) }
                    case 1: call(0x1BAC, "pass \(pass) ailerons \(v)", a: v) { $0.drawAileronIndicator(v) }
                    case 2: call(0x1BCD, "pass \(pass) rudder \(v)", a: v) { $0.drawRudderIndicator(v) }
                    default: call(0x1BE1, "pass \(pass) throttle \(v)", a: v) { $0.drawThrottleIndicator(v) }
                    }
                }
            }
            Self.expectClean(rig, "main-loop passes \(name)")
            stack.expectClean("main-loop passes \(name)")
        }
    }
}
