/// Keyboard, joysticks and every in-flight key handler: a translation of the original's
/// input code. See `re/docs/input.md` for the specification of every routine.
///
/// | Range | Port | File |
/// |---|---|---|
/// | $2250-$2284 | `waitForKey()` | `Dispatch.swift` |
/// | $2418-$2471 | `keyScan()` | `KeyboardScan.swift` |
/// | $24C2-$25EA | `keyPress(_:)`, `requeueKey(_:)`, `keyReleaseCheck()`, `sampleCia1(column:)`, `dequeueKey()`, `enqueueKey(_:)` | `KeyboardScan.swift` |
/// | $2688-$26FE | `joystickAction()`, `autoCenter()` | `Joystick.swift` |
/// | $2700-$2714 | `restoreNmi()` | `KeyboardScan.swift` |
/// | $27D8-$2801, $2F40 | `dispatchKey()` and the dispatch through the table $2718, `keyDatabaseInfo()` | `Dispatch.swift` |
/// | $2801-$2C1D | mode, radio, magneto and war keys | `CommandKeys.swift`, `SelectionKeys.swift` |
/// | $2C1E-$2E91 | throttle, trim, flaps, elevator, ailerons, rudder, view capture | `ControlKeys.swift` |
///
/// Conventions (the same as the other units'):
/// - Every routine reads and writes the bytes its original reads and writes, at the same
///   addresses and in the same order, including the scan temporaries `$0898-$08A5`, the
///   self-modified dispatch operand `$27FF/$2800`, and the multiply scratch `$C4/$C5`. Tables
///   (row masks $2472, column selects $247A, codes $2482, handlers $2718) are read from memory.
/// - CIA1 is read through `io.keyboard` (`KeyMatrix.readPortA/readPortB`) with the column
///   selects the original writes to `$DC00`. The game never changes the data direction
///   registers (DDRA = $FF, DDRB = $00 as the KERNAL left them), so port A drives the columns
///   and port B is read with every line pulled up. Every `$DC01` read follows a `$DC00` store in
///   the same routine, so no port shadow is kept between calls.
/// - Each routine charges the cycles of its own instructions, from its first instruction through
///   its return (or the jump that ends it), progressively before each call it makes; the caller
///   charges its own call. The costs are exact, including taken branches and page crossings.
/// - Register outputs are returned only where a caller uses them: `sampleCia1` (C, X, Y),
///   `dequeueKey` (A, C), `waitForKey` (A), `throttleDown` (A, read by the joystick routine),
///   `captureViewKey` (whether it popped the caller), `restoreNmi` (restart, or return from the interrupt).
public enum Input {
    /// Variables at their original addresses (names from `re/symbols.json`).
    public enum RAM {
        // MARK: Zero page
        public static let viewPitch = 0x6C
        public static let viewBank = 0x6E
        public static let viewHeading = 0x70
        /// `$9C/$9D` marker shape pointer and `$8E/$8F` row pointer of `plotPointList` ($1D01).
        public static let markerShapePtr = 0x9C
        public static let rowPointer = 0x8E
        /// `$C4/$C5` multiplicand of `mulQ15AX`.
        public static let mathResult = 0xC4
        /// `$FC` the selected item of ',' and '.' (see `input.md`).
        public static let selectedItem = 0xFC

        // MARK: Keyboard scan and queue ($0898-$08B0)
        /// `$0836` radar view on.
        public static let radarMode = 0x0836
        public static let headingOffsetA = 0x0846
        public static let headingOffsetB = 0x0848
        /// `$0888` radar eye height (32-bit); the ',' and '.' keys shift its upper bytes `$0889-$088B`.
        public static let radarEyeHeight = 0x0888
        /// `$0898` release check: matrix index of the slot being checked, then the slot index.
        public static let releaseIndex = 0x0898
        public static let scanColumnIndex = 0x0899
        public static let scanColumnSelect = 0x089A
        /// `$089B-$089E` four held-key slots (matrix index, or $80 free).
        public static let heldKeySlots = 0x089B
        /// `$089F` scan row index and `$08A0` row mask of the column being scanned.
        public static let scanRow = 0x089F
        public static let scanRowMask = 0x08A0
        /// `$08A1` port-2 sample; also the row read of the scanned column (stored by `sampleCia1`).
        public static let joyPort2Sample = 0x08A1
        public static let joyPort1Sample = 0x08A2
        public static let joyPort2Sample2 = 0x08A3
        public static let joyPort1Sample2 = 0x08A4
        /// `$08A5` release check: slot index saved across `sampleCia1`.
        public static let releaseSlot = 0x08A5
        /// `$08A6` keyboard phase of the frame IRQ (scan on 0, release check on -1).
        public static let scanPhase = 0x08A6
        public static let keyQueueWrite = 0x08A7
        public static let keyQueueRead = 0x08A8
        /// `$08A9-$08B0` the 8-entry key ring.
        public static let keyQueue = 0x08A9

        // MARK: Modes and requests
        public static let editorRequest = 0x08BA
        public static let modeRequest = 0x08BB
        public static let dgOffset = 0x08C0
        public static let keyDispatchInhibit = 0x08C3
        public static let promptKey = 0x08C4
        public static let compassHeading = 0x08C5
        public static let pauseCount = 0x08CC
        public static let soundEnable = 0x08D3
        public static let throttleJumpArmed = 0x08D5
        public static let fd00HookRequest = 0x08D7
        public static let bombCount = 0x08E8
        public static let quickRepeatWindow = 0x091C
        public static let comSearchRequest = 0x0937
        public static let demoActive = 0x095A
        public static let autoCoordination = 0x0965
        public static let slewMode = 0x0966
        public static let europe1917 = 0x0969
        public static let overControlLimiter = 0x09A9
        public static let fuelTankSelect = 0x09C6
        public static let altimeterOffset = 0x09CE
        public static let altimeterDrift = 0x09D0
        public static let flightPathAngle = 0x09DE
        public static let bankAngle = 0x09E0
        public static let rollTerm = 0x09FC

        // MARK: Controls and their coefficients
        public static let flapDrag = 0x0A0A
        public static let onGround = 0x0A12
        public static let heading = 0x0A13
        public static let aileronCoefficient = 0x0A1D
        public static let flapLift = 0x0A25
        public static let airspeed = 0x0A4C
        public static let flapDragFactor = 0x0A6C
        public static let aileronGain = 0x0A7A
        public static let aileronGainManeuver = 0x0A7C
        public static let flapLiftFactor = 0x0A7E
        /// `$0A9F` x and `$0AA1` index of `plotPointList` (the last point plotted).
        public static let markerX = 0x0A9F
        public static let markerIndex = 0x0AA1
        public static let ailerons = 0x0AA3
        public static let ammo = 0x0AA5
        public static let carbHeat = 0x0AA9
        public static let elevator = 0x0AAB
        public static let elevatorTrim = 0x0AAE
        public static let flaps = 0x0AAF
        public static let gunBurst = 0x0AB2
        public static let lights = 0x0AB5
        public static let magnetoLabel = 0x0AB6
        public static let navSelect = 0x0AB7
        public static let rudder = 0x0ABC
        public static let slewBankRate = 0x0ABF
        public static let slewHeadingRate = 0x0AC1
        public static let slewPitchRate = 0x0AC3
        public static let slewAltitudeRate = 0x0AC5
        public static let throttle = 0x0AC9
        public static let viewDirection = 0x0ACA
        public static let obsSelect = 0x0ACB
        public static let warDeclared = 0x0ACC

        // MARK: Sound, joystick and timers
        public static let soundState = 0x0E59
        public static let ctrlHeld = 0x0E67
        public static let joystickLatched = 0x0E6A
        /// `$0E6E` latched port 2 (throttle, guns) and `$0E6F` port 1 (the yoke), active-high.
        public static let joyPort2 = 0x0E6E
        public static let joyPort1 = 0x0E6F
        public static let coursePlotterRequest = 0x0E70
        /// `$0E71-$0E74` per-slot repeat delays.
        public static let repeatCounters = 0x0E71
        public static let maneuverTimer = 0x0E75
        public static let rollCancel = 0x0E76
        public static let autoCenterCounter = 0x0E78
        public static let joystickUsed = 0x0E7A
        public static let databaseInfoRequest = 0x0E87

        // MARK: Radio records and panel state
        /// `$2196` / `$2199` OBS1 / OBS2 in 2-degree units (0-$B3).
        public static let obs1 = 0x2196
        public static let obs2 = 0x2199
        /// The digits of the COM ($21AE + 2: tens, units, tenths, hundredths), NAV1 ($21B5 + 2)
        /// and NAV2 ($21BC + 2) records, and the four octal transponder digits ($21DB + 2).
        public static let comDigits = 0x21B0
        public static let nav1Digits = 0x21B7
        public static let nav2Digits = 0x21BE
        public static let transponderDigits = 0x21DD
        /// `$26FF` RUN/STOP+RESTORE one-shot.
        public static let restoreOneShot = 0x26FF
        /// `$2715` / `$2716` elevator / aileron indicator positions last drawn.
        public static let elevatorIndicator = 0x2715
        public static let aileronIndicator = 0x2716
        /// `$27FF/$2800` operand of the self-modified indirect jump at $27FE.
        public static let dispatchOperand = 0x27FF
        /// `$EE14/$EE15` magneto switch state (code & 1, code >> 1).
        public static let magnetoState = 0xEE14
    }

    /// Read-only tables (read from memory, never regenerated).
    public enum Table {
        /// `$2472` row bit masks $01..$80.
        public static let rowBitMasks = 0x2472
        /// `$247A` `$DC00` column selects $FE..$7F.
        public static let columnSelects = 0x247A
        /// `$2482` matrix index (column × 8 + row) → command code; ≥ $80 is never queued, $FB = CTRL.
        public static let keyCodeTable = 0x2482
        /// `$2718` 96 handler words for the codes $00-$5F.
        public static let keyDispatchTable = 0x2718
    }

    /// The code `$FB` of CTRL in `keyCodeTable`.
    public static let ctrlCode: UInt8 = 0xFB
    /// `$089E == $3F`: RUN/STOP (matrix index 63) in slot 3, the condition of the restart.
    public static let runStopIndex: UInt8 = 0x3F
    /// `$A7E2`: the cold restart `restoreNmi` jumps to (wave D: modes).
    public static let coldRestart: UInt16 = 0xA7E2

    /// The handler entry points named in the dispatch table $2718, in address order (the table
    /// itself is read from memory; `re/docs/input.md` lists it by key code).
    public enum Handler {
        public static let waitForKey: UInt16 = 0x2250
        public static let keyEditor: UInt16 = 0x2801
        public static let key1: UInt16 = 0x2807
        public static let key2: UInt16 = 0x283D
        public static let key3: UInt16 = 0x285F
        public static let key8: UInt16 = 0x2865
        public static let key9: UInt16 = 0x2869
        public static let decrementSelected: UInt16 = 0x286D
        public static let incrementSelected: UInt16 = 0x298E
        public static let keyDeclareWar: UInt16 = 0x2AD5
        public static let keyCtrlT: UInt16 = 0x2ADF
        public static let keyTransponderSelect: UInt16 = 0x2B0D
        public static let keyAdfSelect: UInt16 = 0x2B25
        public static let keyCtrlB: UInt16 = 0x2B28
        public static let keyCtrlD: UInt16 = 0x2B37
        public static let keyCarbHeat: UInt16 = 0x2B63
        public static let keyLights: UInt16 = 0x2B6E
        public static let keyDropBomb: UInt16 = 0x2B79
        public static let keyComSelect: UInt16 = 0x2B8C
        public static let keyObsSelect: UInt16 = 0x2BA7
        public static let keyNavSelect: UInt16 = 0x2BAC
        public static let keyReturn: UInt16 = 0x2BC4
        public static let keySpace: UInt16 = 0x2BC9
        public static let keyRecallMode: UInt16 = 0x2BDF
        public static let keySaveMode: UInt16 = 0x2BE5
        public static let keyCoursePlotter: UInt16 = 0x2BE9
        public static let keyZeroAttitude: UInt16 = 0x2BEF
        public static let throttleUp: UInt16 = 0x2C1E
        public static let throttleDown: UInt16 = 0x2C31
        public static let throttleJump: UInt16 = 0x2C4F
        public static let keyFuelTankSelect: UInt16 = 0x2C55
        public static let keyRadar: UInt16 = 0x2C5A
        public static let keyViewSelect: UInt16 = 0x2C70
        public static let keyTrimUp: UInt16 = 0x2C87
        public static let keyTrimDown: UInt16 = 0x2C9A
        public static let keyIgnored: UInt16 = 0x2CC1
        public static let keyFlapsUp: UInt16 = 0x2CC2
        public static let keyFlapsDown: UInt16 = 0x2D11
        public static let keyElevatorDown: UInt16 = 0x2D2B
        public static let keyAileronLeft: UInt16 = 0x2D6D
        public static let keyCenter: UInt16 = 0x2D82
        public static let keyAileronRight: UInt16 = 0x2DC2
        public static let keyRudderLeft: UInt16 = 0x2E22
        public static let keyRudderRight: UInt16 = 0x2E2D
        public static let keyElevatorUp: UInt16 = 0x2E5C
        public static let keyDatabaseInfo: UInt16 = 0x2F40
    }
}
