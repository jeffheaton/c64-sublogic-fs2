import Foundation
import FS2Core
import FS2LabKit
import Testing

/// The I/O read counts of the replay checkpoints (`ReplayLog.Checkpoint.ioReads`): the lab's
/// recorder keeps, at every $204B, how many I/O reads the main program had made; the driver
/// compares the port's reads per address with them. A replay that reads the TOD seconds `$DC09`
/// once more or once less than the original fails at the next checkpoint, also where the value
/// read changes nothing in memory (the memory hash matches there). Logs recorded before the
/// counts existed still decode and replay.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct ReplayReadCountTests {
    /// Ten seconds of flight at Meigs: about ten 10 Hz ticks per pass, each reading `$DC09`.
    static let recording = Result {
        try ReplayLab.record("readcount", prefix: ReplaySessions.meigs, session: "wait:600")
    }

    static let tod = 0xDC09

    /// A `$DC09` read whose removal (or duplication) the memory cannot show at the next
    /// checkpoint: every `$DC09` read from it up to the first one after that checkpoint has the
    /// same value, so shifting the port's reads by one changes no value it sees before it.
    /// Returns the read's index in `log.ioReads` and the checkpoint.
    static func silentRead(_ log: ReplayLog) -> (read: Int, checkpoint: Int)? {
        let todReads = log.ioReads.indices.filter { Int(log.ioReads[$0].address) == tod }
        for k in 1..<log.checkpoints.count {
            guard let lo = log.checkpoints[k - 1].ioReads, let hi = log.checkpoints[k].ioReads,
                  let after = todReads.first(where: { $0 >= hi }) else { continue }
            let value = log.ioReads[after].value
            // The run of equal values that ends with the first read after checkpoint k.
            var start = after
            for i in todReads.reversed() where i < after {
                guard log.ioReads[i].value == value else { break }
                start = i
            }
            if start >= lo && start < hi { return (start, k) }
        }
        return nil
    }

    /// The log with read `index` removed (the original made one read fewer) or duplicated (one
    /// more), the checkpoint counts adjusted to match.
    static func tampered(_ log: ReplayLog, read index: Int, remove: Bool) -> ReplayLog {
        var log = log
        if remove { log.ioReads.remove(at: index) } else { log.ioReads.insert(log.ioReads[index], at: index) }
        for k in log.checkpoints.indices {
            if let n = log.checkpoints[k].ioReads, n > index { log.checkpoints[k].ioReads = n + (remove ? -1 : 1) }
        }
        return log
    }

    static func replay(_ r: ReplayLab.Recording, _ log: ReplayLog) -> ReplayDriver.Outcome {
        ReplayDriver(machine: ReplayLab.portMachine(r), log: log).run(from: .mainLoop)
    }

    /// The recorder keeps a non-decreasing count at every checkpoint; the replay matches them all
    /// and makes every recorded read up to the last one (`readBlocks` reads `$D015` through
    /// `readIO`).
    @Test func countsMatch() throws {
        let r = try Self.recording.get()
        let counts = r.log.checkpoints.compactMap(\.ioReads)
        #expect(counts.count == r.log.checkpoints.count && counts.count >= 6)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 } && (counts.last ?? 0) <= r.log.ioReads.count)
        #expect(r.log.ioReads.filter { Int($0.address) == Self.tod }.count >= 60)
        let outcome = Self.replay(r, r.log)
        #expect(outcome.passed, "\(outcome.mismatch.map { "\($0)" } ?? outcome.error ?? "")")
        #expect(ReplayLab.unreadAfterTheLastCheckpoint(r, outcome) && outcome.unloggedReads.isEmpty,
                "unread \(outcome.unreadValues), unlogged \(outcome.unloggedReads)")
    }

    /// The original read `$DC09` once fewer than the port does: the port's extra read fails the
    /// next checkpoint, whose memory still matches.
    @Test func extraReadFails() throws {
        let r = try Self.recording.get()
        let (read, k) = try #require(Self.silentRead(r.log), "a run of equal TOD reads across a checkpoint")
        let outcome = Self.replay(r, Self.tampered(r.log, read: read, remove: true))
        let mismatch = try #require(outcome.mismatch, "the extra read is caught")
        #expect(mismatch.checkpoint == k)
        #expect(mismatch.hash == mismatch.expectedHash && mismatch.poll == mismatch.expectedPoll,
                "only the read count differs: \(mismatch)")
        #expect(mismatch.reads?.address == Self.tod)
        #expect(mismatch.reads.map { $0.port == $0.recorded + 1 } == true, "\(mismatch)")
        #expect(outcome.matched == k)
    }

    /// The original read `$DC09` once more than the port does: the missing read fails the next
    /// checkpoint, whose memory still matches.
    @Test func missingReadFails() throws {
        let r = try Self.recording.get()
        let (read, k) = try #require(Self.silentRead(r.log))
        let outcome = Self.replay(r, Self.tampered(r.log, read: read, remove: false))
        let mismatch = try #require(outcome.mismatch, "the missing read is caught")
        #expect(mismatch.checkpoint == k)
        #expect(mismatch.hash == mismatch.expectedHash && mismatch.poll == mismatch.expectedPoll,
                "only the read count differs: \(mismatch)")
        #expect(mismatch.reads?.address == Self.tod)
        #expect(mismatch.reads.map { $0.port + 1 == $0.recorded } == true, "\(mismatch)")
        #expect(outcome.matched == k)
    }

    /// A checkpoint as logs recorded before the read counts stored it.
    struct OldCheckpoint: Codable {
        var poll: Int
        var cycle: UInt64
        var memoryHash: UInt64
    }

    /// A log as recorded before the read counts.
    struct OldLog: Codable {
        var deliveries: [ReplayLog.Delivery]
        var ioReads: [ReplayLog.IORead]
        var checkpoints: [OldCheckpoint]
    }

    /// An older log (no `ioReads` in its checkpoints) decodes with nil counts and replays as
    /// before: memory and polls only, so the tampered read is not noticed at that checkpoint.
    @Test func olderLogsStillReplay() throws {
        let r = try Self.recording.get()
        func old(_ log: ReplayLog) throws -> ReplayLog {
            let o = OldLog(deliveries: log.deliveries, ioReads: log.ioReads, checkpoints: log.checkpoints.map {
                OldCheckpoint(poll: $0.poll, cycle: $0.cycle, memoryHash: $0.memoryHash)
            })
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("old-replay-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: url) }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(o).write(to: url)
            return try ReplayLog.read(from: url)
        }
        let decoded = try old(r.log)
        #expect(decoded.checkpoints.count == r.log.checkpoints.count)
        #expect(decoded.checkpoints.allSatisfy { $0.ioReads == nil })
        #expect(decoded.deliveries == r.log.deliveries && decoded.ioReads == r.log.ioReads)
        let outcome = Self.replay(r, decoded)
        #expect(outcome.passed, "\(outcome.mismatch.map { "\($0)" } ?? outcome.error ?? "")")
        // The same log with a counted read removed: without counts its checkpoint passes.
        let (read, k) = try #require(Self.silentRead(r.log))
        let tampered = try old(Self.tampered(r.log, read: read, remove: true))
        let driver = ReplayDriver(machine: ReplayLab.portMachine(r), log: tampered)
        var reached = -1
        driver.onCheckpoint = { index, _ in reached = index }
        _ = driver.run(from: .mainLoop)
        #expect(reached >= k, "checkpoint \(k) passes without the counts (reached \(reached))")
        // And a log written now round-trips its counts.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try r.log.write(to: url)
        #expect(try ReplayLog.read(from: url).checkpoints.map(\.ioReads) == r.log.checkpoints.map(\.ioReads))
    }
}
