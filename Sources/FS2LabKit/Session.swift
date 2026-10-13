import C64Kit
import Foundation

// Playing sessions on the lab machine. The session format itself (`Session`, `Session.parse`,
// `C64Key.named`) is in C64Kit (`SessionScript.swift`), shared with the app's headless mode.

/// A lab session step that cannot be played, or a CPU that stopped.
public enum LabError: Error, CustomStringConvertible {
    case badSession(String)
    case unknownKey(String)
    case cpuStopped(pc: UInt16, opcode: UInt8)

    public var description: String {
        switch self {
        case .badSession(let t): return "cannot parse session step '\(t)'"
        case .unknownKey(let k): return "unknown C64 key '\(k)'"
        case .cpuStopped(let pc, let op): return String(format: "CPU stopped at $%04X on illegal opcode $%02X", pc, op)
        }
    }
}

extension C64Machine {
    /// Runs a session, writing screenshots into `directory`.
    public func play(_ session: Session, screenshots directory: URL?) throws {
        var recorder: SessionCoverage?
        defer { recorder?.detach() }
        func keys(_ name: String) throws -> [C64Key] {
            try name.split(separator: "+").map { part -> C64Key in
                guard let k = C64Key.named(String(part)) else { throw LabError.unknownKey(String(part)) }
                return k
            }
        }
        for step in session.steps {
            switch step {
            case .keysDown(let name):
                for k in try keys(name) { keyboard.set(k, pressed: true) }
            case .keysUp(let name):
                for k in try keys(name) { keyboard.set(k, pressed: false) }
            case .nmi:
                if let recorder = replayRecorder { recorder.pressRestore() } else { pressNMI() }
            case .textScreen:
                print("frame \(frameCount) text screen:")
                print(textScreen())
            case .peek(let address, let count):
                let bytes = (0..<max(1, count)).map { String(format: "%02X", bus.ram[(address + $0) & 0xFFFF]) }
                print(String(format: "frame %d PC=$%04X SP=$%02X $%04X:", frameCount, cpu.pc, cpu.sp, address),
                      bytes.joined(separator: " "))
            case .waitByte(let address, let value, let negate, let maxFrames):
                let limit = frameCount + maxFrames
                run(maxCycles: UInt64.max) { m in
                    (m.bus.ram[address] == value) != negate || m.frameCount >= limit
                }
            case .watch(let low, let high):
                // The bus has a single access map. A watch would take it over from a coverage
                // recorder (cov:on, or the `coverage` command) and silently corrupt its data map.
                guard bus.accessMap == nil else {
                    throw LabError.badSession("watch:\(String(format: "%04X:%04X", low, high)) (the bus access map is "
                                              + "already in use by coverage recording or another watch)")
                }
                AccessWatch.attach(to: self, low: low, high: high)
            case .coverage(let command, let name):
                // Coverage steps only record under `run` (a directory to write into). Under the
                // `coverage` command they are ignored, so its own map stays complete.
                guard let dir = directory else { break }
                switch command {
                case "on":
                    // "on" starts a fresh recording unless one is already running.
                    guard recorder == nil else { break }
                    guard bus.accessMap == nil else {
                        throw LabError.badSession("cov:on (the bus access map is already in use by a watch: step)")
                    }
                    recorder = SessionCoverage(machine: self)
                case "off":
                    recorder?.detach()
                    recorder = nil
                default:
                    guard let r = recorder else {
                        print("coverage \(name): not recording (no cov:on), nothing written")
                        break
                    }
                    try r.write(to: dir.appendingPathComponent("\(name).cov"))
                    print("coverage \(name): \(r.executedCount) instruction starts at frame \(frameCount)")
                }
            case .wait(let frames):
                runFrames(frames)
            case .press(let name, let frames):
                // A "+"-joined name holds several keys together (e.g. CTRL+C).
                let held = try keys(name)
                for k in held { keyboard.set(k, pressed: true) }
                runFrames(frames)
                for k in held { keyboard.set(k, pressed: false) }
            case .joystick(let port, let dirs, let frames):
                var j = JoystickState()
                for d in dirs.lowercased().split(separator: "+") {
                    switch d {
                    case "up": j.insert(.up)
                    case "down": j.insert(.down)
                    case "left": j.insert(.left)
                    case "right": j.insert(.right)
                    case "fire": j.insert(.fire)
                    default: throw LabError.badSession(String(d))
                    }
                }
                if port == 1 { keyboard.joystick1 = j } else { keyboard.joystick2 = j }
                runFrames(frames)
                if port == 1 { keyboard.joystick1 = [] } else { keyboard.joystick2 = [] }
            case .poke(let address, let value):
                bus.ram[address] = value
            case .waitPC(let address, let maxFrames):
                let limit = frameCount + maxFrames
                run(maxCycles: UInt64.max) { m in m.cpu.pc == UInt16(address) || m.frameCount >= limit }
            case .snapshot(let name):
                if let dir = directory {
                    try Snapshot(machine: self).write(to: dir.appendingPathComponent("\(name).snap"))
                }
            case .screenshot(let name):
                if let dir = directory {
                    try ImageWriter.writePNG(indices: renderLastFrame(), width: VICPresenter.width,
                                             height: VICPresenter.height, scaleX: 3, scaleY: 4,
                                             to: dir.appendingPathComponent("\(name).png"))
                }
            }
            if let ill = cpu.illegalOpcode { throw LabError.cpuStopped(pc: ill.pc, opcode: ill.opcode) }
        }
    }
}

extension C64Machine {
    /// The text screen as 25 lines of 40 characters. Screen codes are decoded as the
    /// upper/lowercase set ($01-$1A lowercase, $1B-$1F `[ £ ] ↑ ←`, $20-$3F as ASCII, $41-$5A
    /// capitals, $40 as a rule `-`, graphics as `?`); a reverse-video cell ($80+) is prefixed
    /// with `~`.
    public func textScreen() -> String {
        let base = Int(bus.vicBank) + (Int(bus.vicRegs[0x18] & 0xF0) << 6)
        var lines: [String] = []
        for row in 0..<25 {
            var line = ""
            for col in 0..<40 {
                let code = bus.ram[(base + row * 40 + col) & 0xFFFF]
                line += Self.screenCodeText(code)
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// One screen code as text (see `textScreen`; `C64Kit.screenCodeText`).
    public static func screenCodeText(_ code: UInt8) -> String { C64Kit.screenCodeText(code) }
}

/// A machine snapshot for experiments and routine harness runs: RAM, color RAM, CPU registers.
public struct Snapshot: Codable, Sendable {
    public var ram: [UInt8]
    public var colorRAM: [UInt8]
    public var a: UInt8, x: UInt8, y: UInt8, sp: UInt8, pc: UInt16, status: UInt8
    public var cycles: UInt64
    public var frame: Int

    public init(machine m: C64Machine) {
        ram = m.bus.ram; colorRAM = m.bus.colorRAM
        a = m.cpu.a; x = m.cpu.x; y = m.cpu.y; sp = m.cpu.sp; pc = m.cpu.pc; status = m.cpu.status
        cycles = m.cpu.cycles; frame = m.frameCount
    }

    public func write(to url: URL) throws {
        try PropertyListEncoder().encode(self).write(to: url)
    }

    public static func read(from url: URL) throws -> Snapshot {
        try PropertyListDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }
}

/// Coverage recorded by the `cov:` session steps, split by which overlay sits in the $A7E0 window.
///
/// The overlay window $A7E0-$BFFF is shared by five overlays, so a plain 64 KB map cannot tell the
/// editor's code at $B09A from the war overlay's. This recorder keeps one 64 KB plane of flags per
/// overlay and charges every access (instruction starts, data reads and writes, at any address) to
/// the plane of the overlay resident at that moment, identified by its end word at $A7E0:
///
/// | Plane | Overlay | End word |
/// |---|---|---|
/// | 0 | cold start (stage 3) | $AD00 |
/// | 1 | editor | $BC6B |
/// | 2 | war | $B1EA |
/// | 3 | flight (+ root block 66) | $A800 |
/// | 4 | database info | $A878 |
/// | 5 | anything else (mid-load) | |
///
/// The plane is chosen before each instruction, so the store that changes the end word (and the
/// rest of that instruction's accesses) still counts for the previous plane.
///
/// The file is the six planes back to back (6 × 65536 bytes), with `Coverage`'s flag bits
/// (1 read, 2 written, 4 instruction start). OR the planes together for an overlay-blind map.
/// `cov:on` starts a fresh recording; `cov:off` discards it, so save first.
final class SessionCoverage {
    static let planeCount = 6
    static let endWords: [UInt16: Int] = [0xAD00: 0, 0xBC6B: 1, 0xB1EA: 2, 0xA800: 3, 0xA878: 4]

    let planes: UnsafeMutablePointer<UInt8>
    private unowned let machine: C64Machine
    private let previousHook: ((UInt16) -> Void)?
    private let previousMap: UnsafeMutablePointer<UInt8>?
    private var attached = true

    init(machine m: C64Machine) {
        machine = m
        planes = .allocate(capacity: Self.planeCount * 0x10000)
        planes.initialize(repeating: 0, count: Self.planeCount * 0x10000)
        previousHook = m.onInstruction
        previousMap = m.bus.accessMap
        let p = planes, bus = m.bus, previous = previousHook
        var lastWord: UInt16 = 0xFFFF
        var plane = p.advanced(by: 5 * 0x10000)
        m.onInstruction = { pc in
            let word = UInt16(bus.ram[0xA7E0]) | UInt16(bus.ram[0xA7E1]) << 8
            if word != lastWord {
                lastWord = word
                plane = p.advanced(by: (Self.endWords[word] ?? 5) * 0x10000)
                bus.accessMap = plane
            }
            plane[Int(pc)] |= Coverage.executed
            previous?(pc)
        }
        bus.accessMap = plane
    }

    deinit { planes.deallocate() }

    /// Stops recording and restores the machine's previous hooks.
    func detach() {
        guard attached else { return }
        attached = false
        machine.onInstruction = previousHook
        machine.bus.accessMap = previousMap
    }

    var executedCount: Int {
        var n = 0
        for a in 0..<0x10000 {
            for k in 0..<Self.planeCount where planes[k * 0x10000 + a] & Coverage.executed != 0 { n += 1; break }
        }
        return n
    }

    func write(to url: URL) throws {
        try Data(bytes: planes, count: Self.planeCount * 0x10000).write(to: url)
    }
}

/// The `watch:` session step: prints each instruction (once per PC and access kind) that reads or
/// writes RAM inside a range. It owns the bus access map while active.
final class AccessWatch {
    private let map: UnsafeMutablePointer<UInt8>

    private init() {
        map = .allocate(capacity: 0x10000)
        map.initialize(repeating: 0, count: 0x10000)
    }

    deinit { map.deallocate() }

    /// Installs the watch; the machine's instruction hook keeps it (and its access map) alive.
    static func attach(to m: C64Machine, low: Int, high: Int) {
        let watch = AccessWatch()
        let map = watch.map
        m.bus.accessMap = map
        var seen = Set<Int>()
        var lastPC: UInt16?
        let previous = m.onInstruction
        m.onInstruction = { [unowned m] pc in
            withExtendedLifetime(watch) {}
            if let last = lastPC {
                for a in low...high where map[a] != 0 {
                    let key = Int(last) << 2 | Int(map[a] & 3)
                    if !seen.contains(key) {
                        seen.insert(key)
                        let kind = map[a] & 3 == 3 ? "reads+writes" : map[a] & 2 != 0 ? "writes" : "reads"
                        print(String(format: "frame %d PC=$%04X %@ $%04X", m.frameCount, last, kind, a))
                    }
                    map[a] = 0
                }
            }
            lastPC = pc
            previous?(pc)
        }
    }
}
