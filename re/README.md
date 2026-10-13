# The reverse-engineering corpus

What we know about SubLogic Flight Simulator II (C64, v1.0, NTSC), and how the Swift port is
checked against it. The port is a translation of the original routines, so this directory is the
reference the translation follows: the names, the memory layout, the behavior of every routine,
and the lab sessions that confirmed it.

**Rule:** nothing committed here is a copy of the program or its data: no byte dumps, disassembly
listings, table contents, bitmaps or text dumps. Addresses, names, formulas, register values,
behavior described in prose and short identifying strings are fine. The test
`SymbolDatabaseFile.containsNoByteDumps` rejects any run of 12 or more hex byte values in
`symbols.json`, `tools/check_corpus.py` does the same for every file here, and the shipping audits
(`docs/excluded.md`) check the whole repository for the disk's bytes and for instruction listings.
Nothing here reproduces what a modified copy of the disk adds either (`docs/excluded.md`).

| Path | What it is |
|---|---|
| `symbols.json` | The source of truth for names: memory regions, variables, routines, tables and notes, with addresses, types, routine specs and comments. |
| `symbols.d/` | Optional fragments of `symbols.json` for parallel work (normally empty; see below). |
| `docs/*.md` | The specification of each subsystem and of its port, plus the lab's findings. |
| `sessions/*.txt` | Input scripts for the lab (`fs2lab`) and the replay tests. |
| `tools/region_tables.py` | Regenerates the region tables of `docs/memory-map.md` and `docs/excluded.md` from `symbols.json`. |
| `tools/check_corpus.py` | Checks the corpus: no byte dumps anywhere in `re/`, the region tables current, every test and Swift file a doc cites present. |
| `out/` | Generated listings. **Git-ignored**: these files contain SubLogic bytes. |

## Which document covers what

Start with `docs/porting-guide.md` (the rules every ported routine follows) and
`docs/main-loop.md` (the program that drives everything else).

| Document | Covers |
|---|---|
| `porting-guide.md` | The memory-faithful rule, cycles, registers, naming, comments without listings, running tests with a time cap, how a routine is proven, the lab tools |
| `main-loop.md` | The main loop, the raster IRQ, the 10 Hz poll and tick, display setup, the cold start; normal mode (`InterruptScheduler`) and replay mode (`ReplayDriver`) |
| `engine.md` | `NativeEngine` (threads, frames, the latched split, input, key waits), Smooth pacing, the mode library file, the app's side |
| `memory-map.md` | The logical block filesystem, the boot chain, the overlays, the runtime areas, the ABI vector tables, and every region (generated) |
| `excluded.md` | What modified copies add, the protection, the IEC loader and the residue: what is not ported and why; the shipping audits |
| `display.md` | VIC setup, the raster split, the double buffer, palettes, the panel, an overview of the drawing primitives |
| `raster.md` | 2D primitives: pens (self-modified code), plot, line, spans, the row filler, the 3x5 text |
| `render3d.md` | The view matrix, the horizon fill, clipping, polygons (and their overflows), projection, point transforms, the attitude indicator, the turn coordinator, the view overlays |
| `scenery-3d.md` | The display-list interpreter and its opcodes, the horizon pass, the root list and areas, block streaming, the overlay manager and the editor cache |
| `math.md` | The fixed-point library $16AA-$1A0A: multiplies, divide, trig, the speed interpolation, with their quirks |
| `flight-model.md` | Units, timing sources, the aerodynamics, the integrator, ground contact, wind, slew, the engine, failures, crash and splash |
| `input.md` | The keyboard matrix scan, joysticks, the key ring and repeats, the code table, every key handler, RESTORE, the Mac key mapping rules |
| `panel.md` | Needles, gauges, markers, readouts, the time of day and lighting, the instrument masks and their save buffers |
| `radios.md` | The radio stack, the station lookups, the nav instruments (CDI, OBI, glideslope, markers), the ADF and NDBs |
| `atis.md` | The ATIS records, the composer, the teletype and the busy delay |
| `sound.md` | The SID driver, the effects, the pattern player, the engine sound, the quirks the port keeps |
| `editor.md` | The mode editor, the mode records and conversions, the mode library and its disk I/O, the text screen |
| `war.md` | Europe 1917: enemies, guns, bombs, damage, status lines |
| `course-plotter.md` | The course plotter and the database info screen |
| `modes-ui.md` | An overview of the modes, screens and the panel layout, pointing at the pages above |
| `features.md` | What each lab session verified or corrected about the keys and features |
| `coverage.md` | Execution coverage of the original by the sessions: which code each feature runs, what no session reaches |
| `open-questions.md` | The questions still open (they need an image of an unmodified original disk or real hardware), and how every other one was settled |
| `TODO-docs.md` | Open follow-ups outside this directory (code and lab tooling) |

## Listings

```sh
swift build -c release --product fs2lab
.build/release/fs2lab listing --d64 "$FS2_D64"   # writes re/out/
```

`listing` annotates the disk's code and data with `symbols.json` and writes one ca65-flavored
file per region group: `main.s` (the resident image), `overlay-cold-start.s` (stage 3 at $A7E0),
`overlay-editor.s`, `overlay-war.s`, `overlay-flight.s` (with the scenery root block 66 at $A800)
and `overlay-database-info.s`. The disk comes from `--d64`, then `$FS2_D64`, then the imported
copy in `~/Library/Application Support/FS2/`.

- **Code** is disassembled. Routine headers show inputs, outputs, side effects and callers.
  Branch and jump targets get `Lxxxx` labels, I/O registers get names, and notes become comments.
- **Data and tables** become `.byte` rows, or `.word` rows for 16-bit entries; pointer words are
  shown as names.
- **Text** becomes `.byte` rows with the characters in a comment.
- **Buffers and free space** become `.res`.
- **Residue, crack, loader and protection** regions are summarized under a `NOT PORTED` banner
  and never dumped.

A routine label that falls inside an instruction prints as `name = * + k`, which usually means a
wrong address or data inside a code region; the header of each file reports any undocumented
opcodes in code regions.

## Symbols

Change `symbols.json` whenever a fact is established or corrected (confirm it in the lab or the
code first), then:

1. `.build/release/fs2lab symbols-check` must report 0 errors and 0 warnings (the
   `SymbolDatabaseFile` tests in `swift test` repeat the error checks).
2. `python3 re/tools/region_tables.py` refreshes the generated region tables (`--check` reports
   whether they are current).
3. Regenerate the listing and read the region you changed.
4. Update the matching `docs/*.md` when the change affects behavior the port depends on.
5. `python3 re/tools/check_corpus.py` must report ok (it also catches a doc that cites a test or
   a file that was renamed).

**Fragments (`symbols.d/`).** `SymbolDatabase.load` merges every `symbols.d/*.json` into the main
file, in name order: a fragment's region, variable, routine or table replaces the entry of its
kind with the same address and overlay, anything else is added, and notes are appended. Parallel
changes used this so that no two of them edited the same file; the fragments have been folded
into `symbols.json`, and the directory holds only its README. Because the merge replaces by
address, a second name for an address that already has a variable (an alias, which the schema
allows) belongs in `symbols.json` itself.

### Schema (`schemaVersion` 1)

The top level is an object with `schemaVersion` (1), `game` and `description` (free text), and the
arrays `regions`, `variables`, `routines`, `tables` and `notes`. Every array is sorted by overlay
(resident first) and address.

- **Addresses** are strings in the form `"$XXXX"`: exactly four uppercase hex digits.
- **Names** are lowerCamelCase ASCII.
- **`overlay`** is `null` (or absent) for resident memory. Otherwise it is one of `"coldStart"`,
  `"editor"`, `"war"`, `"flight"` or `"databaseInfo"`, and the entry describes that overlay's
  contents in the $A7E0 overlay window. Overlay entries must not lie below $A7E0.
- **`confidence`** is `"high"` (traced in code or confirmed by running it), `"medium"` (inferred
  from code with some interpretation) or `"low"` (a plausible guess).

**`regions`: what every byte is**

| Field | Type | Meaning |
|---|---|---|
| `start`, `end` | address | Inclusive range |
| `kind` | enum | `code`, `data`, `table`, `text`, `asset`, `buffer`, `free`, `residue`, `crack`, `loader`, `protection` |
| `name` | string | Unique among the regions of the same overlay (a separate namespace from labels) |
| `subsystem` | string | Owning module (see below) |
| `overlay` | null / enum | See above |
| `confidence` | enum | Optional |
| `comment` | string | What it is, and porting guidance |
| `encoding` | `"ascii"` / `"screen"` | Optional, text regions only: the game's 3x5-font records, or C64 screen codes in the upper/lowercase set (the editor) |

| Kind | Meaning |
|---|---|
| `code` | 6502 code |
| `data` | Initialized variables; their disk values are the cold-start state |
| `table` | Read-only lookup data |
| `text` | Strings and text records |
| `asset` | Bitmaps, sprites and font, read from the user's disk at run time |
| `buffer` | Runtime-only memory; any loaded content is meaningless |
| `free` | Unused |
| `residue` | Build or development leftovers, never executed |
| `crack` | Bytes that modified copies of the disk add or overwrite |
| `loader` | SubLogic's IEC disk loader, replaced by direct block access |
| `protection` | SubLogic copy protection |

The last four kinds are **excluded**: the port must not reproduce them (`docs/excluded.md`).
Regions must have `start <= end`, must not overlap within one overlay (resident and overlay
regions may share addresses, because overlays replace memory), and must cover every resident byte
from $0002 to $FFFF outside the overlay window $A7E0-$BFFF (a gap is a warning).

**`variables`: named memory**

| Field | Type | Meaning |
|---|---|---|
| `addr` | address | First byte |
| `name` | string | Label |
| `type` | enum | `u8`, `s8`, `u16`, `s16`, `u24`, `s24`, `u32`, `s32`, `bcd`, `ascii`, `ptr`, `bytes`; multi-byte values are little-endian |
| `size` | int | Bytes; must match the fixed-size types (8-bit 1, 16-bit and `ptr` 2, 24-bit 3, 32-bit 4) |
| `subsystem`, `overlay` | | `overlay` optional |
| `units` | string | Units or format, e.g. `"1/256 m"`, `"8.8 m/s"`, `"binary angle ($10000 = 360 deg)"`, `"Q15"` |
| `confidence`, `comment` | | |

Variables may nest (the mode-record fields lie inside `modeRecord`) but must not partially
overlap. Several names at one address are allowed (aliases: zero-page temporaries are shared);
when naming an operand the smallest entry wins, and an address inside a larger entry prints as
`name+k`.

**`routines`: code entry points**

| Field | Type | Meaning |
|---|---|---|
| `addr`, `name`, `subsystem`, `overlay` | | |
| `inputs`, `outputs`, `sideEffects` | string | Registers and memory read and written; empty when unknown |
| `calledFrom` | [address] | Optional: call sites (JSR/JMP/branch, possibly through a `$2000`/`$8000` vector), or the calling routine's entry |
| `confidence`, `comment` | | The comment names the Swift port (`Port: Machine.name`) where one exists |

**`tables`: structured read-only data**

| Field | Type | Meaning |
|---|---|---|
| `addr`, `name` | | |
| `length` | int | Bytes |
| `element` | enum | `u8`, `s8`, `u16`, `s16`, `ptr`, `bytes`; 16-bit and `ptr` elements are listed as `.word`, `ptr` words as names |
| `stride` | int | Optional record size, the listing's row width |
| `format` | string | Layout and indexing |
| `subsystem`, `overlay`, `confidence`, `comment` | | |

**`notes`** are `{ "addr", "overlay"?, "text" }`: comments on single addresses (self-modified
operands, patch points, branch points of interest), printed before the line at that address.

**Uniqueness.** Variables, routines and tables share one label namespace per overlay; an
overlay's names must not repeat a resident name (both are visible in that overlay's listing); the
same name in two overlays is fine (every overlay has a region `overlaySlots`).

**Subsystems:** `core`, `mainLoop`, `scheduler`, `fixedMath` (core and timing); `raster2D`,
`text`, `display`, `panel`, `renderer3D` (graphics); `sceneryVM`, `streaming` (scenery);
`flightModel`, `engine`, `wind`, `failures` (simulation); `input`, `radios`, `atis`, `sound`;
`modes`, `editor`, `war`, `coursePlotter` (modes and screens); `overlayManager`, `init`,
`diskUi`, `systemError` (infrastructure); `loader`, `protection`, `crack`, `residue` (excluded);
`-` (free space).

## Sessions and the lab

The lab (`Sources/M6502`, `Sources/FS2LabKit`, `fs2lab`) runs the original program on a
cycle-counted 6502, a C64 bus and a virtual 1541 that runs SubLogic's own loader, starting from
the state SubLogic's stage 2 leaves (no other boot code on the disk runs). A session is a script
of waits, keys, joystick moves, pokes and captures (`porting-guide.md` lists the steps):

```sh
.build/release/fs2lab run "$FS2_D64" out/sessions/takeoff @re/sessions/takeoff.txt
```

- `regular.txt` is the common prefix: display A, regular flight, the scenery loaded, stopped at
  the top of the main loop.
- The feature sessions (`takeoff`, `views`, `radar`, `switches`, `radios`, `atis`, `ils`,
  `editor`, `library`, `database`, `plotter`, `slew`, `night`, `bw`, `clouds`, `failures`, `stall`,
  `crash`, `splash`, `pause`, `joystick`, `war`, `war-hook`, `demo`, `demo-key`, `demo-loop`,
  `restart`, `idle`) are the evidence of `features.md` and `coverage.md`.
- The `replay-*.txt` sessions are recorded and replayed by the replay tests (below).

## How the port is verified

Three levels, all in `Tests/DifferentialTests` (they need the disk image: `$FS2_D64`, then the
app's imported copy in `~/Library/Application Support/FS2/`; without one they are skipped):

1. **Routine diffs.** Each ported routine runs on many input states (realistic snapshots with
   randomized inputs, edge grids, exhaustive sweeps where feasible) next to the original on the
   lab (`DiffRig`, `Original.call`): the whole 64 KB image except the stack page, the registers a
   caller uses, the exact cycle count, and the SID stores where a routine makes them must be
   identical. Coverage traces of the original show which instructions and branch outcomes the
   suites reach; the subsystem docs list the few they cannot.
2. **Replays.** The lab records a session (`ReplayRecorder`, `fs2lab record`): it takes the
   interrupts only at the two poll sites and logs, per poll, the interrupts, the keys and
   joysticks, every I/O value read, and a memory hash at every top of the main loop ($204B).
   `ReplayDriver` gives the port exactly those inputs, and every checkpoint must match: memory,
   VIC and SID registers, color RAM, the latched raster split, and a golden frame presented with
   the split (`ReplayTests`, `ReplayModesTests`, `ReplayRestartTests`, and through `NativeEngine`
   in random time slices, `NativeEngineReplayTests`; `main-loop.md`).
3. **Golden frames.** The port's presented frame must equal the lab's pixel for pixel: the title
   (`NativeEngineBootTests`), every scenery area and view (`SceneryPassTests`), the editor's text
   screen (`EditorScreenTests`) and every replay checkpoint.

Run the tests with a wall-clock cap (`porting-guide.md`): `make test`, or
`Scripts/capped 600 swift test --filter <Suite>`, which kills the whole process group when the
time is up (check `pgrep -lf swiftpm-testing-helper` after a cap fires).

## Provenance

The first version was a read-only survey of the program: one report per subsystem, each
spot-checked against the program itself, with the spot checks' corrections taking precedence. The
lab sessions then confirmed or corrected the reports (`features.md`), the coverage work refined
the regions until every executed byte belonged to a documented routine (`coverage.md`), and the
port of each subsystem corrected the names and facts its differential tests disproved.
`open-questions.md` keeps the history of what was settled and how.
