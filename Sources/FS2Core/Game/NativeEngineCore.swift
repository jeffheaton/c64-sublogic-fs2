import C64Kit

/// The program-thread side of `NativeEngine`: the hooks the port calls (`Machine.eventHandler`,
/// `pollHandler`, `mainLoopHook`, the scheduler's frame ends) and the state both threads share.
///
/// Shared state is only touched by the side that currently runs (see `NativeEngineGate`): the host
/// writes `target`, `input`, `options` and the request flags while the program is parked, the
/// program reads them while the host waits.
final class NativeEngineCore: @unchecked Sendable {
    let machine: Machine
    let gate = NativeEngineGate()
    /// Normal mode: the raster IRQ equivalents on the virtual clock. Nil in replay mode.
    private(set) var scheduler: InterruptScheduler?
    let smooth = SmoothRenderer()

    // MARK: Written by the host while the program is parked

    /// The cycle the program parks at (`NativeEngineGate.Stop.target`).
    var target: UInt64 = 0
    var input = InputState()
    var options = EngineOptions()
    /// Park at frame ends so the host can present them.
    var deliverFrames = false
    /// Park at the top of every main-loop pass.
    var parkAtIterations = false
    /// Park at the first poll of a new key wait.
    var stopAtKeyWait = false

    // MARK: Written by the program

    /// The program's end (a display-list fault, the end of a replay), nil while it runs.
    var endReason: String?
    /// Replay mode: the driver's report once the replay ended.
    var replayOutcome: ReplayDriver.Outcome?

    // MARK: Program-thread bookkeeping

    /// The scheduler's own event handler and poll hook, wrapped by `event` and `polled`.
    private var schedulerEvent: ((Machine) -> Void)?
    private var schedulerPoll: ((Machine) -> Void)?
    /// When the scheduler wants to run next, as `Machine.charge` would see it without the
    /// wrapper (its own `nextEventCycle`, lowered when the interrupt flag clears).
    private var schedulerNext: UInt64 = .max
    /// The `nextEventCycle` the wrapper itself last stored.
    private var installedNext: UInt64 = .max
    /// True while the scheduler's handler runs (charges made by the handlers it delivers come back
    /// into `event`, where the scheduler must not run again: it does not re-enter itself).
    private var inScheduler = false
    /// Replay mode: the next frame boundary (the replay has no scheduler to report frame ends).
    private var replayFrameEnd: UInt64 = .max
    /// Key-wait stops: the keys dispatched so far (changes of the queue's read index seen at the
    /// polls), the count at the last stop, the clock at the last key-wait poll.
    private var lastReadIndex: UInt8 = 0
    private var dispatches = 0
    private var keyWaitMark: Int?
    private var lastKeyWaitPoll: UInt64 = 0
    private let joystickSharing = JoystickSharing()

    init(machine: Machine) {
        self.machine = machine
    }

    // MARK: Normal mode

    /// Program thread: the cold start from the stage-2 handoff, then the game forever. Returns
    /// only when the program ends (a display list the original cannot run).
    func runNormal() -> Never {
        gate.waitForStart()
        let m = machine
        // The C64's pace: the CPU cycles the VIC takes (badlines, sprites) pass on the clock too.
        m.vicDMA = true
        let scheduler = InterruptScheduler(machine: m)
        self.scheduler = scheduler
        scheduler.onFrameEnd = { [unowned self] m, cycle in self.frameEnded(m, cycle) }
        scheduler.install()
        schedulerEvent = m.eventHandler
        schedulerPoll = m.pollHandler
        schedulerNext = m.nextEventCycle
        m.eventHandler = { [unowned self] m in self.event(m) }
        m.pollHandler = { [unowned self] m in self.polled(m) }
        m.mainLoopHook = { [unowned self] m in self.mainLoopTop(m) }
        m.abandonStack = { [unowned self] reason in self.programEnded(reason ?? "the main loop stopped") }
        armNextEvent(m)
        switch m.coldStart() {
        case .stopped: programEnded("the main loop stopped")
        case .fault(let fault): programEnded("display-list fault: \(fault)")
        }
    }

    // MARK: Replay mode

    #if !os(WASI)
    /// Program thread: replays `log` with D1a's `ReplayDriver` (the interrupts, keys and I/O
    /// reads come from the log). Parks at every matching checkpoint; from the first checkpoint on
    /// also at frame ends and run targets.
    func runReplay(_ log: ReplayLog, from start: ReplayDriver.Start) -> Never {
        gate.waitForStart()
        let m = machine
        // The interrupts come from the log, but the clock keeps the C64's pace (the VIC's DMA too),
        // so the replayed passes take the lab's cycles.
        m.vicDMA = true
        // A terminate while the program runs on the driver's `ProgramThread` leaves its frames
        // through `abandonStack`, which parks that thread for good; the driver's run then returns
        // here, and this thread ends.
        gate.exitProgram = { [unowned self] in
            if let abandon = self.machine.abandonStack { abandon("the engine was terminated") }
            NativeEngineGate.exitThread()
        }
        let driver = ReplayDriver(machine: m, log: log)
        driver.onCheckpoint = { [unowned self] k, m in self.checkpointReached(k, m) }
        let outcome = driver.run(from: start)
        gate.exitProgram = NativeEngineGate.exitThread
        if gate.terminating { NativeEngineGate.exitThread() }
        replayOutcome = outcome
        m.eventHandler = nil
        m.nextEventCycle = .max
        programEnded(outcome.passed ? "the replay ended" : "the replay failed: \(outcome.mismatch.map { "\($0)" } ?? outcome.error ?? "")")
    }

    /// A matching replay checkpoint (on the driver's program thread). The first one installs the
    /// event hook: the driver turns `eventHandler` off before it starts the program.
    private func checkpointReached(_ k: Int, _ m: Machine) {
        if m.eventHandler == nil {
            schedulerEvent = nil
            schedulerNext = .max
            let frame = VirtualClock.cyclesPerFrame
            replayFrameEnd = (m.clock.cycles / frame + 1) * frame
            m.eventHandler = { [unowned self] m in self.event(m) }
            armNextEvent(m)
        }
        gate.park(.checkpoint(k))
    }
    #endif

    // MARK: The hooks

    /// `Machine.eventHandler`: runs the scheduler exactly when it would run without this wrapper
    /// (so where the program parks never changes what it computes), then parks when the clock
    /// reached the run target.
    private func event(_ m: Machine) {
        let observed = m.nextEventCycle
        if inScheduler {
            // A charge made by an interrupt handler the scheduler delivers: the scheduler would
            // return at once (no re-entry); leave `nextEventCycle` as it is so `charge` runs on.
            // A run target reached here is taken after the scheduler's service, which may still
            // owe the host a frame end the handler ran past: `run` returns with every frame up to
            // its target delivered (a host that runs frame by frame gets exactly one per call).
            return
        }
        // Clearing the interrupt flag (`cli()`, or an interrupt return) lowers `nextEventCycle` to
        // the clock to have a held IRQ taken at once.
        if observed < installedNext { schedulerNext = min(schedulerNext, observed) }
        if let handler = schedulerEvent {
            while m.clock.cycles >= schedulerNext {
                let before = schedulerNext
                m.nextEventCycle = schedulerNext
                inScheduler = true
                handler(m)
                inScheduler = false
                schedulerNext = m.nextEventCycle
                if schedulerNext <= before { break }
            }
        } else {
            // Replay mode: only the frame ends.
            while m.clock.cycles >= replayFrameEnd {
                let end = replayFrameEnd
                replayFrameEnd += VirtualClock.cyclesPerFrame
                frameEnded(m, end)
            }
        }
        if m.clock.cycles >= target { gate.park(.target) }
        armNextEvent(m)
    }

    /// Sets `nextEventCycle` to the earlier of the scheduler's next event and the run target.
    private func armNextEvent(_ m: Machine) {
        let next = min(schedulerEvent == nil ? replayFrameEnd : schedulerNext, target)
        m.nextEventCycle = next
        installedNext = next
    }

    /// A frame ended (the scheduler's `onFrameEnd`, or the clock in replay mode): the input for
    /// the next frame goes to the CIA and RESTORE to the scheduler, then the host presents the
    /// frame.
    private func frameEnded(_ m: Machine, _ cycle: UInt64) {
        if let scheduler {
            var input = self.input
            m.io.keyboard = joystickSharing.matrix(for: input.keys, strict: options.strictJoystick, machine: m)
            if input.restore {
                input.restore = false
                self.input = input
                scheduler.requestNMI()
            }
        }
        if deliverFrames {
            gate.park(.frameEnd(cycle))
        } else {
            NativeEngineCore.compactSidWrites(m, above: 4096)
        }
    }

    /// `Machine.pollHandler`: the scheduler's poll point (RESTORE), then the key-wait stop: the
    /// first poll of a key wait that is not the one of the last stop. A wait is new when a key
    /// was dispatched since that stop (the queue's read index moved: every key a wait gets ends
    /// it), or when no key wait polled for a long stretch (a restart's boot loads in between).
    private func polled(_ m: Machine) {
        schedulerPoll?(m)
        let read = m.mem[Input.RAM.keyQueueRead]
        if read != lastReadIndex {
            lastReadIndex = read
            dispatches += 1
        }
        guard NativeEngineCore.inKeyWait(m) else { return }
        let gap = m.clock.cycles &- lastKeyWaitPoll
        lastKeyWaitPoll = m.clock.cycles
        if gap > NativeEngineCore.keyWaitGap { keyWaitMark = nil }
        guard stopAtKeyWait, keyWaitMark != dispatches else { return }
        keyWaitMark = dispatches
        gate.park(.keyWait)
    }

    /// A key wait polls every few dozen cycles; a gap longer than this (about a second) means the
    /// program left it.
    static let keyWaitGap: UInt64 = 1_000_000

    /// `Machine.mainLoopHook` ($204B): the iteration snapshot for Smooth pacing, the host's
    /// iteration callback. The loop never stops in normal mode.
    private func mainLoopTop(_ m: Machine) -> Bool {
        smooth.recordIteration(m)
        if parkAtIterations { gate.park(.iteration) }
        return true
    }

    /// The program ended: never runs again.
    private func programEnded(_ reason: String) -> Never {
        endReason = reason
        gate.parkForGood()
    }

    // MARK: Helpers

    /// A poll from `waitForKey` ($2250): it set text input (`$08BA` = 1) and paused (`$08CC`)
    /// before its first poll; the scenery interpreter never polls in that state.
    static func inKeyWait(_ m: Machine) -> Bool {
        m.mem[Input.RAM.editorRequest] == 1 && m.mem[MainLoop.RAM.pauseCount] != 0
    }

    /// Keeps the SID write stream bounded while no frame takes it: above `limit` writes only the
    /// last write of each register is kept (the register state the audio needs).
    static func compactSidWrites(_ m: Machine, above limit: Int) {
        guard m.io.sidWrites.count > limit else { return }
        var last: [Int: (cycle: UInt64, reg: UInt8, value: UInt8)] = [:]
        for w in m.io.sidWrites { last[Int(w.reg)] = w }
        m.io.sidWrites = last.values.sorted { $0.cycle < $1.cycle || ($0.cycle == $1.cycle && $0.reg < $1.reg) }
    }
}
