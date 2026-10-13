/// A MOS 6526 CIA, evaluated lazily against the CPU cycle count: two 16-bit timers (φ2 or timer-A
/// cascade), the time-of-day clock, interrupt control, and the two ports (whose meaning the
/// machine supplies through `readPortA`/`readPortB`).
final class CIA {
    var pra: UInt8 = 0xFF, prb: UInt8 = 0xFF, ddra: UInt8 = 0, ddrb: UInt8 = 0

    struct Timer {
        var counter: UInt16 = 0xFFFF
        var latch: UInt16 = 0xFFFF
        var running = false
        var oneShot = false
        var countsTimerA = false   // timer B only: count timer A underflows
        var control: UInt8 = 0
    }
    var timerA = Timer()
    var timerB = Timer()
    var lastUpdate: UInt64 = 0

    var icrFlags: UInt8 = 0
    var icrMask: UInt8 = 0

    // Time of day, BCD as in the registers.
    var todTenths: UInt8 = 0, todSeconds: UInt8 = 0, todMinutes: UInt8 = 0, todHours: UInt8 = 0x01
    var todHalted = false
    var todLatched: [UInt8]?
    var todNextTick: Double = 0
    /// Mains frequency feeding the TOD input (NTSC machines: 60 Hz).
    let mainsHz: Double = 60
    let clockHz: Double = 1_022_727.14
    var mainsTicks = 0

    var readPortA: (CIA) -> UInt8 = { $0.pra | ~$0.ddra }
    var readPortB: (CIA) -> UInt8 = { $0.prb | ~$0.ddrb }
    var portAWritten: (CIA) -> Void = { _ in }

    var interruptLine: Bool { icrFlags & icrMask & 0x1F != 0 }

    // MARK: Timers

    func update(_ now: UInt64) {
        guard now > lastUpdate else { return }
        var elapsed = now - lastUpdate
        lastUpdate = now
        let underflowsA = step(&timerA, cycles: elapsed, pulses: nil)
        if underflowsA > 0 { icrFlags |= 0x01 }
        if timerB.countsTimerA {
            if step(&timerB, cycles: 0, pulses: underflowsA) > 0 { icrFlags |= 0x02 }
        } else if step(&timerB, cycles: elapsed, pulses: nil) > 0 {
            icrFlags |= 0x02
        }
        elapsed = 0
        updateTOD(now)
    }

    /// Counts a timer down; returns the number of underflows.
    private func step(_ t: inout Timer, cycles: UInt64, pulses: Int?) -> Int {
        guard t.running else { return 0 }
        var remaining = pulses.map(UInt64.init) ?? cycles
        var underflows = 0
        while remaining > 0 {
            if remaining <= UInt64(t.counter) {
                t.counter -= UInt16(remaining)
                remaining = 0
            } else {
                remaining -= UInt64(t.counter) + 1
                underflows += 1
                t.counter = t.latch
                if t.oneShot {
                    t.running = false
                    t.control &= ~0x01
                    break
                }
                if t.latch == 0 && remaining > 0 { underflows += Int(remaining); remaining = 0 }
            }
        }
        return underflows
    }

    // MARK: Time of day

    private func cyclesPerMainsTick() -> Double { clockHz / mainsHz }

    func updateTOD(_ now: UInt64) {
        if todNextTick == 0 { todNextTick = Double(now) + cyclesPerMainsTick() }
        let ticksPerTenth = timerA.control & 0x80 != 0 ? 5 : 6
        while Double(now) >= todNextTick {
            todNextTick += cyclesPerMainsTick()
            guard !todHalted else { continue }
            mainsTicks += 1
            if mainsTicks >= ticksPerTenth {
                mainsTicks = 0
                advanceTenth()
            }
        }
    }

    private static func bcdIncrement(_ v: UInt8) -> UInt8 {
        var lo = (v & 0x0F) + 1, hi = v >> 4
        if lo > 9 { lo = 0; hi += 1 }
        return hi << 4 | lo
    }

    private func advanceTenth() {
        todTenths += 1
        guard todTenths > 9 else { return }
        todTenths = 0
        todSeconds = Self.bcdIncrement(todSeconds)
        guard todSeconds == 0x60 else { return }
        todSeconds = 0
        todMinutes = Self.bcdIncrement(todMinutes)
        guard todMinutes == 0x60 else { return }
        todMinutes = 0
        let pm = todHours & 0x80
        var h = Self.bcdIncrement(todHours & 0x1F)
        if h == 0x12 { h |= pm ^ 0x80 } else if h == 0x13 { h = 0x01 | pm } else { h |= pm }
        todHours = h
    }

    // MARK: Registers

    func read(_ reg: Int, now: UInt64) -> UInt8 {
        update(now)
        switch reg & 0x0F {
        case 0x0: return readPortA(self)
        case 0x1: return readPortB(self)
        case 0x2: return ddra
        case 0x3: return ddrb
        case 0x4: return UInt8(timerA.counter & 0xFF)
        case 0x5: return UInt8(timerA.counter >> 8)
        case 0x6: return UInt8(timerB.counter & 0xFF)
        case 0x7: return UInt8(timerB.counter >> 8)
        case 0x8:
            let v = todLatched?[3] ?? todTenths
            todLatched = nil
            return v
        case 0x9: return todLatched?[2] ?? todSeconds
        case 0xA: return todLatched?[1] ?? todMinutes
        case 0xB:
            if todLatched == nil { todLatched = [todHours, todMinutes, todSeconds, todTenths] }
            return todLatched![0]
        case 0xD:
            let v = icrFlags | (interruptLine ? 0x80 : 0)
            icrFlags = 0
            return v
        case 0xE: return timerA.control
        case 0xF: return timerB.control
        default: return 0xFF
        }
    }

    func write(_ reg: Int, _ value: UInt8, now: UInt64) {
        update(now)
        switch reg & 0x0F {
        case 0x0: pra = value; portAWritten(self)
        case 0x1: prb = value
        case 0x2: ddra = value; portAWritten(self)
        case 0x3: ddrb = value
        case 0x4: timerA.latch = timerA.latch & 0xFF00 | UInt16(value)
        case 0x5:
            timerA.latch = timerA.latch & 0x00FF | UInt16(value) << 8
            if !timerA.running { timerA.counter = timerA.latch }
        case 0x6: timerB.latch = timerB.latch & 0xFF00 | UInt16(value)
        case 0x7:
            timerB.latch = timerB.latch & 0x00FF | UInt16(value) << 8
            if !timerB.running { timerB.counter = timerB.latch }
        case 0x8:
            if timerB.control & 0x80 == 0 { todTenths = value & 0x0F; todHalted = false }
        case 0x9: if timerB.control & 0x80 == 0 { todSeconds = value & 0x7F }
        case 0xA: if timerB.control & 0x80 == 0 { todMinutes = value & 0x7F }
        case 0xB: if timerB.control & 0x80 == 0 { todHours = value & 0x9F; todHalted = true }
        case 0xD:
            if value & 0x80 != 0 { icrMask |= value & 0x1F } else { icrMask &= ~(value & 0x1F) }
        case 0xE:
            timerA.control = value & ~0x10
            timerA.running = value & 0x01 != 0
            timerA.oneShot = value & 0x08 != 0
            if value & 0x10 != 0 { timerA.counter = timerA.latch }
        case 0xF:
            timerB.control = value & ~0x10
            timerB.running = value & 0x01 != 0
            timerB.oneShot = value & 0x08 != 0
            timerB.countsTimerA = value & 0x60 == 0x40
            if value & 0x10 != 0 { timerB.counter = timerB.latch }
        default: break
        }
    }
}
