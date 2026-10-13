import C64Kit
import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Whole scenery passes in every area, against the original: the main loop's rendering order
/// ($E565 root, $8000 matrix, the page flip, $8003 horizon pass, $8006 scenery) from lab
/// snapshots taken after the area (and its detail block) streamed in, at several positions,
/// heights, attitudes and views, by day and by night (dotted lines) and in the radar view. Each
/// call compares the whole memory and the cycles; the 10 Hz tick is not due (`$0E6B` < 6).
/// Golden frames: both images presented with the game's raster split must be identical.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct SceneryPassTests {
    /// A place to fly: the eye position in high-word units (≈ 256 m), the height in meters,
    /// and the blocks the lab must have streamed in (area slot 0, detail slot 1).
    struct Place: Sendable {
        var name: String
        var north: Int, east: Int, meters: Int
        var area: Int, detail: Int?
        /// The clock hour (`$0983`) when not the regular session's morning.
        var hour: Int? = nil
    }

    static let places: [Place] = [
        Place(name: "downtown", north: 822, east: 281, meters: 400, area: 68, detail: 78),
        Place(name: "downtownnight", north: 818, east: 286, meters: 300, area: 68, detail: 78, hour: 22),
        Place(name: "ohare", north: 859, east: 194, meters: 600, area: 68, detail: 74),
        Place(name: "midway", north: 772, east: 244, meters: 500, area: 68, detail: 76),
        Place(name: "champaign", north: 87, east: 290, meters: 600, area: 52, detail: nil),
        Place(name: "la", north: -982, east: -10585, meters: 600, area: 80, detail: 90),
        Place(name: "lasouth", north: -1453, east: -10272, meters: 600, area: 112, detail: nil),
        Place(name: "seattlenorth", north: 5356, east: -10009, meters: 600, area: 92, detail: 100),
        Place(name: "seattlesouth", north: 4834, east: -10041, meters: 600, area: 102, detail: 110),
        Place(name: "newyork", north: 650, east: 4681, meters: 600, area: 118, detail: 123),
        Place(name: "newengland", north: 1189, east: 5137, meters: 600, area: 58, detail: nil),
        Place(name: "wwi", north: 1000, east: -9000, meters: 800, area: 48, detail: nil),
    ]

    /// The lab snapshot at `place`: regular flight, slew mode (the position holds), the eye moved
    /// there, then the main loop runs until the blocks have streamed in.
    static func snapshot(_ place: Place) throws -> [UInt8] {
        let regular = try String(contentsOf: Original.repoRoot.appendingPathComponent("re/sessions/regular.txt"),
                                 encoding: .utf8)
        func pokes(_ address: Int, _ value: Int) -> String {
            (0..<2).map { String(format: "poke:%02X:%02X", address + $0, (value >> (8 * $0)) & 0xFF) }
                .joined(separator: " ")
        }
        let height = place.meters * 256
        var steps = "poke:0966:01 " + pokes(0x5A, 0x8000) + " " + pokes(0x5C, place.east & 0xFFFF) + " "
        steps += pokes(0x5E, height & 0xFFFF) + " " + pokes(0x60, height >> 16) + " "
        steps += pokes(0x62, 0x8000) + " " + pokes(0x64, place.north & 0xFFFF)
        if let hour = place.hour { steps += String(format: " poke:0983:%02X wait:400", hour) }
        steps += String(format: " until:0900:%02X:4000", place.area)
        if let detail = place.detail { steps += String(format: " until:0901:%02X:4000", detail) }
        steps += " wait:30 pc:204B:3000"
        var ram = try Original.snapshot("scn-\(place.name)", session: regular + "\n" + steps)
        ram[0x0E6B] = 0
        return R3D.sanitized(ram)
    }

    /// Whether the original's scenery pass would read blocks from disk (the flat harness has no
    /// drive): runs $8006 on a copy, stopping at the read $E63C.
    static func wouldLoad(_ rig: DiffRig) -> Bool {
        let h = RoutineHarness(ram: rig.harness.bus.ram)
        var loads = false
        h.cpu.traps[0xE63C] = true
        h.cpu.trapHandler = { _ in loads = true; h.cpu.pc = 0xFFF0; return true }
        _ = h.call(0x8006, .init(), maxCycles: 40_000_000)
        return loads
    }

    /// One main-loop rendering sequence on both sides.
    static func pass(_ rig: DiffRig, _ label: String) {
        rig.run(0xE565, .init(), "\(label) root") { m in m.setSceneryRoot(); return .init() }
        rig.run(0x8000, .init(), "\(label) matrix") { m in m.charge(3); m.buildViewMatrix(); return .init() }
        Render3DFrameTests.flip(rig)
        SCN.run(rig, 0x8003, "\(label) horizon") { m throws(Scenery.Fault) in m.charge(3); try m.horizonPass() }
        SCN.run(rig, 0x8006, "\(label) scenery") { m throws(Scenery.Fault) in m.charge(3); try m.runScenery() }
    }

    /// Variations of attitude, view, position, height, night and radar around a place.
    static func run(_ name: String, _ ram: [UInt8], seed: UInt64, rounds: Int) -> (DiffRig, Int) {
        let rig = SCN.rig(ram)
        var rng = TestRandom(seed: seed)
        var skipped = 0
        let height = rig.machine.u32(0x5E)
        let east = Int(rig.machine.u32(0x5A)), north = Int(rig.machine.u32(0x62))
        for round in 0..<rounds {
            let label = "\(name) \(round)"
            SCN.restoreCode(rig, from: ram)
            // The position: the place itself in the first rounds, then anywhere in its 256 m
            // square, and every third round up to two squares (about 500 m) away.
            if round >= 2 {
                for (address, base) in [(0x5A, east), (0x62, north)] {
                    let squares = round % 3 == 1 ? rng.scnSigned(2) : 0
                    let v = (base & ~0xFFFF) + squares << 16 + rng.scnWord()
                    rig.poke16(address, UInt16(v & 0xFFFF)); rig.poke16(address + 2, UInt16((v >> 16) & 0xFFFF))
                }
            }
            rig.poke16(0x6C, UInt16(round % 4 == 0 ? 0 : rng.scnSigned(0x1400) & 0xFFFF))
            rig.poke16(0x6E, UInt16(round % 4 == 0 ? 0 : rng.scnSigned(0x2800) & 0xFFFF))
            rig.poke16(0x70, UInt16(rng.scnWord()))
            rig.poke(0x0ACA, round < 2 ? 0 : [0, 0, 2, 4, 6, 8, 0x0A, 0x0C, 0x0E, 0xFF][rng.scnBelow(10)])
            let radar = round % 7 == 6
            rig.poke(0x0836, radar ? 1 : 0)
            if radar { rig.poke16(0x0888, 0); rig.poke16(0x088A, UInt16(1 << rng.scnBelow(6))) }
            // Night every third round: the dotted pens (op 1C) and the night colors.
            rig.poke(0x083C, round % 3 == 2 ? 0x00 : 0x01)
            let h = UInt32(truncatingIfNeeded: max(Int(height) + (round % 4) * rng.scnSigned(0x00C0_0000), 0x0001_0000))
            for k in 0..<4 { rig.poke(0x5E + k, UInt8(truncatingIfNeeded: h >> (8 * UInt32(k)))) }
            if wouldLoad(rig) { skipped += 1; continue }
            pass(rig, label)
            // Golden frames: a level day view, a night view, a radar view and the last pass.
            if round == 0 || round == 2 || round == 6 || round == rounds - 1 { GoldenFrames.check(rig, "\(name)-\(round)") }
        }
        return (rig, skipped)
    }

    @Test(arguments: Self.places.map(\.name))
    func area(_ name: String) throws {
        let place = Self.places.first { $0.name == name }!
        let ram = try Self.snapshot(place)
        #expect(ram[0x0900] == UInt8(place.area), "\(name): area block \(ram[0x0900]) streamed in")
        if let detail = place.detail { #expect(ram[0x0901] == UInt8(detail), "\(name): detail \(ram[0x0901])") }
        let seed = UInt64(bitPattern: Int64(place.north &* 31 &+ place.east)) & 0xFFFF_FFFF
        let (rig, skipped) = Self.run(name, ram, seed: seed, rounds: 21)
        rig.expectCleanSCN("passes \(name)")
        #expect(skipped < 5, "\(name): \(skipped) passes would load blocks")
    }

    @Test func meigs() throws {
        let ram = try SCN.regular()
        let (rig, skipped) = Self.run("meigs", ram, seed: 0x204B, rounds: 30)
        rig.expectCleanSCN("passes meigs")
        #expect(skipped == 0)
    }
}

/// Golden frames: the original's and the port's images presented with the game's raster split.
enum GoldenFrames {
    /// The VIC state of the game's split: the window rows multicolor from the buffer just drawn
    /// (`$D018` $F0 = bitmap $4000, $F8 = $6000, as the IRQ writes from $22B0 after the flip),
    /// border `[$22B5]`; the panel hi-res from $4000 with border $0C (the IRQ at line $A3).
    static func present(_ ram: [UInt8]) -> [UInt8] {
        var view = VICState()
        view.cr1 = 0x3B; view.bank = 0x4000
        view.memPtr = ram[0x0200] >= 0x60 ? 0xF8 : 0xF0
        view.cr2 = 0xD8; view.border = ram[0x22B5] & 0x0F
        view.background[0] = ram[0x0E61] & 0x0F
        view.spriteEnable = 0x0F; view.spriteMulticolor = 0x0F
        view.spriteX = [88, 104, 88, 104, 0, 0, 0, 0]; view.spriteY = [170, 170, 181, 181, 0, 0, 0, 0]
        view.spriteColor = Array(repeating: 0x0B, count: 8); view.spriteMC0 = 0x0B; view.spriteMC1 = 0x01
        var panel = view
        panel.memPtr = 0xF0; panel.cr2 = 0xC8; panel.border = 0x0C
        var out: [UInt8] = []
        let colorRAM = [UInt8](repeating: 1, count: 1024)
        ram.withUnsafeBufferPointer { p in
            VICPresenter.render(into: &out, ram: p, colorRAM: colorRAM, charROM: nil) { raster in
                raster >= 0xA3 || raster < 0x20 ? panel : view
            }
        }
        return out
    }

    /// Compares the two presented frames pixel for pixel (and keeps the port's as a PNG under
    /// build/testdata for inspection).
    static func check(_ rig: DiffRig, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let original = present(rig.harness.bus.ram)
        let port = present(rig.machine.memoryImage)
        let differing = zip(original, port).filter { $0 != $1 }.count
        #expect(differing == 0, "\(name): \(differing) pixels differ", sourceLocation: sourceLocation)
        let url = Original.repoRoot.appendingPathComponent("build/testdata/scn-\(name).png")
        try? ImageWriter.writePNG(indices: port, width: VICPresenter.width, height: VICPresenter.height,
                                  scaleX: 2, scaleY: 2, to: url)
    }
}
