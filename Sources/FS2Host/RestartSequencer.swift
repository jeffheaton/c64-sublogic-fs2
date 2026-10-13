import C64Kit
import FS2Core

/// Machine ▸ Restart: presses RUN/STOP + RESTORE the way a player would, frame by frame.
///
/// The original's NMI handler ($2700) restarts only when RUN/STOP is held as the *first* key, i.e.
/// it sits in held-key slot 3 (`$089E == $3F`). The matrix is scanned every 4 frames, so the
/// sequence first releases everything (freeing the slots), then holds RUN/STOP long enough to be
/// scanned, raises RESTORE on the last held frame and hands control back right after, so the
/// re-initialized program does not see RUN/STOP as a new key press.
public struct RestartSequencer: Sendable {
    /// Frames with every key released.
    public static let releaseFrames = 8
    /// Frames RUN/STOP is held; RESTORE goes with the last of them.
    public static let holdFrames = 12
    public static var totalFrames: Int { releaseFrames + holdFrames }

    /// Frames into the sequence; nil when idle.
    private(set) var position: Int?

    public var isActive: Bool { position != nil }

    public mutating func start() { position = 0 }

    /// The input for the next frame: `user` when idle, the scripted input while restarting.
    /// Call once per completed frame.
    public mutating func next(user: InputState) -> InputState {
        guard let p = position else { return user }
        var input = InputState()
        if p >= Self.releaseFrames { input.keys.set(.runStop, pressed: true) }
        if p == Self.totalFrames - 1 { input.restore = true }
        position = p + 1 < Self.totalFrames ? p + 1 : nil
        return input
    }
}
