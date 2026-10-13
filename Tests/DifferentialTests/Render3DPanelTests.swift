import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Differential tests of the attitude indicator ($A378-$A4F1) and the turn coordinator
/// ($A532-$A5A6): random pitch and bank (inverted and beyond ±45° included), the change-by-2
/// redraw rule over small steps, the chord through the patched split row, and the XOR wings.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct Render3DPanelTests {
    @Test func attitudeIndicatorRandom() throws {
        var rng = TestRandom(seed: 0xA378)
        for (name, base) in try R3D.states() {
            let rig = R3D.rig(base)
            for i in 0..<400 {
                rig.poke(0x6C, rng.byte()); rig.poke(0x6E, rng.byte())
                let pitch = i % 3 == 0 ? rng.byte() : UInt8(bitPattern: Int8(rng.r3dSigned(0x24)))
                let bank = i % 5 == 0 ? rng.byte() : UInt8(bitPattern: Int8(rng.r3dSigned(0x60)))
                rig.poke(0x6D, pitch); rig.poke(0x6F, bank)
                if i % 4 == 0 {
                    // Force a redraw.
                    rig.poke(0xA354, pitch &+ 0x40); rig.poke(0xA355, bank &+ 0x40)
                }
                rig.run(0xA378, .init(), "\(name) #\(i) pitch $\(String(pitch, radix: 16)) bank $\(String(bank, radix: 16))") { m in
                    m.drawAttitudeIndicator(); return .init()
                }
            }
            rig.expectCleanR3D("attitude indicator \(name)")
        }
    }

    /// Every pitch/bank combination in a coarse grid around the redraw thresholds, then small
    /// steps (−3...+3) from each, so the rule "redraw unless −2 ≤ Δ ≤ +1" is exercised on both axes.
    @Test func attitudeIndicatorSteps() throws {
        var rng = TestRandom(seed: 0xA379)
        let rig = R3D.rig(try R3D.demo(5400))
        for i in 0..<500 {
            let pitch = rig.machine.mem[0x6D], bank = rig.machine.mem[0x6F]
            let dp = UInt8(bitPattern: Int8(rng.r3dSigned(3))), db = UInt8(bitPattern: Int8(rng.r3dSigned(3)))
            rig.poke(0x6D, i % 50 == 0 ? rng.byte() : pitch &+ dp)
            rig.poke(0x6F, i % 50 == 25 ? rng.byte() : bank &+ db)
            rig.run(0xA378, .init(), "step #\(i)") { m in m.drawAttitudeIndicator(); return .init() }
        }
        rig.expectCleanR3D("attitude indicator steps")
    }

    @Test func attitudeIndicatorPieces() throws {
        var rng = TestRandom(seed: 0xA4A0)
        let rig = R3D.rig(try R3D.regular())
        for i in 0..<64 {
            rig.poke(0xE9, UInt8(0x78 + rng.r3dBelow(0x20)))
            rig.poke(0x1A, rng.byte())
            let n = UInt8(rng.r3dBelow(Int(rig.machine.mem[0xE9]) - 0x77))
            rig.run(0xA4A0, .init(a: n), "fill rows #\(i)") { m in m.aiFillRows(n); return .init() }
        }
        rig.run(0x9C9C, .init(x: 3), "span color") { m in m.setSpanColor(3); return .init() }
        for x in 0x17...0x3B {
            for side: UInt8 in [0, 0xFF] {
                rig.poke(0x8A, side)
                rig.poke(0xE9, UInt8(0x78 + rng.r3dBelow(0x20)))
                rig.run(0xA4CA, .init(x: UInt8(x)), "aiSpan x=\(x) side=\(side)") { m in
                    m.aiSpan(x: UInt8(x)); return .init(x: UInt8(x))
                }
            }
        }
        rig.expectCleanR3D("attitude indicator pieces")
    }

    @Test func turnCoordinator() throws {
        var rng = TestRandom(seed: 0xA532)
        for (name, base) in try R3D.states() {
            let rig = R3D.rig(base)
            for i in 0..<300 {
                if i % 3 == 0 {
                    rig.poke16(0x09FE, rng.r3dWord())
                } else {
                    rig.poke16(0x09FE, UInt16(bitPattern: rng.r3dSigned(0x0C00)))
                }
                rig.run(0xA532, .init(), "\(name) #\(i)") { m in m.drawTurnCoordinator(); return .init() }
            }
            // Every state value; index $F0 (A & $3F = $3C) is left out: its "table entry" lies in
            // the runway code and draws lines across the code the original is running.
            for a in 0..<256 where (a << 2) & 0xFF != 0xF0 {
                rig.run(0xA558, .init(a: UInt8(a)), "\(name) helper A=\(a)") { m in
                    m.turnCoordinatorHelper(UInt8(a)); return .init()
                }
            }
            rig.expectCleanR3D("turn coordinator \(name)")
        }
    }

    @Test func viewOverlays() throws {
        var rng = TestRandom(seed: 0xED3C)
        for (name, base) in try R3D.states() {
            for bufferA in [false, true] {
                let rig = R3D.rig(bufferA ? R3D.flipped(base) : base)
                var cases: [(UInt8, UInt8, UInt8)] = []       // radar, view, war
                for view: UInt8 in [0, 2, 4, 6, 8, 0x0A, 0x0C, 0x0E, 0xFF, 0x80] {
                    for war: UInt8 in [0, 1] { cases.append((0, view, war)) }
                }
                cases.append((1, 0, 0)); cases.append((0x80, 0xFF, 1))
                for _ in 0..<12 { cases.append((0, UInt8(rng.r3dBelow(8) * 2), rng.byte() & 1)) }
                for (radar, view, war) in cases {
                    rig.poke(0x0836, radar); rig.poke(0x0ACA, view); rig.poke(0x0969, war)
                    rig.run(0xED3C, .init(), "\(name) A=\(bufferA) radar=\(radar) view=\(view) war=\(war)") { m in
                        m.drawViewOverlay(); return .init()
                    }
                }
                for entry in stride(from: 0, through: 0x40, by: 8) {
                    rig.run(0xED88, .init(a: UInt8(entry)), "\(name) airframe \(entry)") { m in
                        m.drawAirframe(UInt8(entry)); return .init()
                    }
                }
                rig.expectCleanR3D("view overlays \(name) bufferA=\(bufferA)")
            }
        }
    }
}
