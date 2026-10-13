/// The horizon pass $83A4-$840E (vector $8003): the glue that runs a horizon display list through
/// the interpreter with line drawing disabled to find where the horizon crosses the window, then
/// falls into the sky/ground fill (`horizonFill`, the renderer unit's).
extension Machine {
    /// $0AD0: four 16-byte horizon lists (ground moveto/lineto far out, END), one per yaw
    /// quadrant.
    public static let horizonLists = 0x0AD0

    /// $83A4 (vector $8003): the horizon pass.
    ///
    /// 1. `$35/$36` = the display-list PC (this also invalidates op 07/24's y cache in `$35/$36`),
    ///    the opcode byte of the line driver's call to $9A1D at $8B89 is patched to $0D, which
    ///    turns the call into a harmless read (no drawing), and `$EC` = $FF (no horizon yet).
    /// 2. PC = $0AD0 + (((`$77` + $20) >> 2) & $F0), that is $0AD0 + 16 · ((`$77` + $20) >> 6)
    ///    (8-bit sum): the list of the yaw quadrant.
    /// 3. `$66/$67` and `$6A/$6B` are saved in `$02-$05` and zeroed with the ground base high
    ///    words `$24/$25`, `$27/$28`, `$2A/$2B` (the low bytes `$26`, `$29`, `$2C` keep their
    ///    values): the eye at the origin, at its height.
    /// 4. The list runs from $8742; the line driver leaves the visible part of the horizon in
    ///    `$EB-$EE`.
    /// 5. `$66/$67`, `$6A/$6B`, $8B89 (the call opcode, $20) and the PC are restored (the base
    ///    is not).
    /// 6. Falls into `horizonFill` ($840F), which charges through the return of $83A4.
    public func horizonPass() throws(Scenery.Fault) {
        let m = mem
        m[0x35] = m[0x8B]
        m[0x36] = m[0x8C]
        m[Scenery.lineDrawOpcode] = 0x0D
        m[0xEC] = 0xFF
        let list = Self.horizonLists + Int(((m[0x77] &+ 0x20) >> 2) & 0xF0)
        m[0x8B] = UInt8(list & 0xFF)
        m[0x8C] = UInt8(list >> 8)
        m[0x02] = m[0x66]; m[0x03] = m[0x67]
        m[0x04] = m[0x6A]; m[0x05] = m[0x6B]
        m[0x66] = 0; m[0x67] = 0; m[0x6A] = 0; m[0x6B] = 0
        m[0x24] = 0; m[0x25] = 0; m[0x27] = 0; m[0x28] = 0; m[0x2A] = 0; m[0x2B] = 0
        // Steps 1-3 and the call into the interpreter at $8742.
        charge(112)
        try dlInterpreter()
        m[0x66] = m[0x02]; m[0x67] = m[0x03]
        m[0x6A] = m[0x04]; m[0x6B] = m[0x05]
        m[Scenery.lineDrawOpcode] = 0x20
        m[0x8B] = m[0x35]
        m[0x8C] = m[0x36]
        charge(42)                             // step 5
        horizonFill()
    }
}
