/// The 10 Hz task poll $2330 (vector $2012), polled once per display-list opcode and from the
/// wait-for-key loop.
extension Machine {
    /// $0E6B: frames since the last 10 Hz tick (incremented per frame by the raster IRQ).
    public static let frameDivider = 0x0E6B
    /// $4B: the CPU port value the IRQ restores (`$01` is forced to $35 around the tick).
    public static let savedCpuPort = 0x4B

    /// $2330 (vector $2012): first gives the replay/scheduler hook its poll point
    /// (`pollHandler`), then the original's check: `$0E6B` − 6; when that is negative nothing is
    /// due (16 cycles). Otherwise `$0E6B` keeps the difference, `$01` = $35, the 10 Hz tick body
    /// $2348 (`tick10Hz`) runs, and `$01` = `$4B`. Only one tick runs per poll: a backlog is
    /// caught up over the following polls.
    public func pollTick() {
        poll()
        let m = mem
        let v = m[Self.frameDivider] &- 6
        guard v & 0x80 == 0 else {
            charge(16)                       // nothing due: the test, the return
            return
        }
        m[Self.frameDivider] = v
        m[0x01] = 0x35
        charge(26)               // due: the difference kept, I/O banked in, the call
        tick10Hz()
        m[0x01] = m[Self.savedCpuPort]
        charge(12)                                   // the CPU port restored, the return
    }
}
