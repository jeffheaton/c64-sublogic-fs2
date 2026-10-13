import C64Kit
import Foundation

/// Everything the port needs from the user's disk, built from a .d64 at launch.
public struct GameData: Sendable {
    public enum Error: Swift.Error, CustomStringConvertible {
        case notFlightSimulatorII(mismatched: [Int])

        public var description: String {
            switch self {
            case .notFlightSimulatorII(let m):
                let names = m.prefix(8).map(String.init).joined(separator: ", ") + (m.count > 8 ? ", …" : "")
                let what = m.count == 1 ? "block \(names) differs" : "blocks \(names) differ"
                return "this disk does not match Flight Simulator II v1.0: \(what) "
                    + "(\(m.count) of \(SubLogicDisk.blockCount))"
            }
        }
    }

    public let d64: D64Image
    public let disk: SubLogicDisk
    /// Memory as SubLogic's boot leaves it before the init chain (the crack's bytes scrubbed when
    /// the disk has them; `ColdImage.scrubCrack`).
    public let coldMemory: [UInt8]
    /// Optional 4 KB C64 character ROM (not on the game disk; used only by text-mode screens).
    public let charROM: [UInt8]?

    public init(d64: D64Image, charROM: [UInt8]? = nil, validate: Bool = true) throws {
        let disk = try SubLogicDisk(d64)
        if validate {
            let bad = disk.mismatchedBlocks()
            if !bad.isEmpty { throw Error.notFlightSimulatorII(mismatched: bad) }
        }
        self.d64 = d64
        self.disk = disk
        coldMemory = ColdImage.memory(from: disk)
        self.charROM = charROM?.count == 4096 ? charROM : nil
    }

    public init(d64URL: URL, charROMURL: URL? = nil) throws {
        let rom = try charROMURL.map { [UInt8](try Data(contentsOf: $0)) }
        try self.init(d64: try D64Image(contentsOf: d64URL), charROM: rom)
    }

    public func overlay(_ o: FS2Layout.Overlay) -> [UInt8] { ColdImage.overlay(o, from: disk) }

    /// Where the app keeps the imported disk: ~/Library/Application Support/FS2/.
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FS2", isDirectory: true)
    }

    public static var importedDiskURL: URL { supportDirectory.appendingPathComponent("FlightSimulatorII.d64") }
    public static var importedCharROMURL: URL { supportDirectory.appendingPathComponent("chargen.rom") }
}
