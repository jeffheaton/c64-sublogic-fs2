import C64Kit
import Foundation
import FS2Core
import FS2Data
@testable import FS2LabKit
import M6502
import Testing

/// The replay rig: records a session in the lab (`ReplayRecorder`, the recorder behind
/// `fs2lab record`) from a quiet point at the top of the main loop, then replays its log in the
/// port (`ReplayDriver`) from the same start state, and checks every $204B checkpoint: the memory
/// hash (the driver), the I/O state the port keeps (VIC registers, SID registers, color RAM, the
/// latched split regions) and the golden frame presented with the game's split.
enum ReplayLab {
    /// The hardware state the port mirrors in `io`.
    struct IOState {
        var vic: [UInt8]
        var sid: [UInt8]
        var colorRAM: [UInt8]
        var cia2PortA: UInt8
        var cia2DirectionA: UInt8
        /// The VIC state latched by the last window-phase ($22C0) and panel-phase ($22A2) IRQ.
        var view: VICState?
        var panel: VICState?

        init(_ m: C64Machine, view: VICState?, panel: VICState?) {
            let bus = m.bus
            vic = Array(bus.vicRegs[0..<0x2F])
            sid = Array(bus.sidRegs[0..<0x19])
            colorRAM = bus.colorRAM
            cia2PortA = bus.cia2.pra
            cia2DirectionA = bus.cia2.ddra
            self.view = view
            self.panel = panel
        }
    }

    /// A recorded session: the start state (RAM and I/O at $204B, or the stage-2 handoff), the
    /// log, and per checkpoint the lab's RAM image and I/O state.
    struct Recording {
        var name: String
        var startRAM: [UInt8]
        var startIO: IOState
        var startCycle: UInt64
        var log: ReplayLog
        var images: [[UInt8]]
        var io: [IOState]
    }

    /// One lab machine per recording, recorded by the lab's `ReplayRecorder` as `fs2lab record`
    /// does: the session's `nmi` steps press RESTORE through it (taken at a poll point), and it
    /// follows a RUN/STOP + RESTORE restart.
    static func record(_ name: String, prefix: String?, session: String) throws -> Recording {
        guard let data = Original.data else { throw CocoaError(.fileNoSuchFile) }
        let m = Lab.boot(data)
        if let prefix {
            try m.play(try Session.parse(prefix), screenshots: nil)
            // Start at the top of the main loop, where the port's run starts.
            _ = m.run(maxCycles: 400_000_000) { $0.cpu.pc == 0x204B }
            precondition(m.cpu.pc == 0x204B, "\(name): the prefix did not reach $204B")
        }
        var view: VICState?, panel: VICState?
        let start = IOState(m, view: nil, panel: nil)
        let startRAM = m.bus.ram, startCycle = m.cpu.cycles
        let recorder = ReplayRecorder(machine: m)
        recorder.keepImages = true
        var io: [IOState] = []
        // Latch the split states as the IRQ sets them, and the I/O at every checkpoint.
        m.cpu.traps[0x22C0] = true
        m.cpu.traps[0x22A2] = true
        let previous = m.cpu.trapHandler
        m.cpu.trapHandler = { [unowned m] pc in
            if pc == 0x22C0 { view = m.bus.vicState() }
            if pc == 0x22A2 { panel = m.bus.vicState() }
            let before = recorder.log.checkpoints.count
            let handled = previous?(pc) ?? false
            if recorder.log.checkpoints.count > before { io.append(IOState(m, view: view, panel: panel)) }
            return handled
        }
        try m.play(try Session.parse(session), screenshots: nil)
        return Recording(name: name, startRAM: startRAM, startIO: start, startCycle: startCycle,
                         log: recorder.log, images: recorder.images, io: io)
    }

    /// The port at the recording's start: its RAM and I/O and the disk. No development bridge:
    /// every routine a replay reaches is ported.
    static func portMachine(_ r: Recording) -> Machine {
        let m = Machine(memory: r.startRAM)
        m.diskBlocks = Original.diskBlocks
        m.io.vic = r.startIO.vic
        m.io.sid = r.startIO.sid
        m.io.colorRAM = r.startIO.colorRAM
        m.io.cia2PortA = r.startIO.cia2PortA
        m.io.cia2DataDirectionA = r.startIO.cia2DirectionA
        m.clock.cycles = r.startCycle
        return m
    }

    /// What a replay found.
    struct Report {
        var outcome: ReplayDriver.Outcome
        var problems: [String]
        var framesCompared: Int
    }

    /// Replays `r` in `m` and checks every checkpoint. `frames` presents and compares a golden
    /// frame every that many checkpoints (and at the last one). `observe` sees the port at every
    /// matching checkpoint (what a session is about: an overlay resident, a mode, a palette).
    static func replay(_ r: Recording, on m: Machine, from start: ReplayDriver.Start, frames every: Int = 1,
                       observe: ((Int, Machine) -> Void)? = nil) -> Report {
        let driver = ReplayDriver(machine: m, log: r.log)
        var problems: [String] = []
        var framesCompared = 0
        driver.onCheckpoint = { k, m in
            observe?(k, m)
            guard k < r.io.count, problems.count < 12 else { return }
            let lab = r.io[k]
            let vic = Array(m.io.vic[0..<0x2F])
            if vic != lab.vic {
                let regs = (0..<0x2F).filter { vic[$0] != lab.vic[$0] }
                problems.append("checkpoint \(k): VIC " + regs.prefix(6).map {
                    String(format: "$D0%02X=%02X want %02X", $0, vic[$0], lab.vic[$0]) }.joined(separator: " "))
            }
            if Array(m.io.sid[0..<0x19]) != lab.sid {
                let regs = (0..<0x19).filter { m.io.sid[$0] != lab.sid[$0] }
                problems.append("checkpoint \(k): SID " + regs.prefix(6).map {
                    String(format: "$D4%02X=%02X want %02X", $0, m.io.sid[$0], lab.sid[$0]) }.joined(separator: " "))
            }
            if m.io.colorRAM != lab.colorRAM { problems.append("checkpoint \(k): color RAM differs") }
            // The VIC bank bits of CIA2 port A (the serial bus lines are the loader's, not ported).
            if (m.io.cia2PortA | ~m.io.cia2DataDirectionA) & 0x03 != (lab.cia2PortA | ~lab.cia2DirectionA) & 0x03 {
                problems.append(String(format: "checkpoint %d: CIA2 port A $%02X/DDR $%02X want $%02X/$%02X", k,
                                       m.io.cia2PortA, m.io.cia2DataDirectionA, lab.cia2PortA, lab.cia2DirectionA))
            }
            if let view = lab.view, view != m.io.viewRegion { problems.append("checkpoint \(k): window split state differs") }
            if let panel = lab.panel, panel != m.io.panelRegion { problems.append("checkpoint \(k): panel split state differs") }
            if k % every == 0 || k == r.log.checkpoints.count - 1, let view = lab.view, let panel = lab.panel {
                framesCompared += 1
                let original = present(r.images[k], colorRAM: lab.colorRAM, view: view, panel: panel)
                let port = present(m.memoryImage, colorRAM: m.io.colorRAM, view: m.io.viewRegion, panel: m.io.panelRegion)
                let differing = zip(original, port).filter { $0 != $1 }.count
                if differing != 0 { problems.append("checkpoint \(k): \(differing) pixels differ") }
                if k == r.log.checkpoints.count - 1 {
                    let url = Original.repoRoot.appendingPathComponent("build/testdata/replay-\(r.name).png")
                    try? ImageWriter.writePNG(indices: port, width: VICPresenter.width, height: VICPresenter.height,
                                              scaleX: 2, scaleY: 2, to: url)
                }
            }
        }
        driver.onMismatch = { mm, m in
            guard mm.checkpoint < r.images.count else { return }
            let image = r.images[mm.checkpoint]
            let d = Original.differences(m.memoryImage, image)
            problems.append("\(mm): \(d.count) bytes differ, first " + d.prefix(16).map {
                String(format: "$%04X=%02X want %02X", $0, m.mem[$0], image[$0]) }.joined(separator: " "))
        }
        let outcome = driver.run(from: start)
        return Report(outcome: outcome, problems: problems, framesCompared: framesCompared)
    }

    /// Checks a replay report: every checkpoint matched, no I/O or frame differences.
    static func expectClean(_ r: Recording, _ report: Report, minCheckpoints: Int = 5,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        let o = report.outcome
        let summary = "\(r.name): \(o.matched)/\(o.checkpoints) checkpoints, \(o.polls) polls, \(o.irqs) IRQs, "
            + "\(o.nmis) NMIs, \(report.framesCompared) frames; unlogged reads \(o.unloggedReads), "
            + "unread values \(o.unreadValues)"
        print("replay \(summary)")
        let details = report.problems.joined(separator: "\n")
        #expect(o.passed, "\(summary)\n\(o.error ?? "")\n\(details)", sourceLocation: sourceLocation)
        #expect(report.problems.isEmpty, "\(summary)\n\(details)", sourceLocation: sourceLocation)
        #expect(o.checkpoints >= minCheckpoints, "\(summary): too few checkpoints recorded", sourceLocation: sourceLocation)
        #expect(o.unloggedReads.isEmpty, "\(summary)", sourceLocation: sourceLocation)
    }

    /// Whether the recorded reads the port left unread (`Outcome.unreadValues`) are exactly those
    /// the lab made after the last checkpoint (where the replay stops), plus the ones the port
    /// never makes (`ReplayDriver.unperformedReads`).
    static func unreadAfterTheLastCheckpoint(_ r: Recording, _ o: ReplayDriver.Outcome) -> Bool {
        guard let last = r.log.checkpoints.last?.ioReads else { return false }
        var tail: [Int: Int] = [:]
        for read in r.log.ioReads[last...] { tail[Int(read.address), default: 0] += 1 }
        let performed = o.unreadValues.filter { !ReplayDriver.unperformedReads.contains($0.key) }
        return performed == tail.filter { !ReplayDriver.unperformedReads.contains($0.key) }
    }

    /// A frame presented with the split as the IRQs set it: the window state (line $20) on
    /// raster lines $20-$A2, the panel state (line $A3) on the others.
    static func present(_ ram: [UInt8], colorRAM: [UInt8], view: VICState, panel: VICState) -> [UInt8] {
        var out: [UInt8] = []
        ram.withUnsafeBufferPointer { p in
            VICPresenter.render(into: &out, ram: p, colorRAM: colorRAM, charROM: nil) { raster in
                raster >= 0xA3 || raster < 0x20 ? panel : view
            }
        }
        return out
    }

    /// The game's fixed split derived from memory alone: the window shows the bitmap the IRQ
    /// operand `$22B0` names, with the border `$22B5` and background `$0E69`; the panel is the
    /// hi-res bitmap A with border $0C; the four bezel sprites as `displayInit` sets them.
    static func fixedSplit(_ ram: [UInt8]) -> (view: VICState, panel: VICState) {
        var view = VICState()
        view.cr1 = 0x3B
        view.bank = 0x4000
        view.memPtr = ram[0x22B0]
        view.cr2 = 0xD8
        view.border = ram[0x22B5] & 0x0F
        view.background[0] = ram[0x0E69] & 0x0F
        view.spriteEnable = 0x0F
        view.spriteMulticolor = 0x0F
        view.spriteX = [0x58, 0x68, 0x58, 0x68, 0, 0, 0, 0]
        view.spriteY = [0xAA, 0xAA, 0xB5, 0xB5, 0, 0, 0, 0]
        view.spriteColor = Array(repeating: 0x0B, count: 8)
        view.spriteMC0 = 0x0B
        view.spriteMC1 = 0x01
        var panel = view
        panel.memPtr = 0xF0
        panel.cr2 = 0xC8
        panel.border = 0x0C
        return (view, panel)
    }
}

/// The sessions' common prefix: boot, color display, regular flight, until the Chicago area and
/// the Meigs detail block have loaded.
enum ReplaySessions {
    static func text(_ name: String) throws -> String {
        try String(contentsOf: Original.repoRoot.appendingPathComponent("re/sessions/\(name).txt"), encoding: .utf8)
    }

    static let meigs = """
    pc:2250:9000 key:A:12
    pc:2250:600 key:B:12
    pc:204B:3000
    until:0901:4E:3000 pc:204B:3000 wait:60
    """

    /// The Meigs prefix, then Europe 1917 turned on in the editor (page 0, line 6) and left
    /// (mode 7, the WWI area, the war overlay resident), ten seconds of war mode, the top of the
    /// main loop.
    static let europe1917 = meigs + """

    key:E:6 pc:2250:1500 wait:10 key:RETURN:6 wait:24 key:RETURN:6 wait:24 key:RETURN:6 wait:24
    key:RETURN:6 wait:24 key:RETURN:6 wait:24 key:1:6 wait:24
    key:E:6 pc:204B:3000 pc:204B:3000 wait:600 pc:204B:3000
    """
}

@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"))
struct ReplayHarnessTests {
    /// The key matrix of a delivery round-trips the lab's columns.
    @Test func keyMatrixFromDelivery() {
        var k = KeyMatrix()
        k.set(.runStop, pressed: true)
        k.set(.a, pressed: true)
        k.joystick1 = [.up, .fire]
        let d = ReplayLog.Delivery(poll: 1, irqs: 1, keyColumns: k.columns, joystick1: k.joystick1.rawValue,
                                   joystick2: 0, nmi: false)
        #expect(ReplayDriver.keyMatrix(d) == k)
    }

    /// The fixed split derived from memory equals the state the port's IRQs latch, once both
    /// phases ran after a flip (here: a recorded idle second).
    @Test func fixedSplitMatchesLatchedRegions() throws {
        let r = try ReplayLab.record("split", prefix: ReplaySessions.meigs, session: "wait:120")
        let m = ReplayLab.portMachine(r)
        var compared = 0, problems: [String] = []
        let driver = ReplayDriver(machine: m, log: r.log)
        driver.onCheckpoint = { k, m in
            guard k > 0 else { return }
            let image = m.memoryImage
            let fixed = ReplayLab.fixedSplit(image)
            let a = ReplayLab.present(image, colorRAM: m.io.colorRAM, view: fixed.view, panel: fixed.panel)
            let b = ReplayLab.present(image, colorRAM: m.io.colorRAM, view: m.io.viewRegion, panel: m.io.panelRegion)
            compared += 1
            let differing = zip(a, b).filter { $0 != $1 }.count
            if differing != 0 { problems.append("checkpoint \(k): \(differing) pixels") }
        }
        let outcome = driver.run(from: .mainLoop)
        #expect(outcome.passed, "\(outcome)")
        #expect(compared > 0)
        #expect(problems.isEmpty, "\(problems)")
    }
}
