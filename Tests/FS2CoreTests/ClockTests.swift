import FS2Core
import Testing

/// The virtual clock (`Machine.charge`, `Machine.elapse`): the cycles the VIC-II steals from the
/// CPU (`Machine.vicDMA`), and events taken at their own cycles inside long charges. The model is
/// proved against the lab's VIC in `DifferentialTests/VICDMATests.swift`.
struct ClockTests {
    static let frame = VirtualClock.cyclesPerFrame
    static let line = VirtualClock.cyclesPerLine

    /// A machine with the VIC as the game has it in flight: bitmap mode with the display on and
    /// YSCROLL 3 (`$D011` = $3B), the four attitude-indicator sprites at Y $AA and $B5; the clock at
    /// `cycle`.
    static func flight(dma: Bool = true, at cycle: UInt64 = 0) -> Machine {
        let m = Machine(memory: [UInt8](repeating: 0, count: Machine.memorySize))
        m.clock.cycles = cycle
        m.io.writeVIC(0x11, 0x3B)
        m.io.writeVIC(0x15, 0x0F)
        for (n, y) in [0xAA, 0xAA, 0xB5, 0xB5].enumerated() { m.io.writeVIC(n * 2 + 1, UInt8(y)) }
        m.vicDMA = dma
        return m
    }

    /// xorshift64* for random slicing.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
    }

    /// In flight the VIC takes 25 badlines × 40 and 4 sprites × 21 lines × 2 = 1,168 cycles of
    /// every frame: a frame holds 15,927 cycles of CPU work, charged at once or in pieces.
    @Test func aFrameOfWorkInFlight() {
        let m = Self.flight(at: 100 * Self.frame)
        m.charge(15_927)
        #expect(m.clock.cycles == 101 * Self.frame)
        var rng = Random(state: 0xD1A)
        var left = 10 * 15_927
        while left > 0 {
            let n = min(left, Int(rng.next() % 400))
            m.charge(n)
            left -= n
        }
        #expect(m.clock.cycles == 111 * Self.frame)
    }

    /// The text screen and the disk loads (sprites off): 25 badlines, 1,000 cycles a frame. With the
    /// display off nothing is taken; with DMA off neither.
    @Test func otherRegisterStates() {
        let text = Self.flight(at: 7 * Self.frame)
        text.io.writeVIC(0x11, 0x1B)
        text.io.writeVIC(0x15, 0x00)
        text.charge(Int(Self.frame) - 1_000)
        #expect(text.clock.cycles == 8 * Self.frame)

        let blank = Self.flight()
        blank.io.writeVIC(0x11, 0x0B)
        blank.io.writeVIC(0x15, 0x00)
        blank.charge(3 * Int(Self.frame))
        #expect(blank.clock.cycles == 3 * Self.frame)

        let off = Self.flight(dma: false)
        off.charge(3 * Int(Self.frame))
        #expect(off.clock.cycles == 3 * Self.frame)
    }

    /// `elapse` is wall time: the VIC's windows are in it already. A charge after it waits out
    /// only the windows still ahead.
    @Test func elapseIgnoresTheWindows() {
        let m = Self.flight(at: 20 * Self.frame)
        m.elapse(Int(Self.frame) + 0x33 * Int(Self.line) + 10)       // into the first badline's window
        #expect(m.clock.cycles == 21 * Self.frame + 0x33 * Self.line + 10)
        m.charge(8 * Int(Self.line) - 10)                             // to the next badline, $3B,
        #expect(m.clock.cycles == 21 * Self.frame + 0x3B * Self.line + 40)   // whose window it waits out
        m.charge(1)
        #expect(m.clock.cycles == 21 * Self.frame + 0x3B * Self.line + 41)
        // Wall time that ends where a window starts: the CPU waits it out too.
        m.elapse(Int(0x43 - 0x3B) * Int(Self.line) - 41)
        #expect(m.clock.cycles == 21 * Self.frame + 0x43 * Self.line + 40)
    }

    /// A line's window is taken as soon as the clock reaches the line's start (as the lab's VIC
    /// decides the stall when the instruction that reaches the line ends).
    @Test func windowsAtLineStarts() {
        let badline = 30 * Self.frame + 0x33 * Self.line
        let m = Self.flight(at: badline - 5)
        m.charge(5)
        #expect(m.clock.cycles == badline + 40)
        m.charge(0)
        #expect(m.clock.cycles == badline + 40)
        m.charge(2)
        #expect(m.clock.cycles == badline + 42)
        // A sprite line that is also a badline ($AB, YSCROLL 3): 40 + 2 + 2.
        let both = 30 * Self.frame + 0xAB * Self.line
        m.charge(Int(both - m.clock.cycles) - 40 * ((0xA3 - 0x3B) / 8 + 1) - 1)   // the badlines $3B-$A3 between
        #expect(m.clock.cycles == both - 1)
        m.charge(2)
        #expect(m.clock.cycles == both + 44 + 1)
    }

    /// Register changes count from the next line start: the sprites turned off mid-frame take
    /// nothing more.
    @Test func registerChangesApplyFromTheNextLine() {
        let start = 40 * Self.frame
        let m = Self.flight(at: start)
        m.charge(0xB0 * Int(Self.line))         // up to line $B0 or so: the sprites have begun
        let mid = m.clock.cycles
        m.io.writeVIC(0x15, 0x00)
        var work = Int(start + Self.frame - mid)
        // The rest of the frame without sprites: the badlines from here on only.
        let badlinesLeft = (0xB0...0xF7).filter { $0 & 7 == 3 && UInt64($0) * Self.line >= mid - start }.count
        work -= 40 * badlinesLeft
        m.charge(work)
        #expect(m.clock.cycles == start + Self.frame, "ended at \(Int(m.clock.cycles) - Int(start + Self.frame)) from the frame end")
    }

    /// Events inside a long charge run at their own cycles (one inside a window when the window
    /// ends), and slicing the work at events changes nothing: the same work ends at the same
    /// cycle with events anywhere.
    @Test func eventsStopTheClock() {
        let start = 50 * Self.frame
        let m = Self.flight(at: start)
        let targets: [UInt64] = [start + 1_000, start + 0x33 * Self.line, start + 0x3B * Self.line + 10,
                                 start + Self.frame, start + 3 * Self.frame + 7]
        var seen: [UInt64] = []
        var pending = targets
        m.nextEventCycle = pending.removeFirst()
        m.eventHandler = { mm in
            seen.append(mm.clock.cycles)
            mm.nextEventCycle = pending.isEmpty ? .max : pending.removeFirst()
        }
        m.charge(4 * 15_927)
        #expect(seen == [start + 1_000, start + 0x33 * Self.line + 40, start + 0x3B * Self.line + 40,
                         start + Self.frame, start + 3 * Self.frame + 7])
        #expect(m.clock.cycles == start + 4 * Self.frame)

        var rng = Random(state: 0x5EED)
        for round in 0..<20 {
            let begin = start + rng.next() % Self.frame
            let r = Self.flight(at: begin)
            let plain = Self.flight(at: begin)
            let total = Int(rng.next() % 200_000)
            plain.charge(total)
            r.nextEventCycle = begin + rng.next() % 5_000
            var events = 0
            r.eventHandler = { mm in
                events += 1
                mm.nextEventCycle = mm.clock.cycles + 1 + rng.next() % 3_000
            }
            var left = total
            while left > 0 {
                let n = min(left, Int(rng.next() % 30_000))
                if rng.next() % 3 == 0 { r.elapse(0) }
                r.charge(n)
                left -= n
            }
            #expect(r.clock.cycles == plain.clock.cycles, "round \(round): \(events) events")
        }
    }

    /// The same charges and wall-time stretches end at the same cycle whatever events stop the
    /// clock on the way (a host's run targets fall anywhere, on a window's start too).
    @Test func eventsChangeNothingInWallTime() {
        var rng = Random(state: 0xE1A5)
        for round in 0..<40 {
            let begin = 60 * Self.frame + rng.next() % Self.frame
            var steps: [(wall: Bool, cycles: Int)] = []
            for _ in 0..<(1 + rng.next() % 12) {
                // Some stretches end exactly on a line start (a badline's in flight, often).
                var n = Int(rng.next() % 60_000)
                if rng.next() % 4 == 0 { n = Int(Self.line) * Int(1 + rng.next() % 500) }
                steps.append((rng.next() % 2 == 0, n))
            }
            let plain = Self.flight(at: begin)
            for s in steps { if s.wall { plain.elapse(s.cycles) } else { plain.charge(s.cycles) } }
            let r = Self.flight(at: begin)
            var events = 0
            r.nextEventCycle = begin + rng.next() % 3_000
            r.eventHandler = { mm in
                events += 1
                // Half of them on a line start, so on windows' starts.
                var next = mm.clock.cycles + 1 + rng.next() % 4_000
                if rng.next() % 2 == 0 { next = (next / Self.line + 1) * Self.line }
                mm.nextEventCycle = next
            }
            for s in steps { if s.wall { r.elapse(s.cycles) } else { r.charge(s.cycles) } }
            #expect(r.clock.cycles == plain.clock.cycles, "round \(round): \(events) events, \(steps.count) steps")
        }
    }

    /// A handler that does not move `nextEventCycle` (one that does not re-enter itself) is called
    /// once per charge, and the rest of the charge runs through.
    @Test func handlerThatDoesNotMoveTheEvent() {
        let m = Self.flight(dma: false)
        var calls = 0
        m.nextEventCycle = 100
        m.eventHandler = { _ in calls += 1 }
        m.charge(1_000)
        #expect(calls == 1 && m.clock.cycles == 1_000)
        m.charge(10)
        #expect(calls == 2 && m.clock.cycles == 1_010)
    }

    /// Clearing the interrupt flag brings the event handler in at the next charge, so a raster
    /// IRQ the VIC latched meanwhile is taken at once: at the end of that charge (the unmasking
    /// and what follows it), the port's next instruction boundary. Here the editor cache swap
    /// $E6DB (interrupts masked, 21 pages copied, unmasked, return): the handler runs once, as the
    /// swap returns. An event already due when a charge begins never runs before its work; one
    /// inside it stops it.
    @Test func cliBringsTheHandler() {
        let m = Self.flight(dma: false)
        var calls: [UInt64] = []
        m.eventHandler = { mm in calls.append(mm.clock.cycles); mm.nextEventCycle = .max }
        m.swapEditorCache()
        #expect(calls == [m.clock.cycles] && !m.interruptDisable, "\(calls) at the end \(m.clock.cycles)")
        let end = m.clock.cycles
        m.nextEventCycle = end + 20
        m.charge(0)
        m.charge(30)
        #expect(calls == [end, end + 20] && m.clock.cycles == end + 30)
    }

    /// An NMI taken with the flag clear masks the IRQ for its handler: a raster event inside it
    /// only latches, and its return from interrupt lets that IRQ in at once (the scheduler runs at
    /// the end of the next charge), as unmasking does, not a frame later at the next raster event.
    /// Both vectors point at a bare return from interrupt ($790A) here.
    @Test func nmiReturnTakesTheLatchedIRQ() {
        let m = Self.flight(dma: false)
        m.setU16(0xFFFA, 0x790A)
        m.setU16(0xFFFE, 0x790A)
        m.io.writeVIC(0x12, 0x20)
        m.io.writeVIC(0x1A, 0x01)
        let raster = 10 * Self.frame + 0x20 * Self.line
        m.clock.cycles = raster - 3
        let scheduler = InterruptScheduler(machine: m)
        scheduler.install()
        m.charge(0)                                         // the scheduler's first service
        m.nmi()                                             // its entry passes line $20
        #expect(m.io.vicInterruptLatch & 0x01 != 0 && !m.interruptDisable, "the raster IRQ latched under the NMI")
        let back = m.clock.cycles
        #expect(back == raster - 3 + 7 + 6)
        m.charge(2)
        #expect(m.io.vicInterruptLatch & 0x01 == 0, "the IRQ held is taken after the NMI's RTI")
        #expect(m.clock.cycles == back + 2 + 7 + 6, "the next instruction, then the IRQ: at \(Int(m.clock.cycles) - Int(back))")
        scheduler.uninstall()
    }
}
