# Instrument panel: gauges, indicators and failure masks

The port of the needle and marker code $1A0B-$1D53, the gauge drivers $CE84-$CFB3, the
instrument enable masks and failure graphics $F2E6-$F521, and the 10,000-ft marker $F7DB-$F8AE.
Swift: `Sources/FS2Core/Panel/` (`Gauges*.swift`, `Instruments*.swift`). Differential tests:
`Tests/DifferentialTests/GaugeTests.swift`.

Related pages: `display.md` (VIC layout, the raster split, the attitude indicator $A378 and
turn coordinator $A532, both drawn by the 3D module), `modes-ui.md` (the readouts, the nav
instruments and the radio stack), `raster.md` (the row tables and the 3x5 font used by the
digital readouts), `flight-model.md` (the main-loop phases and the 5 Hz tick).

| File | Routines |
|---|---|
| `GaugesNeedles.swift` | `drawNeedle` $1A86 (with $1AFE/$1B17/$1B30/$1B3F/$1B4B), `updateAltimeterNeedles` $1A0B, `updateAirspeedNeedle` $1A32 (with $1A61), `updateVsiNeedle` $1A6A; the `Gauges` namespace and `Gauges.NeedleQuadrant` |
| `GaugesMarkers.swift` | `plotPointList` $1D01, `plotMarkerShape` $1BC3 (and $1BC7), the control indicators $1B92-$1C33, `drawTurnBall` $1C3D, the fuel and oil bars $1C5D-$1CE6, `drawFuelSelectorMarker` $1CF0 |
| `GaugesDrivers.swift` | `altimeterUpdate` $CE84, `airspeedUpdate` $CF0E, `vsiUpdate` $CF46, `slipBallUpdate` $CF79, `draw10kMarker` $F86F (with $F89E) |
| `InstrumentsMasks.swift` | `updateInstrumentMasks` $F35E, `applyMaskChanges` $F3B3, `toggleInstrumentArea` $F3F0 (with $F493/$F4A9), `bitmapBitAddress` $F4C5, `pushSavedBit` $F4E0, `popSavedBit` $F502; the `Instruments` namespace |

Every routine is a literal translation: each byte the original reads is read from `mem` at the
moment the original reads it (registers become locals), every byte it writes is written in the
same order, including zero-page temporaries and the self-modified opcodes, and the original's
exact cycle count is charged (the final return included, the caller's call excluded). Reads that
cross a page get their extra cycle. Nothing touches I/O. The only routines this part calls outside
its ranges are `mulQ15AX` ($17EF) and `mul8Half` ($1961), the math library's (`math.md`).

## The panel bitmap

- Hi-res, 320×88, rows 112-199 of bitmap A ($5180-$5F3F), loaded from disk blocks 6-9. Rows
  are reached through the row tables ($0200 high / $02C8 low), which always point the panel
  rows at bitmap A (only window rows 0-111 follow the double buffer).
- A pixel x is bit `7 - (x & 7)` of byte `rowBase + (x & $1F8)`; the code adds bit 8 of x as
  a page (+$100). Masks: $0F08 (80..01) for the needles and point lists, $F4BD (the same values)
  for the failure graphics.
- Everything that moves is drawn with **XOR** and erased by drawing it again: the needles, the
  linear markers, the slip ball, the 10,000-ft marker. Two shapes that overlap cancel where they
  cross (the altimeter hands). Nothing redraws the static artwork, so the bitmap is persistent
  state: the port keeps it in `mem` and applies the same XORs in the same order.
- Nothing clips. A marker driven past the bottom of the panel reads rows 200+ past the row tables:
  the high byte comes from $0200 + row, which from row 200 on is the low-byte table ($02C8 =
  row 0's low byte), and the low byte from $02C8 + row, which from row 200 on is the free zero
  bytes at $0390. Rows 200, 201 and 202 therefore have the bases $0000, $0100 and $0200, and the
  XOR lands in pages 0-2. The elevator indicator does this for positions 29-31, which its
  caller ($2D58: ($50 - `$0AAC`) >> 3, 8-bit) computes for an elevator high byte of $51-$68,
  just past the $50 limit of the elevator keys (so only from other writers of `$0AAC`, such as
  the editor's mode settings at $B66D; the keys alone give 0-20). Its 2×3 block at x 108-109 toggles bits of `$0068` (`eyeRelY`, low byte), `$0168`
  (the stack page) and `$0268` (the row-table high byte of window row 104, which the double
  buffer re-bases every pass), and the erase toggles them back. The port does the same; the
  tests compare $0100-$01EF after every call for it, since `DiffRig` skips the stack page.

## Layout

Positions are hi-res pixels (x 0-319) and bitmap rows (112-199). Cadence: "pass" is one main-loop
iteration; "phase n" is the passes with `$22 & 3 = n`; "5 Hz" is the aero step of the 10 Hz tick
($23B1), which the scenery interpreter polls.

| Instrument | Drawn at | Drawn by | Input | Cadence | Mask bit |
|---|---|---|---|---|---|
| Airspeed needle (long) | center (25, 136) | $1A32 → $1A86 gauge 2 | target `$0A84` from $CF0E (`$0A4C/$0A4D`) | target every pass, needle 5 Hz | `$FD` b0 |
| Altimeter hands (long, short) | center (141, 136) | $1A0B → $1A86 gauges 0/1 | `$1F`/`$20` from $CE84 (`$5F/$60`, `$0A87`, `$09CE`) | every pass | `$FD` b3 |
| 10,000-ft marker | origin (12, 10); the shapes hold absolute points, x 140-164, rows 115-153 | $F86F | `$60` | phase 1 | `$FD` b3 |
| VSI needle (short) | center (141, 180) | $1A6A → $1A86 gauge 3 | target `$21` from $CF46 (`$0A50/$0A51`) | target odd passes, needle 5 Hz | `$FD` b7 |
| ADF needle (short) | center (203, 182) | $E7FE → $1A86 gauge 4 | the ADF code (state `$E7F6`, `radios.md`) | odd passes | `$FF` b3 |
| Slip ball | x 14 + v, row 190 | $CF79 → $1C3D | `$09F3` / `$0ABD` | even passes | `$FD` b1 |
| Elevator | x 108, row 169 + v | $1B92 | ($50 - `$0AAC`) >> 3 | key and joystick handlers | — |
| Ailerons | x 93 + v, row 158 | $1BAC | (`$0AA4` + $7F) >> 3 | handlers | — |
| Rudder | x 93 + v, row 196 | $1BCD | (`$0ABD` + $7F) >> 3 | handlers | — |
| Throttle | x 225, row 198 - v | $1BE1 | `$0AC9` >> 3 | handlers | — |
| Flaps | x 225, row 115 + v | $1BFD | `$0AB0` >> 4 | handlers | — |
| Elevator trim | x 225, row 148 + v | $1C10 | ($50 - `$0AAE`) >> 4 | handlers | — |
| Mixture | x 232, row 185 + v | $1C23 | `$0A9A` 0-7 | RETURN, ',' '.' ($E9F0/$EA25) | — |
| Fuel left / right | x 260 / 295 + v, row 178 | $1C5D / $1C75 | `$09C2` / `$09C5` >> 1 | phase 0 / phase 1 | (area `$FE` b5) |
| Oil temperature / pressure | x 260 / 295 + v, row 186 | $1CA7 / $1CBE | `$09CB` / `$09CD` | phase 2 / phase 3 | (area `$FE` b6) |
| Fuel selector | x 287, row 179 | $1CF0 | toggled per change of `$09C6` | CTRL-F, ',' '.' ($295F/$2AA5) | — |

The digital readouts (DG, clock, radios, tach, ...), the nav needles, the attitude indicator
and the turn coordinator's wings are specified elsewhere; see `modes-ui.md` and `display.md`.
(The readouts are documented under "Digital readouts" below, the nav instruments and the ADF in
`radios.md`.)

### Main-loop order

After the draw sequence (horizon, scenery, tach, AI, OBIs, ground elevation, heading, DG,
compass, lights, war slot, view overlays) every pass runs `altimeterUpdate` ($2104),
`airspeedUpdate` ($2107) and `updateInstrumentMasks` ($210A), then the phase tasks:

| Phase | Panel tasks |
|---|---|
| 0 | left fuel $1C5D (with the TC wings $8012); then slip ball $CF79 |
| 1 | right fuel $1C75, 10,000-ft marker $F86F; then VSI target $CF46 |
| 2 | oil temperature $1CA7; then slip ball $CF79 |
| 3 | oil pressure $1CBE (with reality failures $EA84); then VSI target $CF46 |

The 5 Hz step ($23B1, skipped while paused) runs the aero model, then `updateAirspeedNeedle`
($23B4) and `updateVsiNeedle` ($23B7).

## Needles

### drawNeedle ($1A86; A = angle, X = gauge)

- 88 steps per turn: 0 points at 3 o'clock, 22 up, 44 at 9 o'clock, 66 down; angles increase
  counterclockwise.
- Per gauge: center x `$0F67`, row `$0F6C`, type `$0F71` (0 = long, pointer table $0F76, else
  short, $0FA6). Gauges: 0 altimeter long hand, 1 short hand, 2 airspeed (long), 3 VSI (short),
  4 ADF (short).
- Each table holds 23 pointers (shape index 0-22) to run-length shapes: one `(dx, run)` pair per
  scanline, ended by a byte with bit 7 set.
- The quadrant patches the scanline loop $1B4B (four self-modified opcodes) and picks the index:

| Angle | Quadrant | Index | Horizontal ($1AFE / $1B17) | Vertical ($1B30 / $1B3F) |
|---|---|---|---|---|
| 0-21 | right, up | a | x = (cx - 1) + dx, run drawn rightward | first row cy + 1, rows going up |
| 22-43 | left, up | 44 - a | x = (cx + 1) - dx, run drawn leftward | cy + 1, up |
| 44-65 | left, down | a - 44 | leftward | first row cy - 1, rows going down |
| 66-87 | right, down | 88 - a | rightward | cy - 1, down |

  Patches: $1B56 and $1B59 make the run start add or subtract the shape's dx, $1B87 steps x right or
  left, $1B8D steps the row up or down. All 8-bit: index arithmetic wraps for angles of 88 and more
  (88 is index 0 in the lower right quadrant; larger angles read pointers out of the shape data).
- A run XORs `$0F08[x & 7]` into byte `x & $F8` of the row: x is 8 bits, so the needles must
  stay left of x = 256. A run of 0 is 256 pixels.
- Memory: `$0A8C` = angle, `$0A8D` = gauge, `$94/$95` = pointer table, `$96/$97` = shape,
  `$A5`/`$A7` = mirrored origin then the running row, `$E8` = last x, `$E9` = index of the end
  byte, `$9A/$9B` = row base, `$0A8E` = 0. It does not touch `needleAngles`.
- Cycles: 88 + 3 (long) or 12 (short) + 95 / 100 / 92 / 85 (quadrant right-up / left-up /
  left-down / right-down) + per scanline 67 + 44 × run, +1 at rows >= 56 (every panel row),
  +1 per indirect indexed read across a page. Lab check: the long hand at angle 0 (runs 10, 21, 10)
  costs 2194 cycles.

**Port.** The quadrant is explicit Swift state (`Gauges.NeedleQuadrant`); the four patch bytes
are still written, and since `drawNeedle` always writes all four before the loop runs, the
quadrant fully determines them.

### The drivers

- **Altimeter ($1A0B).** When the long-hand target `$1F` differs from the drawn `$0F62`: erase the
  long hand, erase the short hand (`$0F63`), store and draw the short hand at `$20`, store and draw
  the long hand at `$1F` (the shared tail $1A2B stores the angle by gauge and draws it). The short
  hand alone never triggers a redraw. 17 cycles when unchanged, else 80 + four `drawNeedle` calls.
- **Airspeed ($1A32, 5 Hz).** Only with `$FD` bit 0 and the drawn angle `$0F64` != target
  `$0A84`. Erase the old angle (kept in `$B8`), then new = old + (target - old) >> 2 (8-bit
  difference, arithmetic shift), + 1 when that is not negative: a quarter of the way, at least
  one step, never past the target. The stored angle is not wrapped (the targets reach 110);
  $1A61 draws angles of 88 and up at angle - 88. A difference over 127 in 8 bits turns round
  (the real targets, 26-110, never do). Cycles: 14 disabled, 26 settled, else 68 (69 for a
  negative step) + 8 or 9 per $1A61 + two `drawNeedle` calls.
- **VSI ($1A6A, 5 Hz).** No mask test. When `$0F65` != target `$21`: erase, then one step toward
  the target by an unsigned compare (the targets stay in 4-79), store, draw. A failed VSI's
  needle therefore still settles on the frozen target. 18 cycles settled, else 60 (up) / 63
  (down) + two `drawNeedle` calls.
- `$0F66` (gauge 4) is never used: the ADF code ($E841) keeps its angle in `$E7F6` and calls
  `drawNeedle` with X = 4 itself.

## Gauge drivers

### Altimeter ($CE84, every pass, `$FD` bit 3)

1. `$0A8A/$0A8B` = `$5F/$60` (read back by the glideslope at $3DB5); MSL `$0830` = `$5F:$60` +
   field elevation `$0A87`.
2. `$C4:$C5` = MSL + altimeter offset `$09CE` (CTRL-B clears it; reality mode drifts it), then
   `mulQ15AX($24F4)`: steps of 1000 ft / 88 (1 m = 0.2887 step). The product is signed, so MSL
   + offset above 32767 counts as negative.
3. Mod 880: subtract 880 while the 16-bit result stays non-negative (loop $CEBA; a negative
   product is kept unchanged) → `$A5/$A6`.
4. Short hand `$20` = 21 - `mulQ15($0CCC)` (steps / 10), + 88 when negative, capped at 87.
5. Long hand `$1F` = 21 - (steps mod 88), + 88 when negative, capped at 87; the mod 88 is a
   subtract loop over the 16-bit value that ends when the high byte goes negative ($CEF1).
6. On into `updateAltimeterNeedles` $1A0B.

Cycles: 13 disabled, else 158 + 25 per extra 880 subtracted + the mod-88 loop (7 per 88 without
a borrow, 11 per borrow, 10 for the last) + 3 per hand that needs the + 88 and 1 per capped hand
+ the two multiplies + `updateAltimeterNeedles`.

### Airspeed target ($CF0E, every pass, `$FD` bit 0)

v = min(`$0A4D`, $5A); i = v >> 2; t0 = `$14C2[i]` (in `$B8`); d = `$14C2[i+1]` - t0 (8-bit);
f = ((v << 1) | bit 7 of `$0A4C`) & 7, eighths of the table step; target `$0A84` = t0 + high byte
of `mul8Half(x: f·16, y: d, carry: 0)`. Since x·y's high byte is f·d/16, the interpolation covers
only **half** of each table step, so the needle jumps at every fourth unit of the airspeed high
byte. The table is decreasing (110 down to 26): the needle turns clockwise as speed rises.
13 cycles disabled, else 91 (92 when clamped) + `mul8Half`.

### VSI target ($CF46, odd passes, `$FD` bit 7)

h = `$0A51` clamped to -9..9. Two left rotates build a: the first shifts in the carry the clamp
compare left (1 for h >= 9 and for -9 <= h < 0, else 0), the second bit 6 of `$0A50` (the code
compares `$0A50 << 1` with $80, so it tests bit 6, not bit 7): a = 4h + 2c + b6. Target `$21` = ($83
- a) mod 88, so level flight is 43 (9 o'clock), climbs turn toward 4, descents toward 79. Y is left
as `$0A50 << 1` plus the caller's carry.

### Slip ball ($CF79, even passes, `$FD` bit 1)

Input: airborne (`$0A12` = 0) the slip high byte `$09F3`; on the ground 0 when `$0A4D` = 0, else
-`$0ABD` (rudder). Position = ((input + $7F) >> 2) - $1F, clamped to -8..8 (any value of 9 or more
gives 8), + 9: 1-17. Then on to $1C3D, which redraws only when the position differs from `$0A95`.

### 10,000-ft marker ($F86F, phase 1, `$FD` bit 3)

index = min(8, ((`$60` + 2) & $FF) / 6), by a subtract-6 loop: one step per 1536 m. When it
differs from `$F7DB`, the old shape is erased (skipped while `$F7DB` is negative: $FF = none drawn,
the cold value) and the new one drawn, both by $F89E: `$9C/$9D` = `$F7DC[2i]`, then `$1BC3` at
(12, 10). The nine shapes hold absolute coordinates (dx around 140-152, dy 105-143).

## Point lists and linear indicators

### plotPointList ($1D01; X = x, Y = row)

`($9C)` = `[count][dx, dy] × count` (count 0 = 256). Per point: x = X + dx, whose carry is added
into `$0A90` and never cleared, so it accumulates over the list; row = Y + dy
(8-bit); `$8E/$8F` = row base, + $100 when `$0A90` is nonzero; byte `x & $F8` ^= `$0F08[x & 7]`.
Memory: `$0A9F` = X, `$0AA0` = Y, `$0AA1` = list index, `$F3` = 0, `$8E/$8F`. Cycles: 30 + 104 per
point (108 when `$0A90` != 0) - 1, + 1 per point at rows >= 56, + 1 per read across a page (the
slip ball, 12 points: 1289).

Entries: $1BC3 (`$9D` = A, `$0A90` = 0; `$9C` set by the caller; 12 cycles + $1D01), used by the
markers, the 10,000-ft marker and the localizer needles ($3D80); $1BC7 (`$0A90` = A; 7 + $1D01),
used by the fuel selector.

### The indicators

Every indicator has the same frame: it keeps the new value aside, draws the old state (the XOR
draw erases it), stores the new value as the state and falls or jumps into the draw again, which
draws the new one (21 cycles + 2 × the draw). The fuel and oil gauges first compare the source
with the state and return when equal.

| Routine | State | Draw (x, row) | Shape | Draw cycles |
|---|---|---|---|---|
| $1B92 elevator | `$0A93` | (108, $A9 + v) | $0F10, 2×3 block | 30 + $1D01 |
| $1BAC ailerons | `$0A94` | ($5D + v, 158) | $0F1D, 5-3-1 triangle | 27 + $1D01 |
| $1BCD rudder | `$0A96` | ($5D + v, 196) | $0F1D | 30 + $1D01 |
| $1BE1 throttle | `$0A97` | (225, $C6 - v) | $1612, 2×2 | 32 + $1D01 |
| $1BFD flaps | `$0A98` | (225, $73 + v) | $161B, two 1×2 bars | 33 + $1D01 |
| $1C10 trim | `$0A99` | (225, $94 + v) | $161B | 33 + $1D01 |
| $1C23 mixture | `$0A9A` (the mixture itself) | (232, $B9 + v) | $161B | 30 + $1D01 |
| $1C3D slip ball | `$0A95` | ($0E + v, 190) | $0F30, 4×4 disc | 30 + $1D01 |
| $1C5D / $1C75 fuel | `$0A9B` / `$0A9C` | (260 / 295 + v, 178) | $0F49, 2×6 bar | 29 + $1D01 |
| $1CA7 / $1CBE oil | `$0A9D` / `$0A9E` | (260 / 295 + v, 186) | $0F49 | 32 + $1D01 |

- Fuel and oil: the right-hand bars add $23 to the stored value before drawing. The bar code
  ($1C8F/$1CD7) sets `$0A90` = 1 + the carry of v + 4, so x = 256 + ((v + 4) & $FF).
- Fuel selector ($1CF0): XORs the 4 corner pixels of a 4×3 box at (287, 179), `$0A90` = 1. It
  has no state; the tank-select keys call it once per change (26 cycles + $1D01).
- Callers keep their own caches too: `$2715` (elevator) and `$2716` (ailerons) are compared in the
  key handlers before calling.

## Instrument enable masks and failure graphics

### updateInstrumentMasks ($F35E, every pass)

For k = 0, 1, 2: new = `$09A6[k] & $0942[k] & $0945[k]` (settings, failure masks, lighting
masks). When it differs from `$FD[k]`: `$9E` = new, `$A0` = old, store, then $F3B3 over the
k-th area table ($F2E6, $F316, $F346). 60 cycles when nothing changed.

$F3B3 handles bits 0-7 in order: `$B8` = old bit, `$B9` = new bit, `$BA/$BB` = the 6-byte entry,
`toggleInstrumentArea` $F3F0, then shift `$9E`/`$A0` right and advance `$BE/$BF` by 6 (`$A2`
counts).

### toggleInstrumentArea ($F3F0)

Nothing when the bits are equal. Otherwise the entry gives the area: `[x low][rows << 1 | x bit
8][first row][width][save buffer word]`. The area is walked row by row, left to right, through
the row tables ($F4C5 builds `$BA/$BB` and the bit mask). `$F3EF` counts the bits of the current
buffer byte (from 0; at 9 it becomes 1 and `$BC/$BD` moves on).

- **Failure (new bit 0).** Each pixel's bit is read and cleared ($F493) and pushed into the buffer
  ($F4E0 rotates the bit through the carry into the buffer byte). Afterward the last byte is
  shifted left until its first bit is bit 7. The instrument goes blank and stays frozen (its
  driver tests the bit).
- **Repair (new bit 1).** Each pixel takes the next bit ($F502 rotates the buffer byte left; the bit
  that falls out is the pixel) and XORs it in ($F4A9; a 0 bit stores the byte back unchanged). The
  rotate takes in the carry of the counter's compare with 9, 1 on the first bit of every byte but
  the first, so a repair leaves the buffer bytes as $80 (the first one $00).
- Because the repair XORs rather than copies, anything drawn into a failed area meanwhile stays
  (the VSI's 5 Hz needle step, which does not test the mask).
- Cost: about 185 cycles per pixel. Failing the airspeed indicator (51 × 45) takes 426,752
  cycles, 25 frames; the altimeter 443,536.

### The areas

| Mask bit | Area (x, row, width × rows) | Covers | Save buffer |
|---|---|---|---|
| `$FD` b0 | 0, 114, 51×45 | airspeed indicator | $C000 |
| `$FD` b1 | 3, 160, 45×40 | turn coordinator | $C11F |
| `$FD` b2 | 58, 160, 46×40 | DG | $C200 |
| `$FD` b3 | 114, 114, 53×45 | altimeter | $C2E6 |
| `$FD` b4 | 57, 114, 2×2 | blank pixels (no driver tests b4) | $C411 |
| `$FD` b5 | 172, 115, 48×41 | NAV1 OBI | $C412 |
| `$FD` b6 | 243, 194, 53×5 | RPM row (tach) | $C508 |
| `$FD` b7 | 118, 160, 46×40 | VSI | $C52A |
| `$FE` b0 | 230, 163, 26×5 | TIME label | $C610 |
| `$FE` b1 | 275, 147, 38×5 | XPNDR label | $C621 |
| `$FE` b2 | 230, 131, 32×5 | NAV 1 label | $C639 |
| `$FE` b3 | 230, 114, 32×5 | COM 1 label | $C64D |
| `$FE` b4 | 230, 114, 2×2 | compass (in the window): a 2-pixel nick in the C of COM | $C661 |
| `$FE` b5 | 237, 177, 81×7 | fuel row | $C662 |
| `$FE` b6 | 245, 185, 73×7 | oil row | $FF80 |
| `$FE` b7 | 230, 114, 2×2 | radios: the same nick | $FFC0 |
| `$FF` b0 | 297, 195, 21×5 | CH label | $FFC1 |
| `$FF` b1 | 230, 147, 32×5 | NAV 2 label | $C7C0 |
| `$FF` b2 | 275, 131, 25×5 | DME label | $FFCF |
| `$FF` b3 | 172, 158, 53×42 | NAV2 OBI / ADF | $C6A9 |

- The `$FF` table has 4 entries. Bits 4-7 would read the code at $F35E as entries: bit 4 an
  83-row window area at (173, 9) saved over $0942-$0B15 (the masks' own factors), bits 5-7 areas
  whose buffers overwrite the running $F35E code or that wrap past row 255 into the stack page.
  `$09A8` = $0F keeps those bits 0. The port follows the original for bit 4 (tested); bits 5-7
  are not exercised.
- The buffers at $C000-$C7D3 lie in the dead debug monitor. Streamed scenery never reaches them:
  the loader's `$7327` guard drops every byte a load would store at $C000 and above
  (`scenery-3d.md`). The ones at $FF80-$FFDE are free memory below the vectors.
- `$FD` b4 has no tester; the attitude indicator ($A378) is drawn regardless of the masks.

## Tests

`GaugeTests` (21 tests, about 41,500 calls, about 20-25 s in a debug build once the snapshots
are cached; a cold cache first boots the lab for the demo snapshot) run on the regular-flight and
demo snapshots with `DiffRig`, comparing the whole image (stack page excluded), the modeled
registers and the cycles after every call. On top of `DiffRig`, every test checks at the end that
the original wrote nothing to $D000-$DFFF (this code does no I/O) and that $0100-$01EF match; the
indicator and main-loop tests compare $0100-$01EF after every call (the elevator's $0168 toggles
cancel over a draw/erase pair, so only a per-call check sees a port that skips them).

- `drawNeedle`: every gauge × every angle, twice (the panel must return to its start), draw/erase
  pairs, angle 88, and every center with the other needle type.
- Altimeter: altitude swept 0-12,500 m in 9-m steps (every long-hand step, both hands wrapping
  at 880 and 88), back down through negative MSL with a field elevation and offset, 1500 random
  16-bit states, disabled; `$1A0B` with overlapping hands at every angle and the short-hand-only
  case.
- Airspeed: every high byte with the low bytes around bit 7, disabled; the 5 Hz smoothing to
  50 targets (stored angles past 88) and the target→needle chain.
- VSI: every high byte × 8 low bytes × the incoming carry; the 1-step needle over the full scale
  and the chain.
- Slip ball: every slip byte up and down, the ground cases, every ball move.
- Indicators: each control marker over its range up, down and random (the elevator to row 202),
  fuel and oil bars with the x-carry values, the fuel-selector toggle.
- Point lists: every shape (including the 10,000-ft shapes and the localizer bar) at random
  positions with the `$0A90` carry accumulating, and through $1BC3.
- 10,000-ft marker: `$60` 0-255 up and down from the states $FF, 0 and 8, random, disabled.
- Masks: every bit of `$FD`/`$FE` and `$FF` b0-b3 failed and repaired (the panel returns to its
  start), random groups through all three factors, `$FF` bit 4 both ways, a failed VSI/ASI whose
  needles keep stepping, the altimeter failed and repaired; `$F3F0` on 120 random areas (x across
  256, buffers across pages); `$F4C5` for every x on sampled rows; push/pop runs across the
  counter wrap and buffer page crossings; `$F3B3` on each table with random mask changes.
- Interleaving: 240 main-loop passes in the original's order ($CE84, $CF0E, $F35E, the phase
  task, the VSI target or slip ball, the 5 Hz needle steps every other pass, control moves now
  and then) while the flight drifts and single mask bits of the failure and lighting factors
  flip at random, so area saves and restores meet the gauges' XOR state at arbitrary points.

Mutation checks make the relevant tests fail: an off-by-one cycle in a driver, a dropped carry in
`popSavedBit`, a flipped bit in the final save-buffer shift of $F3F0 (caught by the interleaving
test) and a point-list XOR skipped in the stack page (caught only by the per-call stack check).

# Digital readouts, time of day and panel lighting

The port of the readout code $2240-$224F, $3773-$3AF0 and $EB82-$EBA4 and of the time-of-day
code $EBA5-$EC98. Swift: `Sources/FS2Core/Panel/Readouts.swift`,
`Sources/FS2Core/Radio/RadioDisplays.swift` (the radio stack readouts, see `radios.md`) and
`Sources/FS2Core/Display/TimeOfDay.swift`. Differential tests:
`Tests/DifferentialTests/ReadoutTests.swift`. The nav instruments ($3B32-$3F89) and the ADF
($E7F2-$EA5B) are in `radios.md`.

The same rules as above: literal translation, every byte read and written in the original's
order (zero-page scratch included), exact cycles (own instructions through the return; the
call itself belongs to the caller), no I/O.

| File | Routines |
|---|---|
| `Readouts.swift` | `panelRedraw` $2240, `radioGate` $3A53 (internal), `headingReadout` $3773, `drawDgDigits` $377C, `headingToDegrees` $37EA, `wrapDegrees` $37F5, `format3Digits` $3804 (with a copy of $1DBB), `updateCompass` $3823, `drawObs1` $3923 / `drawObs2` $3976 (with `obsDigits` $395E), `drawClockSeconds` $39B6, `drawClock` $39D9, `drawDme` $3A13, `drawMagnetoLabel` $3A71, `drawTach` $3AB9, `drawSlewReadout` $EB82; the `Readouts` namespace |
| `RadioDisplays.swift` | `parseFrequencyDigits` $3896, `drawNav1Frequency` $38BD, `renewNav1Search` $38D4, `drawNav2Frequency` $38D9, `renewNav2Search` $38F5 (with $38F7), `drawComFrequency` $3903, `drawTransponder` $3A5C; the `Radio` namespace |
| `TimeOfDay.swift` | `updateLightingMasks` $EBA5, `selectTimeOfDay` $EBF2, `applyPalette` $EC41, `fillWindowColors` $EC7C; the `TimeOfDay` namespace |

This part calls the text routines $1DDE, $1D54, $1E99 and the digit routine $1DBB
(`printDigit`; `Raster/Text.swift`), `mulQ15AX` $17EF and `mulU16` $188A (`math.md`).

## Text records

Every readout is a text record `[row][x / 2][ASCII...][0]` (`raster.md`): the code stores the
digits into the record in memory and redraws it with $1DDE. The 3x5 cells are opaque, so a
redraw replaces the old digits. The data at $2196:

| Record | Position (row, x/2) | Digits | Written by |
|---|---|---|---|
| `obs1` $2196, `dgDrawnDegrees` $2197, `tachDrawnRpm` $2198, `obs2` $2199 | | | the keys, $377C, $3AB9 |
| `dgRecord` $219C / `dgReciprocalRecord` $21A2 | (171, 35) / (187, 35) | 3 | $377C |
| `compassRecord` $21A8 | (106, 114): inside the window | 3 | $3823 |
| `comRecord` $21AE | (122, 120) | 4 (after a painted '1') | the ',' '.' keys |
| `nav1Record` $21B5 / `nav2Record` $21BC | (138, 120) / (154, 120) | 4 | the keys |
| `obs1Record` $21C3 / `obs1ReciprocalRecord` $21C9 | (117, 93) / (149, 93) | 3 | $3923 |
| `obs2Record` $21CF / `obs2ReciprocalRecord` $21D5 | (160, 93) / (192, 93) | 3 | $3976 |
| `transponderRecord` $21DB | (154, 140) | 4 octal | the keys |
| `tachRecord` $21E2 | (194, 132) | 3 + a fixed '0' | $3AB9 |
| `clockHoursRecord` $21E9 / `clockMinutesRecord` $21EE / `clockSecondsRecord` $21F3 | (163, 129 / 138 / 147) | 2 each | $39D9, $39B6 |
| `dmeRecord` $21F8 | (138, 140) | 3 around a painted point | $3A13 |
| `lightsOnRecord` $21FE '1' / `lightsOffRecord` $2202 'O' | (170, 155) | | $3A71 |
| `carbHeatOnRecord` $2206 'HT' / `carbHeatOffRecord` $220B 'CH' | (194, 150) | | $3A71 |
| `toFromRecords` $2210 | 6 × 8 bytes: NAV1 OFF/TO/FR (141, 94), NAV2 (184, 94) | | $3C81 |

The compass record and the slew readouts ($EB63/$EB73, row 2) lie in the double-buffered
window. They do not flicker: $3823 redraws the compass on every pass (the compass moves on every
call) and $3773 redraws the slew readouts every pass in slew mode, into the buffer being drawn.

## The radio gate ($3A53)

The gate returns normally when the radios are enabled (`$FE` bit 7). Otherwise it drops the caller's
return address from the stack, so its own return also ends the caller. 14 cycles open, 21 closed (a
closed gate costs the caller 27 including its call). Gated: $38BD, $38D9, $3903, $39B6, $39D9,
$3A13, $3A5C, $3A71. The port returns `(open, cycles)` and the callers return early.

## The routines

Cycle notation: `$1DDE` etc. stand for the cost of that call (its return included); n is a
loop count. The decimal digit loop (tens counted up in X as an ASCII digit by repeated
subtraction of 10, the ones left in A as an ASCII digit; values of 100 and more give tens past
'9') costs 14 + 9n (n = value / 10), 14 + 10n when its loop branch crosses a page (the clock
hours at $3A00).

- **panelRedraw ($2240, init).** Calls $38BD, $38D9, $3903, $3A5C, $39D9. 36 cycles + the five.
- **headingReadout ($3773, draw sequence).** In slew mode (`$0966`) the slew readout $EB82.
  13 cycles, slewing 18 + $EB82.
- **drawSlewReadout ($EB82).** `$096B` and `$096D` (the editor's NORTH and EAST settings) as
  signed 5-digit numbers into the records $EB63/$EB73 through $1D54. 54 + 2 × $1D54.
- **drawDgDigits ($377C, draw sequence, `$FD` b2).** heading = `$70/$71` + `$08C0` - `$0848` -
  `$0846` (16-bit); $8000 becomes $8001 (so the Q15 multiply never meets -32768). Degrees by
  $37EA. When the **low byte** of the degrees equals `$2197` nothing is drawn (headings 256
  degrees apart, e.g. 5 and 261, look the same: an original quirk). Otherwise `$2197` = that
  byte, `$39` = the high byte (scratch), the degrees go to $219E and degrees - 180 (wrapped by
  $37F5) to $21A4, both records drawn. 14 cycles disabled; else 72 (76 / 77 for $8000 with a
  nonzero / zero low byte) + 6 + $37EA, then 13 when unchanged, else 26 + $3804 + 10 + $1DDE +
  27 + $37F5 + 10 + $3804 + 7 + $1DDE.
- **headingToDegrees ($37EA).** `$C4/$C5` = A/X (binary angle), × 180 through $17EF, then $37F5.
  16 + $17EF + $37F5.
- **wrapDegrees ($37F5).** Adds 360 to a negative A/X (the sign test leaves the carry set, so
  the add of $67 adds $68) and stores the result in `$B8/$B9`. 17 / 23 / 24 cycles (positive /
  negative / negative with a carry into the high byte).
- **format3Digits ($3804, vector $2033).** `$BA/$BB` = A/X (the field); hundreds and tens by
  $1DBB (A/X = 100 / 10, Y = place), ones = `$B8 | '0'`. `$B8/$B9` are left holding the last
  remainder; `$A5-$A7` as $1DBB leaves them. 1000 and more give a first digit past '9'.
  49 + 2 × $1DBB, where $1DBB = 47 + 28 × digit.
- **updateCompass ($3823, draw sequence, `$FE` b4).** d = compass `$08C5` - heading + `$0848` +
  `$0846`. The compass steps toward the heading on every call, by signed compares of d's high
  byte: >= $0A: -1200; 0..9: -75; $F6..$FF: +75; below $F6: +1200. So it hunts around the
  heading by ±75 (0.4°). Then $37EA, three digits into $21AA, drawn at $21A8. 14 cycles
  disabled; else 85 / 84 / 85 / 83 (the four cases in that order) + 32 + $37EA + 10 + $3804 + 7 +
  $1DDE.
- **drawObs1 ($3923, `$FD` b5) / drawObs2 ($3976, `$FF` b3 and the ADF off).** OBS (2-degree
  units) via $395E into the record, then OBS - 90 units (+180 on a borrow) into the reciprocal
  record, both drawn. $395E: Y = '0' + v / 50, then (v mod 50) × 2 → X = tens, A = ones (36 + 9
  per successful subtraction). drawObs1: 14 disabled; else 84 (87 when the reciprocal wraps) +
  two $395E + 2 × $1DDE. drawObs2: 14 disabled, 20 with the ADF on; else 90 / 93 + the same.
- **drawClockSeconds ($39B6, the 1 Hz tick at $2409).** Gated. Seconds `$091A` → $21F5/$21F6,
  drawn ($21F3); at 0 seconds it falls into $39D9 (the 1 Hz tick has just rolled the minutes).
  27 closed; else 56 + 9n + $1DDE + 14, or + 6 + $39D9 at 0.
- **drawClock ($39D9, vector $2000).** Gated. Minutes `$0984` → $21F0, hours `$0983` → $21EB,
  both drawn. 27 closed; else 98 + 9 × (minutes / 10) + 10 × (hours / 10) + 2 × $1DDE.
- **drawDme ($3A13, phase 0).** Gated. `$09AC` (the redraw flag the nav code sets) is shifted right;
  nothing when a 0 shifts out. With no NAV1 station (`$09AB` != 0) the three digits become blanks;
  otherwise tenths `$09AD` + '0' and miles `$09AE` (two digits; 100 nm and more give a tens digit
  past '9'). Drawn at $21F8. 27 closed, 35 without a request; else 68 (blanks) or 88 + 9n (digits) +
  $1DDE.
- **drawMagnetoLabel ($3A71).** Gated. Carb heat `$0AA9` != 0: 'HT' and the cells $7FE5-$7FE7 =
  $B8; else 'CH' and $FE. Lights `$0AB5` != 0: '1', else 'O'. Then the magneto label
  [`$0AB6` × 2] through the pointers at $3A67 (O/L/R/B/S at $EE57-$EE67; the index is not
  checked). 27 closed; else 105 / 108 (carb heat on) or 111 / 114 (off), for the lights on / off,
  + 3 × $1DDE + 1 per pointer read across a page.
- **drawTach ($3AB9, draw sequence, `$FD` b6).** Only when `$09BE` != `$2198` (the value drawn):
  `$2198` = it, digits of `$09BE` >> 1 into $21E4/$21E5 and '0' / '5' from bit 0 into $21E6 (RPM =
  `$09BE` × 50), drawn at $21E2. 14 disabled, 26 unchanged; else 78 (79 for an odd value) + 9n +
  $1DDE.

## Time of day ($EBF2-$EC98)

- **selectTimeOfDay ($EBF2, phase 0, and the display prompt at $AA6E).** X = (`$0985` & 3) × 8.
  For k = 0-3: minute `$0984` - `$EBD2 + 2k` (only the borrow is used; the minute is always taken
  from the **season-0 row**, a quirk that is harmless because every threshold minute is :00 or
  :30) and hour `$0983` - `$EBD3 + 2k + X` - borrow; a negative result means "before Tk". Before
  T1: night (4), T2: dusk (2), T3: day (1), T4: dusk, after all: night. Then $EC41. Cycles 40 /
  60 / 77 / 100 / 99 (in that order) + $EC41.
- **applyPalette ($EC41, A = state).** A is compared with `$083C` and stored there; when it
  changed, the pair for the state (1: `$0E61/$0E62`, 2: `$0E63/$0E64`, anything else:
  `$0E65/$0E66`) gives the window border, stored into `$22B5` (the immediate operand of the
  raster IRQ's load at $22B4, which it writes to $D020 for the window region), and the screen
  byte, painted by $EC7C. Always: `$0884` = 1 << (`$0985` - 1) by a loop of `$0985` iterations
  (`seasonBit`; 256 iterations and 0 for season 0; 0 for seasons over 8). 11 cycles unchanged,
  else 33 / 40 / 39 (state 1 / 2 / other) + $EC7C; then 11 + 11 × iterations.
- **fillWindowColors ($EC7C).** A into $7C00-$7E2F (window rows 0-13 of screen RAM), top down
  through `$A5/$A6`, which end at $7BFF. 7884 cycles.

The port never writes $D020/$D021: the presenter reads `$22B5`, the window screen RAM and
`$0E69` from memory, like the VIC does.

## Panel lighting ($EBA5)

**updateLightingMasks** (draw sequence): the third factor of the instrument enable masks
(`$0945-$0947`, see `updateInstrumentMasks` above). By day (`$083C` bit 0) and at dusk or night
with the lights on (`$0AB5` != 0): `$08DC-$08DE` (normally $FF, the lights-on set). At dusk or
night with the lights off: $10 / $80 / $01, which leaves only `$FD` b4 (no instrument), `$FE` b7
(the radios) and `$FF` b0 (the CH label): the rest of the panel goes dark through the failure
areas. 39 cycles by day, 39 dark with the lights off, 62 dark with the lights on.

## Tests

`ReadoutTests` (14 tests) run on the regular-flight and demo snapshots and on their own lab
snapshots (`ReadoutFixtures`, one session: radios tuned to Chicago VORs, night, ADF on a Chicago
NDB, three points of the Champaign ILS), with `DiffRig` comparing the whole image (stack page
excluded), the modeled registers and the cycles after every call, and checking that the original
wrote no I/O. The sessions hold CTRL by poking the game's CTRL flag `$0E67` around the key,
because the lab's `key:CTRL+N` presses both keys in one scan and the scan meets N first (the
lab's `down:`/`up:` steps are the other way to do it).

- DG: 300 random headings, DG and area offsets on every snapshot, each drawn twice (the second
  call is the unchanged case), the $8000 case, the mask off.
- Compass: random headings and compass values, three calls each, and a sweep of the difference
  across the ±$0A00 limits.
- `format3Digits` on 0-299, multiples of 97 and random words, into records and across page ends.
- `headingToDegrees` / `wrapDegrees` on every high byte and random angles, -360..359.
- OBS: every value 0-255 for both OBS with the masks and the ADF toggling.
- Clock: hours 0-31 × minutes 0-63 (step 7) × six seconds values, the gate closed, values to 255.
- DME: random flags, tenths and miles (to 255) on three snapshots; magneto/lights/carb labels
  over all combinations and the gate, and the unchecked label index 5-255 (pointers from the code
  after the table, some read across a page); the tach over every engine value up and down.
- Slew readout (including -32768), `panelRedraw` with the gate open and closed and the ADF on.
- Radio displays: random digit strings (some non-digits) in all four records, the gate, the ADF,
  random found bits; $3896 across page ends.
- ADF tuning: 400 random selected items, ADF enable, mixture, digits and repeat windows through
  $E9BF, $E9F6 and $E9A7 (with its tail `storeSelected` $2BBC), and $EA50.
- Time of day: every hour × minutes 0/29/30/59 × seasons 0-4, 7, 9, 255 with the snapshot's
  palette and a random one, random clock and season bytes (the "before" test is an 8-bit sign),
  random states into $EC41 and $EC7C directly; lighting over every state and lights value.
- The fixtures themselves (`fixturesReachTheirStates`): the tuned frequencies and found bits, night,
  the ADF on and its NDB found, the localizer on the approach, the outer and middle marker lamps
  lit, the DME under 1 nm at the middle marker. (An earlier middle-marker segment left the
  north high byte at $FF, which put the aircraft 63 km south of every box; its snapshot had no
  station, no marker and no glideslope reference.)

Mutation checks make the tests fail: one extra cycle in $377C and the nav faults listed in
`radios.md`.
