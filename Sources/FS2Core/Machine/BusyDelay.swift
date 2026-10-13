/// The busy-wait delay $F25B (end of the ATIS teletype; the crash/splash message).
extension Machine {
    /// $F25B: a pure delay of Y passes (Y = 0 means 256), each 255 X steps of an inner loop that
    /// counts A down from 255 by subtraction. Each pass takes 456,711 cycles (the last one
    /// 456,710), plus the return: Y passes cost Y × 456,711 + 5 cycles (Y = 4, the ATIS end:
    /// 1,826,849; Y = 5, the crash message: 2,283,560). The time is charged one X step (1,791
    /// cycles) at a time, so the clock and its events keep running through the wait, as the
    /// raster IRQ did on the C64. Leaves A = X = Y = 0 and the carry set; no memory is touched.
    public func busyDelay(y: UInt8) {
        let passes = y == 0 ? 256 : Int(y)
        for pass in 0..<passes {
            charge(2)                                     // set up the X counter
            // One X step (the full A countdown plus the X decrement): 1,791 cycles, the last 1,790.
            for x in 0..<255 { charge(x < 254 ? 1791 : 1790) }
            charge(pass < passes - 1 ? 5 : 4)     // the Y step; the last one falls through
        }
        charge(6)                                         // return
    }
}
