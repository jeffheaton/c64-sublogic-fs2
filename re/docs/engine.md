# The native engine and the app integration

How the Mac app runs the port: `NativeEngine`, the `GameEngine` that boots the translated game
program from the user's disk and presents it frame by frame; Smooth pacing; the mode library on
the Mac; and the app's side (engine choice, options, key timing, headless runs). The game program
itself (main loop, interrupts, cold start, replay driver) is `main-loop.md`.

## Files

| File | What |
|---|---|
| `Sources/FS2Core/Game/GameEngine.swift` | The `GameEngine` protocol, `InputState`, `FrameOutput`, `Pacing`, `EngineOptions` |
| `Sources/FS2Core/Game/NativeEngine.swift` | The engine: boot, `run(untilCycle:)`, frames, input, options, key waits, replay mode |
| `Sources/FS2Core/Game/NativeEngineGate.swift` | The handshake between the host thread and the program thread |
| `Sources/FS2Core/Game/NativeEngineCore.swift` | The program-thread side: the hooks the port calls (event, poll, main-loop top, frame end) |
| `Sources/FS2Core/Game/NativeEngineInput.swift` | `JoystickSharing`: the CIA matrix of each frame (strict or shared joystick) |
| `Sources/FS2Core/Game/NativeEnginePresenter.swift` | The picture: the latched raster split, a frame without IRQs, text mode |
| `Sources/FS2Core/Game/SmoothRenderer.swift` | Smooth pacing |
| `Sources/FS2Core/Persistence/ModeLibraryFile.swift` | `ModeLibrary.bin`, the editor's library disk |
| `Sources/FS2App/Engine/*` | `EngineFactory` (native by default), `EngineHost`/`EngineLoop` (options, key timing), `EngineDebugging` |
| `Sources/FS2App/Input/KeyTiming.swift` | Minimum hold and release, CTRL before the key it modifies |
| `Sources/FS2App/Headless/*` | `FS2 --headless --engine native` |

## NativeEngine

### Boot

`NativeEngine(data:options:modeLibrary:)` builds `Machine.booting(blocks:)` (the stage-2 handoff)
and runs the cold start `coldStart()` ($A7E2): the boot loads (about 68.7 million cycles, 65 virtual
seconds, as long as the lab's 68.3 million: the loader's IEC time is charged), the title and the two
prompts exactly as the original draws them (the two records a cracker overwrote on modified copies
stay blank, `ColdImage.scrubCrack`), the panel, then the main loop for good. Nothing else is shown:
no banner, no intro. The screen during the boot loads is what the VIC shows then (text mode at $0400
over the loaded code, the border = the block being loaded), as in the lab; the app skips it
(`skipDiskLoading`).

### Threads

The port is straight-line code: the main loop, the scenery interpreter and the key waits never
return to a caller between frames. So the program runs on a thread of its own (64 MB stack, as
`ProgramThread`) and the host thread (the one that calls `run`) and the program take turns
(`NativeEngineGate`):

- `run(untilCycle: c)` sets the target, signals the program and waits; the program runs until it
  parks; the host handles the stop and resumes it until the clock has reached `c`.
- The program parks in `Machine.charge` (through `eventHandler`) when the clock reaches the
  target, at every frame end while frames are delivered, at the top of the main loop ($204B)
  while `onIteration` is set, at a key wait while `runToKeyWait` asks, at replay checkpoints, and
  for good when it ends.
- Exactly one thread runs at a time; every hand-over goes through a semaphore, so all writes of
  one side are visible to the other and `Machine` is never touched by both. Between `run` calls
  the program is parked, so the host may read the machine (and `poke`).
- **Determinism.** The wrapper around the scheduler's event handler calls the scheduler exactly
  when `Machine.charge` would without it: when the clock reaches the scheduler's own next event
  (as the scheduler set it, or as `cli()` lowered it), with the same progress guard, and never
  from a charge made inside the scheduler (it does not re-enter itself). Parking only blocks; the
  host changes the machine only at frame ends (input) or while the program is parked between
  runs. So the program computes the same thing however the time is sliced (tested with thousands
  of random slices).
- **The end.** The program thread ends when the engine goes away: it wakes up and calls
  `Thread.exit()`. Its frames are never unwound, so what they reference (the machine and the
  Smooth buffers, a few hundred KB) is leaked; the thread and its stack are released. In replay
  mode the program runs on the driver's `ProgramThread`: an engine dropped before the replay
  ended leaves it through `abandonStack`, which parks that thread for good (`ProgramThread`), and
  the engine's own thread then exits. The program also ends on a display-list fault
  (`endReason`); `run` then returns at once.
- **Long charges.** A routine that charges a long stretch at once (the loader charges each
  sector's IEC time in one go, about 22 frames) passes several frame ends inside one `charge`:
  the program parks at each of them in turn, so `run` returns after the first one with the clock
  already at the end of the charge, and the following `run` calls deliver the others one by one
  (the app's pacer waits for the wall clock to catch up first). The IRQ is held during a load,
  so those frames all show the same picture.

### Frames

At every frame end (the scheduler's `onFrameEnd`) the program applies the input and, while
`onFrame` is set, parks; the host presents the frame and calls `onFrame` with:

- `pixels`: `VICPresenter` geometry (384 × 248 palette indices), see "The picture";
- `frame`: the frame's index on the virtual clock (end cycle / 17,095);
- `sidWrites`: every SID store since the previous frame delivered, with its cycle (when no frame
  takes them the stream is cut to the last store of each register above 4,096 entries, so the
  audio still learns the register state);
- `monochrome`: `$0E69` = 0, the black and white display chosen at the title (the lab engine's
  rule).

**The picture** (`NativeEnginePresenter`):

- **The split.** The raster IRQ $2285 latches its two phases (`IO.viewRegion` at line $20,
  `IO.panelRegion` at line $A3). Raster lines $20-$A3 show the window state (multicolor, the
  bitmap `$22B0` names, the time-of-day border `$22B5`), all others the panel state (hi-res
  bitmap $4000, border $0C, the four attitude-indicator sprites). Line $A3 still shows the window:
  it is a badline (YSCROLL 3), the VIC takes 40 of its 65 cycles, and the panel phase's first store
  (the border) comes 28 cycles into the handler, on line $A4. The lab's per-line VIC shows the same
  (the title frame matches it pixel for pixel).
- **The frame in which a pass flips** after line $20 (`NativeEnginePresenter.HeldWindow`): the
  window phase latched the bitmap the old `$22B0` named, and the new pass already draws into it
  (the horizon pass repaints it first) while the VIC shows it until the next line $20. The
  horizon fill paints whole rows at about 370 cycles a row (41,000 or more for the 112 rows,
  `render3d.md`): from the horizon up to the top row, the rows the horizon crosses, then from the
  bottom row up to the horizon. The beam moves down a line every 65 cycles, so it shows the old
  picture in most of the window: only the rows just above the horizon (with no horizon, the
  lowest rows), which the fill reaches first, can already show the new sky. A picture of memory
  at the frame end would show the whole window repainted and half redrawn (in the WWI area the
  mountains vanish for one frame every pass). The port shows the old picture in the whole window:
  the window rows kept at the last frame end. The case is told apart from the alternate-pass
  tasks, which draw into the bitmap on display on purpose, by `$22B0`: it already names the other
  bitmap.
- **A frame without raster IRQs** (a disk load or the editor cache transfer holds them, so the
  jiffy `$34` did not move since the last frame presented): the registers stay as the last handler
  left them for the whole frame, one state on every line, the C64's look during loads.
- **One state for the whole frame** otherwise: the editor's text screen (vector $2304,
  `Machine.presentTextScreen` with `GameData.charROM` or the fallback font), and the boot before
  `displayInit`.

### Input

The `GameEngine` contract: `input` set before a frame ends is applied when that frame ends, before
`onFrame`; set inside `onFrame` or between runs, from the next frame end. At each frame end the
program thread writes the matrix to `io.keyboard`, which the frame IRQ's scan ($2418/$2505) reads,
and `input.restore` (cleared then) asks the scheduler for the NMI, taken at the next poll
(`main-loop.md`).

**Joysticks** (`JoystickSharing`, `EngineOptions.strictJoystick`). The keyboard and the joysticks
share CIA1's lines; the column sampler $2574 aborts the scan and the release check while a
joystick bit is low (`input.md`).

- Strict: the matrix as it is (the original: no key seen or released while a stick is deflected).
- Shared (the default): the scan phase `$08A6` says what the next frame IRQ does (1: it scans, 0:
  it checks releases). Before a scan the joysticks are hidden when a pressed key is in none of the
  held-key slots `$089B-$089E` (a new key; not when all four are taken); before a release check
  when a slot holds a key no longer pressed. Every other sampled frame shows them, so the stick is
  latched as before and the 5 Hz joystick action keeps its rate.

### Options

`options` (`EngineOptions`): `pacing` (Authentic, Smooth) and `strictJoystick`, read at the next
frame end (input) or presentation (pacing). Changing the pacing forgets Smooth's iterations.

### Key waits, the quick boot, debugging

- `runToKeyWait(maxFrames:deliverFrames:)` stops at the first poll of a key wait (`waitForKey`
  $2250: `$08BA` = 1 and `$08CC` ≠ 0 at its polls, a state the scenery interpreter never polls in)
  that is not the wait of the last stop: a key was dispatched since (the queue's read index `$08A8`
  moved; every key a wait gets ends it), or no key wait polled for over a million cycles (a
  restart's boot loads in between). The first stop after the boot is the title prompt. When the
  program is still parked at the key wait of the last stop and has not run since (a session's
  `pc:2250` right after the quick boot), it returns at once, as the lab's `pc:2250` stops at the
  PC it is at.
- `runToMainLoopTop(maxFrames:deliverFrames:)` stops at the top of the main loop ($204B, before a
  pass, where the lab's `pc:204B` stops); normal mode only.
- `skipDiskLoading()`: `runToKeyWait(9000, deliverFrames: false)`, then one frame (with all the SID
  stores made meanwhile).
- `poke`, `presentFrame()`, `machine` (read between runs), `onIteration` (the program parked at
  $204B), `smoothFrames` and `framesDelivered` (counters).

### Replay mode

`NativeEngine(replaying:on:from:)` runs the `ReplayDriver` (`main-loop.md`) on the program thread:
the interrupts, the keys and the I/O reads come from a lab recording, `input` and `options` are
ignored. The program parks at every matching checkpoint (`onCheckpoint(k, frame)`, the frame
presented from the machine there); from the first checkpoint on also at run targets and clock frame
ends (the driver turns `eventHandler` off before it starts, so the engine installs its hook at the
first checkpoint). The program ends after the last checkpoint or the first mismatch
(`replayOutcome`).

### The mode library

`Machine.modeLibraryIO` is the editor's hook for its library disk (logical block 64 on a separate
FS2-formatted disk in the original; `editor.md`): CTRL-X `load()`, CTRL-Z `formatAndSave(_:)`.
`ModeLibraryFile` maps it to `~/Library/Application Support/FS2/ModeLibrary.bin`, the 1024-byte
block image (user modes 10-24, 975 bytes used):

- load: the file's 1024 bytes; nil when there is no file or it has another size (the editor's
  disk-error line, as with no library disk);
- formatAndSave: the previous file is copied to `ModeLibrary.bak` first, the new block written
  atomically; false when it cannot be written (the disk-error line).

The app's engine uses `ModeLibraryFile.standard`; File ▸ Import / Export Mode Library go through
the same file (`GameLibrary`), so an import is what the next CTRL-X loads. A headless run keeps its
library in memory unless `--mode-library <path>` names a file. The calls happen on the program
thread, inside the editor, and block it (1 KB of file I/O).

## Smooth pacing

The simulation keeps the authentic cadence; every display frame the window is drawn again with
the camera interpolated between the last two completed main-loop iterations (`SmoothRenderer`).

What the original shows: pass k starts at $204B (s_k), integrates the flight (the camera c_k: the
eye position `$5A-$65`, three 32-bit words in 1/256 m, and the attitude `$6C-$71`, 16-bit binary
angles), builds the matrix, flips (the window then shows pass k-1's picture, drawn with c_(k-1))
and draws pass k's picture into the other bitmap.

- At every $204B the program thread keeps the memory and camera of the last two tops: M_k (at s_k,
  holding c_(k-1)) and M_(k+1) (at s_(k+1), holding c_k).
- At a frame end at t ≥ s_(k+1): f = (t − s_(k+1)) / (s_(k+1) − s_k), clamped to 0...1, the camera
  c_(k-1) + f·(c_k − c_(k-1)) (position words along their signed 32-bit difference, angles the
  shorter way round). A scratch `Machine` gets M_k (the start of the pass that drew with c_k) with
  that camera and `$0E6B` = 0, no event, poll or I/O hooks, and runs the window part of a pass:
  `plotterDisplay`, `setSceneryRoot`, `buildViewMatrix`, the flip's move of the window rows to the
  other bitmap (`$0E79` bit 0 skips it; points and lights are drawn over that bitmap's old
  picture), `horizonPass`, `runScenery`, `updateCompass` (the magnetic compass is drawn in the
  window, at (106, 114)), the war overlay's slot $A7EE when it is resident, `drawViewOverlay`.
  At f = 1 this is exactly pass k's picture; with a still camera every frame is the authentic one
  (tested). No tick runs (the polls find `$0E6B` = 0), a block the interpreter streams lands in
  the scratch memory only, and nothing reaches the real machine: memory at every iteration end is
  the Authentic run's (tested).
- The 112 window rows (14 character rows, $1180 bytes) the scratch drew replace those of the bitmap
  the real window shows, in a copy of the real memory, and the split is presented from that copy:
  the panel, the sprites and the borders are the real state.

The real window is shown instead before two iterations under the same overlay are recorded, when
the flight or war overlay is not resident, from $204B until the pass flips (the row table `$0200`
as at $204B: the window shows c_(k-1), the interpolation at f = 0), while the program draws into
the bitmap on display (the alternate-pass tasks: the ATIS teletype, the crash message, the course
plotter menu, the database info screen draw there before `$22B0` changes), and in frames without
raster IRQs. The flip frame shows the held window, as in Authentic (the picture of c_(k-1), the
interpolation at f = 0). A frame without the split (text mode) forgets the iterations.

Cost: one window pass, two 64 KB copies and one presentation per display frame. Measured with
`FS2 --headless --smooth` (release build) flying at Meigs: 20,130 redrawn frames cost 1.5 s more
than the Authentic run, about 75 µs per frame; a debug build takes about 30 ms per frame.

## The app

- **Engine choice** (`EngineFactory`): the native engine by default; `FS2_ENGINE=lab` or
  `--engine lab` selects the lab, `--engine native` (or `FS2_ENGINE=native`) the port.
- **Options** (`EngineHost`): View ▸ Pacing and Settings ▸ strict joystick go to the engine on its
  thread, at creation and whenever they change; View ▸ Display (monitor) is presentation only.
- **Quick boot**: the host runs the boot loads flat out (`skipDiskLoading`) with either engine.
- **Input mailbox** (`EngineHost`): the UI posts the player's matrix whenever it changes; the
  engine thread reads it once per slice. Every key pressed in any matrix posted since the last
  read is kept (`pressedSinceRead`), so a key pressed and let go again between two reads (a quick
  tap, or a key-down and key-up delivered together after the main thread stalled) still reaches
  the key timing as a press and is held its 4 frames.
- **Key timing** (`KeyTiming`, in `EngineLoop`; `input.md`): the matrix is sampled every fourth
  frame, so each key the player presses is in the matrix at least 4 frames and out at least 4
  frames before it goes in again (a double tap stays two taps); a key pressed with CTRL goes in
  only once CTRL has been in 4 frames (a letter and CTRL first seen in one scan would be read
  letter first, without the −$40), CTRL stays until such keys have been in 4 frames, and a key
  pressed without CTRL waits until CTRL has been out 4 frames (its release check cleared `$0E67`).
  A CTRL pressed in the same frame just after the key still counts. The restart sequence (Machine
  ▸ Restart) bypasses it. Headless runs drive the engine directly, unshaped.
- **Headless** (`FS2 --headless`, `HeadlessRunner`): `--engine native` (the default; `lab` in
  development builds only), `--quick-boot`, `--smooth`, `--strict-joystick`,
  `--mode-library <path>`, `--charrom <path>`, `--scale WxH`. The session steps on the native
  engine:
  - `wait`, `key`, `joy1`/`joy2`, `down`/`up` (keys held across steps), `nmi` (RESTORE, on the
    input of the next step, as the lab's player presses it) and `shot` go through `InputState`
    and the frame callback only, so both engines play a session the same way;
  - `poke`, `snap` (the lab's `Snapshot` format with zero registers), `peek`, `until` (the byte
    checked between runs of 1,000 cycles, where the lab checks it at every instruction) and
    `text` (the text screen at the VIC bank and screen base the port's I/O holds) go through
    `EngineDebugging`;
  - `pc:2250` stops at a key wait (`runToKeyWait`) and `pc:204B` at the top of the main loop
    (`runToMainLoopTop`); any other `pc:` address fails (the port has no program counter);
  - the lab's instrumentation steps `cov:` and `watch:` are skipped (and counted).

## Integration notes

Joining the game program with the editor and war overlays needed these changes:

| File | Change |
|---|---|
| `Display/InitDisplay.swift`, `Display/TextMode.swift` | $794E `fillColorRam` had been ported twice (identical memory, color RAM and 14,050 cycles), and the build failed with both. The display copy (`InitDisplay.swift`, the literal one) is kept and the editor's removed. |
| `Game/OverlaySlots.swift` | The bridge sites at the slots' jumps to $B09A and $AA03 replaced by `editorEntry()` and `warMain()` (the slot's jump was already charged there). |
| `Modes/EditorConversions.swift` | The bridge site `callOriginal($25EB)` in `recordToState` replaced by `displayInit()`. |
| `Game/InterruptScheduler.swift` | `masked` includes `Machine.modeLibraryIOActive` (the editor's library I/O, while it masks interrupts). |
| `Tests/DifferentialTests/EditorTests.swift` | A store to `$D019` among the original's I/O stores (`D2.apply`, which the editor rigs compare with) acknowledges the latch (`IO.acknowledgeVIC`) instead of setting the register shadow, as `IO` models it (the ported `displayInit` in `recordToState` stores $0F there). |

The flat-bus rigs need the port to read I/O as RAM (the ported 10 Hz tick reads `$DC09`) and its
I/O stores mirrored into its RAM image (the tick's SID stores); `DiffRig` does both for
every rig (`ioReadHook`, `mirrorIO`), so the war and editor rigs need nothing of their own.

No development bridge site remains in the game program, the editor or the war overlay, and the
tests no longer install the editor and war entries' lab bridge. The two defensive checks of the
scenery interpreter (op 0A to an unknown native target, `SceneryVM.swift`; a foreign ATIS hook
target, `SceneryRecords.swift`) are unreachable with the disk's lists and stop the program with an
error naming the address.

## Tests

| Suite | What |
|---|---|
| `NativeEngineBootTests` | The boot to the title in the lab's time (68.7 vs 68.3 million cycles), the title frame equal to the lab's per-line frame, pixel for pixel; the prompts answered, the flight overlay and passes at Meigs, the window and panel borders |
| `NativeEngineThreadTests` | A session (boot, prompts, flight with loads, RUN/STOP + RESTORE and the nested restart, the title again, the demo with its editor visit) played in one call per step and again in about 2,200 random slices of 1 to 60,000 cycles with frames and main-loop tops observed on the way: the same memory, clock, VIC/SID/CIA state, latched split, TOD, frames and SID write streams; engines dropped in every state end their threads |
| `NativeEngineReplayTests` | Headless parity in replay mode: lab recordings (take-off; crash with the editor's mode reload; Europe 1917: the editor opened with E and its key waits, EUROPE 1917 turned on, the war overlay loaded, war passes through slot $A7EE with the enemies' scenery-interpreter polls, W declaring war, the take-off roll) replayed through `NativeEngine` in random slices; every checkpoint's memory (the driver's hash) and frame equal to the lab's |
| `NativeEngineInputTests` | The `GameEngine` input contract (input set mid-frame is in the CIA from that frame's end, before `onFrame`; set inside `onFrame`, from the next frame end); flying at Meigs with the stick held left, strict loses an L typed meanwhile and keeps a key let go under the stick in its slot, shared toggles the lights once and frees the slot; the ailerons follow the stick in both |
| `NativeEngineSmoothTests` | Authentic and Smooth on the same input: identical memory at every main-loop top and at the end, identical panel rows, interpolated windows; with a still camera every Smooth frame equals the Authentic one, at Meigs and in Europe 1917 (the scratch pass runs the war slot $A7EE), with the main-loop tops of both runs identical, and the frames in which a pass flips after line $20 showing the frame before's window (the mountains do not vanish); the camera interpolation (wraps, shorter angles) |
| `FS2AppTests.KeyTimingTests` | Taps, double taps, re-presses, CTRL first (also when it comes just after the key), a key after CTRL, joysticks, through `EngineLoop` |
| `FS2AppTests.NativeAppTests` | On the native engine: a one-frame tap answers the title; CTRL+A pressed together is read as CTRL-A; Machine ▸ Restart through the engine loop; `FS2 --headless --engine native` with the title equal to the lab's; the mode library file hook |
| `FS2AppTests.EngineHostTests`, `AudioPathTests` | Options reach the engine (also a new one after a reset); a key pressed and let go between two mailbox reads is held 4 frames; engine resolution (native by default); headless options |
| `FS2AppTests.HeadlessRunnerTests`, `HeadlessSessionTests`, `HeadlessTests`, `LabParityTests` | The headless runner's input timing (each step covers exactly its frames), held keys and RESTORE (`down:`/`up:`/`nmi`) against the lab's player on both engines, the debugging steps on an engine without them, the instrumentation steps skipped; the runner and the app's engine loop against the original |
| `FS2AppTests.PacingTests` (`FS2_PACING=1`) | Authentic pacing in normal mode: the median pass of eight scenes within ±10% of the lab (the cost model on identical work is `ReplayMatrixTests`: ordinary passes take 0.932 of the lab's cycles, the share the lab's VIC DMA takes) |
| `FS2AppTests.PerformanceProbeTests` (`FS2_PERF=1`, release build, run alone) | CPU time per emulated second at Authentic pacing, the Smooth re-render cost per frame, the SID renderer's cost |

## Known limits

- RESTORE is taken at the next poll, not at once (`main-loop.md`); the restart sequence holds
  RUN/STOP, which pauses the game in a key wait that polls, so the NMI follows within a frame.
- A program thread that ends leaks its frames' references (the machine).
- Smooth pacing interpolates one pass behind the simulation (by construction: the original's window
  is a pass behind too), and draws nothing the alternate-pass tasks draw over the window.
