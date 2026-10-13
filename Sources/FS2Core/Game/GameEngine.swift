import C64Kit

/// Live inputs the app feeds the engine (applied at the next frame boundary).
public struct InputState: Sendable, Equatable {
    public var keys = KeyMatrix()
    /// Set to request a RESTORE keypress (NMI) on the next frame.
    public var restore = false
    public init() {}
}

/// One finished video frame plus the SID writes that happened during it.
public struct FrameOutput: Sendable {
    /// Palette indices, `VICPresenter.width` × `VICPresenter.height`.
    public var pixels: [UInt8]
    /// Index of this frame since power-on.
    public var frame: UInt64
    /// SID register writes during the frame, with absolute C64 cycle timestamps.
    public var sidWrites: [(cycle: UInt64, reg: UInt8, value: UInt8)]
    /// True when the display is set to black-and-white monitor mode.
    public var monochrome: Bool

    public init(pixels: [UInt8], frame: UInt64, sidWrites: [(cycle: UInt64, reg: UInt8, value: UInt8)],
                monochrome: Bool) {
        self.pixels = pixels; self.frame = frame; self.sidWrites = sidWrites; self.monochrome = monochrome
    }
}

/// How the engine paces what the window shows (View ▸ Pacing).
public enum Pacing: String, CaseIterable, Sendable {
    /// The original cadence: the out-the-window view changes when a main-loop iteration completes
    /// (about once a second at Meigs), exactly as on the C64.
    case authentic
    /// The simulation keeps the authentic cadence, but every display frame the window is drawn
    /// again with the camera interpolated between the last two completed iterations (the native
    /// engine's `SmoothRenderer`). The panel always shows the real state.
    case smooth
}

/// Settings an engine honors from the next frame on. The lab engine runs the original as it is
/// and ignores them.
public struct EngineOptions: Sendable, Equatable {
    public var pacing: Pacing
    /// Reproduce the original's suspension of the keyboard scan while a joystick is deflected
    /// ($2574 aborts the scan and the release check). Off: the native engine time-shares the CIA
    /// lines so keys pressed and released while a stick is held still get through.
    public var strictJoystick: Bool

    public init(pacing: Pacing = .authentic, strictJoystick: Bool = false) {
        self.pacing = pacing
        self.strictJoystick = strictJoystick
    }
}

/// What the Mac app drives: the native port (and, for development only, the lab running the
/// original code). All methods are called on the engine's own thread.
public protocol GameEngine: AnyObject {
    /// Virtual C64 cycles since power-on.
    var cycles: UInt64 { get }
    /// Runs until the virtual clock reaches `cycle`, calling `onFrame` at every frame end.
    func run(untilCycle cycle: UInt64)
    /// Inputs. Input set before a frame ends is applied when that frame ends, before `onFrame` is
    /// called; input set from inside `onFrame` or between `run` calls applies from the end of the
    /// next frame. Every engine must follow this so headless runs match the lab exactly.
    var input: InputState { get set }
    /// Receives each completed frame.
    var onFrame: ((FrameOutput) -> Void)? { get set }
    /// Pacing and joystick behavior, applied from the next frame end.
    var options: EngineOptions { get set }
}
