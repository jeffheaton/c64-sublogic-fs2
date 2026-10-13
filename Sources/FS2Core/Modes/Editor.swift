/// The mode editor: overlay 1 (logical blocks 42-47 at $A7E0-$BC6A), entered through slot $A7E8
/// (a jump to $B09A) when the main loop sees `$08BA` | `$08BB`. See `re/docs/editor.md`.
///
/// The editor works on the overlay bytes in memory: the two 40 x 25 page images at $A804 (the
/// simulation control and aircraft position pages) and at $ABEC (environmental control), the
/// screen-line table $AFD4, the 24-bit powers of ten $B006, the field descriptors $B020/$B05A
/// (through the pointers $B01C) and the built-in modes $B9E1. Every routine here is a literal
/// translation: it reads and writes the bytes the original does and charges the original's
/// cycles (page crossings included).
///
/// The keys come through the wait-for-key routine ($2003 → $2250, `waitForKey`): the editor
/// blocks there, as the original does, while the poll keeps the 10 Hz tick going.
public enum Editor {
    /// $B09A: the overlay's entry (slot $A7E8).
    public static let entry: UInt16 = 0xB09A
    /// $BC6B: the editor overlay's end word (at $A7E0 while it is resident).
    public static let overlayEnd: UInt16 = 0xBC6B

    /// The editor's variables.
    public enum RAM {
        /// $0948: E was pressed (exit after the field).
        public static let exitKey = 0x0948
        /// $0949: '-' was pressed (move up after the field).
        public static let previousKey = 0x0949
        /// $094A-$094C: the 24-bit field value being parsed or printed.
        public static let fieldValue = 0x094A
        /// $094D: the cursor line · 2 (1-21 on screen: $02-$2A).
        public static let cursorLine = 0x094D
        /// $094E: the page · 2 (0 or 2).
        public static let page = 0x094E
        /// $094F: digits were typed into the current field (it is then accepted).
        public static let fieldEdited = 0x094F
        /// $0950: digits printed so far (leading-zero suppression).
        public static let printedDigits = 0x0950
        /// $0951: digits typed (0-6).
        public static let digitCount = 0x0951
        /// $0952-$0957: the typed ASCII digits, the last typed first ('0' padded).
        public static let typedDigits = 0x0952
        /// $0958: the screen column of the next digit, relative to column 26 (5-11).
        public static let column = 0x0958
        /// $095C: the digit being printed ('0' + count); `loadModeRecord`'s direction.
        public static let digitScratch = 0x095C
        /// $095D: the current field's size (1 or 2); the low byte of a trial subtraction.
        public static let fieldSize = 0x095D
        /// $095E: the middle byte of a trial subtraction.
        public static let subtractMiddle = 0x095E
        /// $09A5: the USER MODE field (0-24 recall, 110-124 save to n - 100, ≥ 210 ignored).
        public static let userModeEntry = 0x09A5
        /// $A9: the cursor line saved around a page reprint.
        public static let savedLine = 0xA9
        /// $AF: the digit just typed.
        public static let typedKey = 0xAF
        /// $37/$38: the source pointer of a page copy; the screen digits of a field.
        public static let sourcePointer = 0x37
        /// $39/$3A: the screen line of the cursor; a field's bytes in the record.
        public static let linePointer = 0x39
        /// $A5/$A6: the field descriptor walk.
        public static let descriptorPointer = 0xA5
    }

    /// The mode record's fields ($0964-$09A4, display values; see `re/docs/editor.md`).
    public enum Record {
        public static let sound = 0x0964
        public static let autoCoordination = 0x0965
        public static let slew = 0x0966
        public static let reality = 0x0967
        public static let europe1917 = 0x0969
        public static let communicationRate = 0x096A
        public static let north = 0x096B
        public static let east = 0x096D
        public static let altitude = 0x096F
        public static let pitch = 0x0971
        public static let bank = 0x0973
        public static let heading = 0x0975
        public static let airspeed = 0x0977
        public static let throttle = 0x0979
        public static let rudder = 0x097B
        public static let ailerons = 0x097D
        public static let flaps = 0x097F
        public static let elevators = 0x0981
        public static let hours = 0x0983
        public static let minutes = 0x0984
        public static let season = 0x0985
        public static let cloud2Tops = 0x0986
        public static let cloud2Bottoms = 0x0988
        public static let cloud1Tops = 0x098A
        public static let cloud1Bottoms = 0x098C
        public static let shear1 = 0x098E
        public static let shear2 = 0x0990
        public static let shear3 = 0x0992
        /// $0994/$0998/$099C/$09A0: wind levels 3, 2, 1 and the surface wind, 4 bytes each
        /// (knots field, direction).
        public static let winds = [0x0994, 0x0998, 0x099C, 0x09A0]
        public static let reliability = 0x09A4
    }

    /// The simulator state the conversions read and write.
    public enum State {
        public static let eastPosition = 0x5A
        public static let altitude = 0x5E
        public static let northPosition = 0x62
        public static let mainLoopCounter = 0x22
        /// $0846/$0848: heading offsets summed into the heading (grid and magnetic).
        public static let headingOffsetA = 0x0846
        public static let headingOffsetB = 0x0848
        /// $0856-$085D: cloud 1 bottoms/tops, cloud 2 bottoms/tops in meters.
        public static let cloudMeters = 0x0856
        /// $085C-$0869: seven words converted meters ↔ feet while the editor runs (the first is
        /// cloud 2 tops in meters).
        public static let metricWords = 0x085C
        public static let lastUserMode = 0x0886
        public static let savedACD = 0x08B5
        public static let killCount = 0x08B2
        public static let warScore = 0x08D1
        public static let damageLevel = 0x08D4
        public static let warFlag08D6 = 0x08D6
        public static let bombCount = 0x08E8
        public static let demoActive = 0x095A
        public static let demoRequest = 0x095B
        public static let temperatureOffset = 0x095F
        public static let flightPathAngle = 0x09DE
        public static let bankAngle = 0x09E0
        public static let heading = 0x0A13
        public static let airspeed = 0x0A4C
        public static let repositionCounter = 0x0A83
        public static let fieldElevation = 0x0A87
        public static let ailerons = 0x0AA3
        public static let ammo = 0x0AA5
        public static let warFlag0AA7 = 0x0AA7
        public static let elevator = 0x0AAB
        public static let flaps = 0x0AAF
        public static let rudder = 0x0ABC
        public static let throttle = 0x0AC8
        public static let warDeclared = 0x0ACC
        public static let acd = 0x0ACD
        /// $0ACF: a return instruction ($60) the exit calls and reads.
        public static let exitHook = 0x0ACF
        /// $0E7C: 7 once Europe 1917 forced mode 7 (the main loop restarts when the mode leaves 7).
        public static let warModeLatch = 0x0E7C
        public static let plotRecorded = 0x0E86
    }

    /// The overlay's tables.
    public enum Table {
        /// $A800: the two page image pointers ($A804, $ABEC).
        public static let pagePointers = 0xA800
        /// $AFD4: 25 screen-line addresses, each at column 26 ($041A, $0442, ...).
        public static let screenLines = 0xAFD4
        /// $B006: 1, 10, 100, 1000, 10000, 100000 as three 6-byte planes (low, middle, high).
        public static let powersOfTen = 0xB006
        /// $B01C: pointers to the field descriptor lists at $B020 (page 0) and at $B05A (page 1):
        /// `[size 1/2][screen line · 2][offset into $0964]`, 0 ends a list.
        public static let fieldTables = 0xB01C
    }

    /// The key codes `waitForKey` returns that the editor acts on.
    public enum Key {
        public static let nextLine: UInt8 = 0x0D        // RETURN
        public static let previousLine: UInt8 = 0x2D    // '-' and the up arrow
        public static let exit: UInt8 = 0x45            // E
        public static let backspace: UInt8 = 0x08       // DEL, ':' and the left arrow
        public static let recall: UInt8 = 0x2B          // '+'
        public static let save: UInt8 = 0x53            // S
        public static let libraryLoad: UInt8 = 0x18     // CTRL-X
        public static let librarySave: UInt8 = 0x1A     // CTRL-Z
    }

    /// The screen code pair of the cursor arrow at column 26: two line characters and '>'.
    public static let cursorArrow: [UInt8] = [0x40, 0x40, 0x3E]

    /// 1 when an indexed read of `base` + `index` crosses a page (one more cycle).
    @inline(__always) static func crossing(_ base: Int, _ index: Int) -> Int {
        (base & 0xFF) + index > 0xFF ? 1 : 0
    }
}

extension Machine {
    // MARK: The main loop's side of the contract

    /// True when the editor has to run on this main-loop pass ($204B: `$08BA` | `$08BB` != 0);
    /// the main loop then calls slot $A7E8 (the editor overlay, `editorEntry`) and afterwards
    /// marks the editor cached (`$08BC` 0 → 1, or swaps it back to the cache when 1).
    public var editorRequested: Bool {
        mem[Input.RAM.editorRequest] | mem[Input.RAM.modeRequest] != 0
    }

    /// The main loop's Europe 1917 exit check ($213D-$2149, in the 1-in-8 block of passes, after
    /// the demo check): once the editor forced mode 7 it latched `$0E7C` = 7; when the current
    /// mode `$0963` is no longer 7 the game restarts cold (a jump to $A7E2: the cold-start
    /// overlay reloads everything, back to the title). The latch is never cleared otherwise.
    public var warModeRestartDue: Bool {
        mem[Editor.State.warModeLatch] != 0 && mem[ModeLibrary.currentMode] != 7
    }

    // MARK: The entry and the field loop ($B09A)

    /// $B09A: the editor. Converts the simulator state to the record (`stateToRecord`),
    /// switches to the text screen (`$203F`), shows page 0 with its fields and the cursor on
    /// line 1. A mode request `$08BB` is served without any key: 1 reloads mode `$0963`
    /// (`'+'`, a crash), 2 saves the situation as a user mode ('S'), anything else loads
    /// built-in mode 2 (the demo); then the exit. Otherwise the field loop runs until E: a
    /// field with typed digits is accepted (`acceptField`), and a USER MODE line keeps the
    /// cursor where it is; RETURN moves down a line, '-' up. The exit is `recordToState`
    /// (a jump to $B559), whose return ends the editor. Clobbers A, X, Y.
    public func editorEntry() {
        let m = mem
        charge(6)
        stateToRecord()
        charge(9)                                       // through the $203F vector
        textModeIrqSwap()
        charge(6)
        editorFirstPage()
        let request = m[Input.RAM.modeRequest]
        charge(4)                                           // a mode request?
        if request != 0 {
            charge(4)
            if request == 1 {
                charge(8)                               // 1: reload the mode
                loadModeRecord()
            } else {
                charge(5)
                if request == 2 {
                    charge(8)                           // 2: save it
                    saveUserMode()
                } else {
                    m[ModeLibrary.currentMode] = 2
                    charge(15)                   // anything else: built-in mode 2
                    loadModeRecord()
                }
            }
            charge(6)                                   // on to the exit
            recordToState()
            return
        }
        charge(3)                                           // no request: the field loop
        while true {
            // $B0C5
            charge(6)
            editorKeys()
            var c = 4                                       // digits typed?
            if m[Editor.RAM.fieldEdited] != 0 {
                charge(c + 8)                           // accept the field
                acceptField()
                c = 4                                       // page 0?
                if m[Editor.RAM.page] == 0 {
                    c += 8                          // on the USER MODE line?
                    if m[Editor.RAM.cursorLine] == 2 {
                        charge(c + 5)                   // stay on it
                        continue
                    }
                    c += 3
                } else {
                    c += 3
                }
            } else {
                c += 3
            }
            // $B0DF
            c += 4                                          // E?
            if m[Editor.RAM.exitKey] != 0 {
                charge(c + 5)                           // the exit
                recordToState()
                return
            }
            c += 7                                      // '-'?
            if m[Editor.RAM.previousKey] != 0 {
                m[Editor.RAM.previousKey] = 0
                charge(c + 14)                   // cleared; up a line
                cursorPreviousLine()
            } else {
                charge(c + 9)                           // down a line
                cursorNextLine()
            }
            charge(3)                                       // the next field
        }
    }

    // MARK: Cursor and pages ($B0FD-$B178, $B803)

    /// $B0FD (RETURN): erases the arrow, moves the cursor one screen line down (`$094D` += 2);
    /// past line 21 the other page is shown (page 1 after page 0, page 0 after page 1) with the
    /// cursor on its line 1. Draws the arrow.
    public func cursorNextLine() {
        let m = mem
        charge(6)
        eraseCursor()
        let line = m[Editor.RAM.cursorLine] &+ 2
        var c = 10                               // one line down; past line 21?
        guard line == 0x2C else {
            charge(c + 3)
            drawCursorArrow(line)
            return
        }
        var page = m[Editor.RAM.page] &+ 2
        c += 12                              // the other page
        if page == 4 {
            page = 0
            c += 4                                      // back to page 0
        } else {
            c += 3
        }
        charge(c)
        switchPage(page)
        charge(2)                                           // line 1
        drawCursorArrow(2)
    }

    /// $B136 ('-'): erases the arrow, moves the cursor one line up; from line 1 the other page
    /// is shown (page 1 from page 0, page 0 from page 1) with the cursor on its line 21.
    public func cursorPreviousLine() {
        let m = mem
        charge(6)
        eraseCursor()
        let line = m[Editor.RAM.cursorLine] &- 2
        var c = 10                               // one line up; above line 1?
        guard line == 0 else {
            charge(c + 3)
            drawCursorArrow(line)
            return
        }
        var page = m[Editor.RAM.page] &- 2
        c += 10                                  // the other page
        if page & 0x80 == 0 {
            c += 3
        } else {
            page = 2
            c += 4                                      // from page 0 to page 1
        }
        charge(c)
        switchPage(page)
        charge(5)                                       // line 21
        drawCursorArrow(0x2A)
    }

    /// $B15B: three spaces over the arrow (columns 26-28 of the cursor line).
    public func eraseCursor() {
        let m = mem
        charge(6)
        fieldLinePointer()
        let p = zpPointer(Editor.RAM.linePointer)
        for y in 0..<3 { m[(p + y) & 0xFFFF] = 0x20 }
        charge(32)
    }

    /// $B16B: `$39/$3A` = the screen address of cursor line `$094D` (column 26) from $AFD4.
    public func fieldLinePointer() {
        let m = mem
        let x = Int(m[Editor.RAM.cursorLine])
        m[Editor.RAM.linePointer] = m[(Editor.Table.screenLines + x) & 0xFFFF]
        m[Editor.RAM.linePointer + 1] = m[(Editor.Table.screenLines + 1 + x) & 0xFFFF]
        charge(8 + Editor.crossing(Editor.Table.screenLines, x) + 3
               + 4 + Editor.crossing(Editor.Table.screenLines + 1, x) + 9)
    }

    /// $B121: `$094D` = `line`, the arrow ($40 $40 $3E) at column 26 of that line.
    public func drawCursorArrow(_ line: UInt8) {
        let m = mem
        m[Editor.RAM.cursorLine] = line
        charge(10)
        fieldLinePointer()
        let p = zpPointer(Editor.RAM.linePointer)
        for (y, code) in Editor.cursorArrow.enumerated() { m[(p + y) & 0xFFFF] = code }
        charge(34)
    }

    /// $B114 (called by the entry; it lies inside `cursorNextLine`): page 0 (`$094E` = 0) with
    /// its fields, the cursor arrow on line 1.
    public func editorFirstPage() {
        charge(2)                                           // page 0
        switchPage(0)
        charge(2)                                           // line 1
        drawCursorArrow(2)
    }

    /// $B116-$B11E: stores the page in `$094E`, copies its image to $0400 ($B803) and prints its
    /// fields ($B3C0; the cursor line `$094D` is left at the last field's line).
    private func switchPage(_ page: UInt8) {
        mem[Editor.RAM.page] = page
        charge(10)
        drawPage()
        charge(6)
        printPageFields()
    }

    /// $B803: copies page `$094E` / 2's image (pointer at $A800 + `$094E`) to $0400.
    public func drawPage() {
        let m = mem
        let x = Int(m[Editor.RAM.page])
        let lo = m[(Editor.Table.pagePointers + x) & 0xFFFF]
        let hi = m[(Editor.Table.pagePointers + 1 + x) & 0xFFFF]
        // The image pointer from the table, then the copy.
        charge(8 + Editor.crossing(Editor.Table.pagePointers, x) + 2
               + 4 + Editor.crossing(Editor.Table.pagePointers + 1, x) + 10)
        copyEditorPage(lo: lo, hi: hi)
        charge(6)
    }

    /// $B346: copies the 1000-byte page image at A (low) / X (high) to the text screen $0400
    /// through `$37/$38` (source) and `$39/$3A` (destination), which end at the image's end and
    /// $07E8.
    public func copyEditorPage(lo: UInt8, hi: UInt8) {
        let m = mem
        m[Editor.RAM.sourcePointer] = lo
        m[Editor.RAM.sourcePointer + 1] = hi
        m[Editor.RAM.linePointer] = 0
        m[Editor.RAM.linePointer + 1] = 4
        var c = 18                   // the source and destination pointers
        while true {
            m[zpPointer(Editor.RAM.linePointer)] = m[zpPointer(Editor.RAM.sourcePointer)]
            c += 16                                  // one byte; the source on
            m[0x37] &+= 1
            if m[0x37] != 0 { c += 3 } else { m[0x38] &+= 1; c += 7 }
            m[0x39] &+= 1
            c += 5                                          // the destination on
            if m[0x39] != 0 { c += 3 } else { m[0x3A] &+= 1; c += 7 }
            c += 5                                      // the screen's end, $07E8?
            if m[0x39] != 0xE8 { c += 3; continue }
            c += 7
            if m[0x3A] != 0x07 { c += 3; continue }
            c += 2
            break
        }
        charge(c + 6)
    }

    // MARK: Keys and digits ($B179-$B288)

    /// $B179: starts a field (`$094F` = 0, `$0958` = 5, `$0951` = `$0948` = 0, the digits
    /// '000000') and reads keys ($B198) until RETURN, '-' or E, which parse the typed digits
    /// into `$094A-$094C` ('-' also sets `$0949`, E increments `$0948`). '+' (`recallKey`) and
    /// 'S' (`saveUserMode`) start over; CTRL-X and CTRL-Z run the library disk and keep
    /// reading; DEL takes back a digit; up to six digits are echoed in reverse video from
    /// column 31 (the field is blanked at the first one). Other keys are ignored.
    public func editorKeys() {
        let m = mem
        while true {
            m[Editor.RAM.fieldEdited] = 0
            charge(12)                               // nothing typed yet; the line pointer
            fieldLinePointer()
            m[Editor.RAM.column] = 5
            m[Editor.RAM.digitCount] = 0
            m[Editor.RAM.exitKey] = 0
            for x in 0..<6 { m[Editor.RAM.typedDigits + x] = 0x30 }
            // The column, the counts and the six '0' digits.
            charge(2 + 4 + 2 + 4 + 4 + 2 + 6 * 12 - 1)
            if fieldInput() {
                charge(6)
                parseFieldValue()
                charge(6)
                return
            }
        }
    }

    /// $B198: the key loop. Returns true for RETURN, '-' and E (the field ends), false for '+'
    /// and 'S' (which start the field over at $B179).
    private func fieldInput() -> Bool {
        let m = mem
        while true {
            charge(9)                                   // through the $2003 vector
            let key = waitForKey()
            var c = 2                                       // RETURN?
            if key == Editor.Key.nextLine {
                charge(c + 3)
                return true
            }
            c += 4                                      // '-'?
            if key == Editor.Key.previousLine {
                m[Editor.RAM.previousKey] = key
                charge(c + 9)                       // noted; the exit branch reuses the compare's zero flag
                return true
            }
            c += 5                                      // E?
            if key == Editor.Key.exit {
                m[Editor.RAM.exitKey] &+= 1
                charge(c + 8)                           // noted
                return true
            }
            c += 5                                      // DEL?
            if key == Editor.Key.backspace {
                c += 6                                  // any digits?
                guard m[Editor.RAM.digitCount] != 0 else {
                    charge(c + 3)                           // none: the next key
                    continue
                }
                m[Editor.RAM.digitCount] &-= 1
                m[Editor.RAM.column] &-= 1
                let y = Int(m[Editor.RAM.column])
                m[(zpPointer(Editor.RAM.linePointer) + y) & 0xFFFF] = 0x20
                for x in 1...5 { m[Editor.RAM.digitCount + x] = m[Editor.RAM.typedDigits + x] }
                m[Editor.RAM.typedDigits + 5] = 0x30
                // One digit fewer, its column blanked, the digits shifted down with a '0' fed in
                // at the top, then back to the key loop (one of the branches crosses a page).
                c += 2 + 6 + 2 + 6 + 4 + 6 + 2 + 5 * 16 - 1 + 2 + 4 + 4 + 3
                charge(c)
                continue
            }
            c += 5                                      // '+'?
            if key == Editor.Key.recall {
                charge(c + 8)                           // recall
                recallKey()
                charge(3)                                   // the field starts over
                return false
            }
            c += 5                                      // 'S'?
            if key == Editor.Key.save {
                charge(c + 8)                           // save
                saveUserMode()
                charge(3)                                   // the field starts over
                return false
            }
            c += 5                                      // CTRL-X?
            if key == Editor.Key.libraryLoad {
                charge(c + 2)
                libraryLoad()
                continue
            }
            c += 6                                      // CTRL-Z? (the branch to here crosses a page)
            if key == Editor.Key.librarySave {
                charge(c + 2)
                librarySave()
                continue
            }
            c += 5                                      // a digit: at least '0'?
            guard key >= 0x30 else {
                charge(c + 5)                           // no: the next key
                continue
            }
            c += 5                                      // at most '9'?
            guard key < 0x3A else {
                charge(c + 6)                           // no: the next key
                continue
            }
            c += 8                                  // room for another digit?
            guard m[Editor.RAM.column] != 0x0B else {
                charge(c + 6)                           // six already: the next key
                continue
            }
            m[Editor.RAM.fieldEdited] &+= 1
            m[Editor.RAM.typedKey] = key
            c += 15                              // typed; the first digit?
            if m[Editor.RAM.digitCount] == 0 {
                let p = zpPointer(Editor.RAM.linePointer)
                for y in stride(from: 0x0C, through: 5, by: -1) { m[(p + y) & 0xFFFF] = 0x20 }
                c += 2 + 2 + 2 + 8 * 13 - 1    // the field blanked
            } else {
                c += 3
            }
            for x in stride(from: 4, through: 0, by: -1) {
                m[Editor.RAM.typedDigits + 1 + x] = m[Editor.RAM.typedDigits + x]
            }
            m[Editor.RAM.typedDigits] = m[Editor.RAM.typedKey]
            m[Editor.RAM.digitCount] &+= 1
            let y = Int(m[Editor.RAM.column])
            m[(zpPointer(Editor.RAM.linePointer) + y) & 0xFFFF] = m[Editor.RAM.typedKey] | 0x80
            m[Editor.RAM.column] = UInt8(truncatingIfNeeded: y + 1)
            // The digits shifted up with the new one first, counted, and echoed in reverse video
            // at the next column; then back to the key loop.
            c += 2 + 5 * 14 - 1 + 3 + 4 + 6 + 4 + 2 + 6 + 2 + 4 + 3 + 3
            charge(c)
        }
    }

    // MARK: Decimal conversion ($B29B, $B2D6)

    /// $B29B: the typed digits `$0952-$0957` (least significant first, bit 7 ignored) to the
    /// 24-bit `$094A-$094C`, by adding the power of ten once per unit of each digit. The carry
    /// of one addition feeds the next (the carry is cleared only once per digit), and a digit is
    /// `(char & $7F) - '0'` taken as an 8-bit count, as the original does for any byte.
    public func parseFieldValue() {
        let m = mem
        let v = Editor.RAM.fieldValue, t = Editor.Table.powersOfTen
        m[v] = 0; m[v + 1] = 0; m[v + 2] = 0
        var c = 14                               // the value zeroed
        for x in 0..<6 {
            var count = (m[Editor.RAM.typedDigits + x] & 0x7F) &- 0x30
            c += 12                          // the digit's count
            if count == 0 {
                c += 3
            } else {
                c += 4                                  // the carry cleared once for the digit
                var carry = false
                repeat {
                    m[v] = FlightModel.adc(m[(t + x) & 0xFFFF], m[v], &carry)
                    m[v + 1] = FlightModel.adc(m[(t + 6 + x) & 0xFFFF], m[v + 1], &carry)
                    m[v + 2] = FlightModel.adc(m[(t + 12 + x) & 0xFFFF], m[v + 2], &carry)
                    count &-= 1
                    c += 9 * 4 + 2 + (count != 0 ? 3 : 2)   // one 24-bit add of the power
                } while count != 0
            }
            c += 4 + (x < 5 ? 3 : 2)                    // the next digit
        }
        charge(c + 6)
    }

    /// $B2D6: prints the 24-bit `$094A-$094C` at columns 31-36 of the cursor line (`$094D`): the
    /// six columns are blanked, then each power of ten from 100000 down is subtracted while the
    /// 24-bit result stays non-negative (the sign of its high byte), counting '0' upward in
    /// `$095C`; leading zeros are skipped (`$0950` counts the digits printed; the units digit
    /// always prints). A count past '9' prints whatever screen code it reaches. Leaves
    /// `$094A-$094C` = the remainder (0) and `$0958` = the next column.
    public func printFieldValue() {
        let m = mem
        let v = Editor.RAM.fieldValue, t = Editor.Table.powersOfTen
        charge(6)
        fieldLinePointer()
        m[Editor.RAM.printedDigits] = 0
        m[Editor.RAM.column] = 5
        let line = zpPointer(Editor.RAM.linePointer)
        for y in 5..<0x0B { m[(line + y) & 0xFFFF] = 0x20 }
        // The counts reset, the six columns blanked, the highest power first.
        var c = 2 + 4 + 2 + 4 + 2 + 2 + 6 * 13 - 1 + 2
        for x in stride(from: 5, through: 0, by: -1) {
            m[Editor.RAM.digitScratch] = 0x30
            c += 6                                      // the digit starts at '0'
            while true {
                var carry = true
                m[Editor.RAM.fieldSize] = FlightModel.sbc(m[v], m[(t + x) & 0xFFFF], &carry)
                m[Editor.RAM.subtractMiddle] = FlightModel.sbc(m[v + 1], m[(t + 6 + x) & 0xFFFF], &carry)
                let high = FlightModel.sbc(m[v + 2], m[(t + 12 + x) & 0xFFFF], &carry)
                c += 34      // the trial 24-bit subtraction
                if high & 0x80 != 0 { c += 3; break }       // negative: this digit is done
                m[v + 2] = high
                m[v + 1] = m[Editor.RAM.subtractMiddle]
                m[v] = m[Editor.RAM.fieldSize]
                m[Editor.RAM.digitScratch] &+= 1
                c += 28              // kept; the digit counts up
                if m[Editor.RAM.digitScratch] != 0 { c += 4; continue }   // the loop branch crosses a page
                c += 2
                break
            }
            // $B324
            let digit = m[Editor.RAM.digitScratch]
            c += 6                                      // the units digit?
            var show = true
            if x == 0 {
                c += 3
            } else {
                c += 4                                  // a zero?
                if digit != 0x30 {
                    c += 3
                } else {
                    c += 6                              // any digit printed yet?
                    if m[Editor.RAM.printedDigits] != 0 { c += 2 } else { c += 3; show = false }
                }
            }
            if show {
                m[Editor.RAM.printedDigits] &+= 1
                let y = Int(m[Editor.RAM.column])
                m[(zpPointer(Editor.RAM.linePointer) + y) & 0xFFFF] = m[Editor.RAM.digitScratch]
                m[Editor.RAM.column] &+= 1
                c += 26                      // printed at the next column
            }
            c += 2 + (x > 0 ? 4 : 2)                        // the next power (the loop branch crosses a page)
        }
        charge(c + 6)
    }

    // MARK: Fields of a page ($B371, $B3C0, $B7D2, $B813)

    /// $B371: a field with typed digits was ended: every field of the current page is read back
    /// from the screen into the record (`readPageFields`), then the USER MODE field `$09A5` is
    /// served: ≥ 210 or equal to the current mode: nothing; 110 and up: save to mode n − 100 when
    /// that is below `$0960` (`storeModeRecord`; modes below 10 are never written); below 110:
    /// load mode n when below `$0960`. Anything refused puts the current mode back into `$09A5`.
    /// The page is reprinted and the cursor line restored from `$A9`.
    public func acceptField() {
        let m = mem
        m[Editor.RAM.savedLine] = m[Editor.RAM.cursorLine]
        charge(13)                                   // the cursor line saved; the fields read back
        readPageFields()
        let entry = m[Editor.RAM.userModeEntry]
        var c = 6                                       // 210 or more?
        var refuse = true
        if entry >= 0xD2 {
            c += 3
        } else {
            c += 6                                      // the current mode?
            if entry == m[ModeLibrary.currentMode] {
                c += 3
            } else {
                c += 4                                  // 110 or more: a save?
                if entry >= 0x6E {
                    let mode = entry &- 0x64                // n − 100
                    c += 11                      // within the limit?
                    if mode >= m[ModeLibrary.modeLimit] {
                        c += 3
                    } else {
                        m[ModeLibrary.currentMode] = mode
                        m[Editor.RAM.userModeEntry] = mode
                        charge(c + 16)           // the mode in both places; stored
                        c = 0
                        storeModeRecord()
                        refuse = false
                    }
                } else {
                    c += 6                              // a load: within the limit?
                    if entry >= m[ModeLibrary.modeLimit] {
                        c += 3
                    } else {
                        m[ModeLibrary.currentMode] = entry
                        charge(c + 12)               // the mode loaded
                        loadModeRecord()
                        m[Editor.RAM.userModeEntry] = m[ModeLibrary.currentMode]
                        c = 11                       // the field shows the mode
                        refuse = false
                    }
                }
            }
        }
        if refuse {
            m[Editor.RAM.userModeEntry] = m[ModeLibrary.currentMode]
            c += 11                                  // refused: the field shows the current mode
        }
        // $B3AE
        charge(c + 6)
        printPageFields()
        m[Editor.RAM.cursorLine] = m[Editor.RAM.savedLine]
        charge(13)                                   // the cursor line back
    }

    /// $B3C0: prints every field of page `$094E` from the record: per descriptor the size
    /// (`$095D`), the pointers (`fieldPointers`), the 1 or 2 record bytes into `$094A` (high
    /// byte 0), `printFieldValue`. Leaves `$094D` at the last field's line.
    public func printPageFields() {
        let m = mem
        var c = startFieldWalk()
        while true {
            let size = m[zpPointer(Editor.RAM.descriptorPointer)]
            m[Editor.RAM.fieldSize] = size
            c += 11                                  // the field's size
            if size == 0 {
                charge(c + 8)                           // the list end
                return
            }
            charge(c + 9)                               // its pointers
            fieldPointers()
            let v = Editor.RAM.fieldValue
            m[v] = 0; m[v + 1] = 0; m[v + 2] = 0
            c = 14                               // the value zeroed
            var y = 0
            while true {
                let p = zpPointer(Editor.RAM.linePointer)
                m[(v + y) & 0xFFFF] = m[(p + y) & 0xFFFF]
                c += 5 + Editor.crossing(p, y) + 5          // one record byte
                y = (y + 1) & 0xFF
                c += 6                                  // the field's size reached?
                if y != Int(m[Editor.RAM.fieldSize]) { c += 3 } else { c += 2; break }
            }
            charge(c + 6)
            printFieldValue()
            c = 3                                           // the next descriptor
        }
    }

    /// $B3C0/$B813 heads: `$A5/$A6` = the field list of page `$094E` (pointer at $B01C + X).
    /// Returns the cycles.
    private func startFieldWalk() -> Int {
        let m = mem
        let x = Int(m[Editor.RAM.page])
        m[Editor.RAM.descriptorPointer] = m[(Editor.Table.fieldTables + x) & 0xFFFF]
        m[Editor.RAM.descriptorPointer + 1] = m[(Editor.Table.fieldTables + 1 + x) & 0xFFFF]
        return 8 + Editor.crossing(Editor.Table.fieldTables, x) + 3
            + 4 + Editor.crossing(Editor.Table.fieldTables + 1, x) + 3
    }

    /// $B7D2: for the descriptor at `$A5/$A6`: `$094D` = its line, `$37/$38` = that screen line
    /// + 5 (column 31, the digits), `$39/$3A` = $0964 + its record offset; `$A5/$A6` += 3.
    public func fieldPointers() {
        let m = mem
        let d = zpPointer(Editor.RAM.descriptorPointer)
        let line = m[(d + 1) & 0xFFFF]
        m[Editor.RAM.cursorLine] = line
        let x = Int(line)
        var c = 7 + Editor.crossing(d, 1) + 6       // the line
        var carry = false
        m[Editor.RAM.sourcePointer] = FlightModel.adc(m[(Editor.Table.screenLines + x) & 0xFFFF], 5, &carry)
        m[Editor.RAM.sourcePointer + 1] = FlightModel.adc(0, m[(Editor.Table.screenLines + 1 + x) & 0xFFFF], &carry)
        // The screen line's address + 5.
        c += 4 + Editor.crossing(Editor.Table.screenLines, x) + 7
            + 6 + Editor.crossing(Editor.Table.screenLines + 1, x) + 3
        let d2 = zpPointer(Editor.RAM.descriptorPointer)
        carry = false
        m[Editor.RAM.linePointer] = FlightModel.adc(m[(d2 + 2) & 0xFFFF], 0x64, &carry)
        m[Editor.RAM.linePointer + 1] = FlightModel.adc(0, 0x09, &carry)
        c += 7 + Editor.crossing(d2, 2) + 14   // the record offset + $0964
        let next = Int(m[Editor.RAM.descriptorPointer]) + 3
        m[Editor.RAM.descriptorPointer] = UInt8(next & 0xFF)
        c += 10                                  // the next descriptor
        if next < 0x100 {
            c += 3
        } else {
            m[Editor.RAM.descriptorPointer + 1] &+= 1
            c += 7
        }
        charge(c + 6)
    }

    /// $B813: reads every field of page `$094E` back from the screen: the characters from
    /// column 31 up to the first space (at most 256; the last six kept, the last typed first)
    /// are parsed (`parseFieldValue`) and the low 1 or 2 bytes stored into the record.
    public func readPageFields() {
        let m = mem
        var c = startFieldWalk()
        while true {
            let size = m[zpPointer(Editor.RAM.descriptorPointer)]
            m[Editor.RAM.fieldSize] = size
            c += 11                                  // the field's size
            if size == 0 {
                charge(c + 8)                           // the list end
                return
            }
            charge(c + 9)                               // its pointers
            fieldPointers()
            for x in 0..<6 { m[Editor.RAM.typedDigits + x] = 0x30 }
            c = 2 + 6 * 12 - 1 + 2             // the digits set to '0'
            var y = 0
            while true {
                let p = zpPointer(Editor.RAM.sourcePointer)
                let ch = m[(p + y) & 0xFFFF]
                c += 5 + Editor.crossing(p, y) + 2          // a space?
                if ch == 0x20 { c += 3; break }             // the field's end
                for x in stride(from: 4, through: 0, by: -1) {
                    m[Editor.RAM.typedDigits + 1 + x] = m[Editor.RAM.typedDigits + x]
                }
                let p2 = zpPointer(Editor.RAM.sourcePointer)
                m[Editor.RAM.typedDigits] = m[(p2 + y) & 0xFFFF]
                y = (y + 1) & 0xFF
                // The digits shifted up with the character first; on to the next (256 at most).
                c += 2 + 2 + 5 * 14 - 1 + 5 + Editor.crossing(p2, (y - 1) & 0xFF) + 6
                if y != 0 { c += 3 } else { c += 2; break }
            }
            charge(c + 6)
            parseFieldValue()
            c = 2                                           // the first byte
            var k = 0
            while true {
                let p = zpPointer(Editor.RAM.linePointer)
                m[(p + k) & 0xFFFF] = m[(Editor.RAM.fieldValue + k) & 0xFFFF]
                c += 4 + Editor.crossing(Editor.RAM.fieldValue, k) + 6   // one byte into the record
                k = (k + 1) & 0xFF
                c += 6                                  // the field's size reached?
                if k != Int(m[Editor.RAM.fieldSize]) { c += 3 } else { c += 2; break }
            }
            c += 3                                          // the next descriptor
        }
    }
}
