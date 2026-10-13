/// Where SubLogic's boot puts things in memory, and the overlay table at $E559.
public enum FS2Layout {
    public struct Load: Sendable {
        public let block: Int, count: Int, address: Int
    }

    /// Stage-2 system/disk layer (track 1 sectors 0-7), resident at $7300.
    public static let stage2 = Load(block: 0, count: 2, address: 0x7300)
    /// Stage-3 cold-start overlay (overlay 0) at $A7E0: init code, title records, zero-page image.
    public static let stage3 = Load(block: 2, count: 3, address: 0xA7E0)
    /// The loads stage 3 performs at $A988, in order.
    public static let bootLoads: [Load] = [
        Load(block: 0x0A, count: 16, address: 0x0200),
        Load(block: 0x06, count: 4, address: 0x5000),
        Load(block: 0x1A, count: 12, address: 0x77E0),
        Load(block: 0x26, count: 4, address: 0xC000),
        Load(block: 0x96, count: 8, address: 0xE000),
    ]
    /// Stage 3 copies $AC02-$ACFF to zero page $02-$FF ($ABB0).
    public static let zeroPageImage = 0xAC02

    /// Overlays, loaded at $A7E0 by the manager at $E5F6 (table at $E559).
    public enum Overlay: Int, CaseIterable, Sendable {
        case coldStart = 0, editor, war, flight, databaseInfo

        public var load: Load {
            switch self {
            case .coldStart: return Load(block: 0x02, count: 3, address: overlayBase)
            case .editor: return Load(block: 0x2A, count: 6, address: overlayBase)
            case .war: return Load(block: 0x9E, count: 3, address: overlayBase)
            case .flight: return Load(block: 0x41, count: 1, address: overlayBase)
            case .databaseInfo: return Load(block: 0x40, count: 1, address: overlayBase)
            }
        }
    }

    public static let overlayBase = 0xA7E0
    /// After any overlay load, this block (the scenery root list) is loaded at the overlay's end address.
    public static let rootBlock = 0x42
    /// The user mode library block (on a separate FS2-formatted disk in the original).
    public static let modeLibraryBlock = 0x40
}
