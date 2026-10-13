import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Differential tests of the sky/ground fill ($840F-$86A3): the fill-byte selection, the no
/// horizon case, random border-to-border horizons, the real horizon of random attitudes (the
/// original run up to $840F), the Bresenham and the split row alone, on both window buffers.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct Render3DHorizonTests {
    /// A random point on the window border (x 0-159, y 0-111).
    static func borderPoint(_ rng: inout TestRandom) -> (UInt8, UInt8) {
        switch rng.r3dBelow(4) {
        case 0: return (0, UInt8(rng.r3dBelow(112)))
        case 1: return (0x9F, UInt8(rng.r3dBelow(112)))
        case 2: return (UInt8(rng.r3dBelow(160)), 0)
        default: return (UInt8(rng.r3dBelow(160)), 0x6F)
        }
    }

    static func fillSelectors(_ rng: inout TestRandom) -> (UInt8, UInt8) {
        let choices: [UInt8] = [0, 0xFF, 0xD5, 0x2A, rng.byte()]
        return (choices[rng.r3dBelow(choices.count)], choices[rng.r3dBelow(choices.count)])
    }

    @Test func randomHorizons() throws {
        var rng = TestRandom(seed: 0x840F)
        for (name, base) in try R3D.states() {
            for bufferA in [false, true] {
                let rig = R3D.rig(bufferA ? R3D.flipped(base) : base)
                for i in 0..<300 {
                    let (sky, ground) = Self.fillSelectors(&rng)
                    rig.poke(0x0880, sky); rig.poke(0x0882, ground)
                    rig.poke(0x73, rng.byte())
                    if i % 10 == 0 {
                        rig.poke(0xEC, 0x80 | rng.byte())   // no horizon
                    } else {
                        var p1 = Self.borderPoint(&rng), p2 = Self.borderPoint(&rng)
                        if i % 7 == 1 { p1 = (UInt8(rng.r3dBelow(160)), UInt8(rng.r3dBelow(112))) }
                        if i % 11 == 2 { p2 = p1 }
                        rig.poke(0xEB, p1.0); rig.poke(0xEC, p1.1)
                        rig.poke(0xED, p2.0); rig.poke(0xEE, p2.1)
                    }
                    rig.run(0x840F, .init(), "\(name) A=\(bufferA) #\(i)") { m in m.horizonFill(); return .init() }
                }
                rig.expectCleanR3D("horizonFill \(name) bufferA=\(bufferA)")
            }
        }
    }

    /// The horizon of real attitudes: the original runs the matrix and the start of the horizon
    /// pass (the scenery interpreter on the horizon list) up to $840F; the fill is compared from
    /// there.
    @Test func realHorizons() throws {
        var rng = TestRandom(seed: 0x83A4)
        for (name, base) in try R3D.states() {
            let rig = R3D.rig(base)
            for i in 0..<120 {
                var ram = base
                ram[0x0ACA] = Render3DMatrixTests.views[i % 9]
                ram[0x0836] = i % 13 == 5 ? 1 : 0
                ram[0x6C] = rng.byte(); ram[0x6D] = i % 3 == 0 ? rng.byte() : UInt8(bitPattern: Int8(rng.r3dSigned(24)))
                ram[0x6E] = rng.byte(); ram[0x6F] = i % 4 == 0 ? rng.byte() : UInt8(bitPattern: Int8(rng.r3dSigned(48)))
                ram[0x70] = rng.byte(); ram[0x71] = rng.byte()
                let (sky, ground) = Self.fillSelectors(&rng)
                ram[0x0880] = sky; ram[0x0882] = ground
                let matrix = Original.call(0x8111, ram: ram).ram
                R3D.load(rig, R3D.runUntil(0x83A4, stop: 0x840F, ram: matrix))
                rig.run(0x840F, .init(), "\(name) #\(i) horizon \(rig.machine.mem[0xEB]),\(rig.machine.mem[0xEC])-\(rig.machine.mem[0xED]),\(rig.machine.mem[0xEE])") { m in
                    m.horizonFill(); return .init()
                }
            }
            rig.expectCleanR3D("real horizons \(name)")
        }
    }

    @Test func bresenhamAndSplitRow() throws {
        var rng = TestRandom(seed: 0x8623)
        for bufferA in [false, true] {
            let base = try R3D.regular()
            let rig = R3D.rig(bufferA ? R3D.flipped(base) : base)
            for i in 0..<400 {
                rig.poke(0xEF, rng.byte()); rig.poke(0xF0, rng.byte())
                rig.poke(0xEB, UInt8(rng.r3dBelow(160))); rig.poke(0xEC, UInt8(rng.r3dBelow(112)))
                rig.poke(0xED, UInt8(rng.r3dBelow(160))); rig.poke(0xEE, UInt8(rng.r3dBelow(112)))
                if i % 9 == 0 { rig.poke(0xEE, rig.machine.mem[0xEC]) }    // horizontal
                if i % 9 == 1 { rig.poke(0xED, rig.machine.mem[0xEB]) }    // vertical
                rig.run(0x8623, .init(), "bresenham #\(i)") { m in m.horizonBresenham(); return .init() }
            }
            for x in 0..<160 {
                rig.poke(0xE9, UInt8(rng.r3dBelow(112)))
                rig.poke(0xEF, rng.byte()); rig.poke(0xF0, rng.byte())
                rig.run(0x85C0, .init(x: UInt8(x)), "split x=\(x)") { m in
                    m.horizonSplitRow(x: UInt8(x)); return .init(x: UInt8(x))
                }
            }
            for i in 0..<60 {
                rig.poke(0xE9, UInt8(rng.r3dBelow(112)))
                rig.poke(0xF3, UInt8(1 + rng.r3dBelow(Int(rig.machine.mem[0xE9]) + 1)))
                rig.poke(0xEF, rng.byte())
                rig.run(0x8504, .init(), "whole rows #\(i)") { m in m.fillWholeRows(); return .init() }
                rig.run(0x84FB, .init(), "swap #\(i)") { m in m.horizonColorSwap(); return .init() }
            }
            rig.expectCleanR3D("bresenham/split bufferA=\(bufferA)")
        }
    }
}
