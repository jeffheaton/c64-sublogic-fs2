#if !os(WASI)
import Foundation
#endif

/// A Commodore 1541 disk image (.d64): 35 or 40 tracks of 256-byte sectors, optionally followed by error bytes.
public struct D64Image: Sendable {
    public enum Error: Swift.Error, CustomStringConvertible {
        case badSize(Int)
        case badSector(track: Int, sector: Int)

        public var description: String {
            switch self {
            case .badSize(let n): return "not a .d64 disk image (unexpected size \(n) bytes)"
            case .badSector(let t, let s): return "track \(t) sector \(s) is outside the disk image"
            }
        }
    }

    /// Sectors per track for tracks 1...40 (index 0 = track 1).
    public static let sectorsPerTrack: [Int] =
        Array(repeating: 21, count: 17) + Array(repeating: 19, count: 7) +
        Array(repeating: 18, count: 6) + Array(repeating: 17, count: 10)

    public let bytes: [UInt8]
    public let trackCount: Int

    public init(data: [UInt8]) throws {
        switch data.count {
        case 174_848, 175_531: trackCount = 35
        case 196_608, 197_376: trackCount = 40
        default: throw Error.badSize(data.count)
        }
        bytes = data
    }

    #if !os(WASI)
    public init(contentsOf url: URL) throws {
        try self.init(data: [UInt8](try Data(contentsOf: url)))
    }
    #endif

    public static func sectorCount(track: Int) -> Int { sectorsPerTrack[track - 1] }

    /// Byte offset of a sector in the image.
    public static func offset(track: Int, sector: Int) -> Int {
        (sectorsPerTrack[0..<(track - 1)].reduce(0, +) + sector) * 256
    }

    public func sector(track: Int, sector: Int) throws -> ArraySlice<UInt8> {
        guard track >= 1, track <= trackCount, sector >= 0, sector < Self.sectorCount(track: track) else {
            throw Error.badSector(track: track, sector: sector)
        }
        let o = Self.offset(track: track, sector: sector)
        return bytes[o..<(o + 256)]
    }
}
