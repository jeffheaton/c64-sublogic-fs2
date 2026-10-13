import FS2Core

/// Wall-clock pacing for the engine thread: where the engine should be at a given moment, at the
/// NTSC rate, in whole frames.
///
/// The engine runs one frame whenever the wall clock has passed the next frame boundary, and the
/// thread sleeps otherwise. When the engine falls more than `maxBacklog` behind (a stall, the
/// machine sleeping, a debugger, an engine slower than real time), the rest of the debt is
/// forgiven: the engine catches up at most `maxBacklog` and, while it stays behind, keeps running
/// flat out instead of sleeping, so it never spirals and never wastes time.
public struct FramePacer: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Run the engine until this cycle (the next frame boundary).
        case run(untilCycle: UInt64)
        /// Nothing is due yet: sleep this long.
        case sleep(nanoseconds: UInt64)
    }

    public static let clockHz = VirtualClock.hz
    public static let cyclesPerFrame = VirtualClock.cyclesPerFrame
    /// Most the engine may fall behind the wall clock before the rest is dropped (about 0.1 s).
    public static let maxBacklog: UInt64 = 6 * VirtualClock.cyclesPerFrame

    /// The engine's cycle count at `baseTime` (nanoseconds of uptime).
    public private(set) var baseCycle: UInt64
    public private(set) var baseTime: UInt64

    public init(now: UInt64, cycles: UInt64) {
        baseTime = now
        baseCycle = cycles
    }

    /// Starts pacing afresh from `cycles` at `now` (after a pause or a new engine): no backlog.
    public mutating func rebase(now: UInt64, cycles: UInt64) {
        baseTime = now
        baseCycle = cycles
    }

    /// The cycle the wall clock says the engine should have reached at `now`.
    public func target(now: UInt64) -> UInt64 {
        baseCycle &+ UInt64(Double(now &- baseTime) * Self.clockHz / 1e9)
    }

    /// What to do next, for an engine at `cycles` at time `now`.
    public mutating func next(now: UInt64, cycles: UInt64) -> Action {
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
