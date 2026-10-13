# The mode editor, the mode library and the text screen

The editor is overlay 1 (logical blocks 42-47 at $A7E0-$BC6A, end word $BC6B). Its code is
$B09A-$B9E0; its data are the two page images, the screen-line table, the powers of ten, the field
descriptors and the ten built-in modes. The port is a literal translation:

| File | Routines |
|---|---|
| `Sources/FS2Core/Modes/Editor.swift` | entry and field loop $B09A, cursor and pages $B0FD-$B178 / $B803, keys and digits $B179-$B288, decimal conversion $B29B / $B2D6, page copy $B346, field walks $B371 / $B3C0 / $B7D2 / $B813 |
| `Sources/FS2Core/Modes/EditorConversions.swift` | state → record $B3F6, record → state $B559, winds $B865 / $B901 |
| `Sources/FS2Core/Modes/ModeLibrary.swift` | mode records $B98D / $B998, save $B7A5, recall $B7C3, library disk $B1F1 / $B223 / $B289, the loader's DOS command $7312 and block write $730C (memory effects) |
| `Sources/FS2Core/Display/TextMode.swift` | $2673 (vector $203F), $796C (hook $732E), $794E (hook $7331), $5F40, the text-screen presenter |
| `Sources/C64Kit/FallbackCharset.swift` | the 8 x 8 character set used when no character ROM is imported |

Every routine reads and writes the bytes the original does (zero-page temporaries, the loader's
variables, the stack aside) and charges the original's cycles, page crossings included. The
differential tests check that (see "Tests").

## Entering and leaving

The main loop ($204B) calls slot $A7E8 when `$08BA | $08BB` is nonzero (`Machine.editorRequested`).
With the flight overlay resident the slot calls $2018, which loads overlay 1 (from disk the first
time; afterward it is swapped in from the cache at $D000, `$08BC` = 1) and returns into the
overlay's own $A7EB, a jump to $B09A. After the editor returns the loop sets `$08BC` 0 → 1, or swaps
the editor back into the cache when it was 1. In the port, `editorEntry()` is the slot's target; the
overlay manager is `Overlays.swift` (`scenery-3d.md`).

| Set by | `$08BA` | `$08BB` | What the editor does |
|---|---|---|---|
| E, CLR/HOME | 1 | | the full editor |
| '+' ($2BDF), a crash or splash ($F95D) | | 1 | `loadModeRecord` (mode `$0963`), exit |
| 'S' ($2BE5) | | 2 | `saveUserMode`, exit |
| the demo check ($2133, `$095B` set) | | 3 | `$0963` = 2, `loadModeRecord`, exit |

Any `$08BB` value other than 1 and 2 takes the demo path. Each of these requests is served before
any key, but only after the entry has converted the state and drawn page 0, so the text screen is
up for that moment.

The exit, `recordToState` ($B559, reached by a jump), ends with the editor's return; it clears
`$08BA` and `$08BB`.

### Europe 1917 and the cold restart

On exit, `$0969` (EUROPE 1917) set forces mode 7: `$09A5` = `$0963` = `$0E7C` = 7 and
`loadModeRecord`, which discards whatever else was typed (the aircraft goes to the WWI base).
The main loop checks once per 8 passes (in the `$22 & 4` block, after the demo check, $213D-$2149):
`$0E7C` != 0 and `$0963` != 7 → a jump to $A7E2, a cold restart. The cold-start overlay reloads
everything and the title and both prompts come back. Nothing but a cold start clears `$0E7C`, so
any later mode other than 7 restarts the game. `Machine.warModeRestartDue` is that test, for the
main loop's port.

### Demo

`A. DEMO MODE` increments `$095B`. The main loop then sets `$08BB` = 3, and the editor loads mode
2 and exits. The exit copies `$095B` to `$095A` (demo running) and clears `$095B`. Any key clears
`$095A` ($27DD). A crash reloads mode 2 through `$08BB` = 1, but `$095A` is then 0, because
`$095B` was already cleared. While `$095A` is set, `stateToRecord` does not save `$0ACD/$0ACE`
into `$08B5/$08B6`.

## The text screen

| Step | Routine | Effect |
|---|---|---|
| the vector $203F | $2673 `textModeIrqSwap` | with interrupts masked: `setTextMode` through the hook $732E (→ $796C), `$0E89` = $97, IRQ vector $FFFE/$FFFF = $2304 (the tick-only IRQ: no screen split); then unmasked |
| | $796C `setTextMode` | `$D020` = 8, `$D018` = $16, `$DD00` = $97 (VIC bank 0), `$D011` = $1B, `$D016` = 8, `$D021` = 1, `$D015` = 0, color RAM $0B (through $794E), $0400-$07FF = spaces |
| | $794E `fillColorRam` | A into color RAM $D800-$DBE7, from $DBE7 down through `($39),Y`; leaves `$39/$3A` = $D7FF, X = $FF, Y = 0 |
| exit: the vector $2042 | $25EB `displayInit` | the bitmap display, IRQ vector $2285, color RAM white via `$7331` → $794E (`main-loop.md`) |
| disk-error prompt | $5F40 `restoreGraphics` | when `$0E89` != $97: `$D021` = `$0E69`, `$DD00` = $96, `$D011` = $3B, color RAM 1 |

The screen is dark gray ($0B) characters on white, with an orange border, using the character ROM's
upper/lowercase set at $1800 in bank 0. The page images are screen codes in that set: $41-$5A
display as capitals, $40 is the horizontal line, and $80-$FF are reverse video.

**Port.** Hardware stores go through `io`: `io.writeVIC`, `io.cia2PortA`, and `io.colorRAM` (low
nibbles). The scheduler can tell the text screen by the IRQ vector bytes ($2304) or by `$0E89` =
$97. The original swaps with the IRQ masked (about 21,000 cycles); the port has no
I flag and `charge` runs the scheduler's events inside the swap, so `textModeIrqSwap` stores `$0E89`
and the vector **before** `setTextMode`: an event there runs the tick-only IRQ, which leaves the VIC
alone, and never the split IRQ $2285, which would rewrite `$D011`/`$D016`/`$D018` over the text
screen just set up (`EditorRoutineTests.textModeSwapUnderEvents`). The final bytes and cycles are
the original's. `Machine.presentTextScreen(into:charROM:)` renders the whole frame from one VIC state (there is
no split) with `VICPresenter`. The character ROM is not on the game disk:

- If one was imported (`GameData.charROM`), the presenter uses it, and the frame matches the lab's
  pixel for pixel.
- Without one, `VICPresenter` uses `FallbackCharset.rom`. This is an original 4 KB set in the ROM's
  layout. Capitals and digits sit on rows 1-6, with two-pixel stems. The line character $40 fills
  row 4 across the whole cell, so the rule joins up and leads into '>'. Codes $80-$FF are the
  inverses. Set 1 is unused by the game.

## Pages, lines and fields

`$094E` holds the page × 2 (0 or 2) and `$094D` the cursor line × 2. Lines 1-21 are stops ($02-$2A),
including lines with no field: the blank line 8 and the AIRCRAFT POSITION heading on line 9 of
page 0. The screen-line table $AFD4 holds 25 addresses at column 26 (line 0 = $041A). The arrow
`$40 $40 $3E` sits at columns 26-28, and the digits at columns 31-36.

The field descriptors are two lists, page 0 at $B020 and page 1 at $B05A (found through the
pointers at $B01C). Each record holds the field's size (one byte or a two-byte word), its screen
line × 2 and its offset into the mode record at $0964; a 0 ends each list. The fields, by editor
line:

- **Page 0.** Line 1 USER MODE (kept in `$09A5`, just past the record); lines 2-7 SOUND,
  AUTO-COORDINATION, SLEW, REALITY MODE, EUROPE 1917 and COMMUNICATION RATE; line 8 blank and
  line 9 the AIRCRAFT POSITION heading, neither of them a field; lines 10-21 NORTH POSITION, EAST
  POSITION, ALTITUDE, PITCH, BANK, HEADING, AIRSPEED, THROTTLE, RUDDER, AILERONS, FLAPS and
  ELEVATORS, all words.
- **Page 1.** Lines 1-3 TIME: HOURS, MINUTES and SEASON; lines 4-7 the tops and bottoms of cloud
  layer 2 and then cloud layer 1 (words); lines 8-16 the three wind levels from the top down, each
  a KNOTS line, a DEGREES line and then its SHEAR ZONE ALTITUDE (all words); lines 17-18 SURFACE
  WIND: KNOTS and DEGREES (words); line 19 RELIABILITY FACTOR; lines 20-21 OVER-CONTROL LIMITER
  and ADF ENABLE, which are kept past the record at `$09A9` and `$09AA`.

The fields not marked as words are single bytes.

Page 0 has 19 fields and page 1 has 21. Rows 23-24 of both pages hold a rule of $40 and
`CM-FS2  FIX MODE ... HIT E TO EXIT`.

### Keys ($B179-$B288, through `waitForKey` $2003 → $2250)

| Code | Keys | Action |
|---|---|---|
| $0D | RETURN | Ends the field. If digits were typed, the page is accepted. The cursor moves down a line; after line 21 it goes to the other page's line 1. |
| $2D | '-', ↑ | Ends the field (`$0949` = $2D). The cursor moves up; from line 1 it goes to the other page's line 21. |
| $45 | E | Ends the field (`$0948` + 1). If digits were typed, the page is accepted first. Then the exit. |
| $08 | DEL, ':', ← | Takes back the last digit: a space over it, the buffer shifted down, '0' in at the top. Does nothing when no digit is typed. |
| $2B | '+' | `recallKey`, then the field starts over (typed digits are forgotten) |
| $53 | S | `saveUserMode`, then the field starts over |
| $18 | CTRL-X | `libraryLoad`; the field input goes on |
| $1A | CTRL-Z | `librarySave`; the field input goes on |
| $30-$39 | digits | The first digit blanks columns 31-38. Each digit goes into `$0952` (the buffer shifts up, so the last typed is first), `$0951` += 1, `$094F` += 1, and is echoed at column `26 + $0958` in reverse video (`| $80`). With six digits typed (`$0958` = 11), further digits are ignored. |
| other | | ignored |

**Parsing ($B29B).** `$094A-$094C` = Σ digit·10^k over the six buffer bytes. Each digit is `(char &
$7F) − '0'` taken as an 8-bit count. The power is added that many times, as a 24-bit add with the
carry cleared once per digit, so the carry out of one addition feeds the next. Any byte is accepted.
Only the low 1 or 2 bytes are stored, so 999999 in a 2-byte field is 16959.

**Printing ($B2D6).** Columns 31-36 are blanked. For 100000 down to 1, the power is subtracted
(24 bits) while the result's high byte stays non-negative, counting '0' upward in `$095C`.
The count is not limited to '9': it can print any screen code, and it stops when the count byte wraps to 0. Leading zeros
are skipped (`$0950`), but the units digit always prints.

**Accepting ($B371).** `$A9` = the cursor line. `readPageFields` ($B813) reads *every* field of the
page back from the screen: from column 31 up to the first space, keeping the last six characters,
which are parsed and stored. Then the USER MODE entry `$09A5` is served:

| `$09A5` | Action |
|---|---|
| ≥ 210 | ignored |
| = `$0963` | nothing |
| 110-209 | n − 100 < `$0960` (25): `$0963` = `$09A5` = n − 100, `storeModeRecord` (writes only for modes ≥ 10) |
| < 110 | n < 25: `$0963` = n, `loadModeRecord`, `$09A5` = `$0963` |
| refused | `$09A5` = `$0963` |

The page is then reprinted (`printPageFields` $B3C0) and the cursor line restored. In the field
loop, an accepted field on page 0 line 1 (USER MODE) keeps the cursor there: the editor stays
open, and a second E exits.

## The mode record ($0964-$09A4, 65 bytes) and the conversions

The record holds display values. `stateToRecord` ($B3F6, on entry) and `recordToState` ($B559, on
exit) convert between those and the simulator's state. All of it goes through `mulU16` ($188A:
`$C4:$C5` × A:X → `$C8-$CB`). A is `$C9`, X is `$CA`, and "bits a-b" means the product's bits.

| Field | State → record | Record → state |
|---|---|---|
| NORTH, EAST +07/+09 | `$200C`: position bytes 2-3, high + $40 | bytes 2-3 = field with high − $40; bytes 0-1 = 0 (the zero bytes at $B018-$B01B) |
| ALTITUDE +0B | (`$5F:$60` + `$0A87:$0A88`) × $D1EB, bits 14-29 (the product shifted left twice), − 9 | `$2006` (`setAltitudeFromEditor`): (ft + 9) × $4E0C, bits 16-31, − field elevation, at least 3 |
| PITCH, BANK +0D/+0F | `$09DE`, `$09E0` × 360, bits 16-31 | deg × $B60C, bits 8-23 |
| HEADING +11 | `$0A13` −= `$0848`, then −= `$0846` (**stored back**), × 360, bits 16-31 | deg × $B60C, bits 8-23, + `$0848` + `$0846` |
| AIRSPEED +13 | `$0A4C` × $0200, bits 16-31 | × $7FFF, bits 8-23 |
| THROTTLE +15, FLAPS +1B | `$0AC8/$0AC9`, `$0AAF/$0AB0` copied | copied |
| RUDDER, AILERONS, ELEVATORS +17/+19/+1D | `$0ABC`, `$0AA3`, `$0AAB` + $7FFF | − $7FFF |
| Shears +2A/+2C/+2E | m × $0348, bits 8-23 (feet) | ft × $4E, bits 8-23 (meters) |
| Winds +30-+3F (`$B901`, 4 bytes) | [0-1] = knots + 100 × turbulence (bytes 0/1); [2-3] = angle × 360, bits 16-31 | [0-1] split by subtracting 100 until negative: [0] = knots, [1] = turbulence; [2-3] = deg × $B60C, bits 8-23 |
| `$085C-$0869` (7 words) | × $0348, bits 8-23 | × $4E0C, bits 16-31 |
| Clouds +22-+29 | feet in both | `$0856/$0858/$085A/$085C` = cloud 1 bottoms/tops, cloud 2 bottoms/tops × $4E, bits 8-23 (meters) |

The conversions lose resolution: a heading of $4000 shows as 90 and comes back as $3FFF. The port
loses exactly what the original loses (`EditorRoutineTests.roundTrips`).

### The exit ($B559) in order

1. EUROPE 1917 → mode 7 (above).
2. `$2042` (`displayInit`, the bitmap display), `$2000` (the clock).
3. Position, altitude, angles, airspeed, throttle, flaps, controls (above).
4. A call of $0ACF: the last byte of the flight variables is a bare return, called as a hook. The
   port checks that it holds the return opcode.
5. In reality mode (`$0967`) with the throttle low byte `$0AC8` = 0: the $0ACF hook again, then
   `$2009` with A = 0 (magnetos OFF). X is still the FLAPS high byte loaded at $B634, and `$2009`
   uses X as the label index.
6. `$095A` = `$095B`, `$095B` = 0.
7. Shears to meters, winds to internal ($B865, Y = 1).
8. War counters: `$0AA5` = 100, `$08E8` = '5'; `$0ACC`, `$08D6`, `$08B2`, `$08D4`, `$0AA7` and `$08D1/$08D2` = 0.
9. `$200F` (refuel, repair, rearm).
10. `$095F` = (`$0ACF` & $1F) − 16 (the return opcode read as data: −16). Overwritten in step 15.
11. `$0A83` = 20 (reposition: `$F9C1` reapplies the altitude for 20 passes).
12. Clouds in meters to `$0856-$085D`.
13. The control indicators `$2024`, `$2027`, `$202A`, `$202D`.
14. `$08BA` = `$08BB` = 0, and `$0886` = `$09A5`.
15. `$095F` = (`$22` & $1F) − 16: the ATIS temperature offset comes from the main-loop counter.
16. SOUND: `$08D3` = `$0964`.
17. `$0E86` = `$08BC` − 2 unless that is 0. With the cache invalid (2) the plotter's flag is kept.
18. `$2045` with A = `$0AB0` (flaps).

## The mode library

| Modes | Where | Notes |
|---|---|---|
| 0-9 | `builtInModes` $B9E1 (editor overlay), 10 × 65 bytes | read only. Mode 0: Meigs, 12:00; mode 2: the demo takeoff; mode 7: Europe 1917 |
| 10-24 | `[$0961]` = $C800, 15 × 65 bytes | `$AB88` fills record n with byte n at the cold start |

**$B998 / $B98D.** `$095C` = 0 (load) or 1 (store). `$39/$3A` = $B9E1, or `[$0961]` with A = mode −
10 for modes ≥ 10. Then 65 is added per mode, counting X down with a sign test, so an index ≥ $81
adds nothing, and a carry that wraps `$3A` to 0 stops the walk. The 65 bytes are moved with Y = $40
down to 0, and `$095C` is re-read on every byte. Stores happen only for modes ≥ 10.

**'S' ($B7A5)** turns a built-in mode n into user mode n + 10 (`$09A5` = `$0963`). Below `$0960`
it stores the record and recalls it. In flight it is served through `$08BB` = 2.

**'+' ($B7C3)** reloads mode `$0963` and reprints the page, keeping the cursor line (pushed and pulled).

### The library disk: CTRL-X and CTRL-Z

The library is logical block 64: 1024 bytes from `[$0961]`, of which 975 are used. On the master
disk block 64 is overlay 4, the database screen. So CTRL-X with the game disk in the drive fills
the user modes with that overlay's bytes, and CTRL-Z formats whatever disk is in the drive.

| Key | Original ($B1F5 / $B227, with interrupts masked until $B23D) |
|---|---|
| CTRL-X | `$B289` (`$731C` = $40, `$731E/F` = `[$0961]`); open `$7306`; read `$7309`; `$A9` = `$094D`; `loadModeRecord`; `printPageFields`; `$094D` = `$A9`; close (`$2039` → `$730F`) |
| CTRL-Z | open `$7306`; `$7312` (the 20-byte new-disk command at $7343, which names the disk and its ID: a full format; status; close; open); `$B289`; write `$730C`; close |
| any error (carry) | `$B216`: the 40 bytes $0E8E-$0EB5 (`** DISK READ/WRITE ERROR **`; the cracker's tags on modified copies are blanked by the import) to row 24 ($07C0-$07E7); no close |

`$730C` sends each sector as bytes 1-255 and then byte 0, for a 1541 whose direct-access buffer
pointer is 1 after the open. Each sector then goes `U2:2 0 tt ss` to channel 15, followed by the
status, `$C3` + 1, and the next sector from the mask walk.

**The port's persistence hook.** The library goes through `Machine.modeLibraryIO` (a
`ModeLibrary.IO?`). The native engine provides a file-backed implementation, `ModeLibrary.bin`:

```swift
public struct ModeLibrary.IO {
    public var load: () -> [UInt8]?                 // CTRL-X: the 1024-byte block, or nil (no library)
    public var formatAndSave: ([UInt8]) -> Bool     // CTRL-Z: replace the library with this block
}
```

- **CTRL-X.** `load()` is called at the open. With a 1024-byte block, the port runs the open
  (`loaderOpen`), the read (`loaderRead`, with the block standing in for the disk's block 64) and
  the close. Every loader byte matches: `$731C/$731E/$731F`, `$C0-$C3`, `$37-$3A`, `$BE/$BF`,
  `$A5/$A6`, `$B8-$BD`, `$7322-$7325`, `$7335`, `$733B-$733F`, and the status text at $7579.
- **CTRL-Z.** `formatAndSave(mem[[$0961]..+1023])` is called at the open. On success the port
  runs the open, then `loaderDosCommand` (the command transfer, the status, the close and the
  reopen), then `setLibraryBlock`, then `loaderWriteBlock` (four sectors: the mask walk, the digits,
  two transfers, the status, `$C2/$C3` advancing; at the end `$731C` = $41 and `$731E/F` +=
  $400), then the close.
- **No hook, nil, a short block, or false.** The open answers the 1541's
  `74,DRIVE NOT READY,00,00` status (`$7325` = $74, so the carry is set), and the editor shows its
  disk-error line. This is the port's choice; no lab run can produce it.
- The game disk is never touched. The original formats the disk in the drive; the port's
  "format" is the store replacing its library.
- **Timing.** `ModeLibrary.Timing` holds the lab drive's times: DOS command 52,167 cycles, and
  324,538 per written sector. The lab's format is instant; a real 1541 takes over a minute. The
  open, read and close reuse `Scenery.Loader`.
- **Interrupts.** The original masks IRQs from $B1F8/$B227 to $B23D, on the
  success and the error paths, and takes one pending raster IRQ afterward: for about 1.6 million
  cycles (a load) no frame tick runs, so the jiffy counter `$34`, the 10 Hz divider `$0E6B`, the
  keyboard scan and the voice-3 pattern stand still. The port does the same with `sei()` and
  `cli()` at those points (`EditorLibraryTests.interruptWindow`): `charge` keeps the
  pacing going, `InterruptScheduler` skips the IRQ work while the flag is set, and one IRQ is taken
  when it clears, exactly as for `readBlocks`.
- `Machine.modeLibraryIO` is a stored property of `Machine`.

**Lab note.** The lab's virtual 1541 sets the buffer pointer to 0 after `OPEN "#"`, and again
after U2. A block it writes therefore lands rotated by one byte per sector, and CTRL-X reads that
rotation back. A real 1541 (pointer 1) stores the bytes as sent. `EditorLibraryTests` accounts for
this by giving the port the rotated block when it compares with the lab's read-back.

## Development bridge

None. `recordToState` calls `displayInit()` for the call through $2042, and the poll inside
`waitForKey` runs the ported 10 Hz tick (`tick10Hz`, `main-loop.md`).

## Tests

| Suite | What it checks |
|---|---|
| `EditorRoutineTests` | Flat bus, exact cycles. Parse and print on random and extreme values; page copy; cursor moves and page switches; the field walks; `acceptField` over USER MODE entries and current modes; mode records for every mode and odd pointers; S and '+'; `stateToRecord` and `windToDisplay` on random states; `recordToState` with I/O (EUROPE 1917, reality and throttle, cache states, demo flags); both round trips; the text-mode helpers, and the swap under scheduler events (only the tick-only vector is ever seen). |
| `EditorSessionTests` | Flat bus, exact cycles, I/O state compared. The whole editor with scripted keys: the lab sessions' flows (editor, slew, night, clouds and wind, failures and reliability, radios, war); every field of both pages; typing, DEL, ignored keys, the six-digit limit; wrapping both ways; USER MODE entries; S and '+'; the mode requests 1, 2, 3 and others; the demo hand-over; the cached and invalid cache entries; Europe 1917 forcing and the restart latch. |
| `EditorFuzzTests` | Flat bus, exact cycles, I/O state compared. 400 random key scripts (RETURN, '-', digits and digit runs, DEL, '+', S, E, ignored keys) from the first and the cached entry, with random current modes 0-27, USER MODE bytes, the demo running, reality mode, the three cache states, another library pointer, and in a quarter of the runs the 10 Hz tick due during the key waits. |
| `EditorLibraryTests` | The full lab machine with the virtual 1541. CTRL-X in several modes; the library session (S, 111, '+', CTRL-X, CTRL-Z); the load-back after the format; CTRL-Z twice; the library keys in the middle of a field, on page 1, and CTRL-Z then CTRL-X in one visit (the port's store stands for the lab's disk, rotation included); the loader's DOS command and block write against the model. Memory exact, cycles within 10% (the lab adds badline DMA). The no-disk paths and the masked-IRQ window (`sei()`/`cli()`) are port only. |
| `EditorScreenTests` | With the fallback set, every cell of the editor screen is its glyph and the page reads back as text (`build/testdata/d2-editor-fallback.png`). With a provided ROM, and without one, the frame equals the lab's pixel for pixel. |
| `FallbackCharsetTests` | The ROM layout, reverse video, distinct glyphs for $00-$5A, the design rules, and the presenter's use of the set. |
