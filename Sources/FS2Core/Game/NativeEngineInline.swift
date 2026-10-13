/// Inline execution of `NativeEngine` (`Execution.inline`): the program runs on the caller's stack
/// with no thread of its own, for WebAssembly (which has none) and for the tests that compare the
/// two kinds.
///
/// The threaded host calls `run(untilCycle:)` (or `runToKeyWait`, `skipDiskLoading`) and does its
/// own work between the calls; each call resumes the program until it parks where the call is done.
/// Inline, the host is asked for that same sequence of calls (`InlineRequest`) at the parks
/// themselves: `NativeEngineGate.park` calls back into the engine, which does what the threaded
/// call does after each resume (present the frame, check the target) and, when the call is done,
/// asks the host for the next one, on the program's stack. When it returns, the program goes on,
/// exactly as the threaded program does when `resume` signals it. What the program computes after a
/// park depends only on the state the host leaves, so both kinds compute the same frames, sound
/// and memory for the same calls.

/// One call the host makes of an inline engine: what the threaded host would call.
public enum InlineRequest: Sendable, Equatable {
    /// `run(untilCycle:)`.
    case run(untilCycle: UInt64)
    /// `runToKeyWait(maxFrames:deliverFrames:)`.
    case runToKeyWait(maxFrames: Int, deliverFrames: Bool)
    /// `skipDiskLoading()`.
    case skipDiskLoading
}

/// The host of an inline engine (the web worker, the tests). Called on the program's stack while
/// the program is parked: it may set `input` and `options`, `poke` memory and block as long as it
/// likes (the wall-clock pacing), as the threaded host does between its calls, but it must not
/// make the engine run (no `run` calls: return the request instead).
public protocol NativeEngineInlineHost: AnyObject {
    /// The next call. `previous` is the call just done (nil before the first); `stoppedAtKeyWait`
    /// is its result when it was a `runToKeyWait` or `skipDiskLoading`.
    func next(_ engine: NativeEngine, after previous: InlineRequest?, stoppedAtKeyWait: Bool) -> InlineRequest
    /// The program ended (`NativeEngine.endReason`); it never runs again, and this never returns.
    func programEnded(_ engine: NativeEngine, reason: String) -> Never
}

/// An inline engine's bookkeeping.
struct InlineState {
    var host: (any NativeEngineInlineHost)?
    /// The call in progress and the cycle it runs to (`run`: its target; key waits: the frame limit).
    var current: (request: InlineRequest, limit: UInt64)?
    /// True while the engine or its host works at a park (a park in there is a bug: host code must
    /// never charge cycles).
    var inHost = false
}

extension NativeEngine {
    /// Runs the program on this stack, with `host` making the calls at its parks, until the program
    /// ends (`host.programEnded`). Inline engines only, once.
    public func runInline(_ host: some NativeEngineInlineHost) -> Never {
        precondition(execution == .inline, "a threaded engine runs through run(untilCycle:)")
        precondition(inline.host == nil, "runInline runs once")
        inline.host = host
        core.gate.inline = { [unowned self] stop in self.parked(stop) }
        inline.inHost = true
        advance(after: nil, stoppedAtKeyWait: false)
        inline.inHost = false
        core.runNormal()
    }

    /// The program parked: what the threaded call does after `resume` returns, then the next call.
    private func parked(_ stop: NativeEngineGate.Stop) {
        precondition(!inline.inHost, "the program ran while the inline host worked")
        inline.inHost = true
        defer { inline.inHost = false }
        if stop == .finished {
            inline.host!.programEnded(self, reason: endReason ?? "the program ended")
        }
        guard let current = inline.current else { preconditionFailure("a park with no call in progress") }
        let (request, limit) = current
        switch request {
        case .run:
            handle(stop)
            if endReason == nil && machine.clock.cycles < limit {
                core.target = limit
                prepareResume()
                return
            }
            complete(request, stoppedAtKeyWait: false)
        case .runToKeyWait(_, let deliverFrames):
            keyWaitParked(stop, request, limit, deliverFrames: deliverFrames)
        case .skipDiskLoading:
            keyWaitParked(stop, request, limit, deliverFrames: false)
        }
    }

    /// `runToKeyWait`'s loop after a resume.
    private func keyWaitParked(_ stop: NativeEngineGate.Stop, _ request: InlineRequest, _ limit: UInt64,
                               deliverFrames: Bool) {
        if stop == .keyWait {
            parkedAtKeyWait = machine.clock.cycles
            complete(request, stoppedAtKeyWait: true)
            return
        }
        handle(stop)
        if endReason == nil && machine.clock.cycles < limit {
            core.target = limit
            prepareResume(deliverFrames: deliverFrames)
            return
        }
        complete(request, stoppedAtKeyWait: false)
    }

    /// A call is done: what the threaded call does on its way out, then the host's next call.
    private func complete(_ request: InlineRequest, stoppedAtKeyWait: Bool) {
        inline.current = nil
        switch request {
        case .run:
            break
        case .runToKeyWait:
            core.stopAtKeyWait = false
        case .skipDiskLoading:
            core.stopAtKeyWait = false
            deliverFrame(at: machine.clock.cycles, frameEnd: false)
        }
        advance(after: request, stoppedAtKeyWait: stoppedAtKeyWait)
    }

    /// Asks the host for calls until one needs the program to run (then sets it up, as the
    /// threaded call does before its first resume, and returns to let the program go on). Calls
    /// that are done without running (the clock is already there) complete at once.
    private func advance(after previous: InlineRequest?, stoppedAtKeyWait: Bool) {
        var previous = previous
        var stopped = stoppedAtKeyWait
        while true {
            let request = inline.host!.next(self, after: previous, stoppedAtKeyWait: stopped)
            if begin(request) { return }
            // Done at once: what the threaded call returns without resuming.
            switch request {
            case .run:
                stopped = false
            case .runToKeyWait, .skipDiskLoading:
                stopped = parkedAtKeyWait == machine.clock.cycles
                if case .skipDiskLoading = request { deliverFrame(at: machine.clock.cycles, frameEnd: false) }
            }
            previous = request
        }
    }

    /// The entry of `request`'s threaded call up to its first resume. True when the program must
    /// run (the call is in progress), false when the call is already done.
    private func begin(_ request: InlineRequest) -> Bool {
        switch request {
        case .run(let cycle):
            guard endReason == nil && machine.clock.cycles < cycle else { return false }
            inline.current = (request, cycle)
            core.target = cycle
            prepareResume()
            return true
        case .runToKeyWait(let maxFrames, let deliverFrames):
            return beginKeyWait(request, maxFrames: maxFrames, deliverFrames: deliverFrames)
        case .skipDiskLoading:
            return beginKeyWait(request, maxFrames: 9000, deliverFrames: false)
        }
    }

    /// `runToKeyWait`'s entry: at once when parked at the key wait of the last stop, else the frame
    /// limit and the key-wait stop.
    private func beginKeyWait(_ request: InlineRequest, maxFrames: Int, deliverFrames: Bool) -> Bool {
        if parkedAtKeyWait == machine.clock.cycles { return false }
        let limit = machine.clock.cycles + UInt64(max(0, maxFrames)) * VirtualClock.cyclesPerFrame
        guard endReason == nil && machine.clock.cycles < limit else { return false }
        core.stopAtKeyWait = true
        inline.current = (request, limit)
        core.target = limit
        prepareResume(deliverFrames: deliverFrames)
        return true
    }
}
