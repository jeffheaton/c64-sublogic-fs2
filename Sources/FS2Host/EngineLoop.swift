import C64Kit
import FS2Core

/// Engine-thread state: the engine, the latest user input, its key timing and the restart
/// sequence. Shared by the Mac app's engine thread and the web worker (`EngineSession`); tests
/// drive a real engine through it without the wall-clock thread.
///
/// The player's keys go through `KeyTiming` (minimum hold and release, CTRL before the key it
/// modifies). The engine latches `engine.input` at each frame end, so every `onFrame` commits the
/// matrix just latched and decides the one for the frame after.
public final class EngineLoop {
    public let engine: any GameEngine
    public internal(set) var userInput = InputState()
    public var sequencer = RestartSequencer()
    public private(set) var keyTiming = KeyTiming()

    /// - Parameter publish: gets every frame first (the display, the audio feed), before the loop
    ///   decides the input for the frame after.
    public init(engine: any GameEngine, publish: @escaping (FrameOutput) -> Void) {
        self.engine = engine
        engine.onFrame = { [unowned self] frame in
            publish(frame)
            self.frameEnded()
        }
        engine.input = shapedUserInput()
    }

    /// A frame ended: the engine latched `engine.input` for the next frame. Sets the input for
    /// the frame after (the engine applies it at the next frame boundary).
    private func frameEnded() {
        keyTiming.commit(engine.input.keys)
        let pendingRestore = engine.input.restore
        let next: InputState
        if sequencer.isActive {
            next = sequencer.next(user: userInput)
            keyTiming.dropRequests()
        } else {
            next = shapedUserInput()
        }
        engine.input = next
        if pendingRestore { engine.input.restore = true }
    }

    /// New input from the UI. Unless a restart sequence owns the keys, it goes to the engine right
    /// away (applied at the next frame boundary), shaped by the key timing.
    public func setUserInput(_ input: InputState) {
        userInput = input
        keyTiming.observe(input.keys)
        guard !sequencer.isActive else { return }
        let pendingRestore = engine.input.restore
        engine.input = shapedUserInput()
        if pendingRestore { engine.input.restore = true }
    }

    /// The player's input with the keys shaped for the next undecided frame.
    private func shapedUserInput() -> InputState {
        var input = userInput
        input.keys = keyTiming.decide()
        return input
    }
}
