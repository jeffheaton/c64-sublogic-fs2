# Course plotter and database info

The port of the course plotter ($F522-$F7DA: the menu text $F522, the menu $F627, the recorder and
display $F6E2, the bank switches $F7B0/$F7B4) and the database info screen (overlay 4, disk block
64 at $A7E0: the record list $A802 and the screen $A86A-$A877). Swift:
`Sources/FS2Core/Modes/CoursePlotter.swift` (the `CoursePlotter` namespace),
`Sources/FS2Core/Modes/DatabaseInfo.swift` (`DatabaseInfo`). Differential tests:
`Tests/DifferentialTests/CoursePlotterTests.swift` (`CoursePlotterTests`, `DatabaseInfoTests`).

Related pages: `modes-ui.md` (the Q and CTRL-E keys), `input.md` (the wait-for-key routine $2250),
`scenery-3d.md` (the display-list ops of the recorded track), `memory-map.md` (the $D000 buffer
and the editor cache), `raster.md` (`clearWindow`, `drawTextList`).

Every routine is a literal translation with the original's exact cycles (its own instructions
through its return; the call itself belongs to the caller), reading and writing every byte the
original does. Nothing touches I/O.

| Routine | Swift | Cycles |
|---|---|---|
| `coursePlotterMenu` $F627 | `coursePlotterMenu()` | per round 6 + `clearWindow` + 10 + `drawTextList` + 6 + $2250 + the key (below) |
| `plotterRecord` $F649 (A), `plotterPrecisionKey` $F671 (C), `plotterStartRecording` $F67A | private `plotterStartRecording(normal:)` | A 13, C 10, then 20 + 17 + 371 + 14 + 3 |
| `plotterDisplayKey` $F654 (B) | private `plotterDisplayKey()` | 13 without a recording, else 21 |
| `plotterOffKey` $F666 (D) | private `plotterOff()` | 13 |
| `plotterDisplay` $F6E2 | `plotterDisplay()` | mode 0: 12; 3 and up: 21; 1: 13 + `plotterRecordStep`; 2: 32 + 17 + 6 + $8006 + 6 + 14 + 6 |
| `plotterRecordStep` $F703 | private `plotterRecordStep()` | 14 counting; 39 with the list full; 40 + 17 + 26 + 3 × (38 + `plotterScaleDelta` + 22) + 34 + 14 + 6 |
| `plotterScaleDelta` $F7BB | private `plotterScaleDelta()` | 15 at scale 4, else 74 |
| `bankOutIo` $F7B0 | `bankOutIo()` | 17 |
| `bankInIo` $F7B4 | `bankInIo()` | 14 |
| `databaseInfoScreen` $A86A (overlay 4) | `databaseInfoScreen()` | 6 + `clearWindow` + 10 + `drawTextList` + 6 + $2003 + 6 |

**Calls outside this subsystem:** `clearWindow` $1EAF and `drawTextList` $1E99 (raster),
`waitForKey` $2250 (input; at $F631 directly, at $A874 through the vector $2003, whose jump costs
3 cycles) and `runScenery` $8730 (the scenery interpreter, at $F6FC through the vector $8006). The
development bridge is not used.

**Callers outside this subsystem:** the main loop calls `plotterDisplay` on every pass ($207A,
after the physics, before the display-list root and the view matrix are set) and, on flip passes,
`coursePlotterMenu` when a set bit shifts out of `$0E70` ($20AE) and slot $A7FA when `$0E87` is set
(it clears it first, $20C3).

## The menu ($F627)

Q (`keyCoursePlotter` $2BE9) sets `coursePlotterRequest` `$0E70`. Each round of the menu clears
the window, draws the records at $F522 ('**** COURSE PLOTTER SYSTEM ****', 'A. BEGIN NORMAL COURSE
RECORDING', 'B. DISPLAY COURSE PLOT', 'C. BEGIN PRECISION RECORDING', 'D. TURN OFF COURSE
PLOTTER', and 'SELECT OPTION, THEN PRESS E TO / RETURN TO FLIGHT, SLEW, OR RADAR / MODE TO VIEW OR
RECORD COURSE.') and waits for a key. A-D act and show the menu again; E returns; other keys show
it again. Key costs after the wait: A 5, B 9, C 13, D 17, E 26 (with the return), other 21; each
option ends with a jump back to $F627 (3).

| Key | Effect |
|---|---|
| A ($F649) | `$08BC` = 2, scale `$0E85` = 6, interval `$0E80` = 10, then $F67A |
| C ($F671) | `$08BC` = 2, scale 4, interval 2, then $F67A |
| $F67A | `$0E82` = 1; I/O out; the list header at $D000 (below); `$0E83/$0E84` = $D016; `$0E86` = 1; I/O in. `$BA/$BB` = $D000 is left, X = 12, Y = 22. The countdown `$0E81` is not reset: the first point comes when it next reaches 0 |
| B ($F654) | `$08BC` = 2; when `$0E86` is set (a recording was started), `$0E82` = 2 |
| D ($F666) | `$0E82` = 0 and `$08BC` = 0 ('never loaded': the next editor entry reloads it from disk) |

## The recorded list at $D000

A scenery display list in the RAM under I/O, written with `$01` = $30:

| Offset | Bytes | Meaning |
|---|---|---|
| $D000 | `07 s` + 12 bytes | op 07, origin with scale `s` (`$0E85`) and the position `$5A-$65` (east, altitude, north; 32-bit, 1/256 m) at the start |
| $D00E | `1C` | op 1C |
| $D00F | `01 00 00 00 00 00 00` | op 01, moveto (0, 0, 0) |
| $D016 | `02 dx dy dz`, 7 bytes each | op 02, lineto per recorded point |
| end | `79` | end marker (an opcode ≥ $46 ends the list), overwritten by the next point |

Each delta is bytes 1-3 of the 32-bit coordinate (east $5B-$5D, altitude $5F-$61, north $63-$65)
minus the origin's bytes at $D003-$D005, $D007-$D009, $D00B-$D00D (24-bit, borrow chained, into
`$B9`, `$BE`, `$BF`), shifted right 4 (a logical 24-bit shift, one bit at a time) unless the
scale is 4; the low 16 bits are stored. So a normal point is in units of 16 × 256 / 256 m = 16 m
at scale 6, a precision point 1 m at scale 4.

**Memory-faithful sharing.** The editor cache ($E6D8/$E6DB) also lives in $D000-$E4FF. The port
keeps both where the original keeps them (`mem` $D000-$DFFF is plain RAM in the port): the
plotter's `$08BC` = 2 makes the overlay manager reload the editor from disk instead of swapping
the cache back, and D sets `$08BC` = 0. This replaces the earlier plan of separate buffers
(`memory-map.md`, `modes-ui.md`).

**Bank switches.** `bankOutIo` stores $30 into `savedCpuPort` `$4B` and `$01`; `bankInIo` $35.
In the port both stores are kept (the raster IRQ restores `$01` from `$4B`, so the original sets
both); nothing else changes, because the port never maps I/O into `mem`.

## plotterDisplay ($F6E2)

- **Mode 1, recording ($F703).** `$0E81` − 1; while not 0, return. At 0: `$0E81` = `$0E80` (an
  interval of 0 counts 256 passes); then the room test: the sign bit of $DFE0 − `$0E83/$0E84` (a
  16-bit subtraction of which only the high byte's sign is tested), so recording stops for good once
  the end marker passes $DFE0, after 578 points (the last at $DFDD, the end marker then at $DFE4;
  only pointers from $5FE1 to $DFE0 pass the test). With room: I/O out, `$BA/$BB` = the pointer,
  `02` and the three deltas (`plotterScaleDelta` for each), `79`, the pointer += 7, I/O in. In the
  lab's climb out of Meigs a main-loop pass takes about 60-70 frames, so normal recording adds a
  point about every 10 seconds and precision recording every 2 seconds.
- **Mode 2, display ($F6F1).** `$8B/$8C` = $D000, I/O out, the scenery interpreter through the
  vector $8006 (it runs the list from the origin record to the end marker), I/O in. The main loop
  sets the display-list root (`$E565`) and the view matrix after this call.
- **Other modes** return (0: 12 cycles; 3 and up: 21).
- The mode-1 branch to $F703 at $F6EA crosses into page $F7: 4 cycles.

## Database info (overlay 4)

CTRL-E increments `databaseInfoRequest` `$0E87`. On the next flip pass the main loop clears it and
calls slot $A7FA. With the flight overlay resident that slot calls $2021 (`vecLoadDatabaseInfo`,
a jump to $E5ED), which loads block 64 over $A7E0 (and the root block after it); the call returns
to $A7FD, which in overlay 4 jumps to $A86A (overlay 4's own $A7FA does too). The screen:

- `clearWindow`, `drawTextList($A802)`: 'CURRENT DATABASES ARE:' at row 10, x 10; 'CHICAGO',
  'LOS ANGELES', 'SEATTLE', 'NEW YORK' at x $32, rows $12-$2A; 'PRESS ANY KEY TO CONTINUE ...' at
  row $58, x $14; the list ends with `00 00` at $A868. ($A800/$A801 are two lead bytes the list
  skips.)
- `waitForKey` through the vector $2003 (the key is consumed; the simulation is paused and the
  sound off meanwhile), then the return.
- The next pass's slot $A7F4 (a call to $201E in overlay 4) loads the flight overlay and the area
  again (about 1,400 frames with the disk loads, in the lab and in the port, which charges the loader's time).

The port's `databaseInfoScreen()` works on the overlay bytes in memory; loading them is the
overlay manager's job (`scenery-3d.md`, `Machine.diskBlocks`).

## Tests (`CoursePlotterTests.swift`)

The fixture session (as `re/sessions/plotter.txt`) stops at the menu entry before and after a
recording, at `plotterDisplay` during a normal recording (climb, turn), a precision recording, the
display in the front and radar views, and after D. Each run compares the whole memory (stack page
excluded) and the exact cycles with the original on the flat bus:

- the menu with key scripts (E; A E; C E; B E; D E; invalid keys; several options in one visit)
  from both menu states, the keys delivered by a trap in the original's key loop ($226B) on both
  sides (`ScriptedKeys`), and the header A writes;
- 1,800 recording passes with random positions, countdowns, intervals, scales and pointers around
  the $DFE0 limit and the $5FE1 sign edge (with checks that points were appended at both scales
  and the full list stopped), a recording from the header to the full list (578 points, one per
  pass, deltas of both signs at both scales), the display through the interpreter (it
  ends at the end marker), the other modes, the bank switches;
- the database screen with three keys, and the port's window against the lab's at the screen's
  return.
