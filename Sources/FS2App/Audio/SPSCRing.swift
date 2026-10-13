import Synchronization

/// A lock-free single-producer, single-consumer ring of trivially copyable values, with storage
/// preallocated at init. One thread may push and one other thread may pop; neither ever blocks or
/// allocates, so the consumer can be a real-time audio thread.
///
/// Positions are free-running counters: the producer publishes a slot with a releasing store of
/// `tail` after writing it, and the consumer frees it with a releasing store of `head` after reading.
final class SPSCRing<Element: BitwiseCopyable>: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element>
    /// Next position to read (written by the consumer only).
    private let head = Atomic<Int>(0)
    /// Next position to write (written by the producer only).
    private let tail = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two.
    init(capacity: Int) {
        precondition(capacity > 0)
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
    }

    deinit { storage.deallocate() }

    /// Number of elements waiting (a snapshot; exact on either the producer or the consumer thread).
    var count: Int { tail.load(ordering: .acquiring) - head.load(ordering: .acquiring) }

    /// Producer: appends `element`; false (nothing written) when the ring is full.
    @discardableResult
    func push(_ element: Element) -> Bool {
        let t = tail.load(ordering: .relaxed)
        if t - head.load(ordering: .acquiring) >= capacity { return false }
        (storage + (t & mask)).initialize(to: element)
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    /// Consumer: the oldest element without removing it.
    func peek() -> Element? {
        let h = head.load(ordering: .relaxed)
        if h == tail.load(ordering: .acquiring) { return nil }
        return storage[h & mask]
    }

    /// Consumer: removes and returns the oldest element.
    func pop() -> Element? {
        let h = head.load(ordering: .relaxed)
        if h == tail.load(ordering: .acquiring) { return nil }
        let e = storage[h & mask]
        head.store(h + 1, ordering: .releasing)
        return e
    }
}
