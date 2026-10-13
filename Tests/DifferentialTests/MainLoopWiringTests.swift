import C64Kit
import Foundation
import FS2Core
import Testing

/// The main loop's wiring of the editor and war units (the integration items of the final pass):
/// the war-exit check restarts exactly when the editor's contract says so, the scheduler skips the
/// IRQ work while the editor's library disk I/O holds the IRQ off, and the native engine presents
/// the editor's text screen while the IRQ vector is $2304. (Slot $A7E8 → `editorEntry` with the
/// `$08BC` bookkeeping and slot $A7EE → `warMain` are replayed against the lab in
/// `ReplayModesTests` and `NativeEngineReplayTests`.)
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct MainLoopWiringTests {
    typealias R = MainLoop.RAM

    /// The 1-in-8 pass of phase 0 at Meigs with the Europe 1917 latch `$0E7C` and the current mode
    /// `$0963` in every combination: the pass ends in the cold restart (the jump to $A7E2) exactly
    /// when `warModeRestartDue` holds.
    @Test func warExitFollowsTheEditorContract() throws {
        var restarts = 0
        for (latch, mode) in [(UInt8(0), UInt8(0)), (0, 7), (7, 7), (7, 0), (7, 3), (7, 24)] {
            let m = try MainLoopSchedulerTests.machine()
            m.mem[R.mainLoopCounter] = 4
            m.mem[R.warModeLatch] = latch
            m.mem[R.currentMode] = mode
            m.mem[R.demoRequest] = 0
            let due = m.warModeRestartDue
            let end = try m.mainLoopPass()
            #expect((end == .coldRestart) == due, "latch \(latch), mode \(mode): \(end), due \(due)")
            if end == .coldRestart { restarts += 1 }
        }
        #expect(restarts == 3)
    }

    /// CTRL-X in the editor under the normal-mode scheduler: no frame tick (no jiffy) while the
    /// interrupt flag holds the IRQ off (the library I/O runs masked for about 90 frames of disk
    /// I/O; the text-mode swap's and the exit's `displayInit` are short windows); the scheduler
    /// keeps running for pacing, and the IRQ held is taken right after each unmasking (the IRQ
    /// vector is $2304, one tick a frame outside the windows).
    @Test func libraryIOHoldsTheIRQ() throws {
        let m = Machine(memory: try D2.state("d2-ed-entry"))
        m.diskBlocks = Original.diskBlocks
        m.modeLibraryIO = ModeLibrary.InMemoryStore(block: Original.diskBlocks[64]).io
        m.io.writeVIC(0x11, 0x3B)
        m.io.writeVIC(0x12, 0x20)
        m.io.writeVIC(0x1A, 0x01)
        let scheduler = InterruptScheduler(machine: m)
        scheduler.install()
        ScriptedKeys(EditorLibraryTests.ctrlX + "E").installPollHandler(on: m)
        let service = m.eventHandler
        /// Every masked stretch the scheduler saw: its services, the ticks inside, the ticks of
        /// the first service after it.
        struct Window { var services = 0, ticks = 0, after: Int? }
        var windows: [Window] = [], outside = 0, wasMasked = false
        var depth = 0
        m.eventHandler = { m in
            // Charges inside the handlers the scheduler runs come back here (the scheduler does
            // not re-enter itself): only the outer calls count.
            depth += 1
            defer { depth -= 1 }
            guard depth == 1 else { service?(m); return }
            let jiffy = m.mem[R.jiffyCounter], masked = m.interruptDisable
            service?(m)
            let ticks = Int(m.mem[R.jiffyCounter] &- jiffy)
            if masked && m.interruptDisable {
                if !wasMasked { windows.append(Window()) }
                windows[windows.count - 1].services += 1
                windows[windows.count - 1].ticks += ticks
            } else {
                outside += ticks
                if wasMasked && !masked, !windows.isEmpty, windows[windows.count - 1].after == nil {
                    windows[windows.count - 1].after = ticks
                }
            }
            wasMasked = masked && m.interruptDisable
        }
        m.editorEntry()
        scheduler.uninstall()
        let library = try #require(windows.max { $0.services < $1.services }, "no masked stretch")
        #expect(library.services > 50, "the scheduler kept running for pacing in the window: \(library.services)")
        #expect(windows.allSatisfy { $0.ticks == 0 }, "ticks while the IRQ was held: \(windows.map(\.ticks))")
        #expect(library.after == 1, "the IRQ held is taken right after the CLI: \(windows.map { $0.after ?? -1 })")
        #expect(outside >= 1, "\(outside) ticks outside it")
        #expect(!m.interruptDisable)
    }

    /// The editor opened with E at Meigs on the native engine: while the IRQ vector is $2304 (the
    /// editor's text mode) every frame presented is the text screen (`presentTextScreen`), not the
    /// split; once the editor is left (E), the split is back.
    @Test func editorTextScreenIsPresented() throws {
        let engine = try NativeEngineSmoothTests.engine(.authentic)
        NativeEngineSmoothTests.prepare(engine, throttle: false)
        let m = engine.machine
        let frame = VirtualClock.cyclesPerFrame
        func frames(_ n: UInt64, _ key: C64Key? = nil) {
            var input = InputState()
            if let key { input.keys.set(key, pressed: true) }
            engine.input = input
            engine.run(untilCycle: (engine.cycles / frame + n) * frame)
        }
        /// Runs frames (not presented) until `done`, at most `limit`.
        func frames(until limit: Int, _ done: () -> Bool) -> Bool {
            for _ in 0..<limit where !done() { frames(1) }
            return done()
        }
        func textScreen() -> [UInt8] {
            var out: [UInt8] = []
            m.presentTextScreen(into: &out, charROM: engine.charROM)
            return out
        }
        // Per frame presented: the IRQ vector was $2304, the frame was the text screen, and the VIC
        // held the editor's text setup (`setTextMode`: screen $0400 with the character ROM,
        // `$D018` = $16; text mode, `$D011` = $1B; bank 0, `$DD00` = $97), which no split IRQ
        // overwrote while the swap ran.
        var presented: [(vector2304: Bool, textScreen: Bool)] = []
        var textSetup: [Bool] = []
        let observe: (FrameOutput) -> Void = { f in
            presented.append((m.u16(TextMode.irqVector) == 0x2304, f.pixels == textScreen()))
            let bank = (m.io.cia2PortA | ~m.io.cia2DataDirectionA) & 0x03
            textSetup.append(m.io.vic[0x18] == 0x16 && m.io.vic[0x11] == 0x1B && bank == 0x03)
        }
        frames(14, .e)
        #expect(frames(until: 3000) { m.u16(TextMode.irqVector) == 0x2304 && m.mem[Input.RAM.editorRequest] == 1 },
                "the editor's text screen")
        engine.onFrame = observe
        frames(60)
        engine.onFrame = nil
        #expect(presented.count == 60 && presented.allSatisfy { $0.vector2304 && $0.textScreen },
                "the editor's frames are its text screen: \(presented.filter { !$0.textScreen }.count) are not")
        #expect(textSetup.count == 60 && textSetup.allSatisfy { $0 }, "the VIC keeps the text setup: \(textSetup)")
        // The editor's page is on it (not a blank screen): its first rows hold text.
        #expect((0..<(3 * TextMode.columns)).contains { m.mem[TextMode.screen + $0] != 0x20 }, "the editor's text")
        // E leaves the editor: the flight overlay comes back and the split with it (once the
        // scenery has streamed in again: a frame without raster IRQs shows one register state).
        frames(14, .e)
        #expect(frames(until: 3000) {
            m.u16(TextMode.irqVector) == 0x2285 && m.io.vic[0x11] & 0x20 != 0 && m.u16(0xA7E0) == 0xA800
                && m.mem[0x0901] == 0x4E && m.mem[MainLoop.RAM.diskLoading] == 0
        }, "back in flight")
        frames(60)
        presented.removeAll()
        engine.onFrame = observe
        frames(120)
        engine.onFrame = nil
        #expect(presented.count == 120 && presented.allSatisfy { !$0.vector2304 && !$0.textScreen }, "the split again")
        #expect(m.mem[R.editorCacheState] == 1, "the editor overlay was loaded and cached ($08BC)")
    }
}
