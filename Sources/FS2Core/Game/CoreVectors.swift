/// The core vector table $2000-$2047: 24 three-byte jumps, a stable ABI the overlays and scenery
/// data use (op 0A native calls name targets by address). `callCoreVector` maps each vector to its
/// port.
extension Machine {
    /// Runs the port of the routine behind the core vector at `vector` ($2000, $2003, ..., $2045)
    /// with the registers the ABI passes, charging the vector's 3-cycle jump (the caller charges
    /// its call). Returns the registers the routine leaves where callers use them (A of $2003 and
    /// $2027; A and the carry of $203C), or nil for a vector whose target is not ported ($203F,
    /// text mode $2673: the editor unit's) or that is no vector.
    ///
    /// The vectors give the overlays the services they share: the keyboard (`waitForKey` with A
    /// out, `dequeueKey` with A and the carry out) and the 10 Hz poll (`pollTick`); the display
    /// setup (`displayInit`; the text-mode swap is the editor unit's); the five overlay loads at
    /// $2015-$2021 (`loadOverlay`: cold start, editor, war, flight, database info) and the disk
    /// helpers (`loadBlockCached`, `cacheHelper`); the aircraft state services
    /// (`setAltitudeFromEditor`, `setMagnetos(A, label: X)`, `slewAux`, `serviceAircraft`,
    /// `updateFlaps(A)`); the four control indicator updates at $2024-$202D (A out of $2027); and
    /// the clock, distance and number helpers (`drawClock`, `stationDistance`,
    /// `format3Digits(field: A + 256·X)`). The switch below is the vector-to-port map.
    public func callCoreVector(_ vector: UInt16, _ regs: CPURegisters = CPURegisters()) -> CPURegisters? {
        var out = CPURegisters()
        switch vector {
        case 0x2000: charge(3); drawClock()
        case 0x2003: charge(3); out.a = waitForKey()
        case 0x2006: charge(3); setAltitudeFromEditor()
        case 0x2009: charge(3); setMagnetos(regs.a, label: regs.x)
        case 0x200C: charge(3); slewAux()
        case 0x200F: charge(3); serviceAircraft()
        case 0x2012: charge(3); pollTick()
        case 0x2015, 0x2018, 0x201B, 0x201E, 0x2021:
            charge(3)
            loadOverlay(Overlay(rawValue: Int(vector - 0x2015) / 3)!)
        case 0x2024: charge(3); updateElevatorIndicator()
        case 0x2027: charge(3); out.a = updateThrottleIndicator()
        case 0x202A: charge(3); updateRudderIndicator()
        case 0x202D: charge(3); updateAileronIndicator()
        case 0x2030: charge(3); stationDistance()
        case 0x2033: charge(3); format3Digits(field: UInt16(regs.x) << 8 | UInt16(regs.a))
        case 0x2036: charge(3); loadBlockCached()
        case 0x2039: charge(3); cacheHelper()
        case 0x203C:
            charge(3)
            let r = dequeueKey()
            out.a = r.code
            out.carry = r.carry
        case 0x2042: charge(3); displayInit()
        case 0x2045: charge(3); updateFlaps(regs.a)
        default: return nil
        }
        return out
    }
}
