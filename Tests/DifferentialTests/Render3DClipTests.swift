import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Differential tests of the line clipping ($9464-$96D3) and the polygons ($8FE8-$990F): random
/// segments (partly outside, behind the eye, on the frustum planes, overflow-halving cases), the
/// four planes alone, random convex and concave polygons partly or fully clipped, and the scan
/// fill of in-frustum polygons, on both window buffers.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct Render3DClipTests {
    static func setPoint(_ rig: DiffRig, _ base: Int, _ p: (UInt16, UInt16, UInt16)) {
        rig.poke16(base, p.0); rig.poke16(base + 2, p.1); rig.poke16(base + 4, p.2)
    }

    /// A point in front of the eye (z > 0), inside or outside the frustum, sometimes huge.
    static func frontPoint(_ rng: inout TestRandom, scale: Int) -> (UInt16, UInt16, UInt16) {
        let z = 1 + rng.r3dBelow(scale)
        let x = rng.r3dBelow(4 * z + 1) - 2 * z, y = rng.r3dBelow(4 * z + 1) - 2 * z
        return (UInt16(truncatingIfNeeded: x), UInt16(truncatingIfNeeded: y), UInt16(truncatingIfNeeded: z))
    }

    static func anyPoint(_ rng: inout TestRandom) -> (UInt16, UInt16, UInt16) {
        switch rng.r3dBelow(5) {
        case 0: return Render3DProjectionTests.point(&rng)
        case 1:
            // Behind the eye.
            let p = frontPoint(&rng, scale: 0x2000)
            return (p.0, p.1, 0 &- p.2)
        case 2: return frontPoint(&rng, scale: 0x7FFF)   // overflowing plane denominators
        default: return frontPoint(&rng, scale: 0x1000)
        }
    }

    /// Outcodes for both points, then `clipLine` and `clipLineEnd` (as the line driver $8B40 calls
    /// them: A clipped when its outcode is set, then B).
    @Test func clipLines() throws {
        var rng = TestRandom(seed: 0x9464)
        for (name, base) in try R3D.states() {
            let rig = R3D.rig(base)
            for i in 0..<700 {
                Self.setPoint(rig, 0xCD, Self.anyPoint(&rng))
                Self.setPoint(rig, 0xD6, Self.anyPoint(&rng))
                rig.run(0x93D2, .init(), "outcode A") { m in m.computeOutcodeA(); return .init() }
                rig.run(0x941B, .init(), "outcode B") { m in m.computeOutcodeB(); return .init() }
                let a = rig.machine.mem[0xCC], b = rig.machine.mem[0xD5]
                if a & b != 0 && i % 4 != 0 { continue }   // rejected by the driver (still try some)
                if a != 0 {
                    rig.run(0x9464, .init(), "\(name) #\(i) clipLine \(a) \(b)") { m in m.clipLine(); return .init() }
                }
                if rig.machine.mem[0xCC] & rig.machine.mem[0xD5] == 0 || i % 4 == 0 {
                    rig.run(0x9478, .init(), "\(name) #\(i) clipLineEnd") { m in m.clipLineEnd(); return .init() }
                }
            }
            rig.expectCleanR3D("clip lines \(name)")
        }
    }

    @Test func clipPlanes() throws {
        var rng = TestRandom(seed: 0x94C0)
        let rig = R3D.rig(try R3D.regular())
        let planes: [(UInt16, String, (Machine) -> Void)] = [
            (0x94C0, "y=z", { $0.clipPlaneYPos() }), (0x953E, "y=-z", { $0.clipPlaneYNeg() }),
            (0x95C6, "x=z", { $0.clipPlaneXPos() }), (0x9644, "x=-z", { $0.clipPlaneXNeg() }),
        ]
        for i in 0..<2000 {
            Self.setPoint(rig, 0xCD, Self.anyPoint(&rng))
            Self.setPoint(rig, 0xD6, Self.anyPoint(&rng))
            let (address, label, port) = planes[i % 4]
            rig.run(address, .init(), "plane \(label) #\(i)") { m in port(m); return .init() }
        }
        rig.run(0x946A, .init(), "swap") { m in m.swapClipEndpoints(); return .init() }
        rig.expectCleanR3D("clip planes")
    }

    /// A random polygon of `n` vertices: a convex n-gon in a random plane, or random points.
    static func polygon(_ rng: inout TestRandom, _ n: Int, convex: Bool, scale: Int) -> [(UInt16, UInt16, UInt16)] {
        if !convex { return (0..<n).map { _ in anyPoint(&rng) } }
        let cz = Double(1 + rng.r3dBelow(scale))
        let cx = Double(rng.r3dBelow(Int(3 * cz) + 1)) - 1.5 * cz
        let cy = Double(rng.r3dBelow(Int(3 * cz) + 1)) - 1.5 * cz
        let r = Double(1 + rng.r3dBelow(Int(cz) + 1))
        let tilt = Double(rng.r3dBelow(100)) / 100.0 - 0.5
        let phase = Double(rng.r3dBelow(628)) / 100.0
        return (0..<n).map { k in
            let t = phase + 2 * Double.pi * Double(k) / Double(n)
            let x = cx + r * cos(t), y = cy + r * sin(t) * (1 - abs(tilt)), z = cz + r * sin(t) * tilt
            return (UInt16(truncatingIfNeeded: Int(x)), UInt16(truncatingIfNeeded: Int(y)),
                    UInt16(truncatingIfNeeded: Int(z)))
        }
    }

    static func setPolygon(_ rig: DiffRig, _ vertices: [(UInt16, UInt16, UInt16)]) {
        for (k, v) in vertices.enumerated() {
            rig.poke(0x0B10 + k, UInt8(truncatingIfNeeded: v.0)); rig.poke(0x0B50 + k, UInt8(v.0 >> 8))
            rig.poke(0x0B90 + k, UInt8(truncatingIfNeeded: v.1)); rig.poke(0x0BD0 + k, UInt8(v.1 >> 8))
            rig.poke(0x0C10 + k, UInt8(truncatingIfNeeded: v.2)); rig.poke(0x0C50 + k, UInt8(v.2 >> 8))
        }
        rig.poke(0xB7, UInt8(vertices.count - 1))
    }

    /// Random polygons of 1-60 vertices. Large concave ones overflow the 64-entry arrays (see
    /// `Render3DOverflowTests` for that regime); their garbage crossings occasionally make a long
    /// span run the split row's code, which `PolygonCheck` compares up to that point.
    @Test func clipPolygons() throws {
        var rng = TestRandom(seed: 0x8FE8)
        var stats = PolygonCheck.Stats()
        for (name, base) in try R3D.states() {
            for bufferA in [false, true] {
                let start = bufferA ? R3D.flipped(base) : base
                let rig = R3D.rig(start)
                for i in 0..<150 {
                    // Each case from the clean state: a degenerate polygon's scan fill can
                    // scramble memory (see render3d.md), which must not leak into the next case.
                    R3D.load(rig, start)
                    let n = [1, 2, 3, 3, 4, 4, 5, 6, 8, 12, 20, 33, 47, 60][rng.r3dBelow(14)]
                    let convex = i % 5 != 0
                    let scale = [0x100, 0x1000, 0x7000][rng.r3dBelow(3)]
                    Self.setPolygon(rig, Self.polygon(&rng, n, convex: convex, scale: scale))
                    rig.poke(0x0876, rng.byte())
                    PolygonCheck.run(rig, "\(name) A=\(bufferA) #\(i) n=\(n) convex=\(convex)", stats: &stats)
                }
                rig.expectCleanR3D("clip polygons \(name) bufferA=\(bufferA)")
            }
        }
        #expect(stats.loops < 10, "\(stats.loops) polygons sent the original into a loop")
        #expect(stats.overruns + stats.overwritten + stats.wild < 10,
                "\(stats.overruns) polygons ran the split row's code, \(stats.overwritten) overwritten code, \(stats.wild) other code")
        #expect(stats.overrunFailures.isEmpty, "\(stats.overrunFailures.joined(separator: "\n"))")
    }

    /// Runway-like ground rectangles around the eye, transformed by the original ($9FD0, as ops
    /// 40/41 do) for random attitudes, views and eye heights, then clipped and filled.
    @Test func groundRectangles() throws {
        var rng = TestRandom(seed: 0x8FE9)
        for (name, base) in try R3D.states() {
            for bufferA in [false, true] {
                let start = bufferA ? R3D.flipped(base) : base
                let rig = R3D.rig(start)
                var drawn = 0
                for i in 0..<80 {
                    var ram = start
                    ram[0x0ACA] = i % 3 == 0 ? Render3DMatrixTests.views[rng.r3dBelow(9)] : 0
                    ram[0x0836] = 0
                    ram[0x6C] = rng.byte(); ram[0x6D] = UInt8(bitPattern: Int8(rng.r3dSigned(0x08) + 0x06))
                    ram[0x6E] = rng.byte(); ram[0x6F] = UInt8(bitPattern: Int8(rng.r3dSigned(0x30)))
                    ram[0x70] = rng.byte(); ram[0x71] = rng.byte()
                    ram = Original.call(0x8111, ram: ram).ram
                    let height = UInt16(1 + rng.r3dBelow(i % 3 == 0 ? 0x40 : 0x800))
                    ram[0x68] = UInt8(truncatingIfNeeded: height); ram[0x69] = UInt8(height >> 8)
                    ram = Original.call(0x8324, ram: ram).ram
                    let ex = rng.r3dBelow(0x1001) - 0x800, ez = rng.r3dBelow(0x1001) - 0x800
                    ram[0x66] = UInt8(truncatingIfNeeded: ex); ram[0x67] = UInt8(truncatingIfNeeded: ex >> 8)
                    ram[0x6A] = UInt8(truncatingIfNeeded: ez); ram[0x6B] = UInt8(truncatingIfNeeded: ez >> 8)
                    // A rectangle (2L x 2W) at a random heading, centered ahead of the eye (heading
                    // $70/$71, clockwise from north = +z) or anywhere around it.
                    let length = Double(0x40 + rng.r3dBelow(0x600)), width = Double(0x10 + rng.r3dBelow(0x80))
                    let heading = Double(ram[0x71]) / 256 * 2 * Double.pi
                    let distance = Double(height) * (1.5 + Double(rng.r3dBelow(600)) / 100)
                    var cx = Double(ex) + distance * sin(heading), cz = Double(ez) + distance * cos(heading)
                    if i % 4 == 3 { cx = Double(rng.r3dBelow(0x1001) - 0x800); cz = Double(rng.r3dBelow(0x1001) - 0x800) }
                    let theta = Double(rng.r3dBelow(628)) / 100
                    let (c, s) = (cos(theta), sin(theta))
                    let corners = [(length, width), (length, -width), (-length, -width), (-length, width)]
                    var vertices: [(UInt16, UInt16, UInt16)] = []
                    let list = 0x7BA0
                    for (l, w) in corners {
                        let px = Int(cx + l * c - w * s), pz = Int(cz + l * s + w * c)
                        ram[list + 1] = UInt8(truncatingIfNeeded: px); ram[list + 2] = UInt8(truncatingIfNeeded: px >> 8)
                        ram[list + 3] = UInt8(truncatingIfNeeded: pz); ram[list + 4] = UInt8(truncatingIfNeeded: pz >> 8)
                        ram[0x8B] = UInt8(list & 0xFF); ram[0x8C] = UInt8(list >> 8)
                        ram = Original.call(0x9FD0, ram: ram, .init(y: 0xD6)).ram
                        vertices.append((UInt16(ram[0xD6]) | UInt16(ram[0xD7]) << 8,
                                         UInt16(ram[0xD8]) | UInt16(ram[0xD9]) << 8,
                                         UInt16(ram[0xDA]) | UInt16(ram[0xDB]) << 8))
                    }
                    R3D.load(rig, ram)
                    Self.setPolygon(rig, vertices)
                    rig.poke(0x0876, rng.byte())
                    rig.poke(0xF2, 0xFF)
                    guard R3D.returns(rig, 0x8FE8) else { continue }
                    let o = rig.run(0x8FE8, .init(), "\(name) A=\(bufferA) rectangle #\(i)") { m in
                        m.clipPolygon(); return .init()
                    }
                    if o.completed, rig.machine.mem[0xF2] != 0xFF { drawn += 1 }
                }
                rig.expectCleanR3D("ground rectangles \(name) bufferA=\(bufferA)")
                #expect(drawn > 10, "only \(drawn) rectangles were drawn")
            }
        }
    }

    /// Polygons wholly inside the frustum, straight to the projection and fill ($96D4).
    @Test func fillPolygons() throws {
        var rng = TestRandom(seed: 0x96D4)
        var skipped = 0
        defer { #expect(skipped < 10, "\(skipped) polygons sent the original into a loop") }
        let start = try R3D.demo(5400)
        let rig = R3D.rig(start)
        for i in 0..<300 {
            R3D.load(rig, start)
            let n = i % 10 == 9 ? 30 + rng.r3dBelow(31) : 1 + rng.r3dBelow(14)
            var vertices: [(UInt16, UInt16, UInt16)] = []
            let convex = i % 3 != 0
            if convex {
                vertices = Self.polygon(&rng, n, convex: true, scale: 0x800).map { v in
                    // Pull every vertex inside |x|, |y| <= z.
                    let z = max(Int(Int16(bitPattern: v.2)), 1)
                    let x = max(-z, min(z, Int(Int16(bitPattern: v.0))))
                    let y = max(-z, min(z, Int(Int16(bitPattern: v.1))))
                    return (UInt16(truncatingIfNeeded: x), UInt16(truncatingIfNeeded: y), UInt16(z))
                }
            } else {
                for _ in 0..<n {
                    let z = 1 + rng.r3dBelow(0x800)
                    vertices.append((UInt16(truncatingIfNeeded: rng.r3dBelow(2 * z + 1) - z),
                                     UInt16(truncatingIfNeeded: rng.r3dBelow(2 * z + 1) - z), UInt16(z)))
                }
            }
            Self.setPolygon(rig, vertices)
            rig.poke(0x0876, rng.byte())
            rig.poke(0xF9, i % 10 == 0 ? rng.byte() : 0)
            let count = UInt8(n)
            guard R3D.returns(rig, 0x96D4, .init(y: count)) else { skipped += 1; continue }
            rig.run(0x96D4, .init(y: count), "fill #\(i) n=\(n) convex=\(convex)") { m in
                m.projectAndFillPolygon(count); return .init()
            }
        }
        rig.expectCleanR3D("fill polygons")
    }
}
