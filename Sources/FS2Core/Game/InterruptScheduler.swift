/// Normal (non-replay) mode: the C64's interrupts on the virtual clock.
///
/// The VIC raises a raster IRQ when the raster line equals the compare register (`$D012` with
/// bit 8 in `$D011`) while `$D01A` bit 0 is set: once per frame at that line. The game moves the
/// compare register between line $20 and line $A3 in its handler, so the scheduler computes the
/// next event from the register's current value after every handler. `Machine.charge` calls the
/// scheduler whenever the clock reaches `nextEventCycle`; a long charge (a disk load, a busy wait)
/// stops at every event on its way, so each handler runs at its own cycle and charges its own time.
///
/// While the main program has interrupts disabled (`Machine.interruptDisable`, set and cleared by
/// `sei()`/`cli()` where the original masks and unmasks them, among them the disk loads
/// $E668/$E698) a raster event only sets the VIC's latch; the one pending IRQ is taken as soon as
/// the flag clears (`cli`), and events in between are lost, as on the C64. A latch the program
/// acknowledges meanwhile (`$D019`, as `displayInit` does before it unmasks interrupts in a
/// restart) drops the pending IRQ: the VIC's IRQ line is the latch. The scheduler never re-enters
/// itself: charges made by the handlers it runs do not run it again.
///
/// RESTORE (`requestNMI`) is taken at the next poll point ($2330's hook), where the lab's replay
/// recorder takes it too. `onFrameEnd` is called at every frame boundary (line 0) for the host.
public final class InterruptScheduler {
    public unowned let machine: Machine
    /// Called at each frame boundary with the cycle at which the frame ended.
    public var onFrameEnd: ((Machine, UInt64) -> Void)?

    private var running = false
    private var irqLatched = false
    private var nmiRequested = false
    /// The time of the last raster event handled (the search for the next one starts after it).
    private var lastRasterEvent: UInt64 = 0
    private var nextFrameEnd: UInt64 = 0
    /// Whether raster IRQs (`$D01A` bit 0) were on at the last service.
    private var rasterEnabled = false
    /// The compare line as the scheduler last left it (after a service, and after each handler it
    /// ran). A different one at the next service was stored by the main program meanwhile.
    private var compareSeen: UInt64 = 0

    public init(machine: Machine) {
        self.machine = machine
    }

    /// Takes over `eventHandler` and `pollHandler` from the current clock on.
    public func install() {
        let now = machine.clock.cycles
        lastRasterEvent = now
        rasterEnabled = machine.io.vic[0x1A] & 0x01 != 0
        compareSeen = compareLine
        nextFrameEnd = (now / VirtualClock.cyclesPerFrame + 1) * VirtualClock.cyclesPerFrame
        machine.eventHandler = { [unowned self] m in self.service(m) }
        machine.pollHandler = { [unowned self] m in self.poll(m) }
        machine.nextEventCycle = now
    }

    /// Removes the handlers.
    public func uninstall() {
        machine.eventHandler = nil
        machine.pollHandler = nil
        machine.nextEventCycle = .max
    }

    /// RESTORE: an NMI at the next poll point.
    public func requestNMI() { nmiRequested = true }

    /// Whether the main program holds IRQs off now: its interrupt flag (a scenery or overlay load
    /// included: `readBlocks` masks them from $E668 to $E698; the editor's library disk I/O from
    /// $B1F8/$B227 to $B23D; the text-mode swap $2673).
    func masked(_ m: Machine) -> Bool {
        m.interruptDisable
    }

    /// The first cycle after `cycle` at which the VIC raises a raster IRQ with its current
    /// registers, or nil when raster IRQs are off.
    public func nextRasterEvent(after cycle: UInt64) -> UInt64? {
        guard machine.io.vic[0x1A] & 0x01 != 0 else { return nil }
        let line = compareLine
        guard line < VirtualClock.linesPerFrame else { return nil }
        let frame = VirtualClock.cyclesPerFrame
        var t = cycle / frame * frame + line * VirtualClock.cyclesPerLine
        if t <= cycle { t += frame }
        return t
    }

    /// The raster compare line: `$D012` with bit 8 in `$D011`.
    private var compareLine: UInt64 {
        UInt64(machine.io.vic[0x12]) | UInt64(machine.io.vic[0x11] & 0x80) << 1
    }

    private func service(_ m: Machine) {
        guard !running else { return }
        running = true
        defer { running = false }
        while true {
            let now = m.clock.cycles
            // Raster IRQs just turned on ($25EB: `$D01A` = 1, the latch acknowledged with `$D019` =
            // $0F, then interrupts unmasked, which brings the scheduler in at once): the first IRQ
            // comes at the next compare match, not at one that passed while they were off.
            let enabled = m.io.vic[0x1A] & 0x01 != 0
            if enabled && !rasterEnabled { lastRasterEvent = max(lastRasterEvent, now) }
            rasterEnabled = enabled
            // The main program moved the compare register (`displayInit`'s line $97, followed by
            // its unmasking, which brings the scheduler in at once): the new line matches from now
            // on, not at a line that passed under the old value (a restart, the editor's exit:
            // raster IRQs stay on).
            if compareLine != compareSeen {
                lastRasterEvent = max(lastRasterEvent, now)
                compareSeen = compareLine
            }
            if irqLatched && m.io.vicInterruptLatch & 0x01 == 0 {
                // The program acknowledged the latch (`$D019`) while it held the IRQ off: the
                // VIC's IRQ line dropped, nothing is pending any more.
                irqLatched = false
            }
            if irqLatched && !masked(m) {
                irqLatched = false
                m.io.vicInterruptLatch &= ~0x01
                m.irq()
                compareSeen = compareLine
                continue
            }
            let raster = nextRasterEvent(after: lastRasterEvent)
            if let t = raster, t <= now, t <= nextFrameEnd {
                lastRasterEvent = t
                if masked(m) {
                    irqLatched = true
                    m.io.vicInterruptLatch |= 0x01
                } else {
                    m.irq()
                    compareSeen = compareLine
                }
                continue
            }
            if nextFrameEnd <= now {
                let end = nextFrameEnd
                nextFrameEnd += VirtualClock.cyclesPerFrame
                if raster == nil { lastRasterEvent = max(lastRasterEvent, end) }
                onFrameEnd?(m, end)
                continue
            }
            // A latched IRQ waits for the flag to clear: `Machine.interruptDisable` brings the
            // scheduler back in at the next charge when it does.
            var next = nextFrameEnd
            if let t = raster { next = min(next, t) }
            m.nextEventCycle = next
            return
        }
    }

    private func poll(_ m: Machine) {
        guard nmiRequested else { return }
        nmiRequested = false
        m.nmi()
    }
}
