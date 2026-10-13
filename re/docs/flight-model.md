# Main loop, timing, fixed-point math and the flight model

The flight model was checked by running the original routines on the boot image in a throwaway 6502 interpreter:

- At full throttle the take-off roll reaches about 97 kt in 15 s.
- With elevator +8 the aircraft climbs at about 1250 fpm at 96 kt.

These results confirm the units below.

**Everything that changes state is integer and bit-exact.** Floating point is allowed only for presentation and audio DSP.

## Units

| Quantity | Storage | Unit |
|---|---|---|
| Position | East `$5A-$5D`, Altitude `$5E-$61`, North `$62-$65`: signed 32-bit | 1/256 m. The high word is in 256 m units. Editor/display N and E = high word + $4000. Start (Meigs): E $011F0000, alt $000301, N $03240000. |
| Altitude | `$5F:$60` = meters above the **local ground datum** | Ground contact at 3 m. MSL = that + field elevation `$0A87:$0A88`, stored in `$0830` by $CE84. |
| Airspeed | `$0A4C:$0A4D` unsigned | 8.8 m/s, one scalar with no separate ground speed. Max $64xx (100 m/s, 194 kt); the ASI clamps at $5A. |
| Vertical speed | `$0A50` | 8.8 m/s = V·sinγ |
| Angles | 16-bit binary | $10000 = 360°. γ (flight path, + climb) `$09DE`; φ (bank, + right) `$09E0`; ψ (true heading, 0 = north, clockwise) `$0A13` |
| Density | `$09DA` | Q15 = $7FFD − (2m + ⌈m/2⌉) for m = MSL meters (≈ $7FFD − 2.5m; see `$35BD`) |
| Engine | `$09BE` | RPM/50 |
| dt | `$0A0D:$0A0E` | Q15 seconds |
| Altimeter | ×9460/32768 | 88 needle steps per 1000 ft |
| VSI | | 64 LSB per needle step = 0.25 m/s |

## Main loop ($2048 / $204B)

The main loop, the interrupts, the ticks and the cold start are specified in `main-loop.md` and
ported in `Sources/FS2Core/Game` (`runMainLoop`, `mainLoopPass`, `rasterIrq`, `tick10Hz`, ...).
What the flight model depends on:

There is **no vsync wait**. The loop runs as fast as rendering allows: about 1.2 M cycles (70
frames, under 1 fps) per pass at Meigs.

- `$2048` calls the flight slot $A7F4 once on entry.

Each pass at `$204B` then runs:

1. **Overlays.** If `$08BA` or `$08BB` is set, the editor slot $A7E8 (editor overlay), then the
   editor cache bookkeeping (`$08BC`, the swap at $E6DB). Then the flight slot $A7F4, which keeps
   the flight overlay resident (normally it just returns).
2. **Physics.** In slew (`$0966`) the slew routine $3660; otherwise the integrator $32EE, then the
   wind drift $E716 (airborne only).
3. The course-plotter display $F6E2 (mode `$0E82`).
4. $E565: set the display-list root `$8B/$8C = [$A7E0]`. The rest of $E565 is the protection
   hang and is **not ported**.
5. The view matrix ($8000 → $8111).
6. **Page flip** ($208B), unless the bit shifted out of `$0E79` is set. See `display.md`.
7. **Alternate passes only** (when `$8D` flips to $20):
   - `$E713` → $F239, the ATIS teletype;
   - `$F95D` if crash code `$0834` is set (A = the code);
   - `$F627` if `$0E70` (course plotter);
   - **`$FD00` if war mode `$0969` and `$08D7`.** The hook is empty on the disk: a documented
     no-op in the port (`excluded.md`).
   - `$A7FA` if `$0E87` (database info).
8. **Draw sequence** ($20D5):

   | Order | Routine | What it does |
   |---|---|---|
   | 1 | $8003 → $83A4 | Horizon and sky/ground fill |
   | 2 | $8006 → $8730 | Scenery |
   | 3 | $3C3F | NAV2 needle step (`stepNav2Needle`) |
   | 4 | $3AB9 | Tach |
   | 5 | $8021 → $A378 | Attitude indicator |
   | 6 | $3BAF / $3C1A | OBIs |
   | 7 | $F8AF | Ground elevation |
   | 8 | $3773, $377C | Heading/DG |
   | 9 | $3823 | Compass |
   | 10 | $EBA5 | Lights |
   | 11 | [$A7EE] | War overlay, war mode only |
   | 12 | $ED3C | View overlays |
   | 13 | $CE84 | Altimeter + MSL |
   | 14 | $CF0E | ASI |
   | 15 | $F35E | Instrument masks |

9. **Phase dispatch on `$22 & 3`:**

   | Phase | Tasks |
   |---|---|
   | 0 | $EBF2 time of day, $A532 turn coordinator, $1C5D left fuel, $E766 wind layer, $3A13 DME. **Only when also `$22 & 4`** (once per 8 passes): $38D4, $38F5, $EA50, the demo check $2133 (`$095B` → `$08BB = 3`) and the war-exit check $213D-$2149 (left Europe 1917 → the cold restart at $A7E2). |
   | 1 | $1C75 right fuel, $F86F 10,000-ft marker |
   | 2 | $1CA7 oil temperature, $35BD density and bank auto-level |
   | 3 | $1CBE oil pressure, $EA84 reality-mode failures (with the carry $1CBE leaves) |
   | Odd (1, 3) | Also $3B32, $3B9B, $CF46 VSI, $E7FE ADF; rotate `$0832:$0833` |
   | Even (0, 2) | Also $F996 splash detect, $F916 regime timer, $CF79 slip ball, $EE6B engine |

10. `$22` + 1, and back to `$204B`.

## Timing sources

| Source | Mechanism | Rate |
|---|---|---|
| Raster IRQ $2285 | Two IRQs per frame (lines $20 and $A3); the window phase runs the frame tick | 59.826 Hz (17,095 cycles/frame at 1,022,727 Hz) |
| Jiffy `$34` | + 1 per frame (window phase, and the alternate IRQ $2304) | 60 Hz |
| `$0E6B` | + 1 per frame; `$2330` runs `$2348` once per 6 counts, one tick per poll, a backlog caught up over the following polls | 10 Hz |
| `$2348` 10 Hz tick | Polled from the interpreter ($8752, once per opcode) and the key wait loop ($2268), not timed | See below |
| CIA1 TOD | Seconds `$DC09` compared with `$0E6D` on each 10 Hz tick | 1 Hz (up to 0.1 s late) |

What the 10 Hz tick (`$2348`) does:

- Every tick:
  - one queued key ($27D8), unless `$08C3`;
  - `$E500` engine pitch;
  - key repeat (slots 3 and 2);
  - the bomb-whistle sweep.
- Even ticks (5 Hz), only when not paused (`$08CC == 0`):
  - `$091C` − 1;
  - **`$2F45` aerodynamics**;
  - `$1A32` and `$1A6A` (airspeed and VSI needles);
  - joystick `$2688` if `$0E6E | $0E6F`;
  - auto-center `$26EC` if `$0E7A`.
- On a TOD second (suspended while `$08CC`):
  - `$CC16` sound tick;
  - the clock (`$091A` seconds, `$0984` minutes, `$0983` hours);
  - `$EAE2` trim creep on even seconds.

**The port's clock.** The virtual NTSC clock (`VirtualClock`) is the only time base: ported
routines charge their cycles; in normal mode `InterruptScheduler` runs the raster IRQ at its
lines from that clock (catching up through long charges, held during disk loads and while
interrupts are masked), and the CIA1 TOD (`TimeOfDayClock`) counts 60 Hz mains ticks of the same
clock. In replay mode the interrupts and the TOD values come from the lab's recording instead
(`ReplayDriver`), so both sides compute from identical asynchronous inputs (`main-loop.md`).

**Interrupts.** `$AB78` masks the CIA IRQs and NMIs. The loader uses CIA1 timer B only for disk
transfers.

**50/60 Hz.** `$AAFA-$AB57` counts loop iterations per TOD tenth. A count ≥ $1ABD sets
`$DC0E=$80` (50 Hz TOD). The physics constants ($0222 and the 6-jiffy tick) are **not**
adjusted, so on PAL the original runs about 17% slow. The port is NTSC only: it waits the
calibration's time and stores the NTSC count $18CB the lab measures (`$DC0E` stays 0).

### Frame-rate-dependent terms

Some effects run once per main-loop pass, not per unit of time:

- fuel burn (phase 2);
- bank auto-leveling (phase 2);
- wind drift (each pass, scaled by the dt high byte);
- the gauge phases.

On the C64 a pass took several frames. The plan therefore keeps the authentic cadence: in Smooth mode the simulation still steps at the original rate, and only the view is interpolated. Never run the logic at 60 Hz, or fuel burn and auto-leveling become roughly 10× faster.

The original also has real busy-waits. They are charged on the virtual clock, in steps, so the
interrupt equivalents keep running through them as the raster IRQ did:

| Busy-wait | Where | Length |
|---|---|---|
| Engine starter | $EEC0 | 586,756 cycles (0.574 s) |
| Crash/splash message delay | $F25B, Y=5 | 2,283,560 cycles (2.23 s) |
| ATIS per-character delay | Scaled by `$096A`, with a final $F25B (Y=4) delay | 1,826,849 cycles at the end |
| 'WAR !!!!' | | ~65536 iterations |
| TOD calibration (cold start, interrupts off) | $AB28-$AB45 | to the next TOD tenth plus two tenths |

## Fixed-point math library ($16AA-$1A0A)

Ported as literal translations of the shift-add and subtract loops, including their truncation errors, saturation and biases (`Sources/FS2Core/Math/`). Errors accumulate through integration, so "correct" replacements would drift. `math.md` is the exact specification; this table is the summary the flight model relies on.

| Routine | Function | Notes |
|---|---|---|
| `$16C9` (entries $17EF A:X → $C6:$C7; $17F6 also copies the result to $C4:$C5) | Signed 16×16 → ≈ (a·b)>>15 | Inverted-bit shift-add: bits 0-5 of the multiplier add only the multiplicand's high byte. Error −1.95..+1.97 LSB (`math.md`). −32768 is treated as −32767. Zero shortcut. Result A=low, X=high. |
| `$16AA` | zp[A] = zp[X]·zp[Y] | Used to build the matrix |
| `$1802` | Signed fractional divide | Dividend X=low, A=high; divisor $C6:$C7; Q15 quotient in $C4:$C5. 15-iteration non-restoring. Valid only for \|n\| < \|d\|. |
| `$188A` | Unsigned 16×16 → 32 in $C8-$CB | Returns bits 8-23 (A=$C9, X=$CA). Used for dt and feet↔meters. |
| `$196D` | Signed 8×8 → ≈ 2·x·y | The bias comes from the caller's carry (or a forced 1/0 by sign): 1×1 = 3 with the carry set, 2 with it clear; 3×5 = 31, 10×20 = 400, 100×100 = 20001 with the carry set. −128 is treated as 127 (`math.md`). |
| `$1961` | `$196D`, then ASR of Y:A | ≈ x·y |
| `$1881` / `$19D5` | 16-bit ASR (X:A) / negate | |
| `$19E2` | Speed-indexed interpolation | Table at ($BA). It reads the airspeed high byte `$0A4D` (V_hi): Y = `$0A4D`>>4, frac = `$0A4D` & 15. Result c5:c4 = t[Y]·256 + 2·$1961(t[Y+1]−t[Y], frac·8). Tables: $0E10, $0E1A, $0E24, $0E42. |
| `$18D0` / `$18CD` | cos / sin of a 16-bit angle (A=high, X=low) | Q15. First-quadrant lookup at index A·2: X=0 gives the exact entry; X=$80 the average of adjacent entries; otherwise linear interpolation via $17EF with (X>>1)<<8. Quadrants by symmetry. Angle $8000 → $7FFF. |
| `$18B8` / `$18BD` | cos / sin of an 8-bit angle | X = 0 |
| `$18C2` / `$18C9` | cos / sin with Y = high byte and A bit 7 = half step | A 9-bit angle; used by the matrix |

**Cosine table $158E-$1611** (a correction to earlier notes): **66 words**, entries 0-65.

- Values follow 32767·cos(i·1.40625°) to within one unit (a few entries are one off from plain
  rounding down).
- **Entry 25 ($15C0) is a glitch**: about 300 below the true cosine. The port reads the table from
  memory; never regenerate it, or the glitch (and the off-by-one entries) would be lost.

Test vectors measured on the original (the math tests check them too):

| Call | Result |
|---|---|
| mul(1000, 1000) | 29 |
| mul(546, 10000) | 166 |
| mul(32767, 32767) | 32765 |
| div(100, 300) | 10922 |
| div(1000, 2000) | 16384 |
| sin($1234) | 14156 |
| cos($1900) | 26489 (shows the entry-25 glitch) |

There are no square-root, logarithm or arctangent tables in this library. The nav instruments have their own arctangent table at `$3AF1` (17 words, read by `arctanRatio` $3E9F; `radios.md`).

## Physics split

The port is in `Sources/FS2Core/Sim/` (namespace `FlightModel`, addresses in `FlightModel.RAM`).
Every routine is a step-for-step translation: it reads and writes the bytes the original does
(zero-page temporaries included), keeps every carry chain and quirk, and charges the original's
cycles exactly (per path, with taken branches and page crossings), progressively before each
call it makes. None of the callers reads a register or flag these routines leave, so they return
nothing; the only register inputs are A of `$F95D` and the carry of `$EA84`.

| Address | Port | Called from | Cycles |
|---|---|---|---|
| `$2E92` | `controlCoefficients()` | key handlers `$2E1E`, `$2E58` | 172 + 2 × asr16 + 4 × mulQ15AX + 90 |
| `$2F07` | `rebuildWingCoefficients()` | `$2CF7` (flaps), fall-through | 90 |
| `$2F45` | `aeroUpdate()` | 10 Hz tick `$23B1` (even ticks, not paused) | 13 in slew, else ≈ 5,000-10,500 |
| `$32DF` | `mulQ15Times4(a:x:)` (internal) | `$31F2` | 6 + mulQ15AX + 25/26 |
| `$32EE` | `integrateFlight()` (with `$3515`) | main loop `$2074` | ≈ 2,000-5,400 |
| `$35BD` | `densityAndAutoLevel()` (with `$3614`) | phase 2 `$2152` | 13 in slew, else ≈ 90-125 (+ service) |
| `$3638` | `serviceAircraft()` | `$361E`, vector `$200F` | 60 |
| `$3660` | `slewIntegrate()` (with `$372B`) | main loop `$206E` | path-dependent |
| `$372B` | `slewAux()` | fall-through, vector `$200C` | 42 |
| `$E716` | `windDrift()` | main loop `$2077` | 13 on the ground, 116-118 |
| `$E766` | `windLayer()` | phase 0 `$211E` | ≈ 800-950 |
| `$EA84` | `realityFailures(carry:)` | phase 3 `$2167` | 33 outside reality mode, 66-119 in it, ≈ 90,000 when a failure clears the window and draws its text |
| `$EAE2` | `trimCreep()` | 1 Hz tick `$2414` | 15 outside reality mode |
| `$EE6B` | `engineModel()` | even phases `$218E` | ≈ 350-1,300; the starter adds 586,756 |
| `$F8AF` | `trackGroundElevation()` | draw sequence `$20EA` | path-dependent |
| `$F916` | `maneuverRegimeTimer()` | even phases `$2188` | 18-57 |
| `$F95D` | `crashMessage(code:)` | flip passes `$20AB` | ≈ 2.36 M with the delay |
| `$F996` | `splashDetect()` | even phases `$2185` | 19-58 |
| `$F9C1` | `setAltitudeFromEditor()` | `$34B4`, vector `$2006` | 72-79 + mulU16 |

**Calls into other subsystems** (all ported): `keySpace` $2BC9 (input; the brakes while
repositioning, from `groundContact` at $354A), `setMagnetoLabel` $2837 (input; the starter at
$EECE with X = 3 returns the switch to BOTH and redraws the label), `updateElevatorIndicator`
$2D58 (input; from `trimCreep` at $EB08), `busyDelay` $F25B (ATIS; Y = 5, the crash message's
2,283,560-cycle delay at $F98D), the math library, `sfxCrash` ($CC68, sound), `clearWindow`
($1EAF) and `drawTextRecord` ($1DDE, raster). The development bridge is not used.

### (a) Aerodynamics `$2F45`: 5 Hz, untimed

Each call integrates speed and γ by one step. Products are `$16C9` Q15 multiplies (`mulQ15AX`)
unless noted; "interp(T)" is `$19E2` on table T at the current V_hi.

1. **Slew**: nothing (a set `$0966` returns at once).
2. **Trig.** `$0A3E` sinγ = sin16(γ); `$09E8` cosγ = cos8(γ_hi); `$0A40` sinφ = sin16(φ); `$09EC` cosφ = cos8(φ_hi); `$09F8` = cosφ·cosφ, negated (`$19D5`) when cosφ < 0.
3. **Rudder gain** `$0A04` = mul8Half(interp($0E42)_hi, rudder_hi), with interp's carry. Never read in resident code.
4. **AoA proxy** `$09DC` = interp($0E10) × elevator `$0AAB`. **Wing lift** `$0A1F` = AoA × `$0A78` (25000, the lift slope).
5. **Wing totals** `$0A56` = wingLift + CL_L (forced to 0 when `damageLevel $08D4` ≠ 0), `$0A58` = wingLift + CL_R.
6. **Stall** ($3009). With aoa_hi = `$09DD`:
   - aoa_hi ≥ 0: lamps `$7E3D/$7E3E` = $12 and stall horn `$0E59 = 1` when aoa_hi ≥ $21, else lamps $1B.
   - aoa_hi ≥ $24, or $80 ≤ aoa_hi ≤ $E6: `stallTimer $0E7B = 15`, `maneuverTimer $0E75 = 6`.
7. **q** `$0A4E` = V × V. `$0A2B`/`$0A2D` = (q × total) << 2 (16-bit shifts, wrapping).
8. **Total lift** `$0A29` = ((L_L + L_R) × density, chained with `$17F6`) × (`$0A27` with its high byte + $0B in ground effect: (alt+1 − $14) with the borrow into alt+2 negative, i.e. below 20 m). While `stallTimer` is nonzero it is decremented and the lift is 0.
9. **Weight terms** `$0A44` = sinγ × W, `$09F0` = cosγ × W. **Normal force** `$0A4A` = L × `$09F8` − `$09F0`.
10. **Drag.** `$0A5A` = `$0A56`², `$0A5C` = `$0A58`². The sum is built with the original's carries ($314B): low = sqR_lo + sqL_lo (a carry increments X), + slipDrag_lo; high = X + sqL_hi + that carry, then + slipDrag_hi and + flapDrag `$0A0A` with the carries dropped. Then × k `$09E6`, + CD0 `$09E4`, × q (chained), × density, + `$0A44` → `$0A00`; when V ≠ 0 also + the **low byte** of `$0A74` (carry into the high byte).
11. **Acceleration.** `$0A08` = thrust − drag; `$0A02` = `$0A08` × `$0A30`.
12. **Turn rate** `$09FE` = `mulQ15Times4`((interp($0E24) × sinφ, chained) × L), + slipYaw `$09F4` when airborne. On the ground with V ≠ 0 it is the rudder `$0ABC` ASR 3 instead.
13. **γ rate** `$09FA` = interp($0E1A) × (normal force, ASR 1 unless `maneuverTimer`), and 0 if negative on the ground.
14. **Speed.** V += acceleration (16-bit). A signed overflow (the V flag) sets the high byte to $64 and keeps the low byte; a negative result zeroes both bytes.
15. **γ.** γ += rate. γ_hi in $40-$7F is reflected (`$32BA`): γ = $8000 − γ (`$19D5` negate, high byte XOR $80), and the bank and heading high bytes flip by 180°. A negative sum is negated (`$32A8`), reflected, and negated again (the second negate falls through into the routine's return).

The model is table-and-coefficient based, not 6-DOF:

- The elevator sets the AoA proxy directly.
- The 5 Hz tick changes γ, not the nose.
- Roll rate is differential lift times distance traveled.
- Nose attitude = γ + 0.107·`$09DC` (via `$0A64`).

### Control-derived coefficients `$2E92-$2F3F`

| Coefficient | Formula | Where |
|---|---|---|
| Slip `$09F3` | (ailerons_hi ASR 1) − (rudder_hi ASR 1), 8-bit. `$09F2`, the low byte, is never written but is read below. `$B9` = rudder_hi ASR 1. | `$2E92` |
| `$0A15` (drag) | (0 : slip_hi) × `$0A70` | `$2E92` |
| `$09F4` (yaw) | slip × `$0A68` | `$2E92` |
| `$0A46` (track offset) | slip × `$0A6A` | `$2E92` |
| `$09F6` (roll) | slip × `$0A66` | `$2E92` |
| CL_R `$0A23` | flapLift + CL0 − aileronCoefficient | `$2F07` |
| CL_L `$0A21` | flapLift + CL0 + aileronCoefficient + slipRoll | `$2F07` |
| Aileron `$0A1D` | `$0AA3:$0AA4` × `$0A7A`, or × `$0A7C` while `$0E75` | key handler `$2E15`, outside this range |
| Flaps lift `$0A25` / drag `$0A0A` | `$0AAF:$0AB0` × `$0A7E` / flaps_hi × `$0A6C` | key handler `$2CEE`, outside this range |

A positive aileron (H, roll right) adds lift on the **left** wing (earlier notes had the signs
swapped). The incoming A of `$2E92` only travels through `asr16` into Y.

### (b) Integrator `$32EE`: every pass, time-scaled

1. `$0A80` = 1 (see slew).
2. **dt.** jiffies = (`$34` − `$08CA`) mod 256; `$08CA` = `$34`. `$188A` multiplies (`$C5` = jiffies : `$C4` = **stale**) by $0222 (immediate operands at $32FF); `$0A0D:$0A0E` = product bits 8-23, the high byte forced to $7F when its bit 7 is set (the test uses the N flag `$188A` leaves from X).
   - **The stale `$C4` is emulated**: whatever the last math call left there adds `$C4`·$0222/256 (up to about 2.1 LSB per unit, ≈ 0.5 jiffy at most). The port reads it from memory like the original, so no decision is needed.
   - dt is the 16-bit value (j·$0222 + ⌊`$C4`·$0222/256⌋) mod $10000 for a gap of j jiffies, with the high byte forced to $7F whenever bit 15 is set. With `$C4` = 0: 0-60 jiffies are linear (60 → $7FF8), 61-120 give $7Fxx, 121-180 **wrap** and start again from about one jiffy (121 → $0212), 181-240 give $7Fxx again, 241-255 wrap again; the jiffy difference itself wraps at 256. Only `$32EE` updates `$08CA`, so a pause freezes dt.
3. **Heading** `$0A13` += turnRate × dt. **d** `$0A0F` = V × dt.
4. **Track** = high byte of (heading + `$0A46`), the offset only when airborne (old `$0A12`). `$B9` = track; `$0A42` = sin8(track), `$09EE` = cos8(track): quantized to 1.406°.
5. **Step.** `$09EA` = cosγ × d; `$0A06` east = `$09EA` × sin(track); `$09D8` up = sinγ × d; `$0A36` north = cos(track) × `$09EA`.
6. **Roll.** `$0A34` = (liftLeft − liftRight) << 2; `$09FC` = `$0A34` × `$0A32` − `$0E76:$0E77` (roll cancel). If the cancel was nonzero it is cleared and `skipFlip $0E79` = 1. Bank `$09E0` += (d × `$09FC`) << 1.
7. **Position.** North `$62-$65` and east `$5A-$5D` += the sign-extended deltas (32-bit). Altitude `$5E-$60` += the sign-extended up delta as a **24-bit** value (`$61` untouched); a negative result becomes $000300.
8. While `repositionCounter $0A83` ≠ 0: `$F9C1`, then the counter counts down.
9. **View.** pitch = AoA × `$0A64` − γ (16-bit; a dead add of zero in the front view), + `$0A0B` when airborne (old flag); `$6C` = low, `$6D` = high + `viewPitchBump $0A2F` (then the bump is cleared); `$6E:$6F` = −φ; `$70:$71` = ψ.
10. **Ground contact** ($3515, a fall-through section):
    - `onGround $0A12` = $FF when altitude `$5E-$60` < $000301 (a 24-bit compare), else 0.
    - On the ground: bank and roll term = 0; γ = 0 if negative. Repositioning: `keySpace` $2BC9 (the brakes) and no crash check. Otherwise, only when descending (VS_hi `$0A51` < 0): **crash** if VS_hi + 8 < 0 (≤ −9 m/s) or (viewBank_hi + 10) mod 256 ≥ 20 (|bank| beyond about 10 high-byte units, 14°): `$0834 = 4`, V_hi = 0, then the crash sound `sfxCrash` $CC68.
    - First contact (`wasOnGround $0A11` = 0): `$0E59 = 8` (touchdown), `$0A11` = $FF, `$0A2F` = VS_hi; on later passes `$0A2F` = 0.
    - Airborne after being on the ground: `$0A11` = 0, and if (north+1 & 3) = 0 the altimeter drift target `$09D0:$09D1` = sign-extended (`$22` + C), C being clear (left by the altitude compare).
11. **Vertical speed** `$0A50` = V × sinγ.

### Other per-pass pieces

| Routine | When | Behavior |
|---|---|---|
| `$35BD` | Phase 2 (nothing in slew) | **Density** `$09DA`: `$C4:$C5` = 2m + ⌈m/2⌉ for m = `$0830` (the rounding comes from the rotate's carry), then $7FFE − that − borrow, the borrow being the inverse of the last add's carry: normally **$7FFD − (2m + ⌈m/2⌉)**. **Auto-level** when rudder_hi `$0ABD` = 0: positive bank + $FFB0 + C, negative bank + $0050 + C, C being the carry of the density subtraction (normally 1: −79 / +81 units per pass, ≈ 0.44°), and a result that crosses 0 becomes 0. Then **$3614**: when `$0838` ≠ 0 and V_hi = 0, `$3638`, and with `$0838` = 2 (war) ammo `$0AA5` = 100 and bombs `$08E8` = '5'; a set request is always cleared. |
| `$3638` | Refuel/repair (also vector `$200F`) | Tanks `$09C2/$09C5 = $20`. Masks `$0942/$0943/$08DC/$08DD = $FF`. `$09BF/$08B7 = 0`, `$09C7/$09C8 = 1`, `$08B8` + 1. |
| `$F8AF` | Every pass (draw sequence) | V_hi < $0A: `$0A87` = target `$0843` directly. Then `$F8C5` twice (called, then fallen into): when the target differs (unsigned 16-bit compare), `$0A87` ±1 toward it and the altitude meters `$5F:$60` ∓1, with a floor of 3 m (negative or < 3 → $0003). |
| `$F9C1` | While `$0A83 ≠ 0` (also vector `$2006`) | meters = ((`$096F` + 9) × $4E0C) bits 16-31 (`$188A`: X = `$CA`, `$CB`) − `$0A87`, at least 3; `$5E` = `$61` = 0. |
| `$F916` | Even phases | `maneuverTimer $0E75` − 1 when that is not negative; otherwise reloaded with 6 when (γ_hi + $0F) ≥ $1E (γ_hi ≥ 15 or ≤ **−16**, ~21°), (bank_hi + $16) ≥ $2C (≥ 22 or ≤ −23, ~31°) or (V_hi + $49) ≥ $92 (V_hi ≥ $49, ~73 m/s), else left at 0. While set, the aileron uses `$0A7C` and the γ rate is not halved. |
| `$E766` | Phase 0 | Record by the altitude meters (signed compares): ≥ `shear3 $0992` → `$0994`; ≥ `shear2` → `$0998`; ≥ `shear1` → `$099C`; else `$09A0` with `$09D7` + 1. `$C0/$C1` = record. dir = rec[3] + `$0847`, then `$09D7` is shifted right and `$0849` added when the shifted-out bit is 1. `$A5` = sin8(dir)_hi, `$A7` = cos8(dir)_hi; `$09D3` = mul8Half(dt_hi, mul8x8(rec[0], `$A5`)_hi), `$09D5` likewise with `$A7`. The carries chain from `cos8` through all four multiplies. rec[1] (turbulence) is not read here. |
| `$E716` | Every pass, airborne | East −= `$09D3`, north −= `$09D5` (32-bit; the sign byte goes through `$A5`). Frame-rate dependent: once per pass, scaled by the dt high byte of the last phase-0 pass. |
| `$3660` | Instead of `$32EE` in slew | If `$0A80` (set by every `$32EE` pass): clear it and zero the elevator, rudder, ailerons, `$0AC3` and `$0AC5`. East bytes 1-3 += step(`$0AA4`); north bytes 1-3 += step(−`$0AAC`). Altitude `$5F-$61` += sign-extended `$0AC5`, negative → 0 (then a no-op reload and store of `$60`). View pitch_hi += 2·`$0AC3`, negated when (viewBank_hi + $40) is negative; a pitch high byte outside $C0..$40 flips the view over (pitch negated with its high byte XOR $80, bank and heading high bytes XOR $80). View bank_hi += `$0ABF`; heading_hi −= `$0AC1`. Then **$372B**: `$096B:$096C` = north bytes 2-3 + $4000, `$096D:$096E` = east likewise. **$3746** step(r): r ≥ 0 → 2^(r/4) − 1; r < 0 → $FFFFFF << ⌈−r/4⌉ (24-bit, `$BE`:X:A, `$B9` = A); 35 + 27k / 22 + 23n cycles. |

### Engine `$EE6B` (even phases)

1. **Stop** (`$F074`: `$09C9 = 0`): outside war mode (`$0969`) and in reality mode, when the mixture `$0A9A` = 7 or both magneto/fuel pairs are 0 (`$EE14 & $09C7`, stored in `$B9`, ORed with `$EE15 & $09C8`); in any mode when the selected tank (`$09C6`: 0 left `$09C2`, else right `$09C5`) is empty.
2. **Start.** Outside reality mode a stopped engine simply starts. In reality mode a stopped engine restarts by windmilling when V_hi ≥ $25; with V_hi < $25 and the switch label `$0AB6` = 4 (START) the starter **busy-waits 586,756 cycles** (0.574 s; the port charges it in 255 steps so the clock and its events advance), then `$2837` with X = 3 sets the label to BOTH and the engine runs.
3. **Windmill** `$BC` = `$EE37`[min(31, V_hi >> 2)].
4. **Effective throttle** Y: 0 when stopped. With carb heat `$0AA9`: −8, or −$20 while `$EE16` counts down (decremented); negative → 0. Failure bits 0-1 of `$09BF`: capped at $10. A dead magneto/fuel pair: −4, floor 0.
5. **Target** `$0E58` = `$EE17`[Y >> 2] (0 when stopped). **Thrust** `$0A48` = ((target < $0E ? 0 : target) : $00) × $07D0 (`$17F6`), × density.
6. **Shown RPM**: `$0E58` = `$BC` unless `$BC` − `$0E58` is negative (the N flag, not an unsigned compare); outside reality mode at least $0D.
7. **Oil.** Temperature `$09CA:$09CB` ramps by $19/256 toward 0 (stopped), 9, or 18 (failure bit 0); pressure `$09CC:$09CD` by $FA/256 toward 0 (stopped or failure bit 1) or 10 (compared with the high byte). An increase whose high byte carried out would fall into the decrease, but the targets keep the high byte ≤ $11 there, so it never happens.
8. **Fuel** (running, `$22` bit 1 set, i.e. phase 2): burn = mul8Half(−5, throttle) (−40 in war mode) into `$A5/$A6`. Leak bit 2: `$09C2` − 1, undone if it goes negative. Left tank selected: `$09C0` += burn_lo; when burn_hi is non-negative the routine **returns here** (the right leak is skipped); else `$09C1` += burn_hi and `$09C2` += $FF + carry unless the result is negative. Then leak bit 3 and the right tank (`$09C3/$09C4/$09C5`) likewise. The tanks are 24-bit amounts with the gauge byte on top (settles the "fuel units" open question).

### Reality mode failures `$EA84` (phase 3) and the trim creep `$EAE2`

Outside reality mode `$EA84` jumps to `$EB0C`, which zeroes `$09CE/$09CF` and `$08C0/$08C1`
(33 cycles). In reality mode:

1. `$08CD` − 1; when it goes negative: `$08CD` = 10 and, with **the caller's carry** (left by the oil-pressure gauge `$1CBE`), if (north+1 + east+1 + C) mod 256 < 100 and ≥ reliability `$09A4`, `$EB1B` triggers a failure: `$1EAF` clears the window, `$1DDE` draws 'AIRCRAFT PROBLEM !!!!' at (50,20), and handler ((`$22` + `$5F` + C) & $0E)/2 of `$EA5C` runs through an indirect jump via `$00BC` (C = the carry `$1DDE` returns, clear for the $00 terminator). `$BC/$BD`, the jump pointer, is the zero-page word whose low byte the engine model uses as the windmill RPM (`sharedPointerBC` in `symbols.json`). Handlers: 0/2/3/5/6/7 clear bit 0/2/3/5/6/7 of `$0942` (instrument failures), 1 sets bits 0-1 and 4 bits 2-3 of `$09BF` (engine; fuel leaks). The handler's return lands at `$EAA6`.
2. **Altimeter drift**, with a quirky compare: h = `$09CF` − `$09D0` (the drift target's **low** byte); `$09CE:$09CF` += 2 when h < 0, −= 2 when h | `$09CE` ≠ 0 (`$B8` = `$09CE`).
3. **DG drift**: `$08C0:$08C1` += 2.

`$EAE2` (1 Hz tick, even TOD seconds): in reality mode the elevator high byte moves 2 toward
`$0AAE` (a signed compare through the overflow flag: elevator − trim overflowing positive or
negative without overflow → +2, otherwise −2, equal → unchanged), then $2D58 refreshes the
elevator indicator even when nothing changed.

### Crash, splash and the message

| Routine | Behavior |
|---|---|
| `$F996` (even phases) | On the ground, window bitmap byte `$50DE` (y 110, x 152-159) = $55 (water), front view (`$0ACA = 0`), not radar (`$0836`), not repositioning: `$0E7F` − 1; at 0 `$0834 = 8`. Any failed condition (and the hit) reloads `$0E7F = 3`. It reads the rendered frame, so the window bitmap must keep the C64 layout. |
| `$F95D` (flip passes, A = `$0834`) | `$BA/$BB` = 'SPLASH !!!' `$F950` for A = 8, else 'CRASH !!!' `$F944`; `$0E59 = 2`, `sfxCrash` $CC68 (crash noise; the handler overwrites the state), `$0834 = 0`, `$1EAF`, the text at (50, 20), `$F25B` with Y = 5 (`busyDelay`: 2,283,560 cycles, about 2.2 s), `$08BB = 1` (the editor reloads the mode). |

## Aircraft constants

These values are never written by code, so they are part of the cold image.

| Name | Value | Name | Value |
|---|---|---|---|
| CL0 `$09E2` | 300 | CD0 `$09E4` | 2400 |
| Induced k `$09E6` | 30000 | Lift scale `$0A27` | $59D8 |
| 1/mass `$0A30` | 10000 | Roll scale `$0A32` | $4000 |
| W `$0A52` | 2500 | AoA→pitch `$0A64` | −3500 |
| Slip roll `$0A66` | −4000 | Slip yaw `$0A68` | −7500 |
| Slip track `$0A6A` | 30000 | Flap drag `$0A6C` | 5000 |
| Slip drag `$0A70` | 1280 | Drag bias `$0A74` | 5 (low byte only) |
| Aileron `$0A7A` / maneuver `$0A7C` | 3000 / 4500 | Flap lift `$0A7E` | 4000 |
| Lift slope `$0A78` | 25000 | | |

No users were found in the resident code for `$0A54`, `$0A5E`, `$0A60`, `$0A62`, `$0A6E`, `$0A72` and `$0A76`. They may belong to the war overlay or the 3D engine.

The gain tables `$0E10/$0E1A/$0E24/$0E42` hold 10 bytes each, indexed by V_hi>>4 and interpolated (`$19E2` reads t[i+1], so a high V_hi reads into the next table).

## Tests

- `Tests/DifferentialTests/FlightModelTests.swift` runs every routine of the flight model on twin images (`DiffRig`) and compares the whole memory (stack page excluded), the cycle count and the SID stores (order and values) after every call.
  - States: three recorded flights cached through `Original.snapshot` (53 states): the take-off roll, braking, lift-off, climb, cruise and a stall series (horn, stall timer, porpoising) into a crash; a climb and a steep right spiral (bank through 180°, γ to −67°, 115 m/s) into a crash; moving into the lake (splash), slew with every rate, leaving slew in mid-air, and reality mode (reliability 0) with wind and a failure, low over the water.
  - Random perturbations of each routine's inputs on every state (thousands of calls per routine), plus grids: γ at every high byte (reflection), exact γ edges ($4000, $8000, $C000 and neighbors, with the γ rate forced to 0), every jiffy gap 0-255 with several stale `$C4` values (the dt saturation and wrap), ground contact at every vertical speed × bank, auto-level at every bank, every slew rate, every failure handler, trim × elevator, the starter, the regime timer, the crash and splash message.
  - Multi-step runs: from ten states, 300 passes each of the 5 Hz aerodynamics, control inputs, the integrator, wind, ground tracking and the phase tasks (engine, density, regime timer, splash, wind layer, failures, trim), the jiffy clock advancing 2-6 frames per pass; and 200 passes from five states with slew mode toggling every 25 passes (the `$0A80` handshake between `$32EE` and `$3660`). Both sides keep their state and every call is compared.
  - Coverage (measured with a trace of the original during the tests): all 1,567 instructions of the flight model's code execute, and every conditional branch is seen both taken and not taken except the ones that cannot go both ways (`$302F`, `$3600`, `$EABF`, `$EAF6`, `$EE9E`, `$F8DB` and the handlers' final branches always branch; `$EFA6`/`$EFDE`, the oil ramps' carry out, cannot happen).
- `Tests/FS2CoreTests/FlightModelUnitTests.swift`: the formulas, thresholds, quirks and cycle costs above on synthetic memory (no disk).

## Port status

- `FixedMath` reproduces every vector above; the cosine table is read from the disk image, never
  regenerated (`math.md`).
- Integer, bit-exact ports of `$2E92-$3772`, `$E716-$E7F1`, `$EA5C-$EB81`, `$EE14-$F079` and
  `$F8AF-$F9F8`, with exact cycles (`Sources/FS2Core/Sim/`).
- A virtual NTSC clock drives the jiffy, the 10/5/1 Hz ticks and the TOD (`InterruptScheduler`,
  `TimeOfDayClock`); the replays reproduce the lab's interrupt placement exactly (`ReplayDriver`,
  `main-loop.md`).
- Per-pass effects keep the authentic cadence (the ported main loop); Smooth pacing only
  interpolates the picture (`engine.md`). Busy-waits are charged on the clock in steps (the
  starter, `busyDelay` for the crash message and the ATIS end, the TOD calibration).
- The variables live at their original addresses in `Machine.mem` (`FlightModel.RAM`), in the
  units of the table above.
