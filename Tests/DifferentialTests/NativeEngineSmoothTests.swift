import C64Kit
import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Smooth pacing redraws the window for every display frame on a scratch copy of memory, with the
/// camera interpolated between the last two completed iterations; the simulation must not notice.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct NativeEngineSmoothTests {
    /// Boot, color, regular flight at Meigs (the loads, some passes), full throttle so the take-off
    /// roll moves the camera.
    static func prepare(_ e: NativeEngine, throttle: Bool = true) {
        let frame = VirtualClock.cyclesPerFrame
        func frames(_ n: UInt64) { e.run(untilCycle: (e.cycles / frame + n) * frame) }
        e.runToKeyWait(maxFrames: 9000, deliverFrames: false)
        frames(8)
        e.input = NativeEngineThreadTests.keys(.a)
        frames(14)
        e.input = InputState()
        e.runToKeyWait(maxFrames: 600)
        frames(8)
        e.input = NativeEngineThreadTests.keys(.b)
        frames(14)
        e.input = InputState()
        frames(1150)
        if throttle { e.poke(0x0AC9, 0x7F) }
        frames(200)
    }

    static func engine(_ pacing: Pacing) throws -> NativeEngine {
        NativeEngine(data: try #require(Original.data), options: EngineOptions(pacing: pacing),
                     modeLibrary: ModeLibrary.InMemoryStore().io)
    }

    /// An Authentic and a Smooth engine on the same input: the memory at every top of the main
    /// loop and at the end is the same; the Smooth frames show the same panel (rows from line $A4)
    /// and borders, and windows in between the authentic ones.
    @Test func smoothFramesLeaveTheSimulationAlone() throws {
        let authentic = try Self.engine(.authentic), smooth = try Self.engine(.smooth)
        var hashesA: [UInt64] = [], hashesB: [UInt64] = []
        authentic.onIteration = { m in hashesA.append(ReplayLog.memoryHash(m.mem)) }
        smooth.onIteration = { m in hashesB.append(ReplayLog.memoryHash(m.mem)) }
        Self.prepare(authentic)
        Self.prepare(smooth)

        let rows = VICPresenter.height, width = VICPresenter.width
        let windowRows = VICPresenter.rasterLineRow(0x20)...VICPresenter.rasterLineRow(0xA3)
        var framesA: [UInt64: [UInt8]] = [:]
        authentic.onFrame = { f in framesA[f.frame] = f.pixels }
        let span = 420 * VirtualClock.cyclesPerFrame
        authentic.run(untilCycle: authentic.cycles + span)
        var panelDiffers = 0, windowDiffers = 0, compared = 0
        smooth.onFrame = { f in
            guard let a = framesA[f.frame] else { return }
            compared += 1
            var window = false
            for row in 0..<rows {
                let same = a[row * width ..< (row + 1) * width] == f.pixels[row * width ..< (row + 1) * width]
                if windowRows.contains(row) { if !same { window = true } } else if !same { panelDiffers += 1 }
            }
            if window { windowDiffers += 1 }
        }
        let start = Date()
        smooth.run(untilCycle: smooth.cycles + span)
        print("smooth: \(smooth.smoothFrames) of \(compared) frames redrawn (\(windowDiffers) windows differ), "
              + "\(hashesB.count) passes, \(String(format: "%.1f", Date().timeIntervalSince(start))) s")

        #expect(hashesA == hashesB, "the main-loop tops differ")
        #expect(hashesA.count >= 8, "\(hashesA.count) passes")
        NativeEngineThreadTests.expectSame(authentic, smooth, writes: ([], []))
        #expect(compared >= 400)
        #expect(smooth.smoothFrames >= 200, "\(smooth.smoothFrames) frames redrawn")
        #expect(windowDiffers >= 50, "the interpolated windows: \(windowDiffers)")
        #expect(panelDiffers == 0, "\(panelDiffers) panel or border rows differ")
        #expect(authentic.smoothFrames == 0)
    }
}

extension NativeEngineSmoothTests {
    /// Standing still at Meigs the camera does not move, so the redrawn window is the authentic
    /// one, pixel for pixel: the scratch pass draws what the real pass drew.
    @Test func aStillCameraRedrawsTheSameWindow() throws {
        let authentic = try Self.engine(.authentic), smooth = try Self.engine(.smooth)
        Self.prepare(authentic, throttle: false)
        Self.prepare(smooth, throttle: false)
        var framesA: [UInt64: [UInt8]] = [:]
        authentic.onFrame = { f in framesA[f.frame] = f.pixels }
        let span = 150 * VirtualClock.cyclesPerFrame
        authentic.run(untilCycle: authentic.cycles + span)
        var differing: [Int] = []
        smooth.onFrame = { f in
            guard let a = framesA[f.frame] else { return }
            let n = zip(a, f.pixels).filter { $0 != $1 }.count
            if n != 0 && !differing.contains(where: { $0 != 0 }) {
                let dir = Original.repoRoot.appendingPathComponent("build/testdata")
                for (name, pixels) in [("smooth-still-authentic", a), ("smooth-still-smooth", f.pixels)] {
                    try? ImageWriter.writePNG(indices: pixels, width: VICPresenter.width, height: VICPresenter.height,
                                              scaleX: 3, scaleY: 3, to: dir.appendingPathComponent("\(name).png"))
                }
                let at = (0..<a.count).filter { a[$0] != f.pixels[$0] }
                print("still: rows \(Set(at.map { $0 / VICPresenter.width }).sorted()) columns \(Set(at.map { $0 % VICPresenter.width }).sorted())")
            }
            differing.append(n)
        }
        smooth.run(untilCycle: smooth.cycles + span)
        #expect(smooth.smoothFrames >= 100, "\(smooth.smoothFrames) frames redrawn")
        #expect(differing.count >= 140 && differing.allSatisfy { $0 == 0 },
                "frames with differing pixels: \(differing.filter { $0 != 0 }.prefix(10))")
    }
}

/// The camera interpolation (no disk needed).
@Suite struct SmoothInterpolationTests {
    static func camera(_ x: UInt32, _ y: UInt32, _ z: UInt32, _ p: UInt16, _ b: UInt16, _ h: UInt16) -> [UInt8] {
        var c: [UInt8] = []
        for v in [x, y, z] { for k in 0..<4 { c.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
        for v in [p, b, h] { c.append(UInt8(truncatingIfNeeded: v)); c.append(UInt8(v >> 8)) }
        return c
    }

    @Test func positionsAndAnglesTakeTheShortWay() {
        let a = Self.camera(0x0000_1000, 0xFFFF_FF00, 0x7FFF_FFF0, 0xFFF0, 0x0010, 0x8000)
        let b = Self.camera(0x0000_2000, 0x0000_0100, 0x8000_0010, 0x0010, 0xFFF0, 0x7000)
        #expect(SmoothRenderer.interpolate(a, b, 0) == a)
        #expect(SmoothRenderer.interpolate(a, b, 1) == b)
        // Halfway: positions along the signed difference (across the 32-bit wrap), angles the
        // shorter way round (through 0 and through $8000).
        #expect(SmoothRenderer.interpolate(a, b, 0.5)
                == Self.camera(0x0000_1800, 0x0000_0000, 0x8000_0000, 0x0000, 0x0000, 0x7800))
    }
}

extension NativeEngineSmoothTests {
    /// From flight at Meigs: E opens the editor, Europe 1917 = 1 (page 0, line 6), E leaves it
    /// (mode 7, the WWI area, the war overlay resident). Keys held 14 frames, 30 frames apart.
    static func enterEurope1917(_ e: NativeEngine) {
        let frame = VirtualClock.cyclesPerFrame
        func frames(_ n: UInt64, _ keys: C64Key...) {
            var input = InputState()
            for k in keys { input.keys.set(k, pressed: true) }
            e.input = input
            e.run(untilCycle: (e.cycles / frame + n) * frame)
        }
        frames(14, .e)
        frames(1)
        e.runToKeyWait(maxFrames: 3000)                     // the editor's field loop
        frames(10)
        for _ in 0..<5 { frames(14, .returnKey); frames(30) }
        frames(14, .digit1)
        frames(30)
        frames(14, .e)
        frames(1500)                                        // the war overlay and the WWI area load
    }

    /// Europe 1917 on the runway: the scratch pass also runs the war slot $A7EE (`warMain`: the
    /// gunsight, the scope, the status lines, the dormant enemies), so with the camera still every
    /// redrawn window is the authentic one, pixel for pixel, and the main-loop tops are the
    /// Authentic run's. Neither flickers: in the frame in which a pass flips after line $20 the
    /// window shows the bitmap's old picture (the frame before's), not the new pass repainting it
    /// (the WWI area's mountains are drawn late in the pass, so a half-redrawn window lacks them).
    @Test func aStillCameraInEurope1917() throws {
        let authentic = try Self.engine(.authentic), smooth = try Self.engine(.smooth)
        var hashesA: [UInt64] = [], hashesB: [UInt64] = []
        for e in [authentic, smooth] {
            Self.prepare(e, throttle: false)
            Self.enterEurope1917(e)
            let m = e.machine
            try #require(m.mem[MainLoop.RAM.europe1917] == 1 && m.mem[MainLoop.RAM.currentMode] == 7
                         && m.u16(0xA7E0) == 0xB1EA, "war mode: \(m.mem[MainLoop.RAM.europe1917]) mode \(m.mem[MainLoop.RAM.currentMode])")
        }
        authentic.onIteration = { m in hashesA.append(ReplayLog.memoryHash(m.mem)) }
        smooth.onIteration = { m in hashesB.append(ReplayLog.memoryHash(m.mem)) }
        let width = VICPresenter.width
        let window = VICPresenter.rasterLineRow(0x33) * width ..< VICPresenter.rasterLineRow(0xA3) * width
        var framesA: [UInt64: [UInt8]] = [:], flipFrames = 0, flickers = 0
        var previousWindow: ArraySlice<UInt8>?
        authentic.onFrame = { [unowned authentic] f in
            framesA[f.frame] = f.pixels
            // The frames in which a pass flipped after line $20: the bitmap on display (latched)
            // is the one drawn into, while `$22B0` names the other. They show the window of the
            // frame before.
            let m = authentic.machine
            let shown = 0x4000 + Int(m.io.viewRegion.memPtr & 0x08) << 10
            let drawn = Int(m.mem[0x0200] & 0xE0) << 8
            if shown == drawn && 0x4000 + Int(m.mem[MainLoop.RAM.flipOperand] & 0x08) << 10 != drawn {
                flipFrames += 1
                if f.pixels[window] != previousWindow { flickers += 1 }
            }
            previousWindow = f.pixels[window]
        }
        let span = 300 * VirtualClock.cyclesPerFrame
        authentic.run(untilCycle: authentic.cycles + span)
        var differing: [Int] = []
        smooth.onFrame = { f in
            guard let a = framesA[f.frame] else { return }
            differing.append(zip(a, f.pixels).filter { $0 != $1 }.count)
        }
        let redrawn = smooth.smoothFrames
        smooth.run(untilCycle: smooth.cycles + span)
        print("smooth war: \(smooth.smoothFrames - redrawn) of \(differing.count) frames redrawn, \(hashesB.count) passes, "
              + "\(flipFrames) flip frames")
        #expect(hashesA == hashesB && hashesA.count >= 3, "\(hashesA.count) and \(hashesB.count) main-loop tops")
        NativeEngineThreadTests.expectSame(authentic, smooth, writes: ([], []))
        #expect(flipFrames >= 3, "\(flipFrames) frames in which a pass flipped after line $20")
        #expect(flickers == 0, "\(flickers) flip frames show another window than the frame before")
        #expect(smooth.smoothFrames - redrawn >= 200, "\(smooth.smoothFrames - redrawn) frames redrawn")
        #expect(differing.count >= 290 && differing.allSatisfy { $0 == 0 },
                "frames with differing pixels: \(differing.filter { $0 != 0 }.prefix(10))")
    }
}
