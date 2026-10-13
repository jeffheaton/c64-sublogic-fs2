import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Compares `clipPolygon` ($8FE8) on one polygon, including the overflow regime: the original
/// runs first on a copy (`R3D.ending`) and the outcome decides the comparison.
/// - It returns: the rig runs both sides and compares memory, registers and cycles at the end.
/// - It runs the split row's code (a long span entered past the row filler's end, from garbage
///   crossings), code that a span overwrote during the call (through a row pointer scrambled
///   by the degenerate sort) or anything else outside the call tree: the original then executes
///   code it was never meant to, which the port does not follow (render3d.md). Everything before that is compared: the state at the
///   last scan-row start the original reached (or the scan start) against the port's at the
///   same cycle, through the machine's event schedule (`nextEventCycle`), which fires inside the
///   `charge` that reaches that cycle. The port's cycles are exact, so this is the end of the
///   previous row (or of the edge setup) on both sides.
/// - It loops or halts on an undocumented opcode: skipped.
enum PolygonCheck {
    struct Stats {
        var compared = 0, loops = 0
        /// Cases compared only up to the original running the split row's code, overwritten
        /// code, or other code outside the call tree.
        var overruns = 0, overwritten = 0, wild = 0
        /// Overflow-regime events seen in the original runs (cases).
        var passOver64 = 0, passOver128 = 0, edgesOver64 = 0, crossingsPastLastEdge = 0
        var spansPastFiller = 0
        /// Cases where pass k (0-3) left no vertices, polygons that reached the scan fill, and
        /// those that came out of the clipper with 129+ vertices (`projectAndFillPolygon` returns).
        var emptyAfterPass = [0, 0, 0, 0], filled = 0, tooManyToFill = 0
        /// Mismatches before such code runs (the rig records the others).
        var overrunFailures: [String] = []
    }

    /// $90DE, $91D9, $92D4, $93CF: the four pass ends (Y = vertices written).
    static let passEnds = [0x90DE, 0x91D9, 0x92D4, 0x93CF]
    /// $985E: the edge setup's end (X = edges); $9861: the scan start; $986E: a scan row;
    /// $98C2: a row's edges done ($98AD = crossings + 2); $996A: the long span's call into the
    /// filler.
    static let observed = passEnds + [0x96D4, 0x985E, 0x9861, 0x986E, 0x98C2, 0x996A]

    /// Runs `entry` (`clipPolygon` by default; `projectAndFillPolygon` at $96D4 with Y = the
    /// count) on both sides of `rig`; `port` is the port's routine.
    @discardableResult
    static func run(_ rig: DiffRig, _ label: @autoclosure () -> String, stats: inout Stats,
                    entry: UInt16 = 0x8FE8, _ regs: RoutineHarness.Registers = .init(),
                    port: (Machine) -> Void = { $0.clipPolygon() },
                    maxCycles: UInt64 = 4_000_000) -> R3D.Ending {
        let ram = rig.harness.bus.ram
        var sync: (ram: [UInt8], cycles: UInt64)? = nil
        var rows = 0
        var pass = [false, false], edges = false, crossings = false, pastFiller = false
        var empty = -1, filled = false, tooMany = false
        let ending = R3D.ending(ram, entry, regs, maxCycles: maxCycles, observing: observed, observer: { h, pc, cycles in
            let b = h.bus.ram
            switch pc {
            case 0x90DE, 0x91D9, 0x92D4, 0x93CF:
                let y = Int(h.cpu.y)
                if y > 64 { pass[0] = true }
                if y > 128 { pass[1] = true }
                if y == 0 && empty < 0 { empty = passEnds.firstIndex(of: pc)! }
            case 0x96D4:
                if h.cpu.y > 128 { tooMany = true }
            case 0x985E:
                if h.cpu.x > 64 { edges = true }
            case 0x9861:
                filled = true
                sync = (b, cycles)
            case 0x986E:
                rows += 1
                if rows >= 2 { sync = (b, cycles) }   // row 1's setup cycles are charged with the row
            case 0x98C2:
                if b[0x98AD] &- 2 >= 27 { crossings = true }   // slot $1C and beyond written
            case 0x996A:
                // The return planted past the filler's end while the call enters inside it: the
                // filler returns at $85BF and the "restore" writes $91 into the split row's code.
                let target = Int(b[0x996B]) | Int(b[0x996C]) << 8
                if 0x851D + Int(b[0xF5]) > 0x85BB && target <= 0x85BD { pastFiller = true }
            default:
                break
            }
        }, restart: {
            sync = nil; rows = 0
            pass = [false, false]; edges = false; crossings = false; pastFiller = false
            empty = -1; filled = false; tooMany = false
        })
        if pass[0] { stats.passOver64 += 1 }
        if pass[1] { stats.passOver128 += 1 }
        if edges { stats.edgesOver64 += 1 }
        if crossings { stats.crossingsPastLastEdge += 1 }
        if pastFiller { stats.spansPastFiller += 1 }
        if empty >= 0 { stats.emptyAfterPass[empty] += 1 }
        if filled { stats.filled += 1 }
        if tooMany { stats.tooManyToFill += 1 }
        switch ending {
        case .loops:
            stats.loops += 1
        case .returns:
            stats.compared += 1
            rig.run(entry, regs, label()) { m in port(m); return .init() }
        case .runsSplitRowCode, .runsOverwrittenCode, .runsOtherCode:
            switch ending {
            case .runsSplitRowCode: stats.overruns += 1
            case .runsOverwrittenCode: stats.overwritten += 1
            default: stats.wild += 1
            }
            guard let sync else {
                stats.overrunFailures.append("\(label()): \(ending) before the scan fill")
                return ending
            }
            let machine = Machine(memory: ram)
            var seen: (ram: [UInt8], cycles: UInt64)? = nil
            machine.nextEventCycle = machine.clock.cycles + sync.cycles
            let start = machine.clock.cycles
            machine.eventHandler = { m in
                seen = (m.memoryImage, m.clock.cycles - start)
                m.nextEventCycle = .max
            }
            port(machine)
            if let seen {
                let d = Original.differences(seen.ram, sync.ram)
                if seen.cycles != sync.cycles || !d.isEmpty {
                    let first = d.first.map { String(format: " $%04X = %@ want %@", $0, hex(seen.ram[$0]), hex(sync.ram[$0])) } ?? ""
                    stats.overrunFailures.append("\(label()): before \(ending), cycles \(seen.cycles) want \(sync.cycles),"
                                                 + " \(d.count) bytes differ\(first)")
                }
            } else {
                stats.overrunFailures.append("\(label()): the port ended after \(machine.clock.cycles - start) cycles,"
                                             + " before the original's \(sync.cycles)")
            }
        }
        return ending
    }
}

/// The polygon clipper and fill with overflowing polygons: 50-64 vertices in every combination of
/// the four frustum planes (straddled, inside, wholly outside, behind the eye) as rings, stars
/// (every other vertex pulled in, crossing the planes many times), zigzags (nearly every edge
/// clipped) and scattered points, plus inputs of 65-168 vertices in the overlapping arrays, over
/// several snapshots of the running game (so the overflowing indices read different surrounding
/// memory), with the stale clipper copies randomized in half the cases and `$F9` in an eighth.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct Render3DOverflowTests {
    /// Regular flight and demo flight (`Original.regularFlight()`, `Original.demoFlight()`) plus two
    /// later demo states.
    static func surroundings() throws -> [(String, [UInt8])] {
        [("regular", try R3D.regular()), ("demo", R3D.sanitized(try Original.demoFlight())),
         ("demo5400", try R3D.demo(5400)), ("demo7200", try R3D.demo(7200))]
    }

    /// Center and radius of the outline along one screen axis (x/z or y/z), in units of z:
    /// 0 inside both planes, 1 across +1 only, 2 across −1 only, 3 across both, 4 wholly beyond +1,
    /// 5 wholly beyond −1.
    static func axis(_ rng: inout TestRandom, _ mode: Int) -> (center: Double, radius: Double) {
        func r(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * Double(rng.r3dBelow(1001)) / 1000 }
        switch mode {
        case 0: return (r(-0.4, 0.4), r(0.05, 0.55))
        case 1: let c = r(0.5, 1.5); return (c, abs(1 - c) + r(0.1, 0.45))
        case 2: let c = r(-1.5, -0.5); return (c, abs(1 + c) + r(0.1, 0.45))
        case 3: return (r(-0.3, 0.3), r(1.4, 3))
        case 4: return (r(1.6, 3), r(0.05, 0.5))
        default: return (r(-3, -1.6), r(0.05, 0.5))
        }
    }

    /// `n` vertices whose screen outline is an ellipse (or a star with `inner` < 1) along the two
    /// axes, at depths varying around a random z.
    static func outline(_ rng: inout TestRandom, n: Int, u: (center: Double, radius: Double),
                        v: (center: Double, radius: Double), inner: Double) -> [(UInt16, UInt16, UInt16)] {
        let z0 = Double(1 + rng.r3dBelow([0x100, 0x800, 0x1200][rng.r3dBelow(3)]))
        let tilt = Double(rng.r3dBelow(1201)) / 1000 - 0.6
        let phase = Double(rng.r3dBelow(628)) / 100, phase2 = Double(rng.r3dBelow(628)) / 100
        return (0..<n).map { k in
            let t = phase + 2 * Double.pi * Double(k) / Double(n)
            let f = k % 2 == 0 ? 1 : inner
            let z = z0 * (1 + tilt * sin(t + phase2))
            let x = (u.center + u.radius * f * cos(t)) * z, y = (v.center + v.radius * f * sin(t)) * z
            func word(_ d: Double) -> UInt16 { UInt16(bitPattern: Int16(max(-32768, min(32767, d.rounded())))) }
            return (word(x), word(y), word(z))
        }
    }

    /// `n` vertices zigzagging across the planes of each axis (mode 1: +1, 2: −1, 3: both):
    /// x/z alternates every vertex, y/z every other vertex, so nearly every edge is clipped and
    /// the passes grow the polygon by half again each.
    static func zigzag(_ rng: inout TestRandom, n: Int, u: Int, v: Int) -> [(UInt16, UInt16, UInt16)] {
        let z0 = Double(0x40 + rng.r3dBelow(0x1000))
        func swing(_ mode: Int, _ up: Bool) -> Double {
            let a = 0.2 + Double(rng.r3dBelow(60)) / 100
            switch mode {
            case 1: return up ? 1 + a : 1 - a
            case 2: return up ? -1 + a : -1 - a
            default: return up ? 1 + a : -1 - a
            }
        }
        return (0..<n).map { k in
            let z = z0 * (1 + Double(rng.r3dBelow(200)) / 1000)
            let x = swing(u, k % 2 == 0) * z, y = swing(v, k / 2 % 2 == 0) * z
            return (UInt16(bitPattern: Int16(x.rounded())), UInt16(bitPattern: Int16(y.rounded())), UInt16(z.rounded()))
        }
    }

    /// `n` (65-128) vertices alternately inside and outside x = z, built byte by byte in the
    /// overlapping arrays: vertex i + 64's x, y and z are (x hi, y lo), (y hi, z lo) and
    /// (z hi, $0C90 + i) of vertex i, so each byte is chosen for both. Inside: x and y small, z
    /// large; outside: x large, z small. The first pass then writes about 1.5·n vertices (130+
    /// from about n = 87 on, so the second pass handles only its last vertex).
    static func alternating(_ rng: inout TestRandom, n: Int) -> (pokes: [(Int, UInt8)], count: Int) {
        func pick(_ lo: Int, _ hi: Int) -> UInt8 { UInt8(lo + rng.r3dBelow(hi - lo + 1)) }
        var pokes: [(Int, UInt8)] = []
        for i in 0..<min(n, 64) {
            let inside = i % 2 == 0
            let xhi = inside ? pick(0, 0x10) : pick(0x40, 0x70)       // vertex i x hi = partner x lo
            let ylo = inside ? pick(0, 0x10) : pick(0x60, 0x70)       // partner x hi
            let yhi = pick(0, 0x10)                                   // partner y lo
            let zlo = pick(0, 0x10)                                   // partner y hi
            let zhi = inside ? pick(0x30, 0x70) : pick(1, 0x20)       // partner z lo
            let free = inside ? pick(0x30, 0x70) : pick(1, 0x10)      // partner z hi ($0C90 + i)
            for (k, v) in [rng.byte(), xhi, ylo, yhi, zlo, zhi].enumerated() { pokes.append((0x0B10 + 0x40 * k + i, v)) }
            if i + 64 < n { pokes.append((0x0C90 + i, free)) }
        }
        return (pokes, n)
    }

    @Test func largePolygons() throws {
        var rng = TestRandom(seed: 0x0E10)
        var stats = PolygonCheck.Stats()
        var combination = 0
        for (name, base) in try Self.surroundings() {
            for bufferA in [false, true] {
                let start = bufferA ? R3D.flipped(base) : base
                let rig = R3D.rig(start)
                for i in 0..<75 {
                    R3D.load(rig, start)
                    var vertices: [(UInt16, UInt16, UInt16)]
                    var raw: (pokes: [(Int, UInt8)], count: Int)? = nil
                    let kind: String
                    switch i % 8 {
                    case 0:
                        kind = "scatter"
                        vertices = (0..<(50 + rng.r3dBelow(15))).map { _ in Render3DClipTests.anyPoint(&rng) }
                    case 1 where i % 16 == 9 && i % 64 != 9:
                        kind = "alternating"
                        vertices = []
                        raw = Self.alternating(&rng, n: 70 + rng.r3dBelow(59))
                    case 1:
                        // More than 64 input vertices: the input arrays themselves overlap (each
                        // later array write lands on an earlier array's vertices). From 129 on
                        // the first pass handles only the last vertex (its index turns negative).
                        kind = "oversized"
                        let n = i % 64 == 9 ? 129 + rng.r3dBelow(40) : 65 + rng.r3dBelow(36)
                        vertices = (0..<n).map { _ in Render3DClipTests.anyPoint(&rng) }
                    case 3:
                        let (mu, mv) = i % 16 == 3 ? (3, 3) : (1 + rng.r3dBelow(3), 1 + rng.r3dBelow(3))
                        kind = "zigzag \(mu)/\(mv)"
                        vertices = Self.zigzag(&rng, n: 56 + rng.r3dBelow(9), u: mu, v: mv)
                    case 7:
                        kind = "inside"
                        vertices = Self.outline(&rng, n: 50 + rng.r3dBelow(15), u: Self.axis(&rng, 0),
                                                v: Self.axis(&rng, 0), inner: i % 16 == 7 ? 1 : 0.3)
                    default:
                        // Every combination of the two axes' modes in turn (36), as rings and stars.
                        let (mu, mv) = (combination % 6, combination / 6 % 6)
                        combination += 1
                        let star = i % 8 >= 4
                        kind = "\(star ? "star" : "ring") \(mu)/\(mv)"
                        let inner = star ? 0.15 + Double(rng.r3dBelow(70)) / 100 : 1
                        vertices = Self.outline(&rng, n: 50 + rng.r3dBelow(15), u: Self.axis(&rng, mu),
                                                v: Self.axis(&rng, mv), inner: inner)
                        if i % 23 == 5 { vertices = vertices.map { ($0.0, $0.1, 0 &- $0.2) } }   // behind the eye
                    }
                    if rng.r3dBelow(2) == 0 {
                        // Stale clipper copies: whatever earlier polygons left.
                        for a in 0x0C90...0x0E0F { rig.poke(a, rng.byte()) }
                    }
                    if let raw {
                        for (a, v) in raw.pokes { rig.poke(a, v) }
                        rig.poke(0xB7, UInt8(raw.count - 1))
                    } else {
                        Render3DClipTests.setPolygon(rig, vertices)
                    }
                    rig.poke(0x0876, rng.byte())
                    if rng.r3dBelow(8) == 0 { rig.poke(0xF9, rng.byte()) }
                    PolygonCheck.run(rig, "\(name) A=\(bufferA) #\(i) \(kind) n=\(raw?.count ?? vertices.count)",
                                     stats: &stats)
                }
                rig.expectCleanR3D("large polygons \(name) bufferA=\(bufferA)")
            }
        }
        let report = "compared \(stats.compared), up to the split row's code \(stats.overruns), up to overwritten "
            + "code \(stats.overwritten), up to other code \(stats.wild), loops \(stats.loops); passes > 64: "
            + "\(stats.passOver64), > 128: \(stats.passOver128); edges > 64: \(stats.edgesOver64); "
            + "crossings past $1C: \(stats.crossingsPastLastEdge); spans past the filler: \(stats.spansPastFiller); "
            + "empty after pass: \(stats.emptyAfterPass); filled: \(stats.filled); 129+ to fill: \(stats.tooManyToFill)"
        let failures = stats.overrunFailures.prefix(12).joined(separator: "\n")
        #expect(stats.overrunFailures.isEmpty, "\(report)\n\(failures)")
        // The set must reach the overflow regime, every early return, and mostly be comparable.
        let total = stats.compared + stats.overruns + stats.overwritten + stats.wild + stats.loops
        #expect(stats.compared > total * 3 / 4, "\(report)")
        #expect(stats.passOver64 > 100 && stats.passOver128 > 10 && stats.edgesOver64 > 40, "\(report)")
        #expect(stats.crossingsPastLastEdge > 10 && stats.spansPastFiller > 10, "\(report)")
        #expect(stats.emptyAfterPass.allSatisfy { $0 > 5 } && stats.filled > 300, "\(report)")
        #expect(stats.overruns > 0, "\(report)")
    }

    /// `count` vertices (up to 192) built byte by byte in the overlapping arrays: slot i's bytes
    /// B0-B7 at $0B10 + i + 64k are vertex i's (x, y, z) = (B0:B1, B2:B3, B4:B5), vertex i + 64's
    /// (B1:B2, B3:B4, B5:B6) and vertex i + 128's (B2:B3, B4:B5, B6:B7). The high bytes of
    /// vertices 0-127 (B1, B3, B5 and B2, B4, B6) and vertex i + 128's z (B7) are chosen; the
    /// low bytes are whatever the other vertices' high bytes are (B0 is random), less than one
    /// step of a high byte.
    /// - Scattered: x and y high bytes small ($00-$0F, $F0-$FF) or, `outside` percent of the
    ///   time, beyond the planes ($20-$3F, $C0-$DF); z high bytes $10-$1F.
    /// - `ellipse` (center and radius in units of z, the same on both axes): vertex k of `count`
    ///   on the ellipse in order, at one depth (z high byte $20-$37), so the outline is convex
    ///   but for the low bytes' jitter.
    /// (Vertex i + 128's high bytes are vertex i's y high and z high bytes: near y = z.)
    static func overlapping(_ rng: inout TestRandom, count: Int, outside: Int,
                            ellipse: (center: Double, radius: Double)? = nil) -> [(Int, UInt8)] {
        func coordinate() -> UInt8 {
            let far = rng.r3dBelow(100) < outside, negative = rng.r3dBelow(2) == 0
            let magnitude = rng.r3dBelow(far ? 0x20 : 0x10)
            return UInt8(far ? (negative ? 0xC0 : 0x20) + magnitude : (negative ? 0xF0 : 0) + magnitude)
        }
        func depth() -> UInt8 { UInt8(0x10 + rng.r3dBelow(0x10)) }
        var high: [(x: UInt8, y: UInt8, z: UInt8)] = (0..<192).map { _ in (coordinate(), coordinate(), depth()) }
        if let ellipse {
            let z = Double(0x20 + rng.r3dBelow(0x18))
            let phase = Double(rng.r3dBelow(628)) / 100
            let cx = ellipse.center * Double(rng.r3dBelow(201) - 100) / 100
            let cy = ellipse.center * Double(rng.r3dBelow(201) - 100) / 100
            for k in 0..<min(count, 128) {
                let t = phase + 2 * Double.pi * Double(k) / Double(count)
                func byte(_ d: Double) -> UInt8 { UInt8(bitPattern: Int8(max(-128, min(127, (d * z).rounded())))) }
                high[k] = (byte(cx + ellipse.radius * cos(t)), byte(cy + ellipse.radius * sin(t)), UInt8(z))
            }
        }
        var pokes: [(Int, UInt8)] = []
        for i in 0..<min(count, 64) {
            var bytes = [rng.byte(), high[i].x, high[i + 64].x, high[i].y, high[i + 64].y, high[i].z]
            if i + 64 < count { bytes.append(high[i + 64].z) }
            if i + 128 < count { bytes.append(high[i + 128].z) }
            for (k, v) in bytes.enumerated() { pokes.append((0x0B10 + 0x40 * k + i, v)) }
        }
        return pokes
    }

    /// The counts where the overlapping arrays meet, on byte-built vertices (`overlapping`):
    /// - `clipPolygon` with 63-66 and 127-131 vertices: the closing copies of 64 and 128 land on
    ///   index 0 of a later array before that array is copied, 129 still walks every vertex (the
    ///   index starts at $80 and turns positive), 130+ handle only the last one;
    /// - `projectAndFillPolygon` ($96D4) straight with Y = 60-65 and 126-130: with 126 and 127 the
    ///   closing x[n + 1] / x[n] land on $0D4F (the closing y[n − 1], the y[−1] of the edge setup)
    ///   and with 127 x[128] on y[0]; with 128, x[127] becomes y[127] and x[128], x[129] are y[0]
    ///   and y[1], overwritten before the closing y[128], y[129] copy them; 129+ return at once.
    ///   Every fill count must be compared in full at least once (the convex outlines).
    @Test func boundaryCounts() throws {
        var rng = TestRandom(seed: 0x0D4F)
        var stats = PolygonCheck.Stats()
        var filledAt = Set<Int>()
        let clipCounts = [63, 64, 65, 66, 127, 128, 129, 130, 131]
        let fillCounts = [60, 63, 64, 65, 126, 127, 128, 129, 130]
        for (name, base) in try Self.surroundings().prefix(2) {
            for bufferA in [false, true] {
                let start = bufferA ? R3D.flipped(base) : base
                let rig = R3D.rig(start)
                for variant in 0..<3 {
                    for (fill, count) in clipCounts.map({ (false, $0) }) + fillCounts.map({ (true, $0) }) {
                        R3D.load(rig, start)
                        if rng.r3dBelow(2) == 0 {
                            for a in 0x0C90...0x0E0F { rig.poke(a, rng.byte()) }
                        }
                        // Fills: two convex outlines inside the window, then scattered points; clips: an
                        // outline straddling the planes, then scattered points partly beyond them.
                        let outside = fill ? 5 : [0, 30, 60][variant]
                        let ellipse: (center: Double, radius: Double)? = fill
                            ? (variant < 2 ? (0.3, 0.2 + Double(rng.r3dBelow(40)) / 100) : nil)
                            : (variant == 0 ? (1, 0.6 + Double(rng.r3dBelow(80)) / 100) : nil)
                        for (a, v) in Self.overlapping(&rng, count: count, outside: outside, ellipse: ellipse) {
                            rig.poke(a, v)
                        }
                        rig.poke(0x0876, rng.byte())
                        let label = "\(name) A=\(bufferA) \(fill ? "fill" : "clip") n=\(count) #\(variant)"
                        if fill {
                            let y = UInt8(count)
                            let ending = PolygonCheck.run(rig, label, stats: &stats, entry: 0x96D4, .init(y: y),
                                                          port: { $0.projectAndFillPolygon(y) })
                            if ending == .returns { filledAt.insert(count) }
                        } else {
                            rig.poke(0xB7, UInt8(count - 1))
                            PolygonCheck.run(rig, label, stats: &stats)
                        }
                    }
                }
                rig.expectCleanR3D("boundary counts \(name) bufferA=\(bufferA)")
            }
        }
        let report = "compared \(stats.compared), up to the split row's code \(stats.overruns), up to overwritten "
            + "code \(stats.overwritten), up to other code \(stats.wild), loops \(stats.loops); passes > 64: "
            + "\(stats.passOver64), > 128: \(stats.passOver128); edges > 64: \(stats.edgesOver64); "
            + "filled: \(stats.filled); 129+ to fill: \(stats.tooManyToFill); fills compared at \(filledAt.sorted())"
        #expect(stats.overrunFailures.isEmpty, "\(report)\n\(stats.overrunFailures.prefix(12).joined(separator: "\n"))")
        #expect(stats.loops < 5, "\(report)")
        #expect(Set(fillCounts).isSubset(of: filledAt), "\(report)")
        #expect(stats.passOver128 > 10 && stats.tooManyToFill > 10 && stats.edgesOver64 > 10, "\(report)")
    }

    /// The spans the overflowing fill can produce from garbage crossings, straight through `span`
    /// ($9996): any right end x (0-255) with any left end, including right ends past the window
    /// and left ends wrapped below 0 (length − 1 > x). A long span (length − 1 >= $18) enters the
    /// row filler at the column of its left end rounded up to a byte, `(left + 3) & $FC` (8-bit):
    /// - up to 160 the call enters the filler, which returns at the planted return or at its own
    ///   final one ($85BF; for x = 160-163 the return was planted on that one, and the "restore"
    ///   then turns it into $91; from x = 164 it was planted past the filler's end, and the
    ///   "restore" writes $91 into the split row's code), all of which the port follows;
    /// - from 164 on the call enters the split row's code, which the original runs from the
    ///   middle: excluded, and checked to be detected as such.
    @Test func spansAnywhere() throws {
        var rng = TestRandom(seed: 0x9910)
        var detected = 0, compared = 0, pastFiller = 0
        for (name, base) in try R3D.states().prefix(2) {
            for bufferA in [false, true] {
                let start = bufferA ? R3D.flipped(base) : base
                let rig = R3D.rig(start)
                for x in 0...0xFF {
                    for k in 0..<5 {
                        R3D.load(rig, start)
                        let row = rng.r3dBelow(0x70)
                        rig.poke(0x8E, rig.machine.mem[Machine.rowAddressLo + row])
                        rig.poke(0x8F, rig.machine.mem[Machine.rowAddressHi + row])
                        rig.poke(0x1E, UInt8(x))
                        rig.poke(0x0876, rng.byte())
                        rig.run(0x9C93, .init(), "\(name) span color") { m in m.setSpanColorFromPalette(); return .init() }
                        let left = k < 4 ? rng.r3dBelow(0xA1) : 0xA1 + rng.r3dBelow(0x5F)
                        let a = UInt8((x - left) & 0xFF)
                        if a >= 0x18 && (left + 3) & 0xFC >= 0xA4 {
                            let ending = R3D.ending(rig.harness.bus.ram, 0x9996, .init(a: a))
                            #expect(ending == .runsSplitRowCode, "\(name) x=\(x) left=\(left): \(ending)")
                            detected += 1
                            continue
                        }
                        if a >= 0x18 && x >= 0xA0 { pastFiller += 1 }
                        compared += 1
                        rig.run(0x9996, .init(a: a), "\(name) A=\(bufferA) span x=\(x) left=\(left)") { m in
                            m.span(a); return .init()
                        }
                    }
                }
                rig.expectCleanR3D("spans anywhere \(name) bufferA=\(bufferA)")
            }
        }
        #expect(compared > 4000 && detected > 300 && pastFiller > 1000,
                "compared \(compared), detected \(detected), past the filler \(pastFiller)")
    }
}
