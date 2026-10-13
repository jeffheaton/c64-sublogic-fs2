import Foundation
import FS2Core
import FS2LabKit
import Testing

/// The renderer's routines in the order of a main-loop pass, over many consecutive frames, with
/// the state each leaves for the next (the clobbered ground base, the attitude indicator's patch
/// of $85C0 around the horizon's Bresenham, the drawn AI/TC state, the alternating window
/// buffers). The other suites start each routine from poked inputs; this one checks that the
/// ports also agree when they only see each other's output.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct Render3DFrameTests {
    /// The window rows flipped to the other buffer, as the main loop does at $208B (`$8D`
    /// alternates +$20 / +$E0).
    static func flip(_ rig: DiffRig) {
        let delta = rig.machine.mem[0x8D]
        for row in 0..<0x70 { rig.poke(0x0200 + row, rig.machine.mem[0x0200 + row] &+ delta) }
        rig.poke(0x8D, delta ^ 0xC0)
    }

    /// One display-list point at $7BA0 (x, y, z words) through a transform into `dest`.
    static func transform(_ rig: DiffRig, _ rng: inout TestRandom, dest: UInt8, ground: Bool, _ label: String) {
        let list = 0x7BA0
        rig.poke16(0x8B, UInt16(list))
        for k in 0..<3 {
            let around = Int(rig.machine.s16(0x66 + 2 * k))
            rig.poke16(list + 1 + 2 * k, UInt16(truncatingIfNeeded: around + rng.r3dBelow(0x2001) - 0x1000))
        }
        if ground {
            rig.poke16(list + 3, rig.machine.u16(list + 5))     // ground points are (x, z)
            rig.run(0x9FD0, .init(y: dest), label) { m in m.transformGround(y: dest); return .init() }
        } else {
            rig.run(0xA1CE, .init(y: dest), label) { m in m.transform3D(y: dest); return .init() }
        }
    }

    @Test func framesInSequence() throws {
        var rng = TestRandom(seed: 0x2080)
        for (name, base) in try R3D.states() {
            let rig = R3D.rig(base)
            let views: [UInt8] = [0, 2, 4, 6, 8, 0x0A, 0x0C, 0x0E, 0xFF]
            var pitch = Int(rig.machine.s16(0x6C)), bank = Int(rig.machine.s16(0x6E))
            var heading = Int(rig.machine.u16(0x70))
            var rate = 0
            var horizons = 0, projected = 0, redraws = 0
            for frame in 0..<160 {
                let label = "\(name) frame \(frame)"
                // A flight path: slow drifts, an occasional jump, a view change now and then.
                pitch += rng.r3dBelow(0x301) - 0x180; bank += rng.r3dBelow(0x601) - 0x300
                heading += rng.r3dBelow(0x401) - 0x200
                if frame % 40 == 39 { pitch = rng.r3dBelow(0x10000); bank = rng.r3dBelow(0x10000) }
                rig.poke16(0x6C, UInt16(truncatingIfNeeded: pitch))
                rig.poke16(0x6E, UInt16(truncatingIfNeeded: bank))
                rig.poke16(0x70, UInt16(truncatingIfNeeded: heading))
                if frame % 25 == 0 { rig.poke(0x0ACA, views[rng.r3dBelow(views.count)]) }
                rig.poke(0x0836, frame % 50 >= 45 ? 1 : 0)
                rig.poke16(0x68, UInt16(1 + rng.r3dBelow(0x1800)))

                // $2080: the matrix, then the page flip.
                rig.run(0x8111, .init(), "\(label) matrix") { m in m.buildViewMatrix(); return .init() }
                Self.flip(rig)

                // $8003: the horizon pass. Its start ($83A4-$840E, ported in `horizonPass` and
                // checked by `SceneryPassTests`) runs here as the original on both sides, through
                // the development bridge; the fill is the port's.
                let fillStart = rig.machine.mem[0x840F]
                rig.poke(0x840F, 0x60)
                rig.run(0x83A4, .init(), "\(label) horizon list") { m in m.callOriginal(0x83A4); return .init() }
                rig.poke(0x840F, fillStart)
                if rig.machine.mem[0xEC] & 0x80 == 0 { horizons += 1 }
                rig.run(0x840F, .init(), "\(label) horizon fill") { m in m.horizonFill(); return .init() }

                // The scenery's use of the transforms, the base (op 07/24) and a clipped line.
                rig.run(0x8324, .init(), "\(label) base") { m in m.computeGroundBase(); return .init() }
                let ground = frame % 2 == 0
                Self.transform(rig, &rng, dest: 0xCD, ground: ground, "\(label) transform A")
                Self.transform(rig, &rng, dest: 0xD6, ground: ground, "\(label) transform B")
                rig.run(0x93D2, .init(), "\(label) outcode A") { m in m.computeOutcodeA(); return .init() }
                rig.run(0x941B, .init(), "\(label) outcode B") { m in m.computeOutcodeB(); return .init() }
                let a = rig.machine.mem[0xCC], b = rig.machine.mem[0xD5]
                if a & b == 0 {
                    if a != 0 { rig.run(0x9464, .init(), "\(label) clip A") { m in m.clipLine(); return .init() } }
                    if b != 0 { rig.run(0x9478, .init(), "\(label) clip B") { m in m.clipLineEnd(); return .init() } }
                    if rig.machine.mem[0xCC] | rig.machine.mem[0xD5] == 0 {
                        rig.run(0x9D05, .init(), "\(label) project A") { m in m.projectPointA(); return .init() }
                        rig.run(0x9D21, .init(), "\(label) project B") { m in m.projectPointB(); return .init() }
                        projected += 1
                    }
                }

                // After the scenery: the overlay, the attitude indicator, every other pass the TC.
                rig.run(0xED3C, .init(), "\(label) overlay") { m in m.drawViewOverlay(); return .init() }
                let ai = rig.run(0xA378, .init(), "\(label) AI") { m in m.drawAttitudeIndicator(); return .init() }
                if ai.cycles > 100 { redraws += 1 }
                if frame % 2 == 1 {
                    rate += rng.r3dBelow(0x301) - 0x180
                    rig.poke16(0x09FE, UInt16(truncatingIfNeeded: rate))
                    rig.run(0xA532, .init(), "\(label) TC") { m in m.drawTurnCoordinator(); return .init() }
                }
            }
            rig.expectCleanR3D("frames \(name)")
            // The sequence must reach the interesting paths, not only the early returns.
            #expect(horizons > 25 && horizons < 160, "\(name): \(horizons) frames with a horizon")
            #expect(projected > 10, "\(name): \(projected) lines projected")
            #expect(redraws > 40, "\(name): \(redraws) AI redraws")
        }
    }
}
