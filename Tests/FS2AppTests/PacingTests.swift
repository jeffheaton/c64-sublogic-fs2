import C64Kit
import FS2Core
import FS2Data
@testable import FS2App
import FS2LabKit
import Foundation
import Testing

/// Authentic pacing against the original: main-loop iteration durations (cycles from one $204B to
/// the next) of the native engine in normal mode against the lab running the original, in several
/// scenes, both driven by the same headless session (`HeadlessRunner`). The port's clock models the
/// cycles the VIC takes from the CPU (`Machine.vicDMA`: 1,168 of every 17,095 in flight, badlines and
/// sprites) and the loader's measured time as wall time, so its passes take the C64's cycles: the
/// median pass of each scene is within 2% of the lab's and the mean within 1% (measured: the means
/// 0.999-1.000, the medians 0.998-1.008, where they were 0.896-0.930 before the DMA was modeled).
/// The median absorbs the drift of two flights in normal mode and the passes that stream scenery.
///
/// The cost model itself is measured on identical work by `ReplayMatrixTests` (the port's cycles
/// per replayed pass against the lab's), and the DMA model by `VICDMATests` (the same instruction
/// at the same cycle as on the lab's VIC); both run by default.
///
/// Opt-in (`FS2_PACING=1`; each scene boots both engines and flies a few thousand frames, about
/// 30 s in a release build but 14 minutes in a debug one, too long for the default suite):
///
///     FS2_PACING=1 swift test -c release -Xswiftc -enable-testing --build-path .build-reltest \
///         --filter PacingTests
@Suite(.enabled(if: TestDisk.data != nil && ProcessInfo.processInfo.environment["FS2_PACING"] != nil,
                "FS2_PACING=1 and the disk image"))
struct PacingTests {
    struct Scene: Sendable, CustomStringConvertible {
        var name: String
        /// The session after the quick boot (both engines stop at the title prompt first).
        var setup: String
        /// Frames measured after the setup.
        var frames = 3600
        var description: String { name }
    }

    /// Color display, regular flight, the Chicago area and the Meigs detail streamed in.
    static let meigs = "key:A:12 wait:60 key:B:12 wait:900"

    /// Slew mode with the eye at a place (high-word units of about 256 m, height in meters), as
    /// `SceneryPassTests` places it.
    static func slew(north: Int, east: Int, meters: Int) -> String {
        func pokes(_ address: Int, _ value: Int) -> String {
            (0..<2).map { String(format: "poke:%02X:%02X", address + $0, (value >> (8 * $0)) & 0xFF) }
                .joined(separator: " ")
        }
        let height = meters * 256
        return " poke:0966:01 " + pokes(0x5A, 0x8000) + " " + pokes(0x5C, east & 0xFFFF) + " "
            + pokes(0x5E, height & 0xFFFF) + " " + pokes(0x60, height >> 16) + " "
            + pokes(0x62, 0x8000) + " " + pokes(0x64, north & 0xFFFF)
    }

    /// EUROPE 1917 turned on in the editor (page 0, line 6), the war overlay and the WWI area.
    static let europe1917 = " key:E:6 wait:900" + String(repeating: " key:RETURN:6 wait:24", count: 5)
        + " key:1:6 wait:24 key:E:6 wait:1500"

    static let scenes: [Scene] = [
        Scene(name: "meigs-idle", setup: meigs + " wait:300"),
        Scene(name: "takeoff", setup: meigs + " key:;:150 wait:540 key:B:6 wait:20 key:B:6 wait:20 key:B:6 wait:20"),
        Scene(name: "demo-climb", setup: "key:A:12 wait:60 key:A:12 wait:3600"),
        Scene(name: "chicago-downtown", setup: meigs + slew(north: 822, east: 281, meters: 400) + " wait:1500"),
        Scene(name: "los-angeles", setup: meigs + slew(north: -982, east: -10585, meters: 600) + " wait:2400"),
        Scene(name: "night-city", setup: meigs + " poke:0983:16 wait:600 key:5:6 wait:20 key:F:6 wait:300"),
        Scene(name: "radar", setup: meigs + " key:4:6 wait:300"),
        Scene(name: "war", setup: meigs + europe1917 + " key:W:6 wait:600 key:;:150 wait:300"),
    ]

    /// Iteration lengths (cycles) that start and end inside [from, to].
    static func iterations(tops: [UInt64], from: UInt64, to: UInt64) -> [UInt64] {
        let inside = tops.filter { $0 >= from && $0 <= to }
        return zip(inside, inside.dropFirst()).map { $1 - $0 }
    }

    struct Measurement {
        var iterations: [UInt64]
        var mean: Double { iterations.isEmpty ? 0 : Double(iterations.reduce(0, +)) / Double(iterations.count) }
        var median: Double {
            guard !iterations.isEmpty else { return 0 }
            let s = iterations.sorted()
            return Double(s[s.count / 2])
        }
    }

    /// Plays `scene` on an engine and returns the iterations of its measured window. `tops` gives
    /// the cycles of every $204B seen so far.
    static func measure(_ scene: Scene, engine: any GameEngine, tops: () -> [UInt64]) throws -> Measurement {
        let runner = HeadlessRunner(engine: engine)
        try runner.quickBoot()
        try runner.play(try Session.parse(scene.setup), screenshots: nil)
        let from = engine.cycles
        try runner.play(try Session.parse("wait:\(scene.frames)"), screenshots: nil)
        return Measurement(iterations: iterations(tops: tops(), from: from, to: engine.cycles))
    }

    static func native(_ scene: Scene) throws -> Measurement {
        let engine = NativeEngine(data: try #require(TestDisk.data), modeLibrary: ModeLibrary.InMemoryStore().io)
        var tops: [UInt64] = []
        engine.onIteration = { m in tops.append(m.clock.cycles) }
        return try measure(scene, engine: engine) { tops }
    }

    static func lab(_ scene: Scene) throws -> Measurement {
        let engine = LabEngine(data: try #require(TestDisk.data))
        var tops: [UInt64] = []
        let m = engine.machine
        let previous = m.onInstruction
        m.onInstruction = { [unowned m] pc in
            if pc == 0x204B { tops.append(m.cpu.cycles) }
            previous?(pc)
        }
        return try measure(scene, engine: engine) { tops }
    }

    @Test(arguments: Self.scenes)
    func iterationDurations(_ scene: Scene) throws {
        let n = try Self.native(scene)
        let l = try Self.lab(scene)
        let ratio = n.median / max(l.median, 1)
        print(String(format: "pacing %@: native median %.0f cycles/pass (mean %.0f, %d passes), lab median %.0f (mean %.0f, "
                     + "%d passes), native/lab median %.3f, mean %.3f",
                     scene.name, n.median, n.mean, n.iterations.count, l.median, l.mean, l.iterations.count, ratio,
                     n.mean / max(l.mean, 1)))
        #expect(n.iterations.count >= 4 && l.iterations.count >= 4, "\(scene.name): too few passes measured")
        #expect(abs(ratio - 1) <= 0.02, "\(scene.name): native \(Int(n.median)) vs lab \(Int(l.median)) cycles per pass")
        #expect(abs(n.mean / max(l.mean, 1) - 1) <= 0.01,
                "\(scene.name): native mean \(Int(n.mean)) vs lab \(Int(l.mean)) cycles per pass")
    }
}
