# The game program: main loop, interrupts, ticks and the cold start

The definitive specification of the program that drives everything else: the main loop
($2048-$2195), the raster IRQ ($2285-$2307), the 10 Hz poll and tick ($2330-$2417), the display
setup ($25EB-$2672), the cold start of overlay 0 ($A946-$ABBA), and how the port runs them: in
normal mode on the virtual clock (`InterruptScheduler`), in replay mode from a lab recording
(`ReplayDriver`). Every routine is a literal translation that reads and writes the original's
bytes at the original's addresses and charges the original's cycles; the differential tests
listed at the end prove it against the lab.

## Port map

| Range | Original | Port (`extension Machine`) | File |
|---|---|---|---|
| $2048 | `mainLoopEntry`: a call to the flight slot $A7F4 | `mainLoopEntry()` | `Game/MainLoop.swift` |
| $204B-$2193 | the main loop | `runMainLoop(fromEntry:)`, `mainLoopPass()` | `Game/MainLoop.swift` |
| $208B-$20D4 | the page flip | `pageFlip()` | `Game/MainLoop.swift` |
| $20A3-$20CF | the alternate-pass tasks | `alternatePassTasks()` | `Game/MainLoop.swift` |
| $20D5-$210C | the draw sequence | `drawSequence()` | `Game/MainLoop.swift` |
| $210D-$2190 | the phase tasks | `phaseTasks()`, `oddPhaseTasks()`, `evenPhaseTasks()` | `Game/MainLoop.swift` |
| $A7E2-$A7FF | the overlay slots (every overlay's first 30 bytes) | `runOverlaySlot(_:)`, `coldStartSlot()` | `Game/OverlaySlots.swift` |
| $2285-$2303 | the raster IRQ | `rasterIrq()`, `frameTick()` ($22C3) | `Game/Interrupts.swift` |
| $2304-$2307 | the alternate IRQ | `altIrq()` | `Game/Interrupts.swift` |
| vectors $FFFE/$FFFA | IRQ / NMI entry | `irq()`, `nmi()` | `Game/Interrupts.swift` |
| $2330-$2347 | the 10 Hz poll | `pollTick()` | `Game/Poll.swift` |
| $2348-$2417 | the 10 Hz tick | `tick10Hz()` | `Game/Tick.swift` |
| $25EB-$2672 | display setup (vector $2042) | `displayInit()` | `Display/InitDisplay.swift` |
| $794E-$796B | color RAM fill (through the loader hook $7331) | `fillColorRam(_:)` | `Display/InitDisplay.swift` |
| stage 2 ($78A2) | the handoff state | `Machine.bootMemory(blocks:)`, `stage2Handoff()`, `Machine.booting(blocks:)` | `Game/ColdStart.swift` |
| $A7E2 / $A946-$A987 | the cold start and its init chain | `coldStart()`, `coldInit()` | `Game/ColdStart.swift` |
| $A988-$AA06 | the boot loads | `bootLoads()` | `Game/ColdStart.swift` |
| $AA07-$AA1B | the radio hook patches | `patchRadioHooks()` | `Game/ColdStart.swift` |
| $AA1C-$AA90 | the title, display and mode prompts | `titleScreen()`, `modePromptScreen()` | `Game/ColdStart.swift` |
| $AA91-$AAF6 | the panel's initial state | `initPanelState()` | `Game/ColdStart.swift` |
| $AAFA-$AB57 | interrupts and the TOD calibration | `interruptAndTimingSetup()` | `Game/ColdStart.swift` |
| $AB66 / $AB78 / $AB88 / $ABB0 | panel row copy, CIA masks, user library, zero page | `copyPanelRow()`, `maskInterrupts()`, `initUserLibrary()`, `copyZeroPage()` | `Game/ColdStart.swift` |
| | normal mode: interrupts on the clock | `InterruptScheduler` | `Game/InterruptScheduler.swift` |
| | replay mode | `ReplayDriver` | `Game/ReplayDriver.swift` |
| | the program's thread (nested restarts) | `ProgramThread` | `Game/ProgramThread.swift` |

Not ported (excluded): the protection stubs $AAF7/$AAF9 (their time is charged) and the loader's
own code (the boot loads use `loaderOpen`/`loaderRead`/`loaderClose`, the loader's memory
effects). Specified elsewhere: $2673 text mode and the editor overlay (`editor.md`), the war
overlay (`war.md`), the overlay manager and the editor cache (`scenery-3d.md`).

**Cycles.** A routine charges from its first instruction through its return; the caller charges
its call and a vector's 3-cycle jump; whoever delivers an interrupt charges the 7-cycle entry
(`irq()`, `nmi()`). Taken branches and page crossings are exact: in the main loop only the branch
at $20FC crosses a page ($2101); in the tick the branches to $2413 and $2405 do; the page flip's
indexed read based at $01FF always does.

## The main loop ($2048 / $204B)

No vsync: one pass after another, about 1.2 M cycles (70 frames) per pass at Meigs.

`$2048 mainLoopEntry` calls the flight slot $A7F4 once. After the cold init overlay 0 is resident
and its slot loads the flight overlay (block 65, then the root block 66 at $A800).

Each pass at `$204B`:

1. **Overlays.** When `$08BA` or `$08BB` is nonzero, the editor slot $A7E8 runs (the editor
   overlay; see the slots below). Then the cache counter `$08BC`: on the first entry (0) it
   becomes 1; when the editor was taken from the cache, the pass swaps it back out through $E6DB.
   The flight slot $A7F4 is called on every pass; with the flight overlay resident it only returns.
2. **Physics.** In slew (`$0966`) the slew routine $3660; otherwise the integrator $32EE and then
   the wind drift $E716.
3. The course plotter display ($F6E2), $E565 (which copies the word at $A7E0 into `$8B/$8C`), and
   the view matrix ($8000).
4. **Page flip**, skipped when the bit shifted out of `$0E79` is set: the row table's 112 high
   bytes at `$0200` each gain `$8D` (rows 0-111 move to the other bitmap), then `$8D` toggles
   between $20 and $E0. When `$8D` became negative, `$22B0` = $F0; otherwise the **alternate-pass
   tasks** run first and `$22B0` = $F8. `$22B0` is the immediate operand the window-phase IRQ
   stores to `$D018`: the bitmap just finished is shown.
5. **Alternate-pass tasks** ($20A3): the ATIS teletype ($E713); a pending message code in `$0834`
   goes to the crash/splash message routine $F95D; a set bit shifted out of `$0E70` runs $F627; in
   war mode, a set bit shifted out of `$08D7` calls the $FD00 hook (**a documented no-op**: the
   hook is empty on the disk, `excluded.md`; the call and a return are charged); a nonzero `$0E87`
   is cleared and the database-info slot $A7FA runs.
6. **Draw sequence** ($20D5): `$8003` horizon, `$8006` scenery, `$3C3F`, `$3AB9`, `$8021`
   attitude indicator, `$3BAF`, `$3C1A`, `$F8AF`, `$3773`, `$377C`, `$3823`, `$EBA5`; in war mode
   the war slot $A7EE; then `$ED3C`, `$CE84`, `$CF0E`, `$F35E`.
7. **Phases** on `$22`:

   | `$22 & 3` | Tasks |
   |---|---|
   | 0 | `$EBF2`, `$8012` turn coordinator, `$1C5D`, `$E766`, `$3A13`; with `$22 & 4`: `$38D4`, `$38F5`, `$EA50`, the **demo check** (`$095B` ≠ 0 → `$08BB` = 3) and the **war-exit check** (`$0E7C` ≠ 0 and `$0963` ≠ 7 → a jump to $A7E2, the cold restart); then the even tasks |
   | 1 | `$1C75`, `$F86F`, then the odd tasks |
   | 2 | `$1CA7`, `$35BD`, then the even tasks |
   | 3 | `$1CBE`, `$EA84` with the carry `$1CBE` leaves (1 when the gauge did not change; else the carry of the plotter's last row add, `plotPointListCarry`), then the odd tasks |
   | odd tasks | `$3B32`, `$3B9B`, `$CF46`, `$E7FE`, then `$0832:$0833` rotated left by one |
   | even tasks | `$F996`, `$F916`, `$CF79`, `$EE6B` |
8. `$22` + 1, and back to `$204B`.

**Port.** `runMainLoop(fromEntry:)` calls `mainLoopHook` before every pass (the replay driver's
checkpoint; without a hook the loop never ends) and `mainLoopPass()` for the pass. A war-exit
jump to $A7E2 returns `.coldRestart` from the pass; the loop then runs `coldStartSlot()` (the slot,
the init chain) and `mainLoopEntry()` and goes on, so that restart never nests.

### The overlay slots ($A7E2-$A7FF)

Every overlay starts with five 6-byte slots: $A7E2 cold start, $A7E8 editor, $A7EE war, $A7F4
flight, $A7FA database info. The owner's own slot jumps to its entry (overlay 0: $A946; editor:
$B09A; war: $AA03; database info: $A86A; the flight overlay's $A7F4 and $A7F7 simply return, and
so do the war overlay's, which therefore stays resident). The other slots call the load
trampolines $2015-$2021 (overlay 0 uses $E5C0-$E5ED directly): the trampoline loads the slot's
overlay over $A7E0 (`loadOverlay`; the editor from the cache when `$08BC` = 1) and its return
lands in the **new** overlay's slot at +3, which holds that overlay's jump to its entry (or a
return).

`runOverlaySlot` executes the slot bytes in memory: a return, a call to a trampoline (3 more
cycles through a vector), or a jump to an entry. The jump to $A946 returns `.coldInit` to the
caller; the other entries run their ports: $B09A `editorEntry()` (`editor.md`), $AA03 `warMain()`
(`war.md`), $A86A `databaseInfoScreen()`.

## The interrupts

### Delivery

`irq()`: 7 cycles, then the handler named by the **memory word** at $FFFE at that moment:
$2285 (`rasterIrq`), $2304 (`altIrq`, installed by $2673 for the editor's text mode and disk
I/O), or the bare returns at $790A/$E58E (stage 2's and the protection code's disabled vectors).
`nmi()`: 7 cycles, then $FFFA: $2700 (`restoreNmi`) or a bare return.

### The raster IRQ ($2285)

The handler saves A, banks I/O in (`$01` = $35) and shifts the phase flag `$4A` right; the bit
shifted out picks the phase:

| Phase | Raster line | Writes | Then |
|---|---|---|---|
| `$4A` bit 0 clear: panel | $A3 (bitmap row 112) | border $0C, `$D018` = $F0 (bitmap A), `$D016` = $C8 (hi-res), `$D012` = $20, `$D019` acknowledged; latched as `io.panelRegion` | `$4A` + 1, `$01` = `$4B`, A restored, return (49 cycles with the entry's own instructions) |
| `$4A` bit 0 set: window | $20 | `$D018` = [`$22B0`] (the bitmap the last flip finished), border = [`$22B5`] (the time-of-day color), `$D016` = $D8 (multicolor), `$D012` = $A3; latched as `io.viewRegion` | the frame tick $22C3 |

The `$D019` acknowledgements do not touch the register shadow `io.vic` (on the chip a read of
$D019 shows the latch, not the last store); `io.acknowledgeVIC` clears the modeled latch bit.

**The frame tick ($22C3)**, shared with $2304: the jiffy `$34` and the 10 Hz divider `$0E6B`
each count up, the voice-3 pattern player runs ($22C8, `patternPlayerFrame`, `sound.md`), then
the keyboard phase $22CD counts `$08A6` down; at 0 `keyScan` ($2418); below 0
`keyReleaseCheck` ($2505) and `$08A6` = 3; above 0 nothing. X and Y are saved around the scan.
Then `$D019` is acknowledged, `$01` = `$4B`, A is restored and the handler returns. A 4-frame
keyboard cycle: idle, idle, scan, release (15 Hz).

**The alternate IRQ ($2304)** saves A and goes straight to the frame tick: no VIC writes, and
I/O is not banked in on entry.

### RESTORE ($2700) and the cold restart

`restoreNmi()` (`input.md`) returns true when RUN/STOP is in slot 3 and the one-shot `$26FF` is
clear; the original then jumps to $A7E2 out of the NMI. The port runs `coldStart()` from inside
`nmi()`: the slot (the flight or war overlay's call to the trampoline $2015 reloads overlay 0 and
returns into its jump to $A946), the whole init chain (the boot loads again, which also clear
`$26FF`), the title and prompts, the main loop. The interrupted Swift frames (the scenery
interpreter or the key wait the NMI came in at) must never continue, as on the 6502, where the init
chain resets the stack: the nested run never returns while the game runs; when a host stops it
(`mainLoopHook`), `abandonStack` leaves the frames for good (`ProgramThread`).

## The 10 Hz poll and tick

**$2330 `pollTick`** (vector $2012): called once per display-list opcode ($8752) and from the key
wait ($2268). First the port's hook `pollHandler` (the scheduler's or the replay driver's poll
point), then `$0E6B` − 6: negative → return (16 cycles); else `$0E6B` keeps the difference, and the
tick $2348 runs with I/O banked in (`$01` = $35, then back to `$4B`). One tick per poll; a backlog
is caught up over the following polls. When `$0E6B` climbs to $80 or more (a long stretch without
polls), the subtraction stays negative and the ticks stop until the IRQ's increments wrap it around.

**$2348 `tick10Hz`**:

1. When the ring is not empty (`$08A8` ≠ `$08A7`) and `$08C3` = 0: `dispatchKey` (one key).
2. `engineSoundSlew` ($E500).
3. Slot 3 then slot 2: held (bit 7 clear) and the counter `$0E74`/`$0E73` = 0 → `requeueKey` with
   the matrix index the slot holds (the counter stays 0: one repeat per tick); held and not 0 →
   the counter counts down.
4. `bombWhistleSweep` ($2381).
5. `$0E6C` + 1; on even counts (5 Hz), unless paused (`$08CC`): `$091C` − 1 when nonzero,
   `aeroUpdate` ($2F45), `updateAirspeedNeedle` ($1A32), `updateVsiNeedle` ($1A6A),
   `joystickAction` when `$0E6F | $0E6E` ≠ 0, `autoCenter` when `$0E7A` ≠ 0. Paused: return.
6. The CIA1 TOD seconds `$DC09` (read through `readIO`) vs `$0E6D`: equal → return. Else `$0E6D`
   = the seconds, and unless paused: `soundTick` ($CC16), the clock (`$091A` seconds; at 59 →
   0 and `$0984` minutes + 1; at 59 → 0 and `$0983` hours + 1, 24 → 0), `drawClockSeconds`
   ($39B6), and on even TOD seconds `trimCreep` ($EAE2).

The clock follows the CIA1 time of day, not the frames: one tick per TOD second, at most 0.1 s
late (the next 10 Hz tick).

**I/O banked out.** The course plot display ($F6F1) runs with `$01` = `$4B` = $30 ($F7B0), and the
poll banks I/O in only around the tick. Every IRQ ends with `$01` = `$4B`, so an IRQ taken inside
the tick leaves I/O banked out for the rest of it: the read of `$DC09` then sees the RAM under I/O
(the clock counts a second whenever that byte differs from `$0E6D`; in normal mode the game clock
runs two to three times too fast while a plot is displayed) and the SID stores land in the RAM under
the SID. `Machine.ioMappedIn` gives `readIO` and `storeSID` the C64's memory map, so the port does
the same. Only normal mode can show it: a replay takes its IRQs at the poll points, outside the
tick.

## Display setup ($25EB)

With interrupts masked: `$D011` = $3B (bitmap mode, display on); CIA2 `$DD02` = $3F, `$DD00` = $96
(VIC bank 1, $4000-$7FFF) and its shadow `$0E89`; sprites 0-3 on and multicolor (`$D015` = `$D01C` =
$0F; multicolors `$D025` = $0B, `$D026` = $01; colors $0B) at ($58,$AA) ($68,$AA) ($58,$B5)
($68,$B5), pointers $E8-$EB at $7FF8-$7FFB (the attitude-indicator bezel, data at $7A00); `$D021` =
`$0E69`; the IRQ vector `$FFFE/$FFFF` = $2285 (memory); `$D012` = $97 (the first raster IRQ),
`$D01A` = 1, `$D019` = $0F; interrupts unmasked; then the color RAM fill with A = 1 through the
loader hook $7331, which jumps to $794E: color RAM $D800-$DBE7 = 1 (white), stored downward through
`$39/$3A` from $DBE7, leaving `$39/$3A` = $D7FF (14,050 cycles). The cold init calls it from $AB0B;
the editor from its exit ($B56C via $2042).

## The cold start

### The stage-2 handoff

`Machine.bootMemory(blocks:)` builds what SubLogic's stage 2 ($78A2, loader code, not ported)
leaves when it jumps to $A7E2, the state the lab boots from (`Lab.boot`):

- stage 2 (blocks 0-1) at $7300 and stage 3 = overlay 0 (blocks 2-4) at $A7E0, with the two
  title records that a cracker overwrote on modified copies blanked (`ColdImage.scrubCrack`);
- the NMI and IRQ vectors at the loader's bare return $790A; `$01` = $35 (KERNAL out; the lab keeps
  the RAM byte under the CPU port at 0 until the first store, the port writes stage 2's value);
- `$731B` (drive number offset) = 0 and `$7326` = 0: the result of SubLogic's drive-status check
  $7848, which is protection and is not ported.

`stage2Handoff()` sets the hardware: color RAM all white, the VIC as the KERNAL left it (`$D011`
$1B, `$D016` $C8, `$D018` $14, border $0E, background $06, raster IRQs off), CIA2 port A $97
(bank 0) with direction $3F, and the interrupt flag set. `Machine.booting(blocks:)` does both
and sets `diskBlocks`.

### The init chain ($A946)

The chain resets the stack pointer to $3F, masks interrupts, turns the sprites off (`$D015` = 0)
and calls the loader's open ($7306: `loaderOpen`), then:

1. **`bootLoads` ($A988)**: five loads from the table at $A800, each `$731E/$731F` = the
   destination, `$731C` = the first block, `$A4` = the count, then per block the loader's read
   ($7309: `loaderRead`, which leaves the loader's memory) and the border = `$731C`:

   | Blocks | Destination |
   |---|---|
   | $0A × 16 | $0200 (main code and data) |
   | $06 × 4 | $5000 (the panel) |
   | $1A × 12 | $77E0 (the 3D engine) |
   | $26 × 4 | $C000 |
   | $96 × 8 | $E000 |

2. A call to $AAF7, SubLogic's protection stub (it only clears the carry), **not ported** (its 14
   cycles are kept).
3. `cacheHelper` ($E6D2, the loader's close), then `copyZeroPage` ($ABB0: $AC02-$ACFF to
   $02-$FF).
4. At **$A970** the cracker's bytes that the loads brought back are scrubbed (`ColdImage`: the two
   title records and the disk-error line's tags), as the lab does at the same point.
5. **`interruptAndTimingSetup` ($AAFA)**: `maskInterrupts` ($AB78: interrupts masked, `$DC0D` =
   `$DD0D` = $1F, both ICRs read), the held-key slots `$089B-$089E` = $80, `displayInit`, the NMI
   vector `$FFFA/$FFFB` = $2700, `$DC0E` = `$DC0F` = 0, the TOD tenths = 0 (starts the clock),
   `$A5/$A6` = 0, then with interrupts masked the **50/60 Hz calibration**: wait for two TOD tenth
   edges, count loop passes during the next tenth into `$A5/$A6`, and unmask; a count of $1ABD or
   more would set `$DC0E` = $80 (a PAL machine's 50 Hz TOD). **The port is NTSC only:** it charges
   the same wait on the virtual TOD and stores the count the lab measures on NTSC
   (`MainLoop.ntscCalibrationCount` = $18CB), so `$DC0E` stays 0. (`$A5/$A6` are overwritten by the
   flight overlay's load at $2048 before any checkpoint.)
6. A call to $AAF9, the second protection stub (an immediate return), not ported (12 cycles kept).
7. **`titleScreen` ($AA1C)**: `clearWindow`, the record list $A80C ('SUBLOGIC FLIGHT SIMULATOR
   II', 'VERSION 1.0', the two blank records, 'WHAT DISPLAY ARE YOU USING?', A/B, '(TYPE A OR
   B)'), `waitForKey` until A or B. A: `$0E61` = $65, `$0E63` = $6C, `$0E65` = $EA, `$0E69` = $0B;
   B: $FC, $CB, $CB, $00. Both: `$0E62/$0E64/$0E66` = $0E/$06/$00, `$083C` = 0,
   `selectTimeOfDay`; then falls into **`modePromptScreen` ($AA71)**: `clearWindow`, the list
   $A8F4, `waitForKey` until A (`$095B` + 1: demo) or B; `$08BA` = 0.
8. **`initPanelState` ($AA91)**: `$08CF` = 1; the indicators drawn at their starting values
   through the second halves of their routines (store, then draw): the altimeter hands at
   `$20`/`$1F` ($1A20), the airspeed needle at the value in `$21` ($1A5C, wrapped below 88 for the
   drawing), the VSI needle at 0 ($1A82), the turn coordinator at 8 (`$8027`), elevator $0A,
   ailerons $0F, rudder $0F, throttle 0, flaps 0, trim 5, mixture 0, slip ball 0, fuel and oil
   bars 0 ($1B9A, $1BB4, $1BD5, $1BE9, $1C05, $1C18, $1C2B, $1C4B, $1C6F, $1C89, $1CB8, $1CD1);
   `drawObs1`, `drawObs2`, `panelRedraw`, `drawMagnetoLabel`, `sidInit`.
9. **`patchRadioHooks` ($AA07)**: the renderer table's hooks get their targets: $802E/$802F =
   $F16A (ATIS composer, op 1E), $802B/$802C = $E956 (NDB hook, op 05).
10. **`copyPanelRow` ($AB66)**: $5180-$52BF to $7180-$72BF (panel row 14 into bitmap B, so the
    split line 112 shows the panel whichever bitmap is displayed).
11. **`initUserLibrary` ($AB88)**: the 15 user-mode records at `[$0961]` = $C800 filled with their
    numbers $0A-$18.
12. On to the main loop entry $2048.

## Normal mode: `InterruptScheduler`

The VIC raises a raster IRQ when its line equals the compare register (`$D012`, bit 8 in
`$D011`) while `$D01A` bit 0 is set: once per frame at that line (17,095 cycles per frame, 65 per
line, frames aligned to cycle 0). The handlers move the register between $20 and $A3, so the
scheduler recomputes the next event from the register after every handler. `Machine.charge`
calls it whenever the clock passes `nextEventCycle`; a long charge (a disk load, a busy delay)
catches up every event it passed, in order.

- **Masked IRQs.** While `interruptDisable` is set (`sei()`/`cli()` in the ported code where the
  original masks and unmasks: the cold init, `displayInit`, every disk load (`readBlocks`, masked
  from $E668 to $E698), the editor cache transfer $E6DC-$E711) or the editor's library disk I/O
  runs (`modeLibraryIOActive`, masked from $B1F8/$B227 to $B23D), a raster event only sets the VIC
  latch; one IRQ is taken as soon as the flag clears, the events in between are lost, as on the
  C64. A latch the program acknowledges meanwhile (`$D019`, as `displayInit` does before it
  unmasks in a restart) drops the pending IRQ: the VIC's IRQ line is the latch. So a RUN/STOP +
  RESTORE restart takes the IRQ latched during each overlay-0 load where that load unmasks, as
  the lab does.
- **No re-entry.** Charges made by the handlers it runs do not run the scheduler again.
- **RESTORE** (`requestNMI`) is taken at the next poll point, where the lab's recorder takes it.
- `onFrameEnd` is called at every frame boundary for the host (presentation, input).
- **Turning raster IRQs on.** Only `displayInit` writes `$D01A`: `$D01A` = 1, the latch
  acknowledged (`$D019` = $0F), then the unmask, whose `cli()` brings the scheduler in at once. A
  scheduler service that finds raster IRQs newly on starts the search for the next compare match
  at that moment, so the first IRQ comes at the next match (line $97 of this frame or the next),
  never at a match that passed while they were off. A compare line the main program stores
  (`displayInit` in a restart or at the editor's exit) matches from then on.

## Replay mode: `ReplayDriver`

The lab records (`ReplayRecorder`, `fs2lab record`) by taking the raster IRQs and RESTORE only at
the two poll sites ($8752, $2268), in the order and number the VIC would have raised them, and
logs per poll index the IRQ count, the key matrix and joysticks in effect, the NMI, every I/O
value the main program read (the loader's own reads excluded), and at every `$204B` the poll
index and a hash of memory (the stack page excluded). The driver gives the port exactly those
inputs:

- `pollHandler` counts the port's poll points (`pollTick` calls it first) and at a recorded index
  sets `io.keyboard` and runs the IRQs through `irq()` (the handler chosen from $FFFE at that
  moment) and then the NMI through `nmi()`;
- `ioReadHook` returns the recorded values in order per address (`$DC09` above all; the reads of
  `$DC08` in the TOD calibration and of `$D015` in `readBlocks`, which the port does not route
  through `readIO`, are left unread);
- `mainLoopHook` compares the hash and the poll count with each checkpoint, stops after the last
  one or at the first mismatch;
- the cycle-driven `eventHandler` is off.

A run starts at `$204B` from the recording's start snapshot (`.mainLoop`) or at the stage-2
handoff (`.coldStart`, `Machine.booting`). It runs on a `ProgramThread`; a run that goes
`pollSlack` polls past the last checkpoint's poll (diverged) is abandoned.

Recording changes the original's timing a little: the lab takes the interrupts only at the poll
points, so the keyboard is scanned only there. A key held entirely within a stretch without polls
(a disk load, a busy delay, a long drawing routine) is never seen; the replay sessions hold keys
14 frames with 30-frame gaps. A recording started at the handoff delivers, at its first poll,
every raster event since cycle 0 (the recorder counts from its start, not from `$D01A`).

**Overlays in replays.** The editor and war overlays are ported, so their polls (the war
overlay runs the scenery interpreter for the enemies at $AC2C; the editor waits for keys through
`waitForKey`) are the port's own poll points, which the driver counts like any other: war mode and
the editor opened by key replay like the rest (`NativeEngineReplayTests.europe1917`: E, the
editor's key waits, EUROPE 1917, the war overlay loaded, war passes with the enemies' polls, W).

**The lab recorder and RESTORE.** `ReplayRecorder` ends a delivered interrupt when its return brings
the stack back to the poll site. The NMI's cold restart never returns (it jumps to $A7E2 out of
the handler), so the recorder also ends the handler batch when the PC reaches $A7E2, and recording
goes on through the cold start, the title and flight. A session's `nmi` step reaches an attached
recorder (`pressRestore`), which delivers the NMI at the next poll after the IRQs due there.
Every checkpoint also keeps the number of I/O reads logged by then, and the driver checks the
reads per address at each checkpoint.

## Development bridge

The game program reaches no development-bridge call (`callOriginal`): the overlay slots run
`editorEntry`, `warMain` and `databaseInfoScreen`, and `pollTick` runs `tick10Hz`. No
`callOriginal` call is left in the sources (`ShippingCodeTests`): the two defensive checks of the
scenery interpreter that the disk's lists never reach stop the program with an error naming the
address (`scenery-3d.md`, Development bridge). The test rigs install no bridge; the replay matrix
installs one only to prove that nothing reaches it, and `Render3DFrameTests` to run the start of
the horizon pass as the original on both sides.

## Tests

| Suite | What |
|---|---|
| `MainLoopTests.interruptHandlers` | $2285 in both phases and $2304 on the full lab machine (no DMA stalls): 400 calls over every keyboard phase, pattern-player state and random keys and joysticks; memory, cycles, VIC registers, SID stores |
| `MainLoopTests.passesAtMeigs` | 20 whole passes $204B → $204B on the full lab machine: every phase of `$22` with the 1-in-8 tasks and the demo check, the skipped flip, slew, the views, the crash and splash messages; phase 3 in reality mode with the failure countdown expiring and the position sum one below the reliability, so the carry `$1CBE` hands `$EA84` decides whether a failure triggers (both outcomes checked); memory, exact cycles, VIC, SID |
| `MainLoopTests.passesInEurope1917` | 10 whole passes in war mode (the war overlay resident, its slot $A7EE and `warMain` every pass): every phase, the skipped flip, the war-exit check in mode 7; then 2 passes outside war mode with the `$08D7` request kept |
| `MainLoopTests.tick10Hz` | 600 ticks and polls on random states (flat bus): dispatch, repeats, bomb sweep, 5 Hz half paused or not, joysticks, TOD edges with the clock carries and the trim creep |
| `MainLoopSchedulerTests` | normal mode: one jiffy per frame and the keyboard phases over 20 s, the clock following the TOD, IRQs held during a load with one after it, the first IRQ after `displayInit` at the next line $97, IRQs held during the editor cache swap, RUN/STOP + RESTORE restarting through the title and prompts |
| `ColdInitTests` | the boot image against `Lab.boot`; the cold boot replayed through the title and prompts to flight (color, regular flight; and an ignored key, black and white, demo); the title screen's bitmap and golden frame (the cracker's two rows blank); the init routines on the flat bus |
| `ReplayTests` | replays of lab recordings (`re/sessions/replay-*.txt`): idle at Meigs 2 min, takeoff and climb, demo mode (the editor's mode 2 load), views and radar, radios and ATIS, a crash with the mode reload, a scenery area crossing (streaming), pause; at every checkpoint memory, VIC/SID registers, color RAM, the VIC bank and the split states, and golden frames presented with the latched split |
| `ReplayModesTests` | more replays: the database info screen (slot $A7FA, overlay 4, the key wait), the course plotter (menu, recording, display, off), leaving Europe 1917 (the cold restart from the main loop, through the title and prompts), a second crash (the editor from its cache, swapped out through $E6DB), the joysticks (the IRQ's latch, the 5 Hz `$2688`, the auto-centering), reality-mode failures (phase 3's check, the handlers, the drifts, the trim creep), dusk and night (the border operand `$22B5` the window IRQ stores) with the panel lights |
| `ReplayRestartTests` | RESTORE alone, then RUN/STOP + RESTORE: the cold restart nested in the port, through the boot loads, the title and the prompts back to flight |
| `ReplayReadCountTests` | the I/O read counts of the checkpoints: one read of `$DC09` more or less than the original fails at the next checkpoint, also where memory matches; logs recorded before the counts existed still replay |
| `ReplayMatrixTests` | every session in `re/sessions/` the lab can record, replayed through `NativeEngine` in random slices (memory and poll count at every $204B, the I/O state, the frames), and the pacing on identical work within ±10% of the lab per session; `war-hook` up to R (the `$FD00` no-op), `demo-loop` only with `FS2_REPLAY_LONG=1` |
| `MainLoopWiringTests` | the war-exit check against the editor's contract, the IRQ held while the editor's library disk I/O runs, the editor's text screen presented while the IRQ vector is $2304 |
| `BankedOutTickTests` | the tick body with I/O banked out (`$01` = $30) on the flat bus, against the original: `$DC09` and the SID stores in the RAM under I/O, and an IRQ taken inside the tick |
| `NativeEngineReplayTests` | the same recordings through `NativeEngine` in random time slices, among them Europe 1917 (the editor opened by E with its key waits, the war overlay's passes and polls); see `engine.md` |

The flat-bus rigs that run the poll with a tick due (`InputRig`, `SceneryVMTests.pollTickDue`)
give the port's `ioReadHook` the flat bus's RAM byte for `$DC09`: the flat bus has no CIA, and the
port reads the TOD through `readIO`.
