import C64Kit
import FS2Core
import Foundation
#if Lab
import FS2LabKit
#endif

/// Optional engine features used by headless sessions (`poke:`, `pc:`, `snap:`, `peek:`,
/// `until:` and `text` steps) and by the app's quick boot. Both engines provide them; the native
/// port has no program counter, so its `pc:` supports the key wait $2250 and the top of the main
/// loop $204B only.
protocol EngineDebugging: AnyObject {
    /// Writes a byte of the 64 KB memory image.
    func poke(_ address: Int, _ value: UInt8)
    /// Reads a byte of the 64 KB memory image (between runs).
    func peek(_ address: Int) -> UInt8
    /// Runs until the program counter reaches `address` (or `maxFrames` frames pass), delivering
    /// frames as usual. Returns true when the address was reached. Throws when the engine cannot
    /// stop at `address`.
    @discardableResult
    func run(untilPC address: UInt16, maxFrames: Int) throws -> Bool
    /// Runs until the byte at `address` equals `value` (or, with `negate`, differs from it), or
    /// `maxFrames` frames pass, delivering frames as usual. Returns true when the byte matched.
    @discardableResult
    func run(untilByte address: Int, equals value: UInt8, negate: Bool, maxFrames: Int) -> Bool
    /// The 40 × 25 text screen the VIC shows (`C64Machine.textScreen`'s decoding).
    func textScreen() -> String
    /// Saves a RAM snapshot (the lab's `Snapshot` format).
    func writeSnapshot(to url: URL) throws
    /// Skips the boot's disk loading by running flat out until the title prompt, then delivers the
    /// frame on screen there.
    func skipDiskLoading()
}

/// $2250: SubLogic's wait-for-key routine, first reached at the title prompt.
let waitForKeyAddress: UInt16 = 0x2250
/// $204B: the top of the main loop (one pass after another).
let mainLoopTopAddress: UInt16 = 0x204B

#if Lab
extension LabEngine: EngineDebugging {
    func poke(_ address: Int, _ value: UInt8) {
        machine.bus.ram[address & 0xFFFF] = value
    }

    func peek(_ address: Int) -> UInt8 {
        machine.bus.ram[address & 0xFFFF]
    }

    @discardableResult
    func run(untilPC address: UInt16, maxFrames: Int) -> Bool {
        let limit = machine.frameCount + maxFrames
        return machine.run(maxCycles: .max) { m in m.cpu.pc == address || m.frameCount >= limit }
            && machine.cpu.pc == address
    }

    /// Exact, as `fs2lab run`'s `until:` (the byte is checked before every instruction).
    @discardableResult
    func run(untilByte address: Int, equals value: UInt8, negate: Bool, maxFrames: Int) -> Bool {
        let limit = machine.frameCount + maxFrames
        let a = address & 0xFFFF
        return machine.run(maxCycles: .max) { m in (m.bus.ram[a] == value) != negate || m.frameCount >= limit }
            && (machine.bus.ram[a] == value) != negate
    }

    func textScreen() -> String {
        machine.textScreen()
    }

    func writeSnapshot(to url: URL) throws {
        try Snapshot(machine: machine).write(to: url)
    }

    /// Runs to the title prompt without delivering the ~3,900 loading frames (rendering each one
    /// costs more than running it), then delivers the last complete frame once. The SID writes made
    /// meanwhile go out with that frame.
    func skipDiskLoading() {
        let deliver = machine.onFrame
        machine.onFrame = nil
        run(untilPC: waitForKeyAddress, maxFrames: 9000)
        machine.onFrame = deliver
        deliver?(machine)
    }
}
#endif

/// A `pc:` step the native engine cannot perform.
struct UnsupportedStop: Error, CustomStringConvertible {
    var address: UInt16
    var description: String {
        String(format: "the native engine has no program counter: pc:%04X is not supported "
                   + "(only pc:2250, the key wait, and pc:204B, the top of the main loop)", address)
    }
}

extension NativeEngine: EngineDebugging {
    func peek(_ address: Int) -> UInt8 {
        machine.mem[address & 0xFFFF]
    }

    /// `pc:2250` (the key wait): `runToKeyWait`, which stops at the first poll of a key wait that
    /// began after the last key it dispatched (the lab stops at the routine's entry, a few hundred
    /// cycles earlier). `pc:204B` (the top of the main loop): `runToMainLoopTop`, before the pass
    /// as in the lab. Any other address throws.
    @discardableResult
    func run(untilPC address: UInt16, maxFrames: Int) throws -> Bool {
        switch address {
        case waitForKeyAddress: return runToKeyWait(maxFrames: maxFrames)
        case mainLoopTopAddress: return runToMainLoopTop(maxFrames: maxFrames)
        default: throw UnsupportedStop(address: address)
        }
    }

    /// The byte is checked between runs of `untilByteSlice` cycles (the lab checks it at every
    /// instruction), so the stop comes up to a slice later.
    @discardableResult
    func run(untilByte address: Int, equals value: UInt8, negate: Bool, maxFrames: Int) -> Bool {
        let a = address & 0xFFFF
        let limit = machine.clock.cycles + UInt64(max(0, maxFrames)) * VirtualClock.cyclesPerFrame
        while (machine.mem[a] == value) == negate {
            let before = machine.clock.cycles
            guard before < limit, endReason == nil else { return false }
            run(untilCycle: min(limit, before + Self.untilByteSlice))
            if machine.clock.cycles == before { return false }
        }
        return true
    }

    /// The granularity of `until:` on the native engine: about 15 raster lines.
    static let untilByteSlice: UInt64 = 1000

    /// The text screen at the VIC bank (`$DD00`) and screen base (`$D018`) the port's I/O holds.
    func textScreen() -> String {
        let io = machine.io
        let base = Int(VICState.bank(fromDD00: io.cia2PortA | ~io.cia2DataDirectionA)) + (Int(io.vic[0x18] & 0xF0) << 6)
        return (0..<25).map { row in
            (0..<40).map { col in screenCodeText(machine.mem[(base + row * 40 + col) & 0xFFFF]) }.joined()
        }.joined(separator: "\n")
    }

    /// The memory image in the lab's `Snapshot` format; the port has no CPU, so the registers are
    /// zero and the PC is 0.
    func writeSnapshot(to url: URL) throws {
        let snapshot = NativeSnapshot(ram: machine.memoryImage, colorRAM: machine.io.colorRAM,
                                      a: 0, x: 0, y: 0, sp: 0, pc: 0, status: 0, cycles: machine.clock.cycles,
                                      frame: Int(machine.clock.frame))
        try PropertyListEncoder().encode(snapshot).write(to: url)
    }

    /// The fields of `Snapshot` (same keys, so `Snapshot.read` reads it).
    private struct NativeSnapshot: Codable {
        var ram: [UInt8]
        var colorRAM: [UInt8]
        var a: UInt8, x: UInt8, y: UInt8, sp: UInt8, pc: UInt16, status: UInt8
        var cycles: UInt64
        var frame: Int
    }
}
