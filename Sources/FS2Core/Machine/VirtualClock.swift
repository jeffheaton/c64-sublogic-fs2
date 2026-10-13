/// The virtual NTSC C64 clock the port runs on: 1,022,727 Hz, 65 cycles × 263 lines per frame.
/// Ported code charges cycles; the scheduler turns frame boundaries into the work the original's
/// raster IRQ did (jiffy count, sound pattern player, keyboard scan, display split).
public struct VirtualClock: Sendable {
    public static let hz = 1_022_727.14
    public static let cyclesPerLine: UInt64 = 65
    public static let linesPerFrame: UInt64 = 263
    public static let cyclesPerFrame: UInt64 = cyclesPerLine * linesPerFrame   // 17095
    public static let framesPerSecond = hz / Double(cyclesPerFrame)            // 59.826

    public var cycles: UInt64 = 0

    public init() {}

    public var frame: UInt64 { cycles / Self.cyclesPerFrame }
    public var rasterLine: Int { Int((cycles % Self.cyclesPerFrame) / Self.cyclesPerLine) }
    public var seconds: Double { Double(cycles) / Self.hz }
}
