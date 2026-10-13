import C64Kit
import FS2LabKit
import Foundation
import Testing

/// The lab's session language (`Session.parse`, `C64Machine.play`): the step types the coverage
/// sessions rely on, their error handling, the overlay-aware `cov:` recorder and the text-screen
/// decoder. None of these tests need the disk image.
@Suite struct SessionLanguage {
    static let sessionsDir = Original.repoRoot.appendingPathComponent("re/sessions", isDirectory: true)

    static func sessionFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every committed session parses, and every coverage session saves its map under a name no
    /// other session uses (the coverage report merges the `.cov` files by name).
    @Test func everySessionFileParses() throws {
        let files = try Self.sessionFiles()
        #expect(files.count >= 2)
        var saveNames: [String: String] = [:]
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let session = try Session.parse(text)
            #expect(!session.steps.isEmpty, "\(url.lastPathComponent) has no steps")
            let base = url.deletingPathExtension().lastPathComponent
            var saves: [String] = []
            for case .coverage(let command, let name) in session.steps where command == "save" { saves.append(name) }
            for name in saves {
                #expect(saveNames[name] == nil, "cov:save:\(name) in \(base) and \(saveNames[name] ?? "")")
                saveNames[name] = base
            }
            // The original prefixes have no coverage steps; every other session ends with its own map.
            if base != "regular" && base != "demo" {
                #expect(saves.last == (base == "idle" ? "idle" : base), "\(base) should end with cov:save:\(base)")
            }
        }
    }

    @Test func parsesTheNewSteps() throws {
        let s = try Session.parse("""
            # comment line
            down:CTRL+PLUS up:COLON nmi text peek:5A:C peek:$0ACF until:0901:4E:3000 until:0834:!00
            cov:on cov:off cov:save:name watch:084A:084F
            """)
        #expect(s.steps.count == 12)
        guard s.steps.count == 12 else { return }
        if case .keysDown(let k) = s.steps[0] { #expect(k == "CTRL+PLUS") } else { Issue.record("down") }
        if case .keysUp(let k) = s.steps[1] { #expect(k == "COLON") } else { Issue.record("up") }
        if case .nmi = s.steps[2] {} else { Issue.record("nmi") }
        if case .textScreen = s.steps[3] {} else { Issue.record("text") }
        if case .peek(let a, let n) = s.steps[4] { #expect(a == 0x5A && n == 12) } else { Issue.record("peek") }
        if case .peek(let a, let n) = s.steps[5] { #expect(a == 0x0ACF && n == 1) } else { Issue.record("peek $") }
        if case .waitByte(let a, let v, let neg, let f) = s.steps[6] {
            #expect(a == 0x0901 && v == 0x4E && !neg && f == 3000)
        } else { Issue.record("until") }
        if case .waitByte(let a, let v, let neg, let f) = s.steps[7] {
            #expect(a == 0x0834 && v == 0 && neg && f == 600)
        } else { Issue.record("until !") }
        if case .coverage(let c, _) = s.steps[8] { #expect(c == "on") } else { Issue.record("cov:on") }
        if case .coverage(let c, _) = s.steps[9] { #expect(c == "off") } else { Issue.record("cov:off") }
        if case .coverage(let c, let n) = s.steps[10] { #expect(c == "save" && n == "name") } else { Issue.record("cov:save") }
        if case .watch(let lo, let hi) = s.steps[11] { #expect(lo == 0x084A && hi == 0x084F) } else { Issue.record("watch") }
    }

    /// Malformed steps are parse errors, never traps or silently clamped values.
    @Test(arguments: [
        "until:10000:01", "until:-1:01", "until:0900:100", "until:0900", "until:0900:01:5:6", "until:0900:XY",
        "peek", "peek:10000", "peek:-5", "peek:0900:0", "peek:0900:ZZ", "peek:0900:1:2",
        "watch:0901:0900", "watch:0000:10000", "watch:0900",
        "cov", "cov:save", "cov:save:", "cov:start", "cov:on:x", "cov:off:x",
        "poke:10000:01", "poke:0900:100", "pc:10000", "pc:-1",
        "wait", "key", "shot", "snap", "joy1", "nmi:1", "text:1", "frob:1",
    ])
    func rejectsMalformedSteps(_ token: String) {
        #expect(throws: SessionError.self) { try Session.parse(token) }
    }

    @Test func keyNamesForTheSyntaxCharacters() {
        #expect(C64Key.named("PLUS") == .plus)
        #expect(C64Key.named("COLON") == .colon)
        #expect(C64Key.named("plus") == .plus)
        #expect(C64Key.named("CTRL") == .control)
        #expect(C64Key.named(";") == .semicolon)
        #expect(C64Key.named("NOPE") == nil)
    }

    @Test func screenCodesDecodeAsTheLowercaseSet() {
        let expected: [UInt8: String] = [
            0x00: "@", 0x01: "a", 0x1A: "z", 0x1B: "[", 0x1C: "£", 0x1D: "]", 0x1E: "↑", 0x1F: "←",
            0x20: " ", 0x21: "!", 0x2D: "-", 0x30: "0", 0x39: "9", 0x3E: ">", 0x3F: "?", 0x40: "-",
            0x41: "A", 0x5A: "Z", 0x5B: "?", 0x7F: "?", 0x81: "~a", 0xC1: "~A", 0xA0: "~ ",
        ]
        for (code, text) in expected {
            #expect(C64Machine.screenCodeText(code) == text, "screen code \(code)")
        }
        // No code decodes to a control character (which would garble a terminal).
        for code in 0...255 {
            let t = C64Machine.screenCodeText(UInt8(code))
            #expect(!t.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }, "screen code \(code)")
            #expect(t.count == (code >= 0x80 ? 2 : 1))
        }
    }

    @Test func textScreenReadsTheScreenTheVICShows() {
        let m = C64Machine(disk: [])
        m.bus.vicRegs[0x18] = 0x14                     // screen at $0400 in bank 0
        let hello: [UInt8] = [0x48, 0x45, 0x4C, 0x4C, 0x4F]
        for (i, c) in hello.enumerated() { m.bus.ram[0x0400 + i] = c }
        m.bus.ram[0x0428] = 0x01                       // row 1, column 0
        m.bus.ram[0x07E7] = 0x9A                       // row 24, column 39: reverse 'z'
        let lines = m.textScreen().split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 25)
        #expect(lines.first?.hasPrefix("HELLO@") == true)
        #expect(lines[1].hasPrefix("a@"))
        #expect(lines[24].hasSuffix("@~z"))
        m.bus.vicRegs[0x18] = 0x24                     // screen at $0800
        #expect(m.textScreen().hasPrefix("@@@@@"))
    }
}

/// `C64Machine.play` with the new steps, on a hand-made machine (no disk needed).
@Suite struct SessionPlayback {
    /// A machine running a small program at $1000 that switches the overlay end word at $A7E0
    /// one byte at a time:
    ///
    ///     $1000  low byte $6B     ($A800 flight -> $A86B: unknown, plane 5)
    ///     $1005  high byte $BC    (-> $BC6B editor, plane 1)
    ///     $100A  copies $2000 to $2001
    ///     $1010  low byte $EA     (-> $BCEA: unknown, plane 5)
    ///     $1015  high byte $B1    (-> $B1EA war, plane 2)
    ///     $101A  reads $2002
    ///     $101D  spins in place
    static func machine() -> C64Machine {
        let m = C64Machine(disk: [])
        let code: [UInt8] = [
            0xA9, 0x6B, 0x8D, 0xE0, 0xA7, 0xA9, 0xBC, 0x8D, 0xE1, 0xA7,
            0xAD, 0x00, 0x20, 0x8D, 0x01, 0x20,
            0xA9, 0xEA, 0x8D, 0xE0, 0xA7, 0xA9, 0xB1, 0x8D, 0xE1, 0xA7,
            0xAD, 0x02, 0x20, 0x4C, 0x1D, 0x10,
        ]
        for (i, b) in code.enumerated() { m.bus.ram[0x1000 + i] = b }
        m.bus.ram[0xA7E0] = 0x00; m.bus.ram[0xA7E1] = 0xA8
        m.bus.ram[0x2000] = 0x42
        m.cpu.pc = 0x1000
        m.cpu.sp = 0xFF
        m.cpu.interruptDisable = true
        return m
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fs2-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func coverageIsChargedToTheResidentOverlaysPlane() throws {
        let m = Self.machine()
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try m.play(try Session.parse("cov:on wait:1 cov:save:t"), screenshots: dir)
        let data = [UInt8](try Data(contentsOf: dir.appendingPathComponent("t.cov")))
        #expect(data.count == 6 * 0x10000)
        guard data.count == 6 * 0x10000 else { return }
        func flags(_ plane: Int, _ a: Int) -> UInt8 { data[plane * 0x10000 + a] }
        let x = Coverage.executed, r = Coverage.read, w = Coverage.written
        // Instruction starts, per plane (the plane is chosen before each instruction).
        let starts: [Int: [Int]] = [3: [0x1000, 0x1002], 5: [0x1005, 0x1007, 0x1015, 0x1017],
                                    1: [0x100A, 0x100D, 0x1010, 0x1012], 2: [0x101A, 0x101D]]
        for (plane, addrs) in starts {
            for a in addrs {
                for p in 0..<6 {
                    #expect((flags(p, a) & x != 0) == (p == plane), "start $\(String(a, radix: 16)) plane \(p)")
                }
            }
        }
        // Data accesses follow the same planes.
        #expect(flags(1, 0x2000) & r != 0 && flags(2, 0x2000) == 0)
        #expect(flags(1, 0x2001) & w != 0 && flags(2, 0x2001) == 0)
        #expect(flags(2, 0x2002) & r != 0 && flags(1, 0x2002) == 0)
        #expect(flags(3, 0xA7E0) & w != 0 && flags(5, 0xA7E1) & w != 0 && flags(1, 0xA7E0) & w != 0)
        #expect(flags(0, 0x1000) == 0 && flags(4, 0x1000) == 0)
        // The recorder detaches when the session ends.
        #expect(m.bus.accessMap == nil && m.onInstruction == nil)
    }

    @Test func coverageStepsAreIgnoredWithoutAnOutputDirectory() throws {
        let m = Self.machine()
        let cov = Coverage()
        cov.attach(to: m)                                   // as the `coverage` command does
        try m.play(try Session.parse("cov:on wait:1 cov:save:t cov:off"), screenshots: nil)
        #expect(m.bus.accessMap == cov.flags)
        #expect(cov.flags[0x101D] & Coverage.executed != 0)
        #expect(cov.flags[0x2002] & Coverage.read != 0)
    }

    @Test func untilWaitsForAByteOrTheFrameLimit() throws {
        let m = Self.machine()
        try m.play(try Session.parse("until:2001:42:5"), screenshots: nil)
        #expect(m.frameCount == 0 && m.bus.ram[0x2001] == 0x42)
        try m.play(try Session.parse("until:2003:05:3"), screenshots: nil)
        #expect(m.frameCount == 3)
        try m.play(try Session.parse("poke:2003:07 until:2003:!07:2"), screenshots: nil)
        #expect(m.frameCount == 5)
        try m.play(try Session.parse("until:2003:!00:2"), screenshots: nil)
        #expect(m.frameCount == 5)
    }

    @Test func keysCanBeHeldAcrossSteps() throws {
        let m = Self.machine()
        try m.play(try Session.parse("down:CTRL+PLUS wait:1"), screenshots: nil)
        #expect(m.keyboard.isPressed(.control) && m.keyboard.isPressed(.plus))
        try m.play(try Session.parse("up:PLUS key:COLON:1"), screenshots: nil)
        #expect(m.keyboard.isPressed(.control) && !m.keyboard.isPressed(.plus) && !m.keyboard.isPressed(.colon))
        #expect(throws: LabError.self) { try m.play(try Session.parse("down:NOPE"), screenshots: nil) }
        try m.play(try Session.parse("nmi"), screenshots: nil)
        #expect(m.cpu.nmiPending)
    }

    /// The bus has one access map, so a watch and coverage recording refuse to share it.
    @Test func watchAndCoverageDoNotShareTheAccessMap() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Self.machine()
        #expect(throws: LabError.self) { try a.play(try Session.parse("cov:on watch:2000:2000"), screenshots: dir) }
        let b = Self.machine()
        #expect(throws: LabError.self) { try b.play(try Session.parse("watch:2000:2000 cov:on"), screenshots: dir) }
        let c = Self.machine()
        Coverage().attach(to: c)
        #expect(throws: LabError.self) { try c.play(try Session.parse("watch:2000:2000"), screenshots: nil) }
        let d = Self.machine()
        try d.play(try Session.parse("watch:2000:2002 wait:1"), screenshots: nil)
        #expect(d.bus.accessMap != nil)
    }
}
