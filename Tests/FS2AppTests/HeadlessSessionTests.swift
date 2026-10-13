import C64Kit
import FS2Core
import FS2Data
import FS2LabKit
@testable import FS2App
import Foundation
import Testing

/// Sessions that hold keys across steps (`down:`/`up:`, the CTRL combinations of re/sessions) and
/// press RESTORE (`nmi`), run headless on both engines (needs the disk).
@Suite(.enabled(if: TestDisk.data != nil, "needs the Flight Simulator II disk image"), .serialized)
struct HeadlessSessionTests {
    /// From the title prompt: A; at the mode prompt CTRL held across a C (CTRL-C, which the
    /// prompt ignores); then RUN/STOP held and RESTORE: the NMI handler's cold restart.
    static let steps = """
        wait:1 key:A:3 wait:30 down:CTRL wait:8 key:C:6 up:CTRL wait:10
        down:RUNSTOP wait:10 nmi wait:4 up:RUNSTOP wait:60 shot:restarting
        """

    /// `FS2 --headless --engine lab` plays held keys and RESTORE exactly like `fs2lab run`: the
    /// keys change and the NMI comes at the same instruction, so the screenshot, RAM, registers and
    /// clock are the same. The native engine restarts on the same steps.
    @Test func heldKeysAndRestoreMatchTheLabPlayer() throws {
        let data = try #require(TestDisk.data)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FS2AppTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let labDir = base.appendingPathComponent("lab"), appDir = base.appendingPathComponent("app")
        for d in [labDir, appDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let reference = Lab.boot(data)
        try reference.play(try Session.parse("pc:2250:9000"), screenshots: nil)
        var restarts = 0
        reference.onInstruction = { pc in if pc == 0xA7E2 { restarts += 1 } }
        try reference.play(try Session.parse(Self.steps), screenshots: labDir)
        reference.onInstruction = nil
        #expect(restarts == 1, "RUN/STOP + RESTORE restarted the original")
        #expect(reference.bus.ram[MainLoop.RAM.restoreOneShot] == 1, "in the restart's loads")

        let engine = LabEngine(data: data)
        let runner = HeadlessRunner(engine: engine)
        try runner.quickBoot()
        try runner.play(try Session.parse("pc:2250:9000 " + Self.steps), screenshots: appDir)
        let a = try Data(contentsOf: labDir.appendingPathComponent("restarting.png"))
        let b = try Data(contentsOf: appDir.appendingPathComponent("restarting.png"))
        #expect(a == b, "the screenshot differs from fs2lab's")
        let m = engine.machine
        #expect(m.cpu.cycles == reference.cpu.cycles && m.frameCount == reference.frameCount)
        #expect(m.cpu.pc == reference.cpu.pc && m.cpu.sp == reference.cpu.sp && m.cpu.status == reference.cpu.status)
        let differing = (0..<0x10000).filter { m.bus.ram[$0] != reference.bus.ram[$0] }
        #expect(differing.isEmpty, "RAM differs at \(differing.prefix(16).map { String(format: "$%04X", $0) })")

        // The native engine: the session's pc:2250 right after the quick boot stops at once, as
        // the lab's does; the same steps restart the program.
        let native = NativeEngine(data: data, modeLibrary: ModeLibrary.InMemoryStore().io)
        let nativeRunner = HeadlessRunner(engine: native)
        try nativeRunner.quickBoot()
        let booted = native.cycles
        try nativeRunner.play(try Session.parse("pc:2250:9000"), screenshots: nil)
        #expect(native.cycles == booted, "already at the title's key wait")
        try nativeRunner.play(try Session.parse(Self.steps), screenshots: nil)
        #expect(native.machine.mem[MainLoop.RAM.restoreOneShot] == 1, "the native engine restarted")
        #expect(native.runToKeyWait(maxFrames: 9000, deliverFrames: false))
        #expect(native.machine.mem[MainLoop.RAM.restoreOneShot] == 0 && native.machine.u16(0xA7E0) == 0xAD00,
                "back at the title, overlay 0 resident")
    }

    /// The regular-flight prefix of re/sessions and CTRL+E (CTRL held with `down:` across the E,
    /// as re/sessions/database.txt does) on the native engine through `FS2 --headless`: the
    /// database info overlay comes up and waits for a key (`pc:2250`), SPACE ends it, the flight
    /// overlay is back at the top of the main loop (`pc:204B`). `until:`, `peek:` and the skipped
    /// `cov:` steps are part of it.
    @Test func ctrlSessionOnTheNativeEngine() throws {
        let data = try #require(TestDisk.data)
        let session = """
            pc:2250:9000 key:A:12
            pc:2250:600 key:B:12
            pc:204B:3000
            until:0901:4E:3000 pc:204B:3000 wait:60
            cov:on
            down:CTRL wait:8 key:E:14 up:CTRL wait:30
            pc:2250:3000 peek:A7E0:2 peek:0E87
            key:SPACE:14 wait:30
            pc:204B:3000 pc:204B:3000 peek:A7E0:2
            cov:save:database
            """
        var options = try HeadlessCommand.parse(["--headless", "--engine", "native", "--quick-boot", "--session", session])
        options.d64 = nil
        let kind = try EngineFactory.resolve(requested: options.engine)
        let engine = try EngineFactory.make(kind, data: data, options: options.engineOptions,
                                            modeLibrary: HeadlessCommand.modeLibrary(options))
        let runner = HeadlessRunner(engine: engine)
        var lines: [String] = []
        runner.output = { lines.append($0) }
        try runner.quickBoot()
        try runner.play(try Session.parse(session), screenshots: nil)
        let values = lines.map { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        #expect(values == ["78 A8", "00", "00 A8"], "the database overlay ($A878), its request served, the flight overlay: \(lines)")
        #expect(runner.skippedSteps == 2)
        let native = try #require(engine as? NativeEngine)
        #expect(native.machine.u16(0xA7E0) == 0xA800 && native.endReason == nil)
    }
}
