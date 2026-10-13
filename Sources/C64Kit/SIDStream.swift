/// A SID register write stamped with the chip cycle at which it happens.
public struct SIDWrite: Sendable, Equatable {
    public var cycle: UInt64
    public var reg: Int
    public var value: UInt8

    public init(cycle: UInt64, reg: Int, value: UInt8) {
        self.cycle = cycle
        self.reg = reg
        self.value = value
    }
}

/// Plays timestamped register writes through a `SIDModel`: rendering clocks the chip and applies each
/// write exactly when the chip reaches its cycle, so the audio matches the writes cycle for cycle.
///
/// Writes must be enqueued in nondecreasing cycle order; a write whose cycle has already passed is
/// applied before the next cycle is clocked. Rendering does not allocate. Not thread-safe: the app
/// wraps the queue in a lock-free ring.
public final class SIDStream {
    public let sid: SIDModel
    private var queue: [SIDWrite] = []
    private var head = 0

    public init(sid: SIDModel, capacity: Int = 4096) {
        self.sid = sid
        queue.reserveCapacity(capacity)
    }

    /// The chip cycle the next sample starts at.
    public var cycle: UInt64 { sid.cycle }

    /// Writes not yet applied.
    public var pendingCount: Int { queue.count - head }

    public func enqueue(_ write: SIDWrite) {
        if head > 0 && queue.count == queue.capacity {
            queue.removeSubrange(0..<head)
            head = 0
        }
        queue.append(write)
    }

    public func enqueue(cycle: UInt64, reg: Int, value: UInt8) {
        enqueue(SIDWrite(cycle: cycle, reg: reg, value: value))
    }

    /// Renders `count` samples, applying queued writes at their cycles.
    public func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        var produced = 0
        while produced < count {
            applyDue()
            let limit = head < queue.count ? Int(clamping: queue[head].cycle - sid.cycle) : .max
            produced += sid.run(cycles: limit, into: out + produced, maxSamples: count - produced).samples
        }
        recycle()
    }

    /// Renders `count` samples starting at chip cycle `start`. If the chip is behind `start`, it is first
    /// clocked silently (applying writes) up to it; if it is already past, rendering continues from where it is.
    public func render(into out: UnsafeMutablePointer<Float>, count: Int, startingAt start: UInt64) {
        advance(toCycle: start)
        render(into: out, count: count)
    }

    /// Allocating convenience for `render(into:count:)`.
    public func render(count: Int) -> [Float] {
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            render(into: buffer.baseAddress!, count: count)
            initialized = count
        }
    }

    /// Clocks the chip without output up to `target`, applying the writes on the way.
    public func advance(toCycle target: UInt64) {
        while sid.cycle < target {
            applyDue()
            var limit = target - sid.cycle
            if head < queue.count { limit = min(limit, queue[head].cycle - sid.cycle) }
            sid.clock(cycles: Int(clamping: limit))
        }
        applyDue()
        recycle()
    }

    private func applyDue() {
        let now = sid.cycle
        while head < queue.count && queue[head].cycle <= now {
            sid.write(queue[head].reg, queue[head].value)
            head += 1
        }
    }

    private func recycle() {
        if head > 0 && head == queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        }
    }

    /// Renders a register log offline (e.g. for WAV export): a fresh chip whose clock starts at `start`
    /// plays `log` until `end`. Writes before `start` are applied up front.
    public static func render(log: [SIDWrite], from start: UInt64, to end: UInt64,
                              clockHz: Double = SIDModel.ntscClockHz, sampleRate: Double) -> [Float] {
        let sid = SIDModel(clockHz: clockHz, sampleRate: sampleRate)
        sid.cycle = start
        let stream = SIDStream(sid: sid, capacity: log.count)
        for write in log where write.cycle < end { stream.enqueue(write) }
        let count = end > start ? Int((Double(end - start) * sampleRate / clockHz).rounded()) : 0
        return stream.render(count: count)
    }
}
