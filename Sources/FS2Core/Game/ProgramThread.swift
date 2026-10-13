#if !os(WASI)
import Foundation

/// Runs the game program on a thread of its own, with a stack large enough for the nested
/// cold restarts, and gives it a way to leave a call stack that must never resume.
///
/// The original's RUN/STOP + RESTORE restart jumps to $A7E2 from the NMI handler: the 6502 simply
/// abandons whatever the interrupted code was doing (the init chain resets the stack). The port
/// takes the NMI at a poll point inside ported routines (the scenery interpreter, the key wait), so
/// the restarted program runs nested inside those Swift frames, and they must never continue. When
/// such a run stops, `Machine.abandonStack` reports the end to the host and parks the thread for
/// good (its frames are leaked, one parked thread per restart that ended a run). A run that stops
/// at the top of its own main loop simply returns and the thread ends.
public enum ProgramThread {
    /// How a program run ended.
    public enum Ending: Sendable, Equatable {
        /// `body` returned.
        case returned
        /// The run stopped inside a nested restart (`Machine.abandonStack`), with nil for a normal
        /// stop or a description of what ended it.
        case abandoned(String?)
    }

    /// The default stack: 64 MB (a nested restart adds the interrupted frames, a few KB each).
    public static let defaultStackSize = 64 << 20

    /// Runs `body` with `machine` on a new thread and waits until it returns or the run is
    /// abandoned. `machine.abandonStack` is set for the duration.
    @discardableResult
    public static func run(_ machine: Machine, stackSize: Int = defaultStackSize,
                           _ body: @escaping (Machine) -> Void) -> Ending {
        let run = Run(machine: machine, body: body)
        let done = DispatchSemaphore(value: 0)
        machine.abandonStack = { reason in
            run.ending = .abandoned(reason)
            done.signal()
            parkForever()
        }
        let thread = Thread {
            run.body(run.machine)
            run.ending = .returned
            done.signal()
        }
        thread.stackSize = stackSize
        thread.start()
        done.wait()
        machine.abandonStack = nil
        return run.ending
    }

    /// Blocks the calling thread forever.
    static func parkForever() -> Never {
        let never = DispatchSemaphore(value: 0)
        while true { never.wait() }
    }

    /// The run's state, handed to the program thread. The host only reads it after the
    /// semaphore, so the accesses never overlap.
    private final class Run: @unchecked Sendable {
        let machine: Machine
        let body: (Machine) -> Void
        var ending = Ending.returned

        init(machine: Machine, body: @escaping (Machine) -> Void) {
            self.machine = machine
            self.body = body
        }
    }
}
#endif
