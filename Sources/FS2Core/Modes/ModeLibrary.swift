import Foundation

/// The mode library: the 65-byte mode record at $0964-$09A4, the ten built-in modes in the
/// editor overlay, the fifteen user modes at `[$0961]` = $C800, and the library disk (logical
/// block 64) the editor's CTRL-X loads and CTRL-Z formats and writes. See `re/docs/editor.md`.
///
/// | Modes | Where | Notes |
/// |---|---|---|
/// | 0-9 | `builtInModes` $B9E1 (editor overlay), 10 x 65 bytes | read only |
/// | 10-24 | `[$0961]` ($C800), 15 x 65 bytes = 975 of the block's 1024 | `storeModeRecord` writes them |
///
/// The persistence hook: the original reads and writes the library on a separate disk with its
/// IEC loader. The port hands the block to `Machine.modeLibraryIO` instead (the native engine
/// maps it to `ModeLibrary.bin`), and reproduces every byte the loader leaves in memory.
public enum ModeLibrary {
    /// $0960: the number of modes (25); USER MODE entries at or above it are refused.
    public static let modeLimit = 0x0960
    /// $0961/$0962: the user library base ($C800).
    public static let userLibraryPointer = 0x0961
    /// $0963: the current mode, 0-24.
    public static let currentMode = 0x0963
    /// $0964-$09A4: the mode record.
    public static let record = 0x0964
    public static let recordSize = 65
    /// $095C: `loadModeRecord`/`storeModeRecord` direction (0 load, 1 store); the editor also
    /// uses it as its digit scratch byte.
    public static let transferDirection = 0x095C
    /// $B9E1: the built-in modes 0-9 (editor overlay).
    public static let builtInModes = 0xB9E1
    public static let builtInCount = 10
    public static let userModeCount = 15
    /// The library is logical block 64 of the library disk ($40).
    public static let libraryBlock: UInt8 = 0x40
    public static let blockSize = 1024

    /// The byte offset of user mode `mode` (10-24) in the library block.
    public static func userRecordOffset(_ mode: Int) -> Int { (mode - builtInCount) * recordSize }

    /// What CTRL-X and CTRL-Z ask of the library disk.
    public struct IO {
        /// CTRL-X: the 1024-byte library block, or nil when there is no library (the editor then
        /// shows its disk-error line).
        public var load: () -> [UInt8]?
        /// CTRL-Z: "format the disk and save": replace the library with this 1024-byte block.
        /// Returns false when it could not be written (the editor shows its disk-error line).
        public var formatAndSave: ([UInt8]) -> Bool

        public init(load: @escaping () -> [UInt8]?, formatAndSave: @escaping ([UInt8]) -> Bool) {
            self.load = load
            self.formatAndSave = formatAndSave
        }
    }

    /// A library disk kept in memory (tests, and an app session before the first save).
    public final class InMemoryStore {
        /// The block on the "disk", nil when no library was ever written.
        public var block: [UInt8]?
        /// How many times each side was used.
        public private(set) var loads = 0, saves = 0
        /// When set, every request fails (no disk / write error).
        public var failing = false

        public init(block: [UInt8]? = nil) { self.block = block }

        public var io: IO {
            IO(load: { [self] in
                loads += 1
                return failing ? nil : block
            }, formatAndSave: { [self] data in
                saves += 1
                guard !failing else { return false }
                block = data
                return true
            })
        }
    }

    /// The drive status a 1541 reports when it cannot read the disk: the port's answer when the
    /// hook has no library (or cannot save one). `$7325` = $74.
    static let driveNotReady: [UInt8] = Array("74,DRIVE NOT READY,00,00\r".utf8)

    /// Times of the loader's DOS command and block write as the lab's 1541 answers them (see
    /// `EditorLibraryTests.measure`: the lab's $7312 call takes 148,097 cycles in all, its
    /// $730C 1,316,471); the open, read and close reuse `Scenery.Loader`. Like the loader's, they
    /// are wall time (`Machine.elapse`): measured in the editor's text mode, whose badlines the
    /// lab's VIC takes meanwhile.
    public enum Timing {
        /// $7312 → $7457 up to the error test after its status read: the 20 command bytes to
        /// channel 15 and the status (the format itself costs nothing in the lab's drive).
        public static let dosCommandCycles = 52_167
        /// One sector of $730C: 256 data bytes to channel 2, the "U2" command and the status.
        public static let sectorWriteCycles = 324_538
    }

}

extension Machine {
    // MARK: Mode records ($B98D, $B998)

    /// $B998: copies mode `$0963` into the record $0964-$09A4 (built-in modes from $B9E1, user
    /// modes from `[$0961]`). Clobbers A, X, Y, `$39/$3A`, `$095C` = 0.
    public func loadModeRecord() {
        charge(2)                                           // direction 0: load
        modeRecordTransfer(0)
    }

    /// $B98D: copies the record into mode `$0963`'s slot, for modes 10 and up only (below 10:
    /// nothing, 15 cycles). Clobbers A, X, Y, `$39/$3A`, `$095C` = 1.
    public func storeModeRecord() {
        guard mem[ModeLibrary.currentMode] >= 0x0A else {
            charge(15)                           // a built-in mode: nothing ($B98C returns)
            return
        }
        charge(13)                           // direction 1: store
        modeRecordTransfer(1)
    }

    /// $B99A: `$095C` = direction; `$39/$3A` = $B9E1, or `[$0961]` with the mode − 10 for modes
    /// ≥ 10; + 65 per mode (the count runs down until it turns negative, so an index of $81 or
    /// more adds nothing; a page carry that wraps the high byte to 0 stops the walk); then the
    /// 65 bytes, Y = $40 down to 0, in the direction `$095C` holds at each step.
    private func modeRecordTransfer(_ direction: UInt8) {
        let m = mem
        m[ModeLibrary.transferDirection] = direction
        m[0x39] = 0xE1
        m[0x3A] = 0xB9
        var c = 20                   // the direction, the built-in base; a user mode?
        var a = m[ModeLibrary.currentMode]
        if a < 0x0A {
            c += 3
        } else {
            a &-= 0x0A                                      // the compare left the carry set
            m[0x39] = m[ModeLibrary.userLibraryPointer]
            m[0x3A] = m[ModeLibrary.userLibraryPointer + 1]
            c += 18                      // the user library base
        }
        c += 2
        var x = a
        while true {
            x &-= 1
            c += 2                                          // one mode fewer
            if x & 0x80 != 0 { c += 3; break }              // done
            let sum = Int(m[0x39]) + 0x41
            m[0x39] = UInt8(sum & 0xFF)
            c += 12                          // + 65
            if sum < 0x100 { c += 3; continue }
            m[0x3A] &+= 1
            c += 7                                      // the page carry
            if m[0x3A] != 0 { c += 3; continue }
            c += 2
            break
        }
        c += 2                                              // the last byte first
        for y in stride(from: 0x40, through: 0, by: -1) {
            let p = zpPointer(0x39)
            c += 4                                          // the direction, read at every byte
            if m[ModeLibrary.transferDirection] != 0 {
                m[(p + y) & 0xFFFF] = m[ModeLibrary.record + y]
                c += 15                          // store: record to slot
            } else {
                m[ModeLibrary.record + y] = m[(p + y) & 0xFFFF]
                c += 8 + Editor.crossing(p, y) + 5      // load: slot to record
            }
            c += 2 + (y > 0 ? 3 : 2)                        // the next byte down
        }
        charge(c + 6)
    }

    // MARK: Save and recall ($B7A5, $B7C3)

    /// $B7A5 ('S' in flight through `$08BB` = 2, or 'S' in the editor): a built-in current mode
    /// n < 10 becomes user mode n + 10 (`$09A5` = `$0963` = n + 10); then, when the mode is
    /// below `$0960`, the record is stored in its slot and recalled (`recallKey`, which reprints
    /// the page). A mode ≥ `$0960` does nothing.
    public func saveUserMode() {
        let m = mem
        let mode = m[ModeLibrary.currentMode]
        if mode < 0x0A {
            let user = mode &+ 0x0A                         // the compare left the carry clear
            m[Editor.RAM.userModeEntry] = user
            m[ModeLibrary.currentMode] = user
            charge(21)               // the new user mode in both places
        } else {
            charge(13)                           // a user mode: within the limit?
            guard mode < m[ModeLibrary.modeLimit] else {
                charge(9)                               // no: nothing
                return
            }
            charge(2)
        }
        charge(6)
        storeModeRecord()
        charge(6)
        recallKey()
        charge(6)
    }

    /// $B7C3 ('+' in the editor; also after a save): reloads mode `$0963` into the record and
    /// reprints the page's fields, keeping the cursor line `$094D` (pushed and pulled).
    public func recallKey() {
        let m = mem
        let line = m[Editor.RAM.cursorLine]
        charge(13)                                   // the cursor line kept on the stack
        loadModeRecord()
        charge(6)
        printPageFields()
        m[Editor.RAM.cursorLine] = line
        charge(14)                                   // the cursor line back
    }

    // MARK: The library disk ($B1F1, $B223, $B289)

    /// $B289: points the loader at the library: destination `$731E/$731F` = `[$0961]`, block
    /// `$731C` = $40.
    public func setLibraryBlock() {
        let m = mem
        m[Scenery.Loader.destination] = m[ModeLibrary.userLibraryPointer]
        m[Scenery.Loader.destination + 1] = m[ModeLibrary.userLibraryPointer + 1]
        m[Scenery.Loader.block] = ModeLibrary.libraryBlock
        charge(28)
    }

    /// $B1F5 (CTRL-X, after the key compare): loads the library block into `[$0961]`, reloads
    /// the current mode and reprints the page (cursor line kept through `$A9`), closes the
    /// channels (`$2039`), and goes back to the field input (through $B245 to $B198, charged
    /// here).
    ///
    /// The original opens the drive ($7306), reads block 64 ($7309) and closes ($2039 → $730F)
    /// with interrupts masked throughout (`sei()`/`cli()`: the scheduler holds the raster IRQ for
    /// the whole disk I/O, about 90 frames, and takes the one the VIC latched once they are
    /// unmasked). The port asks `modeLibraryIO.load()`: with a block the open, the read (of that
    /// block, as if the library disk were in the drive) and the close leave exactly the loader's
    /// memory; without one the open reports the 1541's "74,DRIVE NOT READY" status and the
    /// editor's error path copies the disk-error line ($0E8E) to screen row 24 (no close, as in
    /// the original).
    func libraryLoad() {
        let m = mem
        charge(6)
        setLibraryBlock()
        sei()
        charge(8)                                       // interrupts masked; the open
        let block = modeLibraryIO?.load()
        guard let block, block.count == ModeLibrary.blockSize else {
            libraryOpenFailed()
            charge(4)                                       // the error path (the branch crosses a page)
            libraryDiskError()
            return
        }
        loaderOpen()
        charge(11)                                   // the read
        loaderRead(data: block)                             // block 64 of the library disk
        m[0xA9] = m[Editor.RAM.cursorLine]
        charge(15)                               // the cursor line kept in $A9; the mode reloaded
        loadModeRecord()
        charge(6)
        printPageFields()
        m[Editor.RAM.cursorLine] = m[0xA9]
        charge(10)                                   // the cursor line back
        libraryDone()
    }

    /// $B227 (CTRL-Z, after the key compare): formats the disk in the drive (the new-disk
    /// command at $7343) and writes `[$0961]`..+1023 as block 64, then closes (`$2039`) and goes
    /// back to the field input. The port hands the 1024 bytes to `modeLibraryIO.formatAndSave`
    /// first; on success the open, the DOS command (which closes and reopens), the block write
    /// and the close leave the loader's memory as the original's do; on failure the open
    /// reports "74,DRIVE NOT READY" and the disk-error line is shown.
    func librarySave() {
        let m = mem
        let start = Int(m[ModeLibrary.userLibraryPointer]) | Int(m[ModeLibrary.userLibraryPointer + 1]) << 8
        let data = (0..<ModeLibrary.blockSize).map { m[(start + $0) & 0xFFFF] }
        sei()
        charge(8)                                       // interrupts masked; the open
        guard modeLibraryIO?.formatAndSave(data) == true else {
            libraryOpenFailed()
            charge(3)                                       // the error path
            libraryDiskError()
            return
        }
        loaderOpen()
        charge(8)                                       // the new-disk command
        loaderDosCommand()
        charge(8)                                       // the library block
        setLibraryBlock()
        charge(6)
        loaderWriteBlock()
        charge(2)
        libraryDone()
    }

    /// $B23A: closes the channels ($2039), unmasks interrupts and goes back to the field input
    /// (through $B245 to $B198).
    private func libraryDone() {
        charge(9)                                       // the close, through the $2039 vector
        cacheHelper()
        cli()
        charge(8)                                   // unmasked; back to the field input
    }

    /// $B216: the disk-error line: the 40 bytes $0E8E-$0EB5 (the read/write error message) to
    /// screen row 24 ($07C0-$07E7), then interrupts unmasked and back to the field input.
    private func libraryDiskError() {
        let m = mem
        for x in stride(from: 0x28, through: 1, by: -1) { m[0x07BF + x] = m[0x0E8D + x] }
        // The 40-byte copy, counting down to 0, then an always-taken branch onward.
        charge(2 + 40 * 14 - 1 + 3)
        cli()
        charge(8)                                   // unmasked; back to the field input
    }

    /// The open ($7306) when the drive has no library disk: the open's memory as usual, but the
    /// status channel answers "74,DRIVE NOT READY,00,00" (`$7325` = $74, so the open returns
    /// with the carry set).
    private func libraryOpenFailed() {
        let m = mem
        loaderOpen()
        for (k, b) in ModeLibrary.driveNotReady.enumerated() { m[0x7579 + k] = b }
        m[0x7325] = (m[0x7579] << 4) | (m[0x757A] & 0x0F)
    }

    // MARK: The loader's DOS command and block write (memory effects)

    /// One transfer to the drive (LISTEN, data bytes, UNLISTEN): `$B8` = 0 at the start, the
    /// loader's data transfer (`serialTransfer`: the first byte buffered, the UNLISTEN sends it
    /// with EOI), then `$B9` = $FF and `$BB` = 0 after the last byte sent.
    private func listenTransfer() {
        let m = mem
        m[0xB8] = 0
        serialTransfer()
        m[0xB9] = 0xFF
        m[0xBB] = 0
    }

    /// $7312 → $7457 (after `loaderOpen`): sends the DOS new-disk command "N0:..." (20 bytes from
    /// $7343: `$7324` = $14, `$A5/$A6` = $7343) to channel 15 (`$7323` = $0F), reads the status
    /// (`loaderStatus`: "00, OK,00,00"), then closes ($730F) and reopens ($7306) the channels.
    public func loaderDosCommand() {
        let m = mem
        m[0x7324] = 0x14
        m[0xA5] = 0x43
        m[0xA6] = 0x73
        m[0x7323] = 0x0F
        listenTransfer()
        loaderStatus()
        elapse(ModeLibrary.Timing.dosCommandCycles)
        charge(6)
        loaderClose()
        charge(8)                                       // the reopen
        loaderOpen()
        charge(6)
    }

    /// $730C → $73B4: writes block `$731C` from `$731E/$731F`: the first sector from the mask
    /// walk ($74DC), `$7335` = '2' ("U2"), then per sector the track/sector digits ($755A),
    /// `$A5/$A6` = `$C2/$C3`, `$7324` = 1, the 256 data bytes to channel 2 ($765B: `$7323` = 2),
    /// the 12-byte "U2:2 0 tt ss" command to channel 15 ($7571: `$7324` = $0C, `$A5/$A6` =
    /// $7334; $7657: `$7323` = $0F), the status, the source page `$C3` + 1; the next sector
    /// ($7542). Then `$731C` += 1 and `$731E/$731F` = `$C2/$C3` (4 pages on).
    public func loaderWriteBlock() {
        let m = mem
        m[0xC2] = m[Scenery.Loader.destination]
        m[0xC3] = m[Scenery.Loader.destination + 1]
        var c = 23                       // the source pointer to $C2/$C3; the first sector
        c += loaderFindFirstSector()
        m[0x7335] = 0x32
        m[0x38] = 4
        c += 13                              // "U2"; four sectors
        charge(c)
        for _ in 0..<4 {
            m[0x733B] = 0x30 | m[0xBF] >> 4
            m[0x733C] = 0x30 | m[0xBF] & 0x0F
            m[0x733E] = 0x30 | m[0xBE] >> 4
            m[0x733F] = 0x30 | m[0xBE] & 0x0F
            m[0xA5] = m[0xC2]
            m[0xA6] = m[0xC3]
            m[0x7324] = 1
            m[0x7323] = 2
            listenTransfer()
            m[0x7324] = 0x0C
            m[0xA5] = 0x34
            m[0xA6] = 0x73
            m[0x7323] = 0x0F
            listenTransfer()
            loaderStatus()
            m[0xC3] &+= 1
            m[0x38] &-= 1
            elapse(ModeLibrary.Timing.sectorWriteCycles)
            c = 10                                       // the next page; one sector fewer
            if m[0x38] != 0 {
                c += 8 + loaderNextSector() + 5     // the next sector
            } else {
                c += 3
            }
            charge(c)
        }
        m[Scenery.Loader.block] &+= 1
        m[Scenery.Loader.destination] = m[0xC2]
        m[Scenery.Loader.destination + 1] = m[0xC3]
        charge(28)                   // the next block; the destination moved on
    }
}
