import C64Kit
import FS2Core
import Synchronization

/// What the engine thread sends the audio thread, in order.
public struct AudioEvent: BitwiseCopyable, Sendable, Equatable {
    public enum Kind: UInt8 {
        /// A SID register write at `cycle`.
        case write
        /// The engine has run up to `cycle` (sent after every slice; paces the audio).
        case mark
        /// A new engine (cold reset) whose clock is at `cycle`: reset the chip.
        case reset
    }

    public var cycle: UInt64
    public var kindRaw: UInt8
    public var reg: UInt8
    public var value: UInt8

    public var kind: Kind { Kind(rawValue: kindRaw) ?? .mark }

    public static func write(_ cycle: UInt64, _ reg: UInt8, _ value: UInt8) -> AudioEvent {
        AudioEvent(cycle: cycle, kindRaw: Kind.write.rawValue, reg: reg, value: value)
    }
    public static func mark(_ cycle: UInt64) -> AudioEvent { AudioEvent(cycle: cycle, kindRaw: Kind.mark.rawValue, reg: 0, value: 0) }
    public static func reset(_ cycle: UInt64) -> AudioEvent { AudioEvent(cycle: cycle, kindRaw: Kind.reset.rawValue, reg: 0, value: 0) }
}

/// The engine thread's end of the audio path. Writes are dropped while no audio output is running
/// (so the ring never fills up with nobody reading it).
public final class AudioFeed: Sendable {
    public let ring = SPSCRing<AudioEvent>(capacity: 16384)
    /// Set by the audio output while its render callback is live.
    public let active = Atomic<Bool>(false)
    /// Events that did not fit (diagnostics).
    public let dropped = Atomic<Int>(0)

    public init() {}

    /// A batch larger than this is a burst (e.g. the writes of a quick boot, delivered with one
    /// frame) that the audio side will jump over anyway; only each register's last write is kept.
    public static let burstLimit = 2048

    /// Engine thread: forwards a frame's SID writes.
    public func push(writes: [(cycle: UInt64, reg: UInt8, value: UInt8)]) {
        guard active.load(ordering: .relaxed) else { return }
        if writes.count > Self.burstLimit {
            var last = [Int](repeating: -1, count: 0x20)
            for (i, w) in writes.enumerated() { last[Int(w.reg & 0x1F)] = i }
            for i in last.filter({ $0 >= 0 }).sorted() {
                let w = writes[i]
                if !ring.push(.write(w.cycle, w.reg, w.value)) { dropped.add(1, ordering: .relaxed) }
            }
            return
        }
        for w in writes where !ring.push(.write(w.cycle, w.reg, w.value)) {
            dropped.add(1, ordering: .relaxed)
        }
    }

    /// Engine thread: the engine has run up to `cycle`.
    public func mark(_ cycle: UInt64) {
        guard active.load(ordering: .relaxed) else { return }
        if !ring.push(.mark(cycle)) { dropped.add(1, ordering: .relaxed) }
    }

    /// Engine thread: a new engine (cold reset) starts at `cycle`.
    public func reset(_ cycle: UInt64) {
        guard active.load(ordering: .relaxed) else { return }
        if !ring.push(.reset(cycle)) { dropped.add(1, ordering: .relaxed) }
    }
}

/// Owns the SID model on the audio thread: drains the event ring into a `SIDStream` and renders.
///
/// Timing: the chip runs on the engine's cycle timeline, `latency` cycles behind the newest engine
/// mark (about two frames). The engine runs in bursts and the audio device has its own clock, so
/// whenever the chip drifts more than `resyncThreshold` from that target its cycle counter is
/// simply set to the target. That moves only the timing of later writes; the waveform continues
/// without a click, and a big jump (boot warp, stall, pause) is never rendered through.
///
/// `SIDModel`/`SIDStream` are not thread-safe: after `init` only the audio thread touches them.
public final class SIDRenderer: @unchecked Sendable {
    public static let latency: UInt64 = 2 * VirtualClock.cyclesPerFrame
    public static let resyncThreshold: UInt64 = 2 * VirtualClock.cyclesPerFrame
    public static let streamCapacity = 4096

    public let sampleRate: Double
    public let feed: AudioFeed
    public let muted = Atomic<Bool>(false)
    private let volumeBits = Atomic<UInt32>(Float(0.8).bitPattern)

    private let sid: SIDModel
    private let stream: SIDStream
    /// Newest engine cycle announced by a mark.
    private var latestCycle: UInt64 = 0
    private var started = false
    /// Last value written to each register (to rebuild the chip after an output device change).
    private let shadow = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x20)

    public init(sampleRate: Double, feed: AudioFeed, restoring registers: [UInt8]? = nil) {
        self.sampleRate = sampleRate
        self.feed = feed
        sid = SIDModel(clockHz: SIDModel.ntscClockHz, sampleRate: sampleRate)
        stream = SIDStream(sid: sid, capacity: Self.streamCapacity)
        shadow.initialize(repeating: 0, count: 0x20)
        if let registers {
            for (r, v) in registers.prefix(0x19).enumerated() {
                sid.write(r, v)
                shadow[r] = v
            }
        }
    }

    deinit { shadow.deallocate() }

    public var volume: Float {
        get { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
        set { volumeBits.store(max(0, min(1, newValue)).bitPattern, ordering: .relaxed) }
    }

    /// Register values as last written (call only when the audio thread is stopped).
    public var registers: [UInt8] { Array(UnsafeBufferPointer(start: shadow, count: 0x19)) }

    /// The chip's cycle (for tests; audio thread only).
    public var chipCycle: UInt64 { sid.cycle }

    /// Audio thread: fills `out` with `count` mono samples.
    public func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        drain()
        guard started, !muted.load(ordering: .relaxed) else {
            out.update(repeating: 0, count: count)
            return
        }
        // Keep the chip `latency` behind the engine; jump instead of rendering through gaps.
        let target = latestCycle > Self.latency ? latestCycle - Self.latency : 0
        let chip = sid.cycle
        if chip > target ? chip - target > Self.resyncThreshold : target - chip > Self.resyncThreshold {
            sid.cycle = target
        }
        stream.render(into: out, count: count)
        let v = volume
        if v != 1 { for i in 0..<count { out[i] *= v } }
    }

    /// Moves events from the ring into the stream. The stream's queue never grows past its
    /// preallocated capacity: if a burst fills it, the queued writes are applied at once (a burst
    /// that big only happens before a clock jump, which would apply them immediately anyway).
    private func drain() {
        while let e = feed.ring.pop() {
            switch e.kind {
            case .write:
                if stream.pendingCount >= Self.streamCapacity - 1 { flushQueue() }
                stream.enqueue(cycle: e.cycle, reg: Int(e.reg), value: e.value)
                shadow[Int(e.reg & 0x1F)] = e.value
            case .mark:
                latestCycle = e.cycle
                if !started {
                    started = true
                    sid.cycle = latestCycle > Self.latency ? latestCycle - Self.latency : 0
                }
            case .reset:
                flushQueue()
                sid.reset()
                shadow.update(repeating: 0, count: 0x20)
                latestCycle = e.cycle
                sid.cycle = latestCycle > Self.latency ? latestCycle - Self.latency : 0
                started = true
            }
        }
    }

    /// Applies every queued write immediately, without clocking the chip.
    private func flushQueue() {
        let now = sid.cycle
        sid.cycle = .max
        stream.advance(toCycle: .max)
        sid.cycle = now
    }
}
