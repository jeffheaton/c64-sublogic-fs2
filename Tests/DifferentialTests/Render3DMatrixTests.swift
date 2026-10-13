import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Differential tests of the view matrix ($8111) and the ground base ($8324): every view
/// direction, the down and radar views, pitch and bank across ±90° and inverted, the stale yaw
/// low byte, on regular-flight and demo-flight RAM. Whole memory, registers and cycles.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct Render3DMatrixTests {
    /// The views of `$0ACA` (front .. right-front, down) plus a few values the keys never set.
    static let views: [UInt8] = [0, 2, 4, 6, 8, 0x0A, 0x0C, 0x0E, 0xFF, 1, 7, 0x0F, 0x10, 0x7F, 0x80]

    @Test func viewMatrixAllViews() throws {
        var rng = TestRandom(seed: 0x8111)
        for (name, ram) in try R3D.states() {
            let rig = R3D.rig(ram)
            for i in 0..<600 {
                let view = Self.views[i % Self.views.count]
                rig.poke(0x0ACA, view)
                rig.poke(0x0836, i % 7 == 3 ? UInt8(1 + rng.r3dBelow(255)) : 0)
                // Attitudes: random, near the folds, exact quadrant boundaries.
                let special: [UInt16] = [0, 0x3FFF, 0x4000, 0x4001, 0x7FFF, 0x8000, 0x8001, 0xBFFF, 0xC000, 0xC001, 0xFFFF]
                for a in [0x6C, 0x6E, 0x70] {
                    let w = rng.r3dBelow(4) == 0 ? special[rng.r3dBelow(special.count)] : rng.r3dWord()
                    rig.poke16(a, w)
                }
                rig.poke(0x76, rng.byte())            // the stale yaw low byte
                rig.run(0x8111, .init(), "\(name) #\(i) view $\(String(view, radix: 16))") { m in
                    m.buildViewMatrix(); return .init()
                }
            }
            rig.expectCleanR3D("buildViewMatrix \(name)")
        }
    }

    /// Small attitudes around level flight in all views (the common case), sequentially.
    @Test func viewMatrixNearLevel() throws {
        var rng = TestRandom(seed: 0x8112)
        let rig = R3D.rig(try R3D.regular())
        for i in 0..<400 {
            rig.poke(0x0ACA, Self.views[i % 9])
            rig.poke(0x0836, 0)
            rig.poke16(0x6C, UInt16(bitPattern: rng.r3dSigned(0x0800)))
            rig.poke16(0x6E, UInt16(bitPattern: rng.r3dSigned(0x1800)))
            rig.poke16(0x70, rng.r3dWord())
            rig.run(0x8111, .init(), "near level #\(i)") { m in m.buildViewMatrix(); return .init() }
        }
        rig.expectCleanR3D("buildViewMatrix near level")
    }

    @Test func groundBase() throws {
        var rng = TestRandom(seed: 0x8324)
        for (name, ram) in try R3D.states() {
            let rig = R3D.rig(ram)
            for i in 0..<500 {
                for a in [0x7E, 0x80, 0x82] {
                    let special: [UInt16] = [0, 1, 0x7FFF, 0x8000, 0x8001, 0xFFFF]
                    rig.poke16(a, rng.r3dBelow(5) == 0 ? special[rng.r3dBelow(special.count)] : rng.r3dWord())
                }
                let ys: [UInt16] = [1, 2, 0x7FFF, 0x8000, 0xFFFF, rng.r3dWord(), UInt16(rng.r3dBelow(0x400) + 1)]
                rig.poke16(0x68, ys[rng.r3dBelow(ys.count)])
                rig.poke(0xC8, rng.byte())
                rig.run(0x8324, .init(), "\(name) #\(i)") { m in m.computeGroundBase(); return .init() }
            }
            rig.expectCleanR3D("computeGroundBase \(name)")
        }
    }

    /// The matrix and the base in the order the scenery uses them, then again for the next view.
    @Test func matrixThenBase() throws {
        var rng = TestRandom(seed: 0x8325)
        let rig = R3D.rig(try R3D.demo(5400))
        for i in 0..<200 {
            rig.poke(0x0ACA, Self.views[i % 9])
            rig.poke16(0x68, UInt16(rng.r3dBelow(0x2000) + 1))
            rig.run(0x8111, .init(), "matrix #\(i)") { m in m.buildViewMatrix(); return .init() }
            rig.run(0x8324, .init(), "base #\(i)") { m in m.computeGroundBase(); return .init() }
        }
        rig.expectCleanR3D("matrix then base")
    }
}
