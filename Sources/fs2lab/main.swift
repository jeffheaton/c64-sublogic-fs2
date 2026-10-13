import C64Kit
import FS2Data
import FS2LabKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
func usage() -> Never {
    print("""
    usage: fs2lab <command> [options]
      verify-disk <d64>                       check the disk against the reference block hashes
      cold-panel <d64> <out.png>              render the panel straight from the cold-start image
      run <d64> <outdir> "<session>"          boot the original and play a session, e.g.
                                              "wait:300 shot:title key:A:12 wait:120 shot:mode"
      loop <d64> "<session>"                  main-loop iteration timing over the session
      coverage <d64> <out.bin> "<session>"    execution/data-access coverage map (merged into out.bin)
      profile <d64> "<session>" <frames>      cycle histogram over <frames> frames after the session
      call <snap> <addr> [a=HH x=HH y=HH c=1 poke=ADDR:VAL,... dump=START-END ...]
                                              run one original routine on a snapshot's RAM (flat bus,
                                              no I/O) and print registers, cycles and changed bytes
      record <d64> <outdir> "<prefix>" "<session>"  deterministic replay log over <session>
      listing [--d64 path] [--out dir] [--symbols path]
                                              annotated ca65 listings from re/symbols.json -> re/out/
      symbols-check [--symbols path]          validate re/symbols.json (+ re/symbols.d/*.json)
      Sessions may also be given as @file (see re/sessions/*.txt).
    """)
    exit(2)
}
guard let cmd = args.first else { usage() }

/// A session argument: literal text, or @path to a session file.
func sessionText(_ arg: String) throws -> String {
    arg.hasPrefix("@") ? try String(contentsOfFile: String(arg.dropFirst()), encoding: .utf8) : arg
}

do {
    switch cmd {
    case "verify-disk":
        guard args.count == 2 else { usage() }
        let disk = try SubLogicDisk(try D64Image(contentsOf: URL(fileURLWithPath: args[1])))
        let bad = disk.mismatchedBlocks()
        print(bad.isEmpty ? "ok: all \(SubLogicDisk.blockCount) blocks match" : "mismatched blocks: \(bad)")
    case "cold-panel":
        guard args.count == 3 else { usage() }
        let data = try GameData(d64URL: URL(fileURLWithPath: args[1]))
        try ColdPanel.render(data, to: URL(fileURLWithPath: args[2]))
        print("wrote \(args[2])")
    case "run":
        guard args.count == 4 else { usage() }
        let data = try GameData(d64URL: URL(fileURLWithPath: args[1]))
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let m = Lab.boot(data)
        var ring = [UInt16](repeating: 0, count: 400), ringPos = 0
        if ProcessInfo.processInfo.environment["FS2LAB_RXTRACE"] != nil {
            m.onInstruction = { [unowned m] pc in
                if pc == 0x77F6 { print(String(format: "%llu RX $%02X st=$%02X", m.cpu.cycles, m.bus.ram[0xBD], m.bus.ram[0xB8])) }
            }
        }
        if ProcessInfo.processInfo.environment["FS2LAB_PCTRACE"] != nil {
            m.onInstruction = { pc in ring[ringPos % 400] = pc; ringPos += 1 }
        }
        let start = Date()
        defer {
            if ringPos > 0 {
                let n = min(ringPos, 400)
                print((0..<n).map { String(format: "%04X", ring[(ringPos - n + $0) % 400]) }.joined(separator: " "))
            }
        }
        try m.play(try Session.parse(try sessionText(args[3])), screenshots: out)
        let secs = Date().timeIntervalSince(start)
        print(String(format: "ran %d frames (%.1f s emulated) in %.2f s; PC=$%04X", m.frameCount,
                     Double(m.frameCount) / 59.826, secs, m.cpu.pc))
    case "loop":
        guard args.count == 3 else { usage() }
        let m = Lab.boot(try GameData(d64URL: URL(fileURLWithPath: args[1])))
        let timer = LoopTimer()
        timer.attach(to: m)
        try m.play(try Session.parse(try sessionText(args[2])), screenshots: nil)
        let its = timer.iterations.suffix(200)
        guard !its.isEmpty else { print("no iterations"); break }
        let cyc = its.map { Double($0.cycles) }
        let mean = cyc.reduce(0, +) / Double(cyc.count)
        if ProcessInfo.processInfo.environment["FS2LAB_VERBOSE"] != nil {
            for it in its { print(it.startCycle, it.cycles, it.frames) }
        }
        print(String(format: "%d iterations (last %d): mean %.0f cycles = %.2f frames = %.2f fps; min %.0f max %.0f",
                     timer.iterations.count, its.count, mean, mean / 17095, 1_022_727.14 / mean,
                     cyc.min()!, cyc.max()!))
    case "profile":
        guard args.count == 4, let warm = Int(args[3]) else { usage() }
        let m = Lab.boot(try GameData(d64URL: URL(fileURLWithPath: args[1])))
        try m.play(try Session.parse(try sessionText(args[2])), screenshots: nil)
        var hist = [UInt64](repeating: 0, count: 0x10000)
        var lastPC: UInt16 = 0, lastCycles = m.cpu.cycles
        m.onInstruction = { [unowned m] pc in
            hist[Int(lastPC)] += m.cpu.cycles - lastCycles
            lastPC = pc; lastCycles = m.cpu.cycles
        }
        m.runFrames(warm)
        let total = Double(hist.reduce(0, +))
        var pages = [(Int, UInt64)]()
        for p in 0..<256 { pages.append((p, hist[(p << 8)..<((p + 1) << 8)].reduce(0, +))) }
        for (p, c) in pages.sorted(by: { $0.1 > $1.1 }).prefix(15) {
            print(String(format: "page $%02X00: %5.1f%%", p, Double(c) / total * 100))
        }
        let top = (0..<0x10000).sorted { hist[$0] > hist[$1] }.prefix(25)
        print(top.map { String(format: "$%04X %.1f%%", $0, Double(hist[$0]) / total * 100) }.joined(separator: "  "))
    case "call":
        guard args.count >= 3, let addr = Int(args[2].replacingOccurrences(of: "$", with: ""), radix: 16) else { usage() }
        let snap = try Snapshot.read(from: URL(fileURLWithPath: args[1]))
        let h = RoutineHarness(ram: snap.ram)
        var regs = RoutineHarness.Registers()
        var dumps: [ClosedRange<Int>] = []
        func hex(_ s: Substring) -> Int { Int(s.replacingOccurrences(of: "$", with: ""), radix: 16) ?? 0 }
        for opt in args.dropFirst(3) {
            let kv = opt.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { usage() }
            switch kv[0] {
            case "a": regs.a = UInt8(hex(kv[1]))
            case "x": regs.x = UInt8(hex(kv[1]))
            case "y": regs.y = UInt8(hex(kv[1]))
            case "c": regs.carry = kv[1] == "1"
            case "poke":
                for p in kv[1].split(separator: ",") {
                    let av = p.split(separator: ":")
                    var a = hex(av[0])
                    for v in av.dropFirst() { h.bus.ram[a] = UInt8(hex(v)); a += 1 }
                }
            case "dump":
                let r = kv[1].split(separator: "-")
                dumps.append(hex(r[0])...hex(r.count > 1 ? r[1] : r[0]))
            default: usage()
            }
        }
        let before = h.bus.ram
        let r = h.call(UInt16(addr), regs)
        print(String(format: "%@ after %llu cycles: A=$%02X X=$%02X Y=$%02X C=%d Z=%d N=%d V=%d",
                     r.completed ? "returned" : "DID NOT RETURN", r.cycles, r.registers.a, r.registers.x,
                     r.registers.y, r.registers.carry ? 1 : 0, r.registers.zero ? 1 : 0,
                     r.registers.negative ? 1 : 0, r.registers.overflow ? 1 : 0))
        let changed = (0..<0x10000).filter { $0 >= 0x200 || $0 < 0x100 }.filter { before[$0] != h.bus.ram[$0] }
        print("changed bytes (\(changed.count)):", changed.prefix(64).map { String(format: "$%04X:%02X>%02X", $0, before[$0], h.bus.ram[$0]) }.joined(separator: " "))
        for d in dumps {
            for row in stride(from: d.lowerBound, through: d.upperBound, by: 16) {
                let end = min(row + 15, d.upperBound)
                print(String(format: "$%04X:", row), (row...end).map { String(format: "%02X", h.bus.ram[$0]) }.joined(separator: " "))
            }
        }
    case "record":
        // record <d64> <outdir> "<prefix session>" "<recorded session>": plays the prefix normally,
        // then records a deterministic replay log (+ memory images) over the second session.
        guard args.count == 5 else { usage() }
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let m = Lab.boot(try GameData(d64URL: URL(fileURLWithPath: args[1])))
        try m.play(try Session.parse(try sessionText(args[3])), screenshots: out)
        try Snapshot(machine: m).write(to: out.appendingPathComponent("start.snap"))
        let rec = ReplayRecorder(machine: m)
        try m.play(try Session.parse(try sessionText(args[4])), screenshots: out)
        try rec.write(to: out.appendingPathComponent("replay.plist"))
        let irqs = rec.log.deliveries.reduce(0) { $0 + $1.irqs }
        print("recorded \(rec.log.checkpoints.count) main-loop checkpoints, \(irqs) IRQs in \(rec.log.deliveries.count) batches, \(rec.log.ioReads.count) I/O reads")
        let byAddr = Dictionary(grouping: rec.log.ioReads, by: { $0.address }).mapValues { $0.count }
        print("I/O reads by address:", byAddr.sorted { $0.key < $1.key }.map { String(format: "$%04X×%d", $0.key, $0.value) }.joined(separator: " "))
    case "listing":
        try Listing.run(arguments: Array(args.dropFirst()))
    case "symbols-check":
        try SymbolsCheck.run(arguments: Array(args.dropFirst()))
    case "coverage":
        guard args.count == 4 else { usage() }
        let m = Lab.boot(try GameData(d64URL: URL(fileURLWithPath: args[1])))
        let cov = Coverage()
        let url = URL(fileURLWithPath: args[2])
        try? cov.load(from: url)
        cov.attach(to: m)
        try m.play(try Session.parse(try sessionText(args[3])), screenshots: nil)
        try cov.write(to: url)
        let executed = (0..<0x10000).filter { cov.flags[$0] & Coverage.executed != 0 }.count
        print("instruction starts covered: \(executed)")
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write("fs2lab: \(error)\n".data(using: .utf8)!)
    exit(1)
}
