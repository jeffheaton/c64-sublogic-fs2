import C64Kit
import FS2Core

/// The controls a host hands the engine between slices: the player's input and the menu's requests,
/// as they stood when the host last read them.
public struct HostRequests: Sendable, Equatable {
    public var input = InputState()
    /// Every key pressed in any input posted since the last read (a tap let go before the read
    /// still reaches the key timing as a press).
    public var pressedSinceRead = KeyMatrix()
    /// The input differs from the one the last read handed over.
    public var inputChanged = false
    public var paused = false
    /// RUN/STOP + RESTORE (the original's restart).
    public var restart = false
    /// Machine ▸ Demo Mode (`DemoMode.start`).
    public var demo = false
    public var options = EngineOptions()

    public init() {}
}

/// What a host does between two slices of the engine, without threads or clocks of its own: the
/// Mac app's engine thread (`EngineHost`) and the web worker (`SessionDriver`) run the same steps,
/// so the engine sees the same calls from both.
///
/// Each slice: `step` applies the requests (the input through the key timing, the options, the
/// restart sequence, the demo) and says what to do: wait while paused, sleep until the next frame
/// is due, or run the engine to the next frame boundary (`FramePacer`). After a run, `ran` marks
/// the audio and reports an engine that made no progress.
public struct EngineSession {
    public private(set) var loop: EngineLoop
    public let audio: AudioFeed?
    private var pacer: FramePacer
    private var wasPaused = false

    public enum Action: Sendable, Equatable {
        /// Paused: wait (the Mac host up to 250 ms, or until a control changes), then step again.
        case paused
        /// Nothing is due yet: sleep this long (or until a control changes), then step again.
        case sleep(nanoseconds: UInt64)
        /// Run the engine until this cycle (the next frame boundary), then call `ran`.
        case run(untilCycle: UInt64)
    }

    /// A session for `loop`'s engine, paced from `now` (nanoseconds of uptime).
    public init(loop: EngineLoop, audio: AudioFeed?, now: UInt64) {
        self.loop = loop
        self.audio = audio
        pacer = FramePacer(now: now, cycles: loop.engine.cycles)
    }

    /// A fresh engine (the Mac's cold reset): pacing starts afresh from it.
    public mutating func replace(loop: EngineLoop, now: UInt64) {
        self.loop = loop
        pacer.rebase(now: now, cycles: loop.engine.cycles)
    }

    /// Applies `requests` and decides the next action. `fresh`: the engine was just replaced, so
    /// the input goes to it even when unchanged. Returns the demo's state after the requests.
    public mutating func step(_ requests: HostRequests, fresh: Bool = false,
                              now: () -> UInt64) -> (demo: DemoMode.Status, action: Action) {
        let m = requests
        if m.inputChanged || fresh {
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
        let demo = DemoMode.status(of: loop.engine)
        if m.paused {
            wasPaused = true
            return (demo, .paused)
        }
        if wasPaused {
            wasPaused = false
            pacer.rebase(now: now(), cycles: loop.engine.cycles)
        }
        switch pacer.next(now: now(), cycles: loop.engine.cycles) {
        case .run(let boundary):
            return (demo, .run(untilCycle: boundary))
        case .sleep(let nanoseconds):
            return (demo, .sleep(nanoseconds: nanoseconds))
        }
    }

    /// After a `.run` that started at `cycles`: marks the audio up to the engine's clock. Returns
    /// an error message when the engine did not move (it stopped; the host pauses).
    public func ran(from cycles: UInt64) -> String? {
        audio?.mark(loop.engine.cycles)
        guard loop.engine.cycles == cycles else { return nil }
        let reason = (loop.engine as? NativeEngine)?.endReason.map { " (\($0))" } ?? ""
        return "The engine stopped at cycle \(cycles)\(reason)."
    }
}
