# Features verified in the lab

What the coverage sessions (`re/sessions/*.txt`) established about each key and feature of the
original, checked against `input.md` and `modes-ui.md`. Every claim below names its session and
the evidence: peeked memory (`peek:` steps print the frame, PC, SP and bytes), text-screen dumps
(`text`) or screenshots (`shot:`) that were looked at. Run a session with

```sh
swift build -c release --product fs2lab
.build/release/fs2lab run "$FS2_D64" out/sessions/<name> @re/sessions/<name>.txt
```

The lab is deterministic: the same session always prints the same frames and values. Frame numbers
below are from these runs.

**Status key:** ✅ confirmed as documented · ✏️ corrected or made more precise · 🆕 not documented before

## Session conventions

- Every flight session starts with the `regular.txt` prefix (display A, regular flight B, first
  main-loop pass), then `until:0901:4E:3000 pc:204B:3000 wait:60`.
  - ✏️ The first main-loop pass ($204B) comes **before** the scenery is loaded. The Chicago area
    (block 68, slot tag $0900 = $44) and the Meigs detail block (78, $0901 = $4E) stream in over
    the next ~650 frames. During the load the window still shows the mode prompt, and the keyboard
    is not scanned, so keys pressed then are lost.
  - `regular.txt` used to end mid-load (`wait:300` after the first pass, the PC in the IEC
    loader). It now waits for the scenery and stops at `$204B`, so `Original.regularFlight()` is
    a settled Meigs state.
- Keys are pressed for 6 frames with ≥ 14 frames between presses. The matrix is scanned every
  4 frames and the 10 Hz tick takes one key at a time, so shorter gaps can lose keys.
- 🆕 **CTRL combinations must press CTRL first.** The scan runs column 0 to 7, and CTRL is in
  column 7. When CTRL and a letter go down in the same scan, the letter is queued first without
  the −$40 (switches/radios sessions; scratch test: CTRL+C pressed together gave rudder −4 and FC 0,
  while CTRL held 8 frames earlier gave FC 4). Later scratch tests: a lead of 1-5 frames works or
  not depending on the scan phase (right after the regular start every lead from 1 to 5 frames
  gave $FC = 4; in a longer run a 1-frame lead gave plain C, rudder −4). CTRL+I pressed
  together never toggled the carb heat. The sessions use `down:CTRL wait:8 key:X:6 up:CTRL`.
  The app's key timing puts CTRL into the matrix a whole keyboard cycle before the letter
  (`KeyTiming`, `engine.md`).
- '+' and ':' cannot be written in a key step (they are the step syntax), so they are `PLUS` and
  `COLON`.

## Keyboard timing (scratch tests, recorded in the session comments)

| Claim | Status | Evidence |
|---|---|---|
| A held key repeats after 5 ticks, then every tick | ✅ | ';' held 30 frames: +8 once; 42 frames: 3 steps; 60 frames: 7 steps (first press, then about one repeat per 6 frames after ~30 frames) |
| Holding P ends the pause after about 0.5 s | ✅ ✏️ | `pause` comments: with P held, $08CC = 1 within 8 frames, 0 after ~40 frames, then it **toggles on every repeat** (1, 0, 1 every 10 frames), so the state after release depends on the release time |
| A deflected joystick suspends the keyboard | ✅ | `joystick`: L held while port 1 is held down → lights $0AB5 unchanged, elevator +12 |

## Flight controls

| Key | Claim | Status | Evidence (session) |
|---|---|---|---|
| `;` | Throttle +8, max $78 | ✅ | `takeoff`: $0AC9 0 → $78 after 150 frames held |
| `:` / DEL | Throttle −8 | ✅ | `switches`: $10 → $08 (COLON) → $00 (DEL) |
| `/` | Next throttle key jumps to idle or full | ✅ | `takeoff`: `/` then COLON → $0AC9 = 0; `/` then `;` → $78 |
| B / T | Elevator +4/−4; +16 inside the quick-repeat window | ✅ ✏️ | `takeoff`: B×3 → $24 (4+16+16). The window depends on tick alignment: in `war` B×3 gave $24, in a scratch run $18 (4+4+16) |
| V / R | Trim +4 / −4 | ✅ | `takeoff`: V V → $08, R → $04 |
| F / H | Ailerons −4/+4 | ✅ | `switches`/`takeoff`: H H → $0AA4 = 8 and rudder $0ABD = 8 (AUTO-COORDINATION copies) |
| C / M | Rudder −4/+4 | ✅ | `switches`: C C → $0ABD = $F8 and ailerons $F8 |
| G | Center ailerons and rudder | ✅ | `switches`: $0AA3/$0ABD → 0 |
| N / Y | Flaps +$20 (max $60) / −$20 | ✅ | `switches`: N×4 → $60, Y Y → $20, Y×3 → 0 |
| SPACE | Brakes on the ground | ✅ | scratch test during the roll: airspeed high byte −2 (then acceleration continues) |

Takeoff (`takeoff`): with full throttle from standstill the airspeed reaches $1AC5 (≈27 m/s) after
~9 s; B×3 lifts off within 3 s ($0A12 = 0); climb ≈ 7.6 m/s at first ($0A50 = $079C), 4 m/s
later. Consistent with the `flight-model.md` checks.

## Views and radar

| Claim | Status | Evidence |
|---|---|---|
| '5' then T/Y/H/N/B/V/F/R/G sets $0ACA = 0/2/4/6/8/$0A/$0C/$0E/$FF | ✅ | `views`: all nine values peeked; screenshots show the wing, tail and city in the expected directions |
| The view key does not move the control | ✅ | `views`: $0AAB/$0AAE/$0AB0/$0AA3 unchanged; B without the prefix → elevator +4 |
| 🆕 The view capture resets the selected item | 🆕 | `views`: $FC = 0 after each pair |
| '4' radar: $0836 = 1, $FC = 2 | ✅ | `radar` |
| ',' / '.' halve / double the map height | ✏️ | `radar`: **',' doubles** the 24-bit height $0889-$088B ($03FFFF → $0FFFFF after two presses: zoom out) and **'.' halves** it (zoom in; the low five bits are set again) |
| '5' leaves radar | ✅ | `radar`: $0836 = 0; $FC stays 2 |
| Down view | ✅ | `views` on the ground: the window is all background blue; `war` airborne: green ground with the aircraft cross (bombsight) |

## Panel switches

| Claim | Status | Evidence (session `switches` unless noted) |
|---|---|---|
| L toggles lights $0AB5 ('1'/'O') | ✅ | $FF → 0 → $FF; label LIGHTS-0 / LIGHTS-1 |
| RETURN = magneto/mixture prefix ($FC = 3) | ✅ | $FC = 3 after RETURN |
| Digits 1/2/4/5 after RETURN = OFF/R/BOTH/START; 3 = L without RETURN | ✅ | $0AB6 = 0/2/3/4, 3 → 1 with $FC = 0; labels MAGS-O/R/L/B/S |
| 🆕 R and L give the same switch bits | 🆕 | both set $EE14 = 1, $EE15 = 0; only the label $0AB6 differs (BOTH: 1/1, OFF: 0/0) |
| 🆕 OFF does not stop the engine outside reality mode | 🆕 | RPM $09BE stays $0D for 5 s with the magnetos OFF |
| START reverts to BOTH once the engine runs | ✅ ✏️ | only when the engine was stopped: `failures` (reality mode) START → BOTH after ~2 s with $09C9 = 1; with the engine already running (`switches`) START stays |
| Mixture $0A9A: RETURN then ',' raises, '.' lowers (0..7) | ✅ | ',' ×3 → 3; '.' ×4 → 0 (clamped) |
| CTRL+I toggles carb heat $0AA9 (CH/HT) | ✅ | 0 → $FF → 0; the cell turns orange with 'HT' |
| CTRL+F: $FC = $10 (fuel tank); '.' / ',' move $09C6 | ✅ | '.' → 1 (right, clamped), ',' ',' → 0 |
| CTRL+B clears $09CE-$09D1 | ✅ | `switches` only shows the key running (the bytes are already zero on the runway). Scratch test: $09CE-$09D1 poked to $12 $34 $56 $78, CTRL+B → all zero |
| CTRL+D sets the DG offset $08C0 from the compass | ✅ | $08C0 = $08C5 − $70/$71 + $0848 + $0846 ($2B37). `switches`: 0 on the runway, where the compass and the view heading agree. Scratch test: $08C0 poked to $005A, then CTRL+D at frame ~5140, while the compass is still settling after the start → $08C0 = $08C5 = $0854 |

## Radios (`radios`, `atis`, `ils`)

| Claim | Status | Evidence |
|---|---|---|
| CTRL+C: $FC 4 (MHz), quick repeat → 5 (kHz) | ✅ | 124.85: '.' ×2 → 126.85; kHz '.' ×3 → 126.**00** |
| COM kHz wraps without carry; MHz 118-135 wraps | ✅ | .85 → .00 keeps 126; ',' ×4 from .00 → .80; MHz 126 → 118 → 135 |
| Third quick CTRL+C increments $0937 (COM search) | ✅ (code) | `keyComSelect` path; `atis` shows $0937 = 1 after tuning and 0 once the record matched |
| CTRL+N: $FC 6/7; '1'/'2' pick NAV1/NAV2 ($0AB7) | ✅ | NAV1 110.00 → 112.00; '2' → $0AB7 = 2; NAV2 111.35 → 114.35 → 114.25; MHz wraps 108 → 117 |
| CTRL+V: $FC = $0C; OBS in 2° units, wraps at $B4; '1'/'2' pick OBS1/OBS2 | ✅ | OBS1 '.' ×5 → 5 (010°/190° on the CDI); OBS2 ',' ×3 from 0 → $B1 (354°/174°) |
| CTRL+T (not slewing) and CTRL+X: transponder digits $FC 8-$0B, octal | ✅ | 1200 → 2200 → 2400 → 2407 (',' wraps 0 → 7) |
| A: ADF digits $FC $0D-$0F, then $10 (fuel tank) | ✅ | A, A A, A A A, A A A A → $0D, $0E, $0F, $10 |
| ADF digits change only with ADF ENABLE ($09AA) | ✅ | '.' leaves 287 while $09AA = 0 |
| LEFT SHIFT = ADF select (code $01) | ✅ | after RETURN ($FC 3), LSHIFT → $FC = $0D |
| 🆕 NDB reception | 🆕 | ADF 332 kHz → $E7F3 = 1, station at $0927-$092E = X $00D6, Z $02E8 (19 km SW of Meigs); the ADF gauge replaces the NAV2 OBI and points SW; NAV2 readout → 'ADF 332' |
| 🆕 ATIS | 🆕 | `atis`: COM 121.30 (Meigs Field ATIS record; the Chicago data also holds Midway 128.05, O'Hare 135.15, Kankakee 123.00) → $0939-$0940 loaded, $0958 → the text, the teletype clears the window and types the broadcast (Zulu time = local + 5, visibility, temperature, wind, altimeter, landing runway 36) in ~450 frames, once per tune; then the view returns |
| 🆕 ILS and markers | 🆕 | `ils`: Champaign localizer 109.10 (block 52) gives the CDI 'TO' flag and DME; the outer marker box (east 109-115, north −18..−12) starts sound state 5 and lights the O lamp ($7E7B = $EB); the middle marker box (east 85-87, north 9-11) starts state 6 and lights M ($7E7C = $AB). **No scenery record on the disk stores the inner-marker flag $084A** (the disk holds `25 4C 08` and `25 4E 08` stores, but no `25 4A 08`), so no approach ever sounds it. ✏️ All three markers do sound once at every start: the cold image holds 1 in $084A, $084C and $084E, and $3EFC consumes one flag per pass, so the outer, middle and inner tones and lamps follow each other right after the first main-loop passes (scratch run: outer at frame ~4930, middle ~5010, inner at 5085 with $0E59 = 7 and $7E7D = $1B). That is why `idle` already executes the inner-marker branch $3F1B |

## Pause, database info, course plotter

| Claim | Status | Evidence |
|---|---|---|
| P / RUN/STOP pause via $2250 ($08CC = 1) until any key, which is consumed | ✅ | `pause`: clock $091A and airspeed frozen for 600 frames; B ends the pause and the elevator stays 0 |
| CTRL+E: $0E87 → overlay 4 lists the databases and waits for a key | ✅ | `database`: CHICAGO, LOS ANGELES, SEATTLE, NEW YORK; $A7E0 = $A878; clock frozen; then the flight overlay and the Chicago area are reloaded (~1400 frames) |
| Q: menu A-E via $2250 | ✏️ | `plotter`: the menu **stays up after A/B/C/D**; E returns to flight. C restarts the recording (pointer back to $D016 + new records) |
| Recording writes display-list records at $D000 | ✅ ✏️ | a scenery display list: op 07 origin with scale 6 (normal; 4 for precision) and the 12 position bytes $5A-$65, op 1C, op 01 moveto (0, 0, 0) and the end marker $79 at $D016; then 7-byte lineto segments `02 dx dy dz`; pointer $0E83 grows $D016 → $D047 in about 66 s (frames 5172-9120); $08BC = 2 |
| B displays the plot | ✅ | `plotter`: the recorded track is drawn as a white polyline in the radar view |

## Editor and modes (`editor`, `library`, `slew`, `night`, `clouds`, `failures`, `crash`, `demo-loop`)

| Claim | Status | Evidence |
|---|---|---|
| E opens the editor (text mode, page 0) | ✅ | text dump: SIMULATION CONTROL / AIRCRAFT POSITION; the first entry loads overlay 1 from disk (~680 frames); border 8 |
| Page 0 has 19 fields, page 1 21 fields | ✅ | descriptors at $B020/$B05A; page 1 shows TIME HOURS ... ADF ENABLE |
| RETURN = next field | ✏️ | **RETURN moves the cursor one screen line** ($094D += 2): 21 stops per page (lines 1-21), including the blank line 8 and the AIRCRAFT POSITION heading (line 9) on page 0. After line 21 it switches page. '-' moves one line up; from line 1 it goes to **page 1, line 21** (ADF ENABLE) |
| Typed digits are accepted by RETURN, '-' or E | ✅ | HEADING 90 → $0A13 = $4000, DG 090/270 |
| 🆕 Regular flight does not start in mode 0 | ✏️ | a regular start shows 08:00, COMMUNICATION RATE 200, shear 0 (the cold image); '+' then loads built-in mode 0: 12:00, throttle 0, comm rate 128, shears 3000/6000/9000 ft |
| 'S' saves as user mode $0963+10 | ✅ ✏️ | it also **makes that the current mode**: $0963 = $0A, so a later '+' recalls mode 10 (throttle $38 → $30 restored) |
| USER MODE 0-24 recalls; 110-124 saves to n−100 | ✅ ✏️ | USER MODE 0 + E: the editor redisplays mode 0 and **stays open**; a second E exits (12:00, heading 0). USER MODE 111 saves user mode 11 and selects it |
| S / '+' inside the editor | ✅ | `library`: S → mode 10 saved, $0963 = 10; '+' recalls |
| CTRL+X loads the library (block 64) into $C800 | ✅ | `library`: on the master disk block 64 is overlay 4, so $C800 receives its bytes (starting with its end word $A878) |
| CTRL+Z formats and writes block 64 | ✅ | `library`: completes (the lab's 1541 formats its in-memory copy of the image) |
| SLEW = 1 → $3660 integrator, NORTH/EAST readouts | ✅ | `slew`: $0966 = 1; window shows 'NNNNN NORTH' and 'NNNNN EAST' (17188 → 17190, 16671 → 16673) |
| Slew keys | ✅ | `slew`: ';'/COLON altitude rate $0AC5 ±; T/B north/south (elevator); H/F east/west (ailerons); 9/8 pitch $0AC3 ±1; R bank $0ABF; V heading $0AC1; G zeroes all rates; Z zeroes $6C-$71; CTRL+T copies the view angles back (pitch $F800 → γ $0800, heading $FC00) |
| TIME HOURS 22 → night palette | ✅ ✏️ | `night`: $083C 1 → 4; **$0880-$0882 = 0** so the window shows the background (gray) with dotted city lights; border black |
| B at the display prompt (B&W) | ✅ ✏️ | `bw`: $0E61 = $FC, $0E63 = $0E65 = $CB, $0E69 = 0, as documented. Only the window turns gray; the panel keeps its colors. Time-of-day state $083C: 19:00 and 06:00 → 2 (dusk/dawn, $0880/$0881 = $22, $0882 = 0: gray sky, black ground); 20:00 and 05:00 → 4 (night, all 0) |
| 🆕 Lights at night | 🆕 | `night`: L off → enable masks $0945-$0947 = $10/$80/$01: most instruments vanish; their pixels are saved in $C000-$C7D3 and $FF80-$FFDE and restored when L is pressed again |
| Clouds | ✏️ | `clouds` (layer 1700-2100 ft): below the layer $0880/$0881 = $FF (white sky), inside it the window is white, above it $0880/$0881 = $77 and $0882 = $FF (white deck). The fill selectors depend on the altitude as well as the time of day: the area lists choose the palette words by `$0830` and `$083C` (`display.md`) |
| Mode record holds display values | ✏️ | in flight the record holds internal values: cloud tops/bottoms in **feet** ($098A = 2100), shear zones in **meters** ($098E = 914 for 3000 ft), wind directions as binary angles ($D556 for 300°), wind = knots (low) + turbulence (high) |
| Wind | ✅ | `clouds`: drift $09D3 ≠ 0 once airborne |
| REALITY MODE + RELIABILITY 0 → failures | ✅ ✏️ | `failures`: 'AIRCRAFT PROBLEM !!!!' about every 50 s while parked; $0942 loses bits 3, 7, 5 (altimeter, VSI, NAV1 vanish); $09BF = 3; DG drift $08C0 += 2 per check. 🆕 The editor exit in reality mode leaves the **magnetos OFF and the engine stopped**; RETURN 5 (START) starts it |
| Crash: VS high byte ≤ −9 at contact | ✅ | `crash`: $0834 = 4 with $0A51 = $E7; 'CRASH !!!'; the reload loads **mode 0** (12:00), not the cold state |
| Splash | ✅ | `splash`: taxiing east off Northerly Island ($50DE = $55, $0834 = 8) and gliding onto the lake 1 km east of Meigs (touchdown VS −1.9 m/s); 'SPLASH !!!'; reload |
| 🆕 Stall warning | 🆕 | `stall`: AoA $09DD ≥ $21 → sound state 1 and the red lamp ($7E3D/$7E3E = $12); $0E7B = $0E counting down after the stall; the aircraft drops and crashes |

## Demo and restart

| Claim | Status | Evidence |
|---|---|---|
| A at the mode prompt → mode 2 self-flying takeoff | ✅ | `demo-loop`: $095A = 1, $0963 = 2, 10:17, throttle $7D, elevator $18 |
| Crashes reload mode 2, so the demo repeats | ✅ ✏️ | the demo climbs away in a slow turn and crashes only after **~100,000 frames (28 min)**; mode 2 reloads (10:17 again) but **$095A = 0** after the reload (it is copied from $095B, which the first exit cleared) |
| Any key clears $095A | ✅ | `demo-key`: during the first demo flight $095A = 1, '5' → $095A = 0 (the dispatcher's store at $27DD). `demo-loop`'s final key cannot show it, because $095A is already 0 after the reload |
| RUN/STOP + RESTORE restarts | ✅ | `restart`: with RUN/STOP in slot 3 ($089E = $3F) the NMI sets $26FF = 1 and jumps to $A7E2; the title and both prompts come back; the reload clears $26FF |
| RESTORE alone does nothing | ✅ | NMI with no key, or with L in slot 3: $26FF stays 0, flight continues |

## Joysticks (`joystick`)

| Claim | Status | Evidence |
|---|---|---|
| Port 2 up/down = throttle | ✅ | 120 frames up → $58 (11 steps at 5 Hz) |
| Port 1 up/down = T/B without acceleration | ✅ | down 24 frames → +12 (3 × 4) |
| Port 1 left/right = F/H with auto-centering | ✅ | right → ailerons 4, rudder 4; $0E78 is set to 3 and shifted right at 5 Hz (peeked as 1 one tick later); centered 60 frames later |
| Port 1 fire = '5' | ✅ | $FC = 1, then H → right view |
| Port 2 fire = guns | ✅ | no effect outside war mode |

## Europe 1917 (`war`, `war-hook`)

| Claim | Status | Evidence |
|---|---|---|
| EUROPE 1917 forces mode 7 and loads the war overlay | ✅ | $0969 = 1, $0963 = 7, $A7E0 = $B1EA, WWI area block 48 ($0900 = $30); mountains and the gunsight |
| W declares war; 'WAR !!!!' with a delay | ✅ | $0ACC 1 → 3 |
| SPACE fires when airborne | ✅ | ammo $0AA5 100 → 82 while held (one shot per repeat) |
| X drops a bomb ('5' → '4') | ✅ | $08E8 $35 → $34; whistle |
| Enemies dormant until the player enters a box | ✏️ | the "box" is one corner: an enemy wakes (state 1 → 2) when the aircraft is **west of** record[11..12] **and north of** record[13..14]; it falls back to dormant east of record[15..16] or south of record[17..18]. Flying west from the base wakes enemies 1 and 4 at east < $DD00 and 2 and 5 at < $DCFA. Only enemy 4's zone includes the base |
| Enemy pursuit, ENEMYFIRE, hits, IN RANGE, kills | ✅ | the session places enemy 4 with pokes (an experiment; see the session comment): above the flight path it shows 'IN RANGE' and is shot down (score 1, kills $08B2 = 1); level with the aircraft it fires ('ENEMYFIRE', hits $08B7 → 9, damage $09BF = 4) |
| Rotating AMMO/SCORE/BOMBS/HITS line | ✅ | screenshots |
| 🆕 R in war mode ($FD00 hook) | 🆕 | `war-hook`: the main loop calls $FD00 and runs into zeros: 377 BRKs ($FD00, $FD02, ... $FFF0: 320 in $FD00-$FF7F, 48 in $FF80-$FFDF, 9 in $FFE0-$FFF0), each through $FFFE → $2285, then the residue bytes at $FFF2 act as a call of $20D5. Measured: SP at $204B drops by 4 per R ($3F → $3B → $37) and the jiffy counter $34 advances by ~180 extra. The port treats the call as a documented no-op, so it deliberately does not match the original there (`excluded.md`). ⚠️ The chain runs through $FF80-$FFDF, which is an instrument save buffer (see below): after the lights were switched off at night or a failure blanked an instrument, those bytes hold saved panel pixels and R in war mode executes them as code, so the result then depends on the panel state |
| 🆕 Splash in the WWI area | 🆕 ✏️ | scratch run: taxiing straight ahead (north, heading 0) from the base with a little throttle reaches water about 22 high-word units (≈ 5.6 km) north: $0834 = 8, $50DE = $55, 'SPLASH !!!'. (A run that turned toward the south-east found no water within 200 s.) |
| 🆕 The editor cannot move the aircraft in war mode | 🆕 | scratch run: with EUROPE 1917 = 1, HEADING 270 typed in the editor is discarded: the exit loads mode 7 again ($0963 = 7) and $0A13 = 0 |

## Other findings

- 🆕 $0ACF (the last byte of the flight variables) is a bare return that the editor exit calls
  (`editorExitHook`), and the editor also reads its opcode as data: ($60 & $1F) − $10 = −16 becomes
  the ATIS temperature offset $095F.
- 🆕 $C000-$C7CF (the dead debug monitor) and $FF80-$FFDF (zero, called free space) are the save
  buffers of the instrument-mask code ($F35E-$F521): the failure-graphics records at $F2E6 point
  each instrument's buffer there (`night` with the lights off writes and reads back $C000-$C7D3,
  $FF80-$FFBF and $FFCF-$FFDE). The port must keep these bytes. (An earlier reading had the
  scenery area lists running past $C000 into these buffers; they do not: the loader's `$7327`
  guard drops every byte a load would store at $C000 and above, `scenery-3d.md`.)
- 🆕 The cold-start title shows the panel with the image's own readouts (COM 132.00, NAV1 108.30,
  XPDR 2600, clock 20:08:52) until regular flight sets the real ones. The two rows that modified
  copies overwrite are blank.
