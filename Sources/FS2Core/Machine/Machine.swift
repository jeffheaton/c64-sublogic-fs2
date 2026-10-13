import C64Kit

/// The port's state: the 64 KB memory image the original code works on, the I/O the original
/// touches (as shadows, never mapped into memory), and the virtual NTSC clock.
///
/// Porting rule: a translated routine reads and writes every byte its original reads and writes,
/// at the same addresses — including zero-page temporaries and self-modified code bytes — so the
/// whole image can be compared against the original running in the lab.
public final class Machine {
    public static let memorySize = 0x10000

    /// The memory image. $D000-$DFFF is plain RAM here (the original uses it as RAM under I/O);
    /// hardware registers go through `io`.
    public let mem: UnsafeMutablePointer<UInt8>
    public var io = IO()
    public var clock = VirtualClock()
    /// SubLogic's 164 logical disk blocks (1 KB each), for scenery streaming and overlay loads,
    /// which the port performs as direct copies instead of running the IEC loader.
    public var diskBlocks: [[UInt8]] = []
    /// The library disk behind CTRL-X / CTRL-Z (nil: no library disk; both keys then show the
    /// editor's disk-error line). The native engine installs a file-backed store; tests use
    /// `ModeLibrary.InMemoryStore`.
    public var modeLibraryIO: ModeLibrary.IO?

    public init(memory: [UInt8]) {
        precondition(memory.count == Self.memorySize)
        mem = .allocate(capacity: Self.memorySize)
        mem.initialize(from: memory, count: Self.memorySize)
    }

    deinit { mem.deallocate() }

    /// A copy of the memory image (for snapshots and comparisons).
    public var memoryImage: [UInt8] { Array(UnsafeBufferPointer(start: mem, count: Self.memorySize)) }

    public func load(memory: [UInt8]) {
        precondition(memory.count == Self.memorySize)
        mem.update(from: memory, count: Self.memorySize)
    }

    // MARK: Byte access

    @inline(__always) public subscript(_ address: Int) -> UInt8 {
        get { mem[address & 0xFFFF] }
        set { mem[address & 0xFFFF] = newValue }
    }

    /// 6502-style zero-page indexed address (wraps within page 0).
    @inline(__always) public static func zp(_ base: Int, _ index: UInt8) -> Int { (base + Int(index)) & 0xFF }

    // MARK: Little-endian words

    @inline(__always) public func u16(_ a: Int) -> UInt16 { UInt16(self[a]) | UInt16(self[a + 1]) << 8 }
    @inline(__always) public func s16(_ a: Int) -> Int16 { Int16(bitPattern: u16(a)) }
    @inline(__always) public func setU16(_ a: Int, _ v: UInt16) {
        self[a] = UInt8(v & 0xFF); self[a + 1] = UInt8(v >> 8)
    }
    @inline(__always) public func setS16(_ a: Int, _ v: Int16) { setU16(a, UInt16(bitPattern: v)) }

    /// Zero-page pointer (wraps at $FF like the 6502).
    @inline(__always) public func zpPointer(_ a: Int) -> Int {
        Int(self[a & 0xFF]) | Int(self[(a + 1) & 0xFF]) << 8
    }

    @inline(__always) public func u24(_ a: Int) -> UInt32 {
        UInt32(self[a]) | UInt32(self[a + 1]) << 8 | UInt32(self[a + 2]) << 16
    }
    @inline(__always) public func setU24(_ a: Int, _ v: UInt32) {
        self[a] = UInt8(v & 0xFF); self[a + 1] = UInt8((v >> 8) & 0xFF); self[a + 2] = UInt8((v >> 16) & 0xFF)
    }
    @inline(__always) public func u32(_ a: Int) -> UInt32 { u24(a) | UInt32(self[a + 3]) << 24 }
    @inline(__always) public func s32(_ a: Int) -> Int32 { Int32(bitPattern: u32(a)) }
    @inline(__always) public func setU32(_ a: Int, _ v: UInt32) { setU24(a, v); self[a + 3] = UInt8(v >> 24) }
    @inline(__always) public func setS32(_ a: Int, _ v: Int32) { setU32(a, UInt32(bitPattern: v)) }

    // MARK: Cycle accounting and the interrupt-equivalent schedule

    /// Cycle at which `eventHandler` must next run (the raster-IRQ equivalents at lines $20/$A3,
    /// the frame ends, a host's run target). Set by the scheduler.
    public var nextEventCycle: UInt64 = .max
    public var eventHandler: ((Machine) -> Void)?
    /// The original polls its 10 Hz task tick ($2012 → $2330) once per scenery opcode and from
    /// its wait loops; translated code calls `poll()` at those same points.
    public var pollHandler: ((Machine) -> Void)?

    /// Charges modeled 6502 cycles for work just done (drives Authentic pacing and the
    /// interrupt-equivalent schedule). With `vicDMA` on, the clock also passes the cycles the VIC
    /// steals from the CPU meanwhile.
    ///
    /// The clock stops at every event inside the charge: when it reaches `nextEventCycle`, the
    /// handler runs with the clock exactly there (or at the end of a stolen window the event fell
    /// into), then the rest of the work is charged. A routine that charges a long stretch at
    /// once (a disk load, a busy delay, the editor cache swap) therefore has its interrupts,
    /// frame ends and run targets at their own cycles, as on the C64, not all at the end. An
    /// event already due when the charge begins (a `CLI` lowered it) runs once the charge's work is
    /// done (or at its first stolen window), the next instruction boundary. When the handler leaves
    /// `nextEventCycle` where it was (a handler that does not re-enter itself), the rest of the
    /// charge runs without stopping.
    @inline(__always) public func charge(_ cycles: Int) {
        let end = clock.cycles &+ UInt64(cycles)
        if end < nextEventCycle && end < dmaNext && io.dmaGeneration == dmaGeneration {
            clock.cycles = end
            return
        }
        advanceClock(UInt64(cycles), stolen: true)
    }

    /// Lets `cycles` of wall-clock time pass: time measured on the lab with its VIC's DMA already
    /// in it (the IEC transfers of the loader, which wait on the drive) or a wait for a moment
    /// of the virtual time of day. Events inside run at their own cycles, as in `charge`; unlike
    /// `charge` it does not add the cycles the VIC steals (with `vicDMA` off they are the same).
    public func elapse(_ cycles: Int) {
        let end = clock.cycles &+ UInt64(cycles)
        if end < nextEventCycle && end < dmaNext && io.dmaGeneration == dmaGeneration {
            clock.cycles = end
            return
        }
        advanceClock(UInt64(cycles), stolen: false)
    }

    /// The slow path of `charge` and `elapse`: runs `cycles` of work (`stolen`: CPU cycles, which
    /// wait out the VIC's windows) or of wall time, stopping at the stolen windows and at
    /// `nextEventCycle`.
    ///
    /// A window is taken as soon as the clock reaches its line's start, as the lab's VIC decides a
    /// line's stall when the instruction that reaches the line ends: the clock never rests on a
    /// window's start, and a register stored then counts from the next line. Wall time includes
    /// the windows it passes, also where an event stops it; one that starts exactly where it ends
    /// is waited out like any other. So where events stop the clock never changes the result.
    @inline(never)
    private func advanceClock(_ cycles: UInt64, stolen: Bool) {
        var left = cycles
        var stopAtEvents = true
        while true {
            if io.dmaGeneration != dmaGeneration { syncDMA() }
            if clock.cycles >= dmaNext {
                takeDMAWindow(stolen: stolen, ended: left == 0)
            } else if left > 0 {
                var stop = clock.cycles &+ left
                if stolen { stop = min(stop, dmaNext) }
                // An event inside the work stops it there. One that was due before the work began
                // (a `CLI` brought the scheduler in, a handler left it) runs after this stretch,
                // at the end of the charge: the instruction boundary after the charged
                // instructions, whose memory effects are already made.
                if stopAtEvents && eventHandler != nil && nextEventCycle > clock.cycles {
                    stop = min(stop, nextEventCycle)
                }
                left -= stop - clock.cycles
                clock.cycles = stop
                if clock.cycles >= dmaNext { takeDMAWindow(stolen: stolen, ended: left == 0) }
            }
            if stopAtEvents, clock.cycles >= nextEventCycle, let handler = eventHandler {
                let before = nextEventCycle
                handler(self)
                // A handler that does not move it (one that does not re-enter itself, called from
                // its own charges): the rest of this charge runs through.
                if nextEventCycle <= before { stopAtEvents = false }
                continue
            }
            if left == 0 && clock.cycles < dmaNext { return }
        }
    }

    /// The window at `dmaNext`, which the clock has reached. CPU work (`stolen`) waits until its
    /// end; wall time only when it `ended` exactly at its start (the time it passed held it).
    /// Then the next window.
    private func takeDMAWindow(stolen: Bool, ended: Bool) {
        let start = dmaNext
        let end = start &+ UInt64(dmaStall[dmaLine(start)])
        if stolen ? clock.cycles < end : ended && clock.cycles == start { clock.cycles = end }
        dmaNext = firstDMAWindow(atOrAfter: max(start &+ 1, clock.cycles))
    }

    // MARK: The VIC's DMA

    /// Whether the clock models the cycles the VIC-II takes from the CPU, as the lab's VIC does
    /// (`C64Machine.endLine`): at the start of every raster line, 40 cycles on a badline (display
    /// enabled, lines $30-$F7 whose low three bits equal YSCROLL) and 2 for every enabled sprite
    /// displayed on the line, from the registers `io.vic` holds then (`IO.DMARegisters`). In flight
    /// (bitmap mode, YSCROLL 3, the four attitude-indicator sprites) that is 25 × 40 + 4 × 21 × 2 =
    /// 1,168 of every frame's 17,095 cycles; during a disk load (sprites off) and in the editor's
    /// text mode 1,000. `charge` (CPU work) waits out these windows, `elapse` (wall time) does not.
    ///
    /// Off by default: the routine tests compare the port's instruction cycles with the original's.
    /// `NativeEngine` turns it on, so Authentic passes take the C64's time.
    ///
    /// The clock follows register stores through `io.dmaGeneration`; an `io` replaced as a whole
    /// (or a clock set by hand) is not seen: set `vicDMA` again afterwards to bring the windows up
    /// to date.
    public var vicDMA = false {
        didSet { syncDMA() }
    }

    /// The start of the next stolen window, after the clock (`.max`: none, or `vicDMA` off).
    private var dmaNext: UInt64 = .max
    /// `io.dmaGeneration` when the windows were last brought up to date.
    private var dmaGeneration: UInt64 = 0
    /// The registers `dmaStall` was built for.
    private var dmaTableRegisters: IO.DMARegisters?
    /// Cycles stolen at the start of each raster line (0-262).
    private var dmaStall = [UInt8](repeating: 0, count: Int(VirtualClock.linesPerFrame))
    /// For each line 0...263, the first line at or after it with a window (counted on into the next
    /// frame: 263 + its line), or -1 when no line has one.
    private var dmaFirstLine = [Int](repeating: -1, count: Int(VirtualClock.linesPerFrame) + 1)

    /// Brings the windows up to date with the registers in `io` and the clock. A line that started
    /// at the clock's cycle has had its stall decided already (with the registers before): the
    /// windows count from the next line. Turn `vicDMA` on after setting the clock.
    private func syncDMA() {
        dmaGeneration = io.dmaGeneration
        guard vicDMA else {
            dmaNext = .max
            return
        }
        let registers = io.dmaRegisters
        if registers != dmaTableRegisters {
            dmaTableRegisters = registers
            let lines = Int(VirtualClock.linesPerFrame)
            for line in 0..<lines { dmaStall[line] = UInt8(registers.stolenCycles(line: line)) }
            let first = dmaStall.firstIndex { $0 != 0 }
            dmaFirstLine[lines] = first.map { lines + $0 } ?? -1
            for line in stride(from: lines - 1, through: 0, by: -1) {
                dmaFirstLine[line] = dmaStall[line] != 0 ? line : dmaFirstLine[line + 1]
            }
        }
        dmaNext = firstDMAWindow(atOrAfter: clock.cycles &+ 1)
    }

    /// The raster line a cycle falls on.
    @inline(__always)
    private func dmaLine(_ cycle: UInt64) -> Int {
        Int(cycle % VirtualClock.cyclesPerFrame / VirtualClock.cyclesPerLine)
    }

    /// The start of the first window at or after `cycle`.
    private func firstDMAWindow(atOrAfter cycle: UInt64) -> UInt64 {
        let frameStart = cycle / VirtualClock.cyclesPerFrame * VirtualClock.cyclesPerFrame
        let offset = cycle - frameStart
        var line = Int(offset / VirtualClock.cyclesPerLine)
        if offset % VirtualClock.cyclesPerLine != 0 { line += 1 }
        let first = dmaFirstLine[line]
        guard first >= 0 else { return .max }
        return frameStart + UInt64(first) * VirtualClock.cyclesPerLine
    }

    /// The $2012 poll point.
    @inline(__always) public func poll() { pollHandler?(self) }

    // MARK: Interrupt flag, I/O reads and the main-loop hooks (the game program, unit D1a)

    /// The 6502 interrupt-disable flag as the main program leaves it (`sei()`/`cli()` where the
    /// original masks and unmasks interrupts: the cold init, `displayInit`, the disk loads of
    /// `readBlocks`, the editor cache transfer, the text-mode swap, the editor's library disk
    /// I/O). The normal-mode scheduler holds raster IRQs while it is set, taking one pending IRQ
    /// when it clears, as the VIC's latch does: `cli()` and the `RTI` of an NMI taken with the
    /// flag clear bring the event handler in at the next charge (the scheduler takes the one
    /// after an IRQ's `RTI` itself).
    public var interruptDisable = false
    /// Called with (address, live value) for every I/O register the main program reads through
    /// `readIO`; returns the value the program sees (the replay driver substitutes the recorded
    /// one).
    public var ioReadHook: ((Int, UInt8) -> UInt8)?
    /// Called at the top of every main-loop pass ($204B) before the pass runs; returning false
    /// stops the main loop (`runMainLoop` returns). The replay driver checks its memory
    /// checkpoints here.
    public var mainLoopHook: ((Machine) -> Bool)?
    /// The host's way out of a call stack that must never resume: a cold restart taken from an
    /// interrupt (RUN/STOP + RESTORE) runs the new program inside the interrupted frames, and when
    /// that run stops, those frames must not continue. Called with nil for a normal stop or with a
    /// description of what ended the run. Set by `ProgramThread`.
    public var abandonStack: ((String?) -> Never)?

    // MARK: Development bridge to not-yet-ported routines

    /// Runs an original routine on this machine's memory. Installed only by tests (and the lab),
    /// so units can be ported and verified independently. Shipping code must not reach it: every
    /// `callOriginal` site is replaced by its port before the app uses the native engine.
    public var originalBridge: ((Machine, UInt16, CPURegisters) -> CPURegisters)?

    /// Calls the original routine at `address` (development bridge; see `originalBridge`).
    @discardableResult
    public func callOriginal(_ address: UInt16, _ regs: CPURegisters = CPURegisters()) -> CPURegisters {
        guard let bridge = originalBridge else {
            fatalError(String(format: "routine $%04X is not ported yet", address))
        }
        return bridge(self, address, regs)
    }
}

/// 6502 registers passed to and from an original routine through the development bridge.
public struct CPURegisters: Sendable, Equatable {
    public var a: UInt8, x: UInt8, y: UInt8
    public var carry: Bool, zero: Bool, negative: Bool, overflow: Bool

    public init(a: UInt8 = 0, x: UInt8 = 0, y: UInt8 = 0, carry: Bool = false,
                zero: Bool = false, negative: Bool = false, overflow: Bool = false) {
        self.a = a; self.x = x; self.y = y
        self.carry = carry; self.zero = zero; self.negative = negative; self.overflow = overflow
    }
}
