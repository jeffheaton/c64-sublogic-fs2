// fs2check: the web build's determinism check and stack probe (`make web-check`). It drives the
// port inline (as the web worker does: `SessionDriver` through `InlineSessionHost`) with a fake
// clock and a scripted player, and prints a digest of the frames, the SID writes and memory every
// 200 frames. Built natively and for WebAssembly, the two runs must print the same lines.
//
//     fs2check session < disk.d64          the scripted session (about 2,400 frames)
//     fs2check restarts N < disk.d64       N RUN/STOP + RESTORE restarts, each back to the title:
//                                          the nested cold starts' stack depth

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#endif
#if !os(WASI)
import Foundation
#endif
import C64Kit
import FS2Core
import FS2Data
import FS2Host

func readStandardInput() -> [UInt8] {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        bytes += buffer[0..<n]
    }
    return bytes
}

func fail(_ message: String) -> Never {
    print("fs2check: \(message)")
    exit(1)
}

/// FNV-1a, the same on every platform.
struct Digest {
    var value: UInt64 = 0xCBF2_9CE4_8422_2325
    mutating func add(_ byte: UInt8) { value = (value ^ UInt64(byte)) &* 0x100_0000_01B3 }
    mutating func add(_ bytes: some Sequence<UInt8>) { for b in bytes { add(b) } }
    mutating func add(_ word: UInt64) { for i in 0..<8 { add(UInt8(truncatingIfNeeded: word >> UInt64(8 * i))) } }
}

/// The scripted player: controls that change at given frames, a fake clock that every read and
/// wait advances, and the digests.
final class Player {
    var clock: UInt64 = 1_000_000_000
    var frames = 0
    var reads = 0
    var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    var requests = HostRequests()
    var pauseUntilRead: Int?
    var actions: [(frame: Int, apply: (Player) -> Void)] = []
    var nextAction = 0
    var endFrame = 0
    var pixels = Digest(), sound = Digest()
    var report: (Player) -> Void = { _ in }
    /// The deepest address of the stack the reads saw, and the first one (the stack grows down).
    var stackTop: Int?
    var stackLow = Int.max

    func random() -> UInt64 {
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
        return rng &* 0x2545_F491_4F6C_DD1D
    }

    func press(_ keys: C64Key..., joystick1: JoystickState = [], joystick2: JoystickState = []) {
        var input = InputState()
        for k in keys { input.keys.set(k, pressed: true) }
        input.keys.joystick1 = joystick1
        input.keys.joystick2 = joystick2
        requests.input = input
        requests.inputChanged = true
        for k in keys { requests.pressedSinceRead.set(k, pressed: true) }
    }

    func at(_ frame: Int, _ apply: @escaping (Player) -> Void) { actions.append((frame, apply)) }

    var io: SessionDriver.IO {
        SessionDriver.IO(now: { [unowned self] in clock }, wait: { [unowned self] in clock &+= $0 },
                         readRequests: { [unowned self] in read() })
    }

    private func read() -> HostRequests? {
        reads += 1
        clock &+= 100_000 + random() % 3_000_000
        var marker = 0
        let depth = withUnsafeMutablePointer(to: &marker) { Int(bitPattern: $0) }
        if stackTop == nil { stackTop = depth }
        stackLow = min(stackLow, depth)
        if let until = pauseUntilRead, reads >= until {
            requests.paused = false
            pauseUntilRead = nil
        }
        while nextAction < actions.count && actions[nextAction].frame <= frames {
            actions[nextAction].apply(self)
            nextAction += 1
        }
        guard frames < endFrame else { return nil }
        let r = requests
        requests.restart = false; requests.demo = false; requests.inputChanged = false
        requests.pressedSinceRead = KeyMatrix()
        return r
    }

    /// The stack the program has used so far beyond the first read's depth, in KB.
    var stackKB: Int { ((stackTop ?? 0) - stackLow) / 1024 }
}

/// Runs the check (never returns: the host exits the process when the script ends).
func check(_ arguments: [String]) -> Never {
    let mode = arguments.count > 1 ? arguments[1] : "session"
    let disk = readStandardInput()
    let data: GameData
    do {
        data = try GameData(d64: D64Image(data: disk))
    } catch {
        fail("the disk on standard input cannot be used: \(error)")
    }

    let player = Player()
    let engine = NativeEngine(data: data, modeLibrary: ModeLibrary.InMemoryStore().io, execution: .inline)

    let line = { (label: String) in
        var memory = Digest()
        memory.add(UnsafeBufferPointer(start: engine.machine.mem, count: Machine.memorySize))
        print("\(label) frame \(player.frames) cycle \(engine.cycles) pixels \(hex(player.pixels.value, width: 16)) "
              + "sound \(hex(player.sound.value, width: 16)) memory \(hex(memory.value, width: 16))")
    }

    switch mode {
    case "session":
        // Title (A), the mode prompt (B), regular flight: throttle up, a tap, a stall, a pause, the
        // demo, Smooth pacing with the keypad joystick and strict sharing, then RUN/STOP + RESTORE.
        player.endFrame = 2400
        player.at(30) { $0.press(.a) }; player.at(44) { $0.press() }
        player.at(120) { $0.press(.b) }; player.at(134) { $0.press() }
        player.at(700) { $0.press(joystick2: .up) }; player.at(760) { $0.press() }
        player.at(900) { $0.requests.inputChanged = true; $0.requests.pressedSinceRead.set(.l, pressed: true) }
        player.at(1000) { $0.clock &+= 2_000_000_000 }
        player.at(1100) { $0.requests.paused = true; $0.pauseUntilRead = $0.reads + 40 }
        player.at(1200) { $0.requests.demo = true }
        player.at(1300) { $0.requests.options.pacing = .smooth }
        player.at(1350) { $0.requests.options.strictJoystick = true }
        player.at(1360) { $0.press(joystick1: [.up, .left]) }; player.at(1400) { $0.press() }
        player.at(1550) { $0.requests.options = EngineOptions() }
        player.at(1650) { $0.requests.restart = true }
        player.report = { p in if p.frames % 200 == 0 { line("at") } }
    case "restarts":
        // Restart at the title, wait for the title again, over and over: every restart nests the
        // cold start inside the frames of the key wait it interrupted.
        let count = arguments.count > 2 ? Int(arguments[2]) ?? 10 : 10
        let cycle = 4400
        player.endFrame = 60 + count * cycle
        for k in 0..<count { player.at(60 + k * cycle) { $0.requests.restart = true } }
        player.report = { p in
            if p.frames > 60 && (p.frames - 60) % cycle == cycle - 1 {
                print("restart \((p.frames - 60) / cycle + 1): stack \(p.stackKB) KB")
            }
        }
    default:
        fail("unknown mode \(mode) (session, restarts N)")
    }

    let driver = SessionDriver(engine: engine, audio: nil, options: EngineOptions(), io: player.io) { frame in
        player.frames += 1
        player.pixels.add(frame.pixels)
        for w in frame.sidWrites { player.sound.add(w.cycle); player.sound.add(w.reg); player.sound.add(w.value) }
        player.report(player)
    }
    let host = InlineSessionHost(driver: driver, stopped: {
        line("end")
        print("stack \(player.stackKB) KB")
        exit(0)
    }, ended: { reason in
        line("ended")
        fail("the program ended: \(reason)")
    })

    #if os(WASI)
    engine.runInline(host)
    #else
    // The Mac's program thread size: the nested restarts' frames stay on the stack.
    nonisolated(unsafe) let unsafeEngine = engine, unsafeHost = host
    let thread = Thread { unsafeEngine.runInline(unsafeHost) }
    thread.stackSize = ProgramThread.defaultStackSize
    thread.start()
    while true { _ = sleep(60) }
    #endif
}

check(CommandLine.arguments)
