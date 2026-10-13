#if !os(WASI)
import Foundation
#endif

/// The handshake between the host thread (the one that calls `NativeEngine.run`) and the thread
/// the game program runs on.
///
/// The port is straight-line code: the main loop, the scenery interpreter and the key waits never
/// return to a caller between frames. So the program runs on a thread of its own and the two
/// threads take turns: the host `resume`s the program and blocks; the program runs until it
/// `park`s (inside `Machine.charge`, at a frame end, at the top of the main loop ...) and blocks;
/// the host goes on. Exactly one of the two runs at any time, and each hand-over goes through a
/// semaphore, so everything one side wrote is visible to the other and `Machine` is never touched
/// by both at once.
///
/// Inline execution (`inline` set; the only kind on WASI, which has no threads): there is no
/// program thread. The program runs on the host's own stack, and each park calls `inline` there
/// with the reason; when it returns, the program goes on. `NativeEngine.runInline` drives it.
final class NativeEngineGate: @unchecked Sendable {
    /// Why the program handed control back.
    enum Stop: Equatable, Sendable {
        /// The virtual clock reached the run target.
        case target
        /// A frame ended at this cycle (the host presents it and calls `onFrame`).
        case frameEnd(UInt64)
        /// The top of the main loop ($204B) was reached (only while the host asks for it).
        case iteration
        /// A key wait polled for the first time (only while the host asks for it).
        case keyWait
        /// Replay mode: checkpoint k matched.
        case checkpoint(Int)
        /// The program ended: it will never run again.
        case finished
    }

    /// Inline execution: called on the program's stack at every park (`.finished` when the program
    /// ended, and then it must not return).
    var inline: ((Stop) -> Void)?

    #if !os(WASI)
    private let toProgram = DispatchSemaphore(value: 0)
    private let toHost = DispatchSemaphore(value: 0)
    #endif
    /// Written by the program before it signals the host, read by the host after its wait.
    private var stop = Stop.target
    /// Written by the host before it signals the program, read by the program after its wait.
    private(set) var terminating = false
    /// What the program thread does when it wakes up to terminate (it never returns).
    var exitProgram: () -> Never = NativeEngineGate.exitThread

    // MARK: Program side

    /// Blocks until the host resumes the program for the first time.
    func waitForStart() {
        guard inline == nil else { return }
        #if !os(WASI)
        toProgram.wait()
        if terminating { exitProgram() }
        #endif
    }

    /// Hands control to the host and blocks until it resumes the program.
    func park(_ reason: Stop) {
        if let inline {
            inline(reason)
            return
        }
        #if !os(WASI)
        stop = reason
        toHost.signal()
        toProgram.wait()
        if terminating { exitProgram() }
        #endif
    }

    /// The program has ended: tells the host and blocks until the engine goes away.
    func parkForGood() -> Never {
        if let inline {
            inline(.finished)
            preconditionFailure("the inline host returned after the program ended")
        }
        #if os(WASI)
        preconditionFailure("no program thread on WASI")
        #else
        stop = .finished
        toHost.signal()
        while true {
            toProgram.wait()
            if terminating { exitProgram() }
            // A resume after the end (the host does not do that) parks again at once.
            toHost.signal()
        }
        #endif
    }

    // MARK: Host side

    /// Lets the program run until it parks again; returns why it did.
    func resume() -> Stop {
        #if os(WASI)
        preconditionFailure("no program thread on WASI: use NativeEngine.runInline")
        #else
        toProgram.signal()
        toHost.wait()
        return stop
        #endif
    }

    /// Ends the program thread (the program must be parked or not started). Does not wait.
    func terminate() {
        terminating = true
        #if !os(WASI)
        toProgram.signal()
        #endif
    }

    /// Ends the calling thread without returning into its frames. The frames' references leak
    /// (the machine, a few hundred KB); the thread and its stack are released.
    static func exitThread() -> Never {
        #if os(WASI)
        preconditionFailure("no program thread on WASI")
        #else
        Thread.exit()
        fatalError("Thread.exit returned")
        #endif
    }
}
