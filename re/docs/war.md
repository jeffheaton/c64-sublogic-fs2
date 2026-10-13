# Europe 1917: the war overlay

The WWI war game is overlay 2: logical blocks 158-160, loaded at $A7E0 with its end word $B1EA
(the scenery root block 66 follows at $B1EA). EUROPE 1917 = 1 in the editor (record +05, `$0969`)
forces built-in mode 7, the WWI area (block 48) and this overlay. The main loop then calls the
overlay slot `$A7EE` (a jump to $AA03) once per pass in its draw sequence while `$0969` ≠ 0
(the test and call at $20F9-$20FE): after `updateLightingMasks` ($EBA5), before
`drawViewOverlay` ($ED3C).

Everything in $AA03-$B1E9 is code; there is no embedded data. The overlay works on its own bytes
($A800-$AA02) and on a few resident variables. This document is the specification the port
(`Sources/FS2Core/Modes/War.swift`, `WarEnemies.swift`, `WarGuns.swift`) follows; names are in
`re/symbols.json` (overlay `war`).

## Memory

### Resident variables

| Address | Name | Use |
|---|---|---|
| `$0969` | `europe1917` | War mode (the main loop calls the slot only while it is set) |
| `$08D6` | `warStarted` | 0 until the first `warMain` pass; the editor exit clears it |
| `$0ACC` | `warDeclared` | W (`keyDeclareWar` $2AD5) ORs 1; a bomb on a target ORs 1; the status pass turns 1 into 3 |
| `$0AB2` | `gunBurst` | `fireGuns` ($2C03: SPACE airborne, joystick 2 fire) stores 3 when there is ammunition |
| `$0AA5/$0AA6` | `ammo` | Rounds: 100 at rearm, −1 per burst pass, held at 0 |
| `$0AA7/$0AA8` | `bombCountdown` | Bomb impact countdown (see Bombs) |
| `$0872` | `bombTargetScore` | Points of the target under the aircraft, stored by the WWI scenery |
| `$08E8` | `bombCount` | Bombs left as an ASCII digit (X: `keyDropBomb` $2B79); inside the BOMBS record |
| `$08B2` | `killCount` | Enemies shot down |
| `$08B7` | `hitsTaken` | Times the aircraft was hit |
| `$08B8` | `serviceCount` | `serviceAircraft` $3638 and the first pass increment it; `warServiceCheck` consumes it |
| `$08D1/$08D2` | `warScore` | Score, back to 0 at 1000 |
| `$08D4` | `damageLevel` | +1 per hit at the top damage threshold |
| `$09BF` | `engineFailureBits` | Bits 0-1 cap the RPM, bits 2-3 leak fuel (the engine model, `flight-model.md`) |
| `$0ACA`, `$0836` | view, radar | The gunsight, the tracers and the in-sight test depend on the front view |

The editor exit resets the war counters (`$0AA5` = 100, bombs '5', and 0 into `$0ACC`, `$08D6`,
`$08B2`, `$08D4`, `$0AA7` (the low byte only) and the score) and calls `$200F`
(`serviceAircraft`, which clears the hits and failures and increments `$08B8`).

### Overlay state ($A800-$A83A)

| Address | Name | Use |
|---|---|---|
| $A800 | `enemyOffset` | Record offset of the enemy being updated; every helper reloads X from it |
| $A801 | `warLoopIndex` | Gunsight line offset (+4), and the row of the panel fills |
| $A802/$A805/$A808 | `deltaEast/Altitude/North` | 24-bit target − enemy, in meters (`enemyDelta`) |
| $A80B/$A80C | `enemyRange` | Approximate 3D range (`enemyDistance`) |
| $A80D | `rangeOverflow` | 0 when the three delta top bytes XOR to 0 or $FF, else $7F |
| $A80E/$A810 | `scopeAcross/Along` | The delta rotated by the heading (`plotEnemyScope`) |
| $A812/$A814 | `headingSine/Cosine` | Q15 sin and cos of `$71` |
| $A816 | `enemyFired` | 1 when an enemy fired this pass |
| $A817 | `inRangeFlag` | 3 when an enemy is in the gunsight box; also the gunsight's pen |
| $A818/$A819 | `rotationTimer/Index` | The rotating line (every 4 status passes) |
| $A81A | `statusShown` | 0 blank, 1 IN RANGE, 2 ENEMYFIRE |
| $A81B | `targetsBombed` | Bombed targets (never read) |
| $A81C, $A828 | `enemyBaseA/B` | The two enemy bases, laid out like the aircraft position `$5A-$65` |
| $A834-$A837 | `tracerSlot`, `tracerCursor`, `tracerTimer`, `gunSide` | The tracers |
| $A838 | `enemyShapeIndex` | Shape 0 (far) ... 4 (near) |
| $A839/$A83A | `enemyScreenX/Y` | The enemy dot's projected point A (`$D3/$D4`) |

### Tables and lists

| Address | Contents |
|---|---|
| $A83B, $A849, $A857, $A865 | Status records at (114, 117): 'WAR !!!!', 'IN RANGE', 'ENEMYFIRE', blank; each is a one-record list (14 bytes with its 00 00 end) |
| $A873, $A881 | 'AMMO :000' and 'HITS :000' at (171, 117); digits at $A87B and $A889 |
| $08DF, $08ED | The BOMBS and SCORE records (resident); the score digits at $08F5 |
| $A88F | `warRotationPointers`: AMMO, SCORE, BOMBS, HITS |
| $A897 | `enemyDotList`: op 24 (origin, scale 4, high words 0), op 00 (dot) with the point at $A8A0-$A8A5, END |
| $A8A7 | `gunsightLines`: 6 × (y1, x1, y2, x2) into `$EC`, `$EB`, `$EE`, `$ED` |
| $A8BF | `tracerRecords`: 14 × 6 bytes, then the age byte $FF at $A914 ending the list |
| $A915, $A91A | `enemyShapeOffsets` (5) and `enemyShapes`: a line count, then (dx1, dy1, dx2, dy2) per line |
| $A95B | `enemyRecords`: 6 × 28 bytes |

### The enemy record (28 bytes)

| Offset | Meaning |
|---|---|
| +0, +3, +6 | East, altitude, north: 24-bit meters (bytes 1-3 of the aircraft's 32-bit axes) |
| +9 | Scope row while the enemy shows on the panel scope, else 0; it fires only while nonzero |
| +10 | In-sight flag: 3 in the gunsight box (front view), the view number in another view, else 0 |
| +11, +13 | Trigger east, north (16-bit, compared with the high words `$5C/$5D`, `$64/$65`) |
| +15, +17 | Attack zone east, north |
| +19, +20, +21 | Steps per pass: east, altitude, north |
| +22 | Fire range (meters, low byte) |
| +23 | State: 0 shot down, 1 dormant, 2 attacking (any value but 0 and 1 attacks) |
| +24, +25 | Cooldown after firing, and its reload |
| +26 | Pointer to the enemy's base ($A81C for enemies 0-2, $A828 for 3-5) |

All compares on the triggers and zones look only at the sign of the high byte's subtraction (no
overflow correction): the aircraft is "west of" a value when `$5C/$5D` − it is negative.

## The pass (`warMain` $AA03)

1. First pass (`$08D6` = 0): `$08D6` = 1, `warFirstPass`, `addWarScore(0)` (prints the score),
   `$08B8` + 1.
2. `warServiceCheck`, `drawWarScope`, `gunsAndTracers`, `bombImpact`.
3. With `$0ACC` ≠ 0: `enemyUpdate` for X = 0, $1C, $38, $54, $70, $8C.
4. In the front view (`$0ACA` = 0) outside the radar (`$0836` ≠ 1): the gunsight, `setPen($A817)`,
   then the six lines of $A8A7 (loop index in $A801).
5. `warStatusLines`.

Cycle costs measured on the lab's flat bus (the test states): about 26,800 per pass before war is
declared, 46,700 for the first pass, 65,000-91,000 in the front view once war is declared (the
six enemies, the tracers after a burst), 46,000-58,000 in other views and on the radar, and
403,000 for the declaration pass (busy wait included).

### First pass (`warFirstPass` $B13E)

`$FE` and `$09A7` lose bit 7 (the radios go dark: the instrument enable masks). Span color 0
(`$8024`), then rows $71-$AF are filled from x $9F leftward over 44 pixels (A = $2B through
`$801B`, the row pointers from $0200/$02C8). The 8 × 11 cells from $7E4D (rows of 40) get color
$10: a black status panel over the radio stack.

### The panel scope (`drawWarScope` $B0FC, `plotEnemyScope` $AD21)

Every pass clears rows $78-$AA over 45 pixels ending at x $9F (A = $2C, span color 0) and writes
the aircraft mark: $30 into $5656, $5790, $5791; $FF into $5657; $FC into $5792; 3 into $564F.

`plotEnemyScope`, for the enemy being updated, runs only when the east and north delta top bytes
are equal or complementary (their XOR is 0 or $FF). Then, with h = `$71`:

- `$A812` = sin8(h), `$A814` = cos8(h) (`$18BD`/`$18B8`); across = e·cos − n·sin into `$A80E`,
  along = n·cos + e·sin into `$A810`, each product through `mulQ15AX` with the multiplier in
  `$C4/$C5` (e and n are the delta low words).
- v = across × $0176 (Q15): its high byte must be 0 or $FF and its low byte −22..20 (signed compares
  of the low byte only). x = `~v + $8A + C`, C being the carry of the compare with $EA: $8A − v for
  v < 0, $89 − v otherwise.
- w = along × $01A3: its low byte must be −25..24; its high byte is never checked (the branch at
  $ADEC follows a branch on the opposite outcome of the same compare and cannot be taken). The row
  is w + $92.
- The row is stored in rec+9; a pen choice by the altitude delta ($AE01-$AE29) is overwritten by a
  constant 3 (only its cycles remain); the dot is plotted with pen 3 (`$800C`).
- Any failed test stores 0 in rec+9.

### Enemies (`enemyUpdate` $AA84)

1. `$A800` = X. State 0: return.
2. **Dormant (1).** It attacks (state 2) when the aircraft is west of the trigger east and not
   south of the trigger north. The delta is taken toward its base (`[rec+26]`).
3. **Attacking.** It goes dormant (and returns at once) when the aircraft is not west of the zone
   east or is south of the zone north. Else the delta is taken toward the aircraft (`$5A`), and
   when the enemy is on the scope (rec+9 ≠ 0), `rangeOverflow` and the range high byte are 0 and
   the range low byte is below rec+22, it **fires**: `$A816` = 1, cooldown = reload, `$08B7` + 1,
   `printHitsTaken`, `warDamage`.
4. **Motion.** With a cooldown: it counts down; bit 7 clear afterward → climb 1 m (24-bit
   increment); bit 7 set → on odd passes (`$22` bit 0) sink 1 m with a subtraction **that does not
   set the carry first**: the borrow chain starts from the carry the path left (the last subtraction
   of `enemyDelta`, the final add of the second `stationDistance` in `enemyDistance`, the carry of
   `warDamage`, or set where the branch at $AAFC was taken), and an altitude that reaches 0 is put
   back to 1. Without a cooldown each axis (altitude, east, north, in that order) steps by its step
   toward the sign of the delta's top byte (24-bit add or subtract).
5. **The dot.** The low words of east, altitude and north go to $A8A0; `$8B/$8C` = $A897; pen 3;
   the list runs through `$8006` (the scenery interpreter: op 24 sets the origin, op 00 draws the
   dot when its outcode is 0). `$A839/$A83A` = `$D3/$D4`.
6. The delta toward the aircraft again, `plotEnemyScope`.
7. When the dot is in view (`$CC & $0F` = 0): `enemyDistance`; range $400+ → nothing more; the
   shape is 0 at $200+, 1 at $100+, 2 at $80+, 3 at $40+, else 4. For shapes 1-4 the in-box test
   x $46-$5A, y $2A-$46 gives Y = 1. `drawEnemyShape`. Dormant enemies stop here (flag 0) while
   the aircraft is below 256 m (`$61` = 0 and `$60` − 1 negative). Then rec+10 = the view number
   in another view, 3 (and `$A817` = 3) when in the box, else 0. Out of view or too far: 0.

`drawEnemyShape` ($ACC5) sets pen 3 and, when the position lies in x 4-$9A, y 4-$6A, draws the
lines of the shape (offsets added with 8-bit wrap) through `$8009`.

`enemyDelta` ($B0A3): `($A5),Y` with Y = 1-3, 5-7, 9-11 minus the record's three axes, three
24-bit subtractions into $A802-$A80A; leaves Y = 12 and the borrow of the north top byte in C.

`enemyDistance` ($B04C): `$09BA/$09BC` = the east and altitude delta low words, `$3F38`
(`stationDistance`, `radios.md`); then `$09BA` = that and `$09BC` = the north low word, `$3F38`
again; `$A80B/$A80C` = `$C0/$C1`; `$A80D` as above; X = `$A800`.

### Guns (`gunsAndTracers` $AEED)

- **Burst pass** (`$0AB2` ≠ 0): `$0AB2` − 1; `spendRound` ($B01D: ammo − 1 held at 0, then
  `printAmmo`); `$A836` = 25; the slot `$A834` + 6, $54 wrapping to 0; the record gets age = its
  byte 0 (the start age $0F), x = $27 or $77 by bit 0 of the incremented `$A837`, y = $6F.
- **Timer:** `$A836` − 1; at 0 it is put back to 1 and the routine returns: the tracers are only
  walked during the 25 passes after a burst.
- **Walk:** each record with a nonzero age until the age $FF: age − 1. When the age (before the
  decrement) was below $0B, the first enemy with rec+10 ≠ 0 is **shot down**: state and rec+10 =
  0, `addWarScore(1)`, `$08B2` + 1. Then x += (target x − x) >> 2 and y likewise (8-bit
  difference, shifted right twice keeping its sign), pen 3
  and, in the front view outside the radar, a dot at (x, y) through `$800C`.

So a tracer can only score from its sixth walked pass on, and only against an enemy that was in
the box on the previous pass (rec+10 is updated after the guns). The gun sound comes from
`fireGuns` (`input.md`) → `sfxGun` ($CCD1, `sound.md`).

### Bombs (`bombImpact` $AFB9)

X (`keyDropBomb`) decrements `$08E8` and starts the whistle (`sfxBombRelease`; the explosion is
the sound driver's state 10, `sfxBombWait`). The overlay's part is the countdown:

- While `$0AA7/$0AA8` ≠ 0: A = (`$0AA8` | `$0AA7`) − $32 into `$0AA7`, `$0AA8` − 1 on the
  borrow, and `$0872` = 0.
- When `$0AA8` becomes $FF the bomb lands: with `$0872` ≠ 0 `addWarScore($0872)`, `$A81B` + 1,
  `$0ACC` |= 1 (bombing declares war); the countdown becomes 0.

The WWI detail lists store `$0872` with op 25 behind op 13 range boxes around their targets
(blocks 49 and 50: three targets of 20 points, two of 10), so it holds the points of the target
the aircraft is over. **No code and no display list on this disk stores a nonzero
countdown**: the only writers of `$0AA7/$0AA8` are this routine and the editor exit (which clears
`$0AA7`). A byte scan of the whole disk image finds the address `$0AA7` only in the editor exit's
store and in this overlay, and `$0AA8` only in this overlay. On this disk bombs never score;
the lab `war` session confirms that nothing but $AFB9 touches the pair. Since only the countdown
clears `$0872`, it keeps the points of the last target box the aircraft flew through. The port
keeps the routine as it is.

### Damage (`warDamage` $B19E)

Called after each hit with Y = `$08B7`. With fewer than 4 kills: 60+ → `$08D4` + 1 and bits 0-1;
40+ → bits 0-1; 35+ → bit 1; from 20 on also bit 3 when `$22` < $3F; from 7 on bit 2. With 4
kills or more the steps are 20 (top), 7 (bits 0-1) and 1 (bits 3/2). The bits are ORed into
`$09BF`. The carry it returns ($22 ≥ $3F when bit 2 was set, else clear) feeds the sink step.

### Score, ammunition, hits

- `addWarScore` ($AFEE): score += A; when the 16-bit score is 1000 or more it becomes 0 (a 16-bit
  compare with 1000 on the new bytes); printed into $08F5 through `$2033` (`format3Digits`).
- `printAmmo` ($B03A) → $A87B, `printHitsTaken` ($AE63) → $A889 (leaves X = `$A800`).
- `warServiceCheck` ($AE44): when `$08B8` ≠ 0 (after `serviceAircraft` or the first pass):
  `printAmmo`, `printHitsTaken`, `$08B8` = 0, all six enemies dormant (state 1; shot-down enemies
  return).
- **Rearm** is the flight model's `$3614` (inside `densityAndAutoLevel` $35BD): with the
  service request `$0838` = 2 and the airspeed high byte 0, `serviceAircraft` (tanks, masks,
  hits and failures cleared, `$08B8` + 1), ammo 100 and bombs '5'.

### Status lines (`warStatusLines` $AE77)

1. `$A817` is shifted right; a set bit 0 → 'IN RANGE' (choice 1). Else `$A816` is shifted right; a
   set bit 0 → 'ENEMYFIRE' (choice 2). Else blank (choice 0). The record is drawn (`drawTextList`
   $1E99) only when the choice differs from `$A81A`. Since `enemyUpdate` stores 3, the gunsight is
   white on that pass, pen 1 on the next, and IN RANGE stays for two passes.
2. `$A818` − 1: at 0 it is reloaded with 4, `$A819` + 1 and the record `$A88F[($A819 & 3) · 2]`
   is drawn.
3. `$0ACC` = 1: `$0ACC` = 3, 'WAR !!!!', then a busy wait of 256 × 256 empty loop steps: 328,707
   cycles (about 19 frames) during which the main loop stands still.

## Port

| Original | Port (`extension Machine`) |
|---|---|
| $A7EE | `slotWar()` (3 cycles + `warMain`) |
| $AA03 | `warMain()` |
| $AA84 | `enemyUpdate(_ offset:)` (the step move of one axis is the private `enemyStep`) |
| $ACC5 | `drawEnemyShape()` |
| $AD21 | `plotEnemyScope()` |
| $AE44 | `warServiceCheck()` |
| $AE63 | `printHitsTaken()` |
| $AE77 | `warStatusLines()` |
| $AEED | `gunsAndTracers()` |
| $AFB9 | `bombImpact()` |
| $AFEE | `addWarScore(_:)` |
| $B01D, $B03A | `spendRound()`, `printAmmo()` |
| $B04C | `enemyDistance() -> Bool` (the carry) |
| $B0A3 | `enemyDelta(_:) -> Bool` (the carry) |
| $B0FC | `drawWarScope()` |
| $B13E | `warFirstPass()` |
| $B19E | `warDamage() -> Bool` (the carry) |

Addresses and record fields are in `enum War` (`War.Field`). The port is a literal translation
with exact cycles: every routine charges from its first instruction through its return, the
caller charges its call and the 3-cycle jump of a `$2000`/`$8000` vector. Indexed reads add the page
crossing cycle (enemy records 25-27 for X = $8C, tracer offsets from $41, shape tables). The busy
wait is charged one outer pass (1,284 cycles) at a time so the clock's events keep running.

Only the outputs the code uses are modeled: the carry of `enemyDelta`, `enemyDistance` (derived
from `$C0/$C1` < `$C2/$C3` after the second `stationDistance`, which is exactly the carry of its
final 16-bit add) and `warDamage`, which `enemyUpdate`'s sink step consumes.

**Calls into other subsystems (all ported):** `setPen`, `drawLine`, `plot`, `span`, `setSpanColor`
(raster), `drawTextList` (text), `format3Digits`, `stationDistance` (panel), `sin8`, `cos8`,
`mulQ15AX` (math), `runScenery` (scenery; a fault in the fixed dot list is a precondition
failure). **No development bridge** is used by the war code; the scenery interpreter's poll during
the dot lists runs the ported 10 Hz tick (`tick10Hz`).

The main loop's draw sequence runs the slot bytes at $A7EE while `$0969` is set
(`runOverlaySlot`, `main-loop.md`); the slot's jump to $AA03 calls `warMain()`. `slotWar()` is
the same entry as a stand-alone call (the slot's 3-cycle jump plus `warMain`).

## Tests (`Tests/DifferentialTests/WarTests.swift`, `WarEdgeTests.swift`)

The lab session in `WarFixtures.session` (C3 prefix, then EUROPE 1917 in the editor) snapshots
the entry of `warMain` at every phase: the first pass, on the ground, the declaration pass
(`$0ACC` = 1), after it, airborne (≈ 135 m, heading north), a burst, enemy 4 (record $54)
placed 600 m ahead and ≈ 110 m above in the gunsight (in-sight flag 3), its kill (score 1, frame
≈ 10273), enemy 4 placed 200 m ahead and level until it hits (frame ≈ 10439) and has hit 7
times (`$09BF` = 4, frame ≈ 10684), a bomb, the bombsight, the right view and the radar.

Every comparison is the whole memory image (stack page excluded) and the exact cycle count
against the original on the lab's flat bus (the port's 10 Hz tick reads `$DC09` from the flat
bus's RAM, as `main-loop.md` describes):

- every state once (through the slot and straight into $AA03); the first pass with random masks
  and counters; the declaration with its busy wait, and a bomb landing on a target;
- long runs of 30 passes from 12 states with the aircraft moving between passes and random
  bursts, bomb countdowns, W, view and radar changes and rearms through `$35BD`;
- dogfights: enemies placed around the aircraft (ahead, above, below, behind), 40 passes with the
  guns firing on most passes; the test checks that kills, hits, in-sight passes and damage occur;
- the rearm at the base through the ported `$3614`, then a pass;
- every routine on randomized inputs: `enemyUpdate` (all states, triggers, zones, cooldowns,
  steps, the scope, the views), the motion at 64 K edges and the altitude floor for every record,
  `enemyDelta`/`enemyDistance` with their carries and any pointer, the scope dot, the shapes, the
  guns, the counters, `warDamage` for all 256 hit counts × kills × `$22`, the status lines;
- `everyInstructionIsCompared`: with instruction traps on the original, the tests together
  execute every instruction start of $AA03-$B1E9.

`WarEdgeTests.swift` (part of the same suite) drives every compare to both sides of its exact
edge, with placements that give exact deltas, ranges and screen positions:

- `triggerAndZoneEdges`: the aircraft's high words one below, at and above each record's trigger
  and zone (equal low bytes, and the $7FFF/$8000 cases of the N-flag-only compare);
- `rangeEdgesAndOverflow`: ranges $3F-$401 across the shape thresholds (the enemy straight ahead,
  so the range is the distance), and the fire test for eleven patterns of delta top bytes
  (fires only when they XOR to 0 or $FF);
- `gunsightBoxEdges`: the enemy swept in 1 m steps through the projected columns $45/$46/$5A/$5B
  and rows $29/$2A/$46/$47;
- `dormantAltitudeEdges`: a dormant enemy in the box with `$61/$60` at the edges of the
  below-256-m test (`$61` = 0 and `$60` − 1 negative, including `$60` ≥ $81);
- `scopeEdges`: v from −23 to 21 and w from −26 to 25, heading north and south;
- `pursuitFromTheBases`: the aircraft circles inside every trigger corner near base A for 150
  passes; the six enemies attack from their bases, close in, come onto the scope and into view
  and hit the aircraft.

The suite was checked by mutation testing: of 46 one-off changes to the port (compare
boundaries, branch conditions, carries, cycle counts), 45 make it fail. The survivor drops the
page-crossing cycle of the middle-byte read on the step move's borrow path, which no record
offset (0-$8C) can cross.

## Open points

- The bomb countdown is never started on this disk (see Bombs). If an unmodified copy of the
  disk shows a writer of `$0AA7/$0AA8` (or the cracker's changes removed it), the port needs that
  writer, not a change here. One candidate place is the war-mode `$FD00` hook (R, `excluded.md`),
  which is empty on this disk; nothing links it to the bombs.
- `$A81B` (targets bombed) is written but never read.
