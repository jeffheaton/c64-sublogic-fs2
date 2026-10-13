/// The ADSR envelope of one SID voice, stepped the way the 6581 steps it.
///
/// The chip keeps an 8-bit level and a 15-bit rate counter that advances once per cycle. The
/// counter is compared with a period picked by the current phase's 4-bit rate; when they match,
/// the counter starts over and the level may take one step. Attack steps on every match. Decay and
/// release go through a second divider that needs 1, 2, 4, 8, 16 or 30 matches per step, switched
/// as the level passes 93, 54, 26, 14 and 6 on its way down: a piecewise approximation of an
/// exponential fall, which is why the data sheet lists decay and release times three times the
/// attack times for the same rate.
///
/// Behaviors of the chip that follow from this design and are kept:
/// - Neither a gate change nor a rate write clears the rate counter. When the new period is below
///   the counter, the counter first runs through the rest of its 32,767-state cycle (the 15-bit
///   counter is a shift register with one unused state), delaying the next step by up to 32 ms.
/// - Decay stops when the level *equals* the sustain level (the sustain nibble times $11), so a
///   sustain level raised above the current level does not hold it.
/// - A level that reaches 0 stays there until the next gate-on, and the 8-bit level is free to
///   wrap: an attack that starts at $FF steps to $00 (and stays), a release that starts at $00
///   after a gate-on steps to $FF.
///
/// To keep the per-cycle cost at one decrement, the rate counter is stored as the number of cycles
/// left until its next match; the counter itself is rebuilt only when the period changes.
struct VoiceEnvelope {
    /// `decay` includes holding at the sustain level once the level gets there.
    enum Phase: UInt8 { case attack, decay, release }

    /// Cycles between rate-counter matches for the 16 rate values, as measured on the chip. The
    /// data sheet's attack times (2 ms ... 8 s) are 255 steps of these at about 1 MHz.
    static let periods: [Int32] = [9, 32, 63, 95, 149, 220, 267, 313, 392, 977, 1954, 3126, 3907, 11_720, 19_532, 31_251]

    /// States in the rate counter's cycle.
    static let counterCycle: Int32 = 0x7FFF

    private(set) var level: UInt8 = 0
    private(set) var phase = Phase.release
    /// Set when the level reaches 0; only a gate-on releases it.
    private var stuckAtZero = true
    private var gate = false
    private var attackRate = 0, decayRate = 0, releaseRate = 0
    private var sustainLevel: UInt8 = 0
    /// The current phase's period, and the cycles left until the rate counter reaches it (1...32767).
    private var period = VoiceEnvelope.periods[0]
    private var untilMatch = VoiceEnvelope.periods[0]
    /// Matches needed per decay/release step, and matches counted toward the next one.
    private var divider: UInt8 = 1
    private var dividerCount: UInt8 = 0

    /// The rate counter's current value, 0...32766.
    var rateCounter: Int32 {
        let c = period - untilMatch
        return c >= 0 ? c : c + Self.counterCycle
    }

    /// Advances one cycle.
    @inline(__always)
    mutating func clock() {
        untilMatch &-= 1
        if untilMatch == 0 {
            untilMatch = period
            match()
        }
    }

    /// The control register's gate bit. Only an edge does anything.
    mutating func setGate(_ on: Bool) {
        guard on != gate else { return }
        gate = on
        if on {
            phase = .attack
            stuckAtZero = false
            retune(to: Self.periods[attackRate])
        } else {
            phase = .release
            retune(to: Self.periods[releaseRate])
        }
    }

    /// Register 5 of the voice: attack in the high nibble, decay in the low one.
    mutating func setAttackDecay(_ value: UInt8) {
        attackRate = Int(value >> 4)
        decayRate = Int(value & 0x0F)
        switch phase {
        case .attack: retune(to: Self.periods[attackRate])
        case .decay: retune(to: Self.periods[decayRate])
        case .release: break
        }
    }

    /// Register 6 of the voice: sustain level in the high nibble, release in the low one.
    mutating func setSustainRelease(_ value: UInt8) {
        sustainLevel = (value >> 4) * 0x11
        releaseRate = Int(value & 0x0F)
        if phase == .release { retune(to: Self.periods[releaseRate]) }
    }

    /// Switches to a new period without touching the counter: the next match is when the counter
    /// next equals `newPeriod`, possibly after wrapping around.
    private mutating func retune(to newPeriod: Int32) {
        let counter = rateCounter
        period = newPeriod
        untilMatch = counter < newPeriod ? newPeriod - counter : Self.counterCycle - counter + newPeriod
    }

    /// The rate counter matched its period.
    @inline(never)
    private mutating func match() {
        if phase != .attack {
            dividerCount &+= 1
            if dividerCount < divider { return }
        }
        dividerCount = 0
        if stuckAtZero { return }
        switch phase {
        case .attack:
            level &+= 1
            if level == 0xFF {
                phase = .decay
                retune(to: Self.periods[decayRate])
            }
        case .decay:
            if level == sustainLevel { return }
            level &-= 1
        case .release:
            level &-= 1
        }
        switch level {
        case 0xFF: divider = 1
        case 93: divider = 2
        case 54: divider = 4
        case 26: divider = 8
        case 14: divider = 16
        case 6: divider = 30
        case 0:
            divider = 1
            stuckAtZero = true
        default: break
        }
    }
}
