/// The keys that set a request flag or toggle a switch ($2801-$2806, $2865-$286C, $2AD5,
/// $2B28-$2B8B, $2BC9-$2C1D, $2CC1): the editor and mode library requests, the course plotter,
/// war, bombs and guns, brakes, the CTRL-B/CTRL-D recalibrations, carb heat, lights and the slew
/// attitude keys. The flags are acted on elsewhere (the main loop and the overlays, wave D).
extension Machine {
    /// $2801 (E, CLR/HOME): `$08BA` = 1; the main loop then runs the editor overlay.
    public func keyEditor() {
        mem[Input.RAM.editorRequest] = 1
        charge(12)
    }

    /// $2BDF ('+'): `$08BB` = 1; the editor overlay reloads the current mode `$0963`.
    public func keyRecallMode() {
        mem[Input.RAM.modeRequest] = 1
        charge(12)
    }

    /// $2BE5 (S): `$08BB` = 2; the editor overlay saves the situation as user mode `$0963` + 10.
    public func keySaveMode() {
        mem[Input.RAM.modeRequest] = 2
        charge(15)                                          // branches into the store of '+'
    }

    /// $2BE9 (Q): `$0E70` = 1, the course plotter request.
    public func keyCoursePlotter() {
        mem[Input.RAM.coursePlotterRequest] = 1
        charge(12)
    }

    /// $2AD5 (W): declares war, `$0ACC` |= 1. (The return at $2ADE after it is unreachable.)
    public func keyDeclareWar() {
        mem[Input.RAM.warDeclared] |= 1
        charge(16)
    }

    /// $2F40 (CTRL-E): increments `$0E87`, the database info request.
    public func keyDatabaseInfo() {
        mem[Input.RAM.databaseInfoRequest] &+= 1
        charge(12)
    }

    /// $2CC1: the default dispatch target (a bare return).
    public func keyIgnored() {
        charge(6)
    }

    /// $2865 ('8'): decrements the slew pitch rate `$0AC3`.
    public func key8() {
        mem[Input.RAM.slewPitchRate] &-= 1
        charge(12)
    }

    /// $2869 ('9'): increments `$0AC3`.
    public func key9() {
        mem[Input.RAM.slewPitchRate] &+= 1
        charge(12)
    }

    /// $2BEF (Z): in slew, zeroes the view attitude `$6E-$71` then `$6C/$6D`.
    public func keyZeroAttitude() {
        let m = mem
        let R = Input.RAM.self
        guard m[R.slewMode] != 0 else { charge(14); return }   // not slewing (the branch crosses a page)
        for a in [R.viewBank, R.viewBank + 1, R.viewHeading, R.viewHeading + 1, R.viewPitch, R.viewPitch + 1] {
            m[a] = 0
        }
        charge(4 + 2 + 2 + 3 * 6 + 6)
    }

    /// $2BC9 (SPACE; also called from the ground contact at $354A while repositioning): on the
    /// ground (`$0A12` != 0) the brakes: airspeed high byte `$0A4D` - 2, and when that is negative
    /// the whole airspeed `$0A4C/$0A4D` = 0. Airborne it continues into `fireGuns` (a branch that
    /// crosses a page).
    public func keySpace() {
        let m = mem
        let R = Input.RAM.self
        guard m[R.onGround] != 0 else { charge(8); fireGuns(); return }
        let high = m[R.airspeed + 1] &- 2
        m[R.airspeed + 1] = high
        guard high & 0x80 != 0 else { charge(27); return }   // still rolling
        m[R.airspeed] = 0
        m[R.airspeed + 1] = 0
        charge(36)
    }

    /// $2C03 (SPACE airborne; joystick port 2 fire): in war mode (`$0969`) with ammunition
    /// (`$0AA5/$0AA6` != 0): the 3-frame burst `$0AB2` = 3, sound state `$0E59` = 3 and the gun
    /// sound (`sfxGun`).
    public func fireGuns() {
        let m = mem
        let R = Input.RAM.self
        guard m[R.europe1917] != 0 else { charge(13); return }
        guard m[R.ammo] | m[R.ammo + 1] != 0 else { charge(23); return }
        m[R.gunBurst] = 3
        m[R.soundState] = 3
        charge(34)                                          // the burst and sound state 3
        sfxGun()
        charge(6)
    }

    /// $2B79 (X): in war mode with a bomb left (`$08E8` != '0'), decrements `$08E8` and plays the
    /// bomb release sound (`sfxBombRelease`).
    public func keyDropBomb() {
        let m = mem
        let R = Input.RAM.self
        guard m[R.europe1917] != 0 else { charge(13); return }
        guard m[R.bombCount] != 0x30 else { charge(21); return }
        m[R.bombCount] &-= 1
        charge(26)                                          // one bomb fewer
        sfxBombRelease()
        charge(6)
    }

    /// $2B28 (CTRL-B): clears the altimeter offset and drift `$09CE-$09D1`.
    public func keyCtrlB() {
        let m = mem
        let R = Input.RAM.self
        m[R.altimeterOffset] = 0
        m[R.altimeterOffset + 1] = 0
        m[R.altimeterDrift] = 0
        m[R.altimeterDrift + 1] = 0
        charge(2 + 4 * 4 + 6)
    }

    /// $2B37 (CTRL-D): realigns the DG: `$08C0/$08C1` = compass `$08C5` - view heading `$70` +
    /// `$0848` + `$0846` (16-bit, wrapping).
    public func keyCtrlD() {
        let R = Input.RAM.self
        let value = u16(R.compassHeading) &- u16(R.viewHeading) &+ u16(R.headingOffsetB) &+ u16(R.headingOffsetA)
        setU16(R.dgOffset, value)
        charge(74)
    }

    /// $2B63 (CTRL-I): toggles carb heat `$0AA9` (every bit inverted), then the labels ($3A71).
    public func keyCarbHeat() {
        mem[Input.RAM.carbHeat] ^= 0xFF
        charge(13)
        drawMagnetoLabel()
    }

    /// $2B6E (L, CTRL-L): toggles the lights `$0AB5` (every bit inverted), then the labels ($3A71).
    public func keyLights() {
        mem[Input.RAM.lights] ^= 0xFF
        charge(13)
        drawMagnetoLabel()
    }
}
