import C64Kit
import Foundation
import FS2Core
import FS2LabKit
import Testing

/// Normal (non-replay) mode: `InterruptScheduler` runs the raster IRQ equivalents on the virtual
/// clock while the port runs its main loop, holds them during disk loads, and takes RESTORE at a
/// poll point.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct MainLoopSchedulerTests {
    typealias R = MainLoop.RAM

    /// The port from the regular-flight snapshot at $204B, with the I/O the game set up.
    static func machine() throws -> Machine {
        let ram = try Original.regularFlight()
        let m = Machine(memory: ram)
        m.diskBlocks = Original.diskBlocks
        m.io.writeVIC(0x11, 0x3B)
        m.io.writeVIC(0x12, ram[R.irqPhase] & 1 == 0 ? 0xA3 : 0x20)
        m.io.writeVIC(0x1A, 0x01)
        m.io.writeCIA2(0x02, 0x3F)
        m.io.writeCIA2(0x00, 0x96)
        m.clock.cycles = 50_000_000
        return m
    }

    /// Twenty virtual seconds of flight: one window-phase IRQ per frame (the jiffy counts the
    /// frames), the panel phase between them, the keyboard phase cycling every 4 frames, the 10
    /// Hz tick catching up with the frames, the clock following the virtual TOD.
    @Test func interruptsFollowTheClock() throws {
        let m = try Self.machine()
        let scheduler = InterruptScheduler(machine: m)
        var frames = 0, jiffySteps: [Int] = [], lastJiffy = m.mem[R.jiffyCounter]
        var phases: Set<UInt8> = []
        let end = m.clock.cycles + UInt64(20 * VirtualClock.hz)
        scheduler.onFrameEnd = { m, cycle in
            guard cycle <= end else { return }
            frames += 1
            let j = m.mem[R.jiffyCounter]
            jiffySteps.append(Int(j &- lastJiffy))
            lastJiffy = j
            phases.insert(m.mem[R.scanPhase])
        }
        let seconds0 = m.mem[R.clockSeconds], minutes0 = m.mem[R.clockMinutes]
        m.mainLoopHook = { m in m.clock.cycles < end }
        scheduler.install()
        let exit = m.runMainLoop(fromEntry: false)
        scheduler.uninstall()
        #expect(exit == .stopped)
        #expect(frames >= 1195 && frames <= 1198, "\(frames) frames in 20 s")
        // After the first frame (the IRQ phase may start on either line), exactly one jiffy each.
        let off = jiffySteps.dropFirst(2).filter { $0 != 1 }
        #expect(off.isEmpty, "frames with other jiffy steps: \(off.prefix(10))")
        #expect(phases == [0, 1, 2, 3], "keyboard phases \(phases.sorted())")
        // The clock: 20 TOD seconds later (the pause count is 0 in regular flight).
        let elapsed = (Int(m.mem[R.clockMinutes]) - Int(minutes0)) * 60 + Int(m.mem[R.clockSeconds]) - Int(seconds0)
        #expect((19...21).contains(elapsed), "the clock advanced \(elapsed) s")
        #expect(m.io.viewRegion.cr2 == 0xD8 && m.io.panelRegion.cr2 == 0xC8)
        #expect(m.io.panelRegion.memPtr == 0xF0 && m.io.panelRegion.border == 0x0C)
        #expect(m.mem[R.frameDivider] < 12, "the 10 Hz tick keeps up: $0E6B = \(m.mem[R.frameDivider])")
    }

    /// A scenery load (the Chicago area and the Meigs detail streamed in again) holds the IRQ:
    /// the frames it takes pass without jiffies, and the IRQs resume right after it (the latched
    /// one first, which may be either phase of the split).
    @Test func loadsHoldTheIRQ() throws {
        let m = try Self.machine()
        m.mem[0x0900] = 0                                   // the area slot forgets its block
        let scheduler = InterruptScheduler(machine: m)
        var during: [Int] = [], after: [[Int]] = [], lastJiffy = m.mem[R.jiffyCounter]
        var loads = 0, framesInLoad = 0
        scheduler.onFrameEnd = { m, _ in
            let step = Int(m.mem[R.jiffyCounter] &- lastJiffy)
            lastJiffy = m.mem[R.jiffyCounter]
            if m.mem[R.diskLoading] != 0 {
                if framesInLoad == 0 { loads += 1 } else { during.append(step) }
                framesInLoad += 1
            } else {
                if framesInLoad > 0 { after.append([]) }
                framesInLoad = 0
                if let last = after.indices.last, after[last].count < 3 { after[last].append(step) }
            }
        }
        let end = m.clock.cycles + UInt64(15 * VirtualClock.hz)
        m.mainLoopHook = { m in m.clock.cycles < end }
        scheduler.install()
        m.runMainLoop(fromEntry: false)
        scheduler.uninstall()
        #expect(loads >= 2, "the area and the detail were loaded: \(loads)")
        #expect(during.count > 100, "\(during.count) frames inside loads")
        #expect(during.allSatisfy { $0 == 0 }, "no IRQ inside a load: \(during.filter { $0 != 0 })")
        #expect(after.allSatisfy { $0.reduce(0, +) >= 2 }, "the IRQs resume after each load: \(after)")
        #expect(m.mem[0x0900] == 0x44 && m.mem[0x0901] == 0x4E, "the area and the detail are back")
    }

    /// `displayInit` turns raster IRQs on mid-frame, after line $97 has passed: the first IRQ
    /// comes at line $97 of the next frame (the init acknowledges the latch, `$D019` = $0F, before
    /// it unmasks interrupts), not at once.
    @Test func firstIrqAfterDisplayInit() throws {
        let m = try Self.machine()
        m.io.writeVIC(0x1A, 0x00)
        let frame = VirtualClock.cyclesPerFrame, line = VirtualClock.cyclesPerLine
        // The scheduler runs from line 5 with raster IRQs off; displayInit comes at line $C0.
        m.clock.cycles = 3000 * frame + 5 * line
        let scheduler = InterruptScheduler(machine: m)
        scheduler.install()
        m.charge(Int((0xC0 - 5) * line))
        // Any raster IRQ moves the compare register from displayInit's $97 to $20 or $A3.
        m.displayInit()
        #expect(m.io.vic[0x12] == 0x97, "no IRQ inside displayInit (its color RAM fill ends before line $97)")
        var fired: UInt64?
        for _ in 0..<600 where fired == nil {
            m.charge(Int(line))
            if m.io.vic[0x12] != 0x97 { fired = m.clock.cycles }
        }
        scheduler.uninstall()
        let expected = 3001 * frame + 0x97 * line
        let at = try #require(fired, "a raster IRQ came")
        // Seen after the 65-cycle charge that passed the event and the handler's own cycles.
        #expect(at >= expected && at < expected + line + 300, "first IRQ seen at cycle \(at), want line $97 of the next frame (\(expected))")
    }

    /// `displayInit` with raster IRQs on and one pending (a restart: the VIC latched it while the
    /// cold init held the IRQ off), at line $C0, after the line $20 or $A3 the old compare value
    /// matched in this frame: the init acknowledges the latch (`$D019` = $0F) before it unmasks
    /// interrupts, so the VIC's IRQ line is down and no IRQ comes at the unmasking (the lab's VIC,
    /// like the C64's, takes none), and its new compare line $97 matches from then on, not at the
    /// line $97 that passed before it was stored: the first IRQ comes at line $97 of the next
    /// frame.
    @Test func acknowledgedLatchIsDropped() throws {
        for compare: UInt8 in [0x20, 0xA3] {
            let m = try Self.machine()
            m.io.writeVIC(0x12, compare)
            let frame = VirtualClock.cyclesPerFrame, line = VirtualClock.cyclesPerLine
            m.clock.cycles = 3000 * frame + 5 * line
            let scheduler = InterruptScheduler(machine: m)
            scheduler.install()
            m.interruptDisable = true                       // the cold init masks interrupts
            m.charge(Int(2 * frame))
            #expect(m.io.vicInterruptLatch & 0x01 != 0, "an IRQ is pending")
            m.charge(Int((0xC0 - 5) * line))
            // The first IRQ after displayInit stores $97: seen at the first scheduler call after its
            // handler moves the compare register (also one inside displayInit, as it unmasks).
            let service = m.eventHandler
            var stored97 = false, fired: UInt64?
            m.eventHandler = { m in
                service?(m)
                if m.io.vic[0x12] == 0x97 { stored97 = true } else if stored97 && fired == nil { fired = m.clock.cycles }
            }
            m.displayInit()
            #expect(m.io.vic[0x12] == 0x97, "compare $\(String(compare, radix: 16)): no IRQ at the init's CLI")
            for _ in 0..<600 where fired == nil {
                m.charge(Int(line))
            }
            scheduler.uninstall()
            let expected = 3003 * frame + 0x97 * line
            let at = try #require(fired, "a raster IRQ came")
            #expect(at >= expected && at < expected + line + 300,
                    "compare $\(String(compare, radix: 16)): first IRQ seen at cycle \(at), want line $97 of the next frame (\(expected))")
        }
    }

    /// RUN/STOP + RESTORE in normal mode against the original: the NMI handler sets the one-shot
    /// `$26FF` and jumps to $A7E2 with the interrupt flag the NMI set; the slot reloads overlay 0
    /// with two `readBlocks` (the overlay, then the root block), and each load's unmasking ($E698)
    /// lets in the IRQ the VIC latched during it; then $A946 sets the flag again for the boot
    /// loads, which bring `$26FF` = 0 back. The lab, whose VIC raises its IRQs as they come, and
    /// the port take the same two IRQs while `$26FF` = 1.
    @Test func restartTakesTheReloadIRQs() throws {
        // The original on the lab machine (raster IRQs taken as the VIC raises them).
        let data = try #require(Original.data)
        let lab = Lab.boot(data)
        try lab.play(try Session.parse(ReplaySessions.meigs + " down:RUNSTOP wait:10"), screenshots: nil)
        #expect(lab.bus.ram[R.restoreOneShot] == 0)
        // Per IRQ taken while `$26FF` = 1: how many loads had unmasked interrupts ($E698) by then.
        var labIRQs: [Int] = [], labLoads = 0, labSet = false
        lab.onInstruction = { [unowned lab] pc in
            if lab.bus.ram[R.restoreOneShot] != 0 {
                labSet = true
                if pc == 0xE698 { labLoads += 1 }
                if pc == 0x2285 { labIRQs.append(labLoads) }
            }
        }
        lab.pressNMI()
        lab.run(maxCycles: 60_000_000) { m in labSet && m.bus.ram[R.restoreOneShot] == 0 }
        lab.onInstruction = nil
        #expect(labSet && lab.bus.ram[R.restoreOneShot] == 0, "the original restarted and reached the boot loads")

        // The port in normal mode, from regular flight: IRQs counted by the compare register each
        // handler moves ($20 ↔ $A3), seen at every scheduler call (the handlers' own charges come
        // back here too), so two IRQs in one service count twice; a load is over when `$08DA`
        // goes back to 0 (just before it unmasks interrupts).
        let m = try Self.machine()
        let scheduler = InterruptScheduler(machine: m)
        var frame = 0
        scheduler.onFrameEnd = { m, _ in
            frame += 1
            var k = KeyMatrix()
            if frame < 30 { k.set(.runStop, pressed: true) }
            if frame == 12 { scheduler.requestNMI() }
            m.io.keyboard = k
        }
        scheduler.install()
        let service = m.eventHandler
        var portIRQs: [Int] = [], portLoads = 0, portSet = false
        var compare = m.io.vic[0x12], loading = m.mem[R.diskLoading]
        func observe(_ m: Machine) {
            defer { compare = m.io.vic[0x12]; loading = m.mem[R.diskLoading] }
            guard portSet else { return }
            if loading != 0 && m.mem[R.diskLoading] == 0 { portLoads += 1 }
            if m.io.vic[0x12] != compare && [0x20, 0xA3].contains(m.io.vic[0x12]) { portIRQs.append(portLoads) }
        }
        m.eventHandler = { m in
            if m.mem[R.restoreOneShot] != 0 { portSet = true }
            observe(m)
            service?(m)
            observe(m)
            if portSet && m.mem[R.restoreOneShot] == 0 {
                m.abandonStack?(nil)                        // the boot loads cleared the one-shot
            }
        }
        let ending = ProgramThread.run(m) { m in m.runMainLoop(fromEntry: false) }
        scheduler.uninstall()
        #expect(ending == .abandoned(nil), "the restart reached the boot loads")
        #expect(labIRQs == [1, 2], "the original takes one IRQ after each load of the reload: \(labIRQs)")
        #expect(portIRQs == labIRQs, "port \(portIRQs.count): \(portIRQs.prefix(12)), original \(labIRQs)")
    }

    /// The editor cache transfer ($E6DB/$E6D8) runs with interrupts masked: the raster events of
    /// its 12 frames are held and the one the VIC latched is taken once it unmasks them; then the
    /// IRQs go on.
    @Test func editorCacheSwapHoldsTheIRQ() throws {
        let m = try Self.machine()
        let scheduler = InterruptScheduler(machine: m)
        scheduler.install()
        m.charge(Int(VirtualClock.cyclesPerFrame))
        let jiffy = m.mem[R.jiffyCounter], start = m.clock.cycles
        m.swapEditorCache()
        let frames = (m.clock.cycles - start) / VirtualClock.cyclesPerFrame
        let during = Int(m.mem[R.jiffyCounter] &- jiffy)
        for _ in 0..<4 { m.charge(Int(VirtualClock.cyclesPerFrame)) }
        let after = Int(m.mem[R.jiffyCounter] &- jiffy) - during
        scheduler.uninstall()
        #expect(frames >= 10, "the swap takes \(frames) frames")
        #expect(during <= 1, "\(during) frame ticks during the swap: at most the latched IRQ")
        #expect((3...5).contains(after), "\(after) frame ticks in the 4 frames after it")
    }

    /// RUN/STOP + RESTORE in normal mode: the NMI at the next poll takes the cold restart
    /// (nested inside the interrupted frames), the boot loads run again, the title and the prompts
    /// wait for keys (A, B), and the main loop starts again; the run then ends there
    /// (`ProgramThread` leaves the frames).
    @Test func restartInNormalMode() throws {
        let m = try Self.machine()
        let scheduler = InterruptScheduler(machine: m)
        var frame = 0, sawColdStart = false, prompts = 0, keyFrames = 0, waiting = false
        var titleRows: [UInt8] = []
        scheduler.onFrameEnd = { m, _ in
            frame += 1
            var k = KeyMatrix()
            if frame < 30 { k.set(.runStop, pressed: true) }
            if frame == 12 { scheduler.requestNMI() }
            if m.u16(0xA7E0) == 0xAD00 { sawColdStart = true }
            // A prompt's key wait after the restart: interrupts on (the init unmasked them), text
            // input ($08BA = 1) and paused. A for the display prompt, B for the mode prompt.
            let inWait = sawColdStart && !m.interruptDisable && m.mem[R.editorRequest] == 1 && m.mem[R.pauseCount] != 0
            if inWait && !waiting {
                prompts += 1
                keyFrames = 0
                if prompts == 1 { titleRows = Array(UnsafeBufferPointer(start: m.mem + 0x4000, count: 0x1180)) }
            }
            waiting = inWait
            if inWait {
                keyFrames += 1
                if keyFrames > 8 && keyFrames <= 20 { k.set(prompts == 1 ? .a : .b, pressed: true) }
            }
            m.io.keyboard = k
        }
        m.mainLoopHook = { _ in !sawColdStart }
        scheduler.install()
        let ending = ProgramThread.run(m) { m in m.runMainLoop(fromEntry: false) }
        scheduler.uninstall()
        #expect(ending == .abandoned(nil), "the nested run ended at its main loop")
        #expect(sawColdStart)
        #expect(m.mem[R.restoreOneShot] == 0, "the boot load cleared the one-shot")
        #expect(m.u16(0xA7E0) == 0xA800, "the flight overlay is resident again")
        #expect(m.mem[0x0E69] == 0x0B, "A chose the color display")
        #expect(m.mem[R.demoRequest] == 0, "B chose regular flight")
        #expect(prompts == 2, "two prompts: \(prompts)")
        #expect(titleRows.contains { $0 != 0 }, "the title was drawn")
    }
}
