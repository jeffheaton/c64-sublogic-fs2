import C64Kit
import Foundation
import FS2Core
import FS2Data
@testable import FS2LabKit
import M6502

/// The replay matrix (`ReplayMatrixTests`): every session in `re/sessions/*.txt` that the lab can
/// record, recorded once (`ReplayLab`'s recorders, the recorder behind `fs2lab record`), cached
/// under `build/testdata/replay-matrix/`, and replayed through the native engine.
///
/// A session file becomes a matrix entry like this:
///
/// - The steps that only observe (`peek:`, `text`, `cov:`, `shot:`, `snap:`) are dropped.
/// - A session that starts with the Meigs prefix (`ReplaySessions.meigs`: boot, color display,
///   regular flight, the Chicago area and the Meigs detail block loaded) is recorded from the top
///   of the main loop after that prefix, as `ReplayLab.record` does.
/// - A `replay-*` session gets the prefix its own test gives it (`ReplayTests`,
///   `ReplayModesTests`, `ReplayRestartTests`, `ColdInitTests`).
/// - Any other session (another display or mode answer at the prompts, the demo) is recorded
///   from the stage-2 handoff, the boot and the prompts included, and replayed from the cold
///   start.
/// - A `poke:` inside the recorded part is applied at the next top of the main loop on both
///   sides: in the lab right after that checkpoint's memory is taken, in the port when the
///   engine stops at the same checkpoint (a log has no way to carry a write from outside).
/// - A session with `nmi` (RESTORE) goes through the attached recorder (`pressRestore`), which
///   ends the handler batch at the cold start $A7E2 when the restart leaves the NMI.
/// - After the session the lab runs on through the next top of the main loop (up to 3000
///   frames), so the session's last steps are checked at one more checkpoint (`runsOn`).
enum ReplayMatrix {
    /// One matrix entry.
    struct Entry: Sendable, Hashable, CustomStringConvertible {
        var name: String
        /// The lab session played before the recording starts at $204B; nil: the recording starts
        /// at the stage-2 handoff (the port then replays the cold start).
        var prefix: String?
        /// The recorded steps.
        var session: String
        /// After the session the lab runs on through the next top of the main loop (recorded
        /// too), so the session's last steps are checked at one more checkpoint.
        var runsOn: Bool
        var restartAware: Bool
        /// Long sessions run only with `FS2_REPLAY_LONG=1`.
        var long: Bool
        /// Why the session is not replayed (a documented deviation of the port).
        var excluded: String?

        var description: String { name }
    }

    static let sessionsDirectory = Original.repoRoot.appendingPathComponent("re/sessions", isDirectory: true)
    static let cacheDirectory = Original.repoRoot.appendingPathComponent("build/testdata/replay-matrix",
                                                                         isDirectory: true)

    /// `ReplaySessions.meigs` as tokens.
    static let meigsTokens = tokens(ReplaySessions.meigs)

    /// Sessions that are not replayed, and why.
    static let exclusions: [String: String] = [
        // `excluded.md`: the port treats the call to $FD00 as a no-op; the lab runs the chain of
        // software interrupts through the zeroed memory there.
        "war-hook": "the $FD00 hook is a documented no-op in the port (excluded.md)",
    ]

    /// Sessions too long for the default run (28 virtual minutes of the demo's flight).
    static let longSessions: Set<String> = ["demo-loop"]

    /// Sessions that end where the main loop cannot come back (library.txt: the format wipes the
    /// master disk the editor's exit would reload the flight overlay from; `replay-library`
    /// covers the library keys with a way back).
    static let endsAway: Set<String> = ["library"]

    static var runLong: Bool { ProcessInfo.processInfo.environment["FS2_REPLAY_LONG"] != nil }

    /// The matrix: every `re/sessions/*.txt`, sorted by name.
    static let entries: [Entry] = {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory.path) else { return [] }
        return files.filter { $0.hasSuffix(".txt") }.sorted().compactMap { file in
            let name = String(file.dropLast(4))
            guard let text = try? String(contentsOf: sessionsDirectory.appendingPathComponent(file), encoding: .utf8)
            else { return nil }
            return entry(name, text)
        }
    }()

    /// The session's tokens without comments and without the steps that only observe.
    static func tokens(_ text: String) -> [String] {
        text.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            .filter { t in !["peek:", "cov:", "shot:", "snap:"].contains { t.hasPrefix($0) } && t != "text" }
    }

    static func entry(_ name: String, _ text: String) -> Entry {
        let steps = tokens(text)
        let meigs = ReplaySessions.meigs
        var prefix: String?
        var recorded = steps
        if name.hasPrefix("replay-") {
            // The prefixes the replay tests give these sessions.
            switch name {
            case "replay-coldboot", "replay-coldboot-bw":
                prefix = nil
            case "replay-demo":
                prefix = "pc:2250:9000 key:A:12 pc:2250:600 key:A:12"
            case "replay-crossing":
                prefix = meigs + "\npoke:0966:01 poke:62:00 poke:63:40 poke:64:35 poke:65:02 wait:300 pc:204B:3000"
            case "replay-warexit":
                prefix = meigs + "\npc:204B:3000 poke:0E7C:07"
            case "replay-recrash":
                let crash = (try? String(contentsOf: sessionsDirectory.appendingPathComponent("replay-crash.txt"),
                                         encoding: .utf8)) ?? ""
                prefix = meigs + "\n" + tokens(crash).joined(separator: " ") + "\npc:204B:3000"
            case "replay-failures":
                prefix = meigs + "\npc:204B:3000 poke:0967:01 poke:09A4:00 poke:08CD:00"
            case "replay-dusk":
                prefix = meigs + "\npc:204B:3000 poke:0983:13 poke:0984:1D poke:091A:28"
            default:
                prefix = meigs
            }
        } else if steps.starts(with: meigsTokens) {
            prefix = meigs
            recorded = Array(steps.dropFirst(meigsTokens.count))
        }
        return Entry(name: name, prefix: prefix, session: recorded.joined(separator: " "),
                     runsOn: !endsAway.contains(name), restartAware: steps.contains("nmi"),
                     long: longSessions.contains(name), excluded: exclusions[name])
    }

    // MARK: Recordings

    /// The VIC state as stored in the cache.
    struct VIC: Codable, Equatable {
        var cr1, cr2, memPtr: UInt8
        var bank: UInt16
        var border: UInt8
        var background: [UInt8]
        var spriteEnable: UInt8
        var spriteX: [UInt16]
        var spriteY, spriteColor: [UInt8]
        var spriteMC0, spriteMC1, spriteMulticolor, spriteExpandX, spriteExpandY, spriteBehind: UInt8

        init(_ s: VICState) {
            cr1 = s.cr1; cr2 = s.cr2; memPtr = s.memPtr; bank = s.bank; border = s.border
            background = s.background; spriteEnable = s.spriteEnable; spriteX = s.spriteX; spriteY = s.spriteY
            spriteColor = s.spriteColor; spriteMC0 = s.spriteMC0; spriteMC1 = s.spriteMC1
            spriteMulticolor = s.spriteMulticolor; spriteExpandX = s.spriteExpandX
            spriteExpandY = s.spriteExpandY; spriteBehind = s.spriteBehind
        }

        var state: VICState {
            var s = VICState()
            s.cr1 = cr1; s.cr2 = cr2; s.memPtr = memPtr; s.bank = bank; s.border = border
            s.background = background; s.spriteEnable = spriteEnable; s.spriteX = spriteX; s.spriteY = spriteY
            s.spriteColor = spriteColor; s.spriteMC0 = spriteMC0; s.spriteMC1 = spriteMC1
            s.spriteMulticolor = spriteMulticolor; s.spriteExpandX = spriteExpandX
            s.spriteExpandY = spriteExpandY; s.spriteBehind = spriteBehind
            return s
        }
    }

    /// The I/O the port mirrors (`ReplayLab.IOState`), as stored in the cache.
    struct IO: Codable, Equatable {
        var vic: [UInt8]
        var sid: [UInt8]
        var colorRAM: [UInt8]
        var cia2PortA: UInt8
        var cia2DirectionA: UInt8
        var view: VIC?
        var panel: VIC?

        init(_ m: C64Machine, view: VICState?, panel: VICState?) {
            let s = ReplayLab.IOState(m, view: view, panel: panel)
            vic = s.vic; sid = s.sid; colorRAM = s.colorRAM
            cia2PortA = s.cia2PortA; cia2DirectionA = s.cia2DirectionA
            self.view = view.map(VIC.init)
            self.panel = panel.map(VIC.init)
        }
    }

    /// A poke deferred to a checkpoint.
    struct Poke: Codable, Equatable {
        var checkpoint: Int
        var address: Int
        var value: UInt8
    }

    /// A recorded session: the start state, the log, per checkpoint the lab's I/O and RAM image,
    /// the pokes applied at checkpoints, and what the recording cost.
    struct Recording: Codable {
        static let formatVersion = 2
        var name: String
        var key: String
        /// True: the recording starts at the stage-2 handoff.
        var coldStart: Bool
        var startRAM: [UInt8]
        var startIO: IO
        var startCycle: UInt64
        /// The last checkpoint's cycle.
        var endCycle: UInt64
        /// Where the session's own steps ended (`runsOn` follows).
        var sessionEndCycle: UInt64
        var log: ReplayLog
        var io: [IO]
        var pokes: [Poke]
        /// The checkpoint images, concatenated and LZFSE-compressed.
        var compressedImages: Data
        var recordSeconds: Double

        /// The lab's RAM at every checkpoint.
        func images() -> [[UInt8]] {
            guard let raw = try? (compressedImages as NSData).decompressed(using: .lzfse) as Data else { return [] }
            let n = raw.count / Machine.memorySize
            return (0..<n).map { k in Array(raw[(k * Machine.memorySize)..<((k + 1) * Machine.memorySize)]) }
        }

        /// The frames of the recording (start to the last checkpoint).
        var frames: UInt64 { (endCycle - startCycle) / VirtualClock.cyclesPerFrame }
        /// Frames of the session after its last checkpoint (not checked).
        var uncheckedFrames: UInt64 {
            sessionEndCycle > endCycle ? (sessionEndCycle - endCycle) / VirtualClock.cyclesPerFrame : 0
        }
    }

    /// FNV-1a over a byte sequence.
    static func fnv(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        return h
    }

    /// A fingerprint of the user's disk (the cache is only valid for the disk it was recorded from).
    static let diskFingerprint: UInt64 = Original.data.map { fnv($0.d64.bytes) } ?? 0

    /// The cache key of an entry: the format, the disk, the prefix, the session and the recorder.
    static func key(_ e: Entry) -> String {
        let text = "v\(Recording.formatVersion)|\(diskFingerprint)|\(e.prefix ?? "<cold start>")|\(e.session)|"
            + "\(e.runsOn)|\(e.restartAware)"
        return String(format: "%016llx", fnv(Array(text.utf8)))
    }

    static func cacheURL(_ e: Entry) -> URL {
        cacheDirectory.appendingPathComponent("\(e.name)-\(key(e)).plist")
    }

    /// The entry's recording: from the cache, else recorded in the lab (and cached, replacing the
    /// entry's recordings under other keys). The key does not cover the lab's own code: after a
    /// change to the lab, delete `build/testdata/replay-matrix` to record again.
    static func recording(_ e: Entry) throws -> Recording {
        let url = cacheURL(e)
        if let data = try? Data(contentsOf: url),
           let r = try? PropertyListDecoder().decode(Recording.self, from: data), r.key == key(e) {
            return r
        }
        let r = try record(e)
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        for stale in (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        where stale.hasPrefix("\(e.name)-") && stale.hasSuffix(".plist") && stale.dropFirst(e.name.count + 1).count == 22 {
            try? fm.removeItem(at: cacheDirectory.appendingPathComponent(stale))
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(r).write(to: url, options: .atomic)
        return r
    }

    enum RecordError: Error, CustomStringConvertible {
        case noDisk
        case prefixDidNotReachMainLoop(String)
        var description: String {
            switch self {
            case .noDisk: return "no disk image"
            case .prefixDidNotReachMainLoop(let n): return "\(n): the prefix did not reach $204B"
            }
        }
    }

    /// Records `e` in the lab (as `ReplayLab.record`, with the pokes deferred to checkpoints).
    static func record(_ e: Entry) throws -> Recording {
        guard let data = Original.data else { throw RecordError.noDisk }
        let started = Date()
        let m = Lab.boot(data)
        if let prefix = e.prefix {
            try m.play(try Session.parse(prefix), screenshots: nil)
            _ = m.run(maxCycles: 400_000_000) { $0.cpu.pc == 0x204B }
            guard m.cpu.pc == 0x204B else { throw RecordError.prefixDidNotReachMainLoop(e.name) }
        }
        var view: VICState?, panel: VICState?
        let startIO = IO(m, view: nil, panel: nil)
        let startRAM = m.bus.ram, startCycle = m.cpu.cycles
        let recorder = ReplayRecorder(machine: m)
        recorder.keepImages = true
        var io: [IO] = []
        var pending: [(Int, UInt8)] = []
        var pokes: [Poke] = []
        m.cpu.traps[0x22C0] = true
        m.cpu.traps[0x22A2] = true
        let previous = m.cpu.trapHandler
        m.cpu.trapHandler = { [unowned m] pc in
            if pc == 0x22C0 { view = m.bus.vicState() }
            if pc == 0x22A2 { panel = m.bus.vicState() }
            let before = recorder.log.checkpoints.count
            let handled = previous?(pc) ?? false
            if recorder.log.checkpoints.count > before {
                io.append(IO(m, view: view, panel: panel))
                // The deferred pokes land after the checkpoint's memory was taken.
                for (address, value) in pending {
                    m.bus.ram[address] = value
                    pokes.append(Poke(checkpoint: before, address: address, value: value))
                }
                pending.removeAll()
            }
            return handled
        }
        for step in try Session.parse(e.session).steps {
            switch step {
            case .nmi: recorder.pressRestore()
            case .poke(let address, let value): pending.append((address, value))
            default: try m.play(Session(steps: [step]), screenshots: nil)
            }
        }
        let sessionEnd = m.cpu.cycles
        if e.runsOn {
            // On to the next top of the main loop, and through it: the recorder takes the
            // checkpoint when $204B executes (a `pc:204B` step stops just before).
            let limit = m.frameCount + 3000
            m.run(maxCycles: .max) { $0.cpu.pc == 0x204B || $0.frameCount >= limit }
            if m.cpu.pc == 0x204B { m.step() }
        }
        var raw = Data(capacity: recorder.images.count * Machine.memorySize)
        for image in recorder.images { raw.append(contentsOf: image) }
        let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
        return Recording(name: e.name, key: key(e), coldStart: e.prefix == nil, startRAM: startRAM, startIO: startIO,
                         startCycle: startCycle, endCycle: recorder.log.checkpoints.last?.cycle ?? startCycle,
                         sessionEndCycle: sessionEnd,
                         log: recorder.log, io: io, pokes: pokes, compressedImages: compressed,
                         recordSeconds: Date().timeIntervalSince(started))
    }

    // MARK: Replaying

    /// What a replay through the native engine found.
    struct Report {
        var outcome: ReplayDriver.Outcome?
        var endReason: String?
        var problems: [String] = []
        var framesCompared = 0
        var runCalls = 0
        var seconds = 0.0
        /// The development bridge was reached (it must not be: everything is ported).
        var bridgeCalls: [UInt16] = []
        /// The port's clock at every checkpoint. The replay runs the same passes as the recording
        /// (same work, same interrupts), so the port's cycles per pass against the lab's measure
        /// the cost model (`charge`, with the VIC's DMA of `Machine.vicDMA`) alone.
        var portCycles: [UInt64] = []

        /// Port cycles over lab cycles from the first checkpoint to the last.
        func overallPacing(_ r: Recording) -> Double? {
            guard portCycles.count >= 2 else { return nil }
            let lab = r.log.checkpoints
            return Double(portCycles.last! - portCycles[0]) / Double(lab[portCycles.count - 1].cycle - lab[0].cycle)
        }

        /// Port cycles over lab cycles of every pass.
        func passPacing(_ r: Recording) -> [Double] {
            guard portCycles.count >= 2 else { return [] }
            let lab = r.log.checkpoints
            return (1..<portCycles.count).map {
                Double(portCycles[$0] - portCycles[$0 - 1]) / Double(max(1, lab[$0].cycle - lab[$0 - 1].cycle))
            }
        }
    }

    /// The port at the recording's start: the recording's RAM and I/O at $204B, or the stage-2
    /// handoff for a cold-start recording; the disk; the library disk as the lab's (the master
    /// disk's block 64); and a development bridge that only records that it was reached.
    static func portMachine(_ r: Recording, bridgeCalls: BridgeLog) -> Machine {
        let m: Machine
        if r.coldStart {
            m = Machine.booting(blocks: Original.diskBlocks)
        } else {
            m = Machine(memory: r.startRAM)
            m.diskBlocks = Original.diskBlocks
            m.io.vic = r.startIO.vic
            m.io.sid = r.startIO.sid
            m.io.colorRAM = r.startIO.colorRAM
            m.io.cia2PortA = r.startIO.cia2PortA
            m.io.cia2DataDirectionA = r.startIO.cia2DirectionA
            m.clock.cycles = r.startCycle
        }
        let blocks = Original.diskBlocks
        m.modeLibraryIO = ModeLibrary.InMemoryStore(block: blocks.count > 64 ? blocks[64] : nil).io
        Original.installBridge(on: m)
        let flat = m.originalBridge
        m.originalBridge = { m, address, regs in
            bridgeCalls.append(address)
            return flat!(m, address, regs)
        }
        return m
    }

    /// The addresses the development bridge was asked for.
    final class BridgeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [UInt16] = []
        func append(_ a: UInt16) { lock.lock(); calls.append(a); lock.unlock() }
        var all: [UInt16] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    /// The lab's frame at checkpoint `k`: its RAM and color RAM with the split its raster IRQ
    /// latched there, the window state through the badline $A3 (`NativeEngineReplayTests.labFrame`).
    static func labFrame(_ r: Recording, _ images: [[UInt8]], _ k: Int) -> [UInt8]? {
        guard k < r.io.count, k < images.count, let view = r.io[k].view?.state, let panel = r.io[k].panel?.state
        else { return nil }
        var out: [UInt8] = []
        images[k].withUnsafeBufferPointer { ram in
            VICPresenter.render(into: &out, ram: ram, colorRAM: r.io[k].colorRAM, charROM: nil) { raster in
                raster >= 0x20 && raster <= 0xA3 ? view : panel
            }
        }
        return out
    }

    /// The frames are compared at every checkpoint of a recording with up to 120 of them, else at
    /// every n-th (about 120 in all) and the last: rendering two frames per checkpoint dominates a
    /// debug run, and memory and the I/O state are checked at every checkpoint anyway.
    static func frameEvery(_ r: Recording) -> Int { max(1, (r.log.checkpoints.count + 119) / 120) }

    /// Replays `r` through a native engine (`NativeEngine(replaying:on:from:)`) in random slices
    /// of up to `maxSlice` cycles. At every checkpoint the driver compares the memory hash and the
    /// poll count; here the I/O the port mirrors (VIC and SID registers, color RAM, the VIC bank,
    /// the latched split states) is compared with the lab's, and the frame presented there, pixel
    /// for pixel (`frameEvery`); and the deferred pokes are applied.
    static func replay(_ r: Recording, seed: UInt64, maxSlice: UInt64 = 400_000) -> Report {
        let images = r.images()
        let bridge = BridgeLog()
        let machine = portMachine(r, bridgeCalls: bridge)
        let engine = NativeEngine(replaying: r.log, on: machine, from: r.coldStart ? .coldStart : .mainLoop)
        var report = Report()
        let pokes = Dictionary(grouping: r.pokes, by: \.checkpoint)
        let started = Date()
        engine.onCheckpoint = { [unowned engine] k, frame in
            let m = engine.machine
            defer { for p in pokes[k] ?? [] { m.mem[p.address] = p.value } }
            report.portCycles.append(m.clock.cycles)
            guard k < r.io.count, report.problems.count < 12 else { return }
            let lab = r.io[k]
            let vic = Array(m.io.vic[0..<0x2F])
            if vic != lab.vic {
                let regs = (0..<0x2F).filter { vic[$0] != lab.vic[$0] }
                report.problems.append("checkpoint \(k): VIC " + regs.prefix(6).map {
                    String(format: "$D0%02X=%02X want %02X", $0, vic[$0], lab.vic[$0]) }.joined(separator: " "))
            }
            if Array(m.io.sid[0..<0x19]) != lab.sid {
                let regs = (0..<0x19).filter { m.io.sid[$0] != lab.sid[$0] }
                report.problems.append("checkpoint \(k): SID " + regs.prefix(6).map {
                    String(format: "$D4%02X=%02X want %02X", $0, m.io.sid[$0], lab.sid[$0]) }.joined(separator: " "))
            }
            if m.io.colorRAM != lab.colorRAM { report.problems.append("checkpoint \(k): color RAM differs") }
            if (m.io.cia2PortA | ~m.io.cia2DataDirectionA) & 0x03 != (lab.cia2PortA | ~lab.cia2DirectionA) & 0x03 {
                report.problems.append("checkpoint \(k): the VIC bank differs")
            }
            if let view = lab.view?.state, view != m.io.viewRegion {
                report.problems.append("checkpoint \(k): window split state differs")
            }
            if let panel = lab.panel?.state, panel != m.io.panelRegion {
                report.problems.append("checkpoint \(k): panel split state differs")
            }
            let last = r.log.checkpoints.count - 1
            if k % frameEvery(r) == 0 || k == last, let expected = labFrame(r, images, k) {
                report.framesCompared += 1
                let differing = zip(frame.pixels, expected).filter { $0 != $1 }.count
                if differing != 0 { report.problems.append("checkpoint \(k): \(differing) pixels differ") }
                if k == last {
                    // The last checkpoint's frames, for the screenshot gallery (Scripts/gallery).
                    let dir = cacheDirectory.appendingPathComponent("frames", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for (side, pixels) in [("native", frame.pixels), ("lab", expected)] {
                        try? ImageWriter.writePNG(indices: pixels, width: VICPresenter.width, height: VICPresenter.height,
                                                  scaleX: 3, scaleY: 4,
                                                  to: dir.appendingPathComponent("\(r.name)-\(side).png"))
                    }
                }
            }
        }
        var rng = TestRandom(seed: seed)
        while engine.endReason == nil && report.runCalls < 4_000_000 {
            engine.run(untilCycle: engine.cycles + 1 + rng.next() % maxSlice)
            report.runCalls += 1
        }
        report.seconds = Date().timeIntervalSince(started)
        report.outcome = engine.replayOutcome
        report.endReason = engine.endReason
        report.bridgeCalls = bridge.all
        if let mm = engine.replayOutcome?.mismatch, mm.checkpoint < images.count {
            // The program stopped at the mismatching checkpoint: show where memory differs.
            let image = images[mm.checkpoint]
            let d = Original.differences(machine.memoryImage, image)
            report.problems.append("\(mm): \(d.count) bytes differ, first " + d.prefix(24).map {
                String(format: "$%04X=%02X want %02X", $0, machine.mem[$0], image[$0]) }.joined(separator: " "))
        }
        return report
    }
}
