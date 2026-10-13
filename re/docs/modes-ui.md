# Modes, screens and instruments

An overview of the game's modes and screens and of the instrument panel, with the facts the lab
sessions confirmed or corrected (`features.md`). Each section names the page that specifies the
code exactly and its port:

| Topic | Specification |
|---|---|
| Title, prompts, cold start, main loop, demo and war-exit checks | `main-loop.md` |
| Editor, mode records, mode library, text screen | `editor.md` |
| Europe 1917 | `war.md` |
| Course plotter, database info screen | `course-plotter.md` |
| Keys, pause, views, radar keys, slew keys | `input.md` |
| Crash, splash, slew, failures | `flight-model.md` |
| Panel, gauges, readouts, instrument masks | `panel.md`, `radios.md` |

## Startup screens (overlay 0, stage 3)

`titleScreen` ($AA1C) clears the window ($1EAF), draws the record list at $A80C ($1E99) and waits
for A or B through `waitForKey` ($2250). Records are `[y][x in 2-px units][ASCII][0]`; the list
ends with `00 00`. The text is white (pen 3) on $D021.

| Record | (y, x) | Text | Port |
|---|---|---|---|
| $A80C | (12, 13) | SUBLOGIC FLIGHT SIMULATOR II | Kept |
| $A82B | (20, 45) | VERSION 1.0 | Kept |
| $A839-$A85A | (28, 8) | 31 characters (on modified copies, a line the cracker wrote over the original) | **Not ported.** The row stays blank. |
| $A85B-$A87D | (36, 7) | 32 characters (likewise) | **Not ported.** The row stays blank. |
| $A87E | (50, 10) | WHAT DISPLAY ARE YOU USING? | Kept |
| | (60, 10) | A. COLOR TV OR COMPOSITE MONITOR | Kept |
| | (68, 10) | B. BLACK AND WHITE TV OR MONITOR | Kept |
| | (88, 10) | (TYPE A OR B) | Kept |

The list ends `00 00`, with one spare 0 at $A8F3.

The original text of the two overwritten records is not on the disk: there is no "COPYRIGHT",
"(C)", "1984" or "ARTWICK" anywhere. They were probably a copyright/credit pair. The 69-byte
budget (63 text characters) is known. The import scrub keeps the record structure and turns the
text into spaces, which draw nothing (`excluded.md`).

**The A/B display prompt:**

- **A (color):** `$0E61=$65`, `$0E63=$6C`, `$0E65=$EA`, `$0E69=$0B`.
- **B (black and white):** `$0E61=$FC`, `$0E63=$CB`, `$0E65=$CB`, `$0E69=$00`. Only the window
  turns gray; the panel keeps its colors (lab `bw`).
- **Both:** `$0E62=$0E`, `$0E64=$06`, `$0E66=0`, `$083C=0`, then `selectTimeOfDay` ($EBF2).

**Screen 2** ($A8F4, `modePromptScreen` $AA71):

| (y, x) | Text |
|---|---|
| (40, 10) | SELECT OPERATING MODE |
| (48, 10) | A. DEMO MODE |
| (56, 10) | B. REGULAR FLIGHT MODE |
| (76, 10) | (TYPE A OR B) |

A adds 1 to `$095B` (demo). In the app, View ▸ Display chooses a color or black-and-white monitor
for presentation only; the game's own choice is this prompt's.

## Demo vs regular

- `$095B` = 1 makes the main loop (`$2133`, once per 8 passes) set `$08BB` = 3.
- The editor overlay then sets `$0963` = 2, loads built-in mode 2 and exits. At exit `$095A` =
  `$095B` and `$095B` = 0.
- **Mode 2** is a self-flying takeoff from Meigs: IAS 20, throttle 32000, elevator 38911, aileron
  32700, 10:17, season 3. It climbs away in a slow turn and crashes after about 100,000 frames
  (28 minutes; lab `demo-loop`).
- Any key clears `$095A` (the dispatcher, $27DD).
- A crash reloads the current mode `$0963` (`$08BB` = 1), so the demo flight starts again, but
  `$095A` is then 0: `$095B` was cleared by the first exit.
- Regular flight starts in the cold image's state (08:00, COMMUNICATION RATE 200, no shear) with
  `$0963` = 0; '+' or a crash then loads built-in mode 0 (12:00, throttle 0, comm rate 128,
  shears 3000/6000/9000 ft).
- Mode-record byte +04 is 1 only in mode 2 and has no code references.

## Mode requests (`$08BB`) and the editor entry

| Request | Set by | Editor action |
|---|---|---|
| 1 | '+' and crash/splash ($F95D) | `loadModeRecord` ($B998): reload mode `$0963` into `$0964-$09A4`, i.e. reset the flight |
| 2 | 'S' | `saveUserMode` ($B7A5): save the situation as user mode `$0963`+10 and make it the current mode |
| 3 (and any other value) | Demo check | Load mode 2 |
| (`$08BA` = 1) | E / HOME | The full editor |

The editor's exit (`recordToState`) clears `$08BA/$08BB` at $B776. `editor.md` has every step.

## Editor (overlay 1, blocks 42-47, entry $B09A)

`editor.md` is the specification. In brief:

- **Screen.** Text mode through `$203F` → `$2673` / `$796C`: border 8, `$D018=$16` (ROM
  upper/lowercase), `$DD00=$97`, screen $0400, white background, color RAM $0B. Two 40×25 page
  images (page 0 at $A804: SIMULATION CONTROL and AIRCRAFT POSITION; page 1 at $ABEC:
  ENVIRONMENTAL CONTROL) in screen codes; rows 23-24 hold a rule and `CM-FS2  FIX MODE ... HIT E
  TO EXIT`.
- **Lines and fields.** The cursor stops on every screen line 1-21 of a page, including lines
  without a field (the blank line 8 and the AIRCRAFT POSITION heading on page 0). Page 0 has 19
  fields, page 1 has 21; each descriptor is `[size][line × 2][offset into $0964]`.
- **Keys.** Digits (at most six), RETURN (accept; down **one screen line**, after line 21 the
  other page's line 1), '-' or ↑ (up one line; from line 1 the other page's line 21), DEL/':'/←
  (take back a digit), E (accept and exit), S (save to a user mode), '+' (recall), CTRL-X (load
  the library), CTRL-Z (format and save the library).
- **USER MODE** (`$09A5`): 0-24 recalls a mode (the editor redisplays it and stays open; a
  second E exits), 110-124 saves the current values as mode n−100 and selects it, 210 and above
  is ignored.
- **Conversions** (`stateToRecord` $B3F6 on entry, `recordToState` $B559 on exit, through
  `mulU16` $188A; "bits a-b" are the product's bits):

  | Quantity | State → record | Record → state |
  |---|---|---|
  | Angles | raw × 360, bits 16-31 | deg × $B60C, bits 8-23 |
  | Altitude | (m + field elevation) × $D1EB, bits 14-29, − 9 ft | (ft + 9) × $4E0C, bits 16-31, − field elevation, at least 3 m (`$F9C1`) |
  | Shears | m × $0348, bits 8-23 → ft | ft × $4E, bits 8-23 → m |
  | Wind | knots field = turbulence × 100 + knots; direction × 360, bits 16-31 | split by subtracting 100; deg × $B60C, bits 8-23 (`$B865`/`$B901`) |

- **Exit.** EUROPE 1917 forces mode 7 (and `$0E7C` = 7); the record goes back to the state; the
  war counters are reset (ammo 100, bombs '5', score 0); the indicators are redrawn
  ($2024-$202D); SOUND (`$0964`) is copied to `$08D3` at $B78E. In reality mode with the throttle
  low byte 0 the exit also turns the magnetos OFF (the engine then needs START).

**The mode record** ($0964-$09A4, 65 bytes): while the editor is open it holds display values;
the exit converts the shear and wind fields in place, so in flight they hold meters and the
internal wind values (low byte knots, high byte turbulence; directions as binary angles), while
the cloud fields stay in feet (a copy in meters goes to `$0856-$085D`; lab `clouds`).

| Offset | Field | Offset | Field |
|---|---|---|---|
| +00 | SOUND | +1F / +20 / +21 | HOURS / MINUTES / SEASON |
| +01 | AUTO-COORDINATION | +22 / +24 | Cloud layer 2 tops / bottoms (ft) |
| +02 | SLEW | +26 / +28 | Cloud layer 1 tops / bottoms |
| +03 | REALITY | +2A / +2C / +2E | Shear 1 / 2 / 3 = wind layer bounds |
| +04 | Unused (1 only in demo mode 2) | +30 / +32 | Wind level 3 knots / degrees |
| +05 | EUROPE 1917 | +34 / +36 | Wind level 2 |
| +06 | COMMUNICATION RATE | +38 / +3A | Wind level 1 |
| +07 / +09 | NORTH / EAST (high word + $4000) | +3C / +3E | Surface wind |
| +0B | ALTITUDE (ft) | +40 | RELIABILITY |
| +0D / +0F / +11 | PITCH / BANK / HEADING (deg) | | |
| +13 / +15 | AIRSPEED / THROTTLE | | |
| +17 / +19 / +1B / +1D | RUDDER / AILERONS / FLAPS / ELEVATORS (controls centered at 32767) | | |

Not in the record: USER MODE `$09A5`, OVER-CONTROL LIMITER `$09A9` and ADF ENABLE `$09AA`.

Built-in **mode 0**: N 17188, E 16671 (Meigs), 12:00, season 4, shear 3000/6000/9000,
reliability 100. **Mode 7**: N 17404, E 7434, EUROPE 1917 = 1, comm rate 255.

## Mode library

| Modes | Where | Rules |
|---|---|---|
| 0-9 (built in) | 10 × 65 bytes at $B9E1 in the editor overlay | Read-only |
| 10-24 (user) | 15 × 65 bytes at `[$0961]` = **$C800** | `$AB88` fills record n with byte value n ($0A..$18) at the cold start. Load is `$B998`; store `$B98D` (only modes ≥ 10). |

The library is saved as **logical block 64**: 1024 bytes, 975 used plus 49 slack (D64 track 14,
sectors 4-7), on a separate disk that CTRL-Z formats with the game's own disk name and ID. On the
master disk, block 64 is overlay 4, so CTRL-X with the game disk in the drive loads that overlay's
bytes into the user modes (lab `library`).

**Port:** `ModeLibrary.bin` is that 1024-byte image (`engine.md`, "The mode library"): CTRL-X
loads it, CTRL-Z replaces it (the previous file is kept as `ModeLibrary.bak`), and File ▸ Import
/ Export Mode Library use the same file. The game disk is never written.

## Europe 1917 (overlay 2, blocks 158-160; mode 7)

`war.md` is the specification. In brief:

- **Entry** is the slot `$A7EE`, which jumps to $AA03, called every pass while `$0969` is set.
- **Exit:** leaving mode 7 does a full cold restart (a jump to $A7E2 at $2149, checked once per 8
  passes; the title and prompts come back).
- **First pass ($B13E)** disables the radios (`$FE` / `$09A7` bit 7) and paints a black status
  panel over the radio stack (cells from $7E4D, color $10).
- **Status line** at (114, 117): 'WAR !!!!' once when war is declared, followed by a busy wait of
  exactly 328,707 cycles (256 × 256 empty loop steps, about 19 frames); then 'IN RANGE',
  'ENEMYFIRE' or blank. The records are at $A83B/$A849/$A857/$A865.
- **Rotating line** at (171, 117) advances every 4 war passes (main-loop passes, not frames)
  through the pointers at $A88F: AMMO (`$0AA5/$0AA6`, 100 rounds), SCORE (`$08D1/$08D2`, back to
  0 at 1000), BOMBS (the digit `$08E8`, from '5'), HITS (`$08B7`).
- **Keys:** W declares war (`$0ACC` |= 1, 3 once 'WAR !!!!' shows). SPACE fires when airborne
  (the brakes on the ground; one burst per key repeat). X drops a bomb (the whistle, then the
  explosion).
- **Enemies:** six 28-byte records at $A95B. A dormant enemy (state 1) attacks (state 2) once the
  aircraft is west of its trigger east and not south of its trigger north; an attacking one falls
  dormant again once the aircraft leaves its attack zone (not west of the zone east, or south of
  the zone north). Attackers step toward the aircraft per axis and fire when close and on the
  scope.
- **Guns:** a burst lasts 3 war passes; tracers live 25 passes and can score from their sixth
  walked pass, against an enemy that was in the gunsight box (6 lines from $A8A7, front view
  only) on the pass before. A kill adds 1 to the score and counts in `$08B2`.
- **Bombs never score on this disk:** no code or display list starts the impact countdown
  `$0AA7/$0AA8` (`war.md`, Bombs).
- **Damage ($B19E):** thresholds on the hits taken set failure bits in `$09BF` (and `$08D4` at
  the top threshold), lower after 4 kills.
- **Rearm at base:** `$3614` with the service request `$0838` = 2.
- **$FD00 hook:** R sets `$08D7`, and the main loop then calls $FD00 on the next flip pass.
  The port treats it as a documented no-op (`excluded.md`).

## Radar, views and slew

- **Radar** ('4'): `$0836` = 1, `$FC` = 2. The renderer uses a straight-down camera (pitch $4000,
  bank = −heading) at the height `$0888-$088B`: ',' doubles it (zoom out) and '.' halves it (zoom
  in). `$ED3C` draws the aircraft symbol. '5' leaves radar (`$FC` stays 2).
- **Views:** '5' (or joystick-1 fire) arms `$FC` = 1, then T/Y/H/N/B/V/F/R/G picks `$0ACA` = 0,
  2, ..., $0E or $FF (down); the capture resets `$FC` to 0 and does not move the control
  (`input.md`). Splash detection and the gunsight work only in the front view.
- **Slew** (`$0966`): `$3660` replaces the integrator and shows ` NNNNN NORTH ` at (2, 20) and
  ` NNNNN EAST ` at (2, 82) via `$EB82`/`$1D54`. The slew keys are in `input.md`.

## Course plotter (Q; `$0E70` → $F627)

`course-plotter.md` is the specification. The menu ('COURSE PLOTTER SYSTEM', $F522) waits for a
key through `$2250` and stays up after A-D; E returns to flight:

| Key | Action |
|---|---|
| A | Normal recording: interval 10, scale 6 |
| B | Display the plot (a white polyline, seen in the radar view) |
| C | Precision recording: interval 2, scale 4 (restarts the recording) |
| D | Off |
| E | Return |

- **Recording** writes a display list at $D000 in the RAM under I/O: op 07 (origin with the scale
  and the position `$5A-$65`), op 1C, op 01 moveto (0, 0, 0), then one 7-byte `02 dx dy dz`
  lineto per recorded point and the end marker $79. It sets `$08BC` = 2 (the editor cache at
  $D000 is invalid).
- **Display** (`$0E82`, `$F6E2` every pass) points the scenery interpreter at $D000 and runs it
  through $8006 between the bank switches $F7B0/$F7B4.

**Port:** the same memory, shared with the editor cache as in the original.

## Database info (CTRL-E; overlay 4, block 64)

`$0E87` → `$A7FA` → $A86A. It clears the window and draws the records from $A802:
'CURRENT DATABASES ARE:', 'CHICAGO', 'LOS ANGELES', 'SEATTLE', 'NEW YORK', 'PRESS ANY KEY TO
CONTINUE ...'. Then it waits for a key (the clock stands still), and the next pass reloads the
flight overlay and the area (`course-plotter.md`).

## Crash and splash

| Event | Condition | Result |
|---|---|---|
| Crash (`groundContact` $3515) | On the ground, not repositioning, descending (VS high byte `$0A51` < 0), and either VS_hi + 8 < 0 (≤ −9 m/s) or the bank high byte outside −10..+9 (`(viewBank_hi + 10) mod 256 ≥ 20`, about 14°) | `$0834` = 4, V_hi = 0, the crash noise (`sfxCrash` $CC68) |
| Splash (`splashDetect` $F996, even phases) | On the ground, front view (`$0ACA` = 0), not radar, `$0A83` = 0, and the window bitmap byte `$50DE` (y 110, x 152-159) = $55 (the water pattern) for 3 consecutive checks | `$0834` = 8 |
| Message (`crashMessage` $F95D) | Flip pass with `$0834` set | `$0E59` = 2 and the crash noise, clear the window, 'CRASH !!!' or 'SPLASH !!!' ($F944/$F950) at (50, 20), the delay (`busyDelay`, Y = 5, 2.2 s), `$08BB` = 1 (reload the current mode) |

## Pause

P, RUN/STOP and CTRL-P go straight to `waitForKey` ($2250), which pauses the simulation
(`$08CC`) and mutes the sound. The key that ends the pause is consumed. Holding P toggles the
pause with every key repeat (`input.md`).

## Instrument panel

`panel.md` (gauges, markers, readouts, masks) and `radios.md` (the radio stack and the nav
instruments) are the specifications; this is the layout at a glance.

### Layout (screen pixels)

| Row | Instruments, left to right |
|---|---|
| Top (y 112-160) | Airspeed (needle center 25,136); attitude indicator (x 64-103, y 120-151); altimeter (141,136); NAV1 OBI (x ~172-216); radio stack x 224-319 (COM y 113-128, NAV1 y 129-144, NAV2 y 145-160) |
| Bottom (y 161-199) | Turn coordinator (x 0-48); DG (x 56-100); VSI (141,180); NAV2 OBI or ADF (needle 203,182); engine/clock block (x 224-319, y 161-199) |

### Linear indicators (XOR shapes via $1D01)

| Indicator | Variable | Position |
|---|---|---|
| Elevator | `$0AAC` | x 108, y 169+v (`$2715` = ($50−v)>>3) |
| Ailerons | `$0AA4` | x 93+v, y 158 (`$2716`) |
| Rudder | `$0ABD` | x 93+v, y 196 |
| Throttle | `$0AC9`>>3 | x 225, y 198−v |
| Flaps | `$0AB0`>>4 | x 225, y 115+v |
| Trim | `$0AAE` | x 225, y 148+v |
| Mixture | `$0A9A` (0-7: RETURN, then ',' raises and '.' lowers) | x 232, y 185+v |
| TC ball | `$0A95` | x 14+v, y 190 (`$CF79`) |
| Fuel L / R | `$09C2` / `$09C5` >> 1 | y 178, x 260+v / 295+v |
| Oil temperature / pressure | `$09CB` / `$09CD` | y 186, same x |
| Fuel tank selector | `$09C6` (CTRL-F, then '.' right, ',' left) | Marker at (287, 179) |

### Digital readouts (records at $219C-$223F; (y, x) in record units)

| Readout | Position | Driver |
|---|---|---|
| DG heading / reciprocal | (171, 35) / (187, 35) | `headingReadout` $3773, `drawDgDigits` $377C |
| Magnetic compass | (106, 114), inside the window's bottom right | `updateCompass` $3823; lags toward the heading by ±75 / ±1200 |
| COM 1xx.xx | (122, 120) | `drawComFrequency` $3903 |
| NAV1 / NAV2 | (138, 120) / (154, 120) | `drawNav1Frequency` $38BD / `drawNav2Frequency` $38D9. With the ADF enabled NAV2 shows 'ADF NNN' (`drawAdfPanel` $E936). |
| OBS1 + reciprocal / OBS2 + reciprocal | (117 / 149, 93) / (160 / 192, 93) | `drawObs1` $3923 / `drawObs2` $3976; 2° steps |
| XPDR | (154, 140) | `drawTransponder` $3A5C |
| DME NN.N | (138, 140) | `drawDme` $3A13 (phase 0), from the distance `updateGlideslopeAndDme` $3DA2 computes |
| Clock HH MM SS | (163, 129 / 138 / 147) | `drawClock` $39D9 (vector $2000) and `drawClockSeconds` $39B6 on the 1 Hz tick |
| Magnetos O/L/R/B/S, lights 1/O, CH/HT | (170, 130), (170, 155), (194, 150) | `drawMagnetoLabel` $3A71 (the magneto records through the pointers at $3A67) |
| Tach | (194, 132) | `drawTach` $3AB9: RPM = `$09BE`×50 |

All readouts update only when their bit in `$FD/$FE/$FF` is set; `radioGate` $3A53 gates the
radios on `$FE` bit 7.

### Navigation

| Item | Detail |
|---|---|
| Localizer needle | Shape $3B13 at x 180+v (NAV1 y 126 via $3D71, NAV2 y 171 via $3D68) |
| NAV1 glideslope | 3-byte XOR bar at y 126+v, x 184-207 ($3C5D) |
| TO/FROM | Records $2210+8k (OFF/TO/FR; NAV1 y 141, NAV2 y 184, x 94; $3C81) |
| Marker lamps | Cells $7E7B/$7E7C/$7E7D: unlit $BB; outer $EB, middle $AB, inner $1B. Sound states 5/6/7; not in war mode. No scenery record sets the inner-marker flag `$084A`; the cold image's flags sound all three once after the start (lab `ils`, `idle`). |
| Other | `updateNav1Cdi` $3B32 and `updateNav2Cdi` $3B9B run on odd phases; `stationDistance` $3F38 is also reached through the vector $2030 (the war overlay's distances). |

### Altimeter 10,000-ft marker ($F86F)

It runs in phase 1 only when `$FD` bit 3 is set. Index = min(8, (altitude high byte $60 + 2)/6).
It XOR-redraws one of 9 point-list shapes (pointers $F7DC, state $F7DB) via `$1BC3` at offset
(12, 10).

### Instrument enable and failure masks ($F35E, every pass)

`$FD = $09A6 & $0942 & $0945`, `$FE = $09A7 & $0943 & $0946`, `$FF = $09A8 & $0944 & $0947`
(enable, failure and lighting masks). A bit that changes blanks (saving the pixels) or restores
its instrument's area through the records at $F2E6/$F316/$F346. The owner of every bit is listed
in `display.md` (Panel) and `panel.md` (The areas). The port is literal: a failure freezes exactly
the gauge whose bit it clears.
