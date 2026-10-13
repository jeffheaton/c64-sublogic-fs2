/// The joystick actions and the aileron/rudder auto-centering ($2688-$26F8), run by the 5 Hz half
/// of the 10 Hz tick ($23BA-$23CA) when not paused: `joystickAction` when either latch
/// (`$0E6E`/`$0E6F`) is nonzero, then `autoCenter` while `$0E7A` is set.
extension Machine {
    // MARK: joystickAction ($2688)

    /// $2688: acts on the latched ports, one bit at a time from bit 0, as if the keys were pressed:
    ///
    /// - Port 1 (`$0E6F`, the yoke): up → `$091C` = 0 and T (`keyElevatorDown`); down →
    ///   `$091C` = 0 and B (`keyElevatorUp`), so a stick never gets the quick-repeat step of 16;
    ///   left → F (`keyAileronLeft`) and `$0E78` = 3; right → H (`keyAileronRight`) and `$0E78` = 3;
    ///   fire → '5' (`keyViewSelect`).
    /// - Port 2 (`$0E6E`): up → `throttleUp`; down → `throttleDown`; fire → `fireGuns`.
    ///
    /// Then both latches are cleared and `$0E7A` = 1. A is saved around every call except
    /// `throttleDown`: the fire test after it shifts the A that `throttleDown` returns (the last
    /// bitmap byte the throttle marker XORed, or the negative throttle - 8), so with port 2 down
    /// and fire together the guns fire only when bit 2 of that byte is set (an original quirk,
    /// kept). The view key can capture T/B/F/H when `$FC` = 1 (the handlers' `$2E84`).
    /// Clobbers A, X, Y.
    public func joystickAction() {
        let m = mem
        let R = Input.RAM.self
        var a = m[R.joyPort1]
        var c = 4
        // Bit 0, up: T.
        c += 2
        if a & 1 == 0 { c += 3 } else {
            m[R.quickRepeatWindow] = 0
            charge(c + 17)                                  // save A, close the quick-repeat window
            keyElevatorDown()
            c = 4                                           // restore A
        }
        a >>= 1
        // Bit 1, down: B.
        c += 2
        if a & 1 == 0 { c += 3 } else {
            m[R.quickRepeatWindow] = 0
            charge(c + 17)                                  // save A, close the quick-repeat window
            keyElevatorUp()
            c = 4
        }
        a >>= 1
        // Bit 2, left: F.
        c += 2
        if a & 1 == 0 { c += 3 } else {
            charge(c + 11)                                  // save A
            keyAileronLeft()
            m[R.autoCenterCounter] = 3
            c = 10                                          // auto-center countdown, restore A
        }
        a >>= 1
        // Bit 3, right: H.
        c += 2
        if a & 1 == 0 { c += 3 } else {
            charge(c + 11)                                  // save A
            keyAileronRight()
            m[R.autoCenterCounter] = 3
            c = 10
        }
        a >>= 1
        // Bit 4, fire: '5'.
        c += 2
        if a & 1 == 0 { c += 3 } else {
            charge(c + 8)
            keyViewSelect()
            c = 0
        }
        // $26C5: port 2.
        a = m[R.joyPort2]
        c += 6
        if a & 1 == 0 { c += 3 } else {
            charge(c + 11)                                  // save A
            throttleUp()
            c = 4                                           // restore A
        }
        a >>= 1
        c += 2
        if a & 1 == 0 { c += 3; a >>= 1 } else {
            charge(c + 8)                                   // A is not saved around this one
            a = throttleDown()
            c = 0
        }
        // $26D6: the fire test reads bit 2 of A (the fire bit, unless throttleDown replaced A).
        c += 6
        if a & 0x04 == 0 { c += 3 } else {
            charge(c + 8)
            fireGuns()
            c = 0
        }
        m[R.joyPort2] = 0
        m[R.joyPort1] = 0
        m[R.joystickUsed] = 1
        charge(c + 22)                                      // clear both latches, mark the stick used
    }

    // MARK: autoCenter ($26EC)

    /// $26EC: halves the countdown `$0E78` and returns while the bit shifted out is 1. When the
    /// counter has run out, `$0E7A` is halved too (done) and the ailerons and rudder are centered
    /// (a tail jump to $2D9D with A = 0). A left/right stick sets the counter to 3, so the
    /// controls center on the third 5 Hz tick after the stick is released; after an up/down
    /// action alone (counter already 0) they center at once. The 6 bytes after that jump
    /// ($26F9-$26FE, calls into $2DD2 and $2E38) are unreachable and not ported.
    /// Clobbers A, X, Y.
    public func autoCenter() {
        let m = mem
        let R = Input.RAM.self
        let counter = m[R.autoCenterCounter]
        m[R.autoCenterCounter] = counter >> 1
        guard counter & 1 == 0 else { charge(15); return }  // still counting
        m[R.joystickUsed] = m[R.joystickUsed] >> 1
        charge(19)                                          // run out: done, center
        centerControls()
    }
}
