import C64Kit
import FS2Data
#if !os(WASI)
import Foundation
#endif

/// The native port as the app's `GameEngine`: the translated game program running on the virtual
/// NTSC clock, presented frame by frame. See `re/docs/engine.md`.
///
/// - **Boot.** `Machine.booting(blocks:)` (the stage-2 handoff) and the cold start $A7E2 (unit
///   D1a): the boot loads, the title and the two prompts exactly as the original shows them (the
///   rows a modified copy overwrites stay blank), then the main loop for good.
/// - **Threads.** The program is straight-line code, so it runs on a thread of its own and hands
///   control back and forth inside the virtual clock (`NativeEngineGate`): `run(untilCycle:)`
///   resumes it and returns when the clock reaches the target (or the program parks at a frame
///   end, where this thread presents the frame). Only one of the two threads runs at a time, and
///   the program computes the same thing however `run` slices the time.
/// - **Inline execution** (`Execution.inline`, the only kind on WASI): no program thread. The
///   program runs on the caller's stack inside `runInline`, and a `NativeEngineInlineHost` makes at
///   every park the requests the threaded host makes between its `run` calls, with the same result.
/// - **Interrupts.** D1a's `InterruptScheduler` runs the raster IRQ equivalents and the frame
///   ends on the clock; RESTORE goes to its poll point.
/// - **Input** (the `GameEngine` contract): applied at every frame end before `onFrame`, as the
///   CIA matrix the frame IRQ's keyboard scan reads (`io.keyboard`), with the joysticks shared
///   per `EngineOptions.strictJoystick` (`JoystickSharing`); `restore` raises the NMI.
/// - **Frames**: `onFrame` at every frame end (on the thread that calls `run`) with the presented
///   picture, the frame's timestamped SID writes, and the monochrome flag (`$0E69` = 0: the black
///   and white display was chosen). The picture is the raster split as the IRQ latched it (the
///   window multicolor from the bitmap on display with its border, the panel hi-res with border
///   $0C, the four attitude-indicator sprites), or the single register state otherwise (the
///   editor's text screen through the imported character ROM or the fallback font, the boot).
///   Smooth pacing redraws the window (`SmoothRenderer`).
/// - **Mode library**: `Machine.modeLibraryIO` (the editor's CTRL-X / CTRL-Z) is the given store,
///   by default `ModeLibraryFile.standard`.
/// - **Replay mode** (`init(replaying:on:from:)`, tests and tools): D1a's `ReplayDriver` drives
///   the program from a lab recording; `onCheckpoint` gets every matching checkpoint's frame.
///
/// All methods must be called on one thread (the engine's), never concurrently.
public final class NativeEngine: GameEngine {
    /// Where the program runs.
    public enum Execution: Sendable, Equatable {
        /// On a thread of its own, driven by `run(untilCycle:)` and the other run calls.
        case thread
        /// On the caller's stack, driven by `runInline` and its host.
        case inline

        /// `.inline` on WASI (no threads), `.thread` elsewhere.
        public static var platformDefault: Execution {
            #if os(WASI)
            .inline
            #else
            .thread
            #endif
        }
    }

    /// The port's state. Read or change it only between calls of `run` (the program is parked
    /// then); `poke` is the sanctioned way to change memory.
    public let machine: Machine
    /// The character ROM for text screens (`GameData.charROM`); nil uses the fallback font.
    public let charROM: [UInt8]?
    public var onFrame: ((FrameOutput) -> Void)?
    /// Called on this thread at the top of every main-loop pass ($204B), the program parked there.
    /// The machine must not be changed from it. Normal mode only.
    public var onIteration: ((Machine) -> Void)?
    /// Replay mode: called on this thread at every matching checkpoint with its index and the frame
    /// presented from the machine there (`frame` = the clock's frame).
    public var onCheckpoint: ((Int, FrameOutput) -> Void)?

    let core: NativeEngineCore
    private let replaying: Bool
    public let execution: Execution
    #if !os(WASI)
    /// The program's thread (it waits for the first `run` before it starts the program).
    private var thread: Thread?
    #endif
    /// Inline execution: the host and the request in progress (`NativeEngineInline.swift`).
    var inline = InlineState()
    /// Frames delivered to `onFrame` so far.
    public private(set) var framesDelivered: UInt64 = 0
    /// Frames whose window Smooth pacing drew (the others showed the real window).
    public private(set) var smoothFrames: UInt64 = 0

    // MARK: Creating

    /// The mode library store an engine uses unless told otherwise: the Mac's file, none on WASI
    /// (the web build passes its own).
    public static var defaultModeLibrary: ModeLibrary.IO? {
        #if os(WASI)
        nil
        #else
        ModeLibraryFile.standard.io
        #endif
    }

    /// An engine at the stage-2 handoff of `data`'s disk, ready for the cold start.
    public convenience init(data: GameData, options: EngineOptions = EngineOptions(),
                            modeLibrary: ModeLibrary.IO? = NativeEngine.defaultModeLibrary,
                            execution: Execution = .platformDefault) {
        let m = Machine.booting(blocks: data.disk.blocks)
        m.modeLibraryIO = modeLibrary
        self.init(machine: m, charROM: data.charROM, options: options, execution: execution)
    }

    /// An engine that cold-starts `machine` (which must be at the stage-2 handoff, as
    /// `Machine.booting` builds it).
    public init(machine: Machine, charROM: [UInt8]? = nil, options: EngineOptions = EngineOptions(),
                execution: Execution = .platformDefault) {
        self.machine = machine
        self.charROM = charROM
        replaying = false
        self.execution = execution
        core = NativeEngineCore(machine: machine)
        core.options = options
        #if os(WASI)
        precondition(execution == .inline, "no program thread on WASI")
        #else
        if execution == .thread {
            let core = self.core
            thread = Self.startThread { core.runNormal() }
        }
        #endif
    }

    #if !os(WASI)
    /// An engine that replays a lab recording with D1a's `ReplayDriver`: `machine` holds the
    /// recording's start state (`.mainLoop`: the top of the main loop; `.coldStart`: the stage-2
    /// handoff). The driver supplies the interrupts, the keys and the I/O reads; `input` and
    /// `options` are ignored. The program ends after the last checkpoint (`replayOutcome`).
    public init(replaying log: ReplayLog, on machine: Machine, from start: ReplayDriver.Start,
                charROM: [UInt8]? = nil) {
        self.machine = machine
        self.charROM = charROM
        replaying = true
        execution = .thread
        core = NativeEngineCore(machine: machine)
        let core = self.core
        thread = Self.startThread { core.runReplay(log, from: start) }
    }
    #endif

    deinit {
        core.gate.terminate()
    }

    #if !os(WASI)
    private static func startThread(_ body: @escaping @Sendable () -> Never) -> Thread {
        let t = Thread { body() }
        t.name = "FS2 game program"
        t.stackSize = ProgramThread.defaultStackSize
        t.qualityOfService = .userInteractive
        t.start()
        return t
    }
    #endif

    // MARK: GameEngine

    public var cycles: UInt64 { machine.clock.cycles }

    public var input: InputState {
        get { core.input }
        set { core.input = newValue }
    }

    public var options: EngineOptions {
        get { core.options }
        set {
            if newValue.pacing != core.options.pacing { core.smooth.invalidate() }
            core.options = newValue
        }
    }

    /// Why the program ended (a display-list fault, the end of a replay), nil while it runs.
    public var endReason: String? { core.endReason }
    /// Replay mode: the driver's report, once the replay ended.
    public var replayOutcome: ReplayDriver.Outcome? { core.replayOutcome }

    public func run(untilCycle cycle: UInt64) {
        precondition(execution == .thread, "an inline engine runs through runInline")
        while core.endReason == nil && machine.clock.cycles < cycle {
            core.target = cycle
            handle(resume())
        }
    }

    // MARK: Debugging and tools

    /// Runs until a key wait ($2250, `waitForKey`) polls for the first time after a key was
    /// dispatched since the last such stop (the first one after the boot is the title prompt),
    /// or until `maxFrames` frames have passed. Returns true at once when the program is parked
    /// at the key wait of the last stop and has not run since (as the lab's `pc:2250` stops at
    /// once at the PC it is at: a session's `pc:2250` after the quick boot). Frames are delivered
    /// unless `deliverFrames` is false. Returns true when it stopped at a key wait.
    @discardableResult
    public func runToKeyWait(maxFrames: Int, deliverFrames: Bool = true) -> Bool {
        precondition(execution == .thread, "an inline engine runs through runInline")
        if parkedAtKeyWait == machine.clock.cycles { return true }
        let limit = machine.clock.cycles + UInt64(max(0, maxFrames)) * VirtualClock.cyclesPerFrame
        core.stopAtKeyWait = true
        defer { core.stopAtKeyWait = false }
        while core.endReason == nil && machine.clock.cycles < limit {
            core.target = limit
            let stop = resume(deliverFrames: deliverFrames)
            if stop == .keyWait {
                parkedAtKeyWait = machine.clock.cycles
                return true
            }
            handle(stop)
        }
        return false
    }

    /// The clock when `runToKeyWait` last stopped (the program is still parked at that key wait
    /// while the clock has not moved).
    var parkedAtKeyWait: UInt64?

    /// Runs until the program is at the top of its main loop ($204B, before a pass: where the
    /// lab's `pc:204B` stops), or until `maxFrames` frames have passed. Returns true at once when
    /// the program is parked there and has not run since (the lab's stop at the PC it is at).
    /// Frames are delivered unless `deliverFrames` is false. Normal mode only. Returns true when
    /// it stopped at the top of the loop.
    @discardableResult
    public func runToMainLoopTop(maxFrames: Int, deliverFrames: Bool = true) -> Bool {
        precondition(execution == .thread, "an inline engine runs through runInline")
        guard !replaying else { return false }
        if parkedAtMainLoopTop == machine.clock.cycles { return true }
        let limit = machine.clock.cycles + UInt64(max(0, maxFrames)) * VirtualClock.cyclesPerFrame
        stopAtMainLoopTop = true
        defer { stopAtMainLoopTop = false }
        while core.endReason == nil && machine.clock.cycles < limit {
            core.target = limit
            let stop = resume(deliverFrames: deliverFrames)
            handle(stop)
            if stop == .iteration {
                parkedAtMainLoopTop = machine.clock.cycles
                return true
            }
        }
        return false
    }

    /// Set while `runToMainLoopTop` runs: the program parks at $204B.
    private var stopAtMainLoopTop = false
    /// The clock when `runToMainLoopTop` last stopped at $204B (the program is still parked there
    /// while the clock has not moved).
    private var parkedAtMainLoopTop: UInt64?

    /// Runs flat out to the title prompt without presenting the loading frames (the boot loads take
    /// about 65 virtual seconds), then delivers one frame with everything written to the SID
    /// meanwhile.
    public func skipDiskLoading() {
        precondition(execution == .thread, "an inline engine runs through runInline")
        runToKeyWait(maxFrames: 9000, deliverFrames: false)
        deliverFrame(at: machine.clock.cycles, frameEnd: false)
    }

    /// Writes a byte of the memory image (between `run` calls).
    public func poke(_ address: Int, _ value: UInt8) {
        machine.mem[address & 0xFFFF] = value
    }

    /// The frame the VIC would show now (the presenter `onFrame` uses).
    public func presentFrame() -> [UInt8] {
        present(at: machine.clock.cycles)
    }

    // MARK: Host side of the handshake

    private func resume(deliverFrames: Bool = true) -> NativeEngineGate.Stop {
        prepareResume(deliverFrames: deliverFrames)
        return core.gate.resume()
    }

    /// The flags the program reads when it goes on (set before every resume).
    func prepareResume(deliverFrames: Bool = true) {
        core.deliverFrames = deliverFrames && onFrame != nil
        core.parkAtIterations = (onIteration != nil || stopAtMainLoopTop) && !replaying
    }

    func handle(_ stop: NativeEngineGate.Stop) {
        switch stop {
        case .target, .keyWait, .finished:
            break
        case .frameEnd(let cycle):
            deliverFrame(at: cycle)
        case .iteration:
            onIteration?(machine)
        case .checkpoint(let k):
            if let onCheckpoint {
                onCheckpoint(k, makeFrame(at: machine.clock.cycles))
            }
        }
    }

    func deliverFrame(at cycle: UInt64, frameEnd: Bool = true) {
        guard let onFrame else { return }
        framesDelivered += 1
        onFrame(makeFrame(at: cycle, frameEnd: frameEnd))
    }

    /// The frame presented now, with the SID writes since the last frame.
    private func makeFrame(at cycle: UInt64, frameEnd: Bool = false) -> FrameOutput {
        let pixels = present(at: cycle, frameEnd: frameEnd)
        NativeEngineCore.compactSidWrites(machine, above: 65_536)
        let writes = machine.io.sidWrites
        machine.io.sidWrites.removeAll(keepingCapacity: true)
        return FrameOutput(pixels: pixels, frame: cycle / VirtualClock.cyclesPerFrame, sidWrites: writes,
                           monochrome: machine.mem[TextMode.backgroundColor] == 0)
    }

    /// The jiffy `$34` at the last frame end presented: unchanged means no raster IRQ ran since.
    private var lastJiffy: UInt8?

    private func present(at cycle: UInt64, frameEnd: Bool = false) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: VICPresenter.width * VICPresenter.height)
        let jiffy = machine.mem[MainLoop.RAM.jiffyCounter]
        let previousJiffy = lastJiffy
        if frameEnd { lastJiffy = jiffy }
        guard let split = NativeEnginePresenter.split(machine) else {
            core.smooth.invalidate()
            heldWindow.forget()
            machine.presentTextScreen(into: &out, charROM: charROM)
            return out
        }
        if frameEnd && !replaying && previousJiffy == jiffy {
            // The IRQ was held all frame (a load): the registers as the last handler left them.
            heldWindow.forget()
            machine.presentTextScreen(into: &out, charROM: charROM)
            return out
        }
        let flipFrame = frameEnd && !replaying && heldWindow.isFlipFrame(machine, split: split)
        if flipFrame {
            // Smooth too: the window shows the picture of camera c_(k-1) until this frame ends,
            // the interpolation at f = 0.
            heldWindow.compose(machine).withUnsafeBufferPointer { ram in
                NativeEnginePresenter.render(into: &out, ram: ram, colorRAM: machine.io.colorRAM, split: split)
            }
        } else if core.options.pacing == .smooth && !replaying && core.smooth.compose(real: machine, at: cycle) {
            smoothFrames += 1
            core.smooth.composite.withUnsafeBufferPointer { ram in
                NativeEnginePresenter.render(into: &out, ram: ram, colorRAM: machine.io.colorRAM, split: split)
            }
        } else {
            NativeEnginePresenter.render(into: &out, ram: UnsafeBufferPointer(start: machine.mem, count: Machine.memorySize),
                                         colorRAM: machine.io.colorRAM, split: split)
        }
        if frameEnd && !flipFrame { heldWindow.keep(machine, split: split) }
        return out
    }

    /// The window as the last frame end showed it, for the frame in which a pass flips
    /// (`NativeEnginePresenter.HeldWindow`).
    private let heldWindow = NativeEnginePresenter.HeldWindow()
}
