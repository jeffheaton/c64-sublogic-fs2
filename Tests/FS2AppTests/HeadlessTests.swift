import C64Kit
import FS2Core
import FS2Data
import FS2LabKit
@testable import FS2App
import Foundation
import ImageIO
import Testing

/// The user's disk image ($FS2_D64, else the app's import in
/// ~/Library/Application Support/FS2/FlightSimulatorII.d64); tests skip without it.
enum TestDisk {
    static let data: GameData? = {
        var candidates: [URL] = []
        if let p = ProcessInfo.processInfo.environment["FS2_D64"] { candidates.append(URL(fileURLWithPath: p)) }
        candidates.append(GameData.importedDiskURL)
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let d = try? GameData(d64URL: url) { return d }
        }
        return nil
    }()
}

@Suite(.enabled(if: TestDisk.data != nil, "needs the Flight Simulator II disk image"), .serialized)
struct HeadlessTests {
    /// Boots the original with the lab engine through the headless runner (quick boot through the
    /// disk loading), screenshots the title prompt, answers it and checks the next prompt appears.
    /// The title frame must equal what the lab's own session player produces.
    @Test func bootsToTheTitleAndAnswersThePrompt() throws {
        let data = try #require(TestDisk.data)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FS2AppTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = try HeadlessCommand.parse([
            "--headless", "--engine", "lab", "--quick-boot", "--screenshot-dir", dir.path,
            "--session", "shot:title key:A:12 pc:2250:600 wait:30 shot:mode",
        ])
        options.d64 = nil
        let runner = try HeadlessCommand.run(options, data: data)
        #expect(runner.screenshots.map(\.lastPathComponent) == ["title.png", "mode.png"])

        // PNGs are 384×248 scaled 3×4.
        for url in runner.screenshots {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 1152 && image.height == 992)
        }
        let title = try Data(contentsOf: dir.appendingPathComponent("title.png"))
        let mode = try Data(contentsOf: dir.appendingPathComponent("mode.png"))
        #expect(title != mode, "answering the display prompt should change the screen")
        #expect(runner.engine.cycles > 3000 * VirtualClock.cyclesPerFrame)
        #expect(runner.framesSeen > 42, "frames are delivered after the quick boot")

        // The same session start in the lab's own player gives the identical title frame.
        let lab = Lab.boot(data)
        try lab.play(try Session.parse("pc:2250:9000"), screenshots: nil)
        let reference = lab.renderLastFrame()
        let headlessTitle = try #require(Self.decodeIndices(dir.appendingPathComponent("title.png")))
        #expect(headlessTitle == reference.map { C64Palette.color[Int($0 & 0x0F)] & 0x00FF_FFFF },
                "headless title differs from the lab's")
    }

    /// Runs a few frames through a generic engine: only `wait`, `key` and `shot` steps.
    @Test func genericStepsDriveTheEngine() throws {
        let data = try #require(TestDisk.data)
        let engine = try EngineFactory.make(.lab, data: data)
        let runner = HeadlessRunner(engine: engine)
        try runner.play(try Session.parse("wait:10 key:SPACE:2 joy1:up+fire:1"), screenshots: nil)
        #expect(runner.framesSeen == 13)
        #expect(runner.latest?.pixels.count == VICPresenter.width * VICPresenter.height)
        #expect(engine.cycles >= 13 * VirtualClock.cyclesPerFrame)
    }

    /// Samples the PNG back to 384×248 RGB values (one per C64 pixel).
    static func decodeIndices(_ url: URL) -> [UInt32]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [UInt32] = []
        out.reserveCapacity(VICPresenter.width * VICPresenter.height)
        for y in 0..<VICPresenter.height {
            for x in 0..<VICPresenter.width {
                let o = ((y * 4) * w + x * 3) * 4
                out.append(UInt32(rgba[o]) << 16 | UInt32(rgba[o + 1]) << 8 | UInt32(rgba[o + 2]))
            }
        }
        return out
    }
}
