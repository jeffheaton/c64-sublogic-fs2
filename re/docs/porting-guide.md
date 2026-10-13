# Porting guide

How Flight Simulator II's 6502 code became Swift in `Sources/FS2Core`. Every subsystem is ported;
read this before changing a ported routine or adding a test. The goal is a native, readable port
that is bit-exact with the original, proven by differential tests against the lab (`fs2lab`),
which runs the original code.

## The model

- `Machine` (`Sources/FS2Core/Machine/Machine.swift`) owns the 64 KB memory image the original
  works on. Translated routines are `extension Machine` methods (or static functions for pure
  register-only routines) grouped by subsystem folder: `Math/`, `Raster/`, `Render3D/`, `Scenery/`,
  `Sim/`, `Input/`, `Panel/`, `Radio/`, `Sound/`, `Display/`, `Modes/`, `Game/` (the main loop,
  interrupts, cold start and the engines), `Persistence/`.
- **Memory-faithful rule:** a ported routine reads and writes every byte its original reads and
  writes, at the same addresses, including:
  - zero-page temporaries
  - table pointers
  - self-modified operand bytes, for example the patched immediate at $22B0 or the line-pen
    opcode patches at $9BF5

  Then a test can compare the whole image (except the stack page $0100-$01FF) with the original's.
  Model self-modifying code as explicit Swift state (an enum or a flag) **and** keep writing the
  bytes the original writes.
- Hardware access never touches `mem`: VIC, SID, CIA and color RAM go through `machine.io`
  (`IO.swift`). For example, a store to the border color register $D020 becomes
  `io.writeVIC(0x20, v)`, and a SID store becomes `io.writeSID(reg, v, at: clock.cycles)`.
  $D000-$DFFF in `mem` is RAM (the editor cache and the course plotter use it with `$01 = $30`).
- Register-passing: a routine taking inputs in A/X/Y/carry gets Swift parameters, and a routine
  returning values in registers or flags returns them. Only model the outputs that callers
  actually use, but say which registers are clobbered in a doc comment if a caller depends on it.
- Keep the original integer arithmetic: 8/16-bit wraparound (`&+`, `&-`), the carry chains, the
  truncation and saturation quirks, and the verbatim tables read from `mem` (never regenerated).
  Floating point is only for presentation (audio DSP, scaling), never for state.
- Cycle convention: a ported routine charges the cycles from its first instruction through its
  RTS; the caller charges its own JSR (and any register setup).
- `charge(n)` is CPU work: the virtual clock adds the cycles the VIC steals (badlines and sprite
  DMA) on top. `elapse(n)` is wall-clock time measured on the lab, where that DMA is already
  included (the loader's IEC transfers, waits for a time of day): it adds nothing on top.
- Cycle cost: call `charge(n)` with the original's cycle cost. Measure it with the harness
  (`fs2lab call … ` prints cycles) and fit a formula when it varies, for example a base cost
  plus a per-pixel cost for lines. Pacing only needs to be accurate to about 10%.
- Naming: lowerCamelCase from `re/symbols.json`. Put the original address in each doc comment:
  `/// $9A1D: draws a line …`. Use American spelling.

## Comments and documents: no listings

The port is a translation, not a copy, and its sources and docs must not carry the original's
code or data:
- Comments describe behavior in prose: what a routine reads and writes, the cases it handles, its
  quirks. They never quote the original's instructions or operand sequences, not even a short
  one; name the address and say what happens there instead.
- Cycle costs are charged as totals (per routine, per path, or a base plus a per-item cost), never
  as a sum written out instruction by instruction.
- Data tables are read from `mem` at run time, never written into sources, tests or docs.
- Addresses, names, register values, formulas and short identifying strings are fine.

The shipping audits (`excluded.md`, The audits) check the repository for the disk's bytes and for
instruction listings.

## The development bridge

While the subsystems were ported in parallel, a routine that called into a range not ported yet
wrote `machine.callOriginal(0xXXXX, CPURegisters(a: ..., x: ...))` at that call site, and tests
installed `Original.installBridge(on: machine)`, which runs the original routine on the port's
memory. Every such site has since been replaced by a direct call of the port, and no
`callOriginal` call is left in `Sources`. The two places that could only have been served by the
original (op 0A to a target with no port, a foreign ATIS hook; `scenery-3d.md`) are unreachable
with the disk's display lists and stop the program with an error naming the address. Rules that
still hold:
- Never add a bridge call to shipping code; `ShippingCodeTests` greps `Sources` for
  `callOriginal(`.
- The test rigs install no bridge. A test may install it to run an original routine on the
  port's side itself (`Render3DFrameTests`) or to prove that nothing reaches it (the replay
  matrix); it must never be needed for a port to pass.

## Name hygiene

Every subsystem adds API to `Machine`:
- Public members use the routine and variable names from `re/symbols.json`.
- New helper types are nested in a subsystem namespace (for example `enum Render3D`) or are
  `private`.
- Grep the tree before adding a public name.

## Running tests safely

Always run tests with a wall-clock cap, for example
`Scripts/capped 600 swift test --filter <Suite>` (or `make test`). Ported code loops on game
state the way the original does: wait-for-key, waits on frame counters, the interpreter. A test
that never supplies that state spins forever instead of failing, and the cap turns that into a
failure you can see. Tests that drive the port through waits must supply the inputs on the port
side too, for example a poll hook that delivers scripted keys (`ScriptedKeys`).

`Scripts/capped SECONDS COMMAND…` runs the command in a process group of its own and, when the
time is up, kills the whole group (TERM, then KILL) and exits with status 142. A plain `alarm`
around `swift test` kills SwiftPM but leaves `swiftpm-testing-helper` running the hung test, so
use the script for every build, test, lab and headless run, and after a cap fires check that
`pgrep -lf swiftpm-testing-helper` finds nothing left of that run. Exit status 142 is a hang to
find, not a slow machine. In sandboxed shells, SwiftPM has to run outside the sandbox.

## Proving a port

`Tests/DifferentialTests` has `Original` (`Original.swift`), which provides:
- `Original.data`: the user's disk (tests are skipped when it is absent)
- `Original.data!.coldMemory`: memory after the boot loads, before init
- `Original.regularFlight()`: RAM of the running game at Meigs, a cached lab snapshot
- `Original.snapshot(name, session:)`: RAM after any session
- `Original.call(addr, ram:, regs)`: runs the original routine on a flat 64 KB bus (no I/O) and
  returns the resulting RAM, registers and cycles
- `Original.differences(a, b)`: addresses that differ, with the stack page ignored

A routine diff test does three things:
1. Builds many input states: start from a realistic snapshot and randomize the routine's inputs
   with `TestRandom`.
2. Runs the original and the port on copies.
3. Expects identical memory and register outputs.

See `MathDiffTests.swift` and `DiffRig.swift` (the twin-image rig most suites use). Routines that
touch I/O run against the full lab machine (`C64Machine`, with the VIC, CIAs, SID and the virtual
1541) instead of the flat-bus `RoutineHarness`: `MainLoopTests.FullRig`, the library tests, and
the replay rig (`ReplayHarnessTests.swift`).

## Lab tools (`.build/release/fs2lab`; build with `swift build -c release --product fs2lab`)

| Command | Use |
|---|---|
| `run <d64> <outdir> "<session>"` | boot and play a session; `shot:NAME` writes PNGs, `snap:NAME` writes RAM snapshots |
| `call <snap> <addr> a=.. x=.. y=.. c=1 poke=ADDR:VAL:VAL dump=START-END` | run one routine and show the changed bytes |
| `profile <d64> "<session>" <frames>` | cycle histogram (where time goes) |
| `loop <d64> "<session>"` | main-loop iteration timing |
| `coverage <d64> <out.bin> "<session>"` | execution/data-access coverage map |
| `record <d64> <outdir> "<prefix>" "<session>"` | a deterministic replay log over a session (what the replay tests record) |
| `listing` / `symbols-check` | annotated listing and symbol validation (see `re/README.md`) |

Sessions: whitespace-separated steps, with `#` comment lines (the format is
`Sources/C64Kit/SessionScript.swift`; the lab plays it in `Session.swift`):
- `wait:FRAMES`
- `key:NAME[+NAME]:FRAMES`
- `joy1:up+fire:FRAMES`
- `down:NAME`/`up:NAME` (hold and release keys across steps), `nmi` (RESTORE)
- `poke:ADDR:VAL`
- `pc:ADDR[:MAXFRAMES]`
- `until:ADDR:VAL[:MAXFRAMES]` (wait for a byte; `!VAL`: until it differs)
- `peek:ADDR[:COUNT]`, `text` (print bytes or the text screen)
- `shot:NAME`
- `snap:NAME`
- lab-only instrumentation: `watch:LO:HI` (who touches an address range), `cov:on|off|save:NAME`
  (coverage)

`FS2 --headless --engine native` plays every step but the instrumentation, which it skips; its
`pc:` stops only at the key wait `pc:2250` and the top of the main loop `pc:204B` (the port has
no program counter), and its `until:` checks the byte every 1,000 cycles rather than at every
instruction (`engine.md`, The app). Base sessions are in `re/sessions/*.txt`. Pass one as
`@re/sessions/regular.txt`.

## Do not port

Do not port anything listed in `re/docs/excluded.md`:
- anything a modified copy of the disk adds
- the copy protection: the drive-status check ($7835-$7897), its delayed check in $E565 and the
  init stubs
- the IEC loader ($7300-$7834) and the stage-2 boot ($7898-$7909), which are replaced by direct
  block access that keeps the loader's memory effects and time (the overlay manager, the block
  cache and the editor cache swap at $E58F-$E712 are game code and are ported)
- the debug monitor's code at $C000 (the area itself is a live buffer) and the build residue
- the empty war-mode hook at $FD00, which is a documented no-op
