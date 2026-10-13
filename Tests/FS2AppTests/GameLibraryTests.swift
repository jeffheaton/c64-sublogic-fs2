import C64Kit
@testable import FS2App
import FS2Data
import Foundation
import Testing

@Suite struct GameLibraryTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FS2AppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs the disk checks and returns the error they throw (nil when the image passes).
    private func check(_ url: URL) -> GameLibrary.ImportError? {
        do {
            _ = try GameLibrary.validateDisk(at: url)
            return nil
        } catch let e as GameLibrary.ImportError {
            return e
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    // MARK: The disk checks, failing one by one

    @Test func aMissingFileFailsTheFirstCheck() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = check(dir.appendingPathComponent("gone.d64"))
        #expect(e == .cannotOpen(file: "gone.d64", reason: "no such file or directory"))
        #expect(e?.failedCheck == .opens)
        #expect(e?.errorDescription == "“gone.d64” could not be opened: no such file or directory.")
        #expect(e?.checklist == """
            ✗ The file can be opened
            – It is a .d64 disk image
            – It is Flight Simulator II version 1.0 for the Commodore 64
            """)
        // A folder (or a package such as an .app, which the open panel shows as a file) is not a file.
        #expect(check(dir) == .cannotOpen(file: dir.lastPathComponent, reason: "it is a folder, not a file"))
        let package = dir.appendingPathComponent("Some.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(check(package)?.failedCheck == .opens)
    }

    @Test func anUnreadableFileFailsTheFirstCheck() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let locked = dir.appendingPathComponent("locked.d64")
        try Data(repeating: 0, count: 174_848).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        guard (try? Data(contentsOf: locked)) == nil else { return }   // running as root: nothing to test
        let e = check(locked)
        #expect(e?.failedCheck == .opens)
        #expect(e?.errorDescription?.contains("permission") == true, "\(e?.errorDescription ?? "")")
        // The first check comes first: an unreadable file of the wrong size fails it too, not the size check.
        let lockedSmall = dir.appendingPathComponent("small.d64")
        try Data(repeating: 0, count: 1000).write(to: lockedSmall)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedSmall.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedSmall.path) }
        #expect(check(lockedSmall)?.failedCheck == .opens)
    }

    /// A large file chosen by mistake fails the size check from its size alone, without being read
    /// into memory: a sparse file of more than 2 GB (no disk space used, and checked at once). The
    /// same holds for the character ROM and mode library imports, and nothing is written.
    @Test func aLargeFileIsRejectedWithoutReadingIt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("movie.d64")
        let size = (1 << 31) + 174_848
        try Data().write(to: big)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let e = check(big)
        #expect(e == .notADiskImage(file: "movie.d64", size: size))
        #expect(e?.errorDescription?.contains("It is 2,147,658,496 bytes") == true, "\(e?.errorDescription ?? "")")
        #expect(throws: GameLibrary.ImportError.wrongCharROMSize(size)) {
            try GameLibrary.importCharROM(from: big, to: dir.appendingPathComponent("chargen.rom"))
        }
        #expect(throws: GameLibrary.ImportError.wrongModeLibrarySize(size)) {
            try GameLibrary.importModeLibrary(from: big, to: dir.appendingPathComponent("ModeLibrary.bin"))
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("chargen.rom").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("ModeLibrary.bin").path))
    }

    @Test func aFileOfTheWrongSizeFailsTheSecondCheck() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("empty.d64"), small = dir.appendingPathComponent("game.prg")
        try Data().write(to: empty)
        try Data(repeating: 0, count: 1000).write(to: small)
        #expect(check(empty) == .notADiskImage(file: "empty.d64", size: 0))
        #expect(check(empty)?.errorDescription == "“empty.d64” is empty, so it cannot be a disk image.")
        let e = check(small)
        #expect(e == .notADiskImage(file: "game.prg", size: 1000))
        #expect(e?.failedCheck == .isDiskImage)
        #expect(e?.errorDescription?.contains("It is 1,000 bytes; a .d64 image of a Commodore 1541 disk is 174,848 bytes")
                == true)
        #expect(e?.recoverySuggestion?.contains(".zip") == true)
        #expect(e?.checklist == """
            ✓ The file can be opened
            ✗ It is a .d64 disk image
            – It is Flight Simulator II version 1.0 for the Commodore 64
            """)
        // One byte off a valid size is not a disk image either.
        let off = dir.appendingPathComponent("off.d64")
        try Data(repeating: 0, count: 174_849).write(to: off)
        #expect(check(off)?.failedCheck == .isDiskImage)
    }

    /// Each of the four .d64 sizes passes the size check and reaches the content check.
    @Test func everyDiskImageSizeReachesTheContentCheck() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for size in GameLibrary.diskImageSizes {
            let url = dir.appendingPathComponent("blank-\(size).d64")
            try Data(repeating: 0, count: size).write(to: url)
            #expect(check(url)?.failedCheck == .isFlightSimulatorII, "\(size)")
        }
    }

    @Test func anotherDiskFailsTheThirdCheck() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blank = dir.appendingPathComponent("blank.d64")
        try Data(repeating: 0, count: 174_848).write(to: blank)
        let e = try #require(check(blank))
        guard case .notFlightSimulatorII(let file, let n) = e else {
            Issue.record("expected the content check to fail, got \(e)")
            return
        }
        #expect(file == "blank.d64" && n > SubLogicDisk.blockCount / 2 && n < SubLogicDisk.blockCount)
        #expect(e.errorDescription?.contains("is a disk image, but not of Flight Simulator II") == true)
        #expect(e.recoverySuggestion?.contains("version 1.0") == true)
        #expect(e.checklist == """
            ✓ The file can be opened
            ✓ It is a .d64 disk image
            ✗ It is Flight Simulator II version 1.0 for the Commodore 64
            """)
        // A failed import writes nothing.
        let out = dir.appendingPathComponent("out.d64")
        #expect(throws: GameLibrary.ImportError.self) { try GameLibrary.importDisk(from: blank, to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// A few differing blocks read as a damaged or modified copy, not as another disk.
    @Test func aDamagedCopyIsToldApartFromAnotherDisk() {
        let damaged = GameLibrary.ImportError.notFlightSimulatorII(file: "fs2.d64", mismatchedBlocks: 2)
        #expect(damaged.errorDescription
                == "“fs2.d64” looks like Flight Simulator II, but 2 of its 164 program blocks differ from version 1.0, "
                + "the release this port was made from.")
        #expect(damaged.recoverySuggestion?.contains("damaged or modified") == true)
        let other = GameLibrary.ImportError.notFlightSimulatorII(file: "x.d64", mismatchedBlocks: 140)
        #expect(other.errorDescription?.contains("not of Flight Simulator II: 140 of its 164") == true)
    }

    /// The alert text: what went wrong, the checks, what to do (or the caller's advice instead).
    @Test func alertTextNamesTheFailedCheck() {
        let e = GameLibrary.ImportError.notADiskImage(file: "a.t64", size: 2000)
        let text = FirstRun.errorDetails(e)
        #expect(text == [e.errorDescription!, e.checklist!, e.recoverySuggestion!].joined(separator: "\n\n"))
        let advised = FirstRun.errorDetails(e, advice: FirstRun.importedCopyAdvice)
        #expect(advised.hasSuffix("\n\n" + FirstRun.importedCopyAdvice) && !advised.contains(e.recoverySuggestion!))
        // Other imports have no disk checklist.
        #expect(GameLibrary.ImportError.wrongCharROMSize(1).checklist == nil)
        #expect(FirstRun.errorDetails(GameLibrary.ImportError.noModeLibrary).contains("Control-Z"))
    }

    @Test func firstRunCopyNamesTheFileToChoose() {
        for text in [FirstRun.welcomeText, FirstRun.panelMessage] {
            #expect(text.contains(".d64") && text.contains("1.0") && text.contains("Flight Simulator II"))
        }
        #expect(FirstRun.welcomeText.contains("~/Library/Application Support/FS2/"))
        #expect(FirstRun.welcomeText.contains("NTSC"))
        #expect(FirstRun.welcomeText.contains("a complete copy of version 1.0"))
        // The welcome says up front that the port is unofficial.
        #expect(FirstRun.welcomeText.contains("unofficial port, not affiliated with or endorsed by the rights holders"))
    }

    /// Where to get a character ROM: a dump of the user's own C64, nothing else.
    @Test func characterROMAdviceNamesTheUsersOwnC64() throws {
        let advice = try #require(GameLibrary.ImportError.wrongCharROMSize(1).recoverySuggestion)
        #expect(advice.contains("from your own C64"))
        #expect(!advice.contains("VICE"))
    }

    // MARK: The real disk

    /// The user's disk image: $FS2_D64, else the app's import
    /// (~/Library/Application Support/FS2/FlightSimulatorII.d64).
    private static var realDisk: URL? {
        let candidates = [ProcessInfo.processInfo.environment["FS2_D64"].map { URL(fileURLWithPath: $0) },
                          GameData.importedDiskURL]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test(.enabled(if: realDisk != nil, "needs the Flight Simulator II disk image"))
    func importsTheRealDisk() throws {
        let source = try #require(Self.realDisk)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(check(source) == nil)
        let dest = dir.appendingPathComponent("FS2/FlightSimulatorII.d64")
        let data = try GameLibrary.importDisk(from: source, to: dest)
        #expect(try Data(contentsOf: dest) == Data(data.d64.bytes))
    }

    /// The good image in its other accepted forms, a changed directory (not checked) and one changed
    /// program byte (caught, and reported as a damaged copy).
    @Test(.enabled(if: realDisk != nil, "needs the Flight Simulator II disk image"))
    func variantsOfTheRealDisk() throws {
        let source = try #require(Self.realDisk)
        let bytes = try Data(contentsOf: source)
        try #require(bytes.count == 174_848)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        func variant(_ name: String, _ data: Data) throws -> GameLibrary.ImportError? {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return check(url)
        }
        // With the error bytes, and as a 40-track image.
        #expect(try variant("errors.d64", bytes + Data(repeating: 1, count: 683)) == nil)
        #expect(try variant("forty.d64", bytes + Data(repeating: 0, count: 196_608 - 174_848)) == nil)
        // The BAM and directory (track 18, sectors 0-5) are not part of the game's blocks.
        var renamed = bytes
        renamed[D64Image.offset(track: 18, sector: 0) + 0x90] ^= 0xFF
        #expect(try variant("renamed.d64", renamed) == nil)
        // One changed byte in the first program block.
        var damaged = bytes
        damaged[D64Image.offset(track: 1, sector: 0) + 100] ^= 0x01
        #expect(try variant("damaged.d64", damaged) == .notFlightSimulatorII(file: "damaged.d64", mismatchedBlocks: 1))
        // A copy with other bytes where a crack writes (`SubLogicDisk.crackModifiedBytes`), as a clean
        // copy may have: accepted. One more byte right after a masked range: caught.
        func fileOffset(block: Int, offset: Int) -> Int {
            let (track, sector) = SubLogicDisk.usedSectors[block * 4 + offset / 256]
            return D64Image.offset(track: track, sector: sector) + offset % 256
        }
        // Letters counted on through all the ranges, so the two tag slots differ (not a crack's tag).
        var clean = bytes, i = 0
        for (block, offsets) in SubLogicDisk.crackModifiedBytes {
            for o in offsets {
                clean[fileOffset(block: block, offset: o)] = UInt8(0x41 + i % 26)
                i += 1
            }
        }
        #expect(try variant("clean.d64", clean) == nil)
        let (block, offsets) = SubLogicDisk.crackModifiedBytes[1]
        clean[fileOffset(block: block, offset: offsets.upperBound + 1)] ^= 0x01
        let error = try variant("clean-damaged.d64", clean)
        #expect(error == .notFlightSimulatorII(file: "clean-damaged.d64", mismatchedBlocks: 1))
        #expect(error?.errorDescription == "“clean-damaged.d64” looks like Flight Simulator II, but 1 of its 164 "
                + "program blocks differs from version 1.0, the release this port was made from.")
    }

    // MARK: Character ROM and mode library

    @Test func characterROMMustBe4096Bytes() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.rom"), good = dir.appendingPathComponent("good.rom")
        try Data(repeating: 1, count: 2048).write(to: bad)
        try Data(repeating: 2, count: 4096).write(to: good)
        let dest = dir.appendingPathComponent("chargen.rom")
        #expect(throws: GameLibrary.ImportError.wrongCharROMSize(2048)) { try GameLibrary.importCharROM(from: bad, to: dest) }
        #expect(GameLibrary.ImportError.wrongCharROMSize(2048).errorDescription
                == "A Commodore 64 character ROM is exactly 4,096 bytes; this file is 2,048 bytes.")
        #expect(throws: GameLibrary.ImportError.self) {
            try GameLibrary.importCharROM(from: dir.appendingPathComponent("none.rom"), to: dest)
        }
        try GameLibrary.importCharROM(from: good, to: dest)
        #expect(try Data(contentsOf: dest).count == 4096)
    }

    @Test func modeLibraryKeepsABackup() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = dir.appendingPathComponent("ModeLibrary.bin")
        #expect(try GameLibrary.loadModeLibrary(from: lib) == nil)
        #expect(throws: GameLibrary.ImportError.noModeLibrary) {
            try GameLibrary.exportModeLibrary(to: dir.appendingPathComponent("x.bin"), from: lib)
        }
        let first = [UInt8](repeating: 1, count: 1024), second = [UInt8](repeating: 2, count: 1024)
        try GameLibrary.saveModeLibrary(first, to: lib)
        try GameLibrary.saveModeLibrary(second, to: lib)
        #expect(try GameLibrary.loadModeLibrary(from: lib) == second)
        #expect([UInt8](try Data(contentsOf: GameLibrary.backupURL(for: lib))) == first)
        #expect(throws: GameLibrary.ImportError.wrongModeLibrarySize(1)) { try GameLibrary.saveModeLibrary([0], to: lib) }
        let exported = dir.appendingPathComponent("export.bin")
        try GameLibrary.exportModeLibrary(to: exported, from: lib)
        try GameLibrary.importModeLibrary(from: exported, to: dir.appendingPathComponent("other.bin"))
        #expect(try GameLibrary.loadModeLibrary(from: dir.appendingPathComponent("other.bin")) == second)
        #expect(throws: GameLibrary.ImportError.cannotOpen(file: "missing.bin", reason: "no such file or directory")) {
            try GameLibrary.importModeLibrary(from: dir.appendingPathComponent("missing.bin"), to: lib)
        }
    }

    @Test func diskLookupOrder() {
        #expect(GameLibrary.locateDisk(explicit: "/a/b.d64", environment: ["FS2_D64": "/c.d64"])?.path == "/a/b.d64")
        #expect(GameLibrary.locateDisk(explicit: nil, environment: ["FS2_D64": "/c.d64"])?.path == "/c.d64")
    }
}
