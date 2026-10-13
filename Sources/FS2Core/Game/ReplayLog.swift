import Foundation

/// A deterministic record of the original program's asynchronous inputs, captured by the lab
/// (`fs2lab record`): raster-IRQ deliveries at poll points (with the inputs in effect), RESTORE,
/// main-program I/O reads, and memory checkpoints at the top of the main loop ($204B).
/// The port replays it through its own poll points so both sides can be compared exactly.
public struct ReplayLog: Codable, Sendable {
    public struct Delivery: Codable, Sendable, Equatable {
        /// Poll index (count of poll-site visits since recording started) where this batch ran.
        public var poll: Int
        /// Interrupt handler entries (vector at $FFFE) run at this poll.
        public var irqs: Int
        /// Keyboard matrix columns and joysticks in effect for the batch.
        public var keyColumns: [UInt8]
        public var joystick1: UInt8
        public var joystick2: UInt8
        /// RESTORE was pressed (NMI taken at this poll, after the IRQs).
        public var nmi: Bool

        public init(poll: Int, irqs: Int, keyColumns: [UInt8], joystick1: UInt8, joystick2: UInt8, nmi: Bool) {
            self.poll = poll; self.irqs = irqs; self.keyColumns = keyColumns
            self.joystick1 = joystick1; self.joystick2 = joystick2; self.nmi = nmi
        }
    }

    public struct IORead: Codable, Sendable, Equatable {
        public var address: UInt16
        public var value: UInt8
        public init(address: UInt16, value: UInt8) { self.address = address; self.value = value }
    }

    /// The poll index and a hash of memory (stack page excluded) when PC reached $204B, and how
    /// many I/O reads (`ioReads`) the main program had made by then.
    public struct Checkpoint: Codable, Sendable {
        public var poll: Int
        public var cycle: UInt64
        public var memoryHash: UInt64
        /// The length of `ReplayLog.ioReads` at this checkpoint (the reads the program had
        /// consumed), so a replay that reads once more or once less fails here, even where the
        /// value read changes nothing in memory. Nil in logs recorded before it was kept.
        public var ioReads: Int?
        public init(poll: Int, cycle: UInt64, memoryHash: UInt64, ioReads: Int? = nil) {
            self.poll = poll; self.cycle = cycle; self.memoryHash = memoryHash; self.ioReads = ioReads
        }
    }

    /// The original's poll sites: the call through the vector $2012 at $8752 (scenery opcode loop)
    /// and the direct call of $2330 at $2268 (wait-for-key loop).
    public static let pollSites: [UInt16] = [0x8752, 0x2268]

    public var deliveries: [Delivery] = []
    public var ioReads: [IORead] = []
    public var checkpoints: [Checkpoint] = []

    public init() {}

    /// FNV-1a over memory, skipping the stack page (the port has no 6502 stack).
    public static func memoryHash(_ mem: UnsafePointer<UInt8>) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in 0..<0x10000 where i < 0x100 || i >= 0x200 {
            h = (h ^ UInt64(mem[i])) &* 0x100_0000_01B3
        }
        return h
    }

    public func write(to url: URL) throws {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        try enc.encode(self).write(to: url)
    }

    public static func read(from url: URL) throws -> ReplayLog {
        try PropertyListDecoder().decode(ReplayLog.self, from: Data(contentsOf: url))
    }
}
