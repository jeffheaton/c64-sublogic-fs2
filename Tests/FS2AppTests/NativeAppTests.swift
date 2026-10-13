import C64Kit
import FS2Core
import FS2Data
import FS2LabKit
@testable import FS2App
@testable import FS2Host
import Foundation
import Testing

/// The app's pieces on the native engine (needs the disk): the engine loop's key timing and
/// restart, the headless runner, the mode library file behind the editor's CTRL-X / CTRL-Z.
@Suite(.enabled(if: TestDisk.data != nil, "needs the Flight Simulator II disk image"), .serialized)
struct NativeAppTests {
    /// A native engine at the title prompt, driven through `EngineLoop` (its frames go to a
    /// `FrameExchange`; `last` keeps the newest).
    final class Rig {
        let engine: NativeEngine
        let loop: EngineLoop
        let frames = FrameExchange()

        init() throws {
            engine = NativeEngine(data: try #require(TestDisk.data), modeLibrary: ModeLibrary.InMemoryStore().io)
            engine.runToKeyWait(maxFrames: 9000, deliverFrames: false)
            loop = EngineLoop(engine: engine, frames: frames, audio: nil)
        }

        func run(_ n: Int) {
            let cpf = VirtualClock.cyclesPerFrame
            for _ in 0..<n { engine.run(untilCycle: (engine.cycles / cpf + 1) * cpf) }
        }

        /// The window rows of the newest frame (the title and the prompts are drawn there).
        func window() -> ArraySlice<UInt8> {
            let pixels = frames.takeLatest()?.pixels ?? []
            let w = VICPresenter.width
            let first = 0x40 - VICPresenter.firstRasterLine, last = 0xA0 - VICPresenter.firstRasterLine
            return pixels[first * w ..< last * w]
        }

        func input(_ keys: C64Key...) {
            var i = InputState()
            for k in keys { i.keys.set(k, pressed: true) }
            loop.setUserInput(i)
        }
    }

    /// A one-frame tap of A answers the title: the key timing holds it over a scan frame.
    @Test func aOneFrameTapAnswersTheTitle() throws {
        let rig = try Rig()
        rig.run(6)
        let title = rig.window()
        rig.input(.a)
        rig.run(1)
        rig.input()
        rig.run(60)
        #expect(rig.window() != title, "the mode prompt replaced the title")
        #expect(rig.engine.machine.mem[0x0E61] == 0x65, "A: the color palette")
    }

    /// CTRL and A pressed together for a frame: CTRL goes into the matrix first, so the game reads
    /// CTRL-A ($01), which the title ignores (letter first it would read A and answer).
    @Test func controlComesFirst() throws {
        let rig = try Rig()
        rig.run(6)
        let title = rig.window()
        rig.input(.control, .a)
        rig.run(1)
        rig.input()
        rig.run(60)
        #expect(rig.window() == title, "the title is still up")
        #expect(rig.engine.machine.mem[Input.RAM.keyQueueRead] != 0, "a key was dispatched (CTRL-A)")
        // A plain A afterward answers it.
        rig.input(.a)
        rig.run(1)
        rig.input()
        rig.run(60)
        #expect(rig.window() != title)
    }

    /// Machine ▸ Restart through the engine loop: RUN/STOP held (the pause), RESTORE on the last
    /// frame; the NMI at the next poll restarts (the one-shot `$26FF` set until the boot load
    /// brings the main block back), and the player's keys come back afterward.
    @Test func restartThroughTheEngineLoop() throws {
        let rig = try Rig()
        var user = InputState()
        user.keys.set(.t, pressed: true)
        rig.loop.setUserInput(user)
        rig.run(5)
        rig.loop.sequencer.start()
        rig.run(RestartSequencer.totalFrames + 4)
        #expect(rig.engine.machine.mem[MainLoop.RAM.restoreOneShot] == 1, "the restart began")
        #expect(rig.engine.input == user, "the player's keys are back after the sequence")
        let before = rig.engine.cycles
        #expect(rig.engine.runToKeyWait(maxFrames: 9000, deliverFrames: false))
        #expect(rig.engine.cycles - before > 60_000_000, "the boot loads ran again")
        #expect(rig.engine.machine.mem[MainLoop.RAM.restoreOneShot] == 0)
    }

    /// `FS2 --headless --engine native`: the quick boot to the title, the answers, screenshots; the
    /// title frame is the lab's.
    @Test func headlessNativeEngine() throws {
        let data = try #require(TestDisk.data)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FS2AppTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let options = try HeadlessCommand.parse([
            "--headless", "--engine", "native", "--quick-boot", "--screenshot-dir", dir.path,
            "--session", "wait:10 shot:title key:A:12 pc:2250:600 wait:30 shot:mode",
        ])
        let runner = try HeadlessCommand.run(options, data: data)
        #expect(runner.engine is NativeEngine)
        #expect(runner.screenshots.map(\.lastPathComponent) == ["title.png", "mode.png"])
        let title = try #require(HeadlessTests.decodeIndices(dir.appendingPathComponent("title.png")))
        let mode = try #require(HeadlessTests.decodeIndices(dir.appendingPathComponent("mode.png")))
        #expect(title != mode, "answering the display prompt changes the screen")

        let lab = Lab.boot(data)
        try lab.play(try Session.parse("pc:2250:9000 wait:10"), screenshots: nil)
        let reference = lab.renderLastFrame().map { C64Palette.color[Int($0 & 0x0F)] & 0x00FF_FFFF }
        #expect(title == reference, "the native title differs from the lab's")
    }

    /// The editor's library hook on the file: no file is no library disk, CTRL-Z writes it with a
    /// backup of the previous one, a file of the wrong size reads as no library.
    @Test func modeLibraryFileHook() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FS2AppTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = ModeLibraryFile(url: dir.appendingPathComponent("FS2/ModeLibrary.bin"))
        let io = file.io
        #expect(io.load() == nil)
        let first = [UInt8](repeating: 0x0A, count: 1024), second = (0..<1024).map { UInt8($0 & 0xFF) }
        #expect(io.formatAndSave(first))
        #expect(io.load() == first)
        #expect(io.formatAndSave(second))
        #expect(io.load() == second)
        #expect([UInt8](try Data(contentsOf: file.backupURL)) == first)
        #expect(!io.formatAndSave([1, 2, 3]), "a block is 1024 bytes")
        try Data([1, 2, 3]).write(to: file.url)
        #expect(io.load() == nil, "a damaged library reads as no library")
        #expect(throws: ModeLibraryFile.Error.wrongSize(3)) { try file.load() }
        #expect(GameLibrary.modeLibraryURL == ModeLibraryFile.standardURL)
    }
}
