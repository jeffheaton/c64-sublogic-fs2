import C64Kit
import FS2Core
import Foundation
import M6502

/// Deterministic replay recording.
///
/// The original's only asynchronous inputs are the raster IRQ (two per frame: display split,
/// jiffy and task counters, sound pattern player, keyboard scan), RESTORE (NMI), and I/O reads
/// (CIA time of day, ports). In recording mode the lab stops taking raster IRQs asynchronously and
/// delivers them only at the program's own poll points — the two calls of its 10 Hz task tick,
/// to $2012 from $8752 (once per scenery opcode) and to $2330 from $2268 (wait-for-key loop) — in
/// exactly the order and number the VIC would have raised them. It logs how many were delivered at
/// which poll, with the inputs in effect, plus every I/O value the main program read. The port
/// replays the same log through its own poll points and I/O shadows, so both sides compute from
/// identical asynchronous inputs and their memory can be compared exactly.
///
/// RESTORE: a session's `nmi` step reaches the recorder (`pressRestore`, through
/// `C64Machine.replayRecorder`), which delivers it at the next poll after the IRQs due there. The
/// RUN/STOP + RESTORE restart leaves the NMI handler with a jump to $A7E2 and never returns; the
/// batch ends when the PC reaches $A7E2 and recording goes on (the cold start, the title, flight).
/// Each checkpoint also keeps how many I/O reads were logged by then (`Checkpoint.ioReads`).
public final class ReplayRecorder {
    public static let pollSites = ReplayLog.pollSites
    /// $A7E2: the cold start, where the RESTORE restart leaves its NMI handler for good.
    static let coldStartEntry: UInt16 = 0xA7E2
    public typealias Log = ReplayLog
    typealias Delivery = ReplayLog.Delivery
    typealias IORead = ReplayLog.IORead
    typealias Checkpoint = ReplayLog.Checkpoint

    public private(set) var log = Log()
    /// Full memory images at each checkpoint, for diagnosing a mismatch (optional).
    public var keepImages = false
    public private(set) var images: [[UInt8]] = []

    private unowned let machine: C64Machine
    private var pollIndex = 0
    /// Cycle up to which raster events have been delivered.
    private var deliveredUntil: UInt64
    private var inHandler = false
    private var handlerReturnSP: UInt8 = 0
    private var pendingNMI = false

    public init(machine: C64Machine) {
        self.machine = machine
        deliveredUntil = machine.cpu.cycles
        machine.quantizedIRQs = true
        machine.replayRecorder = self
        for site in Self.pollSites { machine.cpu.traps[Int(site)] = true }
        machine.cpu.traps[0x204B] = true
        let previousTrap = machine.cpu.trapHandler
        machine.cpu.trapHandler = { [unowned self] pc in
            if Self.pollSites.contains(pc) && !self.inHandler, self.poll(at: pc) { return true }
            if pc == 0x204B && !self.inHandler { self.checkpoint() }
            return previousTrap?(pc) ?? false
        }
        machine.bus.ioReadHook = { [unowned self] address, value in
            guard !self.inHandler, !self.inLoader else { return }
            self.log.ioReads.append(IORead(address: UInt16(address), value: value))
        }
        let previousInstruction = machine.onInstruction
        machine.onInstruction = { [unowned self] pc in
            // The handler batch ends when its return from interrupt brings the stack back to
            // where it was.
            if self.inHandler && machine.cpu.sp == self.handlerReturnSP && Self.pollSites.contains(pc) {
                self.inHandler = false
            }
            // ... or when the NMI handler's RUN/STOP + RESTORE restart jumps to the cold start
            // (the jump at $2700), which never returns: the program goes on from there, and its
            // next poll is a new one (the port's driver counts the same way).
            if self.inHandler && pc == Self.coldStartEntry {
                self.inHandler = false
                self.resumingSamePoll = false
            }
            previousInstruction?(pc)
        }
    }

    /// The SubLogic disk layer: the port replaces it with direct block access, so its I/O is not logged.
    private var inLoader: Bool { (0x7300...0x7909).contains(Int(machine.cpu.pc)) }

    public func pressRestore() { pendingNMI = true }

    /// Raster lines at which the VIC raises IRQs, given the compare register (one per frame).
    private func nextRasterEvent(after cycle: UInt64) -> UInt64? {
        let bus = machine.bus
        guard bus.vicRegs[0x1A] & 0x01 != 0 else { return nil }
        let line = UInt64(bus.rasterCompare)
        guard line < UInt64(C64Machine.linesPerFrame) else { return nil }
        // Frame-relative timing: the machine's current line start anchors the raster grid.
        let frameStart = machine.lineStart - UInt64(bus.rasterLine) * C64Machine.cyclesPerLine
        var t = frameStart + line * C64Machine.cyclesPerLine
        while t <= cycle { t += C64Machine.cyclesPerFrame }
        while t > cycle + C64Machine.cyclesPerFrame { t -= C64Machine.cyclesPerFrame }
        return t
    }

    /// At a poll site: run the next pending interrupt (if any) by building an interrupt frame that
    /// returns to this same instruction; when it returns, the trap fires again for the next one.
    private func poll(at pc: UInt16) -> Bool {
        let cpu = machine.cpu
        if !resumingSamePoll { pollIndex += 1 }
        resumingSamePoll = false
        guard !cpu.interruptDisable else { return false }
        if let t = nextRasterEvent(after: deliveredUntil), t <= cpu.cycles {
            deliveredUntil = t
            record(irq: true)
            enterHandler(vector: 0xFFFE)
            return true
        }
        if pendingNMI {
            pendingNMI = false
            record(irq: false, nmi: true)
            enterHandler(vector: 0xFFFA)
            return true
        }
        return false
    }

    private var resumingSamePoll = false

    private func record(irq: Bool, nmi: Bool = false) {
        let k = machine.bus.keyboard
        if var last = log.deliveries.last, last.poll == pollIndex, last.keyColumns == k.columns,
           last.joystick1 == k.joystick1.rawValue, last.joystick2 == k.joystick2.rawValue, !last.nmi {
            if irq { last.irqs += 1 }
            last.nmi = nmi
            log.deliveries[log.deliveries.count - 1] = last
        } else {
            log.deliveries.append(Delivery(poll: pollIndex, irqs: irq ? 1 : 0, keyColumns: k.columns,
                                           joystick1: k.joystick1.rawValue, joystick2: k.joystick2.rawValue,
                                           nmi: nmi))
        }
    }

    private func enterHandler(vector: UInt16) {
        let cpu = machine.cpu
        let bus = machine.bus
        handlerReturnSP = cpu.sp
        bus.write(0x0100 | UInt16(cpu.sp), UInt8(cpu.pc >> 8)); cpu.sp &-= 1
        bus.write(0x0100 | UInt16(cpu.sp), UInt8(cpu.pc & 0xFF)); cpu.sp &-= 1
        bus.write(0x0100 | UInt16(cpu.sp), cpu.status & ~0x10); cpu.sp &-= 1
        cpu.interruptDisable = true
        cpu.pc = UInt16(bus.read(vector)) | UInt16(bus.read(vector &+ 1)) << 8
        cpu.cycles += 7
        inHandler = true
        resumingSamePoll = true
    }

    private func checkpoint() {
        let ram = machine.bus.ram
        let h = ram.withUnsafeBufferPointer { ReplayLog.memoryHash($0.baseAddress!) }
        log.checkpoints.append(Checkpoint(poll: pollIndex, cycle: machine.cpu.cycles, memoryHash: h,
                                          ioReads: log.ioReads.count))
        if keepImages { images.append(ram) }
    }

    public func write(to url: URL) throws { try log.write(to: url) }
}
