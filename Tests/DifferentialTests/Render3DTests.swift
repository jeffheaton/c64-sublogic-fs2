import Foundation
import Synchronization
import FS2Core
import FS2LabKit
import M6502
import Testing

/// Shared fixtures of the 3D renderer differential tests (`Render3D*Tests`): realistic RAM images
/// of the running game, the development bridge, and helpers to put the original into a given
/// state (stop at an address, read the result of a routine).
enum R3D {
    /// The regular-flight RAM at Meigs (`re/sessions/regular.txt`), with the row filler and the
    /// horizon split row restored to their resting code bytes (a snapshot can land while a return
    /// opcode is planted in $851B or while the attitude indicator has $85C0 patched).
    static func regular() throws -> [UInt8] {
        sanitized(try Original.regularFlight())
    }

    /// Demo flight (mode 2: the self-flying takeoff from Meigs), `frames` after the demo starts:
    /// climbing, turning and banking states.
    static func demo(_ frames: Int) throws -> [UInt8] {
        let base = try String(contentsOf: Original.repoRoot.appendingPathComponent("re/sessions/demo.txt"),
                              encoding: .utf8)
        // The base session already waits 3600 frames.
        let extra = frames > 3600 ? " wait:\(frames - 3600)" : ""
        return sanitized(try Original.snapshot("demo\(frames)", session: base + extra))
    }

    /// The fixtures used by most suites: regular flight and three demo states.
    static func states() throws -> [(String, [UInt8])] { try cachedStates.get() }

    /// Built once per test process (the suites run in parallel; the lab snapshots behind them
    /// are cached on disk under build/testdata).
    private static let cachedStates = Result<[(String, [UInt8])], any Error> {
        [("regular", try regular()), ("demo3600", try demo(3600)), ("demo5400", try demo(5400)),
         ("demo7200", try demo(7200))]
    }

    static func sanitized(_ ram: [UInt8]) -> [UInt8] {
        var r = ram
        let cold = Original.data!.coldMemory
        for a in 0x851B...0x85C2 { r[a] = cold[a] }
        return r
    }

    /// The window rows flipped to the other bitmap, as the main loop does ($208B).
    static func flipped(_ ram: [UInt8]) -> [UInt8] {
        var r = ram
        for row in 0..<112 {
            let hi = r[0x0200 + row]
            r[0x0200 + row] = hi &+ (hi >= 0x60 ? 0xE0 : 0x20)
        }
        return r
    }

    /// RAM of the original just before it executes `stop`, when `address` is called on `ram`
    /// (a return opcode is planted at `stop` for the run and the code byte restored afterward).
    /// `stop` must be reached at the routine's own stack level.
    static func runUntil(_ address: UInt16, stop: Int, ram: [UInt8],
                         _ regs: RoutineHarness.Registers = .init()) -> [UInt8] {
        var r = ram
        let saved = r[stop]
        r[stop] = 0x60
        let o = Original.call(address, ram: r, regs)
        precondition(o.result.completed)
        var out = o.ram
        out[stop] = saved
        return out
    }

    /// A rig with the development bridge installed on the port's machine, so a test can run an
    /// original routine on both sides (`Render3DFrameTests` runs the start of the horizon pass
    /// that way), and, with `R3D_COVERAGE` set, the coverage recorder on the original's CPU.
    static func rig(_ ram: [UInt8]) -> DiffRig {
        let rig = DiffRig(ram)
        Original.installBridge(on: rig.machine)
        R3DCoverage.install(on: rig)
        return rig
    }

    /// Whether the original routine at `address` returns within `maxCycles` from the rig's
    /// current RAM (run on a copy). Degenerate inputs can send the original into a loop (the
    /// port would follow it), so such cases are skipped instead of compared.
    static func returns(_ rig: DiffRig, _ address: UInt16, _ regs: RoutineHarness.Registers = .init(),
                        maxCycles: UInt64 = 4_000_000) -> Bool {
        RoutineHarness(ram: rig.harness.bus.ram).call(address, regs, maxCycles: maxCycles).completed
    }

    /// How an original routine ends (see `ending`).
    enum Ending: Equatable {
        /// It returns normally.
        case returns
        /// It loops past the cycle budget or stops on an undocumented opcode (the lab CPU halts there).
        case loops
        /// It executes the split row's code $85C0-$86A3 (the split row and the Bresenham), which
        /// the polygon fill and the spans never call: a long span with its left end right of
        /// x = 163 (garbage crossings of an overflowed polygon) enters the row filler past its
        /// end and runs that code from the middle (even an entry on a byte that reads as a return
        /// opcode, the immediate operand at $85D9, returns with the Y the span set at $994A, which
        /// the raster port's long span does not pass to its filler model).
        case runsSplitRowCode
        /// It executes an instruction whose bytes were overwritten during the call, other than
        /// the code's own self-modification (`selfModifiedCode`): spans through a row pointer
        /// scrambled by the degenerate sort (render3d.md) wrote into code that then runs, such as
        /// the row filler.
        case runsOverwrittenCode
        /// It executes code outside the polygon routines' call tree (`polygonCallTree`) other
        /// than the split row's: a wild jump (a return address overwritten on the stack page).
        case runsOtherCode
    }

    /// The split row's code and the Bresenham that follows it.
    static let splitRowCode = 0x85C0...0x86A3

    /// Everything `clipPolygon` ($8FE8) and the spans run: the math library, the row filler, the
    /// point halving $8B2A, the clipper, fill and raster primitives, the pens, span color and
    /// projection divide, and `project`.
    static let polygonCallTree: [ClosedRange<Int>] = [0x16AA...0x1A0A, 0x851B...0x85BF, 0x8B2A...0x8B3F,
                                                      0x8FE8...0x9BD5, 0x9BE6...0x9E91, 0x9F94...0x9FCF]
    private static let inCallTree: [Bool] = {
        var mask = [Bool](repeating: false, count: 0x10000)
        for range in polygonCallTree { for a in range { mask[a] = true } }
        return mask
    }()

    /// Code bytes the polygon routines and the spans rewrite by design before running them: the
    /// crossing slot operand $98AD, the span pixel ops patched by $9C9C (two 3-byte ops each at
    /// $992A, $9986 and $99BC), the long span's call target $996B/$996C and the projection's
    /// table operand $9E89/$9E8A. (The return the long span plants on a filler store is checked
    /// separately: it may run only where `$F5` says it was planted, and it is restored.)
    static let selfModifiedCode: [Bool] = {
        var sites = [Bool](repeating: false, count: 0x10000)
        for a in [0x98AD, 0x996B, 0x996C, 0x9E89, 0x9E8A] { sites[a] = true }
        for op in [0x992A, 0x9986, 0x99BC] { for a in op..<(op + 6) { sites[a] = true } }
        return sites
    }()

    /// How the original routine at `address` (`clipPolygon`, the spans or a routine they call)
    /// ends when run on `ram` (a copy). The run stops at the first instruction outside the call
    /// tree or of overwritten code. `observer` is called before each instruction at one of the
    /// `observing` addresses with the harness, the address and the cycles since the call.
    ///
    /// A first run traps only what lies outside the call tree (never executed normally). If code
    /// in the call tree has changed by its end (or it did not return), a second run checks every
    /// instruction's bytes against `ram`; `restart` is called before it, so an observer can start
    /// over.
    static func ending(_ ram: [UInt8], _ address: UInt16, _ regs: RoutineHarness.Registers = .init(),
                       maxCycles: UInt64 = 4_000_000, observing: [Int] = [],
                       observer: ((RoutineHarness, Int, UInt64) -> Void)? = nil,
                       restart: (() -> Void)? = nil) -> Ending {
        let first = run(ram, address, regs, maxCycles, observing, observer, checkEveryInstruction: false)
        if first.ending != .loops && !callTreeChanged(first.ram, from: ram) { return first.ending }
        restart?()
        return run(ram, address, regs, maxCycles, observing, observer, checkEveryInstruction: true).ending
    }

    /// Whether a byte of the call tree's code differs, other than at the self-modification sites
    /// and the long span's planted return (still there when the run stopped inside the span).
    private static func callTreeChanged(_ now: [UInt8], from start: [UInt8]) -> Bool {
        let stop = 0x851D + Int(now[0xF5])
        return polygonCallTree.contains { range in
            range.contains { now[$0] != start[$0] && !selfModifiedCode[$0] && !($0 == stop && now[$0] == 0x60) }
        }
    }

    private static func run(_ ram: [UInt8], _ address: UInt16, _ regs: RoutineHarness.Registers,
                            _ maxCycles: UInt64, _ observing: [Int],
                            _ observer: ((RoutineHarness, Int, UInt64) -> Void)?,
                            checkEveryInstruction check: Bool) -> (ending: Ending, ram: [UInt8]) {
        let h = RoutineHarness(ram: ram)
        var observed = noTraps
        for a in observing { observed[a] = true }
        var traps = check ? allTraps : outsideCallTree
        for a in observing { traps[a] = true }
        h.cpu.traps = traps
        let tree = inCallTree, sites = selfModifiedCode, lengths = lengths
        var ending = Ending.returns
        var start: UInt64 = 0
        h.cpu.trapHandler = { pc in
            let p = Int(pc)
            if !tree[p] {
                ending = splitRowCode.contains(p) ? .runsSplitRowCode : .runsOtherCode
            } else if check {
                // The instruction's bytes as they were at the call (the opcode gives the length).
                let length = lengths[Int(h.bus.ram[p])]
                for a in p..<(p + length) where h.bus.ram[a] != ram[a] && !sites[a] {
                    // The long span's planted return, on the store it was planted on.
                    if a == p && a == 0x851D + Int(h.bus.ram[0xF5]) && h.bus.ram[a] == 0x60 { continue }
                    ending = .runsOverwrittenCode
                }
            }
            if ending != .returns {
                h.cpu.pc = 0xFFF0                    // the harness's return sentinel: stop the run
                return true
            }
            if observed[p] { observer?(h, p, h.cpu.cycles - start) }
            return false
        }
        start = h.cpu.cycles
        let r = h.call(address, regs, maxCycles: maxCycles)
        if ending == .returns && !r.completed { ending = .loops }
        return (ending, h.bus.ram)
    }

    /// Instruction lengths by opcode (1 for the undocumented ones, on which the lab CPU stops).
    private static let lengths: [Int] = Opcodes.table.map { $0.documented ? $0.length : 1 }
    private static let noTraps = [Bool](repeating: false, count: 0x10000)
    private static let allTraps = [Bool](repeating: true, count: 0x10000)
    private static let outsideCallTree = inCallTree.map { !$0 }

    /// Loads `ram` into both sides of `rig` (resynchronizes them).
    static func load(_ rig: DiffRig, _ ram: [UInt8]) {
        rig.harness.bus.ram = ram
        rig.machine.load(memory: ram)
    }
}

/// Development aid: with `R3D_COVERAGE` set in the environment, every rig records the addresses
/// in the renderer's ranges where the original executed an instruction, and the pairs of
/// consecutive ones. Each rig's `expectClean` (through `R3DCoverage.flush`) writes the union so
/// far to `build/testdata/r3d-coverage.txt` (one hex address per line, for comparing with the
/// listing) and `build/testdata/r3d-branches.txt`: every executed conditional branch with an
/// outcome no test produced ("never taken" / "never falls through"). Outcomes the code before a
/// branch fixes (a branch right after a constant load, ...) are listed there too; anything else
/// is an untested path.
enum R3DCoverage {
    static let enabled = ProcessInfo.processInfo.environment["R3D_COVERAGE"] != nil
    static let ranges: [ClosedRange<Int>] = [0x8111...0x86A3, 0x8FE8...0x990F, 0x9D05...0x9E91,
                                             0x9F94...0xA5A6, 0xED3C...0xEE13]
    private static let hits = Mutex(Set<Int>())
    /// `from << 16 | to` for consecutive instructions in the ranges (a call out of the ranges
    /// shows as an edge from the call to the instruction after it).
    private static let edges = Mutex(Set<Int>())

    /// The previous instruction of one rig's CPU (each rig runs on one thread at a time).
    private final class Previous: @unchecked Sendable { var pc = -1 }

    static func install(on rig: DiffRig) {
        guard enabled else { return }
        let cpu = rig.harness.cpu
        for range in ranges { for a in range { cpu.traps[a] = true } }
        let previous = Previous()
        cpu.trapHandler = { pc in
            let p = Int(pc)
            hits.withLock { _ = $0.insert(p) }
            if previous.pc >= 0 { edges.withLock { _ = $0.insert(previous.pc << 16 | p) } }
            previous.pc = p
            return false
        }
    }

    static func flush() {
        guard enabled else { return }
        let executed = hits.withLock { $0 }
        let text = executed.sorted().map { String(format: "%04X", $0) }.joined(separator: "\n")
        let dir = Original.repoRoot.appendingPathComponent("build/testdata")
        try? text.write(to: dir.appendingPathComponent("r3d-coverage.txt"), atomically: true, encoding: .utf8)
        // Both outcomes of every executed conditional branch (on any of the four flags).
        let code = Original.data!.coldMemory
        let pairs = edges.withLock { $0 }
        var report: [String] = []
        for pc in executed.sorted() where code[pc] & 0x1F == 0x10 {
            let next = pc + 2, target = next + Int(Int8(bitPattern: code[pc + 1]))
            if !pairs.contains(pc << 16 | target) { report.append(String(format: "%04X never taken", pc)) }
            if !pairs.contains(pc << 16 | next) { report.append(String(format: "%04X never falls through", pc)) }
        }
        try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("r3d-branches.txt"),
                                                  atomically: true, encoding: .utf8)
    }
}

extension DiffRig {
    /// `expectClean`, then the coverage flush (see `R3DCoverage`).
    func expectCleanR3D(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        expectClean(what, sourceLocation: sourceLocation)
        R3DCoverage.flush()
    }
}

extension TestRandom {
    mutating func r3dWord() -> UInt16 { UInt16(truncatingIfNeeded: next() >> 20) }
    mutating func r3dBelow(_ n: Int) -> Int { Int(next() >> 33) % n }
    mutating func r3dSigned(_ magnitude: Int) -> Int16 { Int16(r3dBelow(2 * magnitude + 1) - magnitude) }
}

/// Smoke test of the fixtures themselves.
@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct Render3DTests {
    @Test func fixturesLoad() throws {
        for (name, ram) in try R3D.states() {
            #expect(ram.count == 0x10000, "\(name)")
            // The resting code bytes of the split row and the filler.
            #expect(ram[0x85C0] == 0xA4 && ram[0x85BF] == 0x60, "\(name)")
        }
    }
}
