/// Scenery streaming: the scenery root pointer $E565, the block cache $E58F and the synchronous
/// block read $E63C.
///
/// SubLogic's IEC loader ($7300-$7834) is not ported: block reads are direct copies from
/// `Machine.diskBlocks`. They stay memory-faithful: the destination bytes (with the loader's
/// guard against stores at $C000 and above), the slot tags `$0900-$0903`, the border counter,
/// the sprite and VIC changes, and every byte the loader leaves behind in zero page and in its
/// own variables (`Scenery.Loader`) are reproduced. The load takes the time measured in the lab,
/// as it passes there: each sector's bytes land one by one at the drive's pace.
extension Machine {
    // MARK: setSceneryRoot ($E565)

    /// $E565: the display-list PC `$8B/$8C` = the word at $A7E0 (the loaded overlay's end, where
    /// the root list sits: $A800 in flight). Run by the main loop every pass.
    ///
    /// The rest of the original routine ($E56F-$E58C) is SubLogic's delayed copy-protection hang
    /// and is not ported. Its pass-through path on an intact disk (one flag test, 7 cycles) is
    /// charged as plain time so the pass keeps the original's length.
    public func setSceneryRoot() {
        let m = mem
        m[0x8B] = m[0xA7E0]
        m[0x8C] = m[0xA7E1]
        charge(27)
    }

    // MARK: loadBlockCached ($E58F, vector $2036)

    /// $0900-$0903: the block cache slots (the first block loaded into each).
    public static let blockCacheSlots = 0x0900
    /// $08FB-$08FF: the current block request (block, count, destination, slot).
    public static let blockRequest = 0x08FB

    /// $E58F (vector $2036, op 0D): loads `$08FC` blocks from block `$08FB` to `$08FD/$08FE` for
    /// slot `$08FF`, unless the slot already holds that block (21 cycles). A load records the
    /// block in the slot, zeroes the slots above it (their contents sat on top of this one), and
    /// reads synchronously (`readBlocks`), with `$9E/$9F` = block, count and `$731E/$731F` = the
    /// destination.
    public func loadBlockCached() {
        let m = mem
        let slot = Int(m[Self.blockRequest + 4])
        let block = m[Self.blockRequest]
        guard m[Self.blockCacheSlots + slot] != block else {
            charge(21)                       // already cached: return
            return
        }
        m[Self.blockCacheSlots + slot] = block
        m[0x9E] = block
        var c = 24                   // the slot test, the block recorded
        var x = slot
        while true {
            x = (x + 1) & 0xFF
            c += 4                                      // the next slot
            if x >= 4 { c += 3; break }                     // past the last slot
            m[Self.blockCacheSlots + x] = 0
            c += 10                                  // zeroed
        }
        m[0x9F] = m[Self.blockRequest + 1]
        m[Scenery.Loader.destination] = m[Self.blockRequest + 2]
        m[Scenery.Loader.destination + 1] = m[Self.blockRequest + 3]
        charge(c + 29)              // the count and destination, then the read ($E63C)
        readBlocks()
        charge(6)                                           // return
    }

    // MARK: readBlocks ($E63C)

    /// $E63C: reads `$9F` blocks (0 = 256) from block `$9E` to the address in `$731E/$731F`.
    ///
    /// `$0E8A/$0E8B` = the destination and `$0E8C/$0E8D` = `$9E/$9F` (kept for the disk-error
    /// prompt), `$731C` = the block. Sprites go off (`$D015` read through `readIO`, saved and
    /// restored), `$08DA` and `$7327` (the loader's guard: no stores at $C000 and above) are 1
    /// during the load, the IRQ is masked (from $E668 to $E698) and `$D018`/`$D016` are
    /// forced to $F0/$D8 (the raster split stops; they stay so until the next raster IRQ). Per
    /// block the border counter `$0E88` is incremented and shown in `$D020`, and `$9F` counts
    /// down to 0. Disk errors cannot happen with the imported image, so the retry path ($E6A6)
    /// and the error prompt are not ported.
    ///
    /// Charges from $E63C through its return, the loader's measured time included (`loaderOpen`,
    /// `loaderRead`, `loaderClose`: the drive's part as wall time, the bytes stored as they come),
    /// so the clock's events (the frame ends above all) keep their times during a long load. The
    /// IRQ is held for the whole load (`sei()`), and the unmasking lets it in again whatever the
    /// flag was before: in the RUN/STOP + RESTORE restart, entered from the NMI with the flag set,
    /// the overlay-0 reload takes the IRQ the VIC latched right after each of its two loads, as
    /// the C64 does. `cli()` comes after the tail's memory effects and before its charge, so the
    /// held IRQ runs once `$D015` is restored (on the C64 it comes right after the unmasking, some
    /// 20 cycles before the restore; its handler reads none of those bytes) and the panel phase
    /// latches the sprites the VIC shows.
    public func readBlocks() {
        let m = mem
        precondition(!diskBlocks.isEmpty, "readBlocks needs Machine.diskBlocks")
        let destination = u16(Scenery.Loader.destination)
        m[0x0E8A] = UInt8(destination & 0xFF)
        m[0x0E8B] = UInt8(destination >> 8)
        m[0x0E8C] = m[0x9E]
        m[0x0E8D] = m[0x9F]
        m[Scenery.Loader.block] = m[0x9E]
        let sprites = readIO(0xD015)
        io.writeVIC(0x15, 0)
        m[0x08DA] = 1
        m[Scenery.Loader.guardFlag] = 1
        sei()                                               // $E668
        io.writeVIC(0x18, 0xF0)
        io.writeVIC(0x16, 0xD8)
        // The saves, the sprites off, both flags, the mask, the split forced and the open call.
        charge(80)
        loaderOpen()
        charge(Scenery.Loader.checkCycles + 2)              // the error check (no error)
        repeat {
            m[0x0E88] &+= 1
            io.writeVIC(0x20, m[0x0E88])
            charge(20)                           // the border counter shown, the read ($7309)
            loaderRead()
            m[0x9F] &-= 1
            charge(Scenery.Loader.checkCycles + 7 + (m[0x9F] != 0 ? 3 : 2))   // check, count down
        } while m[0x9F] != 0
        charge(6)                                           // the close ($730F)
        loaderClose()
        m[0x08DA] = 0
        m[Scenery.Loader.guardFlag] = 0
        io.writeVIC(0x15, sprites)
        cli()                                               // $E698
        // The error check, the unmasking, both flags cleared, the sprites back, the return.
        charge(Scenery.Loader.checkCycles + 28)
    }
}

extension Scenery {
    /// The memory SubLogic's stage-2 loader ($7300-$7834) leaves behind. The loader itself is
    /// not ported (`re/docs/excluded.md`); these are its effects on RAM, derived from its code
    /// and confirmed against it in the lab (`SceneryStreamingTests`).
    ///
    /// | Bytes | Meaning |
    /// |---|---|
    /// | `$731C` | block to read next (`$7309` increments it) |
    /// | `$731E/$731F` | destination, advanced 256 bytes per sector (stuck at $C000 under the guard) |
    /// | `$7327` | the guard: while set, no byte is stored at $C000 and above (the pointer stops) |
    /// | `$C2/$C3` | the destination pointer of the read (restored around status reads) |
    /// | `$C0/$C1`, `$37`, `$39`, `$3A`, `$BE`, `$BF` | the walk over the sector-usage mask $7473: counter, mask byte, bit count, byte index, sector and track (BCD) of the last sector |
    /// | `$38` | sectors left in the block (0 afterwards) |
    /// | `$7335`, `$733B-$733F` | the "U1:2 0 tt ss" command: '1' (read), track and sector digits |
    /// | `$A5/$A6` | the command pointer ($7334 after a read, $7342 after an open) |
    /// | `$7322-$7325` | device (8 + `$731B`), secondary address, command length, status |
    /// | `$7579-$7585` | the drive status message "00, OK,00,00" + CR |
    /// | `$B8`, `$B9`, `$BB`, `$BD` | serial status ($40), last byte sent ($FF), bit counter (0), last byte received |
    /// | `$BA`, `$BC` | the buffered-byte flag and the EOI flag: each data transfer rotates them (see `serialTransfer`) |
    public enum Loader {
        public static let block = 0x731C
        public static let destination = 0x731E
        public static let guardFlag = 0x7327
        /// $7473: 3 mask bytes per track (bit 7 first = sector 0), $69 bytes.
        public static let sectorMask = 0x7473
        /// The disk status message the 1541 reports after every command here.
        static let statusMessage: [UInt8] = Array("00, OK,00,00\r".utf8)

        /// The disk-error check $732B (vectored to $5FAB) on success, including the call.
        public static let checkCycles = 18
        /// Measured in the lab (`SceneryStreamingTests.loaderTiming`): the IEC parts of the open
        /// ($7306), of one sector of a read ($7657 + $75A1 + $7618 + the per-byte store loop) and
        /// of the close ($730F), each including its calls and return. These are wall time
        /// (`Machine.elapse`): the loader waits on the drive, and the lab's figures already hold
        /// its VIC's badlines (measured in flight; the editor's text mode has the same).
        public static let openCycles = 58_650
        public static let sectorCycles = 382_690
        /// How a sector's time passes (`SceneryStreamingTests.loaderByteSchedule`, from the lab's
        /// stores): the command "U1", the status and the TALK up to the first data byte, then one
        /// byte every 1,296 cycles, the last one followed by the UNTALK.
        public static let sectorByteCycles = 1_296
        public static let sectorTailCycles = 2_296
        public static let sectorHeadCycles = sectorCycles - 255 * sectorByteCycles - sectorTailCycles
        public static let closeCycles = 37_260
        /// The close when it starts by flushing a buffered byte (`$BA` bit 7): the lab's drive
        /// answers it faster.
        public static let closeFlushedCycles = 31_100
        /// The guarded store loop of $7618: a byte stored costs 15 cycles more than one skipped
        /// (the store and the pointer step; the branch that skips takes one more) and a page wrap
        /// 4 more.
        static let storedByteCycles = 15
    }
}

extension Machine {
    // MARK: The loader's memory effects

    /// The `$7688` check before every IEC command byte: a buffered data byte (`$BA` bit 7) is
    /// sent with EOI first: the EOI flag goes into `$BC`, which ends up shifted right twice, and
    /// `$BA` is shifted right once.
    private func serialFlushBuffered() {
        let m = mem
        guard m[0xBA] & 0x80 != 0 else { return }
        m[0xBC] = 0x40 | m[0xBC] >> 2
        m[0xBA] >>= 1
    }

    /// One data transfer to the drive (`$7752` for the first byte rotates the buffered flag into
    /// `$BA`; the command that follows flushes it: `serialFlushBuffered`). The editor's library
    /// commands and block write use it too (`ModeLibrary.swift`).
    func serialTransfer() {
        let m = mem
        if m[0xBA] & 0x80 == 0 { m[0xBA] = 0x80 | m[0xBA] >> 1 }
        serialFlushBuffered()
    }

    /// A status read (`$75A1`): the message lands at $7579 through `$C2/$C3` (restored after),
    /// `$7325` = the status code, `$B8` = $40 (EOI), `$BD` = the last byte (CR). `$7323` is
    /// restored. The editor's library commands read the status this way too (`ModeLibrary.swift`).
    func loaderStatus() {
        let m = mem
        for (k, b) in Scenery.Loader.statusMessage.enumerated() { m[0x7579 + k] = b }
        m[0x7325] = (m[0x7579] << 4) | (m[0x757A] & 0x0F)
        m[0xB8] = 0x40
        m[0xBD] = 0x0D
    }

    /// $7306 (open: UNTALK, UNLISTEN, open 15, "I0", open 2 "#", status).
    public func loaderOpen() {
        let m = mem
        m[0x7322] = m[0x731B] &+ 8
        serialFlushBuffered()                               // the UNTALK
        serialTransfer()                                    // "I0" to channel 15
        serialTransfer()                                    // "#" to channel 2
        m[0xA5] = 0x42; m[0xA6] = 0x73
        m[0x7324] = 1
        loaderStatus()
        m[0x7323] = 0xF2
        m[0xB9] = 0xFF
        m[0xBB] = 0
        elapse(Scenery.Loader.openCycles)
    }

    /// $730F (close channels 2 and 15, status). Its first LISTEN ($7686) sends a byte still
    /// buffered from earlier output (`$BA` bit 7, possible after the editor's own disk I/O and
    /// field printing) with EOI first.
    public func loaderClose() {
        let m = mem
        let flushed = m[0xBA] & 0x80 != 0
        serialFlushBuffered()
        loaderStatus()
        m[0x7323] = 0x0F
        m[0xB9] = 0xFF
        m[0xBB] = 0
        elapse(flushed ? Scenery.Loader.closeFlushedCycles : Scenery.Loader.closeCycles)
    }

    /// $7309: reads block `$731C` (four sectors) to `$731E/$731F` with the `$7327` guard, then
    /// `$731C` += 1 and `$731E/$731F` = the advanced pointer. Charges the walk over the sector
    /// mask exactly and the IEC part per sector as measured, each byte stored when the lab's
    /// loader stores it. The block comes from `diskBlocks`.
    public func loaderRead() {
        loaderRead(data: diskBlocks[Int(mem[Scenery.Loader.block])])
    }

    /// $7309 with `data` (1024 bytes) as what the drive returns for block `$731C`: the editor's
    /// CTRL-X reads its library disk this way (`ModeLibrary.IO`), without touching `diskBlocks`.
    /// Everything else is `loaderRead`'s: the sector walk of block `$731C`, the guard, the
    /// loader's memory and time.
    public func loaderRead(data: [UInt8]) {
        precondition(data.count == 4 * 256, "a logical block is 1024 bytes")
        let m = mem
        m[0xC2] = m[Scenery.Loader.destination]
        m[0xC3] = m[Scenery.Loader.destination + 1]
        // The destination into $C2/$C3, then the first-sector search ($74DC).
        var c = 20
        c += loaderFindFirstSector()
        m[0x7335] = 0x31
        m[0x38] = 4
        c += 13                              // the read command's digit, four sectors
        charge(c)
        for sector in 0..<4 {
            // $755A: the track and sector digits; $7571: the "U1:2 0 tt ss" command.
            m[0x733B] = 0x30 | m[0xBF] >> 4
            m[0x733C] = 0x30 | m[0xBF] & 0x0F
            m[0x733E] = 0x30 | m[0xBE] >> 4
            m[0x733F] = 0x30 | m[0xBE] & 0x0F
            m[0x7324] = 0x0C
            m[0xA5] = 0x34; m[0xA6] = 0x73
            serialTransfer()
            loaderStatus()
            m[0x7323] = 2
            // The digits ($755A, 98 cycles) and the command setup ($7571, 16); then the IEC
            // part: the command, the status and the first byte.
            charge(134)
            elapse(Scenery.Loader.sectorHeadCycles)
            // The 256 bytes of the sector through the pointer `$C2/$C3` with the guard, one every
            // `sectorByteCycles`: a byte the guard skips takes 15 cycles less in the store loop,
            // a page wrap 4 more (charged with the next byte).
            var adjustment = 0
            for k in 0..<256 {
                if k > 0 { elapse(Scenery.Loader.sectorByteCycles + adjustment) }
                let v = data[sector * 256 + k]
                if m[Scenery.Loader.guardFlag] != 0, m[0xC3] >= 0xC0 {
                    adjustment = -Scenery.Loader.storedByteCycles
                    continue
                }
                m[zpPointer(0xC2)] = v
                m[0xC2] &+= 1
                adjustment = 0
                if m[0xC2] == 0 { m[0xC3] &+= 1; adjustment = 4 }
            }
            m[0xB8] = 0x40
            m[0xBD] = data[sector * 256 + 255]
            elapse(Scenery.Loader.sectorTailCycles + adjustment)
            m[0x38] &-= 1
            // The sector count, and for the next sector the walk from $7542.
            c = 5
            if m[0x38] != 0 {
                c += 8 + loaderNextSector() + 5
            } else {
                c += 3
            }
            charge(c)
        }
        m[Scenery.Loader.block] &+= 1
        m[Scenery.Loader.destination] = m[0xC2]
        m[Scenery.Loader.destination + 1] = m[0xC3]
        m[0xB9] = 0xFF
        m[0xBB] = 0
        charge(28)                   // the next block, the pointer saved, the return
    }

    /// $74DC: finds the first sector of block `$731C` by walking the sector-usage mask: the
    /// counter `$C0/$C1` = block · 4 counts the used sectors down; `$BE`/`$BF` count the sector
    /// and the track in BCD. Returns its cycles, return included (the caller charges them).
    public func loaderFindFirstSector() -> Int {
        let m = mem
        let count = Int(m[Scenery.Loader.block]) << 2
        m[0xC0] = UInt8(count & 0xFF)
        m[0xC1] = UInt8(count >> 8)
        m[0x3A] = 0
        m[0x39] = 0
        m[0xBF] = 1
        m[0xBE] = 0
        return 59 + loaderWalk(fromBitTest: false)
    }

    /// $7542: the next used sector (`$C1` = 0, `$C0` = 1, the walk from the current bit).
    /// Returns its cycles, return included.
    public func loaderNextSector() -> Int {
        mem[0xC1] = 0
        mem[0xC0] = 1
        return 13 + loaderWalk(fromBitTest: true)
    }

    /// The walk $74FA-$7541: per mask bit, a used sector decrements `$C0/$C1`; the sector found
    /// is the one whose decrement takes `$C1` negative. Returns its cycles, return included.
    private func loaderWalk(fromBitTest: Bool) -> Int {
        let m = mem
        var c = 0
        var atBitTest = fromBitTest
        while true {
            if !atBitTest {
                // $74FA: the bit count; a new mask byte every 8 bits.
                m[0x39] &-= 1
                if m[0x39] & 0x80 == 0 {
                    c += 9                              // the branch to $7510 crosses a page
                } else {
                    m[0x39] = 7
                    let x = m[0x3A]
                    precondition(x < 0x69, "block beyond the sector mask")
                    m[0x37] = m[Scenery.Loader.sectorMask + Int(x)]
                    m[0x3A] = x &+ 1
                    c += 31
                }
            }
            atBitTest = false
            // $7510: is the sector used (bit 7 of the mask byte)?
            c += 3
            if m[0x37] & 0x80 != 0 {
                let x = m[0xC0] &- 1
                m[0xC0] = x
                c += 12                      // used: the counter's low byte steps down
                if x == 0xFF {
                    m[0xC1] &-= 1
                    c += 9                          // the borrow into the high byte
                    if m[0xC1] & 0x80 != 0 { return c + 9 }   // negative: found, return
                    c += 2
                } else {
                    c += 3
                }
            } else {
                c += 3
            }
            // $7522: next bit; the sector (BCD) and on wrapping past 23 the track.
            m[0x37] <<= 1
            let sector = Self.bcdIncrement(m[0xBE])
            c += 16                      // the next bit, the sector + 1 in decimal mode
            if sector < 0x24 {
                m[0xBE] = sector
                c += 12                          // stored; the loop branch crosses a page
            } else {
                let track = Self.bcdIncrement(m[0xBF])
                m[0xBF] = track
                precondition(track < 0x36, "track beyond 35")
                m[0xBE] = 0
                c += 29
            }
        }
    }

    /// A decimal-mode increment of a BCD byte.
    @inline(__always)
    static func bcdIncrement(_ v: UInt8) -> UInt8 {
        var lo = (v & 0x0F) + 1, hi = v >> 4
        if lo > 9 { lo -= 10; hi += 1 }
        return (hi << 4 | lo) & 0xFF
    }
}
