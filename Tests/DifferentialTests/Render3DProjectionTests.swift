import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Differential tests of the projection front-end ($9D05-$9E91, $9F94), the outcodes ($93D2,
/// $941B) and the point transforms ($A1CE, $9FD0): random points in and around the frustum, on
/// its edges, behind the eye, n = ±z, overflowing differences, display-list points across a
/// page boundary. Registers, whole memory and cycles.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct Render3DProjectionTests {
    /// A free spot for test display-list points ($7B9A-$7BFF is unused; the last points read into
    /// $7C00+ so the `(zp),Y` reads cross a page).
    static func listAddress(_ rng: inout TestRandom) -> Int { 0x7BA0 + rng.r3dBelow(0x5C) }

    /// A word that is an edge value a quarter of the time.
    static func edgeWord(_ rng: inout TestRandom) -> UInt16 {
        let edges: [UInt16] = [0, 1, 2, 0x3FFF, 0x4000, 0x7FFE, 0x7FFF, 0x8000, 0x8001, 0xC000, 0xFFFE, 0xFFFF]
        return rng.r3dBelow(4) == 0 ? edges[rng.r3dBelow(edges.count)] : rng.r3dWord()
    }

    @Test func projectionDivide() throws {
        var rng = TestRandom(seed: 0x9D3D)
        let rig = R3D.rig(try R3D.regular())
        for i in 0..<6000 {
            let table: UInt16 = i % 2 == 0 ? 0x9E92 : 0x9F13
            rig.poke16(0x9E89, table)
            let z: UInt16
            switch i % 8 {
            case 0: z = Self.edgeWord(&rng)
            case 1: z = UInt16(1 + rng.r3dBelow(16))
            default: z = UInt16(1 + rng.r3dBelow(0x7FFF))
            }
            let n: UInt16
            switch rng.r3dBelow(10) {
            case 0: n = z
            case 1: n = 0 &- z
            case 2: n = z &- 1
            case 3: n = 1 &- z
            case 4: n = Self.edgeWord(&rng)
            case 5: n = 0
            default:
                let magnitude = Int(z) == 0 ? 0 : rng.r3dBelow(Int(z) + 1)
                n = UInt16(truncatingIfNeeded: rng.r3dBelow(2) == 0 ? magnitude : -magnitude)
            }
            rig.poke16(0xC6, z)
            rig.poke(0xA5, rng.byte())
            let a = UInt8(n >> 8), y = UInt8(truncatingIfNeeded: n)
            rig.run(0x9D3D, .init(a: a, y: y), "divide n=\(n) z=\(z)") { m in
                let r = m.projectionDivide(a: a, y: y)
                return .init(a: r.a, x: r.x, y: r.y)
            }
        }
        rig.expectCleanR3D("projectionDivide")
    }

    /// Random eye-space points: inside the frustum, on its planes, outside and behind.
    static func point(_ rng: inout TestRandom) -> (UInt16, UInt16, UInt16) {
        let z = rng.r3dBelow(6) == 0 ? Int(Self.edgeWord(&rng)) : 1 + rng.r3dBelow(0x7FFF)
        let zs = Int(Int16(truncatingIfNeeded: z))
        func component() -> Int {
            switch rng.r3dBelow(6) {
            case 0: return zs
            case 1: return -zs
            case 2: return Int(Self.edgeWord(&rng))
            default: return zs == 0 ? 0 : rng.r3dBelow(2 * abs(zs) + 1) - abs(zs)
            }
        }
        return (UInt16(truncatingIfNeeded: component()), UInt16(truncatingIfNeeded: component()),
                UInt16(truncatingIfNeeded: z))
    }

    @Test func projectAndOutcodes() throws {
        var rng = TestRandom(seed: 0x9F94)
        for (name, base) in try R3D.states() {
            let rig = R3D.rig(base)
            for i in 0..<1500 {
                let (x, y, z) = Self.point(&rng)
                switch i % 5 {
                case 0:
                    rig.poke16(0xC4, x); rig.poke16(0xC6, z)
                    let a = UInt8(y >> 8), yl = UInt8(truncatingIfNeeded: y)
                    rig.run(0x9F94, .init(a: a, y: yl), "\(name) project \(x),\(y),\(z)") { m in
                        let r = m.project(a: a, y: yl)
                        return .init(a: r.a, x: r.x, y: r.y)
                    }
                case 1, 2:
                    let p = i % 5 == 1 ? 0xCD : 0xD6
                    rig.poke16(p, x); rig.poke16(p + 2, y); rig.poke16(p + 4, z)
                    rig.run(p == 0xCD ? 0x9D05 : 0x9D21, .init(), "\(name) projectPoint \(x),\(y),\(z)") { m in
                        if p == 0xCD { m.projectPointA() } else { m.projectPointB() }
                        return .init()
                    }
                default:
                    let p = i % 5 == 3 ? 0xCD : 0xD6
                    rig.poke16(p, x); rig.poke16(p + 2, y); rig.poke16(p + 4, z)
                    rig.run(p == 0xCD ? 0x93D2 : 0x941B, .init(), "\(name) outcode \(x),\(y),\(z)") { m in
                        if p == 0xCD { m.computeOutcodeA() } else { m.computeOutcodeB() }
                        return .init()
                    }
                }
            }
            rig.expectCleanR3D("project/outcodes \(name)")
        }
    }

    /// Exhaustive over the quotient: every numerator 0...±z for a few divisors, both tables.
    @Test func projectionDivideSweep() throws {
        let rig = R3D.rig(try R3D.regular())
        for z: UInt16 in [1, 3, 127, 128, 255, 1000, 0x7FFF] {
            rig.poke16(0xC6, z)
            for table: UInt16 in [0x9E92, 0x9F13] {
                rig.poke16(0x9E89, table)
                let limit = min(Int(z), 700)
                for k in -limit...limit {
                    let n = UInt16(truncatingIfNeeded: k * Int(z) / max(limit, 1))
                    let a = UInt8(n >> 8), y = UInt8(truncatingIfNeeded: n)
                    rig.run(0x9D3D, .init(a: a, y: y), "sweep n=\(n) z=\(z)") { m in
                        let r = m.projectionDivide(a: a, y: y)
                        return .init(a: r.a, x: r.x, y: r.y)
                    }
                }
            }
        }
        rig.expectCleanR3D("projectionDivide sweep")
    }

    @Test func transform3D() throws {
        var rng = TestRandom(seed: 0xA1CE)
        for (name, base) in try R3D.states() {
            let rig = R3D.rig(base)
            for i in 0..<500 {
                if i % 50 == 0 {
                    // A fresh matrix from a random attitude and view.
                    rig.poke(0x0ACA, Render3DMatrixTests.views[rng.r3dBelow(9)])
                    for a in 0x6C...0x71 { rig.poke(a, rng.byte()) }
                    rig.run(0x8111, .init(), "matrix") { m in m.buildViewMatrix(); return .init() }
                }
                let address = Self.listAddress(&rng)
                rig.poke16(0x8B, UInt16(address))
                for k in 1...6 { rig.poke(address + k, rng.byte()) }
                // Small, large and overflowing differences.
                let scale = [0x7F, 0x7FF, 0x3FFF, 0x7FFF][rng.r3dBelow(4)]
                for k in 0..<3 {
                    let w = UInt16(truncatingIfNeeded: rng.r3dBelow(2 * scale + 1) - scale)
                    rig.poke16(address + 1 + 2 * k, w)
                }
                for a in stride(from: 0x66, through: 0x6A, by: 2) {
                    rig.poke16(a, i % 4 == 0 ? Self.edgeWord(&rng) : UInt16(truncatingIfNeeded: rng.r3dBelow(0x4001) - 0x2000))
                }
                let dest: UInt8 = i % 2 == 0 ? 0xCD : 0xD6
                rig.run(0xA1CE, .init(y: dest), "\(name) #\(i) at $\(String(address, radix: 16))") { m in
                    m.transform3D(y: dest); return .init()
                }
            }
            rig.expectCleanR3D("transform3D \(name)")
        }
    }

    @Test func transformGround() throws {
        var rng = TestRandom(seed: 0x9FD0)
        for (name, base) in try R3D.states() {
            let rig = R3D.rig(base)
            for i in 0..<500 {
                if i % 50 == 0 {
                    rig.poke(0x0ACA, Render3DMatrixTests.views[rng.r3dBelow(9)])
                    for a in 0x6C...0x71 { rig.poke(a, rng.byte()) }
                    rig.run(0x8111, .init(), "matrix") { m in m.buildViewMatrix(); return .init() }
                    rig.poke16(0x68, UInt16(1 + rng.r3dBelow(0x3000)))
                    rig.run(0x8324, .init(), "base") { m in m.computeGroundBase(); return .init() }
                }
                if i % 7 == 3 {
                    // Arbitrary bases, including small ones that normalize many steps (never all
                    // zero: a zero point on a zero base never normalizes, the original hangs).
                    for a in 0x24...0x2C { rig.poke(a, i % 2 == 0 ? rng.byte() : rng.byte() & 0x07) }
                    rig.poke(0x26, rig.machine.mem[0x26] | 1)
                }
                let address = Self.listAddress(&rng)
                rig.poke16(0x8B, UInt16(address))
                let scale = [0x3F, 0x7FF, 0x3FFF, 0x7FFF][rng.r3dBelow(4)]
                for k in 0..<2 {
                    var w = UInt16(truncatingIfNeeded: rng.r3dBelow(2 * scale + 1) - scale)
                    if w == 0 { w = 1 }                 // a zero point on a zero base never normalizes
                    rig.poke16(address + 1 + 2 * k, w)
                }
                rig.poke16(0x66, i % 4 == 0 ? Self.edgeWord(&rng) : UInt16(truncatingIfNeeded: rng.r3dBelow(0x4001) - 0x2000))
                rig.poke16(0x6A, i % 4 == 1 ? Self.edgeWord(&rng) : UInt16(truncatingIfNeeded: rng.r3dBelow(0x4001) - 0x2000))
                rig.poke(0x2F, rng.byte())
                let dest: UInt8 = i % 2 == 0 ? 0xCD : 0xD6
                rig.run(0x9FD0, .init(y: dest), "\(name) #\(i) at $\(String(address, radix: 16))") { m in
                    m.transformGround(y: dest); return .init()
                }
            }
            rig.expectCleanR3D("transformGround \(name)")
        }
    }

    /// Overflowing differences with large bases and large same-sign matrix bytes: the sums
    /// exceed 16 bits, so an extension byte reaches 1 or $FE and the renormalization takes
    /// three shifts ($A176).
    @Test func transformGroundWide() throws {
        var rng = TestRandom(seed: 0xA176)
        let rig = R3D.rig(try R3D.regular())
        var threeShifts = 0
        for i in 0..<400 {
            let address = Self.listAddress(&rng)
            rig.poke16(0x8B, UInt16(address))
            let sign = i % 2 == 0 ? 1 : -1
            let p = sign * (0x6000 + rng.r3dBelow(0x2000))
            rig.poke16(address + 1, UInt16(truncatingIfNeeded: p))
            rig.poke16(address + 3, UInt16(truncatingIfNeeded: p + rng.r3dBelow(0x400)))
            rig.poke16(0x66, UInt16(truncatingIfNeeded: -sign * (0x6000 + rng.r3dBelow(0x2000))))
            rig.poke16(0x6A, UInt16(truncatingIfNeeded: -sign * (0x6000 + rng.r3dBelow(0x2000))))
            for a in stride(from: 0x78, through: 0x88, by: 2) {
                let big = UInt8(0x60 + rng.r3dBelow(0x20))
                rig.poke(a, rng.byte())
                rig.poke(a + 1, rng.r3dBelow(3) == 0 ? rng.byte() : (sign > 0 ? big : 0 &- big))
            }
            for k in 0..<3 {
                rig.poke(0x24 + 3 * k, rng.byte())
                rig.poke(0x25 + 3 * k, sign > 0 ? UInt8(0x60 + rng.r3dBelow(0x20)) : UInt8(0x80 + rng.r3dBelow(0x20)))
                rig.poke(0x26 + 3 * k, rng.byte())
            }
            let dest: UInt8 = i % 2 == 0 ? 0xCD : 0xD6
            let o = rig.run(0x9FD0, .init(y: dest), "wide #\(i)") { m in m.transformGround(y: dest); return .init() }
            if o.cycles > 0, rig.machine.mem[0x2F] <= 0x3C { threeShifts += 1 }
        }
        rig.expectCleanR3D("transformGround wide")
        #expect(threeShifts > 0, "no case reached the three-shift renormalization")
    }
}
