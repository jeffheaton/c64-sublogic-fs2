# 3D renderer core

The port of the view matrix and ground base ($8111-$83A3), the sky/ground fill ($840F-$86A3),
polygon clipping and scan conversion ($8FE8-$990F), the projection front-end ($9D05-$9E91,
$9F94), the point transforms ($9FD0-$A353), the attitude indicator ($A354-$A4F1), the turn
coordinator ($A4F2-$A5A6) and the view overlays ($EC99-$EE13). Swift:
`Sources/FS2Core/Render3D/`. Differential tests: `Tests/DifferentialTests/Render3D*Tests.swift`.

Background is in `scenery-3d.md` (the display list, coordinates, what the transforms feed) and
`display.md` (the window, the raster split, the 2D primitives and the panel). The 2D primitives
these routines call (spans, lines, pens, the row filler $851B) are specified in `raster.md`;
the math ($16AA, $16C9, $1802, $188A, $18B8-$18C9, $1961, $196D) in `math.md`.

| File | Routines |
|---|---|
| `ViewMatrix.swift` | `buildViewMatrix` $8111, `computeGroundBase` $8324 (+ $836A) |
| `Horizon.swift` | `horizonFill` $840F (+ $844B, $84EE), `horizonColorSwap` $84FB, `fillWholeRows` $8504, `horizonSplitRow` $85C0, `horizonBresenham` $8623 |
| `Clip.swift` | `computeOutcodeA` $93D2, `computeOutcodeB` $941B, `clipLine` $9464, `swapClipEndpoints` $946A, `clipLineEnd` $9478, `clipPlaneYPos` $94C0, `clipPlaneYNeg` $953E, `clipPlaneXPos` $95C6, `clipPlaneXNeg` $9644 (+ $96C9) |
| `Polygon.swift` | `clipPolygon` $8FE8, `projectAndFillPolygon` $96D4 (+ $9748, $97A4, $986E) |
| `Projection.swift` | `projectPointA` $9D05, `projectPointB` $9D21, `projectionDivide` $9D3D, `project` $9F94 |
| `Transform.swift` | `transform3D` $A1CE (+ $A332) |
| `GroundTransform.swift` | `transformGround` $9FD0 (+ $A023), `renormalizeGround` $A1B9 |
| `AttitudeIndicator.swift` | `drawAttitudeIndicator` $A378, `aiFillRows` $A4A0, `aiSpan` $A4CA |
| `TurnCoordinator.swift` | `drawTurnCoordinator` $A532, `turnCoordinatorHelper` $A558 (+ $A55F) |
| `ViewOverlay.swift` | `drawViewOverlay` $ED3C, `drawAirframe` $ED88 |

## Conventions

- **Memory-faithful.** Every routine reads and writes the bytes its original does: zero-page
  temporaries (including the scratch the matrix build leaves in `$24-$29`), the self-modified
  code bytes, the planted return of the row filler, and the out-of-range writes of degenerate
  inputs (indices past the 64-entry arrays, the zero-page sort below). Tests compare the whole
  64 KB image except the stack page.
- **Self-modifying code is state in memory.** The port writes the patched bytes and, where the
  original executes code it patched elsewhere, reads them back: `horizonBresenham` dispatches
  every row on the opcode at $85C0 (a jump planted there sends it to `aiSpan` $A4CA), and
  `projectionDivide` reads its table from the operand $9E89/$9E8A. Bytes the routine itself
  patches just before using them (the Bresenham's x and row step opcodes, the polygon crossing
  operand $98AD, the filler call's operand $85FC) are written and used directly.
- **Cycles are exact.** Each routine charges the original's cycles from its first instruction
  through its return (the caller charges its call; a call through a renderer vector `$80xx` adds the
  vector's 3-cycle jump). Tail jumps are charged by the routine that jumps. Every test compares the
  cycle count of every call.
- **Registers.** Routines return only what callers use: `projectionDivide` and `project` return
  A, X, Y; `horizonSplitRow`/`aiSpan` take X and preserve it.
- **Hot paths allocate nothing.** No arrays, no escaping closures; the per-row fills and the
  division loops work on the memory pointer.

## Integration (for the scenery VM and the main loop)

| Original | Port | Caller notes |
|---|---|---|
| $8000 → $8111 | `buildViewMatrix()` | Main loop $2080. Charge 6 + 3 for the vector. |
| $83A4-$840E | `horizonPass()` (`scenery-3d.md`) | Saves `$8B/$8C`, patches the line driver's call at $8B89 into a harmless read, `$EC` = $FF, selects the list `$0AD0 + 16·(((yaw_hi + $20) >> 6) & 3)`, zeroes `$66/$67`, `$6A/$6B` (saved in `$02-$05`) and the base high words `$24/$25`, `$27/$28`, `$2A/$2B` (not the low bytes `$26`, `$29`, `$2C`), runs the interpreter, and restores everything but the base. Then **falls into `horizonFill()`**, which charges from $840F through the return of $83A4. |
| $8324 | `computeGroundBase()` | Op 07/24 at $8D9D. |
| $8863/$8864, $88A4/$88A5 | `transformGround(y:)` / `transform3D(y:)` | The interpreter's call at $8862/$88A3 goes to $9FD0 or $A1CE by its self-modified operand; read the operand and call the matching port with Y = $D6 / $CD. |
| $88D1-$88D8, $8896-$889D | `computeOutcodeA/B()`, `projectPointA/B()` | |
| $8B4A, $8B61, $8B6F, $8B76 | `clipLine()`, `clipLineEnd()`, `projectPointA/B()` | The line driver $8B40. |
| $8845 | `clipPolygon()` | Op 29 with `$B7` = count − 1 (≥ 0). |
| $8021 → $A378 | `drawAttitudeIndicator()` | Every pass. |
| $8012 → $A532 | `drawTurnCoordinator()` | Every other pass. |
| $8015/$8027 → $A558 | `turnCoordinatorHelper(_:)` | Cold start $AAA8 (A = 8). |
| $ED3C | `drawViewOverlay()` | Every pass, after the scenery. |

**Calls into the scenery interpreter.** `transform3D` ends by advancing the display-list PC by 7
through `dlStep` $8851, and `transformGround` advances it by 5 with a tail jump to the same
routine. The clip planes' overflow path `halveClipPoints` ($96C9) calls `halvePoint` ($8B2A) with
X = $CD and X = $D6. $8851 adds A to the PC `$8B/$8C` (17 or 21 cycles with its return, the
longer when the high byte carries); $8B2A halves the three signed words at zero page X (the
zero-page indexing wraps; 60 cycles with its return).

## View matrix ($8111 = $8000)

Inputs: pitch `$6C/$6D`, bank `$6E/$6F`, heading `$70/$71`, view `$0ACA`, radar `$0836`.

1. Effective angles `$72-$77`:
   - Radar: pitch $4000, bank = −heading, yaw $0000 (`$76` written). 45 cycles to $81F7.
   - Down view (`$0ACA` bit 7): pitch low = `$6C`, high = `$6D` + $40 (8-bit), bank = −heading,
     yaw $0000. 60 cycles.
   - Views: v = `$0ACA << 4`. If bank_hi + $40 is negative (|bank| ≥ 90°), pitch = $8000 − pitch
     and the bank and heading high bytes flip by $80. pitch' = p·cos v − b·sin v, bank' =
     b·cos v + p·sin v (`$18B8/$18BD`, then four `$16AA`), yaw high `$77` = heading_hi + v.
     **`$76` is not written** (the stale yaw low byte: heading resolution 1.4°; bit 7 of what
     `$76` holds, the boot image's value or the 0 a radar or down view left, adds a half step).
2. If pitch'_hi + $40 is negative: pitch' = $8000 − pitch', `$75` ^= $80, `$77` ^= $80.
3. sin/cos of the three angles (`$18C9`/`$18C2`, 9-bit: the low byte's bit 7 is a half step)
   into `$CD/$CF/$D1` (sin p, b, y) and `$3F/$D6/$D8` (cos p, b, y).
4. Twelve `$16AA` products (dest = first × second): `$DA` = cy·cb, `$42` = sy·sb, `$DF` = cy·sb,
   `$E1` = sy·cb, `$E3` = sp·`$42`, `$45` = sp·`$E1`, `$24` = `$DF`·sp, `$27` = sp·`$DA`; `$78` =
   `$DA` + `$E3`, `$7A` = `$45` − `$DF`; `$7C` = sy·cp, `$7E` = sb·cp, `$80` = cp·cb; `$82` = −sp,
   `$84` = `$24` − `$E1`, `$86` = `$42` + `$27`; `$88` = cy·cp.
5. Loop $8306: `$78`, `$7E`, `$84` (eye x row) arithmetic >> 1; `$7C`, `$82`, `$88` (eye z row)
   arithmetic >> 2.

The products use `$24-$28` as scratch, so the ground base is clobbered every pass; op 07/24
recompute it when y changes. Cycles: 4,400-5,000 (down), 5,600-7,600 (front), 5,900-8,300 (other
views); the variation is the math routines' (bits set in the multiplier, interpolated angles).

## Ground base ($8324)

For each column entry M (`$7E`, `$80`, `$82`): `$188A`(|M|, y = `$68/$69`), the product's bits 8-31
shifted left once (`$C9-$CB`), negated unless M and y have different signs (the sign test XORs `$C5`
with `$69` before |M| is formed). Stored as high word `$24/$25` (`$27/$28`, `$2A/$2B`) and low byte
`$26` (`$29`, `$2C`): the base is −y·M in the units of the ground transform's sums. 2,450-2,750
cycles.

## Horizon fill ($840F, the tail of $83A4 = $8003)

Given the endpoints `$EB-$EE` left by the horizon list (clipped to the window, so normally on
its border):

1. `$EF` (left of / below the line) = `$0882` when 0 or $FF, else $AA; `$F0` = `$0880` when 0
   or $FF, else $55. `$F2` = 0, `$F1` = $6F.
2. **No horizon** (`$EC` bit 7): `$0890` = 0; `$F2` = $FF; swap when `$73` is negative (nose
   up: all sky); rows $6F-0 with `$EF`. 41,152-41,175 cycles.
3. Otherwise `$0890` = $8458, the endpoints into the line list $845A-$845D, `$F1`/`$F2` = the
   rows of the two endpoints ($844B).
   - Swap when x1 = 0, or else when y1 ≠ 0, x2 ≠ 0 and (y2 = 0, or x1 ≠ $9F).
   - Rows `$F1` − 1 down to 0 whole ($8504), when `$F1` > 0.
   - Swap again: x1 = 0 and y2 ≥ y1, or x1 ≠ 0, x2 = 0 and y1 ≥ y2.
   - The crossed rows: `horizonBresenham`.
   - Unless `$F2` = $6F: swap when x1 = 0 and y2 < y1, or x1 ≠ 0, x2 = 0 and y1 < y2; rows $6F
     down to `$F2` + 1 whole.
   41,500-61,000 cycles.

The jump to $84A2 at $849B is dead code: y2 ≠ 0 is already known there, so the branch before it
is always taken.

**Whole rows ($8504):** `$F3` rows (0 = 256) from `$E9` downward (X wraps), each by a call of the
row filler $851B through all 40 columns: 366 cycles per row, 367 from row $38 (the indexed read
of the $02C8 table crosses a page).

**Split row ($85C0):** X = boundary x on row `$E9`. A return is planted over the first instruction
of column (x + 4) >> 2 in the row filler (offset `(x + 4) & $FC`, +2 from column 32, past the
filler's page step), saved in `$F5`; the filler runs from $851B with `$EF`; the original opcode is
put back, the call operand $85FC/$85FD set to that column, and the filler runs from there to its end
with `$F0`. Unless x & 3 = 3, the byte of x's column is rebuilt: `$F0` shifted right two bits per
pixel 0..(x & 3) with `$EF`'s low bits rotated in from `$AF`, stored at `$14DA[x]` (`$8F`
decremented again for x < 128). X is kept (`$B4`). x above 159 would plant the return past the
filler (never happens).

**Bresenham ($8623):** `$18` = |dx|, `$19` = |dy|; $8678/$868C get the opcode that increments x
when x2 ≥ x1, else the one that decrements it; $8679/$869A the opcode that increments the row `$E9`
when y2 ≥ y1, else the one that decrements it. The first row (x1, y1) is split, then:
- dy ≥ dx: `$93` = error = dy; per step error −= dx, on borrow error += dy and x steps; the row
  steps; split.
- dx > dy: `$93` = dx, error = dx − dy; per step x steps, error −= dy, and only on borrow error +=
  dx, the row steps and the row is split.

The split is whatever $85C0 holds; the port reads it once per call.

## Clipping

**Outcodes ($93D2/$941B):** $80 z < 0, $40 x + z < 0, $20 z − x < 0, $10 y + z < 0, $08 z − y < 0,
each the sign bit of a 16-bit sum (overflow ignored). 85-104 cycles.

**Line ($9464, $9478):** `clipLine` swaps the points (7 bytes each: outcode and point; 154
cycles), clips the far point and swaps back. `clipLineEnd` takes the planes $40, $20, $10, $08
in that order; after each clip the outcode is recomputed and it returns as soon as
`$D5` & `$CC` ≠ 0; the last plane tail-jumps into the outcode.

**Planes:** B moves onto the plane along A→B with t = `$1802`(num / den) (kept in `$A9/$AA`;
`$1802` also leaves |den| in `$C6/$C7`):

| Plane | Routine | num | den | Then |
|---|---|---|---|---|
| y = z | $94C0 | zB − yB | (yA − yB) − (zA − zB) | xB += t(xA − xB); zB += t(zA − zB); yB = zB |
| y = −z | $953E | zB + yB | (yB − yA) − (zA − zB) | xB += t(xA − xB); zB += t(zA − zB); yB = −zB |
| x = z | $95C6 | zB − xB | (xA − xB) − (zA − zB) | zB += t(zA − zB); xB = zB; yB += t(yA − yB) |
| x = −z | $9644 | zB + xB | (xB − xA) − (zA − zB) | yB += t(yA − yB); zB += t(zA − zB); xB = −zB |

Each product is `$16C9`(t, A − B). When the denominator's final subtraction overflows, both
points are halved ($96C9 → $8B2A twice) and the plane starts over (until it fits).

## Polygons

**Clipper ($8FE8):** `$B7` = count − 1 is incremented to the count, then four passes: x = z
($0B10 → $0C90), y = z (back), x = −z, y = −z, then on to $96D4 with Y = the count.

- Each pass copies vertex 0 to index n, array by array, and walks n − 1 down to 0 (8-bit; it
  stops when the index turns negative). The first vertex's flag is computed from index 0
  (absolute operands), which equals index n after the copies even when a copy lands on index 0
  of a later array (n = 64, 128, 192).
- A vertex is outside when the sign of z − x (z − y; x + z; y + z) is set; `$B6` keeps the
  previous vertex's flag.
- On a change, B = vertex i and A = vertex i + 1 are clipped by the pass's plane. The clipped
  point is appended unless its z is 0; its z high byte is written to the output slot either way.
- An inside vertex is appended after that.
- A pass that leaves no vertex returns (`$B7` = 0).

**Overflow.** Indices are never bounded. Real scenery polygons are small (a few vertices;
clipping a convex polygon adds at most one per plane), so the game never gets here; random
polygons of 50 vertices or more do, and the port overflows exactly as the original (every read
and write at the same address, in the same order, so the aliasing below falls out):

- Index i + 64 of one array is index i of the next. A pass can write more than 64 vertices, at
  most 1.5 times its input (a vertex adds its clipped point when its flag changes and itself
  when inside): 193 from 129, so the copies reach $0E91 (past $0E0F into the aero gain tables).
  The input arrays themselves overlap from 65 vertices: vertex i + 64's x, y and z are the bytes
  (x hi, y lo), (y hi, z lo) and (z hi, `$0C90 + i`) of vertex i.
- A pass of 130 vertices or more (count − 1 ≥ $81) handles only vertex count − 1 (the index is
  tested for a sign after its first decrement), so a pass never wraps its 8-bit count; 129
  vertices start at index $80, which turns positive after that decrement, and are all handled.
  `$96D4` returns at once for 129+ vertices (the same sign test after a decrement).
- The projected x and y ($0CD0, $0D50: the copies' x hi and y hi) overlap from index 128 (x[128]
  is y[0]); the closing slot $0D4F is x[127]. So the closing writes alias from 126 vertices:
  with 126 and 127, x[n + 1] / x[n] land on $0D4F (the y[−1] the edge setup reads) and with 127
  x[128] on y[0]; with 128, x[127] becomes y[127] and y[0], y[1] become x[0], x[1] before the
  closing y[128], y[129] copy them.
- Up to 128 edges: edge i + 64's fields are edge i's next fields (its `$0B50` is edge i's
  `$0B90`), and edge 128's slope high byte is x[0]. The scan loop then steps aliased edges in the
  same row.
- Crossings: 27 or more on a row reach `$1C` (the last-edge index the next row starts from), `$1D`
  and `$1E` (the pair loop reads `$1E` after storing it). A row of 129 or more (count − 1 negative)
  skips its sort and spans (the sign branch to $9904); the slots wrap within the zero page (from 255
  crossings onto $00/$01, the processor port on the C64; see Degenerate polygons).
- Garbage crossings can lie past x = 159: the spans read `$14DA` past the window's 40 columns.
  A long span ending at x = 160-163 plants its return on the filler's own return at $85BF, and the
  "restore" turns that into $91, so a later fill through $851B runs on into the split row's
  code. One ending at x ≥ 164 plants it past the filler's end: the filler returns at $85BF and
  the "restore" writes $91 into the split row's code at `$851D + $F5`.

This settles the open question on the polygon buffer capacity: the original does overflow, and
the port overflows the same way. Two things the garbage can make the original do are excluded
(below): a long span whose left end, rounded up to its byte (`(left + 3) & $FC`), lies at 164 or
more calls into the filler past its end, into the split row's code $85C0-$8622, which then runs
from the middle (usually into an undocumented opcode, where the lab CPU halts); and spans
through a row pointer scrambled by the degenerate sort (next paragraph) can overwrite code that
then runs in the same call, such as the row filler's immediate operands and its stores.
The port does not follow the original into code it was never meant to run; it reproduces
everything before that.

**Projection and edges ($96D4):** each vertex is projected (`$9F94`) to $0CD0 (x) / $0D50 (y),
with the row range in `$F1`/`$F2`; the loop is closed ($0CCF/$0D4F = the last vertex, [n] and
[n+1] = vertices 0 and 1). The edge table ($9748), edge X from vertex Y to Y + 1:

- Sloped edge, from the top vertex: `$0B10` = top row, `$0B50` = rows, `$0BD0` = x at the top,
  `$0C50:$0C10` = the signed 8.8 slope.
  - The slope is |dx|·256 / rows by a 16-step division ($97C3) by `$F8:$F9`. `$F9` is never
    written by any code: it stays 0 from the boot zero-page image.
  - When the polygon goes on downward, or level, past the edge's lower vertex (the flag in
    `$0B90`: y[Y+2] ≥ y[Y+1] for a downward edge, y[Y−1] ≥ y[Y] for an upward one), the rows
    are decremented, so the row shared with the next edge down is counted once.
  - `$0B90` doubles as the edge's x fraction and is never cleared after the flag: it starts at
    0, or at 1 for a decremented edge (a 1/256-pixel bias).
- Equal y: a horizontal run, extended over the following vertices on the same row.
  - `$0B50` = $FF, `$0B10` = the row, `$0BD0` = max x, `$0C50` = max − min.
  - A run with both neighbors below it on screen (a top: the carry saved from the compare with
    y[Y−1] is clear and the next vertex is lower) is dropped: the edge and vertex indices do not
    advance, and its slot is reused. The two sloped edges that start there cover its row.
- The loop ends when Y − `$B7` is positive.

**Scan loop ($986E):** rows `$F1` to `$F2` in `$B3`, color `$158A[$9BD6[$0876 & 15]]` ($9C93).

- Every edge whose row is `$B3` acts:
  - a run is spanned at once;
  - a sloped edge stores its x through a zero-page store whose operand $98AD counts up from 2,
    then steps:
    x += slope with the fraction's carry, rows − 1, and row + 1 while the rows stay ≥ 0.
- The crossings are bubble-sorted into descending order and spanned in pairs from index
  `$1D` = count − 1 down by 2. `$C8:$C9` adds count − 1 per row.

**Degenerate polygons.** A row with exactly one crossing is not skipped. The sort then runs 256
outer passes (Y = 0, then $FF down to 1) and compares `$02+X` (zp,X) with `$0002+Y` (abs,Y,
reaching $0100/$0101), which scrambles the zero page. The zp,X operand wraps: the first pass
compares (and may swap) `$01` with `$0002`, the second `$00` with `$0101`. On the C64 those two
are the processor port (a write to `$01` can bank ROM over the code at $A000+); the lab's flat
bus and the port treat them as RAM, so the tests cannot tell, and this stays a degenerate-only
difference from real hardware. The following spans use the scrambled row data, and in one
random test case they wrote into the original's own code at $8440-$85xx.

The port reproduces all of this byte for byte. A divergence can only appear when the original
executes the code it overwrote, in the same call (the spans' own filler) or later. The tests
therefore run each random polygon from a clean state, and classify the original's run first
(`R3D.ending`): a polygon whose original runs overwritten code, the split row's code or anything
else outside the polygon routines' call tree is compared up to the last scan-row start before
that point (`PolygonCheck`, below); one that loops or halts is skipped.

## Projection ($9D05-$9E91, $9F94)

`project` points the operand $9E89/$9E8A at TY ($9F13) and divides y (A:Y), `$A7` = $37 − result
(the result is TY[q], or its complement for negative y, so this is $37 − TY or $38 + TY); then at
TX ($9E92) and divides x (`$C4:$C5`), A = $50 + result ($50 + TX or $4F − TX). Returns A = sx,
X = q(x), Y = sy.

`projectionDivide` (A:Y over z = `$C6:$C7`):
- n = z: q = $7F, `$A6` = 0; n = −z: q = $7F, `$A6` = $FF.
- Otherwise `$A6` = A and eight unrolled steps on R (started at n): R = 2R − z after a
  non-negative R (the subtract chain $9D69/$9D7A/$9D8B/$9D9C, then $9E3B-$9E6E), R = 2R + z after a
  negative one (the add chain $9DB1-$9E28). Bit 15 of 2R is lost. The step's carry is rotated
  into `$A5` by the next step (the first rotates in 0, or 1 for negative n).
- q = bits 6-0 of `$A5` (inverted for negative n); the carry of the eighth step is shifted out
  and lost.
- When the eighth add step ends negative with carry set (only possible with a signed overflow),
  the code falls into the fifth subtract step and runs on.
- A = table[q] (+1 cycle from q = $6E with TX), complemented for negative n.

27 cycles per step plus the branches (the S4 → S5 path has a jump; A4 → S5 crosses a page).
`projectPointA/B` copy the point (36 cycles + `project` + 12). A whole point costs 190-820 cycles.

## Point transforms

**3D ($A1CE):** Y = the destination (`$E7`). d = P − (`$66`, `$68`, `$6A`) from `($8B)+1..6`
into `$9E-$A3`.
- If any subtraction overflows, all three become the true difference halved. The overflowing
  ones rotate right through the subtraction's carry, which is bit 16 of the true difference; the
  others use an arithmetic shift.
- If any |d| ≥ $4000 (high byte + $40 negative), all three are halved once more.
- `$2F` = `$30` = 0, then the display-list PC advances by 7 (`dlStep` $8851).
- Per eye axis i: `$A9` = dx·M[$78+2i], `$AB` = dy·M[$7E+2i] (`$16AA`), dz·M[$84+2i] (`$16C9`).
  The sum ($A332, 16-bit wrap) goes to the next word at `$E7`, and `$30` counts sums with
  |high + $40| negative.
- `$30` ≠ 0 halves all three results ($A2C1, zp,X wrap).

3,400-4,200 cycles.

**Ground ($9FD0), block floating point:** the base `$24-$2C` is copied to `$3F-$47` (per axis
the high word, then the low byte), `$0905` = `$2F`, and `$2F` = $40. Then d = P − (`$66`, `$6A`)
from `($8B)+1..4`.

1. **Overflow:** dx and dz become the true differences halved, the base high words are halved
   (the low bytes are not), and `$2F` − 1. The carry left (bit 0 of `$45`) is the first
   product's bias.
2. **Otherwise ($A023):** while dx, dz and the three base high words are all below $4000 in
   magnitude, all five are shifted left (the bases as 24-bit `$40:$3F:$41`) and `$2F` + 1. The
   carry left is clear.
   - A zero d on an all-zero base never ends; the original hangs there. The horizon pass and
     the scenery never produce it, and the port asserts in debug builds.
3. **Products ($A09F):** per axis, `$196D`(dx_hi, M_hi) is added to the axis word.
   - The extension byte (`$41`/`$44`/`$47`, replacing the low byte) becomes the sum's sign,
     inverted on overflow.
   - Then `$196D`(dz_hi, M_hi) is added with sign extension into the extension byte.
   - Matrix high bytes: x `$79`/`$85`, y `$7B`/`$87`, z `$7D`/`$89`.
   - Each multiply's bias carry is the carry of the add before it.
4. **Renormalize ($A156):** each shift is `$A1B9` (a 24-bit logical shift right starting at the
   extension byte; `$2F` − 1).
   - 3 shifts when the three extension bytes XOR to neither 0 nor $FF. That happens when one
     reached 1 or $FE, which takes the overflow path with large differences and same-sign
     matrix bytes.
   - Otherwise 2 shifts when an extension byte disagrees with its word's sign.
   - Otherwise 1 shift when a word is at least $4000 in magnitude.
5. The three words go to `$E7`, then the display-list PC advances by 5 (a tail jump to `dlStep`
   $8851).

Every ground point carries its own exponent, so the vertices of a ground polygon (ops 40/41) can
have different scales; only op 2B reconciles them. This is the ground jitter. 1,300-2,000
cycles.

## Attitude indicator ($A378 = $8021)

1. Return (34 cycles) when both the bank high byte − `$A355` and the pitch high byte − `$A354`
   are within −2..+1, which a mask of $FE tests as 0 or $FE. Otherwise store the new values.
2. The background is span color 0 (pitch ≥ 0) or 3, on rows $97 down to $78 ($A4A0, A = $1F;
   row offsets $40-$60 = columns 8-12).
3. When pitch_hi + $20 < $40, off = `$A356[(pitch_hi + $20) >> 1]` (`$AD`), and the chord ends
   are at angles bank_hi − off and (bank_hi ^ $80) + off:
   - x = $29 + the high byte of `$1961`(cos_hi, $12); the carry out of `$18B8` is the
     multiply's bias;
   - y = $88 + (sin_hi arithmetic >> 3, keeping the sign).
4. `$8A` = $FF when bank < 0, inverted when pitch < 0; the span color is 3 (pitch ≥ 0) or 0.
   $85C0-$85C2 hold a jump to $A4CA around the call of $8623, then are restored (the split row's
   first instruction and the next opcode).
5. `aiSpan` ($A4CA) per chord row: `$8A` = 0 fills x..$33, else $20..x (through `$9996`).
6. When the ends lie on opposite sides of x = $2A (the signs of x − $2A differ), the rows beyond
   the chord's row range are filled ($A4A0):
   - with |bank| < 90° and pitch ≥ 0, or |bank| ≥ 90° and pitch < 0: from min y − 1 up to row
     $78;
   - otherwise from row $97 up to max y + 1.

A redraw costs 4,800-10,400 cycles.

## Turn coordinator ($A532 = $8012, $A558)

The index is `(($09FF:$09FE) << 1)` high byte + 8, clamped: negative → 0, ≥ $10 (signed compare)
→ 15. When it equals `$0A91` the routine returns (41 cycles). Otherwise the old wings are XORed
away ($A55F with `$0A91`) and $A558 records and draws the new ones. The wings use pen $83 and
entry A·4 of $A4F2: (12 + dx1, $B0 + dy1)-(12 − dx1, $B0 − dy1) and (12, $B0)-(12 + dx2,
$B0 + dy2). About 3,400-3,700 cycles for a change. States 16-63 (A·4 is 8-bit) read past the
table into the TC and runway code; the port matches them all except A·4 = $F0, whose lines
reach far outside the panel (not testable; real states are 0-15).

## View overlays ($ED3C, $ED88)

- **Radar** (`$0836` ≠ 0): the $ED1F pixel list.
- **Down view with Europe 1917** (`$0969` ≠ 0): the bombsight list $ECE1.
- Each list entry is (offset lo, offset hi + `[$0200]`, mask), ORed into the current window
  buffer. A zero offset-hi byte ends the list, as does the 8-bit index wrapping to 0.
- **Otherwise:** the airframe trapezoid of entry `$0ACA`·4 (the down view uses $40).

`drawAirframe` sets color 9 (`$0876`, then $801E) and returns at once for width 0: the front
view and the down view have none. Each entry of $EC99 is [width − 1, width fraction step, width
step, start row, x, x fraction step, x step, rows].

The walk state is in $ED7E-$ED87 (x fraction cleared, x, x steps, width fraction cleared,
width, width steps, row, rows). Per row: a span (through $801B), then the two 8.8 additions.
The loop branch crosses a page (4 cycles). An overlay costs about 230 cycles when there is
nothing to draw (front view) and up to 24,400 (side views).

## Observations for other subsystems (settled)

- **`$0880`/`$0882`** hold $77/$BB in demo flight, against $D5/$2A on disk and in regular flight
  (the snapshots `demo3600`-`demo7200`). The area display lists write them (op 1A copies palette
  words by altitude and time of day; `display.md`, `scenery-3d.md`). Both demo values select the
  patterns $55/$AA.
- **`$76`** keeps whatever the radar or down view (0) or the boot image left; the views never
  write it, and neither does the loader (the bytes once read as loader writes of `$76` are the
  operands of a call to $7686). The port reads it from memory like the original.
- **`$F9`** is read only by the edge-slope division and never written: it keeps the 0 of the boot
  zero-page image.

## Tests

The suites below run every case on both the original (lab `RoutineHarness`) and the port through
`DiffRig`. They compare the registers each port returns, the whole memory image except the stack
page, and the cycle count. They use the regular-flight snapshot and three demo-flight snapshots
(`R3D.demo(3600/5400/7200)`: climbing, turning) on both window buffers, and run in about 40
seconds in a debug build once the snapshots are cached in `build/testdata` (`Render3DOverflowTests`
adds about 30 seconds of its own, in parallel).

| Suite | What |
|---|---|
| `Render3DMatrixTests` | `buildViewMatrix` over all views, radar, down, random and edge attitudes, folds at ±90°, inverted, random stale `$76`; `computeGroundBase` with edge words; matrix-then-base sequences |
| `Render3DHorizonTests` | `horizonFill` on random border endpoints, interior endpoints, equal endpoints, no horizon, every fill selector; the real horizon of random attitudes (the original run up to $840F with a return planted there); Bresenham, split row at every x, whole rows, swap |
| `Render3DPanelTests` | AI on random and inverted attitudes, small steps around the redraw rule, `aiFillRows`, `aiSpan` over the chord's x range; TC on random rates and every helper state; overlays for every view, radar, war |
| `Render3DProjectionTests` | `projectionDivide` random and a sweep of every quotient for several z (both tables, n = ±z, edge words); `project`, `projectPointA/B`, outcodes; `transform3D` and `transformGround` (random matrices, small to overflowing differences, display-list points across a page) plus a targeted three-shift case |
| `Render3DClipTests` | outcodes + `clipLine`/`clipLineEnd` as the line driver calls them; the four planes (with the overflow halving); random convex and concave polygons (1-60 vertices, partly or fully clipped, through `PolygonCheck`); runway-like ground rectangles transformed by the original $9FD0; in-frustum polygons straight to $96D4 |
| `Render3DOverflowTests` | 600 overflowing polygons through `PolygonCheck`: 50-64 vertices as rings, stars and zigzags in all 36 combinations of the two axes' modes (inside, across +1, across −1, across both, wholly beyond either: every plane straddled, every early return), behind the eye, scattered points, overlapping inputs of 65-168 vertices and inputs built byte by byte to alternate across x = z (first pass of 129+ vertices); over regular flight, `demoFlight()` and two later demo states on both buffers, with the stale copies $0C90-$0E0F randomized in half the cases and `$F9` in an eighth. It checks that the set reaches passes of 64+ and 128+ vertices, 64+ edges, 27+ crossings on a row, long spans past the filler and empty passes at every stage. `boundaryCounts`: vertices built byte by byte so that the vertices sharing a byte (i, i + 64, i + 128) are all sensible points (convex outlines or scattered), at the counts where the arrays meet: `clipPolygon` with 63-66 and 127-131 vertices (closing copies onto index 0 of a later array, 129 walking every vertex, 130+ only the last) and `$96D4` straight with 60-65 and 126-130 (the closing writes onto $0D4F, y[0] and y[1]; every count compared in full at least once). Plus `span` for every right end x 0-255 with left ends anywhere (past the window, wrapped below 0) |
| `Render3DFrameTests` | 160 consecutive main-loop passes per snapshot along a drifting flight path with view and radar changes: matrix, page flip, the horizon pass (its start run as the original on both sides), ground base, transforms and a clipped, projected line, overlay, AI and every other pass the TC, each routine starting from the state the others left |

**Polygons in the overflow regime (`PolygonCheck`, `R3D.ending`).** The original runs first on a
copy, and the outcome decides the comparison. A first run traps only addresses outside the
polygon routines' call tree (the math library, the row filler $851B-$85BF, $8B2A, $8FE8-$9BD5,
$9BE6-$9E91 and `project`); when the call tree's code bytes have changed by the end (apart from
the designed self-modification: $98AD, the span pixel ops, $996B/$996C, $9E89/$9E8A and the
planted return) or the run did not return, a second run checks every executed instruction's bytes
against the start image.
- It returns: `DiffRig` compares both sides at the end.
- It runs the split row's code, code outside the call tree, or overwritten code: compared up to
  the last scan-row start (or the scan start) before that instruction. The port runs on its own
  machine with the event schedule set to that cycle (`nextEventCycle`); the handler fires inside
  the `charge` that reaches it, which is the end of the previous row on both sides because the
  cycles are exact, and the two images and cycle counts must be equal there.
- It loops or halts on an undocumented opcode: skipped (none in the current sets).

In `Render3DOverflowTests` about 85% of the polygons compare in full, about 15% up to the split
row's code and under 1% up to overwritten code; in `Render3DClipTests` 4 of 1,200 compare up to
the split row's code: the two 60-vertex cases that diverged at their last row once the
regular-flight snapshot moved to the main-loop top (different garbage past the arrays), and two
that were skipped as loops before (the split row's code ran into an undocumented opcode). Every
case matches the original up to that point, cycles included.

**Coverage.** With `R3D_COVERAGE=1` every rig records the addresses where the original executed
an instruction in these ranges (`build/testdata/r3d-coverage.txt`) and the outcomes of its
conditional branches; `build/testdata/r3d-branches.txt` lists every executed branch with an
outcome no test produced. The suites execute every instruction except the dead jump at $849B,
and take both outcomes of every branch except those the preceding code fixes:
- the two around the dead jump ($8499, $84A0: y2 and x2 are known to be non-zero there);
- the constant ones right after a constant is loaded, the carry branch at $9847 after the
  opposite carry branch, and the sign branch at $A174 after the opposite sign branch;
- the pixel-list loop at $ED6F, which would need a list running to the 8-bit index wrap.

Inputs the tests leave out. The game never produces them, and the original then runs or
overwrites code it was not meant to, which the port does not follow:
- `$0ACA` values other than 0, 2, ..., $0E and bit 7 (the view keys set only those) read
  misaligned airframe records. About 85 of the 120 such values never return; the port matches
  the rest except views 9 and 22 (and their aliases + 64), whose spans start left of x = 0: the
  original's long span then jumps into the row filler past its end (into the split row's
  code), while the ported `span` (`raster.md`) assumes a span inside the row.
- TC states whose entry A·4 is $F0 ($3C, $7C, $BC, $FC): the "wings" read from the runway code
  reach far outside the panel and draw over memory the original is using (the zero page
  included). The other states past 15 read the TC and runway code as wing offsets and match.
- x > 159 in the split row: the return is planted past the filler, into the split row's own code.
- Polygon spans that run code they were not meant to (overflowing polygons only, compared up to that
  point; see Polygons): a long span entering the filler at 164 or more runs the split row's code
  from the middle, and spans through a row pointer scrambled by the degenerate sort can overwrite
  code (the filler's operands) that runs in the same call. The ported `span` and `unrolledRowFill`
  follow the filler's structure and do not read those bytes. Even the entry at 188 ($85D9, an
  immediate operand whose value is the return opcode), which returns at once, differs: the original
  returns with the Y the span set at $994A (the planted offset), while the port's long span hands
  its filler model the column offset from `$14DA`. Afterward the original's split row also keeps any
  $91 a span wrote into it at `$851D + $F5`; the port's horizon does not read those bytes either.
- A zero ground point on a zero base: $9FD0 never returns (the port asserts in debug builds and
  loops like the original in release builds).
