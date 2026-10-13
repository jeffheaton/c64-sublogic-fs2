import C64Kit
import FS2Core
import FS2Data
import FS2LabKit
@testable import FS2App
import Foundation
import Testing

/// The headless runner and the app's engine loop against the original program (needs the disk).
@Suite(.enabled(if: TestDisk.data != nil, "needs the Flight Simulator II disk image"), .serialized)
struct LabParityTests {
    /// Key taps of 1-3 frames at every phase of the original's 4-frame keyboard scan, a dead key
    /// (RIGHT SHIFT occupies a held-key slot without queuing a code), both joysticks, then answers
    /// to the title prompt (A: color) and wrong answers to the mode prompt, which stays up.
    static let steps: String = {
        var s = "wait:1"
        for gap in 0..<9 { s += " key:RSHIFT:\(1 + gap % 3) wait:\(gap + 1) shot:tap\(gap)" }
        s += " joy1:up:3 wait:2 joy2:fire:2 wait:5 key:CTRL+F1:2 wait:3 key:A:3 wait:7 shot:answered"
        s += " key:Q:2 wait:1 key:C:4 wait:11 shot:mode"
        return s
    }()

    /// `FS2 --headless --engine lab` must play a session exactly like `fs2lab run`: the same
    /// screenshots and, at the end, the same RAM, registers and clock. Input steps that start on a
    /// frame boundary (all of these) must reach the original program on the same frame.
    @Test func headlessRunnerMatchesTheLabPlayer() throws {
        let data = try #require(TestDisk.data)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FS2AppTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let labDir = base.appendingPathComponent("lab"), appDir = base.appendingPathComponent("app")
        for d in [labDir, appDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let reference = Lab.boot(data)
        try reference.play(try Session.parse("pc:2250:9000 " + Self.steps), screenshots: labDir)

        let engine = LabEngine(data: data)
        let runner = HeadlessRunner(engine: engine)
        try runner.quickBoot()                        // = pc:2250:9000, without rendering the load
        try runner.play(try Session.parse(Self.steps), screenshots: appDir)

        let shots = try FileManager.default.contentsOfDirectory(atPath: labDir.path).sorted()
        #expect(shots.count == 11)
        #expect(try FileManager.default.contentsOfDirectory(atPath: appDir.path).sorted() == shots)
        for name in shots {
            let a = try Data(contentsOf: labDir.appendingPathComponent(name))
            let b = try Data(contentsOf: appDir.appendingPathComponent(name))
            #expect(a == b, "\(name) differs from fs2lab's")
        }
        let m = engine.machine
        #expect(m.cpu.cycles == reference.cpu.cycles && m.frameCount == reference.frameCount)
        #expect(m.cpu.pc == reference.cpu.pc && m.cpu.a == reference.cpu.a && m.cpu.x == reference.cpu.x
                && m.cpu.y == reference.cpu.y && m.cpu.sp == reference.cpu.sp && m.cpu.status == reference.cpu.status)
        let differing = (0..<0x10000).filter { m.bus.ram[$0] != reference.bus.ram[$0] }
        #expect(differing.isEmpty, "RAM differs at \(differing.prefix(16).map { String(format: "$%04X", $0) })")
        #expect(m.bus.colorRAM == reference.bus.colorRAM)

        // Machine ▸ Restart through the app's engine loop: RUN/STOP + RESTORE must make the
        // original's NMI handler ($2700) restart the program ($A7E2), here at the mode prompt.
        let loop = EngineLoop(engine: engine, frames: FrameExchange(), audio: nil)
        var nmis = 0, restarts = 0
        m.onInstruction = { pc in
            if pc == 0x2700 { nmis += 1 }
            if pc == 0xA7E2 { restarts += 1 }
        }
        defer { m.onInstruction = nil }
        func frames(_ n: Int) {
            let cpf = VirtualClock.cyclesPerFrame
            for _ in 0..<n { engine.run(untilCycle: (engine.cycles / cpf + 1) * cpf) }
        }
        var user = InputState()
        user.keys.set(.t, pressed: true)              // a key the player happens to hold
        loop.setUserInput(user)
        frames(5)
        loop.sequencer.start()
        frames(RestartSequencer.totalFrames)
        #expect(nmis == 0, "RESTORE comes with the last frame of the sequence")
        frames(2)
        #expect(nmis == 1 && restarts == 1, "nmi \(nmis), restarts \(restarts)")
        #expect(m.bus.ram[0x26FF] == 1, "the one-shot restart flag is set until the reload clears it")
        #expect(engine.input == user, "the player's keys are back after the sequence")
    }
}
