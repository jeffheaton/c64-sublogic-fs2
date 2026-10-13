import FS2Data
import Foundation

/// The mode library on the Mac: user modes 10-24 as the 1 KB image of the library disk's logical
/// block 64, kept in `~/Library/Application Support/FS2/ModeLibrary.bin`.
///
/// The original keeps the library on a separate FS2-formatted disk: CTRL-X (in the editor) reads
/// block 64 into `[$0961]` ($C800), CTRL-Z formats that disk and writes the block. The port's editor
/// hands both requests to `Machine.modeLibraryIO` (`ModeLibrary.IO`); `io` maps them to this file:
///
/// - **load** (CTRL-X): the file's 1024 bytes, or nil when there is no file or it is not exactly
///   1024 bytes long (the editor then shows its disk-error line, as with no library disk).
/// - **formatAndSave** (CTRL-Z): replaces the file with the 1024-byte block. The previous file is
///   first copied to `ModeLibrary.bak` (one generation of backup); the new file is written
///   atomically. Returns false when it cannot be written (the editor's disk-error line).
///
/// The app's File ▸ Import / Export Mode Library go through `save` / `load` too. Both sides may run
/// on different threads (the game thread for CTRL-X/CTRL-Z, the main thread for the menu); the
/// atomic write means a reader sees either the old or the new library, never a mix.
public struct ModeLibraryFile: Sendable {
    /// One logical block.
    public static let size = ModeLibrary.blockSize
    /// The file the app uses.
    public static var standardURL: URL { GameData.supportDirectory.appendingPathComponent("ModeLibrary.bin") }
    /// The library in Application Support.
    public static var standard: ModeLibraryFile { ModeLibraryFile(url: standardURL) }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// A library is exactly one 1024-byte block.
        case wrongSize(Int)

        public var description: String {
            switch self {
            case .wrongSize(let n): return "a mode library is exactly \(ModeLibraryFile.size) bytes, not \(n)"
            }
        }
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    /// Where the previous library is kept whenever the library is replaced.
    public var backupURL: URL { url.deletingPathExtension().appendingPathExtension("bak") }

    /// Whether a library file exists.
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The saved library, nil when there is none. Throws when the file cannot be read or has the
    /// wrong size.
    public func load() throws -> [UInt8]? {
        guard exists else { return nil }
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count == Self.size else { throw Error.wrongSize(bytes.count) }
        return bytes
    }

    /// Replaces the library with `bytes` (1024 of them), keeping the previous file as the backup.
    public func save(_ bytes: [UInt8]) throws {
        guard bytes.count == Self.size else { throw Error.wrongSize(bytes.count) }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backupURL)
            try fm.copyItem(at: url, to: backupURL)
        }
        try Data(bytes).write(to: url, options: .atomic)
    }

    /// The hook the editor's CTRL-X / CTRL-Z use (`Machine.modeLibraryIO`).
    public var io: ModeLibrary.IO {
        let file = self
        return ModeLibrary.IO(load: { try? file.load() },
                              formatAndSave: { bytes in (try? file.save(bytes)) != nil })
    }
}
