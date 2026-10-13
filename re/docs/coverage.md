# Execution coverage of the original

Scripted lab sessions exercise every feature of Flight Simulator II. Each one records which code
the feature runs. This page maps features to code, lists the code that no session reaches, and
says which data the sessions read. `features.md` records what the sessions verified about the
behavior.

All numbers come from the sessions in `re/sessions/` run on the v1.0 disk, with the region
refinements this work made (once the fragment `symbols.d/coverage.json`, now folded into
`re/symbols.json`). The routine names below are the current ones.

## Reproducing

```sh
swift build -c release --product fs2lab
D64="$FS2_D64"   # the path of your own copy of the disk
# one session: screenshots, peeks, and the overlay-aware coverage file out/sessions/<name>/<name>.cov
.build/release/fs2lab run "$D64" out/sessions/<name> @re/sessions/<name>.txt
# the merged, overlay-blind map over all sessions
for s in re/sessions/*.txt; do .build/release/fs2lab coverage "$D64" out/coverage/all.bin @$s; done
```

Both `out/` and `build/` are git-ignored.

### Session steps added for this work

These live in `Sources/FS2LabKit/Session.swift`. The existing steps are unchanged.

| Step | Meaning |
|---|---|
| `down:KEYS` / `up:KEYS` | Press or release keys without running frames. Used for CTRL first, RUN/STOP held, and the like. |
| `nmi` | RESTORE |
| `peek:ADDR[:COUNT]` | Print frame, PC, SP and RAM bytes |
| `until:ADDR:VAL[:MAX]` | Run until a RAM byte equals `VAL`. `!VAL` means until it differs. |
| `text` | Print the 40×25 text screen. The lab has no character ROM, so editor screenshots show garbage, but the screen codes decode. |
| `cov:on` / `cov:off` / `cov:save:NAME` | Overlay-aware coverage recording, written as `NAME.cov`. `on` starts a fresh recording and `off` discards it, so save first. Ignored by `fs2lab coverage`, which keeps its own map. |
| `watch:LO:HI` | Print each instruction that reads or writes the range. The bus has one access map, so `watch:` and coverage recording (`cov:on` or `fs2lab coverage`) refuse to run together. |

Key names `PLUS` and `COLON` were added, because `+` and `:` are part of the step syntax.

### Overlay-aware maps

`fs2lab coverage` keeps one flag byte per address. The window $A7E0-$BFFF is shared by five
overlays, so that map cannot tell, for example, the editor's $B09A from the war overlay's.

The `cov:` recorder keeps six 64 KB planes instead:

- 0 cold start
- 1 editor
- 2 war
- 3 flight
- 4 database info
- 5 mid-load

The recorder charges every instruction start, read and write to the plane of the overlay that is
resident at that moment. It identifies the overlay by the end word at $A7E0: $AD00, $BC6B, $B1EA,
$A800 or $A878. The flags are 1 read, 2 written and 4 instruction start. A session's recording
covers only the part after `cov:on`.

### Analysis

The tables below were produced by a throwaway script (not committed). It applied these rules:

1. **Baseline.** A feature's code is the set of instruction starts in its session map that are in
   neither `boot` nor `idle` (`re/sessions/idle.txt`):
   - `boot` is the regular start until Meigs is loaded.
   - `idle` is one minute parked at Meigs.
2. **Routine attribution.** Each instruction start belongs to the nearest routine entry at or below
   it in the same overlay, taken from `symbols.json`.
   - Entries `$A7E2-$A7FF` are the resident slot routines.
   - Code that follows an embedded table is marked `(cont.)`.
   - Starts in non-code regions are grouped by region.
3. **Byte coverage.** An instruction start covers the bytes of its instruction. The lengths come
   from images taken with each overlay resident.

The report command proposed for the lab is listed at the end.

## Sessions

Every flight session starts from the `regular.txt` prefix, then waits for the Chicago area and the
Meigs detail block (`until:0901:4E:3000 pc:204B:3000 wait:60`). The exceptions are `demo-loop` and
`demo-key`, which use the demo prefix, and `bw`, which answers B at the display prompt. All sessions run in
under 15 s in the lab except `demo-loop`, which takes 45 s.

| Session | Frames | Exercises |
|---|---|---|
| `idle` | 8595 | Baselines `boot` and `idle` |
| `takeoff` | 8003 | `;` with auto-repeat, the `/` prefix, B rotate, V/R trim, H/G, climb |
| `views` | 6399 | `5` + T/Y/H/N/B/V/F/R/G |
| `radar` | 6253 | `4`, `,` and `.` zoom, `5` back |
| `pause` | 6639 | P and RUN/STOP pause; the key that ends it is swallowed |
| `switches` | 7459 | L, N/Y flaps, RETURN + 1-5 magnetos, mixture, CTRL+I, CTRL+F fuel tank, CTRL+B, CTRL+D, C/M, F/H/G, `;`/COLON/DEL |
| `radios` | 9552 | CTRL+C COM, CTRL+N NAV1/2, CTRL+V OBS1/2, CTRL+T/CTRL+X transponder, LSHIFT, editor ADF ENABLE, A + `,`/`.` ADF, NDB 332 reception, wraps |
| `atis` | 7399 | COM 121.30, Meigs ATIS teletype |
| `ils` | 19742 | Editor placement, NAV1 109.10 / OBS 314, Champaign localizer, outer and middle markers |
| `editor` | 9333 | E, paging both pages, typing with DEL, exit; S save, `+` recall, USER MODE 0 |
| `library` | 7397 | Editor S / `+` / USER MODE 111 / CTRL+X library load / CTRL+Z format and save |
| `database` | 6736 | CTRL+E |
| `plotter` | 11717 | Q, A record, C precision, B display in front/rear/radar, D off |
| `slew` | 11230 | Editor SLEW = 1, all slew keys, CTRL+T copy-back, slew off |
| `night` | 10490 | Editor HOURS 22, lights off and on at night, radar at night, night takeoff |
| `bw` | 11009 | B&W display; HOURS 19/20/6/5, dusk and night palettes |
| `clouds` | 12622 | Editor airborne start, cloud layer, wind levels; climbing through the layer |
| `failures` | 19440 | Editor REALITY 1 / RELIABILITY 0, engine start, four failures |
| `stall` | 7135 | Stall horn and lamp, stall, crash |
| `crash` | 9115 | Dive into the ground, CRASH message, mode reload |
| `splash` | 15574 | Taxi into Lake Michigan; glide onto the lake from an editor placement |
| `war` | 12495 | EUROPE 1917, W, takeoff, enemy placed by poke, IN RANGE kill, ENEMYFIRE hits and damage, X bomb, bombsight |
| `war-hook` | 7783 | R in war mode: the $FD00 hook |
| `joystick` | 5799 | Port 1 and port 2 directions and fire; keyboard suspension |
| `demo-loop` | 106018 | Demo mode 2 flight, crash after ~28 min, reload (the final key finds $095A already 0) |
| `demo-key` | 7262 | A key during the first demo flight clears the demo flag $095A |
| `restart` | 10781 | RESTORE alone, RESTORE with L, RUN/STOP + RESTORE restart to the title |
| `regular`, `demo` | 4511, 7811 | The original prefixes, used only by `fs2lab coverage` |

## Totals

The merged overlay-blind map (`fs2lab coverage` over all 29 session files) has **13,831
instruction starts**.

These are the executed bytes of the regions of kind `code`, counted over the union of the
overlay-aware maps:

| Overlay | Executed / code bytes | Share |
|---|---|---|
| Resident | 22,954 / 24,078 | 95.3% |
| Cold start | 620 / 656 | 94.5% |
| Editor | 2,360 / 2,405 | 98.1% |
| War | 1,772 / 2,053 | 86.3% |
| Flight (slots only) | 14 / 30 | 46.7% |
| Database info | 20 / 44 | 45.5% |
| **All** | **27,740 / 29,266** | **94.8%** |

Notes on the low totals:

- The flight and database-info overlays contain little more than their 30-byte slot tables. The
  slot that loads the current overlay is never used, because that overlay is already loaded.
- The regions of kind `loader`, `protection` and `residue` are left out of the totals, because the
  port does not reproduce them.

## Per feature: the code each feature adds

"New" means not executed by the boot or idle baselines. The table names each feature's specific
routines: new routines that at most three other sessions also add. The full per-session lists,
with every routine and its number of new instruction starts, are in the appendix.

| Feature (session) | Specific routines (resident unless prefixed) |
|---|---|
| Takeoff | `throttleJump` $2C4F, `keyTrimUp` $2C87, `keyTrimDown` $2C9A, `drawTrimIndicator` $1C10, `densityAndAutoLevel` $35BD. Also adds the airborne paths of `aeroUpdate` $2F45, `integrateFlight` $32EE, `groundContact` $3515, `windDrift` $E716 and `engineModel` $EE6B |
| Views | `keyViewSelect` $2C70, `captureViewKey` $2E84, `drawAirframe` $ED88, `buildViewMatrix` $8111 (other yaw offsets) |
| Radar | `keyRadar` $2C5A, `opOriginHigh` $8BC1, `opOrigin` $8BFD, `drawViewOverlay` $ED3C (aircraft symbol), `tuneDecrementPre`/`tuneIncrementPre` $E9BF/$E9F6, `decrementSelected`/`incrementSelected` |
| Pause | No new routine: `waitForKey` $2250 is already in the boot baseline (the title prompts) |
| Switches | `key1` $2807, `key2` $283D, `key3` $285F, `setMagnetos` $2829, `drawMagnetoLabel` $3A71, `keyReturn` $2BC4, `keyLights` $2B6E, `keyCarbHeat` $2B63, `keyFuelTankSelect` $2C55, `drawFuelSelectorMarker` $1CF0, `drawMixtureIndicator` $1C23, `drawFlapsIndicator` $1BFD, `keyCtrlB` $2B28, `keyCtrlD` $2B37, `keyRudderLeft` $2E22 |
| Radios | `keyComSelect` $2B8C, `keyNavSelect` $2BAC, `keyObsSelect` $2BA7, `keyTransponderSelect` $2B0D, `keyCtrlT` $2ADF, `keyAdfSelect` $2B25, `selectAdfDigit` $E9A7, `storeSelected` $2BBC, `drawToFrom` $3C81, `drawLocalizer` $3D71, `updateAdf` $E7FE, `drawAdfBearing` $E860, `drawAdfPanel` $E936, `ndbHook` $E956 (op 05 match) |
| ATIS | `opAtisRecord` $8084, `atisHook` $802D, `composeAtis` $F16A, `atisTeletype` $F239, `busyDelay` $F25B |
| ILS | `opNavRecord` $8030, `updateNav1Cdi` $3B32, `drawDme` $3A13, `stationDistance` $3F38 (marker lamps and sounds), `opRunway` $A5C8, `trackGroundElevation` $F8AF |
| Editor | editor: `editorEntry` $B09A, `cursorNextLine` $B0FD, `cursorPreviousLine` $B136, `fieldInput` $B198, `fieldKeyEntry` $B241, `parseFieldValue` $B29B, `printFieldValue` $B2D6, `copyEditorPage` $B346, `stateToRecord` $B3F6, `recordToState` $B559, `saveUserMode` $B7A5, `recallKey` $B7C3, `windToDisplay` $B865, `storeModeRecord` $B98D, `loadModeRecord` $B998. Resident: `keyEditor` $2801, `keyRecallMode` $2BDF, `keySaveMode` $2BE5, `editorExitHook` $0ACF, `textModeIrqSwap` $2673, `setTextMode` $796C, `swapEditorCache` $E6DB, `loadOverlayEditor` $E5C9 |
| Mode library | editor: `libraryLoad` $B1F1, `librarySave` $B223, `setLibraryBlock` $B289. Resident: the loader's command and write paths `loaderDosCommand` $7312 and `loaderWriteBlock` $730C (loader code: the port reproduces their memory effects, `editor.md`) |
| Database info | `keyDatabaseInfo` $2F40, `loadOverlayDatabaseInfo` $E5ED, `vecLoadDatabaseInfo` $2021; databaseInfo: `databaseInfoScreen` $A86A |
| Course plotter | `keyCoursePlotter` $2BE9, `coursePlotterMenu` $F627, `plotterRecord` $F649, `plotterDisplay` $F6E2, `bankOutIo` $F7B0, `bankInIo` $F7B4 |
| Slew | `slewIntegrate` $3660, `slewRateStep` $3746, `slewAux` $372B, `drawSlewReadout` $EB82, `printSigned5` $1D54, `key8` $2865, `key9` $2869, `keyZeroAttitude` $2BEF, `keyCtrlT` $2ADF (slew branch) |
| Night and B&W | `selectTimeOfDay` $EBF2, `applyPalette` $EC41, `updateLightingMasks` $EBA5, `dottedPlot` $9B80, `opDottedPen` $9B9B, `updateInstrumentMasks` $F35E, `toggleInstrumentArea` $F3F0, `bitmapBitAddress` $F4C5, `pushSavedBit`/`popSavedBit` $F4E0/$F502; coldStart: `titleScreen` $AA1C (the B branch) |
| Clouds and wind | `altimeterUpdate` $CE84 (high altitudes), `setAltitudeFromEditor` $F9C1, `windLayer` $E766 (layers), sky/ground fill variants in `horizonPass` $83A4 |
| Failures | `realityFailures` $EA84, `trimCreep` $EAE2, `failureHandler1/3/5/7` $EB42/$EB4F/$EB57/$EB5F, `updateInstrumentMasks` $F35E, `toggleInstrumentArea` $F3F0, `vecSetMagnetos` $2009, `draw10kMarker` $F86F |
| Stall | `sfxStallHorn` $CC46 (and the stall branch of `aeroUpdate`) |
| Crash | `crashMessage` $F95D, `sfxCrash` $CC68, crash test in `groundContact` $3515 |
| Splash | `splashDetect` $F996 (three-check path), `crashMessage` $F95D, `sfxTouchdown` $CDAF |
| War | `keyDeclareWar` $2AD5, `fireGuns` $2C03, `keyDropBomb` $2B79, `sfxGun` $CCD1, `sfxBombRelease` $CD04, `sfxBombWait` $CE37, `radioGate` $3A53, `loadOverlayWar` $E5DB, `rvLine`/`rvPlot`/`rvSetPen` $8009/$800C/$800F (gunsight and tracers); war: `warMain` $AA03, `enemyUpdate` $AA84, `printHitsTaken` $AE63, `warStatusLines` $AE77, `gunsAndTracers` $AEED, `warFirstPass` $B13E, `warDamage` $B19E |
| War $FD00 hook | 320 BRKs in `freeF9F9`, 48 in `instrumentSaveHigh` and 9 in `freeFFE0`, then `residueFFF1` (the bytes at $FFF2 act as a call of $20D5) |
| Joysticks | `sampleCia1` $2574 (joystick latch path), `keyScan` $2418, `joystickAction` $2688, `autoCenter` $26EC |
| Demo | coldStart: `modePromptScreen` $AA71 (the A branch); editor: mode 2 load ($08BB = 3 path in `editorEntry`); `crashMessage` after the long flight |
| Restart | `restoreNmi` $2700, `loadOverlayColdStart` $E5C0, `vecLoadColdStart` $2015; coldStart: `slotColdInit` $A7E2 and the whole cold init again |

## Code no session executes

### Routines never entered

| Routine | Reason | Next step |
|---|---|---|
| `restoreGraphics` $5F40, `printHexDigit` $5F5D, `diskErrorPrompt` $5FAB (3 of 70 bytes), `systemError` $791E | Disk-error and system-error screens. The lab's virtual 1541 never fails. | Add error injection to `IECDrive` (a bad block or a missing drive). |
| `loaderFatal` $7303, `stage2BootEntry` $78A2, `loaderNmi` $790A, `driveStatusCheck` $7848 | Excluded loader and protection. The lab starts at $A7E2, after stage 2. | None (not ported) |
| `vecDequeueKey` $203C | ABI vector with no caller in any session | Check the scenery data and overlays for calls of $203C. |
| `rvA558` $8015 | Renderer vector with no caller in any code (the cold start uses the twin vector $8027) | None: an unused ABI entry; the port maps it for op 0A |
| `dlInvalidOpcode` $8778 (+ $87E1-$8819) | The scenery VM's bad-opcode path; only corrupt data reaches it | Done: the port throws `Scenery.Fault`, and `SceneryVMTests` faults every unused opcode; op 0A ($87E1) is tested with crafted lists |
| `opJumpAbsolute` $A731 | No caller in any code or list (`scenery-3d.md`: an absolute jump usable as an op 0A target) | Done: ported and tested through op 0A (`SceneryVMTests`) |
| `failureHandler0/2/4/6` $EB39/$EB4B/$EB53/$EB5B | The 4 failures in `failures` picked handlers 1, 3, 5 and 7 | Done: `FlightModelTests` run every failure handler against the original |

### Partly executed routines (gaps of 6 bytes or more)

| Gap | Routine | Probable reason / next step |
|---|---|---|
| $1873-$187F | `divQ15` | Overflow or sign case; cover with a routine-diff test |
| $1D6E-$1D80, $1DAF-$1DB7 | `printSigned5` | Negative values (slew readouts south or west of the zero lines) |
| $2378-$237D | `tick10Hz` | Auto-repeat of the second held key (slot 2). Every session holds one key at a time. Next: hold two keys. |
| $23EE-$23FE | `tick10Hz` | Clock hour rollover (minute 59 → next hour; 23 → 0). Next: start at xx:59 and wait a minute. |
| $26F9-$26FE | after `autoCenter` | 6 unreferenced bytes after its final jump (note added) |
| $28DD-$28FE, $29C3-$29CC, $2A3F-$2A47, $2A87-$2A98 | `decrementSelected` / `incrementSelected` | Untried wraps: NAV kHz, transponder `.` wrap, OBS2 `.`, mixture and fuel-tank edges |
| $2DB0-$2DBB | `centerControls` | Over-control limiter: centering during a large roll term stores a roll cancel (note added). Next: G during a fast roll. |
| $2FEE-$2FF5, $32C2-$32DD | `aeroUpdate` | γ past ±90° (loop or vertical flight: reflection and the 180° flips) |
| $341B-$3426 | `integrateFlight` | Applies that roll cancel and sets `$0E79` (skip the next flip). This answered the question of what sets `$0E79` from the code (`open-questions.md`, Display and rendering). Same next step. |
| $3602-$360A | `densityAndAutoLevel` | Auto-level from the other bank direction |
| $3619-$3636 | `serviceCheck` | Refuel/repair/rearm needs `$0838` (a service spot); not visited |
| $36CA-$36E8, $36FC-$371A | `slewIntegrate` | Altitude clamp at 0 and large-rate cases |
| $3D5E-$3D67, $3E4A-$3E80 | `drawToFrom`, `drawLocalizer` | FROM flag; NAV2 localizer |
| $80D1-$80E1 | after `opAtisRecord` | 17-byte helper with no caller in any code or list (copies 4 display-list bytes to $A5-$A8; note added). The port maps it as an op 0A target (`copyOperandBytes`), tested with crafted lists in `SceneryVMTests`. |
| $8497-$84EA (3 gaps) | `horizonPass` (cont.) | Horizon geometry corner cases (line through screen corners) |
| $8CAD-$8CCA, $8EFD-$8F04, $8FA0-$8FE0 | `opOrigin` etc. | Origin and range-op variants not used by the visited areas (LA, Seattle and NY not visited) |
| $A065-$A06C, $A2C1-$A331 | `transformGround`, `transform3D` | 112 bytes of an alternate transform path (probably far or high points); visit other areas or fly high |
| $A731-$A73D | `opJumpAbsolute` | See above |
| $EABB-$EAD2 | `realityFailures` | Altimeter drift adjustment (needs $09CE ≠ $09D0) |
| $EAFA-$EB07 | `trimCreep` | Elevator above the trim |
| $EEF4-$F072 (4 gaps) | `engineModel` | Starter busy-wait on the ground, fuel leaks (`$09BF` bits 2/3), windmill restart |
| $F1EA-$F206 | `composeAtis` | The ceiling phrase (an ATIS with a cloud layer) |
| $F907-$F914 | `trackGroundElevation` | Ground elevation falling (flying from high to low terrain) |
| coldStart $A96A-$A96F | `coldInit` | Boot-load failure → `loaderFatal`; needs a disk error |
| editor $B216-$B222 | `libraryLoad` | Disk-error exit |
| war $AA9B-$ACAF (several) | `enemyUpdate` | Fire-cooldown counter, negative step directions, enemies above or east of the player |
| war $AFC2-$B039 | after `gunsAndTracers` (`$AFB9`/`$AFEE`/`$B01D` helpers) | Bomb impact on a target and its scoring |
| war $B1C0-$B1DC | `warDamage` | Damage thresholds after the first (more than 9 hits) |
| slot tables (all overlays) | `overlaySlots` | Each overlay's own load trampoline is never used while it is resident |

Resolved by a refinement: $ED7E-$ED87 was a never-executed gap inside the old `viewOverlays`
code region: the 10 bytes between `drawViewOverlay`'s return and `drawAirframe`, zero on disk. They
are `drawAirframe`'s walk state, rewritten by every call (`render3d.md`), so the region is split
into `viewOverlays`, `airframeWalkState` (data) and `airframeCode`.

### Executed outside documented code

| Where | What | Status |
|---|---|---|
| `stage2Loader` $7300-$7834, `loaderGlue` $E618-$E6D7 | SubLogic's IEC loader. The lab runs it against its virtual 1541. | Excluded: replaced by the block store |
| coldStart `protectionStubs` $AAF7-$AAF9 | Stubs in the init chain that return at once | Excluded (protection) |
| `tamperHang` $E56F-$E58C | The first check runs every pass and exits via $E58D. Note added at $E56F. | Excluded; the port skips it |
| `freeF9F9`, `instrumentSaveHigh`, `freeFFE0`, `residueFFF1` | The war-mode $FD00 hook's BRK chain and the call of $20D5 that the bytes at $FFF2 form. Notes added at $20C0, $FD00 and $FFF2. | **Decided:** a documented no-op in the port (`excluded.md`). On this disk the hook advances jiffies by ~180 and leaks 4 stack bytes per R (377 BRKs). The chain crosses the instrument save buffer $FF80-$FFDF, so once that holds saved pixels (lights off at night, failures) R executes them as code. |
| $0ACF | A bare-return hook called by the editor exit | Documented: region `editorHookRts`, routine `editorExitHook` |
| $845F-$84FA | Continuation of `horizonPass` after the embedded table | Note added at $845F |

With the refinements, every other executed byte lies in a documented code routine.

## Data regions read

Read flags count CPU accesses only. Consequences:

- The VIC fetches (screen RAM $7C00/$7E30, sprites $7A00, bitmaps) do not show as reads.
- Loads, the editor-cache swap and the cold init read and write whole regions, so loaded overlay
  data shows as fully "written" and the $D000 cache as fully read.

**Read by game code** (selected):

- Every table the renderer, math, panel, sound and input code use: row tables $0200/$02C8,
  projection $9E92/$9F13, cosine $158E (130 of 132 bytes), needle shapes, font, key tables.
- The editor tables: pages, field descriptors, powers of ten, built-in modes.
- The war tables: status and counter records, rotation pointers, gunsight lines.
- `enemyRecordsRegion`: 121 of 168 bytes.
- The scenery root list: 92 of 136 bytes.
- `rootBlockResidue` $A888-$ABFF: 876 bytes. This is where the area blocks stream in, so it is
  live scenery data in flight, not residue.

**Partly read tables** (the unread parts belong to features or values not reached):

| Region | Read | Unread parts |
|---|---|---|
| `keyDispatchTableRegion` | 92 / 192 | The handler words of codes never typed: CTRL letters without handlers, `@`-range codes, and the like |
| `todThresholdsRegion` $EBD2 | 11 / 32 | Season-dependent rows. All sessions use season 4. |
| `tenKMarkerData` $F7DB | 67 / 148 | The marker shapes above ~12,000 ft |
| `tcWingTableRegion` $A4F2 | 32 / 64 | One turn direction's entries |
| `colorMapRegion` $9BD6 | 5 / 16 | Pens of the areas not visited |
| `failureHandlerTableRegion` $EA5C | 8 / 16 | Handlers 0, 2, 4 and 6 |
| `opcodeHandlerTableRegion` $86A4 | 76 / 140 | Scenery opcodes not used in Chicago, Champaign or the WWI area |
| `atisPhrases` $F087 | 160 / 227 | Phrases of the other airports and the ceiling phrase |
| `aeroGainTables` $0E10 | 36 / 60 | High-speed entries (above ~$60 V_hi) |
| `engineTables` $EE17 | 45 / 64 | Windmill entries at high speeds |
| `tracerRegion`, `enemyShapesRegion` $A8BF-$A95A | 119 / 156 | Tracer slots not reached |

**Never read** (besides `free` space):

- The disk-error text ($0E8E-$0EB5 including the cracker's tags, $5F77-$5FAA) and `systemErrorText`
  $790B: error paths.
- `bitmapBPanelRowCopy` $7180-$72BF
- `linkerExportTable`, `stage3TailResidue`, `editorDuplicateResidue`, `residueC7D4`: residue
- `driveStatusCheck` and `stage2Boot`: excluded

**Runtime use of space marked residue or free** (refined in `re/symbols.json`):

- $C000-$C7D3, the "debug monitor", and $FF80-$FFDE, "free", are written and read back as the
  instrument-mask save buffers.
  - Seen in `night` (lights off) and `failures`.
  - The failure-graphics records at $F2E6 point every instrument's buffer there.
  - The pointer is kept in $BC/$BD (`sharedPointerBC`; the engine model's `windmillRpm` is its
    low byte).

## Requested lab additions (shared files, not changed here)

- `fs2lab coverage-report <dir>`: the analysis above as a lab command reading the `.cov` files and
  the symbol database. It would replace the uncommitted script, so `coverage.md` can be
  regenerated.
- A `--chargen <rom>` option for `run`, so editor screenshots render (`GameData(d64URL:charROMURL:)`
  already supports it).
- Done: `re/sessions/regular.txt` now waits for the initial scenery and stops at the top of the
  main loop, so `Original.regularFlight()` is a settled Meigs state.

<!-- The appendix below is generated from the session maps (one line per overlay). -->

## Appendix: new code per session

Each entry is `routine $entry (new instruction starts)`. `[kind name]` marks starts inside a
region that is not code.

### `takeoff`
- **resident**, 517 new instruction starts: mulQ15 $16C9 (2), asr16 $1881 (8), cos16 $18D0 (37), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawTrimIndicator $1C10 (4), tick10Hz $2348 (3), dispatchKey $27D8 (10), throttleUp $2C1E (9), throttleDown $2C31 (10), throttleJump $2C4F (3), keyTrimUp $2C87 (8), keyTrimDown $2C9A (19), keyIgnored $2CC1 (1), keyElevatorDown $2D2B (14), keyCenter $2D82 (5), centerControls $2D9D (10), keyAileronRight $2DC2 (7), coordinateRudder $2DD2 (30), keyRudderRight $2E2D (16), keyElevatorUp $2E5C (17), captureViewKey $2E84 (4), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (30), integrateFlight $32EE (8), groundContact $3515 (11), densityAndAutoLevel $35BD (2), computeGroundBase $8324 (7), horizonPass $83A4 (9), horizonPass (cont.) $83A4 (2), horizonSplitRow $85C0 (2), horizonBresenham $8623 (7), opEndPolygon $8828 (5), vertexCacheEntry $89E4 (1), opDashedLine $8A43 (4), clipPolygon $8FE8 (2), clipLineEnd $9478 (5), clipPlaneYNeg $953E (1), clipPlaneXNeg $9644 (1), longSpan $9910 (4), span $9996 (9), drawLine $9A1D (1), transformGround $9FD0 (10), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (19), aiSpan $A4CA (4), vsiUpdate $CF46 (4), slipBallUpdate $CF79 (4), windDrift $E716 (34), engineModel $EE6B (12)

### `views`
- **resident**, 248 new instruction starts: cos16 $18D0 (29), drawElevatorIndicator $1B92 (4), tick10Hz $2348 (1), dispatchKey $27D8 (10), keyViewSelect $2C70 (8), keyTrimUp $2C87 (2), keyTrimDown $2C9A (2), keyFlapsUp $2CC2 (2), keyFlapsDown $2D11 (2), keyElevatorDown $2D2B (16), keyAileronLeft $2D6D (2), keyCenter $2D82 (2), keyAileronRight $2DC2 (2), keyElevatorUp $2E5C (15), captureViewKey $2E84 (8), rvSpan $801B (1), buildViewMatrix $8111 (31), computeGroundBase $8324 (7), horizonPass $83A4 (8), clipPolygon $8FE8 (6), clipLineEnd $9478 (5), clipPlaneXNeg $9644 (1), longSpan $9910 (4), span $9996 (8), drawLine $9A1D (1), transformGround $9FD0 (7), renormalizeGround $A1B9 (11), drawViewOverlay $ED3C (4), drawAirframe $ED88 (41), splashDetect $F996 (8)

### `radar`
- **resident**, 234 new instruction starts: mulQ15 $16C9 (2), cos16 $18D0 (29), dispatchKey $27D8 (10), decrementSelected $286D (16), incrementSelected $298E (16), keyRadar $2C5A (8), keyViewSelect $2C70 (6), buildViewMatrix $8111 (28), computeGroundBase $8324 (7), horizonPass $83A4 (8), opOriginHigh $8BC1 (5), opOrigin $8BFD (24), clipPolygon $8FE8 (3), clipLineEnd $9478 (8), clipPlaneYPos $94C0 (1), clipPlaneXNeg $9644 (5), polygonScanLoop $986E (1), longSpan $9910 (3), span $9996 (7), transformGround $9FD0 (3), renormalizeGround $A1B9 (11), tuneDecrementPre $E9BF (6), tuneIncrementPre $E9F6 (5), drawViewOverlay $ED3C (18), splashDetect $F996 (4)

### `pause`
- **resident**, 71 new instruction starts: asr16 $1881 (8), drawThrottleIndicator $1BE1 (4), tick10Hz $2348 (2), dispatchKey $27D8 (10), throttleUp $2C1E (9), throttleDown $2C31 (6), aeroUpdate $2F45 (12), span $9996 (7), slipBallUpdate $CF79 (2), engineModel $EE6B (11)

### `switches`
- **resident**, 477 new instruction starts: mulQ15 $16C9 (2), asr16 $1881 (8), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), drawMixtureIndicator $1C23 (4), drawFuelSelectorMarker $1CF0 (8), tick10Hz $2348 (3), keyPress $24C2 (2), requeueKey $24EB (7), keyReleaseCheck $2505 (8), dispatchKey $27D8 (10), key1 $2807 (7), setMagnetos $2829 (9), key2 $283D (7), key3 $285F (3), decrementSelected $286D (33), incrementSelected $298E (33), keyCtrlB $2B28 (6), keyCtrlD $2B37 (26), keyCarbHeat $2B63 (4), keyLights $2B6E (4), keyReturn $2BC4 (3), throttleUp $2C1E (8), throttleDown $2C31 (14), keyFuelTankSelect $2C55 (3), keyRadar $2C5A (6), keyViewSelect $2C70 (6), keyFlapsUp $2CC2 (33), keyFlapsDown $2D11 (11), keyAileronLeft $2D6D (9), keyCenter $2D82 (5), centerControls $2D9D (10), coordinateRudder $2DD2 (30), keyRudderLeft $2E22 (5), keyRudderRight $2E2D (21), captureViewKey $2E84 (4), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (2), drawMagnetoLabel $3A71 (4), tuneDecrementPre $E9BF (12), tuneIncrementPre $E9F6 (10), engineModel $EE6B (8)

### `radios`
- **resident**, 948 new instruction starts: editorExitHook $0ACF (1), asr16 $1881 (8), neg16 $19D5 (9), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (7), altIrq $2304 (2), tick10Hz $2348 (6), keyPress $24C2 (2), requeueKey $24EB (7), keyReleaseCheck $2505 (8), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), key1 $2807 (14), key2 $283D (14), decrementSelected $286D (106), incrementSelected $298E (99), keyCtrlT $2ADF (2), keyTransponderSelect $2B0D (11), keyAdfSelect $2B25 (1), keyComSelect $2B8C (12), keyObsSelect $2BA7 (3), keyNavSelect $2BAC (8), storeSelected $2BBC (4), keyReturn $2BC4 (3), throttleDown $2C31 (5), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (11), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), serviceAircraft $3638 (16), slewAux $372B (13), drawToFrom $3C81 (80), drawLocalizer $3D71 (73), [loader stage2Loader] $7300 (1), setTextMode $796C (25), loadOverlayEditor $E5C9 (6), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (27), adfDmeUpdate $E7FE (42), printDme $E860 (18), drawAdfPanel $E936 (14), ndbHook $E956 (27), radioSelectHelper $E9A7 (11), tuneDecrementPre $E9BF (20), tuneIncrementPre $E9F6 (37), setAltitudeFromEditor $F9C1 (3)
- **editor**, 854 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (20), cursorNextLine $B0FD (16), cursorPreviousLine $B136 (16), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (18), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (70), windToDisplay $B865 (154)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `atis`
- **resident**, 294 new instruction starts: tick10Hz $2348 (4), keyPress $24C2 (2), requeueKey $24EB (7), keyReleaseCheck $2505 (8), dispatchKey $27D8 (10), decrementSelected $286D (20), incrementSelected $298E (36), keyComSelect $2B8C (12), storeSelected $2BBC (4), atisHook $802D (1), opAtisRecord $8084 (20), tuneDecrementPre $E9BF (6), tuneIncrementPre $E9F6 (5), composeAtis $F16A (75), atisTeletype $F239 (12), busyDelay $F25B (72)

### `editor`
- **resident**, 399 new instruction starts: editorExitHook $0ACF (1), asr16 $1881 (8), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (8), altIrq $2304 (2), tick10Hz $2348 (2), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), keyRecallMode $2BDF (3), keySaveMode $2BE5 (2), throttleUp $2C1E (8), throttleDown $2C31 (6), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (11), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (12), serviceAircraft $3638 (16), slewAux $372B (13), drawDgDigits $377C (1), updateCompass $3823 (2), [loader stage2Loader] $7300 (1), setTextMode $796C (25), vertexCacheEntry $89E4 (1), clipPolygon $8FE8 (2), clipPlaneYNeg $953E (1), drawLine $9A1D (1), transformGround $9FD0 (4), sfxMiddleMarker $CD59 (17), slipBallUpdate $CF79 (2), loadOverlayEditor $E5C9 (7), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (32), windLayer $E766 (5), engineModel $EE6B (11), setAltitudeFromEditor $F9C1 (3)
- **editor**, 954 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (34), cursorNextLine $B0FD (27), cursorPreviousLine $B136 (16), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (34), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (68), stateToRecord $B3F6 (143), recordToState $B559 (220), saveUserMode $B7A5 (10), recallKey $B7C3 (77), windToDisplay $B865 (154), storeModeRecord $B98D (5), loadModeRecord $B998 (28)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `database`
- **resident**, 61 new instruction starts: vecGetKey $2003 (1), vecLoadFlight $201E (1), vecLoadDatabaseInfo $2021 (1), mainLoop $204B (3), tick10Hz $2348 (3), keyPress $24C2 (2), requeueKey $24EB (7), keyReleaseCheck $2505 (8), dispatchKey $27D8 (10), keyDatabaseInfo $2F40 (2), vertexCacheEntry $89E4 (8), transform3D $A1CE (12), loadOverlayDatabaseInfo $E5ED (3)
- **flight**, 1 new instruction starts: slotDatabaseInfo $A7FA (1)
- **databaseInfo**, 8 new instruction starts: slotFlight $A7F4 (1), slotDatabaseInfo $A7FA (1), databaseInfoScreen $A86A (6)

### `plotter`
- **resident**, 916 new instruction starts: mulQ15 $16C9 (2), divQ15 $1802 (2), asr16 $1881 (8), cos16 $18D0 (40), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), mainLoop $204B (1), tick10Hz $2348 (3), dispatchKey $27D8 (10), decrementSelected $286D (16), keyCoursePlotter $2BE9 (3), throttleUp $2C1E (9), throttleDown $2C31 (6), keyRadar $2C5A (8), keyViewSelect $2C70 (8), keyFlapsDown $2D11 (2), keyElevatorDown $2D2B (16), keyCenter $2D82 (5), centerControls $2D9D (10), keyAileronRight $2DC2 (7), coordinateRudder $2DD2 (32), keyRudderRight $2E2D (16), keyElevatorUp $2E5C (17), captureViewKey $2E84 (8), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (33), mulShiftHelper $32DF (1), integrateFlight $32EE (10), groundContact $3515 (11), densityAndAutoLevel $35BD (2), drawDgDigits $377C (1), updateCompass $3823 (2), rvSpan $801B (1), buildViewMatrix $8111 (28), computeGroundBase $8324 (7), horizonPass $83A4 (9), horizonPass (cont.) $83A4 (15), horizonSplitRow $85C0 (2), horizonBresenham $8623 (22), opEndPolygon $8828 (5), vertexCacheEntry $89E4 (1), opDashedLine $8A43 (4), opOriginHigh $8BC1 (5), opOrigin $8BFD (24), clipPolygon $8FE8 (6), clipLineEnd $9478 (8), clipPlaneYNeg $953E (1), clipPlaneXPos $95C6 (1), clipPlaneXNeg $9644 (6), polygonScanLoop $986E (1), longSpan $9910 (4), span $9996 (9), drawLine $9A1D (3), transformGround $9FD0 (10), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (19), aiSpan $A4CA (4), drawTurnCoordinator $A532 (4), vsiUpdate $CF46 (2), slipBallUpdate $CF79 (4), windDrift $E716 (34), tuneDecrementPre $E9BF (6), drawViewOverlay $ED3C (18), drawAirframe $ED88 (41), engineModel $EE6B (11), coursePlotterMenu $F627 (16), plotterRecord $F649 (74), plotterDisplay $F6E2 (94), bankOutIo $F7B0 (2), bankInIo $F7B4 (20), maneuverRegimeTimer $F916 (4)

### `slew`
- **resident**, 950 new instruction starts: editorExitHook $0ACF (1), mulQ15 $16C9 (2), divQ15 $1802 (2), asr16 $1881 (8), cos16 $18D0 (37), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), drawTrimIndicator $1C10 (4), printSigned5 $1D54 (35), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (10), altIrq $2304 (2), tick10Hz $2348 (4), keyPress $24C2 (2), requeueKey $24EB (7), keyReleaseCheck $2505 (8), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), key8 $2865 (2), key9 $2869 (2), keyCtrlT $2ADF (21), keyZeroAttitude $2BEF (10), throttleUp $2C1E (8), throttleDown $2C31 (14), keyTrimUp $2C87 (8), keyTrimDown $2C9A (19), keyIgnored $2CC1 (1), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (26), keyAileronLeft $2D6D (9), keyCenter $2D82 (10), centerControls $2D9D (10), keyAileronRight $2DC2 (7), coordinateRudder $2DD2 (30), keyRudderRight $2E2D (16), keyElevatorUp $2E5C (13), captureViewKey $2E84 (4), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), keyDatabaseInfo $2F40 (1), aeroUpdate $2F45 (26), integrateFlight $32EE (14), groundContact $3515 (11), serviceAircraft $3638 (16), slewIntegrate $3660 (76), slewAux $372B (13), slewRateStep $3746 (29), headingReadout $3773 (1), drawDgDigits $377C (1), [loader stage2Loader] $7300 (1), setTextMode $796C (25), computeGroundBase $8324 (7), horizonPass $83A4 (9), horizonSplitRow $85C0 (2), horizonBresenham $8623 (7), opEndPolygon $8828 (5), vertexCacheEntry $89E4 (1), opDashedLine $8A43 (4), clipPolygon $8FE8 (6), clipLineEnd $9478 (8), clipPlaneYNeg $953E (1), clipPlaneXNeg $9644 (5), longSpan $9910 (4), span $9996 (9), drawLine $9A1D (1), transformGround $9FD0 (7), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (18), aiSpan $A4CA (4), sfxMiddleMarker $CD59 (17), vsiUpdate $CF46 (3), slipBallUpdate $CF79 (2), loadOverlayEditor $E5C9 (7), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (32), windDrift $E716 (34), drawSlewReadout $EB82 (15), engineModel $EE6B (12), maneuverRegimeTimer $F916 (4), splashDetect $F996 (6), setAltitudeFromEditor $F9C1 (3)
- **editor**, 843 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (21), cursorNextLine $B0FD (22), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (16), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (70), windToDisplay $B865 (154)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `night`
- **resident**, 1012 new instruction starts: editorExitHook $0ACF (1), mulQ15 $16C9 (2), divQ15 $1802 (2), asr16 $1881 (8), cos16 $18D0 (40), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (7), altIrq $2304 (2), tick10Hz $2348 (3), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), keyLights $2B6E (4), throttleUp $2C1E (9), throttleDown $2C31 (6), keyRadar $2C5A (8), keyViewSelect $2C70 (8), keyTrimUp $2C87 (2), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (16), keyAileronLeft $2D6D (2), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), keyElevatorUp $2E5C (17), captureViewKey $2E84 (8), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (17), integrateFlight $32EE (7), groundContact $3515 (11), serviceAircraft $3638 (16), slewAux $372B (13), updateCompass $3823 (1), drawMagnetoLabel $3A71 (2), [loader stage2Loader] $7300 (1), setTextMode $796C (25), rvSpan $801B (1), buildViewMatrix $8111 (28), computeGroundBase $8324 (7), horizonPass $83A4 (8), horizonSplitRow $85C0 (2), horizonBresenham $8623 (4), opEndPolygon $8828 (5), vertexCacheEntry $89E4 (19), opDashedLine $8A43 (4), opOriginHigh $8BC1 (5), opOrigin $8BFD (23), clipPolygon $8FE8 (6), clipLineEnd $9478 (5), clipPlaneYPos $94C0 (1), clipPlaneYNeg $953E (1), clipPlaneXNeg $9644 (6), polygonScanLoop $986E (1), longSpan $9910 (4), span $9996 (9), drawLine $9A1D (1), dottedPlot $9B80 (9), opDottedPen $9B9B (17), transformGround $9FD0 (10), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (17), aiSpan $A4CA (4), sfxMiddleMarker $CD59 (17), altimeterUpdate $CE84 (1), airspeedUpdate $CF0E (1), slipBallUpdate $CF79 (5), loadOverlayEditor $E5C9 (6), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (27), windDrift $E716 (34), lightsColors $EBA5 (8), selectTimeOfDay $EBF2 (8), applyPalette $EC41 (5), drawViewOverlay $ED3C (18), drawAirframe $ED88 (41), engineModel $EE6B (11), updateInstrumentMasks $F35E (47), drawMaskChanges $F3F0 (92), bitmapAddressHelper $F4C5 (15), shiftBitsRight $F4E0 (17), shiftBitsLeft $F502 (16), setAltitudeFromEditor $F9C1 (3)
- **editor**, 845 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (18), cursorNextLine $B0FD (27), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (16), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (70), windToDisplay $B865 (154)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `clouds`
- **resident**, 564 new instruction starts: editorExitHook $0ACF (1), mulQ15 $16C9 (2), asr16 $1881 (8), cos16 $18D0 (40), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (7), altIrq $2304 (2), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), throttleDown $2C31 (5), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (11), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (23), integrateFlight $32EE (8), groundContact $3515 (6), serviceAircraft $3638 (16), slewAux $372B (13), [loader stage2Loader] $7300 (1), setTextMode $796C (25), horizonPass $83A4 (9), opEndPolygon $8828 (5), vertexCacheEntry $89E4 (1), opOrigin $8BFD (36), clipPolygon $8FE8 (2), clipLineEnd $9478 (5), clipPlaneXNeg $9644 (1), span $9996 (7), transformGround $9FD0 (5), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (17), aiSpan $A4CA (4), sfxMiddleMarker $CD59 (17), altimeterUpdate $CE84 (2), vsiUpdate $CF46 (4), slipBallUpdate $CF79 (2), loadOverlayEditor $E5C9 (6), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (27), windDrift $E716 (35), windLayer $E766 (5), setAltitudeFromEditor $F9C1 (1)
- **editor**, 849 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (21), cursorNextLine $B0FD (27), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (16), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (70), windToDisplay $B865 (155)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `failures`
- **resident**, 606 new instruction starts: editorExitHook $0ACF (1), asr16 $1881 (8), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSetMagnetos $2009 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (7), altIrq $2304 (2), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), setMagnetos $2829 (9), keyReturn $2BC4 (3), throttleDown $2C31 (5), keyViewSelect $2C70 (6), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (11), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), serviceAircraft $3638 (16), slewAux $372B (13), [loader stage2Loader] $7300 (1), setTextMode $796C (25), sfxMiddleMarker $CD59 (17), altimeterUpdate $CE84 (1), vsiUpdate $CF46 (1), loadOverlayEditor $E5C9 (6), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (27), realityFailures $EA84 (26), trimCreep $EAE2 (20), failureHandler0 $EB39 (3), failureHandler1 $EB42 (4), failureHandler3 $EB4F (2), failureHandler5 $EB57 (2), failureHandler7 $EB5F (2), engineModel $EE6B (53), updateInstrumentMasks $F35E (33), drawMaskChanges $F3F0 (73), bitmapAddressHelper $F4C5 (15), shiftBitsRight $F4E0 (17), draw10kMarker $F86F (1), setAltitudeFromEditor $F9C1 (3)
- **editor**, 870 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (25), cursorNextLine $B0FD (22), cursorPreviousLine $B136 (16), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (18), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (225), recallKey $B7C3 (70), windToDisplay $B865 (154)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `war`
- **resident**, 911 new instruction starts: editorExitHook $0ACF (1), mulQ15 $16C9 (2), divQ15 $1802 (2), asr16 $1881 (8), cos16 $18D0 (37), neg16 $19D5 (9), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadWar $201B (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecNav3F38 $2030 (1), vecFormat3Digits $2033 (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (13), altIrq $2304 (2), tick10Hz $2348 (12), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), keyDeclareWar $2AD5 (4), keyDropBomb $2B79 (8), fireGuns $2C03 (11), throttleUp $2C1E (9), throttleDown $2C31 (6), keyViewSelect $2C70 (8), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (26), keyCenter $2D82 (2), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), keyElevatorUp $2E5C (17), captureViewKey $2E84 (8), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (20), integrateFlight $32EE (7), groundContact $3515 (6), serviceAircraft $3638 (16), slewAux $372B (13), radioGate $3A53 (2), navVector3F38 $3F38 (41), [loader stage2Loader] $7300 (1), setTextMode $796C (25), rvLine $8009 (1), rvPlot $800C (1), rvSetPen $800F (1), rvSpan $801B (1), rvSpanColorX $8024 (1), buildViewMatrix $8111 (18), computeGroundBase $8324 (7), horizonPass $83A4 (8), dlAdvance $8749 (1), opEndPolygon $8828 (34), vertexCacheEntry $89E4 (12), opDashedLine $8A43 (4), opOrigin $8BFD (1), clipPolygon $8FE8 (6), clipLineEnd $9478 (5), clipPlaneYNeg $953E (1), clipPlaneXNeg $9644 (6), longSpan $9910 (4), span $9996 (9), drawLine $9A1D (1), project $9F94 (8), transformGround $9FD0 (34), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (17), aiSpan $A4CA (4), sfxGun $CCD1 (20), sfxBombRelease $CD04 (17), sfxMiddleMarker $CD59 (17), sfxBombWait $CE37 (31), slipBallUpdate $CF79 (4), loadOverlayEditor $E5C9 (6), loadOverlayWar $E5DB (3), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (27), windDrift $E716 (34), windLayer $E766 (5), drawViewOverlay $ED3C (20), engineModel $EE6B (18)
- **editor**, 875 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (21), cursorNextLine $B0FD (22), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (16), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (225), recallKey $B7C3 (70), windToDisplay $B865 (154), loadModeRecord $B998 (27)
- **war**, 789 new instruction starts: slotWar $A7EE (2), slotFlight $A7F4 (1), warMain $AA03 (52), enemyUpdate $AA84 (360), printHitsTaken $AE63 (9), warStatusLines $AE77 (53), gunsAndTracers $AEED (243), warFirstPass $B13E (47), warDamage $B19E (22)
- **flight**, 2 new instruction starts: slotEditor $A7E8 (1), slotWar $A7EE (1)

### `crash`
- **resident**, 708 new instruction starts: editorExitHook $0ACF (1), mulQ15 $16C9 (2), asr16 $1881 (8), cos16 $18D0 (37), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (8), altIrq $2304 (2), tick10Hz $2348 (3), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), throttleUp $2C1E (9), throttleDown $2C31 (6), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (30), coordinateRudder $2DD2 (25), keyRudderRight $2E2D (9), keyElevatorUp $2E5C (17), captureViewKey $2E84 (4), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (35), integrateFlight $32EE (13), groundContact $3515 (24), serviceAircraft $3638 (16), slewAux $372B (13), [loader stage2Loader] $7300 (1), setTextMode $796C (25), computeGroundBase $8324 (7), horizonPass $83A4 (9), opEndPolygon $8828 (5), vertexCacheEntry $89E4 (1), opDashedLine $8A43 (4), clipPolygon $8FE8 (5), clipLineEnd $9478 (5), clipPlaneYNeg $953E (1), longSpan $9910 (4), span $9996 (9), transformGround $9FD0 (8), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (18), aiSpan $A4CA (4), sfxCrash $CC68 (41), vsiUpdate $CF46 (3), slipBallUpdate $CF79 (4), loadOverlayEditor $E5C9 (6), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (27), windDrift $E716 (34), windLayer $E766 (5), engineModel $EE6B (11), busyDelay $F25B (10), maneuverRegimeTimer $F916 (4), crashMessage $F95D (20), splashDetect $F996 (6)
- **editor**, 694 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (10), cursorNextLine $B0FD (16), fieldLinePointer $B16B (6), printFieldValue $B2D6 (46), copyEditorPage $B346 (44), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (33), windToDisplay $B865 (154), loadModeRecord $B998 (20)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `splash`
- **resident**, 749 new instruction starts: editorExitHook $0ACF (1), mulQ15 $16C9 (2), divQ15 $1802 (2), asr16 $1881 (8), cos16 $18D0 (40), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (9), altIrq $2304 (2), tick10Hz $2348 (2), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), throttleUp $2C1E (8), throttleDown $2C31 (6), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (11), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (21), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (30), integrateFlight $32EE (8), groundContact $3515 (25), serviceAircraft $3638 (16), slewAux $372B (13), drawDgDigits $377C (1), updateCompass $3823 (2), [loader stage2Loader] $7300 (1), setTextMode $796C (25), computeGroundBase $8324 (7), horizonPass (cont.) $83A4 (2), horizonSplitRow $85C0 (2), horizonBresenham $8623 (7), opEndPolygon $8828 (5), clipPolygon $8FE8 (2), clipLineEnd $9478 (5), clipPlaneYNeg $953E (1), clipPlaneXPos $95C6 (1), clipPlaneXNeg $9644 (5), longSpan $9910 (4), span $9996 (8), drawLine $9A1D (1), transformGround $9FD0 (36), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (17), aiSpan $A4CA (4), drawTurnCoordinator $A532 (2), sfxCrash $CC68 (41), sfxTouchdown $CDAF (27), vsiUpdate $CF46 (3), slipBallUpdate $CF79 (6), loadOverlayEditor $E5C9 (7), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (32), windDrift $E716 (34), windLayer $E766 (5), engineModel $EE6B (12), busyDelay $F25B (10), crashMessage $F95D (21), splashDetect $F996 (10), setAltitudeFromEditor $F9C1 (3)
- **editor**, 867 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (25), cursorNextLine $B0FD (22), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (16), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (70), windToDisplay $B865 (154), loadModeRecord $B998 (20)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `ils`
- **resident**, 1255 new instruction starts: editorExitHook $0ACF (1), mulQ15 $16C9 (2), divQ15 $1802 (2), asr16 $1881 (8), cos16 $18D0 (40), neg16 $19D5 (10), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (7), altIrq $2304 (2), tick10Hz $2348 (4), keyPress $24C2 (2), requeueKey $24EB (7), keyReleaseCheck $2505 (8), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), decrementSelected $286D (51), incrementSelected $298E (41), keyObsSelect $2BA7 (3), keyNavSelect $2BAC (8), storeSelected $2BBC (4), throttleDown $2C31 (5), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (11), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (23), integrateFlight $32EE (9), groundContact $3515 (6), serviceAircraft $3638 (16), slewAux $372B (13), drawDgDigits $377C (1), task3A13 $3A13 (14), navTask3B32 $3B32 (34), drawToFrom $3C81 (107), drawLocalizer $3D71 (170), navVector3F38 $3F38 (40), [loader stage2Loader] $7300 (1), setTextMode $796C (25), opNavRecord $8030 (19), computeGroundBase $8324 (7), horizonSplitRow $85C0 (2), horizonBresenham $8623 (4), dlAdvance $8749 (1), vertexCacheEntry $89E4 (1), clipPolygon $8FE8 (5), clipLineEnd $9478 (5), clipPlaneXPos $95C6 (1), clipPlaneXNeg $9644 (6), longSpan $9910 (4), span $9996 (9), drawLine $9A1D (2), transformGround $9FD0 (7), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (2), opRunway $A5C8 (165), sfxMiddleMarker $CD59 (17), vsiUpdate $CF46 (3), slipBallUpdate $CF79 (2), loadOverlayEditor $E5C9 (6), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (27), windDrift $E716 (34), tuneDecrementPre $E9BF (6), tuneIncrementPre $E9F6 (5), engineModel $EE6B (12), trackGroundElevation $F8AF (22), setAltitudeFromEditor $F9C1 (1)
- **editor**, 843 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (21), cursorNextLine $B0FD (22), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (16), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (70), windToDisplay $B865 (154)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `demo-loop`
- **resident**, 998 new instruction starts: editorExitHook $0ACF (1), mulQ15 $16C9 (2), divQ15 $1802 (2), asr16 $1881 (8), cos16 $18D0 (40), neg16 $19D5 (9), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (11), altIrq $2304 (2), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), throttleDown $2C31 (5), keyViewSelect $2C70 (8), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (11), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (35), mulShiftHelper $32DF (1), integrateFlight $32EE (15), groundContact $3515 (24), densityAndAutoLevel $35BD (2), serviceAircraft $3638 (16), slewAux $372B (13), drawDgDigits $377C (3), updateCompass $3823 (2), [loader stage2Loader] $7300 (1), setTextMode $796C (25), buildViewMatrix $8111 (30), computeGroundBase $8324 (7), horizonPass $83A4 (9), horizonPass (cont.) $83A4 (15), horizonSplitRow $85C0 (2), horizonBresenham $8623 (22), opEndPolygon $8828 (5), vertexCacheEntry $89E4 (1), opDashedLine $8A43 (4), opOrigin $8BFD (1), clipPolygon $8FE8 (8), clipLineEnd $9478 (7), clipPlaneYNeg $953E (2), clipPlaneXPos $95C6 (1), clipPlaneXNeg $9644 (6), polygonScanLoop $986E (1), longSpan $9910 (4), span $9996 (9), drawLine $9A1D (3), project $9F94 (8), transformGround $9FD0 (24), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (21), aiSpan $A4CA (4), drawTurnCoordinator $A532 (4), opRunway $A5C8 (166), sfxCrash $CC68 (41), altimeterUpdate $CE84 (5), airspeedUpdate $CF0E (1), vsiUpdate $CF46 (5), slipBallUpdate $CF79 (4), loadOverlayEditor $E5C9 (7), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (32), windDrift $E716 (34), windLayer $E766 (11), engineModel $EE6B (13), busyDelay $F25B (10), draw10kMarker $F86F (2), maneuverRegimeTimer $F916 (4), crashMessage $F95D (20), splashDetect $F996 (8)
- **coldStart**, 1 new instruction starts: modePromptScreen $AA71 (1)
- **editor**, 707 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (16), cursorNextLine $B0FD (16), fieldLinePointer $B16B (6), printFieldValue $B2D6 (46), copyEditorPage $B346 (44), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (33), windToDisplay $B865 (154), loadModeRecord $B998 (27)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `restart`
- **resident**, 89 new instruction starts: asr16 $1881 (8), drawThrottleIndicator $1BE1 (4), vecLoadColdStart $2015 (1), tick10Hz $2348 (5), keyPress $24C2 (2), restoreNmi $2700 (10), dispatchKey $27D8 (10), keyLights $2B6E (4), throttleUp $2C1E (8), throttleDown $2C31 (6), aeroUpdate $2F45 (12), drawMagnetoLabel $3A71 (2), span $9996 (1), slipBallUpdate $CF79 (2), loadOverlayColdStart $E5C0 (3), engineModel $EE6B (11)
- **coldStart**, 1 new instruction starts: slotColdInit $A7E2 (1)
- **flight**, 1 new instruction starts: slotColdInit $A7E2 (1)

### `joystick`
- **resident**, 475 new instruction starts: mulQ15 $16C9 (2), asr16 $1881 (8), cos16 $18D0 (13), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), tick10Hz $2348 (5), keyScan $2418 (4), keyReleaseCheck $2505 (14), sampleCia1 $2574 (9), joystickAction $2688 (52), autoCenter $26EC (5), dispatchKey $27D8 (10), keyLights $2B6E (4), fireGuns $2C03 (3), throttleUp $2C1E (8), throttleDown $2C31 (14), keyViewSelect $2C70 (8), keyElevatorDown $2D2B (26), keyAileronLeft $2D6D (9), centerControls $2D9D (10), keyAileronRight $2DC2 (7), coordinateRudder $2DD2 (30), keyRudderRight $2E2D (16), keyElevatorUp $2E5C (15), captureViewKey $2E84 (8), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), aeroUpdate $2F45 (12), integrateFlight $32EE (1), drawMagnetoLabel $3A71 (2), rvSpan $801B (1), computeGroundBase $8324 (7), horizonPass (cont.) $83A4 (2), horizonSplitRow $85C0 (2), horizonBresenham $8623 (7), clipPolygon $8FE8 (2), span $9996 (7), drawLine $9A1D (1), transformGround $9FD0 (6), drawAttitudeIndicator $A378 (2), slipBallUpdate $CF79 (2), drawAirframe $ED88 (41), engineModel $EE6B (11)

### `stall`
- **resident**, 433 new instruction starts: mulQ15 $16C9 (2), asr16 $1881 (8), cos16 $18D0 (40), updateVsiNeedle $1A6A (2), drawElevatorIndicator $1B92 (4), drawThrottleIndicator $1BE1 (4), mainLoop $204B (1), tick10Hz $2348 (3), dispatchKey $27D8 (10), throttleUp $2C1E (9), throttleDown $2C31 (10), throttleJump $2C4F (3), keyElevatorDown $2D2B (14), keyElevatorUp $2E5C (18), captureViewKey $2E84 (4), aeroUpdate $2F45 (44), integrateFlight $32EE (8), groundContact $3515 (24), computeGroundBase $8324 (7), horizonPass $83A4 (9), opEndPolygon $8828 (5), vertexCacheEntry $89E4 (1), opDashedLine $8A43 (4), clipPolygon $8FE8 (5), clipLineEnd $9478 (5), clipPlaneYNeg $953E (1), longSpan $9910 (4), span $9996 (9), transformGround $9FD0 (8), renormalizeGround $A1B9 (11), drawAttitudeIndicator $A378 (17), aiSpan $A4CA (4), sfxStallHorn $CC46 (13), sfxCrash $CC68 (41), vsiUpdate $CF46 (3), slipBallUpdate $CF79 (4), windDrift $E716 (34), engineModel $EE6B (12), busyDelay $F25B (9), maneuverRegimeTimer $F916 (2), crashMessage $F95D (17)

### `library`
- **resident**, 235 new instruction starts: asr16 $1881 (8), drawThrottleIndicator $1BE1 (4), vecGetKey $2003 (1), vecSlewAux $200C (1), vecLoadEditor $2018 (1), vecCacheHelper $2039 (1), vecTextMode $203F (1), mainLoop $204B (1), altIrq $2304 (2), tick10Hz $2348 (5), keyPress $24C2 (2), requeueKey $24EB (7), keyReleaseCheck $2505 (8), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), throttleUp $2C1E (8), throttleDown $2C31 (6), aeroUpdate $2F45 (12), slewAux $372B (13), [loader stage2Loader] $7300 (56), setTextMode $796C (25), loadOverlayEditor $E5C9 (6), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (27), engineModel $EE6B (11)
- **editor**, 653 new instruction starts: slotEditor $A7E8 (1), editorEntry $B09A (15), cursorNextLine $B0FD (16), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (19), libraryLoad $B1F1 (15), librarySave $B223 (13), fieldKeyEntry $B241 (32), setLibraryBlock $B289 (7), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (65), stateToRecord $B3F6 (143), saveUserMode $B7A5 (10), recallKey $B7C3 (77), windToDisplay $B865 (111), storeModeRecord $B98D (5), loadModeRecord $B998 (33)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)

### `demo-key`
- No new code beyond `demo-loop`: every instruction start in `demo-key.cov` is also in `demo-loop.cov`, in the same plane.

### `war-hook`
- **resident**, 529 new instruction starts: mulQ15 $16C9 (2), drawTrimIndicator $1C10 (4), mainLoop $204B (7), dispatchKey $27D8 (10), keyTrimDown $2C9A (19), keyIgnored $2CC1 (1), captureViewKey $2E84 (4), radioGate $3A53 (2), rvLine $8009 (1), rvSetPen $800F (1), rvSpan $801B (1), rvSpanColorX $8024 (1), opEndPolygon $8828 (34), opDashedLine $8A43 (4), opOrigin $8BFD (1), clipPolygon $8FE8 (5), clipPlaneYNeg $953E (1), clipPlaneXNeg $9644 (5), span $9996 (9), transformGround $9FD0 (29), windLayer $E766 (5), engineModel $EE6B (5), [free freeF9F9] $F9F9 (320), [buffer instrumentSaveHigh] $FF80 (48), [free freeFFE0] $FFE0 (9), [residue residueFFF1] $FFF1 (1)
- **war**, 100 new instruction starts: slotWar $A7EE (1), slotFlight $A7F4 (1), warMain $AA03 (34), enemyUpdate $AA84 (3), warStatusLines $AE77 (23), gunsAndTracers $AEED (38)

### `bw`
- **resident**, 412 new instruction starts: editorExitHook $0ACF (1), asr16 $1881 (8), drawElevatorIndicator $1B92 (4), drawAileronIndicator $1BAC (4), drawRudderIndicator $1BCD (4), drawThrottleIndicator $1BE1 (4), drawFlapsIndicator $1BFD (4), vecClock $2000 (1), vecGetKey $2003 (1), vecSetAltitude $2006 (1), vecSlewAux $200C (1), vecService $200F (1), vecLoadEditor $2018 (1), vecLoadFlight $201E (1), vecRedraw2D58 $2024 (1), vecRedraw2C46 $2027 (1), vecRedraw2E4C $202A (1), vecRedraw2DE6 $202D (1), vecTextMode $203F (1), vecGraphicsInit $2042 (1), vec2CD7 $2045 (1), mainLoop $204B (8), altIrq $2304 (2), textModeIrqSwap $2673 (10), dispatchKey $27D8 (10), keyEditor $2801 (3), throttleDown $2C31 (5), keyFlapsUp $2CC2 (24), keyElevatorDown $2D2B (11), coordinateRudder $2DD2 (23), keyRudderRight $2E2D (9), controlCoefficients $2E92 (44), rebuildWingCoefficients $2F07 (29), serviceAircraft $3638 (16), slewAux $372B (13), [loader stage2Loader] $7300 (1), setTextMode $796C (25), dlAdvance $8749 (1), vertexCacheEntry $89E4 (18), dottedPlot $9B80 (9), opDottedPen $9B9B (17), sfxMiddleMarker $CD59 (17), loadOverlayEditor $E5C9 (7), loadOverlay $E5F6 (4), swapEditorCacheIn $E6D8 (2), swapEditorCache $E6DB (32), lightsColors $EBA5 (8), selectTimeOfDay $EBF2 (10), applyPalette $EC41 (8), setAltitudeFromEditor $F9C1 (3)
- **coldStart**, 9 new instruction starts: titleScreen $AA1C (9)
- **editor**, 845 new instruction starts: slotEditor $A7E8 (1), slotFlight $A7F4 (1), editorEntry $B09A (18), cursorNextLine $B0FD (27), eraseCursor $B15B (9), fieldLinePointer $B16B (6), editorKeys $B179 (13), fieldInput $B198 (16), libraryLoad $B1F1 (2), librarySave $B223 (2), fieldKeyEntry $B241 (32), parseFieldValue $B29B (26), printFieldValue $B2D6 (46), copyEditorPage $B346 (59), stateToRecord $B3F6 (143), recordToState $B559 (220), recallKey $B7C3 (70), windToDisplay $B865 (154)
- **flight**, 1 new instruction starts: slotEditor $A7E8 (1)
