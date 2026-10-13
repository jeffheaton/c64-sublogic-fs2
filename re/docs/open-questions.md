# Open questions

The first survey of the disk and the knowledge-base build left a list of questions. The port and
its tests answered almost all of them; this page keeps the few that remain open and records how
each of the others was settled, with the evidence.

When a new question comes up, add it under "Open" with the experiment or the data that would
settle it. When one is settled: update `symbols.json` (confidence, comment) and the subsystem doc,
then move the item to "Settled" with the evidence.

## Open

These cannot be settled from this disk or the lab. None of them blocks the port.

| Question | What would settle it | Port meanwhile |
|---|---|---|
| **The original text of the two title records that modified copies overwrite** ($A839-$A85A, y=28 x=8, 31 characters; $A85B-$A87D, y=36 x=7, 32 characters; probably a copyright/credit pair). The disk has no "COPYRIGHT", "(C)", "1984" or "ARTWICK" anywhere. | An unmodified copy of v1.0 | The rows stay blank (`excluded.md`, `modes-ui.md`). |
| **The war-mode hook at $FD00 on an unmodified copy.** R in Europe 1917 makes the main loop call $FD00, but $F9F9-$FFF0 is zero on this disk and nothing on it writes $FDxx, so the call runs a chain of 377 BRKs (`re/sessions/war-hook.txt`). Either the cracker's changes removed SubLogic code there or it is a latent bug. | An unmodified copy: the bytes at $FD00, and any writer of $FDxx | A documented no-op (`excluded.md`). |
| **The bomb countdown.** No code and no display list on this disk stores a nonzero `$0AA7/$0AA8`, so bombs never score (`war.md`, Bombs). The writer may be missing from this disk (one candidate place is the empty $FD00 hook) or the feature may be unfinished. | An unmodified copy | The routine as it is: bombs never score. |
| **Real 1541 timing.** The port charges the loader's times as the lab's virtual 1541 measures them: the open 58,650 cycles, 382,690 per sector read (`scenery-3d.md`), the DOS command 52,167, 324,538 per sector written; the lab formats a disk at once, while a real 1541 takes over a minute (`editor.md`). Real drives add head stepping and rotational latency that depend on the track. | Timing traces of the loader on real hardware (or a cycle-exact drive emulation) | The lab's figures; pacing only needs about 10%, and loads hold the IRQ off in both. |

## Known differences from real hardware (by design)

Not questions, listed so nobody reopens them:

- **NTSC only.** The 50/60 Hz calibration stores the NTSC count; PAL's slower game (dt and the
  6-jiffy tick are not adjusted) is not reproduced (`main-loop.md`).
- **The $FD00 hook** is a no-op (above).
- **The processor port in degenerate polygons.** A polygon row with one crossing makes the sort
  touch `$00/$01`, the C64's processor port; the lab's flat bus and the port treat them as RAM.
  The game never produces such polygons (`render3d.md`).
- **Code the original was never meant to run.** Garbage polygons and invalid view or turn
  coordinator states can make the original execute data or overwritten code; the port reproduces
  everything up to that point and does not follow it there (`render3d.md`).
- **Loads cannot fail.** The disk is validated at import and read from memory, so the disk-error
  prompt and the SYSTEM ERROR screen are unreachable (`excluded.md`).
- **The SID filter's cutoff in Hz** is chip-dependent. The port's 6581 model supplies it; this is
  presentation (floating point allowed), not game state.

## Settled

### Code that was not analyzed in the first survey

| Item | Settled by |
|---|---|
| War overlay internals $AA03-$B1E9: pursuit, guns, bombs, scoring, damage; the region boundaries inside | `war.md`; `WarTests` (with `everyInstructionIsCompared`: every instruction start of $AA03-$B1E9 is compared with the original) and the edge cases of `WarEdgeTests.swift`; the regions in `symbols.json` are traced (high confidence) |
| Editor conversions $B3F6/$B559 ($B5A3, $B6D5, $B865) | `editor.md`; `EditorRoutineTests.roundTrips`, `stateToRecord`, `recordToState` |
| Instrument failure graphics: tables $F2E6/$F316/$F346, the $F35E-$F521 logic, the variables $F3E6-$F3EF | `panel.md` (The areas, `toggleInstrumentArea`); `GaugeTests.failureMasks`, `instrumentAreas`, `maskChangeTables`; `ReplayModesTests.realityFailures`, `duskAndNight` |
| Radio tuning helpers $E9A7-$EA5B | `radios.md` (`selectAdfDigit`, `tuneDecrementPre`, `tuneIncrementPre`, `setAdfDigit`, `renewAdfSearch`); `ReadoutTests.adfTuning` |
| $3A13, $38D4/$38F5/$EA50, $3C3F | `drawDme`, `renewNav1Search`, `renewNav2Search`, `renewAdfSearch`, `stepNav2Needle` (`radios.md`, `panel.md`); `ReadoutTests.dmeReadout`, `NavTests.cdiTasks`, `NavTests.mainLoopPasses` |
| $1A32/$1A6A on the 5 Hz tick, $1A0B | The airspeed and VSI needle drivers and the altimeter update (`panel.md`); `GaugeTests.airspeedTargets`, `vsiTargets`, `altimeterSweep` |
| $372B, $3746 and the slew axes | `slewAux` and `slewRateStep` (`flight-model.md`, `$3660`): east += step(`$0AA4`), north += step(−`$0AAC`), not rotated by the heading; `FlightModelTests` (every slew rate); lab `slew` (`features.md`) |
| Table $0E2E-$0E41 | No reader: no code points `$19E2` at it (the four gain tables are $0E10, $0E1A, $0E24, $0E42), and the `$0E24` table's t[i+1] read reaches it only for V_hi ≥ $90, above anything the integrator leaves (it zeroes a negative speed and sets the high byte to $64 on a signed overflow, so V_hi < $80). The port keeps the bytes. |
| Constants $0A54, $0A5E, $0A60, $0A62, $0A6E, $0A72, $0A76 | Unused: no absolute or indexed operand in the resident code or any overlay names them (listing scan). The port keeps the bytes. |
| $3AF1-$3B12 | The arctangent table of the nav math: 17 words atan(i/16) as binary angles, read by `arctanRatio` $3E9F (`radios.md`); `NavTests.vectorAngle` |
| $A558 (vectors $8015/$8027), $A731 | `turnCoordinatorHelper` (the cold start draws state 8 through $8027; $8015 has no caller) (`render3d.md`, `Render3DPanelTests`); `opJumpAbsolute`, an absolute jump usable as an op 0A target that no list uses (`scenery-3d.md`, `SceneryVMTests`) |

### Display and rendering

| Question | Answer |
|---|---|
| Who writes the fill selectors `$0880`/`$0882`, and when are 0 and $FF used? | The area display lists: op 1A copies palette words from `$0800-$081E` by the time of day `$083C` and the altitude `$0830` (`scenery-3d.md`). 0 at night, $FF below a cloud layer, $77/$FF above it, $D5/$2A by day, $77/$BB in the demo (`features.md` `night`, `clouds`; `render3d.md`); `ReplayModesTests.duskAndNight` |
| Does night use the $EA palette, or does the window show the background with only lights? | The latter: at night `$0880-$0882` = 0, so the window shows `$D021` with the dotted lights (lab `night`) |
| What sets `$0E79` bit 0 (skip the next flip)? | The integrator, when it applies a roll cancel `$0E76:$0E77` ($341B-$3426, `flight-model.md`); `MainLoopTests.passesAtMeigs` (the skipped flip) |
| Do the compass record ($21A8) and the slew readouts flicker in the double-buffered window? | No: $3823 redraws the compass and $3773 the slew readouts on every pass, into the buffer being drawn (`panel.md`); `ReadoutTests.compass`, `slewAndRedraw` |
| Does the polygon fill handle concave polygons? | Yes, whenever each row has an even number of crossings (`display.md`, `render3d.md`); `Render3DClipTests` (random convex and concave polygons) |
| Polygon buffer capacity: can an index reach 64 and overwrite $0E10+? | Yes: the original overflows, and the port overflows byte for byte (`render3d.md`, Polygons); `Render3DOverflowTests` |
| The per-point exponent mismatch of ops 40/41 | Reproduced exactly (the ground jitter): `transformGround` and the ops are literal (`render3d.md`, `scenery-3d.md`); `SceneryVMTests`, `SceneryPassTests` golden frames |
| The stale yaw low byte `$76`, and does the loader write it? | The forward views never write it (only the radar and down views store 0 there); the loader does not either (the bytes once read as loader writes at $75E8/$7607/$7668 are the operands of a call to $7686). The port reads it from memory like the original (`render3d.md`); `Render3DMatrixTests` (random stale `$76`) |
| Op 1C: why is the dotted pen skipped when `$083C` bit 0 is set? What is `$083C`? | `$083C` is the time of day from `$EBF2`: 1 day, 2 dusk, 4 night (0 after the display prompt until `$EBF2` runs). The dotted pen is for lights at dusk and night only (`display.md`, `raster.md`) |
| The attitude-indicator chord math | Ported literally (`render3d.md`); `Render3DPanelTests` |
| The $ED88 per-view trapezoids | The airframe (wing or tail) seen in each side view (lab `views`; `render3d.md`); `Render3DPanelTests` |
| `$F9` | Never written: it keeps the boot zero-page image's 0; only the edge-slope division reads it (`render3d.md`) |

### Flight model and timing

| Question | Answer |
|---|---|
| The stale `$C4` term in dt | Emulated: the port reads `$C4` from memory like the original (`flight-model.md`); `FlightModelTests` (every jiffy gap with several stale values) |
| Can the `$0E6B` divider climb to $80 and stall the tick? | It can after a long stretch with the IRQ on and no poll (a busy wait); the ticks then stop until the IRQ's increments wrap it. The port has the same arithmetic (`main-loop.md`); the replays through those waits match the lab (`ReplayTests`, crash and ATIS) |
| `$0967`, `$0969`, `$09A4` | REALITY MODE, EUROPE 1917 and RELIABILITY, confirmed in the lab (`features.md` `failures`, `war`) |
| Writers of `$0843:$0844` and `$0A0B:$0A0C` | `$0843`: the airports' `25 43 08 nn 00` records behind their range boxes (`scenery-3d.md`). `$0A0B`: no writer in any code; its disk value applies |
| `$0A04/$0A05` (rudder gain) | Computed and stored, never read anywhere (listing scan); the port keeps the store |
| Fuel units; wind record bytes 1-2 | 24-bit tank amounts with the gauge byte on top (`flight-model.md`, Engine); a wind record is knots, turbulence, then the direction word (`editor.md`, `flight-model.md` `$E766`) |
| PAL timing | Decided: NTSC only (above) |
| Is the position unit exactly 256 m per high-word unit? Runway sizes | Exactly: positions are 32-bit in 1/256 m, so a high-word unit is 256 m; the 246-265 m of the geographic checks is the database's map accuracy. Op 03's values are half-extents: the runway drawn is 2L × 2W (`scenery-3d.md`) |

### Input and radios

| Question | Answer |
|---|---|
| `$0A9A` | The mixture: RETURN, then ',' raises and '.' lowers (0-7); 7 stops the engine in reality mode (lab `switches`; `flight-model.md`, Engine) |
| `$09C6`; the carb heat polarity | The fuel tank selector (CTRL-F, then '.' right, ',' left; lab `switches`). `$0AA9` ≠ 0 is carb heat on ('HT', `panel.md`; the engine's −8 throttle) |
| CTRL-B, CTRL-D | CTRL-B clears the altimeter drift `$09CE-$09D1`; CTRL-D sets the DG offset `$08C0` from the compass (lab `switches` and scratch tests, `features.md`) |
| The third quick CTRL-C (`$0937`) | Retriggers the ATIS: the next pass matches the record again and the broadcast is typed again (`atis.md`) |
| NAV slot naming | `$0925` → station B `$092F` is NAV1 (`$0922` bit 0); `$0923` → station A `$0927` is NAV2 (bit 1), which the ADF shares (`radios.md`) |
| The marker flags `$084A/$084C/$084E` | `25 4C 08` and `25 4E 08` records set the outer and middle flags; no record sets the inner flag `$084A`, so no approach sounds it, but the cold image's three flags sound all markers once after the start; `$3EFC` consumes one flag per pass (lab `ils`, `idle`; `features.md`); `NavTests.markerBeacons` |
| '3' sets the magnetos to L without RETURN; LEFT SHIFT is ADF select | Both are the original's behavior as the lab shows it, kept (lab `switches`, `radios`); the known changes on modified copies do not touch the input code |
| `$0AA5/$0AA6` | The ammunition: −1 per burst pass (`spendRound` $B01D), 100 at a rearm (`war.md`) |

### Sound

| Question | Answer |
|---|---|
| `$09DD` (stall threshold $21) | The high byte of the angle-of-attack proxy `$09DC` (interp($0E10) × elevator), not degrees. ≥ $21 sounds the horn and lights the lamp; ≥ $24 or $80-$E6 starts the stall and maneuver timers (`flight-model.md` (a) step 6; lab `stall`) |
| The engine-target inputs | Specified in `flight-model.md` (Engine `$EE6B`): magnetos `$EE14/$EE15`, fuel `$09C7/$09C8`, carb heat `$0AA9`/`$EE16`, failure bits `$09BF`, the windmill RPM `$BC` |
| The 6581 cutoff in Hz | Decided (above): the port's 6581 model, presentation only |

### Modes, scenery and data

| Question | Answer |
|---|---|
| Op 1E's 8 parameter bytes; the native pointers `09 [$F441]` and `0A [$1D13]` in the Chicago data | The parameters are the runway per wind quadrant and the temperature per season (`atis.md`). The two pointers lie in the Chicago area's dead tail under the detail slot, which the detail blocks overwrite before the code reaches it; no list on the disk uses op 0A (`scenery-3d.md`) |
| `$0846` vs `$0848` | The code uses them together: their high bytes are both added to runway headings, the DG offset (CTRL-D) and the editor's heading; the wind layer adds `$0847`, and `$0849` when the bit shifted out of `$09D7` is set (`flight-model.md`, `$E766`). Which is grid convergence and which magnetic variation does not change the port; the names stay neutral (`headingOffsetA/B`) |
| `$0830`/`$0832` (time or altitude?) | `$0830` is the MSL altitude ($CE84); the area lists read it to choose the cloud palette words. `$0832` is the phase rotor the main loop rotates on odd phases, which the lists test; the port runs the lists as they are (`scenery-3d.md`) |
| `$0856-$085C` (dusk thresholds or ATIS ceiling?) | The cloud layers in meters: `$0856/$0858` cloud 1 bottoms/tops, `$085A/$085C` cloud 2; the ATIS ceiling is `$0856` × 2150 >> 16 (`atis.md`, `editor.md`). The time-of-day thresholds are at $EBD2 |
| Does the root block or an area overwrite the user mode library at $C800 with the editor or war overlay resident? | No: the loader stores nothing at $C000 and above while `$7327` is set, which every load does, so tails past $BFFF are dropped (`scenery-3d.md`, The $C000 guard; `SceneryStreamingTests`) |
| Block 64: overlay 4 and the library target | Confirmed: CTRL-X with the master disk loads overlay 4's bytes into the user modes; CTRL-Z formats the disk in the drive (lab `library`; `editor.md`) |
| The view codes | '5' (or joystick-1 fire), then T/Y/H/N/B/V/F/R/G sets `$0ACA` = 0/2/4/6/8/$0A/$0C/$0E/$FF (lab `views`; `input.md`) |

### Settled by cross-checking against the lab (do not reopen)

| Claim | Resolution |
|---|---|
| "Keyboard scan every 3rd frame" | Every 4th frame (15 Hz): 2 idle, scan on 0, release on −1 (verified $22CD-$22F2) |
| "Block 66 = Boston/Block Island/Martha's Vineyard ATIS data" | Block 66 is the 9-area root list. Its tail after offset $87 is dead residue. |
| "Overlay (65,1) = normal flight with war HUD" | Block 65 is only the header plus END at $A800. The strings after it are residue, overwritten by block 66. |
| "Font = 64 glyphs ($20-$5F, 128 bytes)" | 59 glyphs ($20-$5A) at $1634-$16A9. $16AA is code. |
| Cosine table "65 words", "round()", "entry 25 should be $68A7" | 66 words; within one unit of the true cosine except entry 25, a glitch about 300 too low |
| "Blocks $1A-$25 load to $A3DF" | 12 blocks: $77E0-$A7DF. The ADI/TC and runway op are resident; $A73E-$A7DC is zero. |
| "$AD00-$B3DF looks like game code" | Build residue: it duplicates the editor overlay. The block read/write at $B1FE/$B235 belong to the editor. |
| "$AB88 fills 24 rows × 65 bytes" | 15 records (modes 10-24) × 65 bytes at $C800; every byte of record n = n |
| "ATIS tokens expanded by $F16A" | $F16A fills live values; the teletype $F239 expands tokens |
| "Crack text at $A83A-$A880" | Exactly $A839-$A85A and $A85B-$A87D |
| "Stall horn re-armed every frame by $3016" | At 5 Hz inside the aero routine $2F45; suspended while paused |
| "$E565 runs a wait loop when $7326 is set" | A permanent protection hang, only when `$7326 ≠ 0` and (`$5F` bit 7 or `$22 ≥ $80`) |
| Main loop phase list | The demo check $2133 and the war-exit check $213D-$2149 run once per 8 passes (the `$22 & 4` block) |

### Corrections found while building the knowledge base

| Earlier claim | Finding |
|---|---|
| Refuel/repair/rearm check at $3613 | It starts at $3614, as the tail of $35BD (branch target from $35EE) |
| `$0A0A` flap drag as a word | It is a byte (enters the drag as $0A0A·256); a word would overlap `$0A0B` |
| Projection tables of 128 bytes | Each has a 129th byte repeating entry 127 ($9F12, $9F93) |
| ADI pitch table of 32 entries | $A356-$A377 is 34 bytes |
| Slew text at $EB66 | The records start at $EB63 (y=2, x=20 and y=2, x=82) |
| Free space $79A8-$79FF | $79A8 is a bare return; the free space is $79A9-$79FF |
| Code regions with embedded data | $1CE7-$1CEF (fuel-selector shape), $8458-$845E (horizon line list), $E7F2-$E7FD (ADF state), $EA6C-$EA83 ('AIRCRAFT PROBLEM' record), $F3E6-$F3EF (variables), $F4BD-$F4C4 (bit masks), $2308-$2309, $26FF, $2715-$2717 |
| Key handlers not named in the first survey | Decoded from the $2718 table: $2B25 ADF select (A / CTRL-A / LSHIFT), $2B63 carb heat (CTRL-I), $2B6E lights (L / CTRL-L), $2B8C COM (CTRL-C), $2BA7 OBS (CTRL-V), $2BAC NAV (CTRL-N), $2B0D transponder (CTRL-X), $2C55 fuel tank (CTRL-F), $2807/$283D/$285F digits 1-3, $2865/$2869 digits 8/9, $2BEF Z |
| The ATIS ceiling multiplier at `$0866` | The multiplier is the immediate 2150 (two immediate operands); no code reads the byte at $0866 (`atis.md`) |
| Scenery lists running past $C000 into the instrument save buffers | They do not: the loader's $C000 guard drops those bytes (`scenery-3d.md`) |
| `25 54 08` as the airport elevation | It stores the ATIS Zulu offset `$0854`; the elevation is `$0843`, stored per airport (`scenery-3d.md`) |
