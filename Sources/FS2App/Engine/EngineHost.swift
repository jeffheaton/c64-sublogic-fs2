import C64Kit
import FS2Core
import Foundation
import Synchronization

/// Runs a `GameEngine` on its own thread, paced to the wall clock at the NTSC rate.
///
/// - The engine is created, driven and destroyed on that thread only (`GameEngine` is not thread-safe).
/// - It runs one frame (17,095 cycles) per slice, sleeping until the wall clock reaches the next frame
///   boundary (`FramePacer`). After a stall the backlog is capped, so the engine never spirals
///   trying to catch up.
/// - Frames go to the display through `FrameExchange`, SID writes to the audio through `AudioFeed`.
/// - Input comes in through a lock-protected mailbox and is handed to the engine between slices,
///   so it always takes effect on a frame boundary. A key pressed and let go again between two
///   reads of the mailbox (a quick tap, or key events delivered together after the main thread
///   stalled) still reaches the key timing as a press.
final class EngineHost: Sendable {
    typealias Factory = @Sendable () throws -> any GameEngine

    let frames: FrameExchange
    let audio: AudioFeed?
    private let factory: Factory
    private let quickBoot: Bool
    /// Called on the engine thread when the engine cannot be created or stops; the host pauses.
    private let onError: @Sendable (String) -> Void

    private struct Mailbox {
        var input = InputState()
        /// Every key pressed in any input posted since the engine thread last read the mailbox.
        var pressedSinceRead = KeyMatrix()
        var inputChanged = false
        var paused = false
        var stop = false
        var restart = false
        var reset = false
        /// Machine ▸ Demo Mode (`DemoMode.start`).
        var demo = false
        var options = EngineOptions()
    }

    private let mailbox = Mutex(Mailbox())
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let started = Atomic<Bool>(false)
    /// `DemoMode.Status.rawValue`, published by the engine thread after every slice.
    private let demo = Atomic<UInt8>(0)

    /// - Parameters:
    ///   - quickBoot: run flat out through the boot's disk loading (about 65 virtual seconds in both
    ///     engines: the port charges the loader's time) to the title prompt, without frames.
    init(frames: FrameExchange, audio: AudioFeed?, quickBoot: Bool = true,
         onError: @escaping @Sendable (String) -> Void = { _ in }, factory: @escaping Factory) {
        self.frames = frames
        self.audio = audio
        self.factory = factory
        self.quickBoot = quickBoot
        self.onError = onError
    }

    // MARK: Controls (any thread)

    func start() {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in self.threadMain() }
        thread.name = "FS2 engine"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 16 << 20   // like a main thread; translated 6502 call chains can run deep
        thread.start()
    }

    /// Stops the engine thread and waits for it to finish (idempotent).
    func stop() {
        guard started.exchange(false, ordering: .acquiringAndReleasing) else { return }
        mailbox.withLock { $0.stop = true }
        wake.signal()
        finished.wait()
    }

    func setInput(_ input: InputState) {
        mailbox.withLock { m in
            if m.input != input { m.input = input; m.inputChanged = true }
            for key in C64Key.allCases where input.keys.isPressed(key) { m.pressedSinceRead.set(key, pressed: true) }
        }
    }

    func setPaused(_ paused: Bool) {
        mailbox.withLock { $0.paused = paused }
        wake.signal()
    }

    var isPaused: Bool { mailbox.withLock { $0.paused } }

    func setOptions(_ options: EngineOptions) { mailbox.withLock { $0.options = options } }

    var options: EngineOptions { mailbox.withLock { $0.options } }

    /// RUN/STOP + RESTORE (the original's restart).
    func requestRestart() {
        mailbox.withLock { $0.restart = true }
        wake.signal()
    }

    /// Machine ▸ Demo Mode: the engine thread starts the demo before its next slice, as the mode
    /// prompt's A does (`DemoMode.start`), when the game is in a state that allows it.
    func requestDemo() {
        mailbox.withLock { $0.demo = true }
        wake.signal()
    }

    /// The demo's state as of the engine's last slice (for the menu's check mark and enabling).
    var demoStatus: DemoMode.Status { DemoMode.Status(rawValue: demo.load(ordering: .acquiring)) }

    /// Cold restart: a fresh engine from the disk image.
    func requestReset() {
        mailbox.withLock { $0.reset = true }
        wake.signal()
    }

    // MARK: Engine thread

    private func threadMain() {
        defer { finished.signal() }
        guard var loop = makeLoop() else { return }
        var pacer = FramePacer(now: DispatchTime.now().uptimeNanoseconds, cycles: loop.engine.cycles)
        var wasPaused = false

        while true {
            let m = mailbox.withLock { m -> Mailbox in
                let snapshot = m
                m.restart = false; m.reset = false; m.inputChanged = false; m.demo = false
                m.pressedSinceRead = KeyMatrix()
                return snapshot
            }
            if m.stop { return }
            if m.reset {
                guard let fresh = makeLoop() else { return }
                loop = fresh
                pacer.rebase(now: DispatchTime.now().uptimeNanoseconds, cycles: loop.engine.cycles)
            }
            if m.inputChanged || m.reset {
                // Keys pressed since the last read but already let go: show the key timing the
                // press first, so the tap is held for its minimum frames instead of being lost.
                var taps = m.input
                for key in C64Key.allCases where m.pressedSinceRead.isPressed(key) { taps.keys.set(key, pressed: true) }
                if taps != m.input { loop.setUserInput(taps) }
                loop.setUserInput(m.input)
            }
            if loop.engine.options != m.options { loop.engine.options = m.options }
            if m.restart { loop.sequencer.start() }
            if m.demo { DemoMode.start(on: loop.engine) }
            demo.store(DemoMode.status(of: loop.engine).rawValue, ordering: .releasing)
            if m.paused {
                wasPaused = true
                _ = wake.wait(timeout: .now() + .milliseconds(250))
                continue
            }
            if wasPaused {
                wasPaused = false
                pacer.rebase(now: DispatchTime.now().uptimeNanoseconds, cycles: loop.engine.cycles)
            }

            let cycles = loop.engine.cycles
            switch pacer.next(now: DispatchTime.now().uptimeNanoseconds, cycles: cycles) {
            case .run(let boundary):
                loop.engine.run(untilCycle: boundary)
                audio?.mark(loop.engine.cycles)
                if loop.engine.cycles == cycles {
                    let reason = (loop.engine as? NativeEngine)?.endReason.map { " (\($0))" } ?? ""
                    onError("The engine stopped at cycle \(cycles)\(reason).")
                    mailbox.withLock { $0.paused = true }
                }
            case .sleep(let nanoseconds):
                // Until the next frame is due (or a control wakes the thread).
                _ = wake.wait(timeout: .now() + .nanoseconds(Int(clamping: nanoseconds)))
            }
        }
    }

    /// Creates the engine and wires its frame callback (engine thread).
    private func makeLoop() -> EngineLoop? {
        do {
            let engine = try factory()
            engine.options = options
            let loop = EngineLoop(engine: engine, frames: frames, audio: audio)
            audio?.reset(engine.cycles)
            if quickBoot, let debug = engine as? EngineDebugging {
                // The audio side jumps over the gap on the next mark (no rendering through it).
                debug.skipDiskLoading()
                audio?.mark(engine.cycles)
            }
            return loop
        } catch {
            onError("The engine could not start: \(error)")
            return nil
        }
    }
}

/// Engine-thread state: the engine, the latest user input, its key timing and the restart
/// sequence. Internal (not private) so tests can drive a real engine through it without the
/// wall-clock thread.
///
/// The player's keys go through `KeyTiming` (minimum hold and release, CTRL before the key it
/// modifies). The engine latches `engine.input` at each frame end, so every `onFrame` commits the
/// matrix just latched and decides the one for the frame after.
final class EngineLoop {
    let engine: any GameEngine
    var userInput = InputState()
    var sequencer = RestartSequencer()
    private(set) var keyTiming = KeyTiming()

    init(engine: any GameEngine, frames: FrameExchange, audio: AudioFeed?) {
        self.engine = engine
        engine.onFrame = { [unowned self] frame in
            frames.publish(frame)
            audio?.push(writes: frame.sidWrites)
            self.frameEnded()
        }
        engine.input = shapedUserInput()
    }

    /// A frame ended: the engine latched `engine.input` for the next frame. Sets the input for
    /// the frame after (the engine applies it at the next frame boundary).
    private func frameEnded() {
        keyTiming.commit(engine.input.keys)
        let pendingRestore = engine.input.restore
        let next: InputState
        if sequencer.isActive {
            next = sequencer.next(user: userInput)
            keyTiming.dropRequests()
        } else {
            next = shapedUserInput()
        }
        engine.input = next
        if pendingRestore { engine.input.restore = true }
    }

    /// New input from the UI. Unless a restart sequence owns the keys, it goes to the engine right
    /// away (applied at the next frame boundary), shaped by the key timing.
    func setUserInput(_ input: InputState) {
        userInput = input
        keyTiming.observe(input.keys)
        guard !sequencer.isActive else { return }
        let pendingRestore = engine.input.restore
        engine.input = shapedUserInput()
        if pendingRestore { engine.input.restore = true }
    }

    /// The player's input with the keys shaped for the next undecided frame.
    private func shapedUserInput() -> InputState {
        var input = userInput
        input.keys = keyTiming.decide()
        return input
    }
}

/// Wall-clock pacing for the engine thread: where the engine should be at a given moment, at the
/// NTSC rate, in whole frames.
///
/// The engine runs one frame whenever the wall clock has passed the next frame boundary, and the
/// thread sleeps otherwise. When the engine falls more than `maxBacklog` behind (a stall, the
/// machine sleeping, a debugger, an engine slower than real time), the rest of the debt is
/// forgiven: the engine catches up at most `maxBacklog` and, while it stays behind, keeps running
/// flat out instead of sleeping, so it never spirals and never wastes time.
struct FramePacer: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        /// Run the engine until this cycle (the next frame boundary).
        case run(untilCycle: UInt64)
        /// Nothing is due yet: sleep this long.
        case sleep(nanoseconds: UInt64)
    }

    static let clockHz = VirtualClock.hz
    static let cyclesPerFrame = VirtualClock.cyclesPerFrame
    /// Most the engine may fall behind the wall clock before the rest is dropped (about 0.1 s).
    static let maxBacklog: UInt64 = 6 * VirtualClock.cyclesPerFrame

    /// The engine's cycle count at `baseTime` (nanoseconds of uptime).
    private(set) var baseCycle: UInt64
    private(set) var baseTime: UInt64

    init(now: UInt64, cycles: UInt64) {
        baseTime = now
        baseCycle = cycles
    }

    /// Starts pacing afresh from `cycles` at `now` (after a pause or a new engine): no backlog.
    mutating func rebase(now: UInt64, cycles: UInt64) {
        baseTime = now
        baseCycle = cycles
    }

    /// The cycle the wall clock says the engine should have reached at `now`.
    func target(now: UInt64) -> UInt64 {
        baseCycle &+ UInt64(Double(now &- baseTime) * Self.clockHz / 1e9)
    }

    /// What to do next, for an engine at `cycles` at time `now`.
    mutating func next(now: UInt64, cycles: UInt64) -> Action {
        var target = target(now: now)
        if target > cycles &+ Self.maxBacklog {
            baseCycle = cycles &+ Self.maxBacklog
            baseTime = now
            target = baseCycle
        }
        let nextBoundary = (cycles / Self.cyclesPerFrame + 1) * Self.cyclesPerFrame
        if target >= nextBoundary { return .run(untilCycle: nextBoundary) }
        let nanoseconds = (Double(nextBoundary - target) / Self.clockHz * 1e9).rounded(.up)
        return .sleep(nanoseconds: max(1, UInt64(nanoseconds)))
    }
}
