# Display, raster split and 2D primitives

All drawing is integer and has to be **pixel exact**: golden frames are compared with zero tolerance. Floating point is allowed only for palette conversion and scaling at presentation time.

This page is the overview of the display hardware setup, the raster split, the double buffer, the palette, the panel and the drawing primitives. The ported routines are specified in:

- `raster.md`: the 2D primitives (pens, plot, line, spans, the row filler) and the 3x5 text;
- `render3d.md`: the view matrix, the horizon fill, clipping, polygons, projection, the attitude indicator, the turn coordinator and the view overlays;
- `scenery-3d.md`: the horizon pass ($83A4-$840E) and the display-list interpreter;
- `panel.md`: needles, gauges, markers and the instrument masks;
- `main-loop.md`: the raster IRQ, the page flip and `displayInit` ($25EB);
- `engine.md`: how the port presents a frame (the latched split, text mode).

## VIC setup ($25EB, via $2042 and $AB0B)

| Register | Value | Meaning |
|---|---|---|
| $DD02 / $DD00 | $3F / $96 | VIC bank 1 = $4000-$7FFF (shadowed in $0E89) |
| $D011 | $3B | Bitmap mode, display on, 25 rows, YSCROLL 3 |
| $D018 | $F0 / $F8 | Screen RAM $7C00. Bitmap A $4000 / bitmap B $6000 |
| $D021 | [$0E69] | $0B in color mode, $00 in B&W |
| $D015 / $D01C | $0F / $0F | Sprites 0-3 on, multicolor |
| $D025 / $D026 | $0B / $01 | Sprite multicolor 0 / 1 |
| $D027-$D02A | $0B | Sprite colors |
| Sprite positions | ($58,$AA) ($68,$AA) ($58,$B5) ($68,$B5) | Static attitude-indicator bezel: 40×32 hi-res pixels at screen (64,120) |
| Sprite pointers $7FF8-$7FFB | $E8-$EB | Sprite data at $7A00-$7AFF |
| IRQ | vector $2285, first raster $97, $D01A=$01 | |
| Color RAM | all $01 (white), set via $7331 → $794E | |

## Raster split (IRQ $2285)

The IRQ has two phases, toggled by `irqPhase` ($4A). On entry it forces `$01=$35`; on exit it restores $01 from $4B and acknowledges $D019.

| Raster | Region | Writes | Next IRQ |
|---|---|---|---|
| $20 (line 32) | Window | border = [$22B5] (time-of-day color), $D018 = [$22B0] ($F0/$F8, the buffer to show), $D016 = $D8 (multicolor) | $A3 |
| $A3 (line 163 = bitmap row 112) | Panel | border $0C, $D018 = $F0 (always bitmap A), $D016 = $C8 (hi-res) | $20 |

- The window phase also runs the per-frame tick at $22C3:
  - `$34` + 1 (jiffy)
  - `$0E6B` + 1 (10 Hz divider)
  - the voice-3 gate-pattern countdown
  - the keyboard phase
- **Keyboard phase (a correction to earlier notes).** The scan is not every third frame. `$08A6` counts down from 3 each frame:
  - two idle frames;
  - 0 → full scan $2418;
  - −1 → release check $2505, then reload.

  That is a 4-frame cycle, 15 Hz on NTSC.
- **Alternate IRQ $2304.** It is installed by $2673 for text mode and disk I/O and runs only the tick, with no VIC writes.
- **Panel row copy.** $AB66 copies panel character row 14 ($5180-$52BF) into bitmap B at $7180. Line 112 then looks right even if the split lands late.
- **What the port does.** The raster IRQ's two phases latch their VIC states (`IO.viewRegion` at line $20, `IO.panelRegion` at line $A3); the presenter shows raster lines $20-$A3 with the window state and all others with the panel state, each with its own border color (`engine.md`, "The picture").

## Double buffering ($208B in the main loop)

All drawing goes through the row tables: high bytes at $0200-$02C7 and low bytes at $02C8-$038F, 200 rows each, in the standard C64 bitmap layout.

Each main-loop pass, unless the bit shifted out of `$0E79` is set, the loop does three things:

1. It adds `$8D` to the 112 window-row high bytes ($0200-$026F).
2. It sets `$8D ^= $C0`. `$8D` starts at $20, so it alternates +$20 / +$E0 and drawing alternates between $4000 and $6000.
3. It stores X ($F0 or $F8) into **$22B0**. That is the immediate operand the IRQ writes to $D018, so the buffer just finished is shown.

The window is never cleared separately. The horizon fill repaints all 112 rows every pass. `$1EAF` clears $4000-$517F only for text menus and messages.

**Port:** `pageFlip()` (`main-loop.md`) does exactly this on the row tables in memory. `$0E79` bit 0 is set by the integrator when it applies a roll cancel ($341B-$3426, `flight-model.md`), so the next flip is skipped once.

## Window colors and palette

Window screen RAM $7C00-$7E2F (rows 0-13) holds one byte, written by $EC7C. With color RAM white, each 2-bit pixel means:

| Pen | Source |
|---|---|
| 00 | $D021 background |
| 01 | Sky: screen-byte high nibble |
| 10 | Ground: low nibble |
| 11 | White |

The time of day is chosen by **$EBF2**:

- It reads hour `$0983`, minute `$0984` and season `$0985 & 3` against the thresholds at $EBD2 (4 seasons × 4 × (minute, hour)).
- Quirk: the minute byte is always read from the season-0 row. This is harmless, because all minutes are :00 or :30.
- The thresholds are:

Each season has its own four threshold times (dawn, day, dusk, night), half an hour apart around
morning and evening; the summer season has the longest days and the winter one the shortest. The
port reads them from the table in memory.

- Result: time < T1 → night (4), < T2 → dusk (2), < T3 → day (1), < T4 → dusk, else night. It goes to `$083C`.
- On a change, $EC41 sets the border `$22B5` and $EC7C fills the screen RAM.

The values are set by the display prompt at $AA1C:

| Mode | $D021 ($0E69) | Day ($0E61) | Dusk ($0E63) | Night ($0E65) | Window border day/dusk/night |
|---|---|---|---|---|---|
| A: color | $0B | $65 (blue sky / green ground) | $6C (blue / gray) | $EA (light blue / light red) | $0E / $06 / $00 |
| B: B&W | $00 | $FC | $CB | $CB | $0E / $06 / $00 |

The sky and ground fill patterns come from `$0880`/`$0882`, not from the palette (see Horizon below). The area display lists write them (with `$0876-$0881`): op 1A copies palette words from `$0800-$081E` chosen by the time of day `$083C` and the altitude `$0830` (`scenery-3d.md`). The lab sessions show the results (`features.md`): $D5/$2A by day (patterns $55/$AA), 0 at night (the window shows the background color, with dotted lights), $FF below a cloud layer (white sky), $77/$FF above it.

## Panel

- **Bitmap.** $5180-$5F3F: hi-res, 320×88, bitmap A character rows 14-24, from disk blocks 6-9. It contains stale digits, which `$2240` redraws at init. Treat it as an asset read from the user's disk.
- **Cell colors.** $7E30-$7FE7, from the $77E0 load. The high nibble colors set bits, the low nibble clear bits.

| Value | Where |
|---|---|
| $1B | White on dark gray: most of the panel |
| $1C | Separators / right column |
| $E9 | Light blue on brown: attitude-indicator cells, columns 8-12, rows 15-18 (pixels 64-103 × 120-151) |
| $70 | Yellow on black: radio frequency windows, columns 29-33, rows 15/17/19 |
| $EB / $AB | Lamp cells, row 15, columns 35-36 |
| $BB | Unlit marker lamps $7E7B-$7E7D. Lit: outer $EB, middle $AB, inner $1B. |
| $FB | Light gray on dark gray, rows 22-24 |
| $2B | One red cell, row 16 column 1 |
| $12 / $1B | Stall lamp $7E3D/$7E3E, on / off |
| $FE / $B8 | CH/HT cells $7FE5-$7FE7 |

- **Sprites.** The 4 multicolor sprites at $7A00 form the attitude-indicator bezel: rounded-corner mask, pitch ticks, bank ticks and the fixed aircraft symbol. Sprites are turned off during disk I/O ($E657) and on the error screens.
- **Persistent 1-bit panel.** Needles, markers and the turn-coordinator wings are drawn with **XOR** and erased by redrawing the old state. Overlapping needles cancel each other, as the two altimeter hands do. The port draws into the same bitmap memory with the same XOR operations in the same order.
- **Instrument masks.** `$F35E` combines the enable, failure and lighting masks into `$FD`/`$FE`/`$FF` every pass and blanks or restores an instrument's area when its bit changes (`panel.md`, "The areas"). The bit owners: `$FD` b0 airspeed, b1 turn coordinator, b2 DG, b3 altimeter, b4 none (a 2×2 blank area; no driver tests it), b5 NAV1 OBI, b6 tach row, b7 VSI; `$FE` b0 TIME label, b1 XPNDR label, b2 NAV 1 label, b3 COM 1 label, b4 compass, b5 fuel row, b6 oil row, b7 radios; `$FF` b0 CH label, b1 NAV 2 label, b2 DME label, b3 NAV2 OBI / ADF.

## Text mode (error screens and the editor)

$796C sets up the text screen:

- border $08, $D018 = $16 (ROM upper/lowercase set), $DD00 = $97 (bank 0), $D011 = $1B, $D016 = $08, $D021 = $01
- sprites off, color RAM $0B, screen $0400 cleared

It is reached via $732E (system error $791E, disk-error prompt $5FAB) and via $203F → $2673 (editor). $5F40 restores graphics when `$0E89 != $97`.

**Port:** $2673/$796C/$5F40 are ported (`editor.md`). `Machine.presentTextScreen` renders the text screen with the imported character ROM (`GameData.charROM`) or, without one, `FallbackCharset`. The system-error and disk-error screens cannot be reached in the port (`excluded.md`).

## 2D primitives

Coordinates are multicolor pixels: x 0-159, y = bitmap row. Lines are clipped in 3D before projection, so the 2D primitives never clip. The exact behavior and the port are in `raster.md`.

### Tables

| Table | Use |
|---|---|
| $14DA[x] | Byte offset in the row = ((x>>2)·8) & $FF. For x ≥ 128 the code also increments the row high byte. |
| $157A / $157E | OR masks for pen bit 0 / bit 1 at pixel x&3, MSB-first pairs |
| $1582 / $1586 | Matching AND masks |
| $158A | Fill byte per pen: 00 / 55 / AA / FF |
| $9BD6 | Scenery color code 0-15 → 2-bit pen (op 12 and polygon fills) |

### Pens ($9BF5 = $800F)

`A` = pen 0-3, with bit 7 set for XOR. The routine self-modifies the OR/AND/XOR opcodes and mask operands of every pixel write in the plot and line code: $9A14-$9A19, $9AB0-$9AB5, $9AF1-$9AF6, $9B32-$9B37, $9B73-$9B78, $9B8D-$9B8F.

- Bit 0 (tested against $0F00) selects an OR with $157A or an AND with $1582.
- Bit 1 (tested against $0F01) selects an OR with $157E or an AND with $1586.
- XOR turns both into XORs with the same tables.

Related display-list ops:

| Op | Routine | Effect |
|---|---|---|
| 12 n | $9BE6 | pen = $9BD6[n] |
| 1B | $9B91 | pen 3 |
| 1C | $9B9B | Only when `$083C` bit 0 is clear (dusk or night): pen 1, and the second bit op becomes a call of $9B80. A pixel is then written only when (steps remaining $F3 & 3) == 0, giving dotted lines. Any later `$9BF5` cancels dotted mode. |

**Port:** the pen routines write the patched bytes; the drawing routines decode them into an explicit pen (`SitePen`: `first`, `second`, `dotted`; `raster.md`).

### Plot ($99FD = $800C)

X = x, Y = row. The pointer comes from the row tables, its high byte is incremented when x ≥ 128, the byte offset is $14DA[x], and the write is (byte OP1 mask1) OP2 mask2 for the current pen.

### Line ($9A1D = $8009)

Endpoints are ($EB,$EC)-($ED,$EE).

- The endpoints are swapped so the line **starts at the larger x**, and that pixel is plotted first. x only ever steps left.
- dx goes in $18 and dy in $19. Count $F3 = major delta; error $F4 = major>>1.
- Each step: error −= minor; on borrow, error += major and the minor axis steps.
- There are four loops: $9A7C and $9ABD (y-major, up/down), $9AFE and $9B3F (x-major, up/down).
- Row steps adjust $8E/$8F directly: ±1 inside a character cell, ±$139 across a character row. The boundary is detected by testing the low byte against `$1B`, which holds 7.
- Stepping left: the pixel index wraps from 0 to 3 and Y −= 8 (`$8F` − 1 on a borrow).
- The same routine draws on the panel at 2-pixel resolution, e.g. the turn-coordinator wings.

### Spans ($9996 = $801B; $9910)

- A+1 pixels are filled leftward from x = `$1E` on the row at $8E, with pattern `$1A`.
- Spans shorter than 24 go pixel by pixel, then whole bytes.
- Longer spans use the unrolled row filler at **$851B**: 40 stores through `$8E/$8F`, cut short by planting a return at $851D+Y.
- The color comes from $9C93 = $801E (`$0876 & $0F` → $9BD6) or $9C9C = $8024 (X = pen). These patch the partial-byte ops at $992A, $9986 and $99BC.

### Polygon fill ($96D4-$990F)

Vertices are taken from $0CD0 (x) and $0D50 (y), with the row range in $F1-$F2.

Edge tables:

| Table | Content |
|---|---|
| $0B10 | Start y |
| $0B50 | Rows remaining |
| $0B90 | Fraction |
| $0BD0 | x |
| $0C10 | Fractional slope |
| $0C50 | Integer slope |

Per scanline the crossings are collected into $02+ (the count is self-modified at $98AD), bubble-sorted and filled in pairs via $9996. Because crossings are filled in pairs, concave polygons fill correctly whenever each row has an even number of crossings; a row with a single crossing is the degenerate case `render3d.md` describes. The fill byte is `$158A[$9BD6[$0876 & 15]]`.

### Horizon and sky/ground fill ($83A4 = $8003, every pass)

1. Run the 16-byte horizon list at `$0AD0 + 16·(((yaw_hi + $20) >> 6) & 3)` through the interpreter (`horizonPass`, `scenery-3d.md`):
   - The eye offsets `$66/$67` and `$6A/$6B` (saved in `$02-$05`) and only the high words of the ground base (`$24/$25`, `$27/$28`, `$2A/$2B`) are zeroed; the base low bytes `$26`, `$29`, `$2C` keep their values.
   - Line drawing is disabled by patching the line driver's call at $8B89 into a harmless read.
   - The clipped endpoints are captured into $EB-$EE; `$EC = $FF` means no horizon.
2. Fill bytes:
   - `$EF` (below the horizon) comes from `$0882`: 0 → $00, $FF → $FF, otherwise $AA (ground).
   - `$F0` (above) comes from `$0880`: 0 → $00, $FF → $FF, otherwise $55 (sky).
   - $84FB swaps them for inverted orientation.
   - With no horizon, the whole window gets one color, chosen by the sign of $73.
3. Rows entirely above or below the horizon are filled whole: $8504 → $851B.
4. Crossed rows go through the Bresenham at **$8623** (self-modified x steps at $8678/$868C and row steps of $E9 at $8679/$869A), which calls **$85C0** per row:
   - $EF on pixels 0..x, $F0 to the right;
   - a mixed boundary byte, built by shifting both patterns 2 bits per pixel, stored at $14DA[x].
5. The window bottom row is $6F.
6. The horizon *line* is a separate 7-byte display list at **$8458** (`1B 06 x1 y1 x2 y2 19`). $83A4 rewrites its endpoints. Area lists draw it later with `09 90 08`, a call through the pointer at $0890.

### Text (3x5 font)

**Record format.** `[y][x in 2-pixel units][ASCII...][0]`; a list ends with `00 00` (drawn by $1E99).

**Font (a correction to earlier notes).** $1634-$16A9 holds **59 glyph words for ASCII $20-$5A only**.

- $16AA is code (the multiply wrapper). Characters $5B-$5F would read code bytes.
- Each glyph is 3 bits × 5 rows, top row first, with the bit-2 slot as the leftmost pixel. Glyphs A, Z and 0 were decoded and verified.

**Drawing ($1DDE/$1DE2/$1E01).**

1. Each 3-bit row goes through $1624 to become pen-3 pixel pairs.
2. The pairs are shifted by (x&3)·2 across two bytes.
3. The background is cleared with $162C/$1630, so each cell is **opaque**, 4 pixels wide.
4. x advances by 4.

The same routine draws the white window menus and all panel digits, where one font pixel is two hi-res pixels.

**Number printing.** $1D54 prints the signed 16-bit value in $B8/$B9 as a sign plus 5 digits at record+2. $3804 formats 3 unsigned digits.

### Needles ($1A86; A = angle 0-87, X = gauge 0-4)

- 88 steps per turn: 0 points to 3 o'clock, 22 points up, and angles increase counterclockwise.
- Per-gauge tables: centers x $0F67 and y $0F6C, type $0F71 (0 = long hand, table $0F76; 1 = short hand, table $0FA6), current angle $0F62. `$0F66` (gauge 4's angle) is unused: the ADF keeps its angle in `$E7F6` (`panel.md`).
- Each table holds 23 pointers to run-length shapes: one (x offset, length) pair per scanline, ending in a byte with bit 7 set.
- Quadrants are mirrored by self-modified opcodes (x steps, add or subtract, row steps):
  - a < $16: right/up, index a
  - a < $2C: left/up, index $2C−a
  - a < $42: left/down, index a−$2C
  - otherwise right/down, index $58−a
- Drawing is XOR with the masks at $0F08.

| Gauge | Instrument | Center | Driven by |
|---|---|---|---|
| 0 / 1 | Altimeter long / short hand | (141,136) | $CE84 → $1F/$20 |
| 2 | Airspeed | (25,136) | $CF0E via table $14C2, 1/4-step smoothing |
| 3 | VSI | (141,180) | $CF46, clamped ±9, 1 step per update |
| 4 | ADF | (203,182) | $E7FE |

### Markers and point lists ($1D01)

`($9C)` points to `[count][dx,dy]×count`, plotted with XOR at x = $0A9F+dx (carry into $0A90 = bit 8) and y = $0AA0+dy, mask $0F08.

Shapes: $0F10, $0F1D, $0F30, $0F49, $1612, $161B, $1CE7 (fuel selector), $3B13 (localizer bar), and the 10,000-ft marker shapes $F7EE-$F86E.

### Attitude indicator ($A378 = $8021, every pass)

1. Redraw only when pitch `$6D` or bank `$6F` differs by 2 or more from the last drawn values at $A354/$A355.
2. Fill all 32 rows of the AI cells (rows 151 up to 120, byte offsets $40-$60) with $00 or $FF ($A4A0).
3. If ($6D+$20) < $40, the chord angles are bank − off and bank + $80 + off, where off = $A356[($6D+$20)/2].
4. The endpoints come from sin/cos ($18B8/$18BD) times radius $12 ($1961) around (x $29, y $88), in 2-pixel units. y uses a 3-step arithmetic shift.
5. The chord is drawn by the horizon Bresenham $8623 with $85C0 temporarily patched into a jump to $A4CA (a span between x $20 and $33), then the remaining rows are filled.
6. Set bits show light blue (sky) and clear bits brown (ground), from cell color $E9. The sprites overlay the bezel.

### Turn coordinator ($A532 = $8012)

The rate index 0-15 comes from `$09FE/$09FF`. Two XOR lines (pen $83) are drawn from the 16 × (dx1, dy1, dx2, dy2) table at $A4F2, around (12,176) in 2-pixel units.

### View overlays ($ED3C, every pass)

| Case | Drawing |
|---|---|
| Radar (`$0836`) | ORs the aircraft-symbol pixel list $ED1F |
| War mode + down view ($ED45) | ORs the bombsight list $ECE1 |
| Other views (`$0ACA` bit 7 clear) | $ED88 draws a white span-filled trapezoid per view direction from $EC99, entry `$0ACA`·4 (8 bytes): width − 1, width fraction step, width step, start row, x, x fraction step, x step, rows. None for the front view and the down view. It is the airframe (wing or tail) the `views` session shows in each direction (`render3d.md`). |

Pixel-list entries are (offset lo, offset hi relative to the $0200 row base, mask) and end with `00 00`.

## Port status

Everything on this page is ported and verified against the original: the routines by the
differential suites of `raster.md`, `render3d.md`, `scenery-3d.md` and `panel.md`, the whole
picture by golden frames that must match the lab's pixel for pixel (`SceneryPassTests`,
`ReplayTests`, `NativeEngineBootTests`). The window is the C64's own multicolor bitmap memory, so
the splash detector's read of `$50DE` (y 110, x 152-159) sees the same byte as the original.
