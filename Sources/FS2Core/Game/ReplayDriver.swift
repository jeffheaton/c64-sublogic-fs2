import C64Kit

/// Replays a lab recording (`ReplayLog`, `fs2lab record`) in the port and checks it.
///
/// The lab, recording, takes the raster IRQs and RESTORE only at the program's poll points (the two
/// calls of the 10 Hz poll: through the vector $2012 at $8752, once per display-list opcode, and
/// directly to $2330 at $2268 in the key wait), and logs per poll index how many IRQs ran with
/// which key matrix and joysticks, the NMIs, every I/O value the main program read, and a hash of
/// memory at every top of the main loop ($204B). The driver feeds the port exactly those inputs:
///
/// - `pollHandler`: counts the port's poll points (`pollTick` calls it first) and at each
///   recorded one sets `io.keyboard` and runs that many IRQs (`Machine.irq`, which picks the
///   handler from the vector at $FFFE at that moment: the full raster IRQ $2285 or the tick-only
///   $2304), then the NMI (`Machine.nmi`);
/// - `ioReadHook`: returns the recorded values, in order per address (the TOD seconds `$DC09`
///   above all);
/// - `mainLoopHook`: at every $204B compares the memory hash, the poll count and the I/O reads
///   made so far (per address, against the count the checkpoint recorded) with the recording's
///   checkpoint, and stops after the last one or at the first mismatch;
/// - the cycle-driven `eventHandler` is off: in a replay the interrupts come only from the log.
///
/// The run happens on a `ProgramThread` (a RESTORE restart nests the new program inside the
/// interrupted frames). A run that gets past the last checkpoint's poll by `pollSlack` polls
/// (diverged, e.g. waiting for a key the log never brings) is abandoned.
public final class ReplayDriver {
    /// Where the port starts: at the top of the main loop ($204B, the state of the recording's
    /// start snapshot), or at the stage-2 handoff ($A7E2, `Machine.booting`).
    public enum Start: Sendable { case mainLoop, coldStart }

    /// Recorded reads the port never makes, left out of the read-count check: `$DC08`, the TOD
    /// tenths the cold init's 50/60 Hz calibration loop polls (the port charges the loop's time
    /// and stores the NTSC count instead of running it; `main-loop.md`).
    public static let unperformedReads: Set<Int> = [0xDC08]

    /// An I/O register read a different number of times by the port than in the recording, up to
    /// a checkpoint.
    public struct ReadCount: Sendable, Equatable {
        public var address: Int
        public var port: Int, recorded: Int
    }

    /// The first checkpoint whose memory, poll count or I/O read count differs.
    public struct Mismatch: Sendable, CustomStringConvertible {
        public var checkpoint: Int
        public var poll: Int, expectedPoll: Int
        public var hash: UInt64, expectedHash: UInt64
        /// The first I/O register (lowest address) read a different number of times, nil when
        /// the reads agree (or the log has no read counts).
        public var reads: ReadCount?
        public var description: String {
            var s = String(format: "checkpoint %d: poll %d (recorded %d), memory hash %016llX (recorded %016llX)",
                           checkpoint, poll, expectedPoll, hash, expectedHash)
            if let r = reads {
                s += String(format: ", $%04X read %d times (recorded %d)", r.address, r.port, r.recorded)
            }
            return s
        }
    }

    public struct Outcome: Sendable {
        public var checkpoints: Int
        public var matched: Int
        public var mismatch: Mismatch?
        /// A run that ended otherwise than at a checkpoint (diverged past the log, a fault).
        public var error: String?
        public var polls: Int
        public var deliveries: Int
        public var irqs: Int
        public var nmis: Int
        /// I/O reads of the port the log had no value for (address → count).
        public var unloggedReads: [Int: Int]
        /// Recorded I/O values the port never read (address → count).
        public var unreadValues: [Int: Int]
        public var passed: Bool { mismatch == nil && error == nil && matched == checkpoints }
    }

    public let machine: Machine
    public let log: ReplayLog
    /// Called after each matching checkpoint, with its index (memory golden frames, I/O checks).
    public var onCheckpoint: ((Int, Machine) -> Void)?
    /// Called at a mismatch with the machine in its state at that checkpoint.
    public var onMismatch: ((Mismatch, Machine) -> Void)?
    /// Polls allowed past the last checkpoint's poll before the run counts as diverged.
    public var pollSlack = 100_000

    private var polls = 0
    private var nextDelivery = 0
    private var matched = 0
    private var irqs = 0
    private var nmis = 0
    private var mismatch: Mismatch?
    private var error: String?
    private var reads: [Int: [UInt8]] = [:]
    private var readIndex: [Int: Int] = [:]
    private var unlogged: [Int: Int] = [:]
    private let lastPoll: Int

    public init(machine: Machine, log: ReplayLog) {
        self.machine = machine
        self.log = log
        lastPoll = log.checkpoints.last?.poll ?? 0
        for r in log.ioReads { reads[Int(r.address), default: []].append(r.value) }
    }

    /// The key matrix and joysticks of a delivery.
    public static func keyMatrix(_ d: ReplayLog.Delivery) -> KeyMatrix {
        var k = KeyMatrix()
        for (column, bits) in d.keyColumns.enumerated() {
            for row in 0..<8 where bits & UInt8(1 << row) != 0 {
                if let key = C64Key(rawValue: column * 8 + row) { k.set(key, pressed: true) }
            }
        }
        k.joystick1 = JoystickState(rawValue: d.joystick1)
        k.joystick2 = JoystickState(rawValue: d.joystick2)
        return k
    }

    /// Runs the replay to its last checkpoint (or the first mismatch) and reports.
    public func run(from start: Start) -> Outcome {
        let m = machine
        m.eventHandler = nil
        m.nextEventCycle = .max
        m.pollHandler = { [unowned self] m in self.poll(m) }
        m.ioReadHook = { [unowned self] address, live in self.read(address, live) }
        m.mainLoopHook = { [unowned self] m in self.checkpoint(m) }
        var exit = MainLoop.Exit.stopped
        let ending = ProgramThread.run(m) { m in
            switch start {
            case .mainLoop: exit = m.runMainLoop(fromEntry: false)
            case .coldStart: exit = m.coldStart()
            }
        }
        m.pollHandler = nil
        m.ioReadHook = nil
        m.mainLoopHook = nil
        if case .fault(let fault) = exit, error == nil { error = "display-list fault \(fault)" }
        if case .abandoned(let reason?) = ending, error == nil { error = reason }
        var unread: [Int: Int] = [:]
        for (address, values) in reads where readIndex[address, default: 0] < values.count {
            unread[address] = values.count - readIndex[address, default: 0]
        }
        return Outcome(checkpoints: log.checkpoints.count, matched: matched, mismatch: mismatch, error: error,
                       polls: polls, deliveries: nextDelivery, irqs: irqs, nmis: nmis, unloggedReads: unlogged,
                       unreadValues: unread)
    }

    private func poll(_ m: Machine) {
        polls += 1
        while nextDelivery < log.deliveries.count, log.deliveries[nextDelivery].poll == polls {
            let d = log.deliveries[nextDelivery]
            nextDelivery += 1
            m.io.keyboard = Self.keyMatrix(d)
            for _ in 0..<d.irqs {
                irqs += 1
                m.irq()
            }
            if d.nmi {
                nmis += 1
                m.nmi()
            }
        }
        if polls > lastPoll + pollSlack {
            error = "the port ran \(pollSlack) polls past the recording's last checkpoint (poll \(lastPoll))"
            m.abandonStack?(error)
        }
    }

    private func read(_ address: Int, _ live: UInt8) -> UInt8 {
        let i = readIndex[address, default: 0]
        guard let values = reads[address], i < values.count else {
            unlogged[address, default: 0] += 1
            return live
        }
        readIndex[address] = i + 1
        return values[i]
    }

    private func checkpoint(_ m: Machine) -> Bool {
        guard mismatch == nil, error == nil, matched < log.checkpoints.count else { return false }
        let c = log.checkpoints[matched]
        let hash = ReplayLog.memoryHash(m.mem)
        let reads = c.ioReads.flatMap(readCountDifference(upTo:))
        guard hash == c.memoryHash, polls == c.poll, reads == nil else {
            let mm = Mismatch(checkpoint: matched, poll: polls, expectedPoll: c.poll, hash: hash,
                              expectedHash: c.memoryHash, reads: reads)
            mismatch = mm
            onMismatch?(mm, m)
            return false
        }
        onCheckpoint?(matched, m)
        matched += 1
        return matched < log.checkpoints.count
    }

    /// The recorded reads per address up to the checkpoint being checked (`recordedCursor`
    /// entries of `log.ioReads`).
    private var recordedReads: [Int: Int] = [:]
    private var recordedCursor = 0

    /// The first address (in address order) the port read a different number of times than the
    /// first `count` reads of the log hold; nil when they agree. The port's reads are the values
    /// it consumed plus those it made past the end of the log; `unperformedReads` are left out.
    private func readCountDifference(upTo count: Int) -> ReadCount? {
        let end = min(count, log.ioReads.count)
        while recordedCursor < end {
            recordedReads[Int(log.ioReads[recordedCursor].address), default: 0] += 1
            recordedCursor += 1
        }
        let addresses = Set(recordedReads.keys).union(readIndex.keys).union(unlogged.keys)
            .subtracting(Self.unperformedReads)
        for address in addresses.sorted() {
            let port = readIndex[address, default: 0] + unlogged[address, default: 0]
            let recorded = recordedReads[address, default: 0]
            if port != recorded { return ReadCount(address: address, port: port, recorded: recorded) }
        }
        return nil
    }
}
