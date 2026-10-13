import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Whole-game verification: every session in `re/sessions/*.txt` that the lab can record (the
/// feature sessions and the `replay-*` ones) recorded in the lab and replayed through the native
/// engine (`ReplayMatrix`). At every top of the main loop ($204B) the port's memory (stack page
/// aside) and poll count must equal the lab's, the I/O it mirrors (VIC and SID registers, color
/// RAM, the VIC bank, the latched split states) must match, and the frame presented there must be
/// the lab's, pixel for pixel. The session's last steps are checked too: the recording runs on
/// to the next checkpoint after them (`library` excepted, see `ReplayMatrix.endsAway`).
///
/// Pacing on identical work: the replay runs exactly the recorded passes, so the port's clock
/// per pass against the lab's measures the cost model alone. The native engine's clock models the
/// cycles the VIC takes from the CPU (`Machine.vicDMA`: 1,168 of every 17,095 in flight, badlines
/// and sprites), and the loader's IEC times, measured on the lab, pass as wall time: every session
/// takes the lab's cycles within 1% and every pass within 2% (measured: 1.000 to 1.004 a session,
/// every pass 0.995 to 1.005; 0.932 for every ordinary pass before the DMA was modeled).
///
/// The recordings are cached under `build/testdata/replay-matrix/` (keyed by the disk, the prefix
/// and the session), so only the first run pays for the lab: about 10 minutes for the whole matrix
/// in a debug build on a busy machine, under 3 in a release build
/// (`swift test -c release -Xswiftc -enable-testing --filter ReplayMatrixTests`, which fills the
/// same cache). A cached debug run takes 2-3 minutes. Each run also writes every session's
/// last-checkpoint frames (`frames/`, for `Scripts/gallery/gallery.sh`).
///
/// `war-hook` is replayed only up to R (the `$FD00` hook is a documented no-op in the port,
/// `excluded.md`; `warHookMatchesUpToTheHook`); `demo-loop` (the demo's 28-minute flight into its
/// crash and the second demo, 2765 checkpoints) runs only with `FS2_REPLAY_LONG=1`.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct ReplayMatrixTests {
    /// The entries replayed: all but the excluded ones and (by default) the long ones;
    /// `FS2_REPLAY_ONLY=name,name` narrows the matrix to those sessions.
    static var replayed: [ReplayMatrix.Entry] {
        let only = ProcessInfo.processInfo.environment["FS2_REPLAY_ONLY"].map {
            Set($0.split(separator: ",").map(String.init))
        }
        return ReplayMatrix.entries.filter { e in
            if let only { return only.contains(e.name) }
            return e.excluded == nil && (!e.long || ReplayMatrix.runLong)
        }
    }

    /// Every session file becomes an entry; the replay-* sessions keep their tests' prefixes.
    @Test func everySessionIsInTheMatrix() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: ReplayMatrix.sessionsDirectory.path)
            .filter { $0.hasSuffix(".txt") }
        #expect(ReplayMatrix.entries.count == files.count)
        let byName = Dictionary(uniqueKeysWithValues: ReplayMatrix.entries.map { ($0.name, $0) })
        #expect(byName["takeoff"]?.prefix == ReplaySessions.meigs, "a feature session after the Meigs prefix")
        #expect(byName["replay-coldboot"]?.prefix == nil && byName["demo"]?.prefix == nil, "from the handoff")
        #expect(byName["restart"]?.restartAware == true && byName["replay-restart"]?.restartAware == true)
        #expect(byName["war-hook"]?.excluded != nil)
        #expect(!(byName["idle"]?.session.contains("cov:") ?? true), "the observing steps are dropped")
        #expect(byName["takeoff"]?.runsOn == true && byName["library"]?.runsOn == false)
    }

    @Test(arguments: ReplayMatrixTests.replayed)
    func replay(_ entry: ReplayMatrix.Entry) throws {
        let r = try ReplayMatrix.recording(entry)
        let report = ReplayMatrix.replay(r, seed: ReplayMatrix.fnv(Array(entry.name.utf8)))
        let o = try #require(report.outcome, "\(entry.name): the replay did not end (\(report.endReason ?? "running"))")
        let summary = "\(entry.name): \(o.matched)/\(o.checkpoints) checkpoints over \(r.frames) frames, \(o.polls) polls, "
            + "\(o.irqs) IRQs, \(o.nmis) NMIs, \(report.framesCompared) frames compared, \(r.pokes.count) pokes, "
            + "\(r.uncheckedFrames) session frames after the last checkpoint, unread I/O values \(o.unreadValues); "
            + String(format: "recorded in %.1f s, replayed in %.1f s (%d run calls)", r.recordSeconds, report.seconds,
                     report.runCalls)
        print("replay matrix \(summary)")
        // Pacing on identical work: the port's cycles per pass against the lab's.
        let passes = report.passPacing(r).sorted()
        if let overall = report.overallPacing(r), !passes.isEmpty {
            print(String(format: "replay pacing %@: port/lab cycles %.3f over %d passes "
                         + "(per pass: min %.3f, median %.3f, max %.3f)",
                         entry.name, overall, passes.count, passes.first!, passes[passes.count / 2], passes.last!))
            #expect(abs(overall - 1) <= 0.01, "\(entry.name): the port takes \(overall) times the lab's cycles")
            // Every pass on its own too: a routine whose charges are off shows in the passes it
            // dominates long before it moves a whole session's ratio.
            let outside = report.passPacing(r).enumerated().filter { abs($0.element - 1) > 0.02 }
            let listed = outside.prefix(8).map { String(format: "pass %d: %.3f", $0.offset + 1, $0.element) }
            #expect(outside.isEmpty,
                    "\(entry.name): passes outside ±2% of the lab's cycles: \(listed.joined(separator: ", "))")
        }
        let details = report.problems.joined(separator: "\n")
        #expect(o.passed, "\(summary)\n\(o.error ?? "")\n\(details)")
        #expect(report.problems.isEmpty, "\(summary)\n\(details)")
        #expect(o.checkpoints >= 2, "\(summary): too few checkpoints recorded")
        #expect(r.uncheckedFrames == 0 || ReplayMatrix.endsAway.contains(entry.name),
                "\(summary): the session's end was never checked (no top of the main loop after it)")
        #expect(report.framesCompared >= (o.checkpoints - 1) / ReplayMatrix.frameEvery(r), "\(summary)")
        #expect(o.unloggedReads.isEmpty, "\(summary): I/O reads the lab did not log: \(o.unloggedReads)")
        #expect(report.bridgeCalls.isEmpty,
                "\(summary): the development bridge was reached: \(report.bridgeCalls.prefix(8).map { hex16(Int($0)) })")
        // The lab stops at the last checkpoint, so every I/O value it logged was read before it:
        // a value the port never read is a read of the original's the port skips. Two kinds are
        // by design (`skippedReads`); any other is reported.
        let skipped = o.unreadValues.keys.filter { !Self.skippedReads.contains($0) }.sorted()
        #expect(skipped.isEmpty || !entry.runsOn,
                "\(summary): recorded I/O values the port never read at \(skipped.map { hex16($0) })")
    }

    /// I/O reads of the original the port does not make: `$D015` (the streaming disk glue saves
    /// the sprite enable by reading `$D015`; the port takes `io.vic[0x15]`, a plain register) and
    /// `$DC08` (the cold start's TOD calibration loop, which the port charges by its time).
    static let skippedReads: Set<Int> = [0xD015, 0xDC08]

    /// `war-hook`, the one excluded session, replayed up to its documented deviation: every
    /// checkpoint before R reaches the main loop's call to $FD00 (a no-op in the port, a chain of
    /// software interrupts in this image) must match, and the first mismatch must come after R
    /// was pressed (so the exclusion hides nothing but the hook itself).
    @Test func warHookMatchesUpToTheHook() throws {
        let entry = try #require(ReplayMatrix.entries.first { $0.name == "war-hook" })
        let r = try ReplayMatrix.recording(entry)
        let pressed = try #require(r.log.deliveries.first { ReplayDriver.keyMatrix($0).isPressed(.r) },
                                   "war-hook: R was never delivered")
        let before = r.log.checkpoints.filter { $0.poll < pressed.poll }.count
        let report = ReplayMatrix.replay(r, seed: ReplayMatrix.fnv(Array(entry.name.utf8)))
        let o = try #require(report.outcome, "war-hook: the replay did not end (\(report.endReason ?? "running"))")
        let ending = o.mismatch.map { "\($0)" } ?? o.error ?? "no mismatch"
        print("replay matrix war-hook: \(o.matched)/\(o.checkpoints) checkpoints matched, R delivered at poll "
              + "\(pressed.poll) after checkpoint \(before - 1); \(ending)")
        #expect(before >= 2, "war-hook: too few checkpoints before R")
        let details = report.problems.joined(separator: "\n")
        #expect(o.matched >= before, "war-hook: a checkpoint before R differs\n\(details)")
        // The I/O and frames of the matching checkpoints (the mismatch adds the one line of its own).
        #expect(report.problems.count == (o.mismatch == nil ? 0 : 1), "\(details)")
        #expect(report.bridgeCalls.isEmpty)
        // The deviation itself: the lab's interrupt chain advances the jiffies, the port's no-op
        // does not.
        #expect(o.mismatch != nil, "war-hook: the $FD00 deviation no longer shows; is the hook still a no-op?")
    }
}
