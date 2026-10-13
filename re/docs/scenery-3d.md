# Scenery bytecode, streaming and overlays

The scenery is **bytecode**, and the port interprets it: the data cannot be converted to models.

- It reads and writes absolute game-variable addresses: $5C/$60/$64, $66-$6A, $0800-$0890, $0958 and others.
- It patches values and code operands.
- It can call native code by address.
- It finds radio stations as a side effect of drawing, and it streams its own blocks from disk.

This page is the definitive reference for the display-list interpreter ($8730-$8FE7, the opcode
table $86A4, the record ops $8030-$8110, the runway op $A5C8-$A73D), the horizon-pass glue
($83A4-$840E), the streaming and overlay code ($E565-$E712) and the 10 Hz poll ($2330). The 3D
routines the opcodes call (the view matrix, the point transforms, clipping, polygons, projection,
the horizon fill) are described in `render3d.md`; the 2D primitives (lines, plots, pens, spans) in
`raster.md`; the math in `math.md`.

## The port

| File | Routines |
|---|---|
| `Scenery/SceneryVM.swift` | `runScenery` $8730, `dlInterpreter` $8742, `dlAdvance` $8749, `dlLoop` $8752, the dispatch, `dlStep` $8851, `dlRelativeTarget` $8DB3, ops 0B, 11, 18, 09, 0A, 19, `opJumpAbsolute` $A731, the native-call ABI, `copyOperandBytes` $80D1 |
| `Scenery/SceneryGeometry.swift` | points $88A1/$8860/$88D1/$8896, ops 00/01/02/40/41, the vertex cache $89E4 and ops 31/42/32/33/35, polygons 2F/29, `lineClipDriver` $8B40, op 06, `halvePoint` $8B2A, the dashed line op 2B |
| `Scenery/SceneryConditions.swift` | ops 04, 13, 14, 20-22, 23, 28 |
| `Scenery/SceneryOrigin.swift` | ops 07, 24 ($8C0D) |
| `Scenery/SceneryRecords.swift` | ops 1A, 25, 1D ($8055), 1E, 05 (through `ndbHook`), 0D |
| `Scenery/Runway.swift` | op 03 $A5C8 and its template $A5A7 |
| `Scenery/HorizonPass.swift` | `horizonPass` $83A4-$840E (then the renderer's `horizonFill`) |
| `Scenery/Streaming.swift` | `setSceneryRoot` $E565, `loadBlockCached` $E58F, `readBlocks` $E63C, the loader's memory effects (`Scenery.Loader`, $74DC/$7542) |
| `Game/Overlays.swift` | `loadOverlay` $E5C0-$E5F6, `loadRootBlock` $E618, `cacheHelper` $E6D2, `swapEditorCacheIn` $E6D8, `swapEditorCache` $E6DB |
| `Game/Poll.swift` | `pollTick` $2330 |

Conventions (as in `render3d.md`):

- **Memory-faithful.** Every handler reads and writes the bytes its original does, at the same
  addresses: the PC `$8B/$8C`, the handler address in `$A5/$A6`, every zero-page temporary, and the
  self-modified code bytes (the transform operands $8863/$88A4, the line-draw opcode $8B89, the
  driver exit $8BAC, the native-call operand $880C, the range-test operands $8EA6/$8EAD, the
  subtraction's immediate operand $8F32, the runway template). Where the original executes a byte it
  patched elsewhere, the port reads it back ($8B89, $8BAC, $8863/$88A4). The 6502-stack recursion of
  the calls becomes Swift recursion; the stack page is not modeled (and not compared).
- **Cycles are exact**: from a routine's first instruction through its return; the caller charges
  its call, and a call through a vector ($80xx, $20xx) adds the vector's jump. The tests compare the
  cycles of every call, branch page crossings included ($80EF, $8912, $8B20, $74FC, $753F,
  $E704/$E70B take 4 cycles when taken).
- **Faults.** An unused opcode makes the original call the fatal error $7303 (the SYSTEM ERROR
  text screen). The port throws `Scenery.Fault.invalidOpcode(op, at:)` from the interpreter
  entries instead; the caller decides what to show.

## Per-pass flow (main loop $2048)

1. At $207D, `setSceneryRoot` ($E565): `$8B/$8C` = [$A7E0], the loaded overlay's end word, where
   the root list (block 66) sits: $A800 in flight, $B1EA with the war overlay.
2. At $2080, the view matrix (vector $8000 → $8111, `render3d.md`).
3. The page flip (unless `$0E79` bit 0).
4. At $20D5, the horizon pass (vector $8003 → $83A4), then the sky/ground fill.
5. At $20D8, the scenery display list (vector $8006 → $8730).

The war overlay ($AC2C) and the course plotter ($F6FC) also run lists through $8006.

## The interpreter

| Entry | What |
|---|---|
| $8730 (vector $8006) | `runScenery`: copies the search requests to the per-pass flags (`$0920` → `$0921` NAV, `$0937` → `$0938` COM, `$08BD` → `$08BE` ADF), falls into $8742. 24 cycles. |
| $8742 | Clears `$0916` and `$8A` (9 cycles), falls into $8749 with A = 0. Entered by the horizon pass and by op 1E. |
| $8749 (vector $8018) | `dlAdvance`: PC += A (11 cycles, 15 when the high byte carries), falls into $8752. |
| $8752 | `dlLoop`: the fetch loop. |
| $8851 | `dlStep`: PC += A, then returns (17/21 cycles). |

**The loop ($8752).** Per opcode:

1. The 10 Hz poll through the vector $2012 to $2330 (`pollTick`; 16 cycles when nothing is due).
2. The opcode byte at the PC is fetched and compared with $46.
3. **$46 and above (END, normally $79):** the per-pass search flags `$0938`, `$0921` and `$08BE`
   are cleared and the interpreter returns: the list returns to whoever ran it.
4. Otherwise the handler word for the opcode (entry 2·op of the table at $86A4) goes to `$A5/$A6`
   and the interpreter jumps through it. Handlers start with Y = 0 and X = 2·op.

59 cycles per opcode with the poll and its call (61 from opcode $2E on, whose table reads cross a
page), 57 for END. Handlers end in one of three ways:

- advance by the op's length through $8749 and fetch;
- back to $8752: fetch at the PC as it is (jumps, calls, points and lines that moved the PC);
- return: op 19, END, or (never in practice) a handler that jumps into a driver whose exit is
  patched to a return.

**Calls.** Ops 18, 09 and 0A push PC + 3, count the depth `$0904` up, and run the fetch loop
$8752 as a subroutine (op 0A calls native code instead); when the callee returns (op 19 or END),
the depth counts down, PC = the pushed value, and fetching resumes at $8752. The runway op runs
its template as a nested pass through $8730. Nothing bounds the depth.

**Relative targets** are always *opcode address + rel16* (`$8DB3` puts the target in `$A5/$A6`).
The rel16 sits at bytes 1-2, except for op 28, where it is at bytes 2-3. A taken jump is `$8F43`
/ `$8DA8`: PC = `$A5/$A6`, then fetch at $8752 (15 cycles).

**The 10 Hz poll ($2330).** `$0E6B` − 6; when that is negative the poll returns. Otherwise `$0E6B`
keeps the difference and the tick body $2348 runs with I/O banked in (`$01` = $35, then `$4B`
again): key dispatch, engine pitch, key repeat, 5 Hz aero and joystick, 1 Hz sound and clock. One
tick per poll: a backlog of several ticks is caught up over the following polls (not in a loop). The
port's `pollTick` first gives `Machine.pollHandler` (the replay/scheduler hook) its poll point.

## Opcodes

70 table entries ($86A4, opcodes $00-$45). 40 are used; the other 30 point at the invalid-opcode
handler $8778. The handler addresses themselves are in `symbols.json`; the subsections below name
the ones the text refers to.

| Op | Length | Meaning |
|---|---|---|
| 00 | 7 | 3D dot x y z: point A ($A1CE), then when its outcode is 0 projected again and plotted (`$99FD` with the screen x, y) |
| 01 | 7 | 3D moveto x y z (point A) |
| 02 | 7 | 3D lineto x y z (point B), drawn by the line driver unless a polygon is open |
| 03 | 6 | Runway hdg8 len16 wid16 (see below) |
| 04 | 3 + n + 1 | Cull rel16 i1 … term(≥ $80): jump when every listed cache entry is invalid and their outcodes share a set bit |
| 05 | 9 | NDB record freq16 X24 Z24, through the hook $802A that the cold start points at $E956 (`ndbHook`, `radios.md`) |
| 06 | 5 | Screen line x1 y1 x2 y2 (not clipped) with the current pen |
| 07 | 14 | Origin s X32 Y32 Z32 |
| 09 | 3 | Call the display list at the address in the word at abs16 (skipped when 0) |
| 0A | 3 | Call native code at the address in the word at abs16 (skipped when 0) |
| 0B | 3 | Jump rel16 |
| 0D | 6 | Load blocks: blk cnt rel16 slot |
| 11 | 1 | No-op |
| 12 | 2 | Pen n through the pen table $9BD6 (`raster.md`) |
| 13 | 9 | Range box rel16 R z x |
| 14 | 9 | Range box and altitude rel16 R z x |
| 18 | 3 | Call rel16 |
| 19 | 1 | Return from a list call |
| 1A | 5 | Copy word: [dst16] = [src16] |
| 1B | 1 | Pen 3 (`raster.md`) |
| 1C | 1 | Pen 1 dotted, only when `$083C` bit 0 is clear (dusk/night; `raster.md`) |
| 1D | 11 | NAV/VOR/LOC record freq16 X32 Z32 |
| 1E | len | ATIS record len ? com16 params8 text |
| 20 | 9 | rel16, 1 × (addr16, lo16, hi16): jump unless lo ≤ [addr] ≤ hi |
| 21 | 15 | as 20 with 2 triples |
| 22 | 21 | as 20 with 3 triples |
| 23 | 7 | Bit test rel16 addr16 mask16: jump when [addr] & mask = 0 |
| 24 | 8 | Origin at whole high words s Xhi Yhi Zhi |
| 25 | 5 | Store word: [dst16] = v16 |
| 28 | 8 | Compare type rel16 a16 b16 |
| 29 | 1 | End polygon / close the path |
| 2B | 9 | Dashed ground line x1 z1 x2 z2 |
| 2F | 1 | Begin polygon |
| 31 | 8 | 3D point i x y z → cache entry i |
| 32 | 2 | Moveto cache entry i |
| 33 | 2 | Lineto cache entry i |
| 35 | 2 | Dot at cache entry i |
| 40 | 5 | Ground moveto x z (y = 0) |
| 41 | 5 | Ground lineto x z |
| 42 | 6 | Ground point i x z → cache entry i |
| ≥ 46 | 1 | END: clears `$0938`/`$0921`/`$08BE`, returns |

Unused (invalid): 08, 0C, 0E-10, 15-17, 1F, 26-27, 2A, 2C-2E, 30, 34, 36-3F, 43-45.

Two more entries have no table slot: **$A731** (`opJumpAbsolute`, an absolute jump: it takes the two
list bytes after the current operand position as the new PC and continues through the taken-jump
code at $8DA8; as an op 0A target, entered with Y = 1, it reads the op's high byte and the next byte
as the new PC and runs the list there inside the native call) and **$80D1** (`copyOperandBytes`: the
four display-list bytes at PC + Y + 1 … Y + 4 to `$A5-$A8`, `$39` counting down). No code references
either.

### Points and lines

Point A (`$CC` outcode, `$CD-$D2` x, y, z, `$D3/$D4` screen x, y) is the current point; point B
(`$D5`, `$D6-$DB`, `$DC/$DD`) the lineto target.

- **$88A1 (point A):** with Y = $CD, calls the transform whose address is the self-modified operand
  $88A4/$88A5: `$A1CE` (3D, ops 00/01, PC += 7) or `$9FD0` (ground, op 40 and the dashed line, PC +=
  5). The handler writes the operand first. In a polygon the point is appended at `$B7` (no
  60-vertex check) and `$D5` = its z high byte. Otherwise **$88D1**: the outcode ($93D2), the
  projection ($9D05) when 0, and A (`$CC-$D4`) copied to **`$08-$10`**, the start of the path.
- **$8860 (point B):** the same with the operand $8863/$8864 into `$D6`. In a polygon it is
  appended unless `$B7` ≥ 60 ($3C) and `$D5` &= its z high byte (the z signs combined bitwise:
  negative means the whole polygon is behind the eye). Otherwise **$8896**: the outcode ($941B), the
  projection ($9D21) when 0.
- **Op 00 ($8A25):** point A, then ($8A32) when `$CC` = 0: projected again ($9D05) and plotted by
  $99FD (x = sx, row = sy): a dot with the current pen.
- **Ops 01/40:** point A, then the next fetch. **Ops 02/41:** point B, then the line driver unless a
  polygon is open (`$23`).

**The line driver ($8B40):**

1. `$CC` & `$D5` ≠ 0: rejected (both points beyond one plane).
2. `$CC` ≠ 0: `clipLine` ($9464), `$0916` + 1; still out: rejected.
3. `$D5` ≠ 0: B saved in `$DE-$E4`, `clipLineEnd` ($9478), `$8A` + 1; still out: rejected.
4. The clipped points are re-projected (`$0916`, `$8A`), `$EB-$EE` = (sx A, sy A, sx B, sy B), and
   the call to `drawLine` $9A1D at **$8B89** draws the line (while the horizon pass runs, its
   opcode byte is patched into a harmless read of $9A1D: the endpoints are only captured).
5. In every case B becomes the current point A: the unclipped copy from `$DE-$E4` when B was
   clipped (its screen position then stale), else `$D5-$DD`. `$8A` = `$0916` = 0.
6. **$8BAC**, the jump back to the fetch loop, which the dashed line patches into a return so
   that it can call the driver as a subroutine.

**Op 29 outside a polygon** draws the closing line: B = `$08-$10` (the last moveto), PC += 1, the
driver. Line strips close this way.

**Op 06 ($8BAF):** the four bytes to `$EB-$EE` (an indexed store based at $00EA), then `drawLine`
$9A1D. Not clipped.

**Op 2B, the dashed line ($8A43):** both operands of $8863/$88A4 = $9FD0. Point A from bytes
1-4 (PC += 5), the PC back by one (`$8B`, with the borrow into `$8C`), point B from bytes 5-8
(PC += 5: 9 in all).
Nothing more when `$CC` & `$D5` ≠ 0. The exponents ($8A69): while `$2F` (B's) ≠ `$0905` (A's),
the point with the larger exponent is halved (`$8B2A`) and its exponent decremented. δ = (B − A)
>> 4 (three 16-bit subtractions into `$9E-$A3`, then `$8B2A` four times on `$9E`). The driver
exit $8BAC is patched into a return, `$0AA2` = 8, then per dash: $88D1 (A's outcode and
projection), B = A + δ, $8896, the line driver $8B40 (draws, returns through the patched exit,
and makes B the current point), A += δ (now 2δ past the dash start), and `$0AA2` counts down.
Finally the exit at $8BAC is restored to its jump. Eight dashes of 1/16 with equal gaps.

**$8B2A (`halvePoint`):** the three signed words at zero page X halved (an arithmetic shift right
that keeps the sign; the zero-page indexing wraps). 60 cycles. Also used by the clip planes ($96C9).

### The vertex cache (ops 31, 42, 32, 33, 35, 04)

128 entries × 8 bytes at $0400-$07FF. **$89E4** reads the index byte at PC + Y + 1, **$89E7**
sets `$2D` = index << 3, `$2E` = (index >> 5) + 4, and PC += 1. An entry holds the eye x, y, z
words, then the screen x, y when the point is visible, or (outcode, $FF) when it is not: bit 7 of
byte 7 means invalid.

- **Ops 31/42 ($89A4/$89AB):** the transform operand $8863 patched, the entry selected (PC += 1),
  point B (`$D5-$DD`) saved in `$DE-$E6`, `$DD` = $FF, the point transformed as point B ($8860:
  PC += 7 or 5), a non-zero `$D5` copied to `$DC`, the 8 bytes `$D6-$DD` stored in the entry, B
  restored. In a polygon the point is also appended to the polygon (and has no outcode).
- **Op 32 ($8917):** A = the entry (`$CC` = byte 6 when byte 7 is negative, else 0), also copied to
  `$08-$10`. In a polygon the entry is appended instead ($8976). PC += 2.
- **Op 33 ($8946):** B = the entry (`$D5` likewise), PC += 1, the driver. In a polygon: appended.
- **Op 35 ($8A04):** A = the entry, then $8A32 (plotted when `$CC` = 0).
- **$8976:** appends an entry to the polygon arrays at `$B7` (no 60-vertex check); `$D5` &= its
  z high byte. 92 cycles.
- **Op 04 ($8E0C):** target → `$A5/$A6`, PC += 2, `$DE` = $F8. Per index byte (until one with bit
  7 set): `$89E7`; a valid entry clears `$DE`; an invalid one ANDs its outcode into `$DE`. Then
  PC += 2 (past the terminator) and the jump is taken when `$DE` ≠ 0: every point is invalid and
  all lie beyond one common plane.

### Polygons (ops 2F, 29)

**Op 2F ($881B):** `$23` = $FF, `$B7` = 0, advance 1 (it falls into $8823, op 11).

**Op 29 ($8828), in a polygon:** unless `$D5` is negative (every vertex behind the eye) or `$B7` −
1 is negative (no vertex), `clipPolygon` $8FE8 with `$B7` = count − 1: clip against the four planes,
project, scan-fill with `$158A[$9BD6[$0876 & 15]]` (`render3d.md`). Then `$23` = 0, advance 1.
Points of ops 01/40 and cache entries are appended without the 60-vertex check; only $8860
(ops 02/41/31/42) stops at 60.

### Conditions (ops 13, 14, 20-22, 23, 28)

- **Ops 13/14 ($8E74):** `$98/$99` = R; for z (`$8EA6`/`$8EAD` patched to $64/$65) then x ($5C/$5D),
  **$8EA1**: d = the record word − the eye's high word (`$AB/$AC`); out when R − d (d ≥ 0) or R + d
  (d < 0) has bit 15 set. This is |d| > R with plain sign tests on the high byte (no overflow
  correction: a difference beyond ±$8000 wraps). Out: the original pulls both return addresses off
  the stack (four bytes) and jumps. In: PC += 9. **Op 14** then also jumps when the altitude high
  word (`$60/$61`; in radar mode `$088A/$088B`) − R has bit 15 clear: near and low enough is the
  fall-through case. Detail loads sit behind op 14 boxes; the root list and area lists use op 13
  boxes.
- **Ops 20/21/22 ($8F05 per triple):** `$8E/$8F` = addr; the low byte of [addr] is patched into the
  immediate operand of the subtraction at $8F31 (operand $8F32); `$8E/$8F` is incremented to read
  the high byte. Fails when [addr] − lo or hi − [addr] is negative as a true signed comparison (N ≠
  V); a failure pulls one return address off the stack (two bytes) and jumps. All triples pass:
  advance 9/15/21.
- **Op 23 ($8F4E):** `$8E/$8F` = addr, `$A9` = mask low; jumps when [addr] & mask = 0 (the high
  bytes tested first). `$B5` = 6. Advance 7.
- **Op 28 ($8F7A):** `$A9` = type, `$AB/$AC` = a, `$AD/$AE` = b, `$B5` = 7. Type 0: jump when
  [a] = [b] (high bytes compared first). Type 2: jump when [a] ≥ [b]. Any other type: jump when
  [a] < [b]. Signed, overflow-correct (N ≠ V). Advance 8.

### Origins (ops 07, 24)

**Op 07 s X32 Y32 Z32 ($8BFD):** eye − origin in 32 bits, with the carry chained through each
axis: x into `$3F/$40` (low word) and `$66/$67` (high word), y into `$42/$43` and `$68/$69`, z
into `$45/$46` and `$6A/$6B`. The eye is X `$5A-$5D`, Y `$5E-$61` (radar: `$0888-$088B`), Z
`$62-$65`. Then $8C9C picks 16 bits by s (a short chain of tests on s − 2):

| s | Bits | Code |
|---|---|---|
| 0, 1, $82-$FF | 0-15 | $8CB0 (the low words) |
| 2 | 4-19 | $8D2B |
| 4 | 8-23 | $8CCB |
| 6 | 12-27 | $8CE6 |
| any other | 16-31 | (the high words as they are) |

Then ($8D85) y = 0 becomes 1 (only 0; a negative y stays), and when y differs from **`$35/$36`**
the ground base is recomputed (`$8324`, `render3d.md`); `$35/$36` = y.

**Op 24 s Xhi Yhi Zhi ($8BC1):** the eye's low words are copied to `$3F/$40`, `$42/$43` (radar:
`$0888/$0889`), `$45/$46` unchanged (`$AD` = $FF) and only the high words are subtracted (each
with the carry set). Scale 4 gives meters around a whole-unit origin; this is the area lists'
usual origin.

The horizon pass stores the PC in `$35/$36`, so the first origin op of a pass nearly always
recomputes the base.

### Data ops (1A, 25)

- **Op 1A dst src ($8DC3):** `$A5/$A6` = dst, `$A7/$A8` = src; two bytes through `($A7),Y` →
  `($A5),Y`; the pointers are read again for the second byte (a destination inside `$A5-$A8`
  changes them). `$B5` = 4.
- **Op 25 dst v ($8DEB):** v's low byte is stored through the pointer `$A7` (pre-indexed with
  X = 0), its high byte through the same pointer post-indexed with Y = 1. `$B5` = 4.

Area lists use them for the heading offsets `$0846`/`$0848`, the airport elevation `$0843`, the Zulu offset `$0854`, the
palette words `$0800-$081E` → `$0876-$0882` by `$0830`/`$083C`, and the ATIS runway codes.

### Radio records (ops 1D, 1E, 05)

A retune sets a request (`$0920` NAV, `$08BD` ADF, `$0937` COM); `runScenery` copies the
requests to the per-pass flags; the first matching record met *in range* (behind the area's
boxes) copies its data and clears the request; END clears the per-pass flags.

- **Op 1D ($8030):** while `$0921`: `$0920` = 0; **$8055** compares the record's frequency (BCD,
  e.g. $1390 = 113.90) with `$0925` (slot 8 → `$092F`, `$0922` |= 1) and with `$0923` (slot 0 →
  `$0927`, `$0922` |= 2) and copies the 8 coordinate bytes. `$B8` holds the slot, then counts.
  Localizers use fractional coordinates. Advance 11.
- **Op 05:** the table points at the hook **$802A**, which the cold start ($AA07) points at
  $E956 (`ndbHook`, `radios.md`): while `$08BE`: `$08BD` = 0; on a match with `$E7F4/$E7F5`,
  station A `$0927-$092E` = (0, X24, 0, Z24) and `$E7F3` = 1. It ends by advancing 9 through the
  vector $8018 (to $8749). The port's op 05 charges the hook's jump, calls `ndbHook()` (which
  charges its own instructions up to its jump through the vector), charges the vector's own jump
  itself and advances by the length `ndbHook()` returns.
- **Op 1E ($8084):** byte 1 = the record length (pushed), byte 2 unused. While `$0938`: `$0937`
  = 0; when bytes 3-4 equal the COM frequency `$08B3/$08B4` (e.g. $3515 = 135.15 O'Hare): bytes
  5-12 → `$0939-$0940`, `$0958/$0959` = record + 13 (the text, tokens $80-$8C), `$0941` = 0, then
  the hook $802D (pointed at the ATIS composer $F16A at init: `atis.md`). Then PC += length and
  fetching restarts at $8742 (which also clears `$0916` and `$8A`).

**The ATIS composer and teletype** are specified in `atis.md`: `$F16A` writes the live
values (temperature, wind, Zulu hour, ceiling, runway) into the phrase strings, and the teletype
`$F239` (through `$E713`, on flip passes) expands the tokens and types the text once per tune,
its per-character delay scaled by the COMMUNICATION RATE `$096A`.

### The runway (op 03, $A5C8; template $A5A7)

- θ = $40 − (hdg + hi(`$0849`) + hi(`$0847`)) as an 8-bit angle (a complement plus $41), `$F4`;
  c = cos θ (`$18B8` → `$A9/$AA`), s = sin θ (`$18BD` → `$C0/$C1`).
- L = bytes 2-3 (`$39/$3A`), W = bytes 4-5 (`$9A/$9B`); four `$16C9` products: L·s (`$3F/$40`),
  L·c (`$42/$43`), W·s (`$45/$46`), W·c (`$A9/$AA`).
- The template `2F 40 V1 41 V2 41 V3 41 V4 29 1B 2B C1 C2 19`: V1 = (L·c − W·s, W·c + L·s), V2 =
  (L·c + W·s, L·s − W·c), V3 = −V1, V4 = −V2, C1 = (L·c, L·s), C2 = −C1 (each word and its
  negation written by the handler).
- PC saved, PC = $A5A7, `$0876` = `$0877` = 0, a nested scenery pass through $8730 (the search
  requests are copied to the flags again; the template's 19 returns), PC restored, advance 6.

The result is a pen-0 filled rectangle and a dashed pen-3 centerline. The values are meters at
scale 4 and act as half-extents: the runway drawn is 2L × 2W.

### Native calls (op 0A)

`$A5/$A6` = abs16; the word at abs16 is copied into the operand of the call instruction at $880B
($880C/$880D) and called with A = (low | high byte), X = $14, Y = 1. No list on the disk uses op 0A:
the bytes `09 F441` and `0A 1D13` once noted at $BA70/$BA7A lie in the Chicago area's tail under
the detail slot ($BA2F), which the detail blocks overwrite before the area code calls into it,
and no area pass in the tests executes the handler.
The port maps the target to its Swift port: every vector of the renderer table $8000-$8027
(charging its 3-cycle jump when the vector still holds its jump) and every vector's target
($8111, $83A4, $8730, $9A1D, $99FD, $9BF5, $A532, $A558, $8749, $9996, $9C93, $A378, $9C9C), the
interpreter entries $8742/$8752, $A731 and $80D1, all entered with the ABI's registers. Any other
target has no port, and the interpreter stops the program with an error naming the address; no
list on the disk reaches one.

## The horizon pass ($83A4-$840E, vector $8003)

1. `$35/$36` = PC; the line driver's call at $8B89 is patched into a harmless read (the line
   driver draws nothing); `$EC` = $FF (no horizon yet).
2. PC = $0AD0 + (((`$77` + $20) >> 2) & $F0): one of four 16-byte lists by yaw quadrant
   (`40 x z / 41 x z / 79`, far out; the fourth is at $0B00).
3. `$66/$67`, `$6A/$6B` saved in `$02-$05`, then zeroed with the ground base **high words**
   `$24/$25`, `$27/$28`, `$2A/$2B` (the low bytes `$26`, `$29`, `$2C` keep their values): the eye
   at the origin at its own height.
4. The interpreter at $8742: the moveto/lineto pair goes through the ground transform and the line
   driver, which leaves the visible part of the horizon in `$EB-$EE`.
5. The eye words, the call at $8B89 and the PC are restored; the base is not (the next origin
   op recomputes it, see `$35/$36`).
6. Falls into $840F (`horizonFill`, `render3d.md`), which sets `$0890` to the 7-byte line list
   **$8458** (`1B 06 x1 y1 x2 y2 19`, endpoints rewritten) or 0. Area lists draw the horizon line
   with `09 90 08`.

## Root list and areas

**Block 66** is the root, loaded at the overlay's end word ($A800 in flight). It holds 9 pairs:

- an op 13 range box around the area's center, roughly ±128 km on each axis;
- an op 0D that loads the area's blocks to root + $87.

END is at offset $87. The boxes are disjoint, so at most one area matches; its blocks load at
root + $87 ($A887) and execution falls through into them. If nothing matches, the last area stays
in memory and its own range tests hide everything. Bytes $88-$3FF of block 66 are dead residue.

| Area | Rough location | Blocks |
|---|---|---|
| Chicago: Meigs, Midway, O'Hare, Kankakee | northern Illinois, around the start at Meigs | 68-73 |
| Champaign / Kankakee | central Illinois, about 250 km south of the Chicago box | 52-57 |
| Los Angeles | southern California, far to the west-southwest | 80-85 |
| LA south: Catalina, San Diego | directly south of the Los Angeles box | 112-117 |
| Seattle north | Puget Sound, far to the northwest | 92-97 |
| Seattle south / Olympia | directly south of the Seattle north box | 102-106 |
| New York: JFK, Bridgeport | far to the east, at about Chicago's latitude | 118-122 |
| New England: Boston, Block Island, Martha's Vineyard | just east of the New York box, slightly to the north | 58-63 |
| WWI area (no ATIS) | far to the west at about Chicago's latitude, a few hundred kilometers east of the west-coast areas | 48-51 |

The exact box centers are in the root block itself; the port reads them from the disk.

**Area header:** `25 46 08 ww ww` and `25 48 08 ww ww` set the heading offsets `$0846`/`$0848`
(the high bytes are added to every runway heading: 0 in Chicago, $0AAA = 15° in LA, ~21° in
Seattle, −7°/−15° in New York); `25 54 08 nn 00` sets the ATIS Zulu offset `$0854` in hours (5 in
Chicago and Champaign, 7 in LA and Seattle, 4 in New York and New England; the WWI area has
none). Each airport's elevation in meters goes to `$0843` (`terrainElevationTarget`, which
`$F8AF` follows) through a `25 43 08 nn 00` record behind its range box.

**Detail blocks** stream into slot 1 at an area-specific address (the area code calls offsets
+0 or +3 of the slot with op 18; each detail block starts with `0B rel`). The boxes are op 14
(near and low) or op 22 tests:

| Area | Slot 1 address | Detail blocks |
|---|---|---|
| Chicago | $BA2F | 78 (Meigs and downtown, behind two boxes), 76 (Midway), 74-75 (O'Hare) |
| LA | $BB2A | 90, 89, 86-87 |
| Seattle north | $BC0E | 100, 98 |
| Seattle south | $BC0E | 109, 110, 107 |
| New York | $BA0F | 123-124, 125, 126-127 and 128-129 (one box for both) |

Each group sits behind its own small box (a few kilometers to about a dozen across) around the
airport or district it draws; the boxes are in the area blocks.

**The $C000 guard.** Six area blocks at $A887 end at $C086, and the New York detail at $C20E,
but the loader stores nothing at $C000 and above while `$7327` is set, which `readBlocks` does
for every load: those tails are dropped, and the pointer stops at $C000. ($C000-$C7CF stays the
instrument masks' save buffer.) The same guard drops the root block's last $6B bytes when the
editor overlay ($BC6B) is resident.

## Streaming ($E58F, vector $2036)

1. Op 0D copies `blk cnt dst slot` to `$08FB-$08FF`; dst = opcode address + rel16 unless
   `$08D9` bit 7 is set (then absolute); `$08D9` &= 3 afterward.
2. If `$0900[slot]` = blk: nothing (21 cycles).
3. Otherwise `$0900[slot]` = blk, **the higher slots are zeroed** (their blocks sat on top of this
   one), `$9E/$9F` = blk, cnt, `$731E/$731F` = dst, then `readBlocks`.

**$E63C (`readBlocks`).** `$0E8A/$0E8B` = the destination and `$0E8C/$0E8D` = `$9E/$9F` (for the
disk-error prompt, which writes an END there when the user gives up), `$731C` = block. `$D015`
saved and 0 (sprites off: their DMA would break the serial timing), `$08DA` = `$7327` = 1,
interrupts masked, `$D018` = $F0, `$D016` = $D8 (the raster split stops until the next IRQ).
Then the loader's open ($7306); per block the border counter `$0E88` counts up and goes to `$D020`
(the border flashes), the loader's read ($7309) runs and the count `$9F` goes down; then the
loader's close ($730F), interrupts unmasked, `$08DA` = `$7327` = 0, `$D015` restored. After each
loader call the status check $732B runs (→ $5FAB: on an error the prompt and a retry from
$E6A6).

**The port** copies from `Machine.diskBlocks` (no disk errors, so no retry or prompt) and leaves
the memory SubLogic's loader leaves (`Scenery.Loader`, confirmed byte for byte against the loader
running on the lab's virtual 1541):

| Bytes | After a read of n ≥ 1 blocks |
|---|---|
| destination | the blocks, except bytes at $C000 and above |
| `$731C` | block + n |
| `$731E/$731F`, `$C2/$C3` | destination + 1024·n, or $C000 when the guard stopped it (unchanged when it started at $C000 or above) |
| `$37`, `$39`, `$3A`, `$BE`, `$BF`, `$C0/$C1` | the walk over the sector mask $7473 for the last sector (4·(block + n − 1) + 3): the mask byte shifted to the current bit, 7 − (sector & 7), the next mask byte index, sector and track in BCD, $FFFF |
| `$38` | 0 |
| `$7335`, `$733B-$733F` | '1', the track and sector digits of the last sector |
| `$A5/$A6` | $34/$73 (the "U1" command) |
| `$7322`, `$7323`, `$7324`, `$7325` | 8 + `$731B`, $0F, $0C, 0 |
| `$7579-$7585` | "00, OK,00,00" + CR |
| `$B8`, `$B9`, `$BB`, `$BD` | $40, $FF, 0, CR |
| `$BA`, `$BC` | per data transfer to the drive (two in the open, one per sector) `$BA` = $40 \| `$BA` >> 2 and `$BC` likewise; the open and the close first flush a byte still buffered (`$BA` bit 7: `$BA` >>= 1, `$BC` = $40 \| `$BC` >> 2). Both settle at $55. Both bytes are other routines' scratch too (`$BA` the $19E2 table pointer, `$BC` the windmill RPM), so a load can start, and the editor's close ($E6D2 after its library load prints the fields) can run, with any value |
| `$9F` | 0 |
| `$0E88` | + n |

**Timing** (measured in the lab, where the loader runs against the virtual 1541): the open
58,650 cycles, per sector 382,690 (less 15 per byte the guard skips, plus 4 per page wrap), the
walk over the sector mask exactly as the original ($74DC/$7542, a few thousand cycles growing with
the block number), the close 37,260 (31,100 when it flushes a buffered byte), plus the glue's own
instructions. A set `$BC` bit 7 sends the first command bytes with the EOI handshake, up to about
2,300 cycles more (not modeled: within the pacing tolerance): about 1.55 M cycles per
block, 1.65 M for a one-block load, 9.4 M for a six-block area. The port charges the open, each
sector and the close as separate steps so timed events keep running during a long load. The
original holds the raster IRQ off for the whole load (masked from $E668 to $E698; `$08DA` = 1
marks it too): the port's `readBlocks` calls `sei()` and `cli()` there, so the scheduler only
latches the raster events in between and takes one IRQ where the load unmasks (`main-loop.md`,
Normal mode). The lab's figures include the badline DMA during the load; the drawing elsewhere is
charged by instruction cycles only.

## Overlays ($E5C0-$E6D7) and the editor cache ($E6D8-$E712)

| Entry | Vector | Overlay (pair at $E559 + 2k) |
|---|---|---|
| $E5C0 | $2015 | cold start, blocks 2-4 |
| $E5C9 | $2018 | editor, blocks 42-47 (from the cache when `$08BC` = 1) |
| $E5DB | $201B | war, blocks 158-160 |
| $E5E4 | $201E | flight, block 65 |
| $E5ED | $2021 | database info, block 64 |

**$E5F6 (`loadOverlay`):** `$9E/$9F` = the pair, `$731E/$731F` = $A7E0, then `readBlocks`; after
the editor's pair (first block = [$E55B]) the copy to the cache ($E6D8) unless `$08BC` = 2; falls
into **$E618 (`loadRootBlock`)**: `$0900-$0903` = 0, `$9E/$9F` = the pair at $E563 (block 66, 1),
`$731E/$731F` = [$A7E0], falls into $E63C. The root lands at $A800 (flight), $B1EA (war), $A878
(database), $AD00 (cold start), $BC6B (editor; truncated at $C000).

**The editor cache:** $E6D8 (carry clear) copies and $E6DB (carry set) exchanges $A7E0-$BCDF
($15 pages) with $D000-$E4FF, with interrupts masked and `$01` = $30 during the copy, then
`$01` = `$4B` and interrupts unmasked; `$A5/$A6` and `$A7/$A8` end at $BCE0 and $E500. `$08BC`:
0 never loaded, 1 cached, 2 invalid (the course plotter recorded lists at $D000). The first editor
entry loads from disk and copies; the main loop then sets 1 ($205B). Later entries swap the editor
in ($E5C9 goes straight to $E6DB, no root reload) and the main loop swaps it back out ($2063).
**$E6D2** (vector $2039, after the editor's own block writes) closes the channels through the
loader's close $730F.

## Coordinates

**Eye.** X east `$5A-$5D`, Y up `$5E-$61` (in radar mode `$0888-$088B`), Z north `$62-$65`; all
32-bit with a fractional low word. One high-word unit is about 256 m (the Meigs–O'Hare and
Seattle–LA distances fit; geographic checks give 246-265 m). World Y = 0 is the scenery ground
plane. After an origin op, `$66/$68/$6A` hold the eye relative to the object in the op's units,
and points are transformed relative to them (`render3d.md`: $A1CE for 3D points, the block
floating point $9FD0 for ground points, whose per-point exponent makes the ground jitter; only
op 2B reconciles exponents).

## The 3D pipeline in brief

The routines belong to the renderer (`render3d.md` has the exact behavior); what the bytecode
relies on:

- **View matrix ($8111):** inputs pitch `$6C/$6D` (positive = nose down), bank `$6E/$6F`, heading
  `$70/$71` (clockwise from north), the view `$0ACA` (0-$0E: 8 directions at 45°, bit 7: down) and
  radar `$0836`. The words at `$78-$89` are `[$78 + 6j + 2i]`, the coefficient of world axis j (X,
  Y, Z) for eye axis i:
  - eye_x = (cy·cr + sp·sy·sr)·dX + (sr·cp)·dY + (cy·sr·sp − sy·cr)·dZ
  - eye_y = (sp·sy·cr − cy·sr)·dX + (cp·cr)·dY + (sy·sr + sp·cy·cr)·dZ
  - eye_z = (sy·cp)·dX + (−sp)·dY + (cy·cp)·dZ

  The x terms are halved and the z terms quartered ($8306), so the frustum |x| ≤ z, |y| ≤ z is
  53.13° × 28.07°. The yaw low byte `$76` is never refreshed by the views (1.4° heading steps).
- **Outcodes** ($93D2 for A, $941B for B): $80 z < 0, $40 x < −z, $20 x > z, $10 y < −z, $08 y > z.
  The apex is at the eye, so there is no near plane.
- **Projection** ($9D05/$9D21): q = floor(128·|n| / z) (7 bits); sx = $50 + TX[q] (x ≥ 0) or $4F
  − TX[q], sy = $37 − TY[q] (y ≥ 0) or $38 + TY[q], TX[i] = floor(5i/8), TY[i] = floor(7i/16):
  a 160 × 112 window centered on (80, 55).
- **Ground base:** origin ops recompute `$24/$27/$2A` = −y × the matrix's Y column ($8324) when y
  changes.

## Development bridge

None: no `callOriginal` call is left. Two defensive checks stand where fallbacks once called the
original, and neither is reachable with the disk's lists: op 0A to a target that has no port
(`SceneryVM.swift`), and an ATIS hook `$802D` patched to anything but `$F16A`
(`SceneryRecords.swift`). Both stop the program with an error naming the address
(`ShippingCodeTests`). Every other call is a direct call of a port:
`pollTick` runs `tick10Hz`, op 1E's hook runs `composeAtis`, and the renderer's `transform3D`,
`transformGround` and `halveClipPoints` call `dlStep` and `halvePoint`.

## Tests

`Tests/DifferentialTests/Scenery*Tests.swift`, against the original in the lab:

| Suite | What |
|---|---|
| `SceneryVMTests` | Every opcode on crafted lists (`DiffRig`, whole memory and cycles): control flow (18, 09 with a pointer and 0, 0A to $80D1/$A731/$8749 and 0, 0B, 11, 19, END); op 0A into every renderer vector and its target; boxes 13/14 (edges, wrap, radar altitude); 20-22 (signed bounds, edge words, a variable across a page); 23; 28 (types 0-3 and others); 1A/25 (stores into their own pointers), 0D cached, pens 12/1B/1C by day and night; 07/24 (every scale, overflowing differences, radar, y = 0, the base cache); random scenes of points, lines, polygons (past 60 vertices), the cache and its cull, screen and dashed lines (at a page end) and runways from random attitudes, heights and views on both window buffers; records 1D/1E/05 with the searches on and off; the poll with the tick due; every unused opcode faulting |
| `SceneryPassTests` | The main loop's rendering order ($E565, $8000, flip, $8003, $8006) at Meigs and in every area (downtown Chicago by day and at night, O'Hare, Midway, Champaign, LA, LA south, Seattle north and south, New York, New England, the WWI area) from lab snapshots taken after the blocks streamed in, 21-30 passes each with random attitudes, views, positions (within about 500 m), heights, night pens and the radar view; golden frames presented with the game's split must be identical |
| `SceneryStreamingTests` | `loadBlockCached` for every area and detail group, the guard, high slots, various serial flags, and a cached request; the loader's parts against $7306/$7309/$730F/$E6D2; the open and the close from random serial flags `$BA`/`$BC`; every overlay, and the editor's first entry with its copy to the cache; whole passes that stream an area and a detail; the sector-mask walk for all 164 blocks (exact); the editor cache copy, swap and trampoline; `setSceneryRoot`. The loads run on the full lab machine with the virtual 1541 and are compared byte for byte, the time within 1% (the open within 3%: it varies with the raster phase) |

With `SCN_COVERAGE` set, the rigs record the original's instructions in the scenery ranges
(`build/testdata/scn-coverage.txt`: never executed; `scn-branches.txt`: branch outcomes never
seen). The flat-harness suites execute everything except the invalid-opcode path (tested on the
port: the original would enter the fatal error), the dead advance by 2 at $885B, and the loads
(tested on the full machine); the branch outcomes not taken are the constant ones (the
always-taken branch after a constant zero at $8E2A, and the overflow tests at $8F29, $8F3C, $8FB0
and $8FC7 that an earlier overflow test already decided).
