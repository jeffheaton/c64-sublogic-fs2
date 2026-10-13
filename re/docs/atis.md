# ATIS and the busy delay

The port of the ATIS broadcast: the token offset table $F07A, the phrase strings $F087-$F169, the
value composer $F16A, the teletype $E713 / $F239-$F2E5 and the busy delay $F25B. Swift:
`Sources/FS2Core/Radio/Atis.swift` (the `Atis` namespace) and
`Sources/FS2Core/Machine/BusyDelay.swift`. Differential tests:
`Tests/DifferentialTests/AtisTests.swift`.

Related pages: `radios.md` (the COM readout `$3903` that raises the search and the one-shot),
`scenery-3d.md` (display-list op 1E, the record that triggers a broadcast), `raster.md` (the 3x5
font, `drawTextRecord` $1DDE, `clearWindow` $1EAF, `format3Digits` $3804), `math.md` (`mulU16`
$188A), `flight-model.md` (the main loop that calls $E713, and the crash message, the other
user of $F25B).

Every routine is a literal translation with the original's exact cycles (its own instructions
through its return; the call itself belongs to the caller), reading and writing every byte the
original does, the self-modified phrase bytes and the zero-page scratch included. Nothing
touches I/O.

| Routine | Swift | Cycles |
|---|---|---|
| `atisTeletypeJump` $E713 | `atisTeletypeJump()` | 3 + `atisTeletype` |
| `composeAtis` $F16A | `composeAtis()` | 2,750-3,500 (exact per branch) |
| `atisFormatByte` $F221 / `atisFormatWord` $F223 | private `atisFormat` | 36 / 34 + `format3Digits` |
| `atisTeletype` $F239 | `atisTeletype()` | 13 when done; else see below |
| `busyDelay` $F25B | `busyDelay(y:)` | Y × 456,711 + 5 (Y = 0: 256 passes) |
| `atisTypeText` $F26B (entry $F275) | private `atisTypeText` | see below |
| `atisNextCell` $F2C5 | private `atisNextCell` | 24; 34 for a new line; 41 + `clearWindow` for a new page |
| `atisAdvanceColumn` $F2DE | private `atisAdvanceColumn` | 16 |

**Calls outside this subsystem:** `mulU16` $188A (math), `format3Digits` $3804 (readouts),
`drawTextRecord` $1DDE and `clearWindow` $1EAF (raster). **Development bridge:** none; the
flight model's `crashMessage` (`Sim/Ground.swift`, $F98D) calls `busyDelay` directly.

**Callers outside this subsystem (not ported here):** the main loop calls $E713 on every flip pass
($20A3); display-list op 1E ($8084) calls the hook $802D, which the cold start points at $F16A (the
hook's jump costs 3 more cycles, charged by the scenery interpreter); `crashMessage` $F95D calls
`busyDelay` with Y = 5.

## How a broadcast happens

1. Tuning the COM radio (`$3903`, `radios.md`) stores the frequency in `$08B3/$08B4` (BCD, kHz
   byte first), sets the search request `$0937` = 1 and the one-shot `atisOneShot` `$0941` = 1.
2. Each scenery pass copies `$0937` to `$0938` ($8736). The first op 1E record the interpreter
   meets while `$0938` is set clears `$0937`; a record whose frequency matches copies its 8
   parameter bytes to `$0939-$0940`, sets `atisTextPtr` `$0958/$0959` = record + 13, clears
   `$0941` and calls the composer. Records sit behind range tests: at Meigs the Chicago area's
   Meigs (121.30), Midway (128.05) and O'Hare (135.15) records are in range, Kankakee (123.00) is
   not.
3. On the next flip pass $E713 runs the teletype, which sets `$0941` and types the text once.
4. 🆕 A third quick CTRL-C (`keyComSelect`, `input.md`) increments `$0937` without retuning: the
   next scenery pass matches the record again, recomposes and clears `$0941`, and the broadcast
   is typed again (lab: the `atis` prefix, then CTRL-C ×3 → `$0937` = 1, `$F16A` hit, `$0941` = 0,
   typing). This settled the question about `$0937` (`open-questions.md`, Input and radios).

### The record (op 1E)

`1E len 00 freqLo freqHi p0 … p7 text… 00`: `len` is the record length (the interpreter's
advance), the frequency is BCD (`30 21` = 121.30), the text is ASCII $20-$5A plus tokens
$80-$8C. The parameters, as `$0939-$0940`:

| Bytes | Meaning | Meigs | Midway | O'Hare |
|---|---|---|---|---|
| `$0939-$093C` | runway for wind quadrant 0-3 (`$09A3 >> 6`: N-E, E-S, S-W, W-N), a plain number | 36 18 18 36 | 4 13 22 31 | 4 14 22 32 |
| `$093D-$0940` | temperature (°F) for season 1-4, read as `$093C + season` | 18 53 79 56 | 20 51 75 58 | 17 55 80 53 |

The season is the mode record's SEASON `$0985` (1-4). The composer does not mask it: any value
indexes `$093C + season`, with a page-crossing cycle from 196 up.

## composeAtis ($F16A)

Writes six values into the phrase strings, each formatted by `format3Digits` into the three bytes
$F21E-$F220 (zero on disk, inside the code region) through $F221 (A = value, X = 0) or $F223
(A:X), which return Y = hundreds, A = tens, X = units:

| Phrase bytes | Value | Leading zeros |
|---|---|---|
| $F0B6-$F0B7 'TEMPERATURE tt' | `$093C[season] + temperatureOffset $095F` (8-bit, then tens and units only) | kept |
| $F125-$F127 'WIND ddd' | (`$09A2/$09A3` × $0168) >> 16 = direction in degrees (`mulU16`) | hundreds '0' → ' ' |
| $F12C-$F12D 'AT ss' | `$09A0` (tens and units) | tens '0' → ' ' |
| $F09E-$F09F 'hh:00 ZULU' | `clockHours $0983 + zuluOffset $0854` (8-bit), minus 24 once when ≥ 24 | kept |
| $F133, $F145-$F147 'CEILING ccc00' | (`$0856/$0857` × $0866) >> 16 (`mulU16`) | see below |
| $F0E5-$F0E6 'RUNWAY rr' | `$0939[$09A3 >> 6]` (tens and units) | kept |

- **Ceiling.** `$0856/$0857` is the base of cloud layer 1 in meters (the editor's exit stores CLOUD
  1 BOTTOMS × $4E >> 8, feet to meters). × 2150 >> 16 gives hundreds of feet; the phrase appends
  '00'. The multiplier is the immediate $0866 (two immediate operands at $F1CC/$F1D0), not the byte
  at $0866, which no code reads (an early reading took that byte for the multiplier). $F133, the
  second byte of the ceiling phrase, is first set to 0; when the product's bits 16-31 are zero it
  stays 0 and the phrase is cut to its first byte ' ', so token $8B types three space cells (its
  leading cell, the phrase's ' ' and its closing cell). Otherwise $F133 = ' ' and the digits go to
  $F145-$F147 with a leading '0' as ' ', and the tens '0' as ' ' too when the hundreds were blank.
- **Zulu offset.** `$0854` is written by the scenery: a poke is overwritten (5 in the Chicago
  area). Only the hour is live; the minutes are always ':00'.
- **Wind speed** of 100 and up loses its hundreds (100 types as ' 0').
- The 8-bit temperature wraps: 20 - 16 types '04', 51 + 100 types '51'.
- Cycles: 20 + $F221 + 32 + 699 (`mulU16` with the multiplicand $0168) + 11 + $F223 + 27/28 + $F221
  + 31/32 + 3/6 + $F221 + 32 + 715 (`mulU16`, $0866) + 19 (no ceiling: the branch to $F207 crosses
  into page $F2, 4 cycles) or 14/17 + 12 + $F223 + 17/23/24, then 28 + $F221 + 14. The pairs are the
  leading-zero and Zulu-wrap branches. `format3Digits` is 143 + 28 per subtraction (its digits sum,
  for values below 1000). Measured: 2,778 at the Meigs match.
- Side effects: `$A5-$A7`, `$B8/$B9` (the last remainder), `$BA/$BB` = $F21E, `$C4-$CB` (the second
  multiply leaves `$C4/$C5` = 0).

## atisTeletype ($F239, through $E713)

- `$0941` ≠ 0: return (13 cycles; the main loop calls it every flip pass).
- Otherwise `$0941` + 1, `$BD` = 0 (the terminator of the cell record), `$BA` (row) = `$BB` (x) =
  3, `clearWindow`, the cursor `$B8/$B9` = `atisTextPtr`, `atisTypeText` ($F26B), then Y = 4 and
  the fall-through into `busyDelay` (1,826,849 cycles, about 1.8 s).
- **Typing ($F26B).** Fetch a byte at the cursor and advance it. 0: return ($F278). A
  character other than ' ': `$BC` = character and `drawTextRecord($00BA)` (the one-character
  record row, x, char, 0), then the delay, then x += 4 ($F2DE). ' ': only the next cell ($F2C5).
  A token ($80-$FF): push the cursor, point it at $F087 + [$EFFA + token] (the high byte $F0 plus
  the carry), call the $F275 entry with A = ' ' (a space cell, then the phrase up to its 0), then
  one more space cell ($F2C5), and restore the cursor. Tokens above $8C read past the offset table
  into the phrases; the disk's records use $80-$8C only.
- **Cells ($F2C5).** x < $64: x += 4. Otherwise a new line, x = 3 and row += 8 (an add of 7
  plus the carry the compare leaves), or a new page when that row would be ≥ $5A: `clearWindow` and
  row 3. Characters advance with $F2DE alone, so lines break only at a space or a token's cell
  once x ≥ $64 (100): a word is never split, and one that starts near x 100 runs on to its end.
  A page holds 11 lines (rows 3-83). Correction to `scenery-3d.md`, which had x and y swapped and
  the limits exchanged.
- **The per-character delay.** X = 0 − `commRate` `$096A` (the editor's COMMUNICATION RATE), 0
  meaning 256: X passes of a 120-step countdown, 606 cycles each (the last pass 605). The regular
  mode's rate $C8 gives 56 passes, 33,936 cycles (about 2 frames) per character; rate 0 is the
  slowest (256 passes), $FF the fastest (1 pass).
- **Faithful edge paths.** The branch back to $F26B at $F29D tests the restored cursor's high
  byte, so a text in zero page falls into the character path with A = 0 after a token: an empty
  cell is drawn (nothing visible) with a full delay. The branch after each cell advance falls
  through when x wraps to 0, which cannot happen from x = 3. The port keeps both paths.
- **Cycles.** 29 + `clearWindow` + 20 + the typing + 2 + 1,826,849. Per visible character 77 +
  `drawTextRecord` (one glyph) + 606 × passes (+4 when the cursor's low byte wraps); per space 64;
  +10 for a new line, +17 + `clearWindow` for a new page; a token 61 + 49 (the leading space
  cell) + its phrase's characters + 25 (the phrase's 0) + 47 (the closing cell and the restore);
  the text's final 0 25.
- **Timing in the port.** The original busy-waits while the raster IRQ keeps the jiffy clock,
  the keyboard scan and the sound running (the 10 Hz tick is not polled, so keys queue until the
  broadcast ends). The port charges the delay one pass (606 cycles) at a time, and the final
  delay one X pass (1,791 cycles) at a time, so the scheduler's events run inside the wait at
  their times (the test `teletypeChargesInSteps`). The Meigs broadcast at rate $C8 takes about 490
  frames (8.3 million cycles).
- Side effects: `$0941` = 1, the window bitmap, `$B8/$B9` past the text's 0, `$BA-$BD` the last
  cell, `$C0-$C3` and the glyph scratch (`$38`, `$8E/$8F`, `$A5-$AE`) as `drawTextRecord` leaves
  them. Clobbers A, X, Y (all 0 at the end, carry set).

## busyDelay ($F25B)

Three nested countdowns: Y outer passes (Y = 0: 256), each of 255 X passes, each of which counts A
down from $FF one subtraction at a time. One X pass is 1,791 cycles (the last 1,790), one Y pass
456,711 (the last 456,710), so Y passes cost Y × 456,711 + 5 with the return: Y = 4 (the ATIS end)
1,826,849, Y = 5 (the crash message) 2,283,560. No memory is touched; A = X = Y = 0 and the carry is
set at the end. The port charges it one X pass at a time.

## Tests (`AtisTests.swift`)

The fixture session (prefix as `re/sessions/atis.txt`) tunes four broadcasts and stops at the
composer's entry, the teletype's entry and the return to the main loop ($20A6) of each:

| Stage | Station | How | Season, hour, temperature offset, wind, cloud base, rate |
|---|---|---|---|
| meigs | Meigs 121.30 | the CTRL-C and ',' '.' keys | 4, 08:00, 0, calm, none, $C8 |
| midway | Midway 128.05 | pokes `$08B3/$08B4`, `$0937`, `$0941` | 1, 22:00, -16, 315° at 27, 183 m (600 ft), $F8 |
| ohare | O'Hare 135.15 | pokes | 3, 03:00, +5, 135° at 5, 8192 m (26,800 ft), $E0 |
| midway2 | Midway | pokes | 2, 23:00 (04 Zulu), +100, 90° at 100, 31 m (100 ft), $C0 |

- the composer at the four matches (memory and cycles, and the phrases it writes), and 3,000
  randomized calls (any season index, offsets, winds, hours, Zulu offsets, cloud bases around the
  ceiling's edges, parameter bytes);
- the whole teletype run of each broadcast and through $E713 (memory and cycles on the flat bus,
  up to 8.3 million cycles each), and the port's window and cursor against the lab's state after
  the real run (with IRQs);
- the one-shot (13 cycles), 14 synthetic broadcasts (tokens, spaces, texts that cross pages and
  fill several window pages, rates 0 and $F0-$FF, the zero-page text path, the cut ceiling
  phrase) with a check that the original took the token, new-page and empty-cell paths, and 6
  texts of any byte values (tokens $8D-$FF, whose offsets are phrase bytes; control bytes
  $01-$1F, which end their one-character record at once; codes past 'Z') at the fastest rates;
- `busyDelay` with Y = 1, 2, 3, 5 against the original, Y = 0 by formula, and the stepped charging
  of both the delay and the teletype against a frame event schedule.
