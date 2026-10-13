# Memory map and load chain

The port keeps the original 64 KB layout: `Machine.mem` is the byte image the translated routines work on, at the original addresses. Three things force this:

- Scenery bytecode reads and writes absolute addresses and calls native routines by address.
- Bitmap memory is the framebuffer.
- Keeping the layout makes every ported routine directly comparable with the original in the lab.

This page explains the layout. `re/symbols.json` is authoritative for exact ranges; the tables at the end are generated from it.

## Logical block filesystem

SubLogic reads the disk as **164 logical blocks of 1 KB**. Each block is 4 consecutive *used* sectors in track/sector order over tracks 1-35, with two exceptions:

- Track 3 is skipped entirely.
- Track 18 uses only sectors 6-18. Sectors 0-5 hold the BAM and directory.

The loader's sector-usage mask is at $7473. That gives 656 sectors, which is 164 blocks. `FS2Data.SubLogicDisk` reproduces the mapping, and `GameData` checks every block of the disk when it is imported.

| Blocks | Contents |
|---|---|
| 0-1 | Stage-2 loader (T1 S0-S7) at $7300 |
| 2-4 | Stage 3 / overlay 0 at $A7E0: cold init, title records, zero-page image, build residue |
| 5 | Empty |
| 6-9 | Panel bitmap: loaded at $5000; the panel is $5180-$5F3F |
| $0A-$19 (10-25) | Main code and data, $0200-$41FF |
| $1A-$25 (26-37) | 3D engine, scenery interpreter, attitude indicator / turn coordinator and runway op, $77E0-$A7DF. **Twelve blocks**, ending at $A7DF, not $A3DF. |
| $26-$29 (38-41) | $C000-$CFFF: the dead debug monitor (at run time the instrument save buffers), user-mode area $C800, sound driver $CC00, gauges $CE84 |
| 42-47 | Overlay 1: editor |
| 48-63 | Scenery areas: WWI area 48-51, Champaign 52-57, New England 58-63 |
| 64 | Overlay 4 (database info). On a separate FS2-formatted disk the same block number holds the user mode library. |
| 65 | Overlay 3 (flight): header and END only |
| 66 | Scenery root list (9 area boxes) plus a dead tail |
| 67 | Empty |
| 68-129 | Scenery areas and detail blocks (see `scenery-3d.md`) |
| 77, 79, 99 | Orphans: valid-looking display lists that nothing references (77 and 79 are identical). Ignore them. |
| 88, 91, 101, 108, 111, 130-149 | Empty |
| $96-$9D (150-157) | $E000-$FFFF: engine pitch, overlay manager, ATIS, radios, engine model, instruments, plotter |
| 158-160 | Overlay 2: war (Europe 1917) |
| 161-163 | Empty |

## Boot chain (original, without the cracker's loader)

1. Modified copies of the disk carry a cracker's KERNAL boot loader in **track 18 sector 2**; it
   is not ported (`excluded.md`).
2. SubLogic's stage-2 loader (blocks 0-1 at $7300) starts at $78A2: it loads stage 3 (blocks 2-4)
   to $A7E0, runs the drive-status check $7848 (protection, not ported) and jumps to $A7E2. The
   port starts from the state stage 2 leaves there (`Machine.bootMemory`, `Machine.booting`).
3. Stage 3 ($A946, the cold init) performs five loads from the table at $A800 (`bootLoads` $A988):
   - $0A×16 to $0200
   - $06×4 to $5000
   - $1A×12 to $77E0
   - $26×4 to $C000
   - $96×8 to $E000
4. $ABB0 copies $AC02-$ACFF to zero page $02-$FF; at $A970 the cracker's bytes (on modified
   copies) are scrubbed.
5. The rest of the init chain, in order: $AAFA interrupt and timing setup (raster IRQ $2285, NMI
   $2700, the 50/60 Hz TOD calibration), $AA1C title and display prompt, $AA71 operating-mode
   prompt, $AA91 the panel's initial state (with the SID init), $AA07 the radio hook patches,
   $AB66 the copy of panel row 14 into bitmap B, $AB88 the user library fill.
6. On to $2048: the main loop.

`main-loop.md` specifies every step and its port (`Game/ColdStart.swift`).
`FS2Data.ColdImage.memory` builds the image as it stands just before the init chain ($A970): stage
2 and stage 3, the five loads, the zero-page copy and the scrub of the cracker's bytes (the lab's
and the tests' reference).

**The initial variable image is data.** Several ranges are never written by code, so their
loaded values are the game's constants and cold-start state; the port gets them from the user's
disk by running the boot loads:

- $0800-$0EFF: aircraft constants, palette words, horizon lists, wind and cloud defaults, mode-record defaults.
- The zero-page image $AC02-$ACFF.
- The radio strings at $2196-$223F and $E7F3-$E7FD.

## Overlays

There is one overlay window at **$A7E0**. The manager is at $E5C0-$E712 (with the block cache $E58F) and its table is at **$E559**, a list of (first block, count) pairs.

| # | Blocks | Contents | End word | Entry |
|---|---|---|---|---|
| 0 | 2-4 | Cold start (stage 3) | $AD00 | $A7E2 → $A946 |
| 1 | 42-47 | Editor | $BC6B | $A7E8 → $B09A |
| 2 | 158-160 | War game | $B1EA | $A7EE → $AA03 |
| 3 | 65 | Plain flight (header only) | $A800 | $A7F4 returns at once |
| 4 | 64 | Database info screen | $A878 | $A7FA → $A86A |

How an overlay is laid out and called:

- **Header.** Every overlay starts with an end-address word, then five 6-byte slots at $A7E2/$A7E8/$A7EE/$A7F4/$A7FA. The owning overlay's slot jumps to its code. The other slots call $2015/$2018/$201B/$201E/$2021, which load the right overlay and re-enter the slot.
- **Root block.** After any overlay load, $E618 loads **block 66 (the scenery root list) at the overlay's end address** and clears the block-cache tags $0900-$0903. In flight the root is therefore at $A800.
- **Who calls which slot.**
  - `$A7F4` every pass (keeps the flight overlay resident).
  - `$A7E8` when `$08BA|$08BB` is set (editor).
  - `$A7EE` in Europe 1917.
  - `$A7FA` when `$0E87` is set (CTRL-E).
- **Editor cache.** $E6D8/$E6DB swap $A7E0-$BCDF with RAM under I/O at $D000-$E4FF to keep the editor cached. `$08BC` tracks the cache: 0 = never loaded, 1 = cached, 2 = invalid. The course plotter also records display lists from $D000 and sets `$08BC=2`.

**Port:** the same mechanism, memory-faithful (`Game/Overlays.swift`, `Game/OverlaySlots.swift`):
one overlay at a time in the window, loaded by `loadOverlay` from `Machine.diskBlocks` with the
loader's memory effects and time, the root block after it, the slots executed from the overlay
bytes in memory, and the editor cache and the course-plotter recording sharing $D000-$E4FF as in
the original. Setting EUROPE 1917 forces mode 7, and leaving mode 7 restarts cold
(a jump to $A7E2); the editor exit resets the war counters (`editor.md`, `war.md`).

## Runtime-only areas

| Range | Use |
|---|---|
| $0400-$07FF | Transformed-vertex cache: 128 × 8 bytes. Also the text screen of the editor and of the system/disk-error screens. The loaded bytes are residue. |
| $0B10-$0E0F | Polygon vertex buffers (structure of arrays, 12 × 64 bytes) with ping-pong copies |
| $4000-$517F / $6000-$717F | Window rows 0-111 of bitmap A and bitmap B, double-buffered |
| $7180-$72BF | Copy of panel row 14 in bitmap B |
| $7C00-$7E2F | Window screen RAM, filled with one byte by $EC7C |
| $A887-$BFFF (flight) | Scenery area list: slot 0 at root+$87, plus a detail block in slot 1 at an area-specific address. Longer areas (to $C086) and the New York detail (to $C20E) are cut at $BFFF by the loader's `$7327` guard (`scenery-3d.md`). |
| $C800-$CBFF | User mode library: 15 × 65 bytes |
| $D000-$E4FF | Editor cache and course-plotter recording (RAM under I/O) |
| $FFFA-$FFFF | Vectors. The disk values are stale; at run time NMI = $2700 and IRQ = $2285. |

## ABI vector tables

Two vector tables are a **stable ABI**, and the port must keep their addresses:

- **$2000-$2047**: 24 jump vectors.
- **$8000-$802F**: 16 jump vectors.

Scenery bytecode can call native code by address (op 0A calls [abs16]; op 09 calls a display list through a pointer), although no list on the disk uses op 0A (`scenery-3d.md`). The overlays, the root block's patched hooks and the slots call through these tables. The port keeps the vector bytes in memory and maps the op 0A targets to their ports. The `vec*` and `rv*` routines in `symbols.json` name every entry.

## Regions (generated from symbols.json)

Regenerate with `python3 re/tools/region_tables.py` after changing `symbols.json`.

<!-- generated:regions:begin -->
The excluded kinds are shown in **bold**: residue, crack, loader and protection. "Notes" is the
first sentence of the region's comment in `symbols.json`.

### Resident image

| Range | Kind | Name | Subsystem | Notes |
|---|---|---|---|---|
| $0002-$00FF | data | `zeroPage` | core | Zero-page variables. |
| $0100-$01FF | buffer | `stack` | core | 6502 stack. |
| $0200-$02C7 | table | `rowAddressHiTable` | raster2D | Bitmap row base high bytes for rows 0-199. |
| $02C8-$038F | table | `rowAddressLoTable` | raster2D | Bitmap row base low bytes for rows 0-199 (standard C64 bitmap layout: $4000 + (r>>3)*320 + (r&7)). |
| $0390-$03F7 | free | `free0390` | - | All zero on disk; no references found. |
| $03F8-$07FF | buffer | `vertexCacheArea` | renderer3D | Runtime: transformed-vertex cache $0400-$07FF (128 x 8 bytes) and the text-mode screen $0400 of the editor and the system/disk-error screens. |
| $0800-$081F | table | `paletteSources` | renderer3D | 16 palette words (fill/sky/ground patterns) that display lists copy into the active colors $0876-$0882 by time of day ($0830/$083C). |
| $0820-$08FF | data | `variables0800` | core | Core state: time/flags $0830-$085C, active colors $0876-$0882, radar height $0888-$088B, horizon list pointer $0890, keyboard slots and queue $0899-$08B0, mode requests $08BA/$08BB, editor-cache state $08BC, prompt key $08C4, pause $08CC, sound enable $08D3, war counters, block request $08FB-$08FF. |
| $0900-$09FF | data | `variables0900` | core | Core state: block cache $0900-$0905, radio search/station data $0920-$0960, user library pointer $0961, current mode $0963, the 65-byte mode record $0964-$09A4, editor extras $09A5-$09AA, engine/fuel $09BE-$09CD, flight state $09D0-$09FF. |
| $0A00-$0ACE | data | `flightVariables` | flightModel | Flight variables, aircraft constants $0A52-$0A7F (never written by code: pure data), control positions $0AA3-$0ACC (view direction $0ACA). |
| $0ACF-$0ACF | code | `editorHookRts` | editor | A single RTS executed as the hook editorExitHook (lab coverage: every session that leaves the editor). |
| $0AD0-$0B0F | table | `horizonLists` | renderer3D | Four 16-byte horizon display lists, one per yaw quadrant: ground moveto/lineto (-8000,500)-(8000,500) rotated per quadrant, then END. |
| $0B10-$0E0F | buffer | `polygonBuffers` | renderer3D | Polygon structure-of-arrays buffers: 12 arrays of 64 bytes at $0B10 + k*$40. |
| $0E10-$0E4B | table | `aeroGainTables` | flightModel | Speed-indexed gain tables read through $19E2: $0E10 elevator->AoA, $0E1A gamma rate, $0E24 turn rate, $0E2E no direct reader, $0E42 rudder. |
| $0E4C-$0E8D | data | `variables0E4C` | core | Sound/IRQ variables $0E58-$0E7E, window palette $0E61-$0E69, course plotter $0E80-$0E87, $DD00 shadow $0E89, disk-error pointer $0E8A. |
| $0E8E-$0E90 | text | `diskErrorLineLead` | editor | Start of the 40-character editor disk-error line (copied to screen $07C0 by the editor at $B216). |
| $0E91-$0E93 | **crack** | `diskErrorTagLeft` | crack | Three bytes before '** DISK READ/WRITE ERROR **' that are spaces in the original and are overwritten in modified copies. |
| $0E94-$0EAE | text | `diskErrorLineText` | editor | '** DISK READ/WRITE ERROR **' (original SubLogic text). |
| $0EAF-$0EB1 | **crack** | `diskErrorTagRight` | crack | Three bytes after the disk-error text, restored as spaces like diskErrorTagLeft. |
| $0EB2-$0EB5 | text | `diskErrorLineTail` | editor | Trailing spaces of the disk-error line. |
| $0EB6-$0EFF | free | `free0EB6` | - | Zero on disk. |
| $0F00-$0F61 | table | `panelMaskAndMarkerTables` | panel | Bit masks $0F00-$0F0F (01..80, then MSB-first 80..01 at $0F08) and XOR point-list marker shapes $0F10/$0F1D/$0F30/$0F49. |
| $0F62-$0F66 | data | `needleAngleState` | panel | Angle each XOR needle was last drawn at (altimeter long/short hand, airspeed, VSI); the old needle is erased by redrawing it. |
| $0F67-$0FD3 | table | `needleGeometry` | panel | Needle centers x $0F67 / row $0F6C (hi-res pixels), type $0F71 (0 = long, else short), and the shape pointer tables $0F76 (long, 23 used) / $0FA6 (short, 23). |
| $0FD4-$14C1 | asset | `needleShapes` | panel | Needle run-length shapes: per scanline (x offset, run length), ending with a byte with bit 7 set. |
| $14C2-$14D9 | table | `asiNeedleTableRegion` | panel | Airspeed needle positions (88 steps per revolution) indexed by min(V_hi, $5A)/4. |
| $14DA-$158D | table | `rasterTables` | raster2D | Column byte offsets $14DA (160 entries), pixel masks $157A-$1589, fill patterns $158A-$158D. |
| $158E-$1611 | table | `cosineTableRegion` | fixedMath | Cosine table, 66 signed words. |
| $1612-$1633 | table | `markerAndFontTables` | panel | Marker shapes $1612/$161B, font row expansion $1624, font clear masks $162C/$1630. |
| $1634-$16A9 | asset | `font3x5` | text | 3x5 font, 59 glyph words for ASCII $20-$5A only (characters $5B-$5F would read code bytes from $16AA). |
| $16AA-$1A0A | code | `mathLibrary` | fixedMath | Q15 multiply, fractional divide, unsigned multiply, sin/cos, 8x8 multiply, shifts, negate, speed-table interpolation. |
| $1A0B-$1CE6 | code | `panelIndicators` | panel | Needle drivers $1A0B/$1A32/$1A6A, XOR needle drawer $1A86 (scanline loop $1B4B with self-modified opcodes $1B56/$1B59/$1B87/$1B8D), linear indicators $1B92-$1CE6. |
| $1CE7-$1CEF | table | `fuelSelectorShapeRegion` | panel | XOR point-list shape (4 points) drawn by $1CF0. |
| $1CF0-$1D53 | code | `panelMarkers` | panel | Fuel-selector marker $1CF0 and the XOR point-list plotter $1D01. |
| $1D54-$1EC9 | code | `textRenderer` | text | Signed 5-digit print $1D54, text records $1DDE/$1DE2/$1E01, record lists $1E99, window clear $1EAF. |
| $1ECA-$1FFF | free | `free1ECA` | - | All zero. |
| $2000-$2047 | code | `coreVectors` | core | 24 JMP vectors: a stable ABI that the overlays and the resident code call by address (display-list op 0A could call them too; no list on the disk uses it). |
| $2048-$2195 | code | `mainLoopCode` | mainLoop | Main loop and its 4/8-phase task dispatch on $22. |
| $2196-$223F | data | `panelTextRecords` | panel | OBS1 $2196, DG drawn $2197, tach drawn $2198, OBS2 $2199, then the readout text records $219C-$220F (one table each: DG, compass, COM, NAV1/NAV2, OBS, transponder, tach, clock, DME, lights, carb heat) and the six TO/FROM records $2210-$223F. |
| $2240-$2284 | code | `panelInitAndGetKey` | panel | Panel readout redraw at init $2240 and the wait-for-key routine $2250. |
| $2285-$2307 | code | `rasterIrqCode` | scheduler | Two-phase raster IRQ $2285 (screen split, frame tick, keyboard phase, voice-3 pattern player) and the alternate tick-only IRQ $2304. |
| $2308-$2309 | data | `patternPlayerState` | sound | Voice-3 gate pattern step counter $2308 and working shift register $2309. |
| $230A-$2417 | code | `tickScheduler` | scheduler | Pattern step $230A, polled 10 Hz scheduler $2330/$2348 (key dequeue, engine pitch, repeat, bomb sweep, 5 Hz aero/joystick, 1 Hz sound and clock). |
| $2418-$2471 | code | `keyboardScanCode` | input | Keyboard matrix scan $2418. |
| $2472-$24C1 | table | `keyboardTables` | input | Row masks $2472, column selects $247A, matrix-to-code table $2482. |
| $24C2-$25EA | code | `keyboardSlots` | input | Held-key slots, press/repeat queueing, release check $2505, CIA1 sampler $2574, queue $25C4/$25DC. |
| $25EB-$26FE | code | `displayInitAndJoystick` | display | VIC init $25EB, text-mode IRQ swap $2673 (port: Machine.textModeIrqSwap, Sources/FS2Core/Display/TextMode.swift), joystick action $2688, auto-center $26EC. |
| $26FF-$26FF | data | `restoreOneShotFlag` | input | One-shot flag for the RUN/STOP+RESTORE restart. |
| $2700-$2714 | code | `restoreNmiCode` | input | NMI handler: RUN/STOP+RESTORE restart (through the cold-start slot $A7E2). |
| $2715-$2717 | data | `indicatorState2715` | panel | Control indicator state: the elevator indicator position ($50-v)>>3 at $2715 (elevatorIndicator) and the aileron indicator value at $2716 (aileronIndicator); $2717 has no known reader or writer. |
| $2718-$27D7 | table | `keyDispatchTableRegion` | input | 96 handler words for command codes $00-$5F (default $2CC1 = RTS). |
| $27D8-$2E91 | code | `keyHandlers` | input | Command dispatcher $27D8 and every in-flight key handler (controls, radios, views, modes, war keys); view capture $2E84. |
| $2E92-$32DE | code | `aeroModel` | flightModel | Control-derived coefficient builders $2E92-$2F3F and the 5 Hz aerodynamics update $2F45 (also arms the stall horn). |
| $32DF-$365F | code | `flightIntegrator` | flightModel | Helper $32DF, per-frame integrator $32EE, ground contact/crash $3515, density/auto-level $35BD, refuel/repair/rearm $3614/$3638. |
| $3660-$3772 | code | `slewModel` | flightModel | Slew-mode integrator $3660 and $372B (vector $200C). |
| $3773-$3A66 | code | `panelReadouts` | panel | Heading/slew $3773, DG $377C (degrees $37EA/$37F5), 3-digit formatter $3804, compass $3823, frequency digits $3896, NAV1/NAV2/COM displays $38BD/$38D9/$3903 with the search renewals $38D4/$38F5, OBS $3923/$3976, clock $39B6/$39D9, DME $3A13, radio gate $3A53, transponder $3A5C. |
| $3A67-$3A70 | table | `magnetoLabelPointerRegion` | panel | Five pointers to the magneto label records O/L/R/B/S at $EE57-$EE67. |
| $3A71-$3AF0 | code | `panelReadouts2` | panel | Carb-heat, lights and magneto labels $3A71, tach $3AB9. |
| $3AF1-$3B12 | table | `arcTableRegion` | radios | Arctangent table of the nav bearings: 17 words atan(i/16) as binary angles, 0..$2000 (45 degrees), read with linear interpolation by $3E9F. |
| $3B13-$3B31 | table | `localizerNeedleShapeRegion` | panel | Localizer needle XOR point list (14 points: a 2-pixel-wide, 7-row bar), then 2 zero bytes. |
| $3B32-$3F89 | code | `navInstruments` | radios | NAV1/NAV2 CDI tasks $3B32/$3B9B (deviation $3B61, TO/FROM $3D2B, needle $3D84, glideslope and DME $3DA2), OBI drawing $3BAF/$3C1A/$3C3F, glideslope bar $3C5D, TO/FROM records $3C81, station bearing $3C8F with the arctangent $3E46-$3EFB, localizer needles $3D68/$3D71, marker beacons $3EFC, distance $3F38 (vector $2030). |
| $3F8A-$3FFF | free | `free3F8A` | - | All zero. |
| $4000-$517F | buffer | `bitmapAWindow` | display | Bitmap A, window rows 0-111 (front or back buffer). |
| $5180-$5F3F | asset | `panelBitmap` | panel | Panel hi-res bitmap, 320x88, character rows 14-24 of bitmap A (disk blocks 6-9). |
| $5F40-$5F76 | code | `graphicsRestore` | display | $5F40 restores bitmap mode after a text screen (port: Machine.restoreGraphics, Sources/FS2Core/Display/TextMode.swift); $5F5D prints a hex digit to the text screen (system error, not ported). |
| $5F77-$5FAA | text | `diskErrorPromptText` | diskUi | 'DISK ERROR - PRESS A TO RETRY OR B TO IGNORE ERROR' (screen text for $5FAB). |
| $5FAB-$5FF0 | code | `diskErrorPrompt` | diskUi | Disk-error retry/ignore prompt reached via $732B. |
| $5FF1-$5FFF | free | `free5FF1` | - | All zero. |
| $6000-$717F | buffer | `bitmapBWindow` | display | Bitmap B, window rows 0-111 (the other buffer). |
| $7180-$72BF | buffer | `bitmapBPanelRowCopy` | display | Copy of panel character row 14 written by $AB66 so a late raster split on line 112 still shows the panel. |
| $72C0-$72FF | free | `free72C0` | - | All zero. |
| $7300-$7834 | **loader** | `stage2Loader` | loader | SubLogic stage-2 IEC block loader (blocks 0-1) with its API at $7300-$7314 ($7303 fatal error, $7306 open, $7309 read, $730C write, $730F close, $7312 DOS command), sector mask $7473. |
| $7835-$7897 | **protection** | `driveStatusCheck` | protection | A drive-status check (copy protection). |
| $7898-$7909 | **loader** | `stage2Boot` | loader | Loader overlay table copy $7898 and the stage-2 boot entry $78A2 (loads stage 3, runs the drive-status check, enters the cold-start slot $A7E2). |
| $790A-$790A | code | `loaderNmiReturn` | systemError | RTI used as the NMI target in loader contexts ($78A9). |
| $790B-$791D | text | `systemErrorText` | systemError | Screen-code text of the 'SYSTEM ERROR' line, copied to $0401 by $791E. |
| $791E-$79A8 | code | `systemErrorCode` | systemError | Fatal 'SYSTEM ERROR' path $791E-$794D (prints error code and caller address, hangs): not ported. |
| $79A9-$79FF | free | `free79A9` | - | All zero. |
| $7A00-$7AFF | asset | `aiBezelSprites` | display | Four multicolor sprites (pointers $E8-$EB) forming the static attitude-indicator bezel, pitch ticks, bank ticks and aircraft symbol. |
| $7B00-$7B99 | **residue** | `linkerExportTable` | residue | Development residue: linker/export address table (about 70 words naming entry points and tables of the $0F00-$1EAF instrument/math library, then $7A00). |
| $7B9A-$7BFF | free | `free7B9A` | - | All zero. |
| $7C00-$7E2F | buffer | `windowScreenRam` | display | Window screen RAM (rows 0-13): one byte (sky/ground nibbles) filled at runtime by $EC7C from the time-of-day palette. |
| $7E30-$7FE7 | asset | `panelScreenRam` | panel | Panel cell colors (rows 14-24; high nibble = set bits, low nibble = clear bits), including the lamp cells $7E3D/$7E3E/$7E7B-$7E7D that code rewrites. |
| $7FE8-$7FFF | buffer | `spritePointers` | display | Unused screen bytes and sprite pointers $7FF8-$7FFB (written as $E8-$EB by $25EB). |
| $8000-$802F | code | `rendererVectors` | renderer3D | 16 JMP vectors of the 3D/raster module ABI; $802A/$802D are radio hooks patched at init ($AA07). |
| $8030-$8110 | code | `radioRecordOps` | sceneryVM | Display-list ops 1D (NAV/LOC records, $8030), 1E (ATIS records, $8084) and 0D (block load, $80E2). |
| $8111-$8457 | code | `viewMatrixAndHorizon` | renderer3D | View matrix $8111, ground base $8324, horizon pass $83A4 (start). |
| $8458-$845E | data | `horizonLineListRegion` | renderer3D | 7-byte display list 'pen 3, 2D line x1 y1 x2 y2, return' whose endpoints $83A4 rewrites each frame; area lists draw it via op 09 through the pointer at $0890. |
| $845F-$86A3 | code | `horizonFillCode` | renderer3D | Sky/ground fill: whole rows $8504, unrolled row filler $851B, split row $85C0, horizon Bresenham $8623. |
| $86A4-$872F | table | `opcodeHandlerTableRegion` | sceneryVM | 70 handler words for display-list opcodes $00-$45 ($8778 = invalid). |
| $8730-$8FE7 | code | `sceneryInterpreter` | sceneryVM | Interpreter $8742/$8749/$8752 and opcode handlers: calls, compares $8E4A-$8F7A, origins $8BC1/$8BFD, vertex cache ops $8917-$8A04, dashed line $8A43, line-clip driver $8B40. |
| $8FE8-$990F | code | `clipAndPolygon` | renderer3D | Sutherland-Hodgman polygon clipping, outcodes $93D2/$941B, line clipping $9464-$9644, polygon projection and scan fill $96D4-$990F. |
| $9910-$9BD5 | code | `rasterPrimitives` | raster2D | Spans $9910/$9996, plot $99FD, Bresenham line $9A1D, dotted plot $9B80, pen ops $9B91/$9B9B. |
| $9BD6-$9BE5 | table | `colorMapRegion` | raster2D | Scenery color code 0-15 -> 2-bit pen. |
| $9BE6-$9E91 | code | `penAndProjection` | raster2D | Pen ops $9BE6/$9BF5, span colors $9C93/$9C9C, projection front-end $9D05/$9D21, divide $9D3D. |
| $9E92-$9F12 | table | `projectionXRegion` | renderer3D | TX[i] = floor(5i/8), i = 0..127, plus a 129th byte repeating entry 127. |
| $9F13-$9F93 | table | `projectionYRegion` | renderer3D | TY[i] = floor(7i/16), i = 0..127, plus a 129th byte repeating entry 127. |
| $9F94-$A353 | code | `transforms` | renderer3D | Projection $9F94, ground (block floating point) transform $9FD0, 3D transform $A1CE. |
| $A354-$A355 | data | `aiLastAttitude` | panel | Pitch/bank at the last attitude-indicator redraw. |
| $A356-$A377 | table | `aiPitchTableRegion` | panel | Attitude-indicator chord angle offsets indexed by (pitch+$20)/2 (34 bytes). |
| $A378-$A4F1 | code | `attitudeIndicator` | panel | Attitude indicator $A378, row fill $A4A0, span patch target $A4CA. |
| $A4F2-$A531 | table | `tcWingTableRegion` | panel | Turn-coordinator wing line offsets: 16 entries x (dx1, dy1, dx2, dy2). |
| $A532-$A5A6 | code | `turnCoordinator` | panel | Turn-coordinator XOR wings $A532 and $A558 (vectors $8015/$8027). |
| $A5A7-$A5C7 | data | `runwayMiniListRegion` | renderer3D | Display-list template used by op 03: filled runway rectangle (2F 40 41 41 41 29) and dashed centerline (1B 2B), return. |
| $A5C8-$A73D | code | `runwayOp` | renderer3D | Runway op 03 handler and opJumpAbsolute $A731 (an absolute jump with no opcode slot). |
| $A73E-$A7DC | free | `freeA73E` | - | All zero. |
| $A7DD-$A7DF | **residue** | `residueA7DD` | residue | Three stray bytes at the end of the $77E0 load. |
| $C000-$C7CF | buffer | `debugMonitor` | panel | On disk: SubLogic's remote debug monitor, never called (installs IRQ/BRK vector $C79A, expansion-port I/O $DE03/$DE06/$DE09, command table $C22B); the code is NOT PORTED. |
| $C7D0-$C7D3 | buffer | `instrumentSaveTail` | panel | Last bytes of the instrument save buffer that starts in debugMonitor (record pointer $C7C0; lab: written and read back with the lights off at night). |
| $C7D4-$C7FF | **residue** | `residueC7D4` | residue | Junk bytes. |
| $C800-$CBFF | buffer | `userModeLibrary` | modes | User mode library: 15 x 65-byte records (modes 10-24), filled by $AB88 (every byte of record n = n). |
| $CC00-$CC15 | table | `soundStateTableRegion` | sound | 11 effect handler words indexed by $0E59. |
| $CC16-$CE83 | code | `soundDriver` | sound | SID effect state machine $CC16 and effect routines $CC46-$CE37 (block $29). |
| $CE84-$CFB3 | code | `gaugeDrivers` | panel | Altimeter and MSL altitude $CE84, airspeed target $CF0E, VSI target $CF46, slip ball $CF79. |
| $CFB4-$CFFF | free | `freeCFB4` | - | All zero. |
| $D000-$E4FF | buffer | `editorCache` | overlayManager | RAM under I/O: $E6D8/$E6DB swap $A7E0-$BCDF with $D000-$E4FF ($01=$30) to cache the editor overlay; the course plotter also records display lists from $D000 (and sets $08BC=2 to invalidate the cache). |
| $E500-$E558 | code | `engineSound` | sound | Engine drone pitch slew $E500 (10 Hz). |
| $E559-$E564 | table | `overlayTableRegion` | overlayManager | Overlay (first block, count) pairs. |
| $E565-$E56E | code | `sceneryRootPointer` | sceneryVM | Sets the display-list PC $8B/$8C from the word at $A7E0 (the loaded overlay's end address = scenery root). |
| $E56F-$E58C | **protection** | `tamperHang` | protection | Part of the drive-status check (copy protection). |
| $E58D-$E58E | code | `rootPointerExit` | sceneryVM | The return of $E565 and the interrupt return used as a disabled-NMI target. |
| $E58F-$E617 | code | `blockCacheAndOverlays` | overlayManager | Block cache/streaming $E58F (slot semantics must be kept), the overlay trampolines $E5C0-$E5ED and the overlay manager body $E5F6 (falls into $E618). |
| $E618-$E6D7 | code | `loaderGlue` | streaming | Disk glue: the root-block load $E618, the synchronous read $E63C (sprites off, $D018/$D016 forced, border counter, interrupts masked), the retry path $E6A6 and fatal error $E6C4 (unreachable with the imported image, not ported), the close helper $E6D2. |
| $E6D8-$E712 | code | `editorCacheSwap` | overlayManager | $E6D8 copies, $E6DB exchanges $A7E0-$BCDF with the cache $D000-$E4FF ($01 = $30). |
| $E713-$E7F1 | code | `windAndAtisJump` | wind | $E713 (on to the ATIS teletype $F239), wind drift $E716, wind layer select $E766. |
| $E7F2-$E7FD | data | `adfState` | radios | ADF state: face pending $E7F2, found flag $E7F3, frequency $E7F4/$E7F5, needle angle $E7F6, frequency record $E7F7 (154, 115) with the tunable digits $E7FA-$E7FC. |
| $E7FE-$E885 | code | `adfDme` | radios | ADF needle update $E7FE and the ADF bearing readout $E860 (the DME is $3A13/$3DA2). |
| $E886-$E935 | text | `adfPanelRecords` | radios | Text records of the ADF face drawn over the NAV2 OBI by $E936 (the record list $E886, then the bearing record $E930 (165, 95)). |
| $E936-$EA5B | code | `adfAndTuning` | radios | ADF face $E936, NDB op-05 hook $E956, ADF digit select $E9A7, ',' and '.' pre-handlers $E9BF/$E9F6 (ADF digits, mixture), digit store $EA2B, ADF search renewal $EA50. |
| $EA5C-$EA6B | table | `failureHandlerTableRegion` | failures | Eight failure handler words ($EB39-$EB5F). |
| $EA6C-$EA83 | text | `aircraftProblemRecord` | failures | Text record (y=50, x=20) 'AIRCRAFT PROBLEM !!!!'. |
| $EA84-$EB62 | code | `failuresCode` | failures | Reality-mode failures and drift $EA84-$EB1B, trim creep $EAE2, failure handlers $EB39-$EB62. |
| $EB63-$EB81 | text | `slewTextRecords` | flightModel | Slew readout records (y=2, x=20) ' 00000 NORTH ' and (y=2, x=82) ' 00000 EAST '. |
| $EB82-$EBD1 | code | `slewReadoutAndLights` | panel | Slew NORTH/EAST readout $EB82, instrument lighting masks $EBA5. |
| $EBD2-$EBF1 | table | `todThresholdsRegion` | display | Time-of-day thresholds: 4 seasons x 4 x (minute, hour). |
| $EBF2-$EC98 | code | `timeOfDayPalette` | display | Time-of-day selection $EBF2, palette apply $EC41 (window border $22B5, season bit $0884), window color fill $EC7C. |
| $EC99-$ECE0 | table | `airframeSilhouetteRegion` | display | Per-view white trapezoid (wing/airframe) descriptors: 8 bytes per entry at index $0ACA x 4 (width - 1, width fraction step, width step, start row, x, x fraction step, x step, rows); the front (0) and down ($40) entries have width 0. |
| $ECE1-$ED3B | table | `viewOverlayPixelLists` | display | OR pixel lists of (offset lo, offset hi relative to the $0200 row base, mask) ending 00 00: war bombsight $ECE1, radar aircraft symbol $ED1F. |
| $ED3C-$ED7D | code | `viewOverlays` | display | $ED3C pixel-list overlays (bombsight, radar symbol) and the airframe dispatch. |
| $ED7E-$ED87 | data | `airframeWalkState` | display | The airframe trapezoid walk state of $ED88 (x and width in 8.8, their steps, row, rows left). |
| $ED88-$EE13 | code | `airframeCode` | display | $ED88 per-view airframe trapezoid. |
| $EE14-$EE16 | data | `engineSwitchState` | engine | Magneto state $EE14/$EE15 and the carb-heat countdown $EE16. |
| $EE17-$EE56 | table | `engineTables` | engine | RPM/50 target by throttle ($EE17) and windmilling RPM/50 by airspeed ($EE37), 32 bytes each. |
| $EE57-$EE6A | text | `magnetoLabels` | panel | Five 4-byte text records for the magneto label O/L/R/B/S. |
| $EE6B-$F079 | code | `engineModelCode` | engine | Engine, thrust, oil and fuel model $EE6B. |
| $F07A-$F086 | table | `atisTokenOffsetRegion` | atis | Offsets into $F087 for ATIS tokens $80-$8C. |
| $F087-$F169 | text | `atisPhrases` | atis | ATIS phrase strings that $F16A fills with live values and $F239 types out. |
| $F16A-$F2E5 | code | `atisCode` | atis | ATIS value composer $F16A (with the digit helpers $F221/$F223 and their 3-byte field $F21E), the teletype $F239-$F2E5 and the busy delay $F25B. |
| $F2E6-$F35D | table | `failureGraphics` | panel | Instrument area tables of $FD/$FE/$FF ($F2E6/$F316/$F346): per mask bit 6 bytes [x low][rows << 1 \| x bit 8][first row][width][save buffer word]. |
| $F35E-$F3E5 | code | `instrumentMaskCode` | panel | Instrument enable masks $F35E and the per-bit loop $F3B3. |
| $F3E6-$F3EF | data | `instrumentMaskScratch` | panel | Ten bytes of variables inside the $F35E module: the new state of the mask bit being drawn ($F3E6 areaNewBit), the area walk ($F3E7-$F3EE) and the save-buffer bit counter ($F3EF savedBitCounter, used by $F4E0/$F502). |
| $F3F0-$F4BC | code | `instrumentMaskCode2` | panel | toggleInstrumentArea $F3F0 (save and clear, or XOR back, an instrument's panel area) and its per-pixel helpers $F493 (read and clear) / $F4A9 (XOR in). |
| $F4BD-$F4C4 | table | `bitMaskTableF4BD` | panel | MSB-first bit masks 80..01 used by $F4C5. |
| $F4C5-$F521 | code | `instrumentMaskCode3` | panel | Bitmap bit address $F4C5, save-buffer push $F4E0 and pop $F502. |
| $F522-$F626 | text | `plotterMenuText` | coursePlotter | COURSE PLOTTER SYSTEM menu text records. |
| $F627-$F7DA | code | `coursePlotterCode` | coursePlotter | Menu $F627 and its keys $F649-$F6DF, the recorder/display $F6E2-$F7AF, bank switches $F7B0/$F7B4, delta scaling $F7BB. |
| $F7DB-$F86E | table | `tenKMarkerData` | panel | Altimeter 10,000-ft marker: state byte $F7DB, 9 shape pointers $F7DC, 9 XOR point-list shapes $F7EE-$F86E. |
| $F86F-$F8AE | code | `tenKMarkerDriver` | panel | 10,000-ft marker driver $F86F (phase 1, when $FD bit 3 is set). |
| $F8AF-$F943 | code | `groundElevationCode` | flightModel | Ground elevation tracking $F8AF, maneuver-regime timer $F916. |
| $F944-$F95C | text | `crashTexts` | modes | 'CRASH !!!' and 'SPLASH !!!' records. |
| $F95D-$F9F8 | code | `crashAndAltitude` | modes | Crash/splash message $F95D/$F974, splash detect $F996, altitude set $F9C1. |
| $F9F9-$FF7F | free | `freeF9F9` | - | All zero, including $FD00, the target of the war-mode hook JSR $FD00 ($20C0, after R). |
| $FF80-$FFDF | buffer | `instrumentSaveHigh` | panel | Instrument save buffers of the failure-graphics records at $F33A ($FF80), $F340 ($FFC0), $F346 ($FFC1) and $F352 ($FFCF). |
| $FFE0-$FFF0 | free | `freeFFE0` | - | All zero; part of the BRK chain of the war-mode $FD00 hook. |
| $FFF1-$FFF9 | **residue** | `residueFFF1` | residue | Stray non-zero bytes below the vectors. |
| $FFFA-$FFFF | table | `hardwareVectors` | scheduler | NMI/RESET/IRQ vectors. |

### Overlay 0: cold start (stage 3, blocks 2-4)

| Range | Kind | Name | Subsystem | Notes |
|---|---|---|---|---|
| $A7E0-$A7E1 | data | `overlayEndWord` | overlayManager | Overlay end address ($AD00): where the root block lands during init. |
| $A7E2-$A7FF | code | `overlaySlots` | overlayManager | Entry slots $A7E2/$A7E8/$A7EE/$A7F4/$A7FA (6 bytes each): each enters the owner's code or calls the trampoline that loads the owning overlay. |
| $A800-$A80B | table | `bootLoadTableRegion` | init | Boot load list: (first block, count) pairs ending with 0; $A80B unidentified. |
| $A80C-$A838 | text | `titleRecords` | modes | Title records: (12,13) 'SUBLOGIC FLIGHT SIMULATOR II', (20,45) 'VERSION 1.0'. |
| $A839-$A85A | **crack** | `titleCrackRecord1` | crack | A title record (y=28, x=8, 31 characters) whose original text is not on the disk; modified copies carry other text here. |
| $A85B-$A87D | **crack** | `titleCrackRecord2` | crack | A title record (y=36, x=7, 32 characters) like titleCrackRecord1; the import blanks its text bytes $A85D-$A87C. |
| $A87E-$A8F3 | text | `displayPromptRecords` | modes | 'WHAT DISPLAY ARE YOU USING?', 'A. COLOR TV OR COMPOSITE MONITOR', 'B. BLACK AND WHITE TV OR MONITOR', '(TYPE A OR B)', list end; spare 0 at $A8F3. |
| $A8F4-$A945 | text | `modePromptRecords` | modes | 'SELECT OPERATING MODE', 'A. DEMO MODE', 'B. REGULAR FLIGHT MODE', '(TYPE A OR B)'. |
| $A946-$AAF6 | code | `coldInit` | init | Cold init chain from $A946 (boot loads $A988, title $AA1C, mode prompt $AA71). |
| $AAF7-$AAF9 | **protection** | `protectionStubs` | protection | Two stubs in the init chain (probably copy protection). |
| $AAFA-$ABBA | code | `coldInit2` | init | Interrupt setup and TOD calibration $AAFA, SID init $AB58, panel row copy $AB66, IRQ masking $AB78, user library init $AB88, zero-page copy $ABB0. |
| $ABBB-$ABFF | **residue** | `stage3TailResidue` | residue | Build residue: editor overlay text bytes left in the stage-3 image. |
| $AC00-$ACFF | data | `zeroPageImage` | core | Zero-page initial image: $AC02-$ACFF is copied to $02-$FF by $ABB0. |
| $AD00-$B3DF | **residue** | `editorDuplicateResidue` | residue | Build residue: 1759 of 1760 bytes equal the editor overlay at the same addresses. |

### Overlay 1: editor (blocks 42-47)

| Range | Kind | Name | Subsystem | Notes |
|---|---|---|---|---|
| $A7E0-$A7E1 | data | `overlayEndWord` | overlayManager | End address $BC6B (the root block is loaded there after the overlay). |
| $A7E2-$A7FF | code | `overlaySlots` | overlayManager | Entry slots; slot 1 ($A7E8) enters the editor at $B09A. |
| $A800-$A803 | table | `editorPagePointerRegion` | editor | Pointers to the two page images ($A804, $ABEC). |
| $A804-$ABEB | text | `editorPage0` | editor | 40x25 screen-code page 0: SIMULATION CONTROL and AIRCRAFT POSITION; rows 23-24 are a rule of $40 and 'CM-FS2  FIX MODE ... HIT E TO EXIT'. |
| $ABEC-$AFD3 | text | `editorPage1` | editor | 40x25 screen-code page 1: ENVIRONMENTAL CONTROL. |
| $AFD4-$B005 | table | `screenLineTableRegion` | editor | 25 screen-line addresses in $0400-$07FF. |
| $B006-$B01B | table | `powersOfTenRegion` | editor | 24-bit powers of ten 1..100000 as three 6-byte planes (lo/mid/hi) for decimal conversion, then 4 zero bytes. |
| $B01C-$B01F | table | `fieldTablePointerRegion` | editor | Pointers to the field descriptor lists of page 0 ($B020) and page 1 ($B05A). |
| $B020-$B059 | table | `page0FieldsRegion` | editor | 19 field descriptors [size 1/2][screen line*2][offset into $0964] and a 0 terminator. |
| $B05A-$B099 | table | `page1FieldsRegion` | editor | 21 field descriptors and a 0 terminator. |
| $B09A-$B9E0 | code | `editorCode` | editor | Editor: entry $B09A and the field loop $B0C5, cursor and pages $B0FD-$B178/$B803, keys and digits $B179-$B288, library disk $B1F1-$B240/$B289, decimal conversion $B29B/$B2D6, page copy $B346, field walks $B371/$B3C0/$B7D2/$B813, conversions $B3F6/$B559/$B865, save and recall $B7A5/$B7C3, mode records $B98D/$B998. |
| $B9E1-$BC6A | table | `builtInModesRegion` | modes | Built-in modes 0-9: 10 x 65-byte mode records (read-only). |

### Overlay 2: war (blocks 158-160)

| Range | Kind | Name | Subsystem | Notes |
|---|---|---|---|---|
| $A7E0-$A7E1 | data | `overlayEndWord` | overlayManager | End address $B1EA. |
| $A7E2-$A7FF | code | `overlaySlots` | overlayManager | Entry slots; slot 2 ($A7EE) enters warMain at $AA03; $A7F4/$A7F7 return at once. |
| $A800-$A83A | data | `warVariables` | war | War overlay state: record offset $A800, loop index $A801, deltas $A802-$A80A, range $A80B-$A80D, scope rotation $A80E-$A815, status flags $A816-$A81B, the two enemy bases $A81C/$A828, tracer state $A834-$A837, shape and screen position $A838-$A83A. |
| $A83B-$A872 | text | `warStatusRecords` | war | Status line records at (114,117): 'WAR !!!!', 'IN RANGE', 'ENEMYFIRE', blank (14 bytes each). |
| $A873-$A88E | text | `warCounterRecords` | war | Rotating line records at (171,117): 'AMMO :000' $A873 and 'HITS :000' $A881. |
| $A88F-$A896 | table | `warRotationRegion` | war | Four record pointers the status line rotates through every 4 war passes (main-loop passes, not frames): AMMO $A873, SCORE $08ED, BOMBS $08DF, HITS $A881. |
| $A897-$A8A6 | data | `enemyDotListRegion` | war | The enemy dot display list run through $8006 by enemyUpdate: op 24 (origin, scale 4, high words 0), op 00 (dot; the point at $A8A0-$A8A5 is rewritten per enemy), END $79. |
| $A8A7-$A8BE | table | `gunsightLinesRegion` | war | Gunsight: 6 lines x (y1, x1, y2, x2), loaded into $EC, $EB, $EE, $ED; drawn by warMain in the front view outside the radar. |
| $A8BF-$A914 | data | `tracerRegion` | war | 14 tracer records of 6 bytes (start age, age, target x, x, target y, y), then the age byte $FF at $A914 ending the list (the byte before it is unused). |
| $A915-$A95A | table | `enemyShapesRegion` | war | The enemy shapes: 5 offsets into $A91A, then per shape a line count and (dx1, dy1, dx2, dy2) per line relative to the enemy's screen position. |
| $A95B-$AA02 | data | `enemyRecordsRegion` | war | Six 28-byte enemy records. |
| $AA03-$B1E9 | code | `warCode` | war | The Europe 1917 game, all code (no embedded data): main $AA03, enemies $AA84-$AE43, service check $AE44, status $AE77, guns $AEED, bombs $AFB9, score/ammo $AFEE-$B04B, range $B04C, deltas $B0A3, scope $B0FC, first pass $B13E, damage $B19E. |

### Overlay 3: flight (block 65) + root block 66 at $A800

| Range | Kind | Name | Subsystem | Notes |
|---|---|---|---|---|
| $A7E0-$A7E1 | data | `overlayEndWord` | overlayManager | End address $A800: the scenery root list (block 66) is loaded there. |
| $A7E2-$A7FF | code | `overlaySlots` | overlayManager | Entry slots; $A7F4/$A7F7 return at once (the flight overlay is resident). |
| $A800-$A887 | data | `sceneryRootList` | sceneryVM | Block 66 (loaded at $A800): 9 x ['13 rel R=500 Z X' box test, '0D blk cnt rel slot0' load to root+$87], END at $A887. |
| $A888-$ABFF | **residue** | `rootBlockResidue` | residue | Dead tail of block 66 (New England VOR/op-1D records). |

### Overlay 4: database info (block 64)

| Range | Kind | Name | Subsystem | Notes |
|---|---|---|---|---|
| $A7E0-$A7E1 | data | `overlayEndWord` | overlayManager | End address $A878. |
| $A7E2-$A7FF | code | `overlaySlots` | overlayManager | Entry slots; slot 4 ($A7FA) enters the database info screen at $A86A. |
| $A800-$A869 | text | `databaseInfoRecords` | modes | Two lead bytes then records 'CURRENT DATABASES ARE:', 'CHICAGO', 'LOS ANGELES', 'SEATTLE', 'NEW YORK', 'PRESS ANY KEY TO CONTINUE ...', list end. |
| $A86A-$A877 | code | `databaseInfoCode` | modes | Clear window, draw the record list, wait for a key, return. |
<!-- generated:regions:end -->
