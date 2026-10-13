import C64Kit
import FS2Core
import FS2Data
import FS2LabKit
import Foundation

/// Access to the original program for differential tests: the user's disk image, lab snapshots
/// of the running game (cached under build/testdata), and calls into original routines.
enum Original {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The disk image: $FS2_D64, else the app's import
    /// (~/Library/Application Support/FS2/FlightSimulatorII.d64).
    static let data: GameData? = {
        var candidates: [URL] = []
        if let p = ProcessInfo.processInfo.environment["FS2_D64"] { candidates.append(URL(fileURLWithPath: p)) }
        candidates.append(GameData.importedDiskURL)
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let d = try? GameData(d64URL: url) { return d }
        }
        return nil
    }()

    static var available: Bool { data != nil }

    /// Whether the image is a modified copy that carries the patches the import scrubs. The checks
    /// that read what to look for from those bytes run only then: a clean image of the original
    /// disk has nothing to scrub and nothing to look for.
    static let isModifiedCopy: Bool = data.map {
        ColdImage.crackPresent(in: CrackExclusionTests.unscrubbedMemory($0.disk))
    } ?? false

    /// The game in demo mode a minute into its self-flying takeoff (re/sessions/demo.txt).
    static func demoFlight() throws -> [UInt8] {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("re/sessions/demo.txt"), encoding: .utf8)
        return try snapshot("demo", session: text)
    }

    /// RAM of the running game after a session (cached by session name).
    static func snapshot(_ name: String, session: String) throws -> [UInt8] {
        let dir = repoRoot.appendingPathComponent("build/testdata", isDirectory: true)
        let url = dir.appendingPathComponent("\(name).snap")
        if let s = try? Snapshot.read(from: url) { return s.ram }
        guard let data else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = Lab.boot(data)
        try m.play(try Session.parse(session), screenshots: dir)
        let snap = Snapshot(machine: m)
        try snap.write(to: url)
        return snap.ram
    }

    /// The game sitting at Meigs in regular flight (re/sessions/regular.txt).
    static func regularFlight() throws -> [UInt8] {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("re/sessions/regular.txt"), encoding: .utf8)
        return try snapshot("regular", session: text)
    }

    /// Runs an original routine on `ram` and returns the resulting RAM, registers and cycles.
    static func call(_ address: UInt16, ram: [UInt8], _ regs: RoutineHarness.Registers = .init(),
                     maxCycles: UInt64 = 5_000_000) -> (ram: [UInt8], result: RoutineHarness.Result) {
        let h = RoutineHarness(ram: ram)
        let r = h.call(address, regs, maxCycles: maxCycles)
        return (h.bus.ram, r)
    }

    /// A full lab machine booted into regular flight (re/sessions/regular.txt), for routines that
    /// do I/O or disk loads. Each call to `callFull` can substitute the RAM image.
    static func machineHarness() throws -> MachineHarness {
        guard let data else { throw CocoaError(.fileNoSuchFile) }
        let m = Lab.boot(data)
        let text = try String(contentsOf: repoRoot.appendingPathComponent("re/sessions/regular.txt"), encoding: .utf8)
        try m.play(try Session.parse(text), screenshots: nil)
        return MachineHarness(machine: m)
    }

    /// The disk's logical blocks, for `Machine.diskBlocks`.
    static var diskBlocks: [[UInt8]] { data?.disk.blocks ?? [] }

    /// The development bridge (`Machine.callOriginal`): the original routine runs in the lab
    /// harness on a copy of the port's memory, the result is copied back, and its cycles are
    /// charged. Writes to $D000-$DFFF land in RAM there (no I/O). Shipping code never calls it
    /// (`ShippingCodeTests`); a test installs it only to run an original routine on the port's
    /// side itself (`Render3DFrameTests`) or to prove that nothing reaches it (the replay matrix).
    static func installBridge(on machine: Machine) {
        machine.originalBridge = { m, address, regs in
            let h = RoutineHarness(ram: m.memoryImage)
            var r = RoutineHarness.Registers(a: regs.a, x: regs.x, y: regs.y, carry: regs.carry)
            r.zero = regs.zero; r.negative = regs.negative; r.overflow = regs.overflow
            let result = h.call(address, r)
            precondition(result.completed, String(format: "bridged routine $%04X did not return", address))
            // Keep the port's stack page; everything else comes back from the original.
            let stack = Array(UnsafeBufferPointer(start: m.mem + 0x100, count: 0x100))
            m.load(memory: h.bus.ram)
            for i in 0..<0x100 { m.mem[0x100 + i] = stack[i] }
            m.charge(Int(result.cycles))
            let o = result.registers
            return CPURegisters(a: o.a, x: o.x, y: o.y, carry: o.carry, zero: o.zero,
                                negative: o.negative, overflow: o.overflow)
        }
    }

    /// Addresses whose bytes differ between two images, ignoring the stack page.
    static func differences(_ a: [UInt8], _ b: [UInt8], ignoring: [ClosedRange<Int>] = [0x0100...0x01FF]) -> [Int] {
        (0..<0x10000).filter { i in a[i] != b[i] && !ignoring.contains { $0.contains(i) } }
    }
}

/// Deterministic pseudo-random numbers for test vectors (xorshift64*).
struct TestRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next() >> 32) }
}
