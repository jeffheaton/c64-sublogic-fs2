# Sound (SID 6581, NTSC)

The whole sound system has two parts:

- a small register-level driver in block $29, loaded at **$CC00-$CE83**;
- three pieces of game code that drive it: the IRQ pattern player, the engine slew, and the bomb sweep.

Nothing else on the disk touches the SID. All 164 blocks were scanned for $D4xx accesses, overlays included. Facts that limit what the port needs:

- `$D41B`/`$D41C` (osc3/env3) are never read, so the SID is **not** a random-number source.
- Pulse width, sync and ring modulation are never used.
- The control values written are only `$21` (saw+gate), `$81` (noise+gate), `$80` (noise, gate off) and `$00`.
- `$D415` (cutoff low bits) is never written. It stays 0 after the clear at $AB58.

**Port:** put a 6581 model (`SIDModel`) behind a write-register API, and replay exactly these register writes, cycle-timestamped. Keep the registers write-only with persistent state, because the effects depend on it:

- Low bytes left over from earlier writes.
- AD values set by a crash or touchdown persist and shape later retriggers.
- A new waveform written while the gate is already on gives no new attack.

The DSP, filter and resampling may use floating point. The register logic is integer and exact. It is ported in `Sources/FS2Core/Sound` (see [The port](#the-port)).

Clock: **1,022,727 Hz** (NTSC). f = reg × 1022727 / 2^24 ≈ reg × 0.0609594 Hz. The marker tones land exactly on 400, 1300 and 3000 Hz, which confirms the NTSC clock. Do not use PAL.

## Voices

| Voice | Use |
|---|---|
| 1, 2 | Engine drone: sawtooth `$21`, SR $B2 (sustain 11, release 48 ms), through the low-pass filter. AD is $00 after the clear and is never set by the idle state. Pitch only. **Volume never follows throttle**: master volume is 11 ($D418=$1B), or 15 ($1F) during a crash or explosion. |
| 3 | Every effect, gated by the per-frame pattern player |
| (1, 2) | The crash takes over voices 1 and 2 (noise); the touchdown takes over voice 2. The explosion uses only voice 3 but routes all three voices through the filter ($D417=$77). |

Because V2 = 2·V1 + 1 is one step sharp of V1's second harmonic, the two engine voices phase slowly (a beat period of many seconds at idle RPM). That is the original's sound, not a rendering artifact.

## Timing

| Part | Where | Rate |
|---|---|---|
| Gate-pattern step | Frame IRQ ($22C8 → $230A), in both the raster IRQ $2285 and the alternate IRQ $2304 | Once per video frame (59.826 Hz), independent of the main loop, paused or not |
| Engine slew $E500, bomb sweep $2381 | 10 Hz tick $2348 (one per 6 frames, catch-up), paused or not | 10 Hz |
| Effect state machine $CC16 | $23DD, on the first 10 Hz tick after the CIA1 TOD seconds ($DC09) differ from `$0E6D` | 1 Hz real time (up to 0.1 s late); suspended while `$08CC` ≠ 0, although `$0E6D` still follows the TOD |

## Gate-pattern player ($22C8, $230A)

1. `$0E5B` − 1 ($22C8, every frame). At 0, run the step at $230A and reload `$0E5B` from `$0E5A` (the step period in frames). A countdown that wraps from 0 waits 256 frames.
2. If (`$2308` & 7) == 0, reload the shift register: `$2309 = $0E5E`.
3. `$2308` + 1.
4. `$2309` is shifted right. If the bit shifted out is 1, write `$0E60` to $D412; otherwise write $00. $D412 is written on every step, even when the value does not change.
5. Back into the frame tick at $22CD (the keyboard phase).

So `$0E5E` is an 8-bit on/off rhythm, LSB first, one bit per `$0E5A` frames. This is the only $D412 writer outside the effect routines.

## Engine ($E500, 10 Hz)

- `E = $09BE` is the current value in RPM/50; the tach shows E×50.
- `T = $0E58` is the target, written by the engine model at $EF3F-$EF7C:

| Step | Rule |
|---|---|
| Base | T = `$EE17[throttle $0AC9 >> 2]`. The table holds 32 values from 650 to about 2450 RPM. |
| Engine off | Index 0 when `$09C9 = 0`, and T = 0 |
| Carb heat (`$0AA9`) | Index −8, or −$20 while `$EE16` counts down |
| Failure bits (`$09BF & 3`) | Index capped at 16 |
| No fuel (`$EE14 & $09C7`, `$EE15 & $09C8`) | Index −4 |
| Windmilling | T = max(T, `$EE37[min(31, airspeed $0A4D >> 2)]`) |
| Floor | If `$0967 == 0`, T ≥ $0D. Values below $0E give zero thrust. |

- **Slew:** E moves toward T by exactly 2 per call, clamped at T. When E == T the routine **returns without writing the SID**.
  - Down: E − 2, replaced by T when it is below T, or when it is ≥ $F0 unsigned. That wrap test also makes any E ≥ $F2 snap straight to T (unreachable with the table above).
  - Up: E + 2 with 8-bit wrap (E = $FE and T = $FF would wrap to 0; also unreachable), replaced by T when it reaches T.
- **Frequencies:** V1 `$D400/1 = (E>>1)·16`; V2 `$D407/8 = 2·V1 + 1` (an octave up, detuned by 1). That is about RPM/102.5 Hz: 2500 RPM gives 24.4 Hz and 48.8 Hz. The high bytes are built in the scratch bytes `$0E52` (V1) and `$0E54` (V2). The + 1 also adds the carry out of the doubling of `$0E54`, which is bit 7 of the V1 high byte and is never set.

## Effect state machine ($CC16; jump table $CC00, 11 words by `$0E59`)

1. If `$08D3` (SOUND, copied from editor byte `$0964` on editor exit) is 0: write 0 to $D404, $D40B, $D412, `$2309` and `$0E5E`, then return. `$0E5C` is not shifted, so a pending delay freezes while sound is off.
2. `$0E5C` is shifted right. If the bit shifted out is set, return. This is the tick-skip delay: `$0F` = 4 ticks, `3` = 2, `1` = 1.
3. Copy the word `$CC00[2 × $0E59]` into the operand of the jump at $CC43 (bytes $CC44/$CC45) and jump through it.

Most effects end at `$CDF3` (`$0E59 = 9`). Effects that keep being re-armed (stall, markers, guns) keep playing; the rest are reset on the tick after their delay runs out.

| State | Routine | Trigger | Registers |
|---|---|---|---|
| 0 idle | $CE07 | Every idle tick | $D404=$D40B=$21, $D412=0, `$0E60`=0, $D417=$83 (res 8, filter V1+V2), $D416=$70 (FC=$380), $D418=$1B (LP, vol 11), `$0E5A`=$28, SR $B2 on all voices. The engine AD is never set here. |
| 1 stall horn | $CC46 | **Stored** (not called) at $3014-$3016 by the 5 Hz aero routine $2F45 while the high byte `$09DD` is $21-$7F (negative values are skipped). Also sets the stall lamps $7E3D/$7E3E. | V3 saw. **Only $D40F=$18 is written**, so the low byte is left over (0 after the clear → 374.5 Hz; after a marker, the marker's low byte). AD 0, SR $A0, pattern $FF and `$2309`=$FF, gated at once ($D412=$21). No skip delay. Exits to state 9, so the horn stops on the next tick unless re-armed. |
| 2 crash/splash | $CC68 | Called at $356D (hard landing / excess bank) and at $F979 (message, after storing `$0E59`=2, which the routine overwrites) | Noise on all voices: V3 $0080 AD $2D; V2 $0200 AD $2C; V1 $4000 AD $08 (written in that order); SR 0. $D417=$76, $D418=$1F, $D416=$80, then controls $81. V1/V2 are normally gated already, so they decay without a new attack. Pattern $FF, `$0E5C`=$0F (4 skipped ticks, ~5 s). |
| 3 machine gun | $CCD1 | $2C03 (joystick-2 fire or SPACE airborne), only in war mode with ammo: stores `$0E59`=3, then calls it | V3 noise $1770, AD 0, SR $90, period 2, pattern $55 (15 bursts/s), `$0E60`=$81, `$0E5C`=1. No $D412 write: the pattern player does the gating. **Quirk:** the code compares the pattern $55 with `$0E5A`, the period that was just set to 2 (probably meant `$0E5E`), so `$2309`/`$0E5E` are always reloaded and the rhythm restarts on every shot. The bursts end one or two ticks after the last trigger. |
| 4 bomb release | $CD04 | Called at $2B88 by $2B79 (X, bombs left) | Whistle `$0E7D/E` = $4A38, V3 AD 0, SR $60, pattern $FF, `$0E60`=$D412=$21; sets state 10 and returns on its own (no skip delay). It writes no SID frequency: voice 3 starts at whatever frequency was left until the first sweep step (≤ 0.1 s). The sweep subtracts $F0 every 6 frames into $D40E/$D40F (first write $4948 = 1143.6 Hz, about −14.6 Hz per step) while bit 7 of `$0E7E` is clear. |
| 10 explosion | $CE37 | Each 1 Hz tick checks the whistle; it explodes once the high byte is < $30 (about 2.8 s of whistle, then up to 1 s more) | `$0E7E`=$FF (sweep off); V3 noise $0380, AD $2D, SR 0; $D417=$77, $D418=$1F, $D416=$80; V3 retriggered with $80 then $81; pattern $FF, `$0E5C`=3; state 9 cuts it about 3 s later. The compare is unsigned: if the sweep already wrapped to $FFxx (possible only while sound is off), it never explodes and state 10 stays until another effect is armed. |
| 5 outer marker | $CD2E | Stored at $3F34 by $3EFC (not in war mode), which consumes `$084C` by shifting it right; lamp $7E7B=$EB | 400 Hz ($19A1), AD 0, SR $60, period 15, pattern $55 (2 dashes/s) |
| 6 middle marker | $CD59 | `$084E`; lamp $7E7C=$AB | 1300 Hz ($534B), AD 0, SR $60, period 5, pattern $27 (dash-dot) |
| 7 inner marker | $CD84 | `$084A`; lamp $7E7D=$1B | 3000 Hz ($C037), AD $20, SR $62, period 5, pattern $55 (6 dots/s) |
| 8 touchdown | $CDAF | **Stored** (not called) at $3579 in `groundContact`, on the first pass with the on-ground flag `$0A12` set while `$0A11` is still 0 (then `$0A11` − 1), so it can start up to 1 s late | V3 noise, only $D40F=$FF, AD $44, SR 0, gated at once. V2 saw, only $D408=$FF (~3.98 kHz with the engine's low byte), AD $72, SR 0, retriggered $00 then $21. $D417=$81 (filter V1 only). Pattern $FF, `$0E5C`=3. |
| 9 reset | $CDF9 | End of an effect | $D404=$D40B=0, `$0E59`=0, `$09BE` + 1 (forces $E500 to rewrite the V1/V2 frequencies), then falls into state 0, which re-gates V1/V2 (an envelope retrigger) |

All the markers set `$0E60=$21` (sawtooth) and `$0E5C=3`. They do not write `$2309`, so a new pattern takes effect at the next 8-step reload. A marker that stays armed replays its handler every third tick; once its flag stops, the tone runs out the 3-tick delay and the reset follows.

Order of stores at first ground contact: a crash at $356D calls $CC68 (state 9), and then the touchdown store at $3579 overwrites the state with 8 in the same pass. The crash message's second call of $CC68 ($F974-$F979) runs on a later pass, while the crash's 4-tick delay is still pending, and sets state 9 again, so the chirp is normally not heard (read from the code; not yet checked in the lab).

**Boot:** $AB58 writes 0 to $D418 down to $D400 (an indexed store, X = $18..0), then calls $CDF9.

## Quirks to keep

- **Sound off** (`$08D3 = 0`). Directly called effects (crash, gun, bomb) are still heard until the next 1 Hz tick silences them, and the IRQ pattern player keeps gating V3 in between. The engine slew and the bomb sweep keep writing frequencies. Implement SOUND as the original flag, not as a mixer mute.
- **Late or long tails.** A touchdown can sound up to 1 s late. The stall horn stops on the tick after its trigger ends; the markers up to 3 ticks after.
- **Lasting envelope changes.** Crash AD values ($D405=$08, $D40C=$2C) and touchdown ($D40C=$72) persist forever and affect the next V1/V2 retrigger.
- **Key waits.** `$2250` forces silence: it zeroes `$08D3` and calls $CC16, and restores `$08D3` afterward. V1/V2 stay gated off until the state machine next runs state 0 or 9.
- **No extra sounds.** There are no sounds for wind, gear, flaps or key clicks. Do not add any.

## The port

`Sources/FS2Core/Sound` translates every routine above as `Machine` methods. Each SID store goes through `io.writeSID(reg, value, at: clock.cycles)` in the original's order, stamped with the cycle at which the store instruction starts (the lab's `sidWrites` use the same convention), and every RAM byte the original writes is written, including the self-modified operand $CC44/$CC45 and the scratch bytes `$0E52/$0E54`. The handler table at $CC00 is read from the loaded memory image.

| Method | Original | Called by (scheduler port) | Cycles charged |
|---|---|---|---|
| `patternPlayerFrame()` | $22C8-$22CC + $230A-$232D | Every frame tick ($22C3 in $2285, and $2304), after the `$34` / `$0E6B` increments, before the keyboard phase $22CD | 8, or 10 + 43-51 |
| `patternStep()` | $230A | `patternPlayerFrame()` | 43-51 (with the jump back to $22CD) |
| `engineSoundSlew()` | $E500 | 10 Hz tick, the call at $2358 | 17, or 114-119 |
| `bombWhistleSweep()` | $2381-$239A | 10 Hz tick, after the key-repeat checks (falls through to $239B) | 7 or 34 |
| `soundTick()` | $CC16 | 10 Hz tick at $23DD; key wait $2250 (after `$08D3 = 0`) | 34 (off), 22 (skipped), 42 + handler |
| `sidInit()` | $AB58 | Cold init ($AAF3) | 349 |
| `sfxCrash()`, `sfxGun()`, `sfxBombRelease()`, ... | $CC46-$CE37 | The handlers, also callable directly | 12-139 |
| `triggerEffect(_:)` | $3016, $3579, $3F34 (stores); $2C15-$2C1A, $2B88, $356D, $F974-$F979 (calls) | Game code that arms an effect | The routine's own cycles; the call site's loads, stores and call are the caller's |

Cycle convention: a method charges from its first instruction through its own return (fragments: through their last instruction); the caller charges its call. Charges are made progressively, one chunk before each SID store, so an event handler run by `charge` can fall between two stores, as an IRQ could on the C64.

**TOD.** None of these routines reads I/O. The only input from hardware is the CIA1 TOD seconds that the 10 Hz tick compares with `$0E6D` at $23CD before calling $CC16. The scheduler's port of $2348 supplies it from a virtual TOD clocked by 60 Hz mains ticks derived from the virtual clock (one tenth per 6 ticks, as in the lab's CIA model; the port is NTSC only), and calls `soundTick()` on the first 10 Hz tick after the BCD seconds change, unless `$08CC` is set.

**Verification.** `Tests/DifferentialTests/SoundDiffTests.swift` runs the original routines on the lab's flat bus and the port on the same states (the regular-flight snapshot with the sound bytes randomized), and requires identical SID stores (order, values and cycle offsets), cycles and memory (stack and I/O pages excluded):

- `$CC16` for all 11 states × sound on/off × skip values × whistle heights, 1500 random states (including $80-$8A, which the doubled table index folds onto 0-10), and every handler called directly;
- `triggerEffect` against the game's own call sites ($3014, $3577, $3F20/$3F29/$3F32, $2C15, $2B88, $356D, $F974), run in the original up to the end of their sound part;
- `$AB58` on the boot image;
- the pattern player for countdown/period/counter edge cases, every step path (with the 43-51 cycle range), and over 1200 frames;
- `$E500` for all 65,536 (E, T) pairs;
- the bomb sweep at the borrow and wrap edges, a release through the explosion with sound on and off, and every effect's lifecycle under a frame/10 Hz/1 Hz schedule;
- eight one-minute random schedules: random arming (held effects re-armed), SOUND toggles, `$2250` key waits, engine target changes and a drifting 1 Hz phase;
- **interrupt points:** with the event handler firing on every `charge`, each point at which the port could run the frame IRQ's work must be an instruction boundary of the original at the same cycle offset, with the same sound bytes and the same SID stores so far. This checks that no RAM store is made ahead of a SID store that precedes it in the original.

`renderEffectsToWAV` plays each effect through the port and C64Kit's `SIDStream`/`SIDModel` into `out/sound/<effect>.wav` (git-ignored) and checks that the markers peak at 400, 1300 and 3000 Hz. Rerun it with `swift test --filter renderEffectsToWAV`.
