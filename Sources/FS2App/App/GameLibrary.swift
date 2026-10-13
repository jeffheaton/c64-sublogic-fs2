import C64Kit
import FS2Core
import FS2Data
import Foundation

/// The user's game files in ~/Library/Application Support/FS2/: the imported disk image and the
/// optional character ROM. The app ships no SubLogic data; everything comes from here.
enum GameLibrary {
    /// The checks a disk image goes through before it is imported, in order. The first one that
    /// fails stops the import, and the alert names it in plain words.
    enum DiskCheck: Int, CaseIterable, Sendable {
        /// The file exists and can be read.
        case opens
        /// Its size is one of a .d64 image's (35 or 40 tracks, with or without error bytes).
        case isDiskImage
        /// Every one of SubLogic's 164 logical blocks matches the release this port was made from
        /// (SHA-256 per block, with the bytes a crack may have changed masked out, so a clean copy
        /// and a modified one both pass; `SubLogicDisk.mismatchedBlocks`).
        case isFlightSimulatorII

        /// The check, in plain words.
        var title: String {
            switch self {
            case .opens: return "The file can be opened"
            case .isDiskImage: return "It is a .d64 disk image"
            case .isFlightSimulatorII: return "It is Flight Simulator II version 1.0 for the Commodore 64"
            }
        }
    }

    /// The .d64 sizes `D64Image` accepts: 35 or 40 tracks, each with or without the error bytes.
    static let diskImageSizes = [174_848, 175_531, 196_608, 197_376]

    enum ImportError: Error, LocalizedError, Equatable {
        /// The file could not be read at all (missing, no permission, a folder).
        case cannotOpen(file: String, reason: String)
        /// The size is not a .d64 image's.
        case notADiskImage(file: String, size: Int)
        /// A .d64 image whose blocks differ from Flight Simulator II v1.0's.
        case notFlightSimulatorII(file: String, mismatchedBlocks: Int)
        case wrongCharROMSize(Int)
        case wrongModeLibrarySize(Int)
        case noModeLibrary

        /// The disk check that failed (nil for the other imports).
        var failedCheck: DiskCheck? {
            switch self {
            case .cannotOpen: return .opens
            case .notADiskImage: return .isDiskImage
            case .notFlightSimulatorII: return .isFlightSimulatorII
            case .wrongCharROMSize, .wrongModeLibrarySize, .noModeLibrary: return nil
            }
        }

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let file, let reason):
                return "“\(file)” could not be opened: \(reason)."
            case .notADiskImage(let file, let size):
                if size == 0 { return "“\(file)” is empty, so it cannot be a disk image." }
                return "“\(file)” is not a .d64 disk image. It is \(GameLibrary.bytes(size)); a .d64 image of a "
                    + "Commodore 1541 disk is \(GameLibrary.bytes(174_848)) (\(GameLibrary.bytes(175_531)) with "
                    + "error information, or \(GameLibrary.bytes(196_608)) / \(GameLibrary.bytes(197_376)) "
                    + "for 40 tracks)."
            case .notFlightSimulatorII(let file, let n):
                let total = SubLogicDisk.blockCount
                if n * 2 > total {
                    return "“\(file)” is a disk image, but not of Flight Simulator II: \(n) of its \(total) "
                        + "program blocks do not match the game."
                }
                return "“\(file)” looks like Flight Simulator II, but \(n) of its \(total) program blocks "
                    + (n == 1 ? "differs" : "differ") + " from version 1.0, the release this port was made from."
            case .wrongCharROMSize(let n):
                return "A Commodore 64 character ROM is exactly \(GameLibrary.bytes(4096)); this file is \(GameLibrary.bytes(n))."
            case .wrongModeLibrarySize(let n):
                return "A mode library is exactly \(GameLibrary.bytes(GameLibrary.modeLibrarySize)) (one disk "
                    + "block); this file is \(GameLibrary.bytes(n))."
            case .noModeLibrary:
                return "No mode library has been saved yet."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .cannotOpen:
                return "Check that the file is still there and that you can read it, then choose it again."
            case .notADiskImage:
                return "Choose the .d64 file itself. If it is inside a .zip archive, unpack it first; other "
                    + "formats such as .g64, .t64 or .prg are not supported."
            case .notFlightSimulatorII(_, let n):
                if n * 2 > SubLogicDisk.blockCount {
                    return "Choose your disk image of Flight Simulator II version 1.0 for the Commodore 64 "
                        + "(NTSC, 1984)."
                }
                return "The image may be damaged or modified, or come from another release (other versions and "
                    + "PAL releases are not supported). Try another image of your version 1.0 disk."
            case .wrongCharROMSize:
                return "Use a dump of the character ROM from your own C64 (the 4,096-byte “chargen” file)."
            case .wrongModeLibrarySize:
                return "Choose a ModeLibrary.bin file saved by this app (Control-Z in the editor, or File ▸ "
                    + "Export Mode Library)."
            case .noModeLibrary:
                return "In the game's editor (E), Control-Z saves your user modes to the library."
            }
        }

        /// The disk checks, each marked passed (✓), failed (✗) or not reached (–); nil when this is
        /// not a disk error.
        var checklist: String? {
            guard let failed = failedCheck else { return nil }
            return DiskCheck.allCases.map { check in
                let mark = check.rawValue < failed.rawValue ? "✓" : check == failed ? "✗" : "–"
                return "\(mark) \(check.title)"
            }.joined(separator: "\n")
        }
    }

    /// "174,848 bytes".
    static func bytes(_ n: Int) -> String {
        n == 1 ? "1 byte" : "\(n.formatted(.number.locale(Locale(identifier: "en_US")))) bytes"
    }

    static var diskURL: URL { GameData.importedDiskURL }
    static var charROMURL: URL { GameData.importedCharROMURL }

    static var hasImportedDisk: Bool { FileManager.default.fileExists(atPath: diskURL.path) }
    static var hasCharROM: Bool { FileManager.default.fileExists(atPath: charROMURL.path) }

    /// Loads the imported game data, checked again, with the character ROM when one was imported
    /// (an unreadable or wrong-size ROM is ignored: the text screens use the fallback font).
    static func load() throws -> GameData {
        let rom = hasCharROM ? (try? Data(contentsOf: charROMURL)).map { [UInt8]($0) } : nil
        return try validateDisk(at: diskURL, charROM: rom)
    }

    /// Runs the disk checks on `url` and returns its game data, without copying anything. Throws an
    /// `ImportError` that names the first check that failed.
    static func validateDisk(at url: URL, charROM: [UInt8]? = nil) throws -> GameData {
        let file = url.lastPathComponent
        let bytes = [UInt8](try readFile(url, sizes: diskImageSizes) {
            ImportError.notADiskImage(file: file, size: $0)
        })
        let image: D64Image
        do {
            image = try D64Image(data: bytes)
        } catch {
            throw ImportError.notADiskImage(file: file, size: bytes.count)
        }
        do {
            return try GameData(d64: image, charROM: charROM)
        } catch GameData.Error.notFlightSimulatorII(let mismatched) {
            throw ImportError.notFlightSimulatorII(file: file, mismatchedBlocks: mismatched.count)
        } catch {
            // SubLogicDisk reads only tracks 1-35, which every accepted size has; kept for safety.
            throw ImportError.notFlightSimulatorII(file: file, mismatchedBlocks: SubLogicDisk.blockCount)
        }
    }

    /// The reason a file could not be read, in plain words ("no such file or directory").
    static func reason(_ error: Error) -> String {
        let ns = error as NSError
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            let text = String(cString: strerror(Int32(posix.code)))
            return text.prefix(1).lowercased() + String(text.dropFirst())
        }
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError): return "there is no such file"
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError): return "you do not have permission to read it"
        default: return ns.localizedFailureReason ?? ns.localizedDescription
        }
    }

    /// Validates `url` and copies it into Application Support (replacing an earlier import).
    /// Nothing is written when a check fails.
    @discardableResult
    static func importDisk(from url: URL, to destination: URL = GameLibrary.diskURL) throws -> GameData {
        let data = try validateDisk(at: url)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(data.d64.bytes).write(to: destination, options: .atomic)
        return data
    }

    /// Checks and copies a 4096-byte character ROM (used only by the text-mode screens).
    static func importCharROM(from url: URL, to destination: URL = GameLibrary.charROMURL) throws {
        let bytes = try readFile(url, sizes: [4096]) { ImportError.wrongCharROMSize($0) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .atomic)
    }

    /// Reads a file the user chose, when its size is one of `sizes`. Throws `cannotOpen` when it
    /// is a folder or cannot be opened or read, and `wrongSize(size)` for any other size, without
    /// reading it: a large file chosen by mistake is never loaded into memory.
    static func readFile(_ url: URL, sizes: [Int], wrongSize: (Int) -> ImportError) throws -> Data {
        let file = url.lastPathComponent
        // A folder (or a package such as an .app, which an open panel shows as a file).
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            throw ImportError.cannotOpen(file: file, reason: "it is a folder, not a file")
        }
        let handle: FileHandle
        let size: UInt64
        do {
            handle = try FileHandle(forReadingFrom: url)
            size = try handle.seekToEnd()
        } catch {
            throw ImportError.cannotOpen(file: file, reason: reason(error))
        }
        defer { try? handle.close() }
        guard sizes.contains(Int(clamping: size)) else { throw wrongSize(Int(clamping: size)) }
        do {
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            // The file changed size between the two calls.
            guard data.count == Int(size) else { throw wrongSize(data.count) }
            return data
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.cannotOpen(file: file, reason: reason(error))
        }
    }

    // MARK: User mode library

    /// User modes 10-24 live in one 1 KB block, as the original keeps them on its library disk
    /// (block 64). The native engine reads and writes the same file (`ModeLibraryFile`) when the
    /// editor's CTRL-X / CTRL-Z run.
    static let modeLibrarySize = ModeLibraryFile.size
    static var modeLibraryURL: URL { ModeLibraryFile.standardURL }

    /// The previous library, kept whenever the library is replaced.
    static func backupURL(for url: URL) -> URL { ModeLibraryFile(url: url).backupURL }

    /// Writes the library (keeping the previous one as a backup), as CTRL-Z does; imports go
    /// through it too.
    static func saveModeLibrary(_ bytes: [UInt8], to url: URL = GameLibrary.modeLibraryURL) throws {
        guard bytes.count == modeLibrarySize else { throw ImportError.wrongModeLibrarySize(bytes.count) }
        try ModeLibraryFile(url: url).save(bytes)
    }

    /// The saved library, if there is one.
    static func loadModeLibrary(from url: URL = GameLibrary.modeLibraryURL) throws -> [UInt8]? {
        do {
            return try ModeLibraryFile(url: url).load()
        } catch ModeLibraryFile.Error.wrongSize(let n) {
            throw ImportError.wrongModeLibrarySize(n)
        }
    }

    static func importModeLibrary(from source: URL, to url: URL = GameLibrary.modeLibraryURL) throws {
        let bytes = try readFile(source, sizes: [modeLibrarySize]) { ImportError.wrongModeLibrarySize($0) }
        try saveModeLibrary([UInt8](bytes), to: url)
    }

    static func exportModeLibrary(to destination: URL, from url: URL = GameLibrary.modeLibraryURL) throws {
        guard let bytes = try loadModeLibrary(from: url) else { throw ImportError.noModeLibrary }
        try Data(bytes).write(to: destination, options: .atomic)
    }

    /// The disk for tools and headless runs: an explicit path, then $FS2_D64, then the import.
    static func locateDisk(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> URL? {
        if let explicit { return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath) }
        if let p = environment["FS2_D64"], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return hasImportedDisk ? diskURL : nil
    }
}
