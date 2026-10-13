import C64Kit

/// Smooth pacing: the out-the-window view drawn again for every display frame, with the camera
/// interpolated between the last two completed main-loop iterations, while the simulation keeps
/// the original's cadence.
///
/// What the original shows: pass k starts at $204B (time s_k), integrates the flight (the camera
/// c_k: the eye position `$5A-$65`, three 32-bit words in 1/256 m, and the attitude `$6C-$71`,
/// pitch, bank and heading as 16-bit binary angles), builds the view matrix, flips (from then on
/// the window shows what pass k-1 drew, with c_(k-1)) and draws pass k's picture into the other
/// bitmap. So the window changes once per pass, a pass after its camera.
///
/// - **Iterations** (program thread, at every $204B): `recordIteration` keeps the whole memory and
///   the camera of the last two tops of the loop: M_k (at s_k, holding c_(k-1)) and M_(k+1) (at
///   s_(k+1), holding c_k).
/// - **Frames** (host thread, at a frame end at cycle t ≥ s_(k+1), while the program is parked):
///   f = (t − s_(k+1)) / (s_(k+1) − s_k), clamped to 0...1, and the camera c_(k-1) + f·(c_k −
///   c_(k-1)) (each position word along its signed 32-bit difference, each angle the shorter way
///   round). A scratch `Machine` gets M_k, the start of the pass that drew with c_k, with that
///   camera and `$0E6B` = 0, no event, poll or I/O hooks, and runs the window part of a pass:
///   `plotterDisplay` ($F6E2), `setSceneryRoot` ($E565), `buildViewMatrix` ($8000), the flip's
///   move of the window rows to the other bitmap (whose old picture the points and lights are
///   drawn over), `horizonPass` ($8003), `runScenery` ($8006), `updateCompass` ($3823: the
///   magnetic compass is drawn in the window, at (106, 114)), the war overlay's slot $A7EE when it
///   is resident, `drawViewOverlay` ($ED3C). At f = 1 that is exactly pass k's picture (the state
///   its drawing started from and the bitmap it drew over); a still camera gives the authentic
///   window on every frame. The polls find no tick due, a block the interpreter streams lands in the scratch
///   memory only, and nothing reaches the real machine: the simulation is the authentic one.
/// - **Composition**: the 112 window rows of the bitmap the scratch drew (14 character rows,
///   $1180 bytes) replace those of the bitmap the real window shows, in a copy of the real memory;
///   the split is presented from that copy, so the panel, the sprites and the borders are the real
///   state.
///
/// The window is the real one (Authentic) whenever the interpolation would show something the
/// original does not, or nothing new:
/// - before two iterations under the same overlay are recorded, and when the flight or war overlay
///   is not resident (the title and prompts, the editor, the database screen);
/// - from s_(k+1) until pass k+1 flips (the row table `$0200` still as at $204B): the window shows
///   pass k-1's picture with c_(k-1), which is the interpolation at f = 0;
/// - while the program draws into the bitmap on display (the alternate-pass tasks: the ATIS
///   teletype, the crash message, the course plotter menu, the database info screen draw there
///   before the flip operand `$22B0` changes).
/// A frame without the split (text mode) forgets the recorded iterations.
public final class SmoothRenderer: @unchecked Sendable {
    /// One recorded iteration: the clock at its $204B, the camera bytes, the overlay resident
    /// (the end word at $A7E0).
    struct Iteration: Equatable {
        var cycle: UInt64
        var camera: [UInt8]
        var overlay: UInt16
    }

    /// The camera bytes: the position $5A-$65, then the attitude $6C-$71.
    static let positionBase = 0x5A, positionWords = 3
    static let attitudeBase = 0x6C, attitudeWords = 3
    static let cameraSize = 4 * positionWords + 2 * attitudeWords
    /// Overlay end words at $A7E0 under which the window shows flight: the flight overlay and the
    /// war overlay.
    static let flightOverlays: Set<UInt16> = [0xA800, 0xB1EA]
    /// The window's share of a bitmap: rows 0-111, 14 character rows of 320 bytes.
    static let windowBytes = 14 * 320

    private(set) var latest: Iteration?
    private(set) var previous: Iteration?
    private var latestMemory = [UInt8](repeating: 0, count: Machine.memorySize)
    private var previousMemory = [UInt8](repeating: 0, count: Machine.memorySize)
    private let scratch = Machine(memory: [UInt8](repeating: 0, count: Machine.memorySize))
    /// The memory the composed frame is presented from.
    private(set) var composite = [UInt8](repeating: 0, count: Machine.memorySize)

    // MARK: Program thread

    /// $204B: records the iteration that just completed.
    func recordIteration(_ m: Machine) {
        previous = latest
        swap(&previousMemory, &latestMemory)
        latest = Iteration(cycle: m.clock.cycles, camera: Self.camera(of: m.mem), overlay: m.u16(0xA7E0))
        latestMemory.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: m.mem, count: Machine.memorySize) }
    }

    // MARK: Host thread

    /// Forgets the recorded iterations (the next two start afresh).
    func invalidate() {
        latest = nil
        previous = nil
    }

    /// Composes the frame for the real machine `m` at cycle `t` with the split `view`/`panel`
    /// into `composite`, or returns false when the real window must be shown instead.
    func compose(real m: Machine, at t: UInt64) -> Bool {
        guard let latest, let previous, latest.overlay == previous.overlay,
              Self.flightOverlays.contains(latest.overlay), m.u16(0xA7E0) == latest.overlay,
              m.mem[Machine.rowAddressHi] != latestMemory[Machine.rowAddressHi],
              Self.drawBitmap(m.mem) != Self.flipBitmap(m.mem) else { return false }
        let span = Double(max(1, latest.cycle &- previous.cycle))
        let f = t > latest.cycle ? min(1, Double(t - latest.cycle) / span) : 0
        guard let drawn = renderWindow(camera: Self.interpolate(previous.camera, latest.camera, f), real: m) else {
            return false
        }
        let shown = Self.bitmapBase(memPtr: m.io.viewRegion.memPtr)
        composite.withUnsafeMutableBufferPointer { c in
            c.baseAddress!.update(from: m.mem, count: Machine.memorySize)
            (c.baseAddress! + shown).update(from: scratch.mem + drawn, count: Self.windowBytes)
        }
        return true
    }

    /// Runs the window part of a pass on the scratch machine from the previous top of the loop
    /// with `camera`. Returns the base of the bitmap it drew into, nil when its display list
    /// faulted.
    func renderWindow(camera: [UInt8], real m: Machine) -> Int? {
        let s = scratch
        s.load(memory: previousMemory)
        Self.setCamera(camera, in: s.mem)
        s.mem[MainLoop.RAM.frameDivider] = 0
        // The pass's flip moves the window rows to the other bitmap (unless `$0E79` bit 0 skips
        // it): the drawing must start from that bitmap's content, as the real pass's did (the
        // horizon pass repaints the sky and ground, but points and lights drawn over the old
        // picture depend on it).
        if s.mem[MainLoop.RAM.skipFlip] & 1 == 0 {
            let delta = s.mem[MainLoop.RAM.drawBufferDelta]
            for row in 0..<0x70 { s.mem[Machine.rowAddressHi + row] &+= delta }
        }
        s.io = m.io
        s.io.sidWrites = []
        s.diskBlocks = m.diskBlocks
        s.clock = m.clock
        s.interruptDisable = false
        s.eventHandler = nil
        s.nextEventCycle = .max
        s.pollHandler = nil
        s.ioReadHook = nil
        s.mainLoopHook = nil
        do {
            s.charge(6)
            s.plotterDisplay()
            s.charge(6)
            s.setSceneryRoot()
            s.charge(9)                                 // through the vector $8000
            s.buildViewMatrix()
            s.charge(9)                                 // through the vector $8003
            try s.horizonPass()
            s.charge(9)                                 // through the vector $8006
            try s.runScenery()
            s.charge(6)
            s.updateCompass()
            if s.mem[MainLoop.RAM.europe1917] != 0 && s.u16(0xA7E0) == 0xB1EA {
                s.charge(6)
                s.runOverlaySlot(0xA7EE)
            }
            s.charge(6)
            s.drawViewOverlay()
        } catch {
            return nil
        }
        return Self.drawBitmap(s.mem)
    }

    // MARK: Camera

    static func camera(of mem: UnsafeMutablePointer<UInt8>) -> [UInt8] {
        Array(UnsafeBufferPointer(start: mem + positionBase, count: 4 * positionWords))
            + Array(UnsafeBufferPointer(start: mem + attitudeBase, count: 2 * attitudeWords))
    }

    static func setCamera(_ camera: [UInt8], in mem: UnsafeMutablePointer<UInt8>) {
        for k in 0..<(4 * positionWords) { mem[positionBase + k] = camera[k] }
        for k in 0..<(2 * attitudeWords) { mem[attitudeBase + k] = camera[4 * positionWords + k] }
    }

    /// c₀ + f·(c₁ − c₀): the 32-bit position words along their signed difference, the 16-bit
    /// angles the shorter way round (both wrap as the 6502's arithmetic does).
    public static func interpolate(_ a: [UInt8], _ b: [UInt8], _ f: Double) -> [UInt8] {
        var out = a
        for w in 0..<positionWords {
            let o = 4 * w
            let pa = word32(a, o), pb = word32(b, o)
            let d = Double(Int32(bitPattern: pb &- pa))
            let p = pa &+ UInt32(bitPattern: Int32((d * f).rounded()))
            for k in 0..<4 { out[o + k] = UInt8(truncatingIfNeeded: p >> (8 * k)) }
        }
        for w in 0..<attitudeWords {
            let o = 4 * positionWords + 2 * w
            let aa = UInt16(a[o]) | UInt16(a[o + 1]) << 8, ab = UInt16(b[o]) | UInt16(b[o + 1]) << 8
            let d = Double(Int16(bitPattern: ab &- aa))
            let v = aa &+ UInt16(bitPattern: Int16((d * f).rounded()))
            out[o] = UInt8(truncatingIfNeeded: v)
            out[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
        }
        return out
    }

    private static func word32(_ bytes: [UInt8], _ o: Int) -> UInt32 {
        UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
    }

    // MARK: Bitmaps

    /// The bitmap the program draws into: the high byte of window row 0 (`$0200`), $40xx or $60xx.
    static func drawBitmap(_ mem: UnsafeMutablePointer<UInt8>) -> Int { Int(mem[Machine.rowAddressHi] & 0xE0) << 8 }

    /// The bitmap the window phase of the raster IRQ shows next: the flip operand `$22B0`.
    static func flipBitmap(_ mem: UnsafeMutablePointer<UInt8>) -> Int { bitmapBase(memPtr: mem[MainLoop.RAM.flipOperand]) }

    /// The bitmap a `$D018` value selects in VIC bank 1 ($4000 or $6000).
    static func bitmapBase(memPtr: UInt8) -> Int { 0x4000 + Int(memPtr & 0x08) << 10 }
}
