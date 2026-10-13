# Radios, nav instruments and the ADF

The port of the radio stack readouts ($3896-$3922, $3A5C), the nav instruments $3B32-$3F89 (with
the arctangent table $3AF1 and the localizer needle shape $3B13) and the ADF $E7F2-$EA5B. Swift:
`Sources/FS2Core/Radio/RadioDisplays.swift`, `Sources/FS2Core/Radio/Adf.swift`,
`Sources/FS2Core/Panel/NavInstruments.swift`, `Sources/FS2Core/Panel/NavMath.swift`. Differential
tests: `Tests/DifferentialTests/NavTests.swift` (and the radio displays and ADF tuning in
`ReadoutTests.swift`).

Related pages: `panel.md` (the panel bitmap, the needle drawer $1A86 and point lists $1BC3 the
nav instruments draw with, the readouts and the radio gate $3A53), `scenery-3d.md` (the display
list ops 1D/05/1E that find the stations), `input.md` (the tuning keys), `sound.md` (the marker
tones 5/6/7).

Every routine is a literal translation with the original's exact cycles (its own instructions
through its return; the call itself belongs to the caller), reading and writing every byte the
original does, zero-page scratch included. Nothing touches I/O.

| File | Routines |
|---|---|
| `RadioDisplays.swift` | `parseFrequencyDigits` $3896, `drawNav1Frequency` $38BD, `renewNav1Search` $38D4, `drawNav2Frequency` $38D9, `renewNav2Search` $38F5 (with $38F7), `drawComFrequency` $3903, `drawTransponder` $3A5C; the `Radio` namespace |
| `NavInstruments.swift` | `updateNav1Cdi` $3B32, `updateNav2Cdi` $3B9B, `updateGlideslopeAndDme` $3DA2, `drawObi1` $3BAF, `drawObi2` $3C1A, `stepNav2Needle` $3C3F, `drawGlideslope` $3C5D (with $3C7A), `drawToFrom` $3C81, `drawLocalizer2` $3D68, `drawLocalizer` $3D71 (with $3D73), `markerBeacons` $3EFC |
| `NavMath.swift` | `stationBearing` $3C8F (with $3D18/$3D21), `vectorAngle` $3E46 (with $3E55, $3E6B, `arctanRatio` $3E9F, $3EEE), `stationDistance` $3F38, `courseDeviation` $3B61, `classifyToFrom` $3D2B, `deviationNeedle` $3D84; the `Nav` namespace |
| `Adf.swift` | `updateAdf` $E7FE, `drawAdfBearing` $E860, `drawAdfPanel` $E936, `ndbHook` $E956, `selectAdfDigit` $E9A7, `tuneDecrementPre` $E9BF, `tuneIncrementPre` $E9F6, `setAdfDigit` $EA2B (private), `renewAdfSearch` $EA50; the `Adf` namespace |

**Calls outside this subsystem:** `mulQ15AX` $17EF, `divQ15` $1802, `mulU16` $188A, `mul8Half`
$1961, `negate16` $19D5 (math), the text routines $1DDE/$1E99/$3804, `drawNeedle` $1A86,
`plotMarkerShape` $1BC3 and `drawMixtureIndicator` $1C23 (panel), and `storeSelected` $2BBC (input:
`$FC` = A, `$091C` = 3), the tail of `selectAdfDigit`. **Development bridge:** none. The scenery
interpreter's continuation after the NDB hook is not called: `ndbHook` returns the advance length
instead (below).

## The radio stack and the station lookups

| Radio | Digits (ASCII, in the record) | Frequency (BCD, low byte first) | Search request | Found |
|---|---|---|---|---|
| COM | $21B0-$21B3 ('1' painted) | `$08B3/$08B4` (op 1E) | `$0937` | the ATIS (`$0941` = one-shot) |
| NAV1 | $21B7-$21BA | `navFrequencyB` `$0925/$0926` | `$0920` | `$0922` bit 0, station B `$092F` |
| NAV2 | $21BE-$21C1 | `navFrequencyA` `$0923/$0924` | `$0920` | `$0922` bit 1, station A `$0927` |
| ADF | $E7FA-$E7FC | `$E7F4` = d1·16 + (d2 & 15), `$E7F5` = d0 & 15 | `$08BD` | `$E7F3` = 1, station A `$0927` |
| XPDR | $21DD-$21E0 (octal) | — | — | — |

- The tuning keys (`input.md`: CTRL-C/N/V/X/T, A, ',' '.') edit the ASCII digits and call the
  display routine, which redraws the record and turns the digits into BCD with $3896 (X = d0·16 +
  (d1 & 15), A = d2·16 + (d3 & 15)), then raises the search request.
- The scenery interpreter copies the requests to its per-pass flags (`$0921`, `$0938`, `$08BE`)
  at $8730; the first station record in range whose frequency matches copies its position and
  clears the request. Op 1D (NAV/LOC) matches `$0925` first (→ station B, bit 0) and then `$0923`
  (→ station A, bit 1); op 05 (NDB) goes through `ndbHook` (→ station A). So the NAV2 station and
  the NDB share record A.
- **Renewal.** Once per 8 passes (`$22 & 7` = 4) the main loop calls $38D4, $38F5 and $EA50: each
  clears its found bit (or `$E7F3`) and raises the request. A station stays found only while one
  of its records is in range, so a station is lost about 8 passes after leaving its range box.
- Station records (8 bytes): X32 (east) at +0..+3 and Z32 (north) at +4..+7 in the 1/256 m
  position units. Only bytes 1-3 are used for the geometry; byte +4 of station B is the
  **localizer flag**: localizer records carry fractional coordinates (`$0933` != 0), VORs do not.
  The NDB hook stores 0 into +0 and +4.

### Display routines

- **drawNav1Frequency ($38BD) / drawNav2Frequency ($38D9).** Gated ($3A53). NAV2 does nothing
  while the ADF is enabled (`$09AA`). Draw the record, store the BCD, then fall into the renewal
  ($38D4: `$0922` &= $FE; $38F5: &= $FD; both through $38F7: `$0920` = 1). Cycles: 27 with the
  gate closed; NAV1 30 + $1DDE + 10 + $3896 + 8 + 25; NAV2 34 with the ADF on, else 36 + $1DDE +
  10 + $3896 + 8 + 22. $3896 is 74 cycles + 1 per digit read across a page.
- **drawComFrequency ($3903).** Gated. Draw, store the BCD into `$08B3/$08B4`, `$0941` = 1 and
  `$0937` = 1. 27 closed; else 30 + $1DDE + 10 + $3896 + 24.
- **drawTransponder ($3A5C).** Gated. Redraws $21DB. 27 closed; else 30 + $1DDE + 6.

## Station geometry

### stationBearing ($3C8F, X = 0 station A, 8 station B)

1. dN = north bytes 1-3 (`$63-$65`) - station +5..+7 (24-bit), shifted left by 4 ($3D18: $3D21
   called three times, then once more by falling into it; 126 cycles). `stationDeltaNorth`
   `$09BA/$09BB` = its upper 16 bits: the north distance in **16 m units**, signed. Also kept in
   `$BC/$BD` with the low byte in `$B9`. dE likewise from `$5B-$5D` and +1..+3 → `$09BC/$09BD`,
   `$BA/$BB`, `$BF`. `$C0` and `$C2` are scratch.
2. Normalization ($3CDB): while both high bytes (`$BD`, `$BB`) are within -16..16 (`+$10 < $21`),
   both 24-bit values shift left; north shifts in a **1**, east a 0. This
   keeps the precision of the divide below for short distances. It always ends: the 1s make north
   grow.
3. angle = `vectorAngle` of (east `$BA/$BB`, north `$BC/$BD`); `$B8/$B9` = angle - `$0848` -
   `$0846` (the area heading offsets, so the bearing is in the same frame as the OBS and heading).
4. Returns the carry of the last subtraction, which `updateAdf` uses (its subtraction of `$70`
   does not set the carry first).

The bearing is the direction **from the station to the aircraft** (the radial), clockwise from
north. Cycles: 366 + 57 per normalization shift + 12 (or 23 when the north test passes and the
east one stops it) + 6 + $3E46 + 42 (+1 per station byte read across a page; none for X = 0/8).

### vectorAngle ($3E46-$3EFB)

The angle of (east `$BA/$BB`, north `$BC/$BD`) as a binary angle clockwise from north ($10000 =
360°). The words are changed in place.

- $3E46: east negative → negate it ($3EEE), recurse into $3E55, negate the result (a tail jump to
  `negate16` $19D5).
- $3E55: north negative → negate, recurse into $3E6B, negate, and + $8000 (bit 7 of the
  high byte flipped).
- $3E6B (first quadrant): east < north (unsigned 16-bit) → atan(east / north) by $3E9F.
  Otherwise the words are swapped and the angle is $4000 - atan(north / east) (`negate16`, +$40
  on the high byte); on **equal** components east is first incremented (so 45° comes out as just
  under 45°).
- $3E9F (`arctanRatio`): q = `divQ15`(numerator `$BA/$BB`, denominator `$BC/$BD`) in Q15. The
  table index is bits 11-14 of q (`$C5 >> 2 & $FE`, a word offset into the 17 words at $3AF1:
  atan(i/16) as binary angles, 0..$2000). The interpolation fraction is built in `$C4/$C5` as
  `$C4` = q low >> 3 and `$C5` = ((q high << 4) & $60) + that: it keeps bits 3-7 and 9-10 of q
  and **drops bit 8** (an original quirk; the error is up to half a table step). result =
  ~(fraction × (t[i] - t[i+1]) through `mulQ15AX` - t[i]), i.e. t[i] - fraction × step - 1.
  `$C0/$C1` = t[i].

Cycles: $3E46 6 + the rest when east >= 0, else 50 + $3E55 + $19D5; $3E55 6 + the rest when north
>= 0, else 47 + $3E6B + 6 + $19D5 + 16; $3E6B 12 (east high < north high), 14 (greater), 19 / 21
(equal high bytes, lower / greater low byte), 28 or 32 (equal: increment, with the carry into the
high byte), then $3E9F directly (east lower), or 30 + $3E9F + 6 + $19D5 + 18 after the swap;
$3E9F 24 + $1802 + 83 (+1 per table read across a page: byte offsets 12 and up) + $17EF + 26.
$3EEE: 28.

### stationDistance ($3F38, vector $2030)

With L and S the larger and smaller of |`$09BA/$09BB`| and |`$09BC/$09BD`| (unsigned compare;
-32768 stays $8000), `$C0/$C1` = L + S × (S / 2L): `divQ15`(S, 2L) then `mulQ15AX`(S). `$C2/$C3`
= L, `$C6/$C7` and the math scratch as those leave them. A good approximation of the Euclidean
length for the 16 m units. The war overlay uses it as a 3D distance through the vector. Cycles: 8
+ (3, or 8 + $19D5 when negative) + 14 + (3, or 8 + $19D5) + the compare (6 east smaller-high, 8
greater-high, 12 / 13 equal-high with a lower / not lower low byte) + 16 when the words are
swapped + 30 + $1802 + 12 + $17EF + 22.

## The course deviation indicators

### courseDeviation ($3B61; A = mask, X = station, Y = course)

- No station (`$0922 & A` = 0): `$B8/$B9` = 0, A = 0 (OFF). 18 cycles.
- Otherwise `$3A` = course, `stationBearing`, course16 = course × 364 (`mulU16`; OBS units of 2°
  to a binary angle: 180 units → $FFF0), d = (course16 - bearing) × 540 >> 15 (`mulQ15AX`): **3
  units per degree**, signed, stored in `$B8/$B9`, then `classifyToFrom`. Cycles: 16 + $3C8F + 21
  + $188A + 33 + $17EF + 9 + $3D2B.

### classifyToFrom ($3D2B; A/X = d, also in `$B8/$B9`)

- |d| < 256 (85°): FR (A = 2), `$B8/$B9` kept: the aircraft is on the course's side of the
  station (the bearing is the radial, station → aircraft). 19 (d >= 0) / 22 cycles.
- 256 <= |d| < 300 (100°): OFF (A = 0), `$B8/$B9` = 0: abeam. 31 / 34.
- Otherwise TO (A = 1) with `$B8/$B9` = 540 - d (d > 0) or -540 - d (d < 0): the deviation seen
  from the reciprocal. 44 (d >= 512), 50 (300 <= d < 512), 40 (d < -512), 46.

### deviationNeedle ($3D84)

Clamps `$B8/$B9` to -30..30 (low bytes $E2..$1E), then A = (v + 30) >> 1 (8-bit): 0..30, 15 =
centered, ±10° full scale (the localizer uses the same scale). 27-31 cycles.

### updateNav1Cdi ($3B32) and updateNav2Cdi ($3B9B), odd passes

- NAV1: course = OBS1 (`$2196`), or for a localizer (`$0933` != 0) the low byte of the product
  (`localizerCourse` `$0852/$0853`, the full word, × $1555 >> 15): the scenery stores the runway
  course there in 1/3 degrees, and × 1/6 gives OBS units (the Champaign localizer comes out as
  312°). `courseDeviation`(1, X = 8) → `nav1ToFrom` `$09B5`;
  `deviationNeedle` → `nav1NeedleTarget` `$09B0`; then on to $3DA2. Cycles: 21 (VOR) or 39 +
  $17EF + 14 (localizer) + $3B61 + 10 + $3D84 + 7 + $3DA2.
- NAV2: OBS2 (`$2199`), station A, mask 2 → `$09B6`, `$09B2`. 14 + $3B61 + 10 + $3D84 + 10.

## Glideslope and DME ($3DA2)

**Glideslope**, only when the scenery stored a reference into `glideslopeReference`
`$0850/$0851` this pass (op 25 inside the ILS area; the low byte is tested):

1. `$9E/$9F` = reference / 2; distance `$C0/$C1` = `stationDistance` of the vector $3C8F left in
   `$09BA-$09BD` (NAV1's, when found this pass).
2. h = `$0A8A/$0A8B` / 2 (the altitude $CE84 copied, in meters).
3. h >= distance (unsigned): target 18 (full deflection). Otherwise r = `divQ15`(h, distance) in
   Q15, which is 8 × the tangent of the elevation angle (h is half the meters, the distance is in
   16 m units); v = high byte of (r - `$9E/$9F`) + 18 (8-bit): v < 36 → v / 2, else (bit 7 clear)
   → 18, else (wrapped negative) → 0. About 9 target units per degree: ±1° full scale.
4. `glideslopeTarget` `$09B4` = 0..18 (9 = on the glideslope, higher = the aircraft is above, so
   the bar moves down). `$98` is scratch.

At Champaign the reference corresponds to about a 3.4° glideslope. In all cases
`$0850/$0851` = 0 afterward (consumed).

**DME** (NAV1): without a station (`$0922` bit 0 clear) `dmeNoStation` `$09AB` = 1 and the redraw
flag `$09AC` = 1. Otherwise `$09AB` = 0, distance (again $3F38) × 283 (`mulU16`; 283/32768 per
16 m ≈ 1/1852 m): `dmeMiles` `$09AE` = bits 15-22 of the product, `dmeTenths` `$09AD` = high byte
of `mul8Half`(20, bits 8-14) = tenths 0-9; `$09AC` = 1 when the tenths changed. `drawDme` ($3A13,
`panel.md`) prints it on phase 0.

Cycles: 7 without a reference; else 32 + $3F38 + 17 + the compare (3 lower, 5 higher, 9 / 10
equal high bytes with a not-lower / lower low byte) + (5 above, or 26 + $1802 + 22 + 5 / 9 / 12 +
6) + 4; then 16 + (23 without a station, or 15 + $3F38 + 22 + $188A + 26 + $1961 + 24 changed /
19 unchanged).

## Drawing the OBIs

| Item | Drawn by | Position | Range | State drawn / target |
|---|---|---|---|---|
| NAV1 localizer needle | $3D71 → $3D73 → $1BC3, shape $3B13 (2×7 bar) | x 180 + v, row 126 | 0-30 | `$09AF` / `$09B0` |
| NAV2 needle | $3D68 (nothing while the ADF is on) | x 180 + v, row 171 | 0-30 | `$09B1` / `$09B2` |
| Glideslope bar | $3C5D: XOR $FF into the bytes at $B8, $C0, $C8 of the row | x 184-207, row 126 + v | 0-18 | `$09B3` / `$09B4` |
| TO/FROM | $3C81: record $2210 + 8 × A (opaque text) | (141, 94) NAV1, (184, 94) NAV2 | 0-2 (NAV2 + 3) | `$09B7` / `$09B5`, `$09B8` / `$09B6` |

A negative position means "not drawn" (the cold values $FF): `$3C5D` and `$3D73` do nothing.

- **drawObi1 ($3BAF, draw sequence, `$FD` b5).** When `$09B5` differs from `$09B7` (stored anyway):
  erase the needle and the bar, draw the TO/FROM record, redraw the bar and the needle (the text
  cells are opaque and would cut the XOR shapes). Then the needle, and then the bar, take one step
  toward the target: nothing when the drawn position equals it; otherwise the compare's flags are
  kept on the stack across the erase, and the sign of drawn - target (8-bit) decides: down by 1 when
  it is not negative, else up by 1; store, draw. Then `markerBeacons`. Cycles: 15 disabled (its
  branch crosses a page); else 22 (TO/FROM unchanged) or 34 + 2 × $3D71 + 2 × $3C5D + $3C81 + 43,
  then the two steps (11 when settled, else 22 + draw + 25 down / 28 up + draw), then 12 + $3EFC.
- **drawObi2 ($3C1A, `$FF` b3).** A changed `$09B6` (vs `$09B8`) erases the needle, draws record
  `$09B6` + 3, redraws it; then falls into $3C3F. 14 disabled; else 22 or 34 + 2 × $3D68 + $3C81 +
  24, then $3C3F.
- **stepNav2Needle ($3C3F).** The NAV2 step alone (+ the return, 6). It is the first routine of the
  draw sequence and also the tail of $3C1A, so the NAV2 needle can move two steps per pass; it is
  not gated by `$FF`.
- **drawGlideslope ($3C5D)** 11 cycles for "none", else 99 + 1 per row-table or XOR read across
  a page; `$B8/$B9` = the row base. Positions past 73 read rows beyond the 200-row tables (the
  low-byte table read as high bytes), so the bar lands anywhere; for a base of $0000 the first
  XOR hits the pointer `$B8` itself and the next two go through the changed pointer (into the
  stack page). Each page crossing of those XOR reads is decided by the pointer **before** that
  byte's store. **drawToFrom ($3C81)** 18 (19 when A × 8 + $10 carries) + $1DDE. **drawLocalizer
  ($3D71)** 13 / 22 + $1BC3; **drawLocalizer2 ($3D68)** 13 (ADF on), 22 ("none") or 31 + $1BC3.

## Marker beacons ($3EFC, end of $3BAF)

Not in Europe 1917 (`$0969`). The lamp cells $7E7B-$7E7D become $BB (unlit); then the outer
(`$084C`), middle (`$084E`) and inner (`$084A`) flags are shifted right in that order until one
shifts out a 1: that lamp is lit ($EB / $AB / $1B) and the sound state `$0E59` is set to 5 / 6 / 7
(the driver's 400 / 1300 / 3000 Hz patterns). The flags after it are not shifted. The scenery sets
the flags (op 25 stores of 1) while the aircraft is inside each marker's box (`scenery-3d.md`), so
the lamp is lit on the passes where the scenery ran in the box. Cycles: 13 in war mode; else 50
(outer), 55 (middle), 65 (inner) or 51 (none).

## The ADF

Enabled by the editor's ADF ENABLE (`$09AA`); it then replaces the NAV2 OBI: $38D9 (NAV2
frequency), $3976 (OBS2) and $3D68 (NAV2 needle) do nothing, and the face is drawn by $E936.

- **updateAdf ($E7FE, odd passes).** The first call after `$E7F2` was set (shifted out of it) draws
  the face. With `$E7F3` (station found): `stationBearing`(station A), then h = (bearing - view
  heading `$70/$71`, with the carry $3C8F left) + $4000 + `$0849` + `$0847` (the offsets added back
  to the high byte), halved into `$C4/$C5` and `$C0/$C1`; needle = $58 - 1 - (h × 88 >> 15). The
  needle (gauge 4 of `drawNeedle`, angle `$E7F6`) is erased and redrawn when it changed, unless
  `$E7F6` is negative; then $E860. Cycles: 13 disabled; else 15 (+5 + $E936 on the first call), then
  13 without a station, or 14 + $3C8F + 62 + $17EF + 10 + (9 needle hidden, 19 unchanged, or 22 + 2
  × $1A86 + 12 + $E860 + 6).
- **drawAdfBearing ($E860).** (`$C0/$C1` + $2000) & $7FFF (the halved relative bearing turned by
  180° to point at the station) × 360 >> 15 → degrees in `$B8/$B9`, three digits ($3804) into the
  record $E930 (165, 95) inside the face, drawn. 28 + $17EF + 16 + $3804 + 7 + $1DDE. (The lab
  check: an NDB 24 km south-west of Meigs, heading north, reads 232.)
- **drawAdfPanel ($E936).** The record list $E886 (the face over the NAV2 OBI), `$E7F6` = 10 and
  the needle at 10, the records $E930 and $E7F7. 10 + $1E99 + 14 + $1A86 + 10 + $1DDE + 10 +
  $1DDE + 6.
- **ndbHook ($E956).** Display-list op 05 (`[05][freq lo][freq hi][X24][Z24]` at `$8B/$8C`) through
  the hook $802A, which the cold start points at $E956. While `$08BE` is set: `$08BD` = 0; when both
  frequency bytes match `$E7F4/$E7F5`, station A = (0, X24, 0, Z24) and `$E7F3` = 1. It ends by
  advancing 9 through the vector $8018 (to $8749, the interpreter's advance by A). **The port
  returns 9** for the interpreter to continue with; the charged cycles end with the jump to the
  vector (the interpreter charges the vector's own jump). Cycles: 12 inactive, 31 low byte mismatch,
  44 high byte mismatch, 125 match (+1 per record read across a page).
- **selectAdfDigit ($E9A7; A, CTRL-A, left SHIFT).** `$FC` = $0D; within the quick-repeat window
  (`$091C` != 0) and `$FC` in $0D-$0F, the next item ($0E, $0F, then $10 = fuel tank). Then on to
  `storeSelected` $2BBC. 12 / 19 / 23 / 25 (window closed / `$FC` below $0D / from $10 / stepping)
  + $2BBC.
- **tuneDecrementPre ($E9BF, ',') / tuneIncrementPre ($E9F6, '.').** Called first by the ','
  and '.' handlers ($286D/$298E), which continue with the returned A = `$FC`. With the ADF on and
  `$FC` = $0D-$0F: the digit `$E7FA + ($FC - $0D)` - 1 ('0' wraps to '9') / + 1 ('9' wraps to
  '0') through $EA2B. With `$FC` = 3: the mixture `$0A9A` + 1 (',' up to 7) / - 1 ('.' down to 0)
  through `drawMixtureIndicator` $1C23. The '.' version's first branch (ADF off) crosses a page.
- **setAdfDigit ($EA2B).** Stores the digit, redraws $E7F7, rebuilds `$E7F4` = d1·16 + (d2 & 15)
  and `$E7F5` = d0 & 15 (`$B9` scratch), then falls into $EA50. 77 + $1DDE.
- **renewAdfSearch ($EA50, once per 8 passes).** `$E7F3` = 0, `$08BD` = 1, A = `$FC`. 24 cycles.

## Tests

`NavTests` (12 tests) on their own lab snapshots (NAV1 on the VOR 38 km south of Meigs, NAV2 on
the one 28 km north-west, the ADF on a Chicago NDB, and three points of the Champaign ILS: on the
approach with the glideslope reference set, in the outer marker box, in the middle marker box),
the regular and demo snapshots; `ReadoutTests.fixturesReachTheirStates` checks the states (the
outer and middle lamps lit, the localizer and the glideslope reference present, the DME under
1 nm at the middle marker). `DiffRig` compares the whole image (stack page excluded), the
modeled registers (A/X, the carry of $3C8F) and the cycles after every call; the original must
write no I/O. The aircraft is moved around the stations at random (mostly within ±16 km,
sometimes on top of a station or anywhere).

- `vectorAngle` on all pairs of edge values (0, ±1, $00FF/$0100, $7FFF/$8000/$8001, ...), equal
  components (the increment, including $00FF + 1), and 1500 random vectors.
- `stationBearing` for both records on six snapshots, with the carry out.
- `stationDistance` on edge pairs and 800 vectors (equal components, $8000).
- `courseDeviation` / `deviationNeedle` with random found bits and courses;
  `classifyToFrom` / `deviationNeedle` at every boundary (0, ±30, ±256, ±300, ±540 ± 3).
- The CDI tasks with the localizer course and glideslope reference as the Champaign data sets them
  (or random), random altitudes and OBS; $3DA2 directly with random vectors.
- The OBI drawing over 400 random target/TO-FROM sequences per snapshot with the masks and the ADF
  toggling (so every erase/step/redraw path meets the XOR state); every needle and bar position
  0-40 drawn twice (the panel must come back), then every position 0-255 twice; every TO/FROM
  record and the indexes that carry into $23xx (30, 31) or wrap (32).
- The stack page: `DiffRig` skips it, so `ReadoutFixtures.StackWatch` compares $0100-$01DF after
  every call of the drawing tests and $0100-$01BF in the interleaving test (the nav chains push
  down to about $01EA). The bar's positions 74, 75, 106 and 107 XOR into $01B8-$01C8; the erase
  repeats the draw, so only a per-call check sees a port that skips those writes.
- `markerBeacons` over every flag combination (0-3 each) in and out of war mode.
- `updateAdf` with random positions, headings, found flags, needle states and the face pending;
  `drawAdfBearing`, `drawAdfPanel`.
- `ndbHook` on records across page ends, matching or not, search on or off (a return planted at
  $8018 returns from the original; the port side adds its 6 cycles).
- Interleaving: 240 passes in the main loop's order (draw sequence, phase-0 and odd-pass tasks,
  the 1 Hz clock) while the aircraft flies past the stations and turns, with the scenery's
  answers imitated (found bits restored after a request, the glideslope reference stored each pass
  on the ILS, marker flags now and then).

Mutation checks make the tests fail: a 0 shifted into east instead of north's 1 in the
normalization, the arctangent fraction built from bits 0-1 instead of 1-2 of `$C5`, one extra
cycle in $377C, the page-crossing cycle of the NDB record reads dropped, and the bar's XORs into
page 1 skipped (caught only by the stack watch). The every-position bar test found a real
defect, since fixed: the port took the page crossing of the first XOR read from the pointer
after the store had changed it (positions 74 and 106, base $0000: 103 cycles instead of 102).
