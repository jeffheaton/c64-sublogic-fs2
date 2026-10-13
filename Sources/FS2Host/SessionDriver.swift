import FS2Core

/// Drives an engine as `EngineHost`'s thread does, with the clock, the waits and the controls
/// supplied by the caller: the quick boot, then `EngineSession`'s step every slice. It hands out
/// the engine calls as `InlineRequest`s, so an inline engine takes them at its parks
/// (`InlineSessionHost`, the web worker) and a threaded one can be driven with the same calls
/// (the tests compare the two).
public final class SessionDriver {
    /// What the host supplies.
    public struct IO {
        /// Nanoseconds of uptime.
        public var now: () -> UInt64
        /// Blocks up to `nanoseconds` (returning early when a control changes is fine).
        public var wait: (_ nanoseconds: UInt64) -> Void
        /// The controls as they stand, clearing the one-shot requests and the taps (the mailbox
        /// read); nil when the host stops the engine.
        public var readRequests: () -> HostRequests?
        /// The demo's state after every step.
        public var demoStatus: (DemoMode.Status) -> Void = { _ in }
        /// After every slice the engine ran, with its clock (the audio rendering goes here).
        public var sliceEnded: (UInt64) -> Void = { _ in }
        /// The engine stopped making progress; the driver pauses until the controls say paused.
        public var error: (String) -> Void = { _ in }

        public init(now: @escaping () -> UInt64, wait: @escaping (UInt64) -> Void,
                    readRequests: @escaping () -> HostRequests?) {
            self.now = now
            self.wait = wait
            self.readRequests = readRequests
        }
    }

    public let engine: any GameEngine
    public let audio: AudioFeed?
    private var io: IO
    private let quickBoot: Bool
    private let options: EngineOptions
    private let publish: (FrameOutput) -> Void
    private var loop: EngineLoop?
    private var session: EngineSession?
    /// The clock when the slice in progress started.
    private var runFrom: UInt64 = 0
    /// Set when the engine stopped: paused until the host's controls show the pause.
    private var forcedPause = false

    /// How long a paused host waits before it looks at the controls again.
    public static let pausedWait: UInt64 = 250_000_000

    /// - Parameters:
    ///   - quickBoot: start with `.skipDiskLoading` (the boot's loads flat out, without frames).
    ///   - options: the engine's options until the first step.
    ///   - publish: gets every frame first (the display; the audio feed gets the SID writes here).
    public init(engine: any GameEngine, audio: AudioFeed?, quickBoot: Bool = true, options: EngineOptions,
                io: IO, publish: @escaping (FrameOutput) -> Void) {
        self.engine = engine
        self.audio = audio
        self.quickBoot = quickBoot
        self.options = options
        self.io = io
        self.publish = publish
    }

    /// The loop driving the engine, once the first call made it.
    public var engineLoop: EngineLoop? { loop }

    /// The next call to make of the engine after `previous` (nil for the first), or nil when the
    /// host stopped. Blocks while paused and until the next frame is due.
    public func next(after previous: InlineRequest?) -> InlineRequest? {
        if previous == nil {
            // `EngineHost.makeLoop`: options, the loop (frame callback, first input), the audio reset.
            engine.options = options
            let audio = self.audio
            let publish = self.publish
            loop = EngineLoop(engine: engine, publish: { frame in
                publish(frame)
                audio?.push(writes: frame.sidWrites)
            })
            audio?.reset(engine.cycles)
            if quickBoot { return .skipDiskLoading }
        }
        if case .skipDiskLoading = previous {
            // The audio side jumps over the gap on the next mark (no rendering through it).
            audio?.mark(engine.cycles)
        }
        if session == nil, let loop {
            session = EngineSession(loop: loop, audio: audio, now: io.now())
        }
        if case .run = previous, let session {
            if let error = session.ran(from: runFrom) {
                io.error(error)
                forcedPause = true
            }
            io.sliceEnded(engine.cycles)
        }
        while true {
            guard var requests = io.readRequests() else { return nil }
            if forcedPause {
                if requests.paused { forcedPause = false }
                requests.paused = true
            }
            let (demo, action) = session!.step(requests, now: io.now)
            io.demoStatus(demo)
            switch action {
            case .paused:
                io.wait(Self.pausedWait)
            case .sleep(let nanoseconds):
                io.wait(nanoseconds)
            case .run(let boundary):
                runFrom = engine.cycles
                return .run(untilCycle: boundary)
            }
        }
    }
}

/// An inline engine's host that drives it with a `SessionDriver` (the web worker).
public final class InlineSessionHost: NativeEngineInlineHost {
    public let driver: SessionDriver
    private let stopped: () -> Never
    private let ended: (String) -> Never

    /// - Parameters:
    ///   - stopped: the driver's host stopped the engine (never returns).
    ///   - ended: the program ended with this reason (never returns).
    public init(driver: SessionDriver, stopped: @escaping () -> Never, ended: @escaping (String) -> Never) {
        self.driver = driver
        self.stopped = stopped
        self.ended = ended
    }

    public func next(_ engine: NativeEngine, after previous: InlineRequest?, stoppedAtKeyWait: Bool) -> InlineRequest {
        guard let request = driver.next(after: previous) else { stopped() }
        return request
    }

    public func programEnded(_ engine: NativeEngine, reason: String) -> Never {
        ended(reason)
    }
}
