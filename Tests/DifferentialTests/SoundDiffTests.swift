import C64Kit
import FS2Core
import FS2LabKit
import Foundation
import Testing

/// One SID store: register ($D400 + reg), value, and the cycle offset from the start of the call.
private struct SIDStore: Equatable, CustomStringConvertible {
    var offset: UInt64
    var reg: Int
    var value: UInt8
    var description: String { String(format: "+%llu $D4%02X=$%02X", offset, reg, value) }
}

/// The original running on the flat bus, with every SID store stamped with the cycle at which its
/// instruction starts (the lab's convention). RAM persists across calls, so sequences can be run.
private final class OriginalSound {
    let harness: RoutineHarness
    /// Total cycles of all calls so far (used to stamp sequences).
    private(set) var elapsed: UInt64 = 0
    /// Every SID store of every call, stamped with `elapsed` at the store.
    private(set) var log: [SIDStore] = []

    /// `returnAt` puts a return opcode at the given addresses, so fragments of larger routines
    /// ($22C8 in the frame IRQ, $2381 in the 10 Hz tick) return where the sound part ends.
    init(ram: [UInt8], returnAt: [Int] = []) {
        var ram = ram
        for a in returnAt { ram[a] = 0x60 }
        harness = RoutineHarness(ram: ram)
    }

    var ram: [UInt8] { harness.bus.ram }
    func peek(_ a: Int) -> UInt8 { harness.bus.ram[a] }
    func poke(_ a: Int, _ v: UInt8) { harness.bus.ram[a] = v }

    /// Runs the routine at `address` until it returns; returns its SID stores and cycles.
    /// `boundary`, when given, is called at every instruction boundary (before each instruction and
    /// after the last one) with the cycle offset from the start and the number of SID stores so far.
    @discardableResult
    func call(_ address: UInt16, boundary: ((UInt64, Int) -> Void)? = nil) -> (sid: [SIDStore], cycles: UInt64) {
        let cpu = harness.cpu, bus = harness.bus
        cpu.interruptDisable = true
        cpu.irqLine = false
        cpu.decimal = false
        // Return address $FFEF on the stack: the return lands on the sentinel $FFF0.
        bus.ram[0x01FF] = 0xFF
        bus.ram[0x01FE] = 0xEF
        cpu.sp = 0xFD
        cpu.pc = address
        bus.ioWrites.removeAll()
        let start = cpu.cycles
        var stores: [SIDStore] = []
        while cpu.pc != 0xFFF0 && cpu.cycles - start < 100_000 {
            let before = cpu.cycles, seen = bus.ioWrites.count
            boundary?(before - start, stores.count)
            if cpu.step() == 0 { break }
            for w in bus.ioWrites[seen...] where (0xD400...0xD41F).contains(Int(w.address)) {
                stores.append(SIDStore(offset: before - start, reg: Int(w.address) - 0xD400, value: w.value))
            }
        }
        if cpu.pc != 0xFFF0 { Issue.record(Comment(rawValue: String(format: "original $%04X did not return", address))) }
        let cycles = cpu.cycles - start
        boundary?(cycles, stores.count)
        log += stores.map { SIDStore(offset: elapsed + $0.offset, reg: $0.reg, value: $0.value) }
        elapsed += cycles
        return (stores, cycles)
    }
}

/// The port, with the same bookkeeping.
private final class PortSound {
    let machine: Machine
    private(set) var log: [SIDStore] = []

    init(ram: [UInt8], returnAt: [Int] = []) {
        var ram = ram
        for a in returnAt { ram[a] = 0x60 }
        machine = Machine(memory: ram)
        machine.clock.cycles = 1_000_000
    }

    var ram: [UInt8] { machine.memoryImage }
    func peek(_ a: Int) -> UInt8 { machine[a] }
    func poke(_ a: Int, _ v: UInt8) { machine[a] = v }

    /// `overhead` is added to the port's cycles and offsets so a sequence's log lines up with the
    /// original's, whose fragments end in an extra planted return.
    @discardableResult
    func call(overhead: UInt64 = 0, _ body: (Machine) -> Void) -> (sid: [SIDStore], cycles: UInt64) {
        let start = machine.clock.cycles, seen = machine.io.sidWrites.count
        body(machine)
        let stores = machine.io.sidWrites[seen...].map {
            SIDStore(offset: $0.cycle - start, reg: Int($0.reg), value: $0.value)
        }
        machine.clock.cycles += overhead
        let cycles = machine.clock.cycles - start
        log += stores.map { SIDStore(offset: start - 1_000_000 + $0.offset, reg: $0.reg, value: $0.value) }
        return (stores, cycles)
    }
}

/// Memory that must match: everything except the stack page and the I/O page (the flat bus also
/// stores the SID values into RAM at $D4xx; the port sends them to `io` only).
private let ignored: [ClosedRange<Int>] = [0x0100...0x01FF, 0xD000...0xDFFF]

private func hex(_ a: [Int]) -> String {
    a.prefix(12).map { String(format: "$%04X", $0) }.joined(separator: " ") + (a.count > 12 ? " ..." : "")
}

/// Compares one call: SID stores (order, values, cycle offsets), cycles and memory. Records an
/// issue on a mismatch and returns whether they matched.
@discardableResult
private func expectSame(_ o: (sid: [SIDStore], cycles: UInt64), _ p: (sid: [SIDStore], cycles: UInt64),
                        _ oRAM: [UInt8], _ pRAM: [UInt8], _ what: @autoclosure () -> String,
                        sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
    let diff = Original.differences(oRAM, pRAM, ignoring: ignored)
    let ok = o.sid == p.sid && o.cycles == p.cycles && diff.isEmpty
    if !ok {
        Issue.record("""
            \(what()): cycles original \(o.cycles) port \(p.cycles); memory differs at \(hex(diff))
              original SID: \(o.sid)
              port SID:     \(p.sid)
            """, sourceLocation: sourceLocation)
    }
    return ok
}

/// Sound-relevant bytes a test randomizes on top of a real snapshot.
private let soundBytes = [0x09BE, 0x0E58, 0x0E5A, 0x0E5B, 0x0E5C, 0x0E5E, 0x0E60, 0x0E7D, 0x0E7E, 0x2308, 0x2309]

@Suite(.enabled(if: Original.available, "needs the Flight Simulator II disk image"), .serialized)
struct SoundDiffTests {
    static let base: [UInt8] = (try? Original.regularFlight()) ?? Original.data?.coldMemory ?? []

    /// A copy of the snapshot with the sound bytes randomized.
    static func randomized(_ rng: inout TestRandom) -> [UInt8] {
        var ram = base
        for a in soundBytes { ram[a] = rng.byte() }
        return ram
    }

    // MARK: $CC16 state machine

    @Test func soundTickEveryStateSkipAndEnable() throws {
        var rng = TestRandom(seed: 0xCC16)
        var failures = 0
        for state in 0...10 {
            for enable: UInt8 in [0x00, 0x01, 0x80] {
                for skip: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x0F, 0xFE, 0xFF] {
                    // The whistle height matters only to the bomb states.
                    let heights: [UInt8] = state == 4 || state == 10 ? [0x00, 0x2F, 0x30, 0x4A, 0x7F, 0xFF] : [rng.byte()]
                    for whistleHi in heights {
                        var ram = Self.randomized(&rng)
                        ram[0x08D3] = enable
                        ram[0x0E59] = UInt8(state)
                        ram[0x0E5C] = skip
                        ram[0x0E7E] = whistleHi
                        let o = OriginalSound(ram: ram), p = PortSound(ram: ram)
                        let ro = o.call(0xCC16), rp = p.call { $0.soundTick() }
                        if !expectSame(ro, rp, o.ram, p.ram,
                                       "state \(state) enable \(enable) skip \(skip) whistle $\(String(whistleHi, radix: 16))") {
                            failures += 1
                        }
                        if failures > 5 { return }
                    }
                }
            }
        }
    }

    /// Every handler with its original address, including the ones game code calls directly ($CC68,
    /// $CCD1, $CD04) and the common exit.
    private static let handlers: [(UInt16, @Sendable (Machine) -> Void)] = [   // in address order
        (0xCC46, { $0.sfxStallHorn() }), (0xCC68, { $0.sfxCrash() }), (0xCCD1, { $0.sfxGun() }),
        (0xCD04, { $0.sfxBombRelease() }), (0xCD2E, { $0.sfxOuterMarker() }), (0xCD59, { $0.sfxMiddleMarker() }),
        (0xCD84, { $0.sfxInnerMarker() }), (0xCDAF, { $0.sfxTouchdown() }), (0xCDF3, { $0.sfxExit() }),
        (0xCDF9, { $0.sfxReset() }), (0xCE07, { $0.sfxIdle() }), (0xCE37, { $0.sfxBombWait() }),
    ]

    @Test func effectRoutinesCalledDirectly() throws {
        var rng = TestRandom(seed: 0xCD00)
        for (address, port) in Self.handlers {
            for n in 0..<40 {
                var ram = Self.randomized(&rng)
                if address == 0xCE37 { ram[0x0E7E] = [0x2F, 0x30, 0x00, 0xFF, rng.byte()][n % 5] }
                if address == 0xCDF9 && n == 0 { ram[0x09BE] = 0xFF }     // the increment wraps
                let o = OriginalSound(ram: ram), p = PortSound(ram: ram)
                let ro = o.call(address)
                if address != 0xCDF3 && address != 0xCE37 { #expect(!ro.sid.isEmpty) }
                if !expectSame(ro, p.call(port), o.ram, p.ram, String(format: "handler $%04X case %d", address, n)) { break }
            }
        }
    }

    @Test func soundTickTableDispatchWritesTheJumpOperand() throws {
        // The port reads the handler table from memory and keeps the self-modified operand.
        var ram = Self.base
        ram[0x08D3] = 1
        ram[0x0E5C] = 0
        for state in 0...10 {
            ram[0x0E59] = UInt8(state)
            let p = PortSound(ram: ram)
            p.call { $0.soundTick() }
            let operand = UInt16(p.ram[0xCC44]) | UInt16(p.ram[0xCC45]) << 8
            #expect(UInt16(ram[0xCC00 + 2 * state]) | UInt16(ram[0xCC01 + 2 * state]) << 8 == operand,
                    "table entry for state \(state)")
            #expect(SoundDriver.Effect(handler: operand) == SoundDriver.Effect(rawValue: UInt8(state)),
                    "the handler of state \(state)")
        }
    }

    @Test func sidInitMatches() throws {
        // $AB58 lives in the cold-start overlay, so this runs on the boot image.
        var rng = TestRandom(seed: 0xAB58)
        for n in 0..<8 {
            var ram = try #require(Original.data).coldMemory
            if n > 0 { for a in soundBytes { ram[a] = rng.byte() } }
            let o = OriginalSound(ram: ram), p = PortSound(ram: ram)
            let ro = o.call(0xAB58)
            #expect(ro.sid.count > 25, "the clear and the idle state write the SID")
            expectSame(ro, p.call { $0.sidInit() }, o.ram, p.ram, "sidInit case \(n)")
        }
    }

    // MARK: Gate-pattern player

    @Test func patternPlayerFrameEdgeCases() throws {
        var rng = TestRandom(seed: 0x22C8)
        var failures = 0
        for countdown: UInt8 in [0x00, 0x01, 0x02, 0xFF] {
            for period: UInt8 in [0x00, 0x01, 0x02, 0x05, 0x0F, 0x28, 0xFF] {
                for counter: UInt8 in [0x00, 0x01, 0x07, 0x08, 0x0F, 0xFF] {
                    for _ in 0..<3 {
                        var ram = Self.randomized(&rng)
                        ram[0x0E5B] = countdown
                        ram[0x0E5A] = period
                        ram[0x2308] = counter
                        // $22CD (keyboard phase) becomes a return: the original's extra 6 cycles.
                        let o = OriginalSound(ram: ram, returnAt: [0x22CD]), p = PortSound(ram: ram, returnAt: [0x22CD])
                        if !expectSame(o.call(0x22C8), p.call(overhead: 6) { $0.patternPlayerFrame() }, o.ram, p.ram,
                                       "countdown \(countdown) period \(period) counter \(counter)") {
                            failures += 1
                        }
                        if failures > 5 { return }
                    }
                }
            }
        }
    }

    @Test func patternStepDirectly() throws {
        var rng = TestRandom(seed: 0x230A)
        var stepCycles = (UInt64.max, UInt64(0)), frameCycles = (UInt64.max, UInt64(0))
        for n in 0..<300 {
            var ram = Self.randomized(&rng)
            // Every path: reload or not ($2308 & 7), and a 1 or a 0 shifted out.
            let counters: [UInt8] = [0x00, 0x08, 0x03, 0xFF]
            ram[0x2308] = counters[n % 4] &+ (n % 8 < 4 ? 0x00 : 0x10)
            ram[0x0E5E] = n % 8 < 4 ? 0x01 : 0x00
            ram[0x2309] = UInt8(n / 8 % 2)
            let o = OriginalSound(ram: ram, returnAt: [0x22CD]), p = PortSound(ram: ram, returnAt: [0x22CD])
            let ro = o.call(0x230A)
            if !expectSame(ro, p.call(overhead: 6) { $0.patternStep() }, o.ram, p.ram, "step case \(n)") { break }
            stepCycles = (min(stepCycles.0, ro.cycles - 6), max(stepCycles.1, ro.cycles - 6))
            // The whole frame part when the countdown expires: the countdown, its page-crossing
            // branch, the step.
            ram[0x0E5B] = 1
            let of = OriginalSound(ram: ram, returnAt: [0x22CD]), pf = PortSound(ram: ram, returnAt: [0x22CD])
            let rf = of.call(0x22C8)
            expectSame(rf, pf.call(overhead: 6) { $0.patternPlayerFrame() }, of.ram, pf.ram, "frame step case \(n)")
            frameCycles = (min(frameCycles.0, rf.cycles - 6), max(frameCycles.1, rf.cycles - 6))
        }
        // The costs the docs quote (without the return stub at $22CD).
        #expect(stepCycles == (43, 51), "step costs \(stepCycles)")
        #expect(frameCycles == (53, 61), "frame with a step costs \(frameCycles)")
    }

    @Test func patternPlayerOverManyFrames() throws {
        // 1200 frames with the pattern, period and control changed now and then, as effects do.
        var rng = TestRandom(seed: 0x2309)
        let ram = Self.randomized(&rng)
        let o = OriginalSound(ram: ram, returnAt: [0x22CD]), p = PortSound(ram: ram, returnAt: [0x22CD])
        for frame in 0..<1200 {
            if frame % 97 == 0 {
                let pattern = rng.byte(), period = rng.byte() & 0x1F, control = rng.byte()
                for s in [o.poke, p.poke] {
                    s(0x0E5E, pattern); s(0x0E5A, period); s(0x0E60, control)
                }
            }
            o.call(0x22C8)
            p.call(overhead: 6) { $0.patternPlayerFrame() }
        }
        #expect(o.log == p.log)
        #expect(Original.differences(o.ram, p.ram, ignoring: ignored).isEmpty)
    }

    // MARK: Engine slew

    @Test func engineSlewAllPairs() throws {
        // Every (E, T) pair on one shared state: SID stores, cycles and the bytes it writes.
        let o = OriginalSound(ram: Self.base), p = PortSound(ram: Self.base)
        var failures = 0
        var cycleRange = (UInt64.max, UInt64(0))
        for e in 0..<256 {
            for t in 0..<256 {
                for s in [o.poke, p.poke] { s(0x09BE, UInt8(e)); s(0x0E58, UInt8(t)) }
                let ro = o.call(0xE500), rp = p.call { $0.engineSoundSlew() }
                let same = ro.sid == rp.sid && ro.cycles == rp.cycles
                    && [0x09BE, 0x0E52, 0x0E54].allSatisfy { o.peek($0) == p.peek($0) }
                if !same {
                    failures += 1
                    Issue.record("E=\(e) T=\(t): original \(ro.sid) \(ro.cycles); port \(rp.sid) \(rp.cycles)")
                    if failures > 5 { return }
                }
                if e != t { cycleRange = (min(cycleRange.0, ro.cycles), max(cycleRange.1, ro.cycles)) }
            }
        }
        #expect(Original.differences(o.ram, p.ram, ignoring: ignored).isEmpty)
        #expect(cycleRange.0 == 114 && cycleRange.1 == 119, "moving slew costs \(cycleRange.0)...\(cycleRange.1) cycles")
    }

    @Test func engineSlewUpDownAndAtTarget() throws {
        // Full-memory checks on fresh snapshots for slews up, down, at the target and wrapping.
        let cases: [(UInt8, UInt8)] = [(0x10, 0x10), (0x32, 0x32), (0x0D, 0x32), (0x31, 0x32), (0x32, 0x0D),
                                       (0x0E, 0x0D), (0x01, 0x00), (0xF2, 0x10), (0xF1, 0x10), (0xFE, 0xFF),
                                       (0xFF, 0x00), (0x00, 0xFF), (0x7F, 0x80)]
        var rng = TestRandom(seed: 0xE500)
        for (e, t) in cases + (0..<100).map({ _ in (rng.byte(), rng.byte()) }) {
            var ram = Self.randomized(&rng)
            ram[0x09BE] = e
            ram[0x0E58] = t
            let o = OriginalSound(ram: ram), p = PortSound(ram: ram)
            expectSame(o.call(0xE500), p.call { $0.engineSoundSlew() }, o.ram, p.ram, "E=\(e) T=\(t)")
        }
        // Slewing to the target takes |E - T| / 2 calls and then stops writing.
        var ram = Self.base
        ram[0x09BE] = 0x0D
        ram[0x0E58] = 0x32
        let p = PortSound(ram: ram)
        var calls = 0
        while p.call({ $0.engineSoundSlew() }).sid.count == 4 { calls += 1 }
        #expect(calls == 19 && p.ram[0x09BE] == 0x32)
    }

    // MARK: Bomb whistle

    @Test func bombSweepSteps() throws {
        var rng = TestRandom(seed: 0x2381)
        let values: [UInt16] = [0x4A38, 0x3000, 0x2FFF, 0x00F0, 0x00EF, 0x0000, 0x7FFF, 0x8000, 0xFFFF, 0x0100]
        for v in values + (0..<200).map({ _ in UInt16(rng.byte()) << 8 | UInt16(rng.byte()) }) {
            var ram = Self.randomized(&rng)
            ram[0x0E7D] = UInt8(v & 0xFF)
            ram[0x0E7E] = UInt8(v >> 8)
            // $239B (the `$0E6C` count and the rest of the tick) becomes a return.
            let o = OriginalSound(ram: ram, returnAt: [0x239B]), p = PortSound(ram: ram, returnAt: [0x239B])
            expectSame(o.call(0x2381), p.call(overhead: 6) { $0.bombWhistleSweep() }, o.ram, p.ram,
                       String(format: "whistle $%04X", v))
        }
    }

    /// Plays a schedule on both sides: the frame IRQ's pattern player every frame, the 10 Hz tick's
    /// engine slew and bomb sweep every 6 frames, and the 1 Hz tick every 60 frames.
    private static func play(_ o: OriginalSound, _ p: PortSound, frames: Int, startFrame: Int = 0,
                             atFrame: (Int) -> Void = { _ in }) {
        for frame in startFrame..<(startFrame + frames) {
            atFrame(frame)
            o.call(0x22C8)
            p.call(overhead: 6) { $0.patternPlayerFrame() }
            if frame % 6 == 0 {
                o.call(0xE500)
                p.call { $0.engineSoundSlew() }
                o.call(0x2381)
                p.call(overhead: 6) { $0.bombWhistleSweep() }
                if frame % 60 == 0 {
                    o.call(0xCC16)
                    p.call { $0.soundTick() }
                }
            }
        }
    }

    @Test(arguments: [UInt8(1), 0])
    func bombThroughExplosion(sound: UInt8) throws {
        var ram = Self.base
        ram[0x08D3] = sound
        ram[0x0E59] = 0
        ram[0x0E5C] = 0
        ram[0x0E58] = 0x20
        let o = OriginalSound(ram: ram, returnAt: [0x22CD, 0x239B]), p = PortSound(ram: ram, returnAt: [0x22CD, 0x239B])
        Self.play(o, p, frames: 30)
        o.call(0xCD04)
        p.call { $0.triggerEffect(.bombRelease) }
        Self.play(o, p, frames: 60 * 12, startFrame: 30)
        #expect(o.log == p.log)
        #expect(Original.differences(o.ram, p.ram, ignoring: ignored).isEmpty)
        // Sound on: the explosion stopped the sweep at $FF and the state machine went back to idle.
        // Sound off: the sweep ran until it wrapped below zero, and state 10 is still pending.
        let explosions = p.log.filter { $0.reg == 0x12 && $0.value == 0x80 }.count
        if sound != 0 {
            #expect(explosions == 1 && p.ram[0x0E7E] == 0xFF && p.ram[0x0E59] == 0)
        } else {
            #expect(explosions == 0 && p.ram[0x0E7E] >= 0x80 && p.ram[0x0E59] == 10)
        }
    }

    // MARK: Effect lifecycles

    /// Effects whose trigger keeps firing while the condition holds (stall, markers, fire held).
    private static let held: [SoundDriver.Effect] = [.stallHorn, .gun, .outerMarker, .middleMarker, .innerMarker]

    /// Arms an effect the way game code does, on both sides.
    private static func arm(_ effect: SoundDriver.Effect, _ o: OriginalSound, _ p: PortSound) {
        switch effect {
        case .gun:
            o.poke(0x0E59, 3); o.call(0xCCD1)
        case .bombRelease:
            o.call(0xCD04)
        case .crash:
            o.call(0xCC68)
        default:
            o.poke(0x0E59, effect.rawValue)
        }
        p.call { $0.triggerEffect(effect) }
    }

    @Test(arguments: SoundDriver.Effect.allCases)
    func effectLifecycle(effect: SoundDriver.Effect) throws {
        // Each effect armed once (the held ones re-armed for 3 s, as their triggers do), with sound
        // on, then turned off mid-way and back on.
        for toggleSound in [false, true] {
            var ram = Self.base
            ram[0x08D3] = 1
            ram[0x0E59] = 0
            ram[0x0E5C] = 0
            ram[0x0E58] = 0x28
            let o = OriginalSound(ram: ram, returnAt: [0x22CD, 0x239B]), p = PortSound(ram: ram, returnAt: [0x22CD, 0x239B])
            Self.play(o, p, frames: 61)
            Self.arm(effect, o, p)
            Self.play(o, p, frames: 60 * 8, startFrame: 61) { frame in
                if Self.held.contains(effect), frame < 61 + 180, frame % 12 == 0 {
                    Self.arm(effect, o, p)
                }
                if toggleSound && frame == 61 + 150 { o.poke(0x08D3, 0); p.poke(0x08D3, 0) }
                if toggleSound && frame == 61 + 330 { o.poke(0x08D3, 1); p.poke(0x08D3, 1) }
            }
            #expect(o.log == p.log, "\(effect) toggle \(toggleSound)")
            #expect(Original.differences(o.ram, p.ram, ignoring: ignored).isEmpty, "\(effect) toggle \(toggleSound)")
        }
    }

    @Test func soundOffSilencesButDirectEffectsStillPlay() throws {
        // The quirk the docs describe: with $08D3 = 0, a directly called effect gates voice 3 through
        // the pattern player until the next 1 Hz tick zeroes the pattern.
        var ram = Self.base
        ram[0x08D3] = 0
        ram[0x0E5C] = 0
        let o = OriginalSound(ram: ram, returnAt: [0x22CD, 0x239B]), p = PortSound(ram: ram, returnAt: [0x22CD, 0x239B])
        Self.play(o, p, frames: 1)
        Self.arm(.gun, o, p)
        let mark = p.log.count
        Self.play(o, p, frames: 58, startFrame: 1)
        #expect(o.log == p.log)
        #expect(p.log[mark...].contains { $0.reg == 0x12 && $0.value == 0x81 })
        // The tick at frame 60 zeroes the pattern; every later step writes $D412 = 0.
        Self.play(o, p, frames: 62, startFrame: 59)
        #expect(o.log == p.log)
        #expect(p.peek(0x0E5E) == 0 && p.peek(0x2309) == 0)
        #expect(p.log.last { $0.reg == 0x12 }?.value == 0)
    }

    // MARK: Call sites

    @Test func triggerEffectMatchesTheGameCallSites() throws {
        // Each place the game arms an effect, run in the original through the end of its sound part,
        // against `triggerEffect` with the call site's own instructions charged around it (the
        // caller's share, as `triggerEffect` documents).
        struct Site {
            var effect: SoundDriver.Effect
            var start: UInt16
            /// Where the original's sound part ends (a return is planted there).
            var stub: Int
            /// The call site's cycles before the effect routine (loads, stores, the call), and
            /// after it.
            var before: Int, after: UInt64
        }
        let sites: [Site] = [
            // $3014 in the 5 Hz aero routine: sound state 1 into `$0E59`.
            Site(effect: .stallHorn, start: 0x3014, stub: 0x3019, before: 2 + 4, after: 6),
            // $3577 in groundContact: state 8 into `$0E59`.
            Site(effect: .touchdown, start: 0x3577, stub: 0x357C, before: 2 + 4, after: 6),
            // $3F29: state 5 into `$0E59` through a branch to the shared store, then the return;
            // and the middle and inner variants.
            Site(effect: .outerMarker, start: 0x3F29, stub: 0x3F37, before: 2 + 3 + 4, after: 6),
            Site(effect: .middleMarker, start: 0x3F32, stub: 0x3F37, before: 2 + 4, after: 6),
            Site(effect: .innerMarker, start: 0x3F20, stub: 0x3F37, before: 2 + 3 + 4, after: 6),
            // $2C15 in fireGuns: state 3 into `$0E59`, then the effect routine $CCD1.
            Site(effect: .gun, start: 0x2C15, stub: 0x2C1D, before: 2 + 4 + 6, after: 6),
            // $2B88 in keyDropBomb: a call to the effect routine $CD04.
            Site(effect: .bombRelease, start: 0x2B88, stub: 0x2B8B, before: 6, after: 6),
            // $356D in groundContact: a call to $CC68.
            Site(effect: .crash, start: 0x356D, stub: 0x3570, before: 6, after: 6),
            // $F974, before the crash/splash message: state 2 into `$0E59`, then $CC68.
            Site(effect: .crash, start: 0xF974, stub: 0xF97C, before: 2 + 4 + 6, after: 6),
        ]
        var rng = TestRandom(seed: 0x2C15)
        for site in sites {
            for n in 0..<20 {
                var ram = Self.randomized(&rng)
                ram[0x0E59] = rng.byte() % 11
                let o = OriginalSound(ram: ram, returnAt: [site.stub]), p = PortSound(ram: ram, returnAt: [site.stub])
                let ro = o.call(site.start)
                let rp = p.call(overhead: site.after) { m in
                    m.charge(site.before)
                    m.triggerEffect(site.effect)
                }
                if !expectSame(ro, rp, o.ram, p.ram, String(format: "%@ at $%04X case %d", "\(site.effect)", site.start, n)) {
                    break
                }
            }
        }
    }

    @Test func soundTickRandomStatesIncludingWrappedIndexes() throws {
        // Random sound bytes in every combination, and states $80-$8A, which index the table like
        // 0-10 because the index doubling drops bit 7 (no game code stores them; the port must
        // still agree).
        var rng = TestRandom(seed: 0xCC43)
        var failures = 0
        for n in 0..<1500 {
            var ram = Self.randomized(&rng)
            ram[0x0E59] = (rng.byte() % 11) | (n % 2 == 0 ? 0x00 : 0x80)
            ram[0x08D3] = n % 5 == 0 ? 0x00 : rng.byte()
            // Mostly even skip masks, so most cases dispatch.
            ram[0x0E5C] = n % 3 == 0 ? rng.byte() : rng.byte() & 0xFE
            ram[0x09BE] = rng.byte()
            let o = OriginalSound(ram: ram), p = PortSound(ram: ram)
            if !expectSame(o.call(0xCC16), p.call { $0.soundTick() }, o.ram, p.ram,
                           String(format: "case %d state $%02X", n, ram[0x0E59])) {
                failures += 1
                if failures > 5 { return }
            }
        }
    }

    // MARK: Interrupt-equivalent points

    /// The bytes the sound code writes (and the enable flag), watched at every instruction boundary.
    private static let watched = soundBytes + [0x08D3, 0x0E52, 0x0E54, 0x0E59, 0xCC44, 0xCC45]

    /// The machine state at one instruction boundary.
    private struct Boundary: Equatable, CustomStringConvertible {
        var offset: UInt64
        var stores: Int
        var bytes: [UInt8]
        var description: String {
            "+\(offset) stores \(stores) [" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ") + "]"
        }
    }

    /// Runs one call on both sides with the port's event handler firing at every `charge`, and
    /// requires each of those points to be an instruction boundary of the original at the same cycle
    /// offset, with the same watched bytes and the same SID stores so far. That is what lets the
    /// scheduler run the frame IRQ's work from `charge`: the handler always sees a state at which the
    /// C64 could have taken the interrupt.
    @discardableResult
    private static func expectBoundaries(_ ram: [UInt8], _ address: UInt16, returnAt: [Int] = [],
                                         _ what: @autoclosure () -> String, _ body: (Machine) -> Void,
                                         sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let o = OriginalSound(ram: ram, returnAt: returnAt)
        var original: [UInt64: Boundary] = [:]
        o.call(address) { offset, stores in
            original[offset] = Boundary(offset: offset, stores: stores, bytes: watched.map { o.peek($0) })
        }
        // Everything the original wrote is watched, so the comparison has no blind spot.
        let unwatched = Original.differences(ram, o.ram, ignoring: ignored)
            .filter { !watched.contains($0) && !returnAt.contains($0) }

        let p = PortSound(ram: ram, returnAt: returnAt)
        let start = p.machine.clock.cycles, seen = p.machine.io.sidWrites.count
        final class Points { var list: [Boundary] = [] }
        let points = Points()
        p.machine.nextEventCycle = 0
        p.machine.eventHandler = { m in
            points.list.append(Boundary(offset: m.clock.cycles - start, stores: m.io.sidWrites.count - seen,
                                        bytes: watched.map { m[$0] }))
        }
        body(p.machine)
        p.machine.eventHandler = nil
        p.machine.nextEventCycle = .max

        let bad = points.list.filter { original[$0.offset] != $0 }
        let ok = unwatched.isEmpty && !points.list.isEmpty && bad.isEmpty
        if !ok {
            let near = bad.first.map { b in original.values.filter { $0.offset + 12 >= b.offset && $0.offset <= b.offset + 12 } }
            Issue.record("""
                \(what()): \(points.list.count) event points; unwatched writes \(hex(unwatched))
                  port points not at an original boundary: \(bad.prefix(3))
                  original boundaries nearby: \((near ?? []).sorted { $0.offset < $1.offset })
                """, sourceLocation: sourceLocation)
        }
        return ok
    }

    @Test func eventPointsAreInstructionBoundaries() throws {
        var rng = TestRandom(seed: 0x01F0)
        var failures = 0
        func check(_ ram: [UInt8], _ address: UInt16, returnAt: [Int] = [], _ what: String,
                   _ body: (Machine) -> Void) {
            if failures <= 5 && !Self.expectBoundaries(ram, address, returnAt: returnAt, what, body) { failures += 1 }
        }
        // $CC16 in every state, sound on and off, skipped or not.
        for state in 0...10 {
            for enable: UInt8 in [0, 1] {
                for skip: UInt8 in [0, 1] {
                    for whistleHi: UInt8 in state == 10 ? [0x2F, 0x30] : [rng.byte()] {
                        var ram = Self.randomized(&rng)
                        ram[0x0E59] = UInt8(state)
                        ram[0x08D3] = enable
                        ram[0x0E5C] = skip
                        ram[0x0E7E] = whistleHi
                        check(ram, 0xCC16, "tick state \(state) enable \(enable) skip \(skip)") { $0.soundTick() }
                    }
                }
            }
        }
        // Every handler on its own.
        for (address, port) in Self.handlers {
            for n in 0..<4 {
                var ram = Self.randomized(&rng)
                if address == 0xCE37 { ram[0x0E7E] = n % 2 == 0 ? 0x2F : 0x30 }
                check(ram, address, String(format: "handler $%04X case %d", address, n), port)
            }
        }
        // The pattern player, with and without a step, and the step on its own.
        for n in 0..<16 {
            var ram = Self.randomized(&rng)
            ram[0x0E5B] = n % 2 == 0 ? 1 : 5
            ram[0x2308] = n % 4 < 2 ? 0x00 : 0x03
            check(ram, 0x22C8, returnAt: [0x22CD], "frame case \(n)") { $0.patternPlayerFrame() }
            check(ram, 0x230A, returnAt: [0x22CD], "step case \(n)") { $0.patternStep() }
        }
        // The engine slew up, down, at the target and snapping.
        let pairs: [(UInt8, UInt8)] = [(0x10, 0x10), (0x0D, 0x32), (0x32, 0x0D), (0x01, 0x00), (0xF5, 0x10), (0xFE, 0xFF)]
        for (e, t) in pairs + (0..<20).map({ _ in (rng.byte(), rng.byte()) }) {
            var ram = Self.randomized(&rng)
            ram[0x09BE] = e
            ram[0x0E58] = t
            check(ram, 0xE500, "slew E=\(e) T=\(t)") { $0.engineSoundSlew() }
        }
        // The bomb sweep, running and stopped.
        for v: UInt16 in [0x4A38, 0x00EF, 0x00F0, 0x8000, 0xFF00] {
            var ram = Self.randomized(&rng)
            ram[0x0E7D] = UInt8(v & 0xFF)
            ram[0x0E7E] = UInt8(v >> 8)
            check(ram, 0x2381, returnAt: [0x239B], String(format: "sweep $%04X", v)) { $0.bombWhistleSweep() }
        }
        // The clear at boot.
        check(try #require(Original.data).coldMemory, 0xAB58, "sidInit") { $0.sidInit() }
    }

    // MARK: Random schedules

    /// Long random runs on both sides: effects armed at random (the held ones re-armed while their
    /// condition lasts), SOUND switched off and on, key waits ($2250: silence, a call to $CC16,
    /// no 1 Hz ticks until the key comes), engine targets changing, and the 1 Hz tick drifting
    /// against the 10 Hz grid as the TOD seconds do.
    @Test(arguments: 0..<8)
    func randomSchedules(seed: Int) throws {
        var rng = TestRandom(seed: 0x5EED_0000 &+ UInt64(seed))
        var ram = Self.randomized(&rng)
        ram[0x08D3] = rng.byte() & 1
        ram[0x0E59] = rng.byte() % 11
        let o = OriginalSound(ram: ram, returnAt: [0x22CD, 0x239B]), p = PortSound(ram: ram, returnAt: [0x22CD, 0x239B])
        let todOffset = Double(rng.byte())
        var lastSecond = -1
        var held: SoundDriver.Effect?
        var heldUntil = 0
        var keyWaitUntil = -1
        var savedEnable: UInt8 = 0
        func compare(_ frame: Int) -> Bool {
            let common = min(o.log.count, p.log.count)
            let mismatch = (0..<common).first { o.log[$0] != p.log[$0] } ?? (o.log.count == p.log.count ? nil : common)
            let diff = Original.differences(o.ram, p.ram, ignoring: ignored)
            if mismatch == nil && diff.isEmpty { return true }
            let at = mismatch ?? 0
            Issue.record("""
                seed \(seed) frame \(frame): memory differs at \(hex(diff)); first SID mismatch at store \(mismatch.map(String.init) ?? "-")
                  original: \(o.log[max(0, at - 2)..<min(o.log.count, at + 3)])
                  port:     \(p.log[max(0, at - 2)..<min(p.log.count, at + 3)])
                """)
            return false
        }
        for frame in 0..<3600 {
            switch rng.byte() {
            case 0...2:
                let effect = SoundDriver.Effect.allCases[Int(rng.byte()) % SoundDriver.Effect.allCases.count]
                Self.arm(effect, o, p)
                if Self.held.contains(effect) { held = effect; heldUntil = frame + Int(rng.byte()) * 2 }
            case 3 where keyWaitUntil < frame:
                // The editor's SOUND setting copied on exit.
                let v = rng.byte() & 1
                o.poke(0x08D3, v); p.poke(0x08D3, v)
            case 4 where keyWaitUntil < frame:
                savedEnable = o.peek(0x08D3)
                o.poke(0x08D3, 0); p.poke(0x08D3, 0)
                o.call(0xCC16)
                p.call { $0.soundTick() }
                keyWaitUntil = frame + Int(rng.byte())
            case 5...7:
                let t = rng.byte()
                o.poke(0x0E58, t); p.poke(0x0E58, t)
            default:
                break
            }
            if let h = held, frame < heldUntil, frame % 12 == 0 { Self.arm(h, o, p) }
            if frame == keyWaitUntil { o.poke(0x08D3, savedEnable); p.poke(0x08D3, savedEnable) }
            o.call(0x22C8)
            p.call(overhead: 6) { $0.patternPlayerFrame() }
            if frame % 6 == 0 {
                o.call(0xE500)
                p.call { $0.engineSoundSlew() }
                o.call(0x2381)
                p.call(overhead: 6) { $0.bombWhistleSweep() }
                let second = Int((Double(frame) + todOffset) / VirtualClock.framesPerSecond)
                if second != lastSecond {
                    lastSecond = second
                    // Suspended during a key wait ($08CC is set), as at $23D8.
                    if keyWaitUntil < frame {
                        o.call(0xCC16)
                        p.call { $0.soundTick() }
                    }
                }
            }
            if frame % 600 == 599 && !compare(frame) { return }
        }
        #expect(o.log.count > 1000, "the schedule produced \(o.log.count) SID stores")
    }

    // MARK: WAV sanity renders

    @Test func renderEffectsToWAV() throws {
        // Plays each effect through the port and C64Kit's SID model into out/sound/*.wav (git-ignored),
        // and checks that the result is not silent and that the markers sound at 400/1300/3000 Hz.
        let dir = Original.repoRoot.appendingPathComponent("out/sound", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sampleRate = 44_100.0
        for effect in SoundDriver.Effect.allCases where effect != .reset && effect != .bombWait {
            var ram = Self.base
            ram[0x08D3] = 1
            ram[0x0E5C] = 0
            ram[0x0E58] = 0x20     // 1600 RPM
            ram[0x09BE] = 0x20
            let m = Machine(memory: ram)
            m.sidInit()
            let seconds = 8
            let frames = Int(Double(seconds) * VirtualClock.framesPerSecond)
            let armFrame = 30
            var second = 0
            for frame in 0..<frames {
                m.clock.cycles = max(m.clock.cycles, UInt64(frame) * VirtualClock.cyclesPerFrame)
                if frame == armFrame || (Self.held.contains(effect) && frame > armFrame && frame < frames - 90
                                         && frame % 12 == 0) {
                    m.triggerEffect(effect)
                }
                m.patternPlayerFrame()
                if frame % 6 == 0 {
                    m.engineSoundSlew()
                    m.bombWhistleSweep()
                    let now = Int(m.clock.seconds)
                    if now != second {
                        second = now
                        m.soundTick()
                    }
                }
            }
            let end = UInt64(frames) * VirtualClock.cyclesPerFrame
            let log = m.io.sidWrites.map { SIDWrite(cycle: $0.cycle, reg: Int($0.reg), value: $0.value) }
            let samples = SIDStream.render(log: log, from: 0, to: end, sampleRate: sampleRate)
            try WAVWriter.write(samples: samples, sampleRate: Int(sampleRate),
                                to: dir.appendingPathComponent("\(effect).wav"))
            // The effect window: from the trigger to two seconds later.
            let window = Array(samples[Int(Double(armFrame + 70) / VirtualClock.framesPerSecond * sampleRate)...]
                .prefix(Int(sampleRate * 2)))
            let rms = (window.reduce(0) { $0 + Double($1) * Double($1) } / Double(window.count)).squareRoot()
            #expect(rms > 0.005, "\(effect) is silent (rms \(rms))")
            let marker: Double? = [.outerMarker: 400, .middleMarker: 1300, .innerMarker: 3000][effect]
            if let f = marker {
                let at = goertzel(window, f, sampleRate)
                let below = goertzel(window, f * 0.8, sampleRate), above = goertzel(window, f * 1.25, sampleRate)
                #expect(at > 10 * max(below, above), "\(effect): \(at) vs \(below) / \(above)")
            }
        }
    }

    /// Power of `x` at frequency `f` (Goertzel).
    private func goertzel(_ x: [Float], _ f: Double, _ rate: Double) -> Double {
        let w = 2 * Double.pi * f / rate, c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s = Double(v) + c * s1 - s2
            s2 = s1; s1 = s
        }
        return s1 * s1 + s2 * s2 - c * s1 * s2
    }
}
