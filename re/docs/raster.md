# 2D raster primitives and the 3x5 text renderer

The port of $9910-$9D04 (spans, plot, line, pens, span colors), the unrolled row filler at $851B,
and the text renderer $1D54-$1EC9. Swift: `Sources/FS2Core/Raster/`. Differential tests:
`Tests/DifferentialTests/RasterDiffTests.swift`. Background (VIC layout, the double buffer and
the callers) is in `display.md`.

| File | Routines |
|---|---|
| `RasterPen.swift` | The explicit pen state: `PixelSite`, `PixelOp`, `SitePen`, `Machine.sitePen(_:)`, and the internal `PixelWriter` (also the dotted plot $9B80) |
| `Pens.swift` | `setPen` $9BF5, `opPen3` $9B91, `opDottedPen` $9B9B, `opPen` $9BE6, `setSpanColor` $9C9C, `setSpanColorFromPalette` $9C93 |
| `Line.swift` | `plot` $99FD, `drawLine` $9A1D with its four loops |
| `Span.swift` | `span` $9996, `longSpan` $9910, `unrolledRowFill` $851B |
| `Text.swift` | `printSigned5` $1D54, `drawTextRecord` $1DDE, `drawTextRecordAt` $1DE2, `drawGlyph` $1E01, `drawTextList` $1E99, `clearWindow` $1EAF |

Every routine reads and writes the same bytes as the original (zero-page temporaries, the
self-modified code bytes, the planted return) and charges the original's **exact** cycle count,
the return included and the caller's call excluded. The tests check both against the lab for every
case. Nothing touches I/O.

## Coordinates and memory

- x is a multicolor pixel, 0-159; the byte offset in a row is `$14DA[x] = ((x >> 2) * 8) & $FF`,
  and x >= 128 adds $100 to the row pointer. Pixel `x & 3` is a bit pair, pixel 0 = bits 7-6.
- Rows go through the row tables $0200 (high) and $02C8 (low), so window rows 0-111 follow the
  double buffer and rows 112-199 are the panel in bitmap A. On the panel a "pixel" is 2 hi-res
  pixels.
- Nothing clips. Lines are clipped in 3D before projection; the tests also drive x up to 255,
  which the original handles by walking into the next character columns.

## The pen is self-modifying code

Each pixel write reads the byte through the row pointer, applies two operations op1 and op2 (an
OR, AND or XOR with a mask table indexed by the pixel index X) and stores the byte back. The pen
routines patch op1/op2 (opcode and operand) at these sites:

| Site (op1; op2 = +3) | Code | Patched by |
|---|---|---|
| $9A14 | `plot`, so also the first pixel of each line | $9BF5 |
| $9AB0, $9AF1 | y-major line loops $9A7C (up), $9ABD (down) | $9BF5; op2 = a call of $9B80 by $9B9B |
| $9B32, $9B73 | x-major line loops $9AFE (up), $9B3F (down) | $9BF5; op2 = a call of $9B80 by $9B9B |
| $9B8D (op only) | the dotted plot's op | $9BF5 (as an op2) |
| $99BC | short span pixels | $9C9C |
| $992A, $9986 | long span left / right partial bytes | $9C9C |

- `setPen` (A): op1 ORs the mask table $157A when `A & [$0F00]`, else ANDs $1582; op2 ORs $157E
  when `A & [$0F01]`, else ANDs $1586. Bit 7 makes both operations XORs with the tables chosen the
  same way, so the pixel is XORed with mask1 ^ mask2: $83 (the turn coordinator's pen) and
  $80 both XOR the pixel with 11, while $81 and $82 flip the other three pixels of the byte.
- `setSpanColor` (X): the same choice for the span sites, never XOR, plus `$1A = $158A[X]`.
  Until the first call the span sites hold the operations from the disk (an OR with $157A and an
  AND with $1583); the regular-flight snapshot is still in that state.
- `opDottedPen` (op $1C): only when `$083C` bit 0 is clear, pen 1, then op2 of the four line loops
  becomes a call of the dotted plot $9B80. `dottedPlot` saves the op1 result in $AF and applies the
  $9B8D op only when `$F3 & 3 == 0` (steps remaining, before the decrement), otherwise stores the
  byte back unchanged. The plot site is not patched: the first pixel is always drawn. Any later
  `setPen` restores op2 and so cancels dotted mode.

**Port.** `setPen`/`opDottedPen`/`setSpanColor` write exactly these bytes. The drawing routines read
them back at each call: `sitePen(site)` decodes the opcodes and operands into an explicit `SitePen`
(`first`, `second`, `dotted`), and `PixelWriter` compiles it with the mask tables read from memory
into per-pixel maps `byte = (byte & keep[px]) ^ flip[px]` (any chain of OR, AND and XOR has that
form) plus per-pixel cycle costs. So a restored snapshot always draws exactly like the original,
including the disk-state operands, and no extra state lives outside memory. Decoding costs a few
dozen operations per call; drawing costs about 3 ns per pixel in release builds.

## Plot ($99FD = $800C)

X = x, Y = row. `$8E/$8F` = row base (+$100 for x >= 128), Y = `$14DA[x]`, X = `x & 3`, one
write through the $9A14 site. Returns A (byte stored), X, Y; `drawLine` saves X/Y in $B2/$B3.

## Line ($9A1D = $8009)

1. If x1 < x2 the endpoints are swapped **in memory**, so ($EB,$EC) is the right end. `$18 = |dx|`.
2. Plot the right end (`$B2/$B3` = its pixel index and byte offset).
3. `$19 = |dy|`; X = 1 if y1 >= y2 (rows decrease, "up"), else $FF. dx = dy = 0 returns.
4. dy >= dx is y-major (diagonals too). `$F3` = major (steps), `$F4` = major >> 1.
5. Loop until `$F3` reaches 0. Each step: `error -= minor`; on borrow `error += major` and the
   minor axis steps. The major axis steps every iteration. Then the pixel, then `$F3` − 1.
   - x step (left only): X − 1; from 0 it wraps to 3 with `Y -= 8` (`$8F` − 1 on a borrow).
   - row down: `$8E` + 1; if `$8E & [$1B]` (= 7) is 0, `$8E/$8F += $138` (with carry).
   - row up: if `$8E & [$1B]` is 0, `$8E/$8F -= $138`; then `$8E` − 1.
   - The single steps of `$8E` never carry into $8F; with real row bases they never need to.

The row tables are used only for the first pixel, so a line from the window into panel rows keeps
walking the bitmap it started in. Outputs: $EB-$EE (swapped), $18, $19, $B2, $B3, $F3 = 0,
$F4 = final error, $8E/$8F = last pixel's row pointer, $AF (dotted only).

### Cycles per step

Verified against the lab (the tests compare every case exactly).

| Part | Cycles |
|---|---|
| error, no borrow | 14 |
| error, borrow | 19, plus the minor-axis step (y-major: the x step; x-major: the row step) |
| x step | 5; wrap to the next byte 17; wrap with the `$8F` borrow 21 |
| row step up or down | 14; across a character row 28 |
| pixel write | 19 (+1 page cross on the read through the pointer, +1 per mask-table page cross) |
| dotted pixel write | 45 drawn, 42 skipped (op2 is the call) |
| loop tail | 8 (7 on the last step) |

`plot` costs 52-59 cycles. `drawLine` costs 111 for a single pixel; otherwise 139-185 of setup
(swap, first plot, deltas, loop dispatch, return) plus the steps. A horizontal line costs about 49
cycles per pixel and a vertical one about 57.

## Spans ($9996 = $801B, $9910)

`span(A)`: fill A+1 pixels **leftward** from x = `$1E` (inclusive) on the row at `$8E/$8F`.

- A < $18 (up to 24 pixels): copy the pointer to `$9A/$9B` (+$100 for x >= 128); right partial
  byte pixel by pixel (x&3 down to 0), whole bytes with `$1A` (count >> 2), then the remaining
  count & 3 pixels from pixel 3. `$8E/$8F` unchanged, `$F3` ends at 0.
- A >= $18: `longSpan`. `$AF` = left x; its partial byte (pixels left&3..3) through $992A while
  `$AF` counts up (`$8F` + 1 when it reaches $80); then a return is planted on the store of x's
  column in $851B (offset `(x & $FC)` +2 from column 32, saved in `$F5`), the call operand
  $996B/$996C is set to the start of `$AF`'s column, the filler runs, the store opcode is
  restored; the right byte is stored whole when x & 3 = 3, else pixels x&3..0 through $9986.
  `$9B` saves `$8F`, which is restored at the end.

Cycles (lab): a 24-pixel short span on a byte boundary costs 229, a full 160-pixel row through
the long path 465. Short spans cost 25 per whole byte and 31 per partial-byte pixel; long
spans add about 8 per byte in the filler.

### The unrolled row filler ($851B), shared with the horizon fill

Four bytes per column: the column's byte offset 8k loaded into Y, then a store through
`$8E/$8F`, for columns 0-31 ($851B + 4k); the page step of `$8F` at $859B; columns 32-39 at
$859D + 4j; Y = 0 at $85BD and the return at $85BF. Callers plant a return and enter at the
start of a column:

| Caller | Plants on | Enters at |
|---|---|---|
| `longSpan` $9910 | the store of x's column, `$851D + off` | `$AF`'s column (self-modified call) |
| `fillWholeRows` $8504 | nothing | $851B |
| `horizonSplitRow` $85C0 | the start of column (x+4)>>2, `$851B + off` | $851B, then that column (call operand $85FC) |

**API for the renderer:** `machine.unrolledRowFill(entry:stop:pattern:y:) -> UInt8` runs the filler
from instruction address `entry` up to the planted return at address `stop` ($85BF for none),
storing `pattern` through `$8E/$8F` (and incrementing `$8F` at $859B if passed). It returns Y and
charges 2 per Y load, 6 per store, 5 for the page step and 6 for the return; the caller charges its
own call and writes the planted/restored bytes itself, as the original does (a debug assertion
checks that `stop` holds a return opcode). Tested in both horizon patterns, including the returned
Y.

## Pen and span-color ops

The display-list handlers end by advancing `len` through $8749. The port returns `len` (`opPen3`
1, `opDottedPen` 1, `opPen` 2) and charges up to and including that jump; the interpreter advances.
`opPen` reads n at `($8B)+1` and uses `$9BD6[n]` unmasked (n >= 16 reads the code after the table,
as in the original).

## Text

**Record:** `[row][x][ASCII...][terminator]`. Row through the row tables; x in multicolor pixels
(the panel digits are therefore 2 hi-res pixels per font pixel). Each character is an opaque 4x5
cell: the font row is ANDed with `$162C/$1630[x & 3]` and ORed with the pen-3 pixels, over two
bytes (offset `(x << 1) & $1F8` and +8). x += 4 per character (8-bit). The record ends at any byte
< $20 or >= $A0 (a subtraction of $20 and a sign test). `$C0/$C1` end just past the terminator.

**Glyphs:** `$1634[2·(ch - $20)]`, 59 words for $20-$5A. Each row takes the next 3 bits from the
bottom of the word: the top row is bits 0-2, and bit 2 of each group is the leftmost pixel (the
bits are reversed into the `$1624` index). Characters $5B-$9F read past the font into the code at
$16AA; the port reads memory the same way, so they render identically.

**Lists ($1E99):** records until one whose first two bytes are 00 00; a record with row 0 and x != 0
is drawn.

**Numbers ($1D54):** A/X = record. Byte +2 = ' ' or '-' (then $B8/$B9 is negated in place),
bytes +3..+6 = digits by repeated subtraction of 10000/1000/100/10 (`$1DBB`, stopping when the
high byte goes negative), byte +7 = `$B8 | $30`. -32768 is still negative after negation and
prints as six dashes. The record is then drawn ($1DE2). Leaves $B8/$B9 = last remainder,
$BA/$BB = record+2, $A5-$A7 per the last glyph.

**Carry out.** Every record routine ($1D54, $1DDE, $1DE2, $1E01) exits through that end test, so
the carry is set for a terminator $A0-$FF and clear for $00-$1F. The failure picker at $EB25
depends on it: right after drawing the "AIRCRAFT PROBLEM" record (00 terminator) it adds `$22` and
`$5F` without clearing the carry first. The ports return this carry
(`@discardableResult Bool`), and the tests compare it with the original's.

**clearWindow ($1EAF):** zeros $4000-$517F (bitmap A, ignoring the row tables), leaves
`$8E/$8F = $5100`, 71,891 cycles.

### Text cycles

Verified against the lab: `drawTextRecord` of an empty record costs 133 cycles, and each
character adds 868 + 95·(x & 3), +1 per glyph row at row >= $38, +1 per row whose pointer low
byte is >= $F8, +2 for codes >= $86. `readRecordByte` ($1DF6) costs 22 cycles plus the call (25
when `$C0` wraps). Its taken branch to $1E00 crosses a page.

## Tests

`RasterDiffTests` (21 tests, about 56,000 cases, 4.5 s in a debug build) runs each case on the
regular-flight RAM with the window rows on bitmap B (as captured) and on bitmap A (flipped as the
main loop does). It compares the whole 64 KB image except the stack page, and the cycle count:

- `setPen` for all 256 A values from every pen state (including dotted and the disk operands);
  `setSpanColor` for all X; `setSpanColorFromPalette` for all `$0876`.
- Ops $1B, $1C (day and night) from every pen state, and op $12 n for every n, with the list
  inside a page and across one (`$8749` stubbed with a return; the expected cycles add its 6).
- Plots, and about 7,600 lines in total over every pen state (pens 0-3, $80-$83, dotted, disk
  operands) and both buffers: random, short in every octant, horizontal, vertical, single-pixel, diagonal,
  crossing x = 128, edges and corners of the window and panel; 400 XOR lines with x up to 255.
- Spans for every right end x 0-159 with the boundary lengths (0, 3, 22, 23, 24, x) and random
  short and long spans, for every span color and the disk state, both buffers.
- The filler as the horizon uses it (whole rows; halves cut at a planted return).
- Text records (random positions, characters including $5B-$9F, all terminator kinds, records
  across a page boundary), the $1DE2 and $1E01 entries, lists, and `printSigned5` for the 5-digit
  edges (0, ±1, ±9999, ±10000, 32767, -32767, -32768, ...) plus random values, at record
  addresses where record+2 carries into the next page; the exit carry of every record routine.
- Exhaustive sweeps: every short line (|dx|, |dy| < 10) from every pixel phase and every row of a
  character cell, both sides of x = 128 and across the window/panel boundary; every span (x,
  A <= x) of the window; `plot` at every x 0-255 on edge rows (with the returned registers);
  every glyph index $00-$7F at every x & 3 phase; `printSigned5` at every digit boundary
  m·10^n ± 1, both signs.
- Arbitrary patched ops: every site patched with random OR/AND/XOR ops and mask-table operands
  (a third ending a page, so the indexed reads cross it), with the dotted call in some cases, then
  lines, plots and spans. This proves the decoding of the code bytes in general, not only the
  states `setPen`/`setSpanColor` produce.
- Operation sequences: random sequences of all the pen ops, span colors, plots, lines, spans,
  records and numbers on one evolving RAM, each step starting from the original's RAM after the
  previous one.
