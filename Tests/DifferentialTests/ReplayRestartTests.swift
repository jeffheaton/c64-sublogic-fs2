import C64Kit
import Foundation
import FS2Core
import FS2LabKit
import Testing

/// RUN/STOP + RESTORE: the NMI handler's cold restart, recorded by the lab's own recorder and
/// replayed. The session's `nmi` steps press RESTORE through the recorder attached to the lab
/// machine (`C64Machine.replayRecorder`), which delivers it at a poll point and logs it; the
/// restart leaves the NMI handler with a jump to $A7E2 and never returns, and the recorder ends the
/// handler batch there and goes on recording. In the port the restart runs nested inside the
/// interrupted frames (`ProgramThread` leaves them when the replay ends).
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct ReplayRestartTests {
    @Test func runStopRestore() throws {
        let session = try ReplaySessions.text("replay-restart")
        let r = try ReplayLab.record("restart", prefix: ReplaySessions.meigs, session: session)
        let nmis = r.log.deliveries.filter { $0.nmi }
        #expect(nmis.count == 2, "two RESTOREs delivered at poll points: \(nmis.map(\.poll))")
        // The recording went on after the restart (the boot loads, the title, the prompts, flight):
        // IRQ batches and checkpoints after the second NMI, every checkpoint with its read count.
        let restart = try #require(nmis.last)
        #expect(r.log.deliveries.contains { $0.poll > restart.poll && $0.irqs > 0 }, "IRQs after the restart")
        #expect(r.log.checkpoints.contains { $0.poll > restart.poll }, "a checkpoint after the restart")
        #expect(r.log.checkpoints.allSatisfy { $0.ioReads != nil })
        let m = ReplayLab.portMachine(r)
        let report = ReplayLab.replay(r, on: m, from: .mainLoop, frames: 2)
        ReplayLab.expectClean(r, report, minCheckpoints: 4)
        #expect(report.outcome.nmis == 2)
        // Every read up to the last checkpoint was made by the port (the driver counted them at
        // each one), but the TOD calibration's `$DC08`: what is left unread is what the lab read
        // after it.
        #expect(ReplayLab.unreadAfterTheLastCheckpoint(r, report.outcome), "\(report.outcome.unreadValues)")
        // The restart reloaded overlay 0 and ran the init chain: the one-shot is clear again and the
        // flight overlay is back.
        #expect(m.mem[MainLoop.RAM.restoreOneShot] == 0)
        #expect(m.u16(0xA7E0) == 0xA800)
    }

    /// The `nmi` step at the stage-2 handoff (the NMI vector is the loader's bare return from
    /// interrupt, $790A): without a recorder it raises the NMI on the lab's CPU at once
    /// (`pressNMI`), so `fs2lab run` sessions keep their timing; with one attached it waits for a
    /// poll point (none during the boot loads), so nothing runs it yet.
    @Test func nmiStepGoesThroughTheRecorder() throws {
        let data = try #require(Original.data)
        for recording in [false, true] {
            let m = Lab.boot(data)
            let recorder = recording ? ReplayRecorder(machine: m) : nil
            #expect((m.replayRecorder != nil) == recording)
            var handled = 0
            let previous = m.onInstruction
            m.onInstruction = { pc in
                if pc == 0x790A { handled += 1 }
                previous?(pc)
            }
            try m.play(try Session.parse("wait:1 nmi wait:1"), screenshots: nil)
            #expect(handled == (recording ? 0 : 1), "recording \(recording): the NMI handler ran \(handled) times")
            #expect(recorder?.log.deliveries.isEmpty ?? true)
            withExtendedLifetime(recorder) {}
        }
    }
}
