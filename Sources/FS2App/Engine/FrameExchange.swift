import FS2Core
import Synchronization

/// The newest frame handed from the engine thread to the display, triple-buffer style: the engine
/// fills its back slot and swaps it with the middle one; the display swaps the middle slot to the
/// front when it is fresh. Neither side waits for the other, and the lock is held only for the swap.
final class FrameExchange: Sendable {
    /// One frame: palette indices plus what the presenter needs to know about it.
    final class Slot: @unchecked Sendable {
        var pixels: [UInt8] = []
        var frame: UInt64 = 0
        var monochrome = false
        /// Increases with every frame published through this exchange (lets the display skip repeats).
        var serial: UInt64 = 0
    }

    private struct Indices {
        var back = 0, middle = 1, front = 2
        var fresh = false
        var serial: UInt64 = 0
    }

    private let slots = [Slot(), Slot(), Slot()]
    private let indices = Mutex(Indices())

    init() {}

    /// Engine thread: publishes a finished frame.
    func publish(_ frame: FrameOutput) {
        let backIndex = indices.withLock { $0.back }
        let slot = slots[backIndex]
        slot.pixels = frame.pixels          // the engine allocates each frame; no copy is made
        slot.frame = frame.frame
        slot.monochrome = frame.monochrome
        indices.withLock { s in
            s.serial += 1
            slot.serial = s.serial
            swap(&s.back, &s.middle)
            s.fresh = true
        }
    }

    /// Display: the newest frame if one arrived since the last call, else nil. The returned slot
    /// stays valid (unchanged) until the next call.
    func takeLatest() -> Slot? {
        let index: Int? = indices.withLock { s in
            guard s.fresh else { return nil }
            swap(&s.front, &s.middle)
            s.fresh = false
            return s.front
        }
        return index.map { slots[$0] }
    }
}
