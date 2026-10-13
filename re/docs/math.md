# Fixed-point math library ($16AA-$1A0A)

The integer math every other subsystem builds on: the Q15 multiply and divide, an unsigned 16×16
multiply, sine and cosine of binary angles, signed 8×8 multiplies, and the speed-indexed table
interpolation of the aerodynamics. The port is in `Sources/FS2Core/Math/`. Every routine is a
step-for-step translation that reproduces the original's results, its zero-page side effects,
the registers and flags its callers use, and its cycle cost. `Tests/DifferentialTests/MathDiffTests.swift`
proves it against the original routines, mostly exhaustively.

## Conventions

- **Number formats.** Q15 words are signed 16-bit values with 32768 = 1.0. Binary angles are
  16-bit, with $10000 = 360°. Words are little-endian and register pairs are written high:low
  (X:A means X is the high byte), except `mul8x8`, which returns Y:A.
- **Port API.** Every routine is an `extension Machine` method named after its symbol. Register
  inputs are parameters (including the incoming carry where the routine reads it). The return
  value is a named tuple of the registers the routine leaves, plus `carry` where a caller uses it.
  `Machine.asr16`/`negate16` also exist as static pure functions.
- **Memory.** Each port writes exactly the bytes the original writes, so the whole image can be
  compared. Pushes and pulls inside a routine (`$1802`, `$1961`) are not modeled, because the
  differential tests ignore the stack page.
- **Cycles.** Each port charges the cycles from the routine's first instruction through its return,
  which is what `fs2lab call` and `Original.call` measure. The caller's call (6 cycles) belongs to
  the caller. A routine that calls or jumps to another charges its own instructions, including that
  call or jump, and the callee charges the rest. Costs are computed exactly from the path taken,
  including page-crossing penalties on indexed table reads.

## Zero-page temporaries

| Address | Written by | Contents afterward |
|---|---|---|
| `$A5` | `$16AA`, `$196D` | destination address (`$16AA`); y (`$196D`) |
| `$A7` | `$16C9`, `$1802` | product low byte; remainder low byte |
| `$A8` | `$16C9` | high byte before negation (negative products only) |
| `$BE`, `$BF` | `$18D0`/`$1911`, `$19E2` | trig intermediates (see below); t[i] |
| `$C4:$C5` | almost all | `mathResult`: the first operand going in, the result or a remnant coming out |
| `$C6:$C7` | almost all | `mathOperand`: the second operand, left as its absolute value |
| `$C8-$CB` | `$188A` | `product32` |

These are shared scratch bytes: other subsystems use `$A5`-`$A8` and `$BE`/`$BF` as well.

## Routines

| Address | Name (port) | In | Out | Cycles |
|---|---|---|---|---|
| `$16AA` | `mulZeroPage(a:x:y:)` | A = dst, X, Y = zero-page operands | zp[A] = zp[X]·zp[Y]; A, X; Y = dst | 55 (56 if Y = $FF) + `$16C9` |
| `$16C9` | `mulQ15()` | `$C4:$C5` = m, `$C6:$C7` = n | X:A ≈ m·n/32768; Y = sign | 17/24 (zero), else 271-454 |
| `$17EF` | `mulQ15AX(a:x:)` | `$C4:$C5`, X:A | as `$16C9` | 9 + `$16C9` |
| `$17F6` | `mulQ15Chain(a:x:)` | `$C4:$C5`, X:A | as `$16C9`, and `$C4:$C5` = product | 24 + `$16C9` |
| `$1802` | `divQ15(a:x:)` | A:X = n (A high), `$C6:$C7` = d | `$C4:$C5` ≈ n/d·32768; Y = 0 | 692-771 |
| `$1881` | `asr16(a:x:)` | X:A | X:A >> 1; Y = old A; C = bit out | 20 |
| `$188A` | `mulU16(a:x:)` | `$C4:$C5` = m, X:A = n | `$C8-$CB` = m·n; A = `$C9`, X = `$CA` | 635 + 16·popcount(m) |
| `$18B8` | `cos8(a:)` | A = angle high byte | X:A Q15, carry | 5 + `$18D0` |
| `$18BD` | `sin8(a:)` | A | X:A, carry | 5 + `$18CD` |
| `$18C2` | `cos9(a:y:)` | Y = high byte, A bit 7 = $80 low byte | X:A, carry | 9 + `$18D0` |
| `$18C9` | `sin9(a:y:)` | Y, A bit 7 | X:A, carry | 6 + `$18CD` |
| `$18CD` | `sin16(a:x:)` | A = high, X = low | X:A, carry | 4 + `$18D0` |
| `$18D0` | `cos16(a:x:)` | A = high, X = low | X:A, Y, carry | 33-514 |
| `$1911` | `cosFirstQuadrant` (internal) | A = 0-$40, X | X:A, Y, carry | 23 / 48 / 85 + `$17EF` |
| `$1961` | `mul8Half(x:y:carry:)` | X, Y signed, carry | Y:A ≈ x·y; carry = bit out | 31 + `$196D` |
| `$196D` | `mul8x8(x:y:carry:)` | X, Y signed, carry | Y:A ≈ 2·x·y; X; carry | 119-152 |
| `$19D5` | `negate16(a:x:)` | X:A | −X:A; Y = new A | 23 (24 if A = 0) |
| `$19E2` | `interpBySpeed()` | (`$BA`) table, `$0A4D` | `$C5:$C4` 8.8; A = `$C5`; carry | 79 (+page crossings) + `$1961` |

There is nothing else in the range: `$16AA-$1A0A` is fully covered by these entries and their
internal labels.

## `$16C9` signed Q15 multiply

An inverted-bit shift-add loop. Step by step:

1. **Zero shortcut.** If m = 0 (17 cycles) or n = 0 (24 cycles), A = X = 0, and Y, the carry and
   memory are unchanged.
2. **Sign.** Y = `$C5` ^ `$C7`.
3. **m.** `$C4:$C5` becomes ~|m|. A positive m is complemented, and a negative m is decremented
   (m − 1 = ~|m|). The loop then adds wherever a bit of ~|m| is **0**. m = −32768 survives the
   decrement and increment unchanged as $8000 = ~$7FFF, so it acts as |m| = 32767.
4. **n.** `$C6:$C7` becomes |n|, with −32768 → $7FFF. A still holds the high byte that the sign
   code last computed: |n|'s high byte, or **$80** (not $7F) for n = −32768.
5. **Bit 0** of |m| keeps that A as the 8-bit accumulator, otherwise A = 0.
6. **Bits 1-5** shift A right (the bit shifted out is rotated into the top of `$C4`) and add only
   |n|'s **high byte**.
7. The next shift right loses a bit. From here **bits 6-14** each add all of |n| into the 16-bit
   accumulator A:`$A7`, which shifts right once per step. Bit 15 is ignored.
8. A final shift; a negative sign negates A:`$A7` through `$A8`.

Result: X:A, with `$A7` = the low byte. The error against the exact m·n/32768 stays within
−1.95..+1.97 LSB (2 million random products). The routine is sign-symmetric but not commutative,
because bits 0-5 of the first operand only see the second operand's high byte.

## `$1802` signed fractional divide

The sign byte A ^ `$C7` is pushed. `$C4:$C5` becomes |n| and `$C6:$C7` becomes |d|, both
negated in memory. Then come 15 non-restoring steps on the remainder A:`$A7`:

- Quotient bits rotate into `$C4:$C5` from the bottom and push |n| out of the top.
- A step is "negative" when bit 15 of the 16-bit remainder is set, so a large |d| (≥ $4000) can
  overflow that test.

A final doubling makes **bit 0 always 0** (2-LSB resolution). If the doubling sets bit 15, which
happens when |n| ≥ |d|, both bytes are decremented separately. That turns $8000 into $7FFF, but
other values lose 257. A negative sign negates `$C4:$C5`.

Registers: A is the pulled sign byte for a positive quotient, otherwise the quotient's high
byte. X is the remainder high byte from the last step that saved it. Y = 0. The results are only
meaningful for |n| < |d|.

## `$188A` unsigned multiply

A 16-step right-shift multiply that is **exact**: the uninitialized `$C8:$C9` is shifted out
completely. Afterward `$C4:$C5` = 0 and `$C6:$C7` = n. The returned A and X are bits 8-23 of
the product.

- The N flag reflects X, and the caller at `$3303` branches on it after a store.
- Y is unchanged.
- The final carry is bit 7 of the old `$C9`. No caller uses it.

## Sine and cosine (`$18B8`-`$1960`)

The table at `$158E` holds 66 Q15 words, cos(i · 1.40625°) for i = 0..65. Entry 25 is a glitch
(26489; it should be 26789). The port reads the table from memory through `cosTableEntry` and
never regenerates it. `$1911` reads entries 0-64. **Entry 65 is never read**: index 64 is only
reached with a zero low byte.

`$18D0` cos16, for an angle t = A:X:

1. If bit 15 is set, t := −t (cos is even). $8000 has no positive twin and becomes **$7FFF**.
2. If the high byte is $40-$7F, the result is −`$1911`($8000 − t). The call of `$1911` is
   followed by a negate, which leaves the unnegated value in `$BE:$BF`.
3. Otherwise it branches to `$1911`.

`$1911` (first quadrant, i = A ≤ $40, Y = 2i):

| X | Result | Notes |
|---|---|---|
| 0 | t[i] | 23 cycles |
| $80 | (t[i] + t[i+1]) / 2 | The 16-bit sum's carry is dropped before a **logical** shift right. `$BE` = the low byte of the sum. Harmless for the real table (no negative pairs are averaged). 48 cycles. |
| other | t[i] + `$17EF`(t[i+1] − t[i], (X >> 1) << 8) | `$BE:$BF` = t[i], `$C4:$C5` = the difference. X = 1 adds nothing (zero shortcut). 85 cycles + `$17EF`. |

Each table read at an index of $70/$72 or more crosses into page $16 and costs one extra cycle.

`$18CD` sin16 computes cos(t − $4000) by subtracting $40 from the high byte. `$18B8`/`$18BD`
force X = 0. `$18C2`/`$18C9` take Y as the high byte and A bit 7 as a $80 low byte (a "half
step", the average of two entries); the view matrix uses these.

**Carry out matters.** `cos8` is followed directly by `mul8Half` at $A3D0/$A3FB (attitude
indicator) and, through a few stores, by `mul8x8` at $E7CF (wind). Both read the carry as their
bias. The carry is:

- clear for an exact entry;
- the bit the average shifts out;
- the carry of the interpolation's final high-byte add;
- in the second quadrant, set only when the result is 0.

## `$196D` / `$1961` signed 8×8

The 7-step shift-add over the inverted bits of |y| reduces exactly to:

```
magnitude = 2·|x|·|y| + c          (−128 counts as 127 for both operands)
Y:A = −magnitude if x XOR y is negative, else magnitude
```

Here c is the bit the first rotate of `$C6` takes in, and it ends up as bit 0 of the product:

| Operands | c |
|---|---|
| x ≥ 0, y ≥ 0 | the **caller's carry** |
| x ≥ 0, y < 0 | 1 (left by the subtraction that forms \|y\|) |
| x < 0 | 0 (left by the addition that forms \|x\|) |

This is the "bias" quirk. 1×1 = 3 with the carry set and 2 with it clear. 0 × (y < 0) = −1.
The earlier sample values 3×5 = 31 and 100×100 = 20001 had the carry set, and 10×20 = 400 had
it clear.

`$C6:$C7` keeps the magnitude, never negated. `$C4` = |x| and `$A5` = y.

- X is x for a positive product, otherwise the low byte.
- Carry out is set for a positive product, otherwise only when the magnitude is 0. The wind code
  chains it from $E7CF into $E7D5 and from $E7D5 into $E7E2.

`$1961` arithmetic-shifts the result right by one. A positive product comes out as exactly x·y,
and a negative one as −|x·y| − c. Carry out is the bit shifted out.

## `$19E2` speed-indexed interpolation

The routine reads the airspeed high byte `$0A4D` (not `$0A4C`). With i = `$0A4D` >> 4 and
f = `$0A4D` & 15:

```
$C5:$C4 = t[i]·256 + 2·mul8Half(x = f·8, y = t[i+1] − t[i])
```

- The difference is an 8-bit wrapping subtraction, so a step of more than ±127 interpolates the
  wrong way.
- The carry entering `$196D` is 0 (left by the ASLs), so only falling steps get the bias. For
  example, halfway from 40 down to 30 gives 8958, not 8960.
- `$BE` = t[i]. A = `$C5`.
- Carry out is from the final high-byte add, and the caller at $2FA4 passes it into `mul8Half`.

The tables are `$0E10`, `$0E1A`, `$0E24`, `$0E2E` and `$0E42`, each read at t[0..16].

## Callers that depend on flags

The rest of the program only relies on these flag outputs, found by scanning every call site for
flags read before they are set, including flags carried through a following call:

- N after `$188A` reflects X ($3303).
- The carry after `cos8` feeds `mul8Half`/`mul8x8` ($A3CB → $A3D0, $A3F6 → $A3FB, $E7C2 → $E7CF).
- The carry chains between the 8×8 calls at $E7CF → $E7D5 → $E7E2 → $E7E8.
- The carry after `$19E2` feeds `mul8Half` at $2FA4.

The other call sites of `$196D`/`$1961` pass in a carry left by their own arithmetic, so their
ports must pass the real carry. The ports also return Y wherever the routine changes it, because
some callers pass registers through to later code. `mulQ15` returns `y: nil` on its zero
shortcut, which leaves Y unchanged.

## Verified vectors

Measured in the lab on the running game, with the conventions spelled out:

| Call | Inputs | Result | Cycles |
|---|---|---|---|
| mul(1000, 1000) | `$16C9`, `$C4:$C5` = 1000, `$C6:$C7` = 1000 | 29 | 336 |
| mul(546, 10000) | `$16C9` | 166 | 291 |
| mul(32767, 32767) | `$16C9` | 32765 | 416 |
| div(100, 300) | `$1802`, A = $00, X = $64, `$C6:$C7` = 300 | `$C4:$C5` = 10922 | 728 |
| div(1000, 2000) | `$1802`, A = $03, X = $E8, `$C6:$C7` = 2000 | 16384 | 697 |
| sin($1234) | `$18CD`, A = $12, X = $34 | 14156 | 457 |
| cos($1900) | `$18D0`, A = $19, X = $00 | 26489 (entry 25) | 33 |

All of the earlier vectors were correct as stated.

## Corrections to earlier notes

- **`$196D` bias.** The "1×1 = 3" bias is the caller's carry (or a forced 1/0 by sign), not a
  constant. Ports must pass the real carry.
- **`$16C9` error range.** The error range is −1.95..+1.97 LSB (earlier: −1.8..+1.9).
  - A second quirk: n = −32768 seeds the bit-0 term with $80 instead of $7F.
- **`$19E2` input.** It reads `$0A4D`; the old symbol entry said `$0A4C`.
- **`$1802` result.** The result always has bit 0 clear. The overflow patch is two independent
  decrements.
- **`$19D5` name.** The symbol is renamed `negate16`, to match the existing port.
- **`$1911` symbol.** `cosFirstQuadrant` is a new routine symbol: called from `$18E6` and
  a branch target from `$18D6`.

## Tests

- `Tests/DifferentialTests/MathDiffTests.swift` runs each original routine and its port on twin
  memory images (the running game at Meigs). After every call it compares the whole image
  (stack page excluded), A/X/Y, the carry where modeled, and the cycle count.
  - Exhaustive: `$196D` and `$1961` (all 65536 operand pairs × both carries), `$18D0` and `$18CD`
    (every angle), `$18C2` and `$18C9` (every Y × every A), `$18B8`/`$18BD`, `$1881`/`$19D5`.
  - Edge-value grids plus tens of thousands of random cases: `$16C9`, `$17EF`, `$17F6`,
    `$16AA` (every destination and source, including $FF and the routine's own temporaries),
    `$1802`, `$188A`, and `$19E2` (the game's tables at every speed, plus random tables
    crossing a page).
  - Operand sweeps: `$16C9`, `$1802` and `$188A` see every value of each operand against a
    random or edge-value partner (`$1802` half the time inside |n| < |d|).
  - Random cosine tables: all six trig entries on 24 random tables (uniform, all negative,
    saturation values, random walks), with random incoming Y and carry. The real table is
    falling and non-negative, so only these reach the rising steps, the dropped carry of the
    average, a difference that wraps 16 bits, and a clear carry out of the interpolation.
  - `$19E2` tables that wrap past $FFFF into page 0, and page-0 tables that overlap `$BA:$BB`,
    `$BE` (written between the two reads) and the 8×8 temporaries.
- `Tests/FS2CoreTests/MathTests.swift` holds the documented vectors, quirks and cycle formulas.
  It needs no disk; the trig tests use a synthetic table.
