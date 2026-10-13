# Input: keyboard matrix, joysticks, command dispatch

The definitive specification of the original's input code and its port (`Sources/FS2Core/Input`,
`enum Input`). Every routine below is ported as a literal translation: the same bytes read and
written in the same order, the same register results where a caller uses them, and the exact
cycle count (proved by `Tests/DifferentialTests/InputHandlerTests.swift` and
`InputScanTests.swift`). Lab evidence for the behavior is in `features.md` and the sessions named
there; this document folds in its verified facts.

Input is modeled in two layers:

1. **Matrix layer (Mac-specific, `FS2App`).** Mac keys map to C64 matrix positions and gamepads
   to joystick bits in `io.keyboard` (`KeyMatrix`). See "Mac key mapping" at the end.
2. **Original logic (ported exactly).** Everything after the matrix: the CIA sampling and the
   joystick arbitration, scan and repeat timing, the held-key slots and the ring, the CTRL −$40
   rule, the code table $2482, the dispatch through $2718, the selected item `$FC`, the
   quick-repeat window `$091C`, and every handler.

All control arithmetic and clamping is 8-bit integer and feeds the flight model.

## Port map

| Range | Routines | Port (`extension Machine`) | File |
|---|---|---|---|
| $2250-$2284 | wait for key | `waitForKey() -> UInt8` | `Dispatch.swift` |
| $2418-$2471 | matrix scan | `keyScan()` | `KeyboardScan.swift` |
| $2472-$24C1 | row masks, column selects, code table | read from memory (`Input.Table`) | |
| $24C2-$2504 | new press, re-queue | `keyPress(_:)`, `requeueKey(_:)` | `KeyboardScan.swift` |
| $2505-$2573 | release check, joystick latch $2557 | `keyReleaseCheck()`, private `joystickLatch(y:)` | `KeyboardScan.swift` |
| $2574-$25C3 | CIA1 sampler | `sampleCia1(column:) -> (joystick, x, y)` | `KeyboardScan.swift` |
| $25C4-$25EA | the ring | `dequeueKey() -> (code, carry)`, `enqueueKey(_:)` | `KeyboardScan.swift` |
| $2688-$26EB | joystick actions | `joystickAction()` | `Joystick.swift` |
| $26EC-$26F8 | auto-centering | `autoCenter()` | `Joystick.swift` |
| $26F9-$26FE | unreachable code that coordinates the rudder and the ailerons ($2DD2, $2E38) | not ported | |
| $2700-$2714 | RESTORE NMI | `restoreNmi() -> Bool` | `KeyboardScan.swift` |
| $2718-$27D7 | handler table | read from memory | |
| $27D8-$2800 | dispatcher | `dispatchKey()` | `Dispatch.swift` |
| $2801-$2E91, $2F40 | every key handler | see the command map | `CommandKeys.swift`, `SelectionKeys.swift`, `ControlKeys.swift`, `Dispatch.swift` |

`$2F40` (`keyDatabaseInfo`, CTRL-E) sits between the flight model's $2F07 and $2F45 but is a
key handler; it is ported here.

### Entry points for the game program (the IRQ and the 10 Hz tick; `main-loop.md`)

| When (original) | Call | Site |
|---|---|---|
| Frame IRQ, keyboard phase `$08A6` = 0 after its count down | `keyScan()` | the call at $22E3 |
| Frame IRQ, phase negative | `keyReleaseCheck()`, then `$08A6` = 3 | the call at $22ED |
| 10 Hz tick, ring not empty (`$08A8` ≠ `$08A7`) and `$08C3` = 0 | `dispatchKey()` | $2355 |
| 10 Hz tick (after the dispatch and $E500), slot 3 then slot 2 held (bit 7 of `$089E`/`$089D` clear) and its counter `$0E74`/`$0E73` = 0 | `requeueKey(index)` with the matrix index the slot holds (the counter stays 0, so it repeats every tick); else the counter counts down | $2365, $2378 |
| 5 Hz half of the tick, not paused, after `$091C` − 1 | `joystickAction()` when `$0E6F` \| `$0E6E` ≠ 0, then `autoCenter()` when `$0E7A` ≠ 0 | $23C2, $23CA |
| NMI (RESTORE) | `restoreNmi()`; when it returns true, `nmi()` runs the cold restart $A7E2 (`coldStart`) | vector $2700 |

The caller charges its own call (6 cycles) and, for the NMI, the 7-cycle interrupt entry.

### Entry points for other subsystems

| Original | Port | Callers |
|---|---|---|
| $2003 → $2250 | `waitForKey()` | title prompts ($AA26, $AA7B), course plotter, editor fields |
| $2009 → $2829 | `setMagnetos(_:label:)` | editor overlay |
| $2024 → $2D58 | `updateElevatorIndicator()` | editor exit; trim creep $EB08 (`Failures.swift`) |
| $2027 → $2C46 | `updateThrottleIndicator() -> UInt8` | editor exit |
| $202A → $2E4C | `updateRudderIndicator()` | editor exit |
| $202D → $2DE6 | `updateAileronIndicator()` | editor exit |
| $2045 → $2CD7 | `updateFlaps(_:)` (A = `$0AB0`) | editor exit ($B7A1) |
| $203C → $25C4 | `dequeueKey()` | overlays |
| $2837 | `setMagnetoLabel(_:)` | engine starter $EECE (`Engine.swift`) |
| $2BBC | `storeSelected(_:)` | `selectAdfDigit` $E9BC (`Adf.swift`) |
| $2BC9 | `keySpace()` | ground contact $354A (`Integrator.swift`) |

A call through a `$20xx` vector costs the vector's jump (3 cycles) on top, charged by the
caller.

### Development bridge

None. Every routine the input code calls is ported (the readouts, radio displays and ADF helpers,
the indicator markers, the multiply, the control coefficients, the sound effects and
`soundTick`); the 10 Hz poll inside `waitForKey` is `pollTick` ($2330, `Game/Poll.swift`).

## Timing

| What | Where | Rate |
|---|---|---|
| Matrix scan / release check | Frame IRQ $22CD: `$08A6` − 1; 0 → scan $2418; negative → release $2505 and reload 3; else idle | Every 4 frames: idle, idle, scan, release = 15 Hz (NTSC) |
| Dequeue one key, auto-repeat | 10 Hz tick $2348 (polled through $2012/$2330) | At most one key per tick |
| Joystick, `$091C` decrement, auto-center | $2348 on even ticks, not paused (`$08CC`) | 5 Hz |

The 10 Hz tick is **polled**: once per display-list opcode ($8752 → $2012 → $2330) and from the
key wait loop ($2268 → $2330). It runs when `$0E6B` ≥ 6 and subtracts 6, so a backlog of frames
is caught up rather than lost.

There is no polling of held keys. **Every effect is a discrete key event.** Holding a key works
only through auto-repeat:

- Only slots 3 and 2 repeat (counters `$0E74`/`$0E73`): normally the first two keys held.
- The slot counter starts at 5 and each tick decrements it; the tick that finds it 0 re-queues
  the key (after that tick's own dispatch), and so does every later tick while it is held. So the
  first repeat is dispatched 6 ticks after the press, then one per tick (10/s)
  (`InputScanTests.heldKeyRepeats`). Lab: ';' held 30 frames gave one step, 42 frames 3, 60
  frames 7 (the counts depend on where the press falls in the tick).
- Two repeating keys queue two codes per tick while one is dispatched, so a **backlog** builds up
  in the ring (whose 8 entries wrap over unread codes) and keeps being dispatched, one per tick,
  after the keys are released (`InputScanTests.severalKeys`).
- Holding P re-triggers it: after the 0.5 s delay a repeat ends the pause (the key is consumed)
  and the next repeat pauses again, so the pause toggles with the repeats (lab `pause`: `$08CC`
  1, 0, 1 about every 10 frames) and the state after release depends on the release time.
- Keys are read only by the scan: a key must be down during a scan frame to be seen, and up
  during a release-check frame (the frame after a scan) to be released. A key pressed and
  released between two scans is lost: a press of 1-3 frames is seen only when it covers a scan
  frame (`InputScanTests.pressesNeedAScanFrame`).

## CIA sampling and joystick arbitration ($2574)

`sampleCia1(column:)`, X = the column select:

1. `$DC00` = $FF. `$08A1` = `$DC00` (port 2), `$08A2` = `$DC01` (port 1).
2. `$DC00` = X, X = `$DC01` (the row read of the column).
3. `$DC00` = $FF. `$08A3` = `$DC00`, `$08A4` = `$DC01`.
4. When none of the four samples has a 0 bit: `$08A1` = the row read, C = 0 (78 cycles).
5. Otherwise a joystick is active: C = 1, and Y = $00 when the two samples of each port agree,
   $FF when they differ. With a static matrix the samples always agree; Y = $FF needs the input
   to change within the 24 cycles between them.

The game never writes the data direction registers: DDRA = $FF, DDRB = $00 as the KERNAL left
them, so port A drives the columns and port B is read with all lines pulled up. The port reads
`io.keyboard.readPortA(portAOut: v, portB: $FF)` and `readPortB(portA: v, portBOut: $FF)` with
the value `v` the original has just stored to `$DC00`. Every `$DC01` read follows such a store in
the same routine, so no `$DC00` shadow is kept between calls.

A joystick sample aborts the caller through **$2557** (`joystickLatch`, entered by a jump, so its
return ends `keyScan`/`keyReleaseCheck`): with Y = $FF it returns; otherwise `$0E6A` = 1,
`$0E6E` = ~`$08A1` & $1F (port 2), `$0E6F` = ~`$08A2` & $1F (port 1), active-high.

Consequences (lab `joystick` session, `InputScanTests.joystickSuspendsKeyboard`):

- A deflected joystick **suspends the keyboard**: no new key is seen (keys pressed meanwhile are
  lost) and no slot is released (the release check aborts too), so a key held when the stick
  moved stays in its slot, and keeps auto-repeating from slot 3/2, until the stick is centered.
- The latches are refreshed by every aborted scan and release check (30 times a second) and
  consumed by `joystickAction` at 5 Hz.
- `$0E6A` is cleared by the next column sample without a joystick bit; nothing else reads it.

## The matrix scan ($2418)

`$0899` (column index base) = 0, `$089A` = X = $FE. For each of the 8 columns:

1. `sampleCia1` ($2574); a joystick ends the scan.
2. A pending `$0E6A` is cleared.
3. When the row read is not $FF: for each row (`$089F` = 0.., mask `$08A0` = $01..$80, shifted
   left each time) whose bit reads low, `keyPress` with A = `$0899` + row.
4. `$0899` += 8; `$089A` is rotated left with a 1 coming in; loop while the bit rotated out is 1.

Columns go 0 to 7. CTRL is in column 7, so **a letter and CTRL that first appear in the same
scan are processed letter first**, without the −$40 (lab scratch test: CTRL+C together gave
rudder −4; `InputScanTests.ctrlTiming`).

## Matrix → command code ($2482)

The index is `column·8 + row`: the column is the `$DC00` bit pulled low (the column selects at
$247A), the row the `$DC01` bit (the row masks at $2472). The 64-entry code table at $2482 is
never written at run time. Columns follow the C64 matrix: DEL, RETURN, the cursor and function
keys in column 0, LEFT SHIFT in column 1, CTRL, SPACE, C= and RUN/STOP in column 7.

Most keys give the ASCII code of their key cap: the letters, the digits, SPACE, RETURN, `+`, `−`,
`.`, `,` and `/`. The game-specific codes are:

- **Dead keys.** The F-keys, CRSR-RT, @, £, *, =, RIGHT SHIFT and C= have codes of $80 and
  above, which are never queued. CRSR-DN gives $00, which dispatches to the no-op.
- **Aliases.** DEL, `:` and ← give $08 (throttle down; editor: backspace); ↑ gives $2D, the same
  as − (editor: previous field); `;` gives $15, the code of CTRL-U; HOME gives $1B; RUN/STOP gives
  $50, the same as P.
- **CTRL** ($FB) only sets `$0E67` (in `requeueKey`, also on each repeat of a CTRL slot). While it
  is set, $40 is subtracted from every code queued, including repeats: letters $41-$5F become
  the CTRL codes $01-$1F; codes below $40 (digits, SPACE, `,` `.` `;` `+` `/` …) wrap to $C0-$FF
  and are dropped by the dispatcher, so CTRL+digit does nothing.
- **LEFT SHIFT** gives $01, the same as CTRL-A: ADF select (lab: after RETURN, LSHIFT → `$FC` =
  $0D).

## Held-key slots and the ring ($24C2-$2504, $2505, $25C4, $25DC)

| Item | Detail |
|---|---|
| Slots `$089B-$089E` | A matrix index, or $80 when free. Set to $80 at init ($AAFD). |
| `keyPress` $24C2 (A = index) | Ignored when a slot holds the index. Otherwise the first slot with bit 7 set from 3 down takes it, its counter `$0E71,X` = 5, and it falls into `requeueKey`. With 4 keys held a fifth is lost. |
| `requeueKey` $24EB (Y = index) | A = `$2482,Y` (+1 cycle across the page for Y ≥ $7E). ≥ $80: only CTRL acts (`$0E67` = 1; the branch over it crosses a page, 4 cycles). Else −$40 while `$0E67` ≠ 0, then on to `enqueueKey` $25DC. |
| `keyReleaseCheck` $2505 | For each held slot from 3 down: `$0898` = index, `$08A5` = slot, drive column `$247A`[index >> 3] through `$2574` (a joystick aborts). When `$2472`[index & 7] & `$08A1` ≠ 0 the key is up: slot = $80; if its code is ≥ $80, `$0898` = slot and, for CTRL, `$0E67` = 0. |
| `enqueueKey` $25DC (A) | `$08A7` + 1, `$08A9`[`$08A7` & 7] = A. No overflow check. 32 cycles. |
| `dequeueKey` $25C4 | `$08A8` = `$08A7`: C = 0, A = `$08A8` (18 cycles). Else `$08A8` + 1, A = `$08A9`[`$08A8` & 7], C = 1 (37 cycles). The indices are compared as whole bytes. |

## Dispatch ($27D8)

1. `dequeueKey` ($25C4) and `$095A` = 0 (any key ends the demo; lab `demo-key`).
2. If `$08BA` ≠ 0 (the editor, or `waitForKey`): `$08C4` = A | $80, return.
3. Codes ≥ $60: return.
4. `$27FF/$2800` = $2718 + 2·A (a 16-bit add), then an indirect jump through `$27FF`: the
   handler's return returns for the dispatcher.

The port writes `$27FF/$2800` too, reads the table entry from memory and runs the handler at
that address (`runKeyHandler`). The default target is `$2CC1` (a bare return).

### Command map (the $2718 table)

| Code | Key(s) | Handler | Port | Action |
|---|---|---|---|---|
| $01, $41 | CTRL-A, A, LSHIFT | $2B25 | `keyAdfSelect` | on to `selectAdfDigit` $E9A7: `$FC` $0D, within the window $0E → $0F → $10 (fuel tank) → $0D |
| $02 | CTRL-B | $2B28 | `keyCtrlB` | `$09CE-$09D1` = 0 (altimeter offset and drift; lab: poked $12 $34 $56 $78 → 0) |
| $03 | CTRL-C | $2B8C | `keyComSelect` | COM: see the radio selects |
| $04 | CTRL-D | $2B37 | `keyCtrlD` | `$08C0` = `$08C5` − `$70/$71` + `$0848` + `$0846` (16-bit; DG realigned to the compass) |
| $05 | CTRL-E | $2F40 | `keyDatabaseInfo` | `$0E87` + 1: the database info screen (lab `database`) |
| $06 | CTRL-F | $2C55 | `keyFuelTankSelect` | `$FC` = $10 |
| $08 | DEL, `:`, ← | $2C31 | `throttleDown` | throttle −8 |
| $09 | CTRL-I | $2B63 | `keyCarbHeat` | `$0AA9` ^= $FF, labels $3A71 ('HT' when on, 'CH' off) |
| $0C, $4C | CTRL-L, L | $2B6E | `keyLights` | `$0AB5` ^= $FF, labels $3A71 ('1' / 'O') |
| $0D | RETURN | $2BC4 | `keyReturn` | `$FC` = 3 (magneto / mixture prefix) |
| $0E | CTRL-N | $2BAC | `keyNavSelect` | NAV: `$FC` 6, within the window 6 → 7 |
| $10, $50 | CTRL-P, P, RUN/STOP | $2250 | `waitForKey` | pause until any key (consumed) |
| $14 | CTRL-T | $2ADF | `keyCtrlT` | transponder select; in slew copies the view attitude back |
| $15 | `;`, CTRL-U | $2C1E | `throttleUp` | throttle +8 |
| $16 | CTRL-V | $2BA7 | `keyObsSelect` | `$FC` = $0C (no window) |
| $18 | CTRL-X | $2B0D | `keyTransponderSelect` | `$FC` 8, within the window +1 up to $0C |
| $1B, $45 | HOME, E | $2801 | `keyEditor` | `$08BA` = 1 (editor) |
| $20 | SPACE | $2BC9 | `keySpace` | brakes on the ground, guns airborne |
| $2B | + | $2BDF | `keyRecallMode` | `$08BB` = 1: the editor overlay reloads mode `$0963` |
| $2C / $2E | `,` / `.` | $286D / $298E | `decrementSelected` / `incrementSelected` | adjust the selected item |
| $2F | / | $2C4F | `throttleJump` | `$08D5` = 1 |
| $31 | 1 | $2807 | `key1` | `$FC` = 3: magnetos OFF; 6/7: NAV1; $0C: OBS1 |
| $32 | 2 | $283D | `key2` | `$FC` = 3: magnetos R; 6/7: NAV2; $0C: OBS2 |
| $33 | 3 | $285F | `key3` | magnetos L **unconditionally** (no RETURN needed) |
| $34 | 4 | $2C5A | `keyRadar` | `$FC` = 3: magnetos BOTH; else radar on (`$0836` = 1), `$FC` = 2 |
| $35 | 5 | $2C70 | `keyViewSelect` | `$FC` = 3: magnetos START; radar on: radar off (`$FC` kept); else `$FC` = 1 (view prefix) |
| $38 / $39 | 8 / 9 | $2865 / $2869 | `key8` / `key9` | `$0AC3` − 1 / + 1 (slew pitch rate) |
| $42 / $54 | B / T | $2E5C / $2D2B | `keyElevatorUp` / `keyElevatorDown` | elevator +4 / −4 (16 in the window) |
| $43 / $4D | C / M | $2E22 / $2E2D | `keyRudderLeft` / `keyRudderRight` | rudder −4 / +4 |
| $46 / $48 | F / H | $2D6D / $2DC2 | `keyAileronLeft` / `keyAileronRight` | ailerons −4 / +4 |
| $47 | G | $2D82 | `keyCenter` | center ailerons and rudder |
| $4E / $59 | N / Y | $2D11 / $2CC2 | `keyFlapsDown` / `keyFlapsUp` | flaps +$20 / −$20 |
| $51 | Q | $2BE9 | `keyCoursePlotter` | `$0E70` = 1 (the plotter menu A-E) |
| $52 / $56 | R / V | $2C9A / $2C87 | `keyTrimDown` / `keyTrimUp` | trim −4 / +4 |
| $53 | S | $2BE5 | `keySaveMode` | `$08BB` = 2: save as user mode `$0963` + 10, which becomes the current mode |
| $57 | W | $2AD5 | `keyDeclareWar` | `$0ACC` \|= 1 (the return at $2ADE after it is unreachable) |
| $58 | X | $2B79 | `keyDropBomb` | bomb in war mode |
| $5A | Z | $2BEF | `keyZeroAttitude` | slew: `$6C-$71` = 0 |

All other codes $00-$5F go to $2CC1.

## The flight-control keys

Each also steps a slew rate (the slew integrator $3660 reads them; in slew the elevator and the
ailerons are the north and east rates).

| Key | Port | Exact behavior |
|---|---|---|
| T | `keyElevatorDown` | `$2E84` (X = 0); `$0AAC` − 4, − 12 more when `$091C` ≠ 0 and not slewing (`$0966`); store; a **negative** result below $B0 becomes $B0 (positive results are not clamped); then $2D50: store, `$091C` = 3, $2D58 |
| B | `keyElevatorUp` | `$2E84` (X = 8); + 4, + 12 more in the window when not slewing; a **positive** result ≥ $50 becomes $50; then $2D50 |
| $2D58 | `updateElevatorIndicator` | ($50 − `$0AAC`) >> 3; when ≠ `$2715`: store, `drawElevatorIndicator` |
| F | `keyAileronLeft` | `$2E84` (X = $0C); `$0AA4` − 4, refused when the result is $80; then $2DD2 |
| H | `keyAileronRight` | `$2E84` (X = 4); + 4, refused on signed overflow (the overflow branch crosses a page); falls into $2DD2 |
| $2DD2 | `coordinateRudder` | AUTO-COORDINATION (`$0965`): rudder `$0ABC/$0ABD` = ailerons, `updateRudderIndicator` $2E4C; then $2DE6 |
| $2DE6 | `updateAileronIndicator` | (`$0AA4` + $7F) >> 3 into `$2716`, `drawAileronIndicator` when it changed; `$0A1D` = ailerons × `$0A7A` (`$0A7C` while `$0E75` ≠ 0), Q15 through `$C4/$C5`; `controlCoefficients` |
| C | `keyRudderLeft` | `$0ABD` − 4 refused when $80 (no view capture); $2E35: store, $2E38 |
| M | `keyRudderRight` | + 4 refused on overflow; $2E35 |
| $2E38 | (private `coordinateAilerons`) | AUTO-COORDINATION: ailerons = rudder, `updateAileronIndicator` $2DE6; then $2E4C |
| $2E4C | `updateRudderIndicator` | `drawRudderIndicator` with (`$0ABD` + $7F) >> 3 (always), `controlCoefficients` |
| G | `keyCenter` | `$2E84` (X = $FF); in slew `$0AAC`, `$0AC3`, `$0ABF`, `$0AC1`, `$0AC5` = 0; then $2D9D |
| $2D9D | `centerControls` | A = 0 into `$0AA4` and `$0ABD`; when (`$09A9` >> 1) + `$09FD` (8-bit) ≥ `$09A9`, the roll term `$09FC/$09FD` is copied to the roll cancel `$0E76/$0E77`; then $2DD2 and $2E38 |
| V | `keyTrimUp` | `$2E84` (X = $0A); `$0AC1` + 1; trim `$0AAE` + 4 unless the result is exactly $54; $2CAF: marker ($50 − trim) >> 4 via $1C10 |
| R | `keyTrimDown` | `$2E84` (X = $0E); `$08D7` = 1 (the war-mode `$FD00` request); `$0ABF` + 1; trim − 4 unless exactly $AC; $2CAF |
| Y | `keyFlapsUp` | `$2E84` (X = 2); `$0ABF` − 1; flaps `$0AB0` − $20, negative → 0; $2CD4: store, $2CD7 |
| N | `keyFlapsDown` | `$2E84` (X = 6); `$0AC1` − 1; in slew nothing more; + $20, negative → $60 (both sign branches cross a page); $2CD4 |
| $2CD7 | `updateFlaps` | marker A >> 4 via $1BFD; `$0A25` = flaps × `$0A7E`; `rebuildWingCoefficients`; `$0A0A` = high byte of flaps × `$0A6C` |
| `;` | `throttleUp` | `$0AC5` + 1; when a 1 shifts out of `$08D5`: `$0AC9` = $78; else + 8 unless the sum is negative (it returns: $78 is the top, and an odd value such as the demo's $7D stays); $2C43: store, $2C46 |
| `:` | `throttleDown` | `$0AC5` − 1; '/' armed: 0; else − 8 unless negative (it returns with A = the difference: 1-7 stay, there is no floor at 0); $2C43 |
| $2C46 | `updateThrottleIndicator` | `$0AC9` >> 3, then on to the throttle marker $1BE1; returns A = the last bitmap byte the marker XORed |
| SPACE | `keySpace` | airborne (`$0A12` = 0): `fireGuns` (the branch crosses a page); on the ground `$0A4D` − 1 twice, negative → `$0A4C/$0A4D` = 0 |
| guns | `fireGuns` | war mode and ammo `$0AA5/$0AA6` ≠ 0: `$0AB2` = 3, `$0E59` = 3, `sfxGun` |

Every handler marked `$2E84` first calls the **view capture** `captureViewKey`: when `$FC` = 1
(after '5') it sets `$FC` = 0 and `$0ACA` = X and drops the handler's return address, so the key
only picks the view and moves nothing (lab `views`: all nine values, controls unchanged, `$FC` = 0
afterward). View codes: T 0, Y 2, H 4, N 6, B 8, V $0A, F $0C, R $0E, G $FF (down; the bombsight in
war mode). The renderer uses `$0ACA`·16 as the yaw offset (45° steps).

**The quick-repeat window** `$091C`: the elevator keys and `storeSelected` set it to 3, the 5 Hz
tick decrements it, ',' and '.' clear it, and the joystick clears it before T/B. Inside it the
elevator steps 16 (unless slewing) and the radio selects step to the next sub-field. Whether a
repeat falls inside depends on the tick alignment: lab B×3 gave $24 (4+16+16) in `takeoff` and
`war`, $18 (4+4+16) in a scratch run.

**Slew mode** reuses the handlers: T/B the north rate (elevator), H/F the east rate (ailerons),
';'/':' the altitude rate `$0AC5`, 9/8 the pitch rate `$0AC3`, R the bank rate `$0ABF`, V the
heading rate `$0AC1`, G zeroes all rates, Z zeroes the attitude, CTRL-T copies the view angles
back (lab `slew`).

## The selected item `$FC`

| `$FC` | Item | Set by |
|---|---|---|
| 1 | View prefix | '5' (and joystick fire) |
| 2 | Radar zoom | '4' |
| 3 | Magnetos / mixture | RETURN |
| 4 / 5 | COM MHz / kHz | CTRL-C |
| 6 / 7 | NAV MHz / kHz | CTRL-N |
| 8-$0B | Transponder digits 1-4 | CTRL-X, CTRL-T |
| $0C | OBS | CTRL-V (and the fifth quick CTRL-X) |
| $0D-$0F | ADF digits | A, CTRL-A, LSHIFT |
| $10 | Fuel tank | CTRL-F (and the fourth quick A) |

`setMagnetos` ($2829, A = code, X = label) and the digit and magneto keys set `$FC` = 0.

### Magnetos (RETURN, then a digit)

`$2829`: `$FC` = 0, `$EE15` = A >> 1, `$EE14` = A & 1, `$0AB6` = X, then `drawMagnetoLabel` $3A71.

| Key after RETURN | Code A | Label X `$0AB6` | Switch bits `$EE14/$EE15` |
|---|---|---|---|
| 1 | 0 | 0 OFF | 0 / 0 |
| 2 | 1 | 2 R | 1 / 0 |
| 3 (also without RETURN) | 1 | 1 L | 1 / 0 |
| 4 | 3 | 3 BOTH | 1 / 1 |
| 5 | 3 | 4 START | 1 / 1 |

R and L set the same bits; only the label differs. Outside reality mode OFF does not stop the
engine. The engine's starter ($EEC0) reverts START to BOTH (`setMagnetoLabel` $2837 with X = 3) when
it starts a stopped engine (lab `failures`; with the engine running START stays).

### Radio selects

| Key | Port | Rule |
|---|---|---|
| CTRL-C | `keyComSelect` | (a dead load of 1) within the window and `$FC` = 4: `$FC` = 5 (the window is not renewed). Otherwise `$FC` = 4 and the window (`storeSelected`), after `$0937` + 1 (COM search request) when `$FC` was 5 within the window |
| CTRL-N | `keyNavSelect` | within the window and `$FC` = 6: `$FC` = 7; else `$FC` = 6 and the window |
| CTRL-V | `keyObsSelect` | `$FC` = $0C, no window |
| CTRL-X | `keyTransponderSelect` | within the window and `$FC` in 8-$0B: `$FC` + 1 (so the fifth quick press reaches $0C, the OBS); else 8; then the window |
| CTRL-T | `keyCtrlT` | outside slew as CTRL-X; in slew `$09DE/$09DF` = −`$6C/$6D`, `$09E0/$09E1` = −`$6E/$6F` (16-bit), `$0A13/$0A14` = `$70/$71` (66 cycles) |
| A | `keyAdfSelect` | `selectAdfDigit` ($E9A7): $0D; within the window and `$FC` in $0D-$0F, `$FC` + 1; then `storeSelected` |
| `$2BBC` | `storeSelected` | `$FC` = A, `$091C` = 3 (15 cycles) |

### ',' and '.' ($286D, $298E)

First `tuneDecrementPre`/`tuneIncrementPre` ($E9BF/$E9F6, `radios.md`): with the ADF enabled
(`$09AA`) and `$FC` $0D-$0F the ADF digit, and with `$FC` = 3 the mixture `$0A9A` (',' raises,
'.' lowers, 0..7). Then `$091C` = 0, and:

| Condition | ',' (`decrementSelected`) | '.' (`incrementSelected`) |
|---|---|---|
| War mode (`$0969`), any `$FC`, or `$FC` = 2 | radar zoom out: the 24-bit `$0889-$088B` shifted left with a 1 in, bit 23 cleared (lab `radar`: $03FFFF → $0FFFFF after two presses) | zoom in: shifted right with a 0 in, then `$0889` \|= $1F |
| 4 COM MHz (`$21B0/$21B1`) | 118 → 135, else units −1 with a borrow | 135 → 118, else units +1 with a carry |
| 5 COM kHz (`$21B2/$21B3`, $2963 / $2AA9) | .x5 → .x0, .x0 → .(x−1)5, .00 → .95 | .x0 → .x5, .x5 → .(x+1)0, .95 → .00 (no carry into MHz) |
| 6 NAV MHz (NAV1 `$21B7`, NAV2 `$21BE` by `$0AB7`; $2977 / $2ABE) | 108 → 117 | 117 → 108 |
| 7 NAV kHz (`$21B9` / `$21C0`) | as COM kHz | as COM kHz |
| 8-$0B transponder digit `$21DD`+(`$FC`−8) | '0' → '7', else −1 | '7' → '0', else +1 |
| $0C OBS (`$2196` / `$2199` by `$0ACB`) | −1, $FF → $B3 (2° units) | +1, $B4 → 0 |
| $10 fuel tank `$09C6` | 1 → 0 (`$1CF0` toggles the marker) | 0 → 1 |
| anything else | nothing | nothing |

Each change redraws its readout: `$3903` COM (also `$0941` = 1 and the COM search `$0937` = 1),
`$38BD`/`$38D9` NAV1/NAV2, `$3A5C` transponder, `$3923`/`$3976` OBS1/OBS2. Lab: COM 124.85 → '.'×2
126.85, kHz '.'×3 → 126.00; MHz 126 → 118 → 135; NAV 110.00 → 112.00, NAV2 114.35 → 114.25;
OBS1 '.'×5 → 5, OBS2 ','×3 from 0 → $B1; transponder 1200 → 2200 → 2400 → 2407.

## Command and switch keys

| Key | Port | Exact behavior |
|---|---|---|
| E, HOME | `keyEditor` | `$08BA` = 1 (12 cycles) |
| + | `keyRecallMode` | `$08BB` = 1 (12) |
| S | `keySaveMode` | `$08BB` = 2 (15) |
| Q | `keyCoursePlotter` | `$0E70` = 1 (12) |
| W | `keyDeclareWar` | `$0ACC` \|= 1 (16) |
| X | `keyDropBomb` | war mode and `$08E8` ≠ '0': `$08E8` − 1, `sfxBombRelease` |
| CTRL-E | `keyDatabaseInfo` | `$0E87` + 1 (12) |
| CTRL-B / CTRL-D / CTRL-I / L | see the command map | |
| 8 / 9 / Z | `key8` / `key9` / `keyZeroAttitude` | slew pitch rate − / +; Z in slew zeroes `$6E-$71` then `$6C/$6D` (the branch past it crosses a page) |

## Joysticks ($2688, $26EC; 5 Hz)

`joystickAction` shifts the latches right, bit by bit:

| Port | Bit | Action |
|---|---|---|
| 1 (`$0E6F`, the yoke) | 0 up | `$091C` = 0, then T (`keyElevatorDown`): elevator −4 (never 16) |
| | 1 down | `$091C` = 0, then B: +4 |
| | 2 left | F, then `$0E78` = 3 |
| | 3 right | H, then `$0E78` = 3 |
| | 4 fire | '5' (`keyViewSelect`) |
| 2 (`$0E6E`) | 0 up | `throttleUp` |
| | 1 down | `throttleDown` |
| | 4 fire | `fireGuns` |

Then `$0E6E` = `$0E6F` = 0 and `$0E7A` = 1. A is saved on the stack around every call except
`throttleDown`: the fire test after it shifts the A that `throttleDown` returns. **With port 2
down and fire together, the guns fire only when bit 2 of that A is set**: the last bitmap byte
the throttle marker XORed, or (when the throttle did not change) the negative throttle − 8. An
original quirk, kept (the port returns A from `throttleDown`/`updateThrottleIndicator`, read back
from the state `plotPointList` leaves).

The view key captures T/B/F/H too when `$FC` = 1 (fire is processed after the directions, so a
fire with a direction captures the next tick's direction).

`autoCenter` ($26EC): `$0E78` is shifted right; a 1 shifted out returns. Otherwise `$0E7A` is
shifted right and `centerControls` $2D9D runs with A = 0 (center ailerons and rudder). After
left/right (`$0E78` = 3) the controls center on the third 5 Hz tick after the stick (lab: centered
within 60 frames); after up/down alone (`$0E78` already 0) at once. Analog sticks must be
thresholded to these digital bits: each processed direction steps 4 units per 5 Hz tick (lab: port 2
up 120 frames → throttle $58; port 1 down 24 frames → +12).

## Wait for key ($2250)

1. Push `$08BA` and `$08D3`.
2. `$08D3` = 0 and `soundTick` ($CC16): the SID is silenced.
3. `$08CC` + 1: the 5 Hz work and the 1 Hz sound/clock tick stop (the clock `$091A` and the
   airspeed freeze; lab `pause`).
4. `$08BA` = 1 (text input: the dispatcher stores keys in `$08C4`).
5. Loop: the poll $2330, until `$08C4` is negative (13 cycles per pass plus the poll).
6. `$08C4` &= $7F, restore `$08D3` and `$08BA`, shift `$08CC` right, return A = code & $7F (no
   echo).

Used by the pause (P, CTRL-P, RUN/STOP; the key that ends it is consumed), the title prompts
($AA26 display A/B, $AA7B demo/regular), the course plotter menu (A-E; the menu stays up after
A-D, E returns), and the editor fields (RETURN next line, −/↑ previous, DEL/←/: backspace, E exit;
see `modes-ui.md`).

**Port:** `waitForKey()` charges its instructions, calls `poll()` where the original calls $2330
(the scheduler's `pollHandler`, which must charge $2330 from its first instruction and keep the
virtual clock, the frame IRQ work and the 10 Hz tick going), and returns the code. Without a poll
handler it stops with a precondition failure instead of hanging.

## RESTORE (NMI $2700)

The NMI vector is set to $2700 at $AB0E. The handler saves A; when `$089E` = $3F (RUN/STOP in
slot 3, so it must be the first key held) and `$26FF` = 0, it sets the one-shot `$26FF` and jumps
to the cold restart $A7E2 (the reload clears `$26FF`). Otherwise it restores A and returns.
RESTORE alone, or with RUN/STOP held second, does nothing (lab `restart`). While the loader runs,
$E57F and $78A9 point the NMI at a bare return.

**Port:** `restoreNmi() -> Bool` charges $2700 through the return (22 or 28 cycles) or the jump
(26); true means the caller performs the cold restart: `nmi()` runs `coldStart()` (`main-loop.md`).

## Cycle costs (exact; the caller charges its call)

| Routine | Cycles |
|---|---|
| `sampleCia1` | 78 (no joystick); 88 / 98 / 97 (joystick: port 2 samples differ / port 1 samples differ / both agree) |
| `enqueueKey` | 32 |
| `dequeueKey` | 18 empty, 37 |
| `keyPress` | 13-31 when already held; otherwise 49 + 11 per occupied slot skipped, + `requeueKey`; 77 when no slot is free |
| `requeueKey` | 16 + `enqueueKey` (19 + `enqueueKey` while CTRL is held); 19 for a dead code ≥ $80; 23 for CTRL; + 1 for an index ≥ $7E |
| `captureViewKey` | 14, or 30 when it captures |
| `storeSelected` | 15 |
| `keyCtrlD` / `keyCtrlT` (slew) | 74 / 66 |
| `restoreNmi` | 22 (not RUN/STOP) / 28 (one-shot set), both through the return; 26 through the jump to $A7E2 |
| the rest | the instruction sums in the port, verified per call against the lab |

## Mac key mapping

| Mac | C64 | Mac | C64 |
|---|---|---|---|
| Letters, digits, `, . /`, Space, Return | Same key | Esc | RUN/STOP |
| `;` | `;` (throttle up) | Home | CLR/HOME |
| `'` | `:` (throttle down) | Delete | INST/DEL |
| `=` | + | Control | CTRL |
| `-` | − | Both Shifts | Right SHIFT (ignored). This avoids the LSHIFT = ADF quirk; the ADF stays on A. |
| `[` / `]` / `\` / `` ` `` | @ / * / £ / ← | Option | C= |
| Arrows | Cursor keys | Page Up / Page Down | Throttle aliases (`;` / `:`) |

Keypad as joystick: keypad 8/2/4/6 port 1, keypad 5/0 port-1 fire, keypad +/− port-2 throttle,
Enter guns. Gamepad: the left stick or D-pad is port 1, the right stick Y axis port 2, A port-1
fire, B/RT guns.

The authoritative table is `Sources/FS2App/Input/KeyMapper.swift`, which the app's key reference
window shows; it also covers the shifted cursor directions (← and ↑ as SHIFT + CRSR), F2-F8 and
the keypad's diagonals.

### What the mapper must do for the original's timing

The matrix is sampled only by the scan, once every 4 frames (the 4-frame phase of `$08A6`), and
released only by the release check, the frame after a scan. So the mapper, which writes
`io.keyboard` at frame boundaries, follows these rules (the app's `KeyTiming` and
`JoystickSharing`, `engine.md`):

- **CTRL combinations: put CTRL into the matrix at least one scan before the letter.** Press CTRL,
  keep the letter out of the matrix for 4 frames (one whole keyboard cycle, which always contains
  a scan), then add the letter. In the same scan the letter (columns 1-6) is processed before
  CTRL (column 7) and is queued without the −$40 (CTRL+C together gives rudder −4; CTRL+I together
  never toggles the carb heat). With a 1-frame lead 3 of the 4 scan phases give the plain
  letter; a 4-frame lead gives the CTRL code in all four (`InputScanTests.ctrlLeadNeedsOneScan`).
  The lab sessions use `down:CTRL wait:8 key:X:6 up:CTRL`.
- **Hold every key for at least 4 frames**, and keep it released for at least 4 frames before a
  re-press, so a scan and a release check see each edge.
- **Machine ▸ Restart**: hold RUN/STOP alone for at least 4 frames (it must take slot 3: no other
  key may be held first), then raise RESTORE (the NMI) while RUN/STOP is still held. RUN/STOP also
  queues $50, the pause, which does not matter: the NMI runs during the pause.
- Never hold more than two keys expecting repeats: only the first two held keys repeat, and two
  repeating keys build a backlog that keeps acting after release (see Timing).
- Joysticks: with Settings ▸ strict joystick a deflected stick (keypad or gamepad) suspends the
  keyboard exactly as described above. The default, shared mode hides the stick bits only in the
  frames whose scan or release check needs the keyboard (a new key to scan, a held key to
  release), so keys and the stick work together (`JoystickSharing`, `engine.md`).
