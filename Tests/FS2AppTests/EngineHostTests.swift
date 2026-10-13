import C64Kit
import FS2Core
@testable import FS2App
@testable import FS2Host
import Foundation
import Testing

/// What a fake engine saw, shared between the engine thread and the test (lock protected).
final class EngineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _engines = 0
    private var _inputs: [InputState] = []
    private var _restores = 0
    private var _options: [EngineOptions] = []

    func engineCreated() { lock.withLock { _engines += 1 } }
    func options(_ o: EngineOptions) { lock.withLock { _options.append(o) } }
    var optionsSet: [EngineOptions] { lock.withLock { _options } }
    func frame(input: InputState) {
        lock.withLock {
            _inputs.append(input)
            if input.restore { _restores += 1 }
        }
    }
    var engines: Int { lock.withLock { _engines } }
    var inputs: [InputState] { lock.withLock { _inputs } }
    var restores: Int { lock.withLock { _restores } }
}

/// A `GameEngine` that only keeps time: a frame every 17,095 cycles, one SID write per frame.
final class FakeEngine: GameEngine {
    var cycles: UInt64 = 0
    var input = InputState()
    var onFrame: ((FrameOutput) -> Void)?
    var options = EngineOptions() {
        didSet { recorder.options(options) }
    }
    private var frame: UInt64 = 0
    private let recorder: EngineRecorder

    init(recorder: EngineRecorder) {
        self.recorder = recorder
        recorder.engineCreated()
    }

    func run(untilCycle cycle: UInt64) {
        let cpf = VirtualClock.cyclesPerFrame
        while cycles < cycle {
            let boundary = (cycles / cpf + 1) * cpf
            guard boundary <= cycle else { cycles = cycle; return }
            cycles = boundary
            frame += 1
            recorder.frame(input: input)
            input.restore = false
            onFrame?(FrameOutput(pixels: [UInt8](repeating: UInt8(frame & 0x0F), count: 16), frame: frame,
                                 sidWrites: [(cycles - 100, 0x18, 0x0F)], monochrome: false))
        }
    }
}

@Suite(.serialized) struct EngineHostTests {
    private func makeHost(_ recorder: EngineRecorder, frames: FrameExchange, audio: AudioFeed? = nil) -> EngineHost {
        EngineHost(frames: frames, audio: audio, quickBoot: true) { FakeEngine(recorder: recorder) }
    }

    private func latestFrame(_ x: FrameExchange, _ last: inout UInt64) -> UInt64 {
        if let s = x.takeLatest() { last = s.frame }
        return last
    }

    @Test func pacesToTheWallClockAndPauses() throws {
        let recorder = EngineRecorder()
        let frames = FrameExchange()
        let host = makeHost(recorder, frames: frames)
        host.start()
        defer { host.stop() }
        var last: UInt64 = 0
        Thread.sleep(forTimeInterval: 0.5)
        let n = latestFrame(frames, &last)
        // 0.5 s at 59.83 fps is about 30 frames.
        #expect((20...40).contains(n), "frames after 0.5 s: \(n)")

        host.setPaused(true)
        Thread.sleep(forTimeInterval: 0.1)
        let paused = latestFrame(frames, &last)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(latestFrame(frames, &last) == paused, "no frames while paused")

        host.setPaused(false)
        Thread.sleep(forTimeInterval: 0.3)
        let resumed = latestFrame(frames, &last) - paused
        // No catch-up burst for the paused time: about 18 frames, not 36.
        #expect((10...26).contains(resumed), "frames after resuming: \(resumed)")
    }

    @Test func inputReachesTheEngineAtFrameBoundaries() {
        let recorder = EngineRecorder()
        let host = makeHost(recorder, frames: FrameExchange())
        host.start()
        defer { host.stop() }
        var input = InputState()
        input.keys.set(.a, pressed: true)
        input.keys.joystick1 = [.up]
        host.setInput(input)
        Thread.sleep(forTimeInterval: 0.15)
        #expect(recorder.inputs.last == input)
        host.setInput(InputState())
        Thread.sleep(forTimeInterval: 0.1)
        #expect(recorder.inputs.last == InputState())
    }

    /// A key pressed and let go before the engine thread reads the mailbox (key events delivered
    /// together after a stall of the main thread) is still a press: the key timing holds it for
    /// its four frames.
    @Test func aTapBetweenTwoReadsIsNotLost() {
        let recorder = EngineRecorder()
        let host = makeHost(recorder, frames: FrameExchange())
        host.start()
        defer { host.stop() }
        Thread.sleep(forTimeInterval: 0.1)
        for _ in 0..<2 {
            var tap = InputState()
            tap.keys.set(.q, pressed: true)
            host.setInput(tap)
            host.setInput(InputState())
            Thread.sleep(forTimeInterval: 0.25)
        }
        let q = String(recorder.inputs.map { $0.keys.isPressed(.q) ? "#" : "." })
        #expect(q.components(separatedBy: ".").filter { !$0.isEmpty } == ["####", "####"], "\(q)")
    }

    @Test func restartHoldsRunStopThenRestore() {
        let recorder = EngineRecorder()
        let host = makeHost(recorder, frames: FrameExchange())
        host.start()
        defer { host.stop() }
        var held = InputState()
        held.keys.set(.space, pressed: true)
        host.setInput(held)
        Thread.sleep(forTimeInterval: 0.1)
        host.requestRestart()
        Thread.sleep(forTimeInterval: Double(RestartSequencer.totalFrames + 10) / 59.8)
        let inputs = recorder.inputs
        #expect(recorder.restores == 1)
        guard let r = inputs.firstIndex(where: \.restore) else { return }
        // RUN/STOP alone for the frames before RESTORE, then the user's input again.
        let before = inputs[(r - RestartSequencer.holdFrames + 1)...r]
        #expect(before.allSatisfy { $0.keys.isPressed(.runStop) && !$0.keys.isPressed(.space) })
        #expect(inputs.last?.keys.isPressed(.space) == true && inputs.last?.keys.isPressed(.runStop) == false)
    }

    @Test func resetBuildsAFreshEngineAndAudioFollows() {
        let recorder = EngineRecorder()
        let frames = FrameExchange()
        let audio = AudioFeed()
        audio.active.store(true, ordering: .relaxed)
        let host = makeHost(recorder, frames: frames, audio: audio)
        host.start()
        defer { host.stop() }
        Thread.sleep(forTimeInterval: 0.4)
        var last: UInt64 = 0
        let before = latestFrame(frames, &last)
        host.requestReset()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(recorder.engines == 2)
        #expect(latestFrame(frames, &last) < before, "the new engine starts again from frame 1")
        var kinds: [AudioEvent.Kind] = []
        while let e = audio.ring.pop() { kinds.append(e.kind) }
        #expect(kinds.first == .reset)
        #expect(kinds.filter { $0 == .reset }.count == 2)
        #expect(kinds.contains(.write) && kinds.contains(.mark))
    }

    @Test func stopIsPromptAndIdempotent() {
        let host = makeHost(EngineRecorder(), frames: FrameExchange())
        let options = EngineOptions(pacing: .smooth, strictJoystick: true)
        host.setOptions(options)
        #expect(host.options == options)
        host.start()
        Thread.sleep(forTimeInterval: 0.05)
        let t = Date()
        host.stop()
        host.stop()
        #expect(Date().timeIntervalSince(t) < 0.2)
    }

    /// The options set on the host reach the engine when it is built and whenever they change.
    @Test func optionsReachTheEngine() {
        let recorder = EngineRecorder()
        let host = makeHost(recorder, frames: FrameExchange())
        let smooth = EngineOptions(pacing: .smooth, strictJoystick: false)
        host.setOptions(smooth)
        host.start()
        defer { host.stop() }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(recorder.optionsSet.last == smooth)
        let strict = EngineOptions(pacing: .authentic, strictJoystick: true)
        host.setOptions(strict)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(recorder.optionsSet.last == strict)
        host.requestReset()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(recorder.engines == 2 && recorder.optionsSet.last == strict, "a new engine starts with the options")
    }

    @Test func factoryErrorsAreReported() {
        struct Boom: Error {}
        let reported = EngineRecorder()
        let host = EngineHost(frames: FrameExchange(), audio: nil, onError: { _ in reported.engineCreated() }) {
            throw Boom()
        }
        host.start()
        Thread.sleep(forTimeInterval: 0.05)
        host.stop()
        #expect(reported.engines == 1)
    }
}
