import C64Kit
import FS2Core
import FS2Host
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

        /// What the session step takes from the mailbox.
        var requests: HostRequests {
            var r = HostRequests()
            r.input = input
            r.pressedSinceRead = pressedSinceRead
            r.inputChanged = inputChanged
            r.paused = paused
            r.restart = restart
            r.demo = demo
            r.options = options
            return r
        }
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
        guard let loop = makeLoop() else { return }
        let now = { DispatchTime.now().uptimeNanoseconds }
        var session = EngineSession(loop: loop, audio: audio, now: now())

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
                session.replace(loop: fresh, now: now())
            }
            let (status, action) = session.step(m.requests, fresh: m.reset, now: now)
            demo.store(status.rawValue, ordering: .releasing)
            switch action {
            case .paused:
                _ = wake.wait(timeout: .now() + .milliseconds(250))
            case .sleep(let nanoseconds):
                // Until the next frame is due (or a control wakes the thread).
                _ = wake.wait(timeout: .now() + .nanoseconds(Int(clamping: nanoseconds)))
            case .run(let boundary):
                let cycles = session.loop.engine.cycles
                session.loop.engine.run(untilCycle: boundary)
                if let error = session.ran(from: cycles) {
                    onError(error)
                    mailbox.withLock { $0.paused = true }
                }
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

extension EngineLoop {
    /// The Mac app's loop: every frame to the display, its SID writes to the audio.
    convenience init(engine: any GameEngine, frames: FrameExchange, audio: AudioFeed?) {
        self.init(engine: engine, publish: { frame in
            frames.publish(frame)
            audio?.push(writes: frame.sidWrites)
        })
    }
}
