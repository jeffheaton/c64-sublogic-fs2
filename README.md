# Flight Simulator II for the Mac (C64 port)

A native macOS port of SubLogic's **Flight Simulator II** for the Commodore 64 (version 1.0, NTSC,
1984). This is an unofficial project, not affiliated with or endorsed by the rights holders (see
[Legal](#legal)).

**Play it in your browser: <https://www.heatonresearch.com/c64-sublogic-fs2/>**: the same port
compiled to WebAssembly (see [Web version](#web-version)). **How the original works:**
[ARCHITECTURE.md](ARCHITECTURE.md).

This is a translation of the original 6502 program into Swift, routine by routine. It is
**not an emulator**: no 6502 CPU is emulated and no disk drive either. The game's own routines run
as Swift code on the original memory layout with the original integer math, and only the C64's
output hardware is modeled: a VIC-II presenter turns the game's bitmaps into the picture, and a
6581 model written for this port plays the sound registers the game writes. So the port draws the
same pixels (the software rasterizer, the panel, the day and night palettes), flies the same flight
model and sounds the same. Differential tests run the translated routines against the original
program (in a dev-only 6502 lab) and compare the results byte for byte and pixel for pixel.

The repository and the app contain no copy of SubLogic's program or data files: no byte dumps,
disassembly listings or data tables. The program's bytes are read at run time from your own disk
image, which the app imports the first time it starts.

For a tour of how the original program works inside (the raster split, the 3D pipeline, the
scenery bytecode, the flight model and the rest), written for people who programmed the C64, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- A Mac with **macOS 15** (Sequoia) or later.
- To build: Xcode 16.3 or later, or the Swift 6.1 (or later) command-line tools. The package
  needs Swift tools version 6.1.
- **Your own disk image of Flight Simulator II version 1.0 for the Commodore 64 (NTSC)**: a
  `.d64` file, normally 174,848 bytes (the 175,531-byte form with error information and 40-track
  images are accepted too). Other releases, such as later versions or PAL disks, are not supported:
  the app checks each of the disk's 164 program blocks against version 1.0. See
  [Getting the disk image](#getting-the-disk-image).
- Optional: the C64's character generator ROM (`chargen`, 4096 bytes, a dump of the character ROM
  from your own C64). Only the editor's text screens use it; without it they use a look-alike font
  that comes with the app.
- Optional: a game controller.

## Getting the disk image

The app needs the game's disk as a `.d64` file. Image your own disk:

- With a 1541 drive, connect it to the Mac through a ZoomFloppy (or another XUM1541 adapter) and
  copy the disk with OpenCBM's `d64copy`.
- Without one, read the disk in any 5.25-inch drive with a flux reader such as a Greaseweazle or
  KryoFlux and convert the result to `.d64`.

Read errors outside the program blocks don't matter (the copy protection may cause some): the app
reads only SubLogic's 164 program blocks, and the protection check is not part of the port.

The app checks whatever image you give it, so you don't need to know in advance which release a
disk is: a later version or a PAL disk fails the check, and the alert says so. Copies with two
rows of the title screen overwritten still pass, because the check skips those few bytes; the app
then shows the two rows blank, since their original text is not on such a copy. An image of an
unmodified original disk keeps them.

## Building

```sh
make app      # release build without the lab, assembled into build/FS2.app (icon, Info.plist, ad-hoc signature)
make test     # unit and differential tests under a hard wall-clock cap (the differential ones need the .d64)
make audit    # builds the app, then audits the repository and the app's binary (needs the .d64)
make lab      # the dev-only lab CLI: .build/release/fs2lab
make clean    # remove build/ and SwiftPM's build products
```

`make app` builds the bundle and does not launch it. Open `build/FS2.app` from the Finder (or
with `open build/FS2.app`). To check a built bundle without launching it, run
`Packaging/check-app.sh build/FS2.app`: it verifies the Info.plist keys, the executable, the icon
and the ad-hoc signature (`codesign -dv`). `make app` also checks that the binary contains no lab
code.

Without `make`: `swift build -c release --product FS2 --disable-default-traits` builds the app's
executable as `make app` does, without the lab. Plain `swift build`, `swift run` and `swift test`
are development builds: they include the lab (the package trait `Lab`, on by default). Run tests
with a wall-clock cap (see [Differential and replay tests](#differential-and-replay-tests)).

## First run

1. Open the app. The welcome sheet asks for your disk image: click **Choose Disk Image…** and
   pick the `.d64` file.
2. The app checks the file in three steps and stops at the first one that fails, with an alert
   that marks each step passed (✓), failed (✗) or not reached (–) and says in plain words what
   was wrong and what to do:
   - **The file can be opened**: it exists and you can read it.
   - **It is a .d64 disk image**: its size is one of the four .d64 sizes above. A `.zip`
     archive, a `.g64`, `.t64` or `.prg` file fails here.
   - **It is Flight Simulator II version 1.0 for the Commodore 64**: every one of SubLogic's 164
     program blocks matches. When only a few blocks differ, the alert says the image looks like a
     damaged or modified copy; when most differ, that it is another disk. The disk's name and
     directory are not checked.
3. The app keeps a copy in `~/Library/Application Support/FS2/` and from then on starts straight
   into the game. **File ▸ Import Disk Image…** (⌘O) replaces it. Nothing is sent anywhere.
4. The game boots. The app skips the original's 65 seconds of disk loading and shows SubLogic's
   title screen. Answer WHAT DISPLAY ARE YOU USING? with **A** (color) or **B** (black and white),
   then SELECT OPERATING MODE with **A** (the demo, which flies itself until you press a key) or
   **B** (regular flight). Regular flight starts on runway 36 at Meigs Field, Chicago.

**File ▸ Import Character ROM…** adds the optional character ROM; it is used from the next cold
start (**Machine ▸ Reset**). If the imported disk copy ever fails its check at launch (for example
because the file was damaged), the app says which check failed and asks for the disk image again;
if the copy was deleted, the welcome sheet comes back as on the first run.

What the app keeps in `~/Library/Application Support/FS2/`:

| File | What |
|---|---|
| `FlightSimulatorII.d64` | The imported copy of your disk image |
| `chargen.rom` | The optional character ROM |
| `ModeLibrary.bin`, `ModeLibrary.bak` | The mode library and its previous version (see below) |

## Flying

**Help ▸ Flight Simulator II Help** (⌥⌘/) is a short guide to the game, and **Machine ▸ Keyboard
Reference** (⌘/) lists every key. A first flight:

1. Hold `;` for full throttle (or press `/` and then `;`, which jumps straight to full).
2. Watch the airspeed build, then press `B` a few times to lift the nose.
3. Trim with `V` (nose up) and `R` (nose down); bank with `F` and `H`; `G` centers the ailerons
   and rudder.
4. Look around with `5` followed by a key around `G` (`T` ahead, `B` back, `F` left, `H` right,
   `G` down); `4` shows the radar.

The keyboard behaves as on the C64, because the original's keyboard routine runs unchanged. It
reads the keyboard 15 times a second and acts on one key per tenth of a second. Each press moves a
control one step. A held key repeats after about 0.6 seconds and then 10 times a second, but only
the first two keys held repeat. The app holds every tap long enough for the C64 to see it, and for
a Control combination it puts CTRL down before the letter, as the C64 needs; just hold Control and
press the letter.

## Controls

Keys map by position to the C64 keyboard, and **⌘ shortcuts always go to the Mac menus**.

### Quick reference

At the title, answer **A** (color) or **B** (black and white), then **B** for regular flight
(**A** is the demo). You start on runway 36 at Meigs Field, Chicago.

**Flying**

| Keys | What |
|---|---|
| `T` / `B` | Elevator: nose down / nose up |
| `F` / `H` | Ailerons: bank left / bank right |
| `C` / `M` | Rudder left / right |
| `G` | Center the ailerons and rudder |
| `R` / `V` | Trim nose down / nose up |
| `Y` / `N` | Flaps up / down |
| `;` or Page Up | Throttle up |
| `'`, Page Down or Delete | Throttle down |
| `/`, then a throttle key | Straight to full throttle or idle |
| Space | Brakes (the guns in Europe 1917) |

Each press moves a control one step; hold a key to repeat it. Keypad 8, 2, 4 and 6 or a game
controller work as the yoke.

**Looking around**

| Keys | What |
|---|---|
| `5`, then `T` `Y` `H` `N` `B` `V` `F` `R` | Look ahead, front right, right, back right, back, back left, left, front left: the key's place around `G` points the way |
| `5`, then `G` | Look down (the bombsight in Europe 1917) |
| `4` | Radar view: `,` zooms out, `.` zooms in, `5` leaves it |

**Radios, engine and instruments**

| Keys | What |
|---|---|
| `,` / `.` | Decrease / increase the selected item (radio, transponder, OBS, ADF, mixture, fuel tank) |
| Control-C | COM radio (a quick second press selects the kHz) |
| Control-N, then `1` or `2` | NAV 1 or NAV 2 (a quick second press selects the kHz) |
| Control-V, then `1` or `2` | OBS 1 or OBS 2 |
| Control-X or Control-T | Transponder |
| `A` | ADF |
| Control-F | Fuel tank |
| Return, then `1` to `5` | Magnetos OFF, R, L, BOTH, START (Return, then `,` / `.` sets the mixture) |
| Control-I | Carburetor heat |
| `L` | Lights |
| Control-D | Realign the heading indicator with the compass |
| Control-B | Recalibrate the altimeter |

For a Control combination, hold Control and press the letter.

**Modes and the game**

| Keys | What |
|---|---|
| `P` or Esc | Pause (any key resumes) |
| `E` | The editor, the mode settings screens (`E` again leaves) |
| `=` | Recall the current mode (start the flight over from its settings) |
| `S` | Save the situation as a user mode |
| `Q` | Course plotter (a menu: `A` to `E`) |
| Control-E | Database info screen |
| `W`, `X`, Space | Europe 1917: declare war, drop a bomb, fire the guns |

**Mac shortcuts**

| Keys | What |
|---|---|
| ⌘P | Pause the whole machine, sound included |
| ⌘R | Restart (RUN/STOP + RESTORE): back to the title |
| ⇧⌘R | Reset (cold start) |
| ⌘2 to ⌘6, ⌘0 | Zoom, fit to the window |
| ⌃⌘F | Full screen |
| ⌘/ | Keyboard Reference (every key) |
| ⌥⌘/ | Flight Simulator II Help |

**Machine ▸ Demo Mode** starts the demo, and **View ▸ Pacing** switches between Authentic and
Smooth.

### Every key

The tables below are generated from the app's key map (`Sources/FS2App/Input/KeyMapper.swift`) and the
original's command table as documented in `re/docs/input.md`. The Keyboard Reference window shows
the same tables. To regenerate them after changing the key map, replace the block between the
markers with the output of `.build/debug/FS2 --key-reference`; a test fails while the README is
out of date. Another test checks the command codes against the original's own tables on your disk.

<!-- BEGIN KEYBOARD REFERENCE: generated by `FS2 --key-reference`; do not edit by hand -->

### Keyboard

| Mac | Commodore 64 | In Flight Simulator II |
|---|---|---|
| `A` | `A` | ADF: select the first frequency digit; quick repeats select the next digits, then the fuel tank |
| `B` | `B` | Elevator up (nose up). After 5: look back. Slew: south |
| `C` | `C` | Rudder left |
| `D` | `D` | No function in the game |
| `E` | `E` | Open the editor (the mode settings screens). In the editor: leave the editor |
| `F` | `F` | Ailerons left (bank left). After 5: look left. Slew: west |
| `G` | `G` | Center the ailerons and rudder. After 5: look down (the bombsight in Europe 1917). Slew: stop all motion |
| `H` | `H` | Ailerons right (bank right). After 5: look right. Slew: east |
| `I` | `I` | No function in the game |
| `J` | `J` | No function in the game |
| `K` | `K` | No function in the game |
| `L` | `L` | Lights on/off |
| `M` | `M` | Rudder right |
| `N` | `N` | Flaps down. After 5: look back right. Slew: heading rate down |
| `O` | `O` | No function in the game |
| `P` | `P` | Pause (the next key resumes) |
| `Q` | `Q` | Course plotter (a menu: A to E) |
| `R` | `R` | Trim nose down. After 5: look front left. Slew: bank rate up |
| `S` | `S` | Save the situation as a user mode (the current mode + 10). In the editor: save the situation as a user mode |
| `T` | `T` | Elevator down (nose down). After 5: look ahead. Slew: north |
| `U` | `U` | No function in the game |
| `V` | `V` | Trim nose up. After 5: look back left. Slew: heading rate up |
| `W` | `W` | Declare war (Europe 1917) |
| `X` | `X` | Drop a bomb (Europe 1917) |
| `Y` | `Y` | Flaps up. After 5: look front right. Slew: bank rate down |
| `Z` | `Z` | Slew: zero the pitch, bank and heading |
| `1` | `1` | After Return: magnetos OFF. After Control-N: NAV 1. After Control-V: OBS 1. In the editor: type a digit |
| `2` | `2` | After Return: magnetos R. After Control-N: NAV 2. After Control-V: OBS 2. In the editor: type a digit |
| `3` | `3` | Magnetos L (no Return needed). In the editor: type a digit |
| `4` | `4` | Radar view (, and . zoom, 5 leaves it). After Return: magnetos BOTH. In the editor: type a digit |
| `5` | `5` | View select: then T Y H N B V F R G picks the view. Leaves the radar view. After Return: START. In the editor: type a digit |
| `6` | `6` | In the editor: type a digit |
| `7` | `7` | In the editor: type a digit |
| `8` | `8` | Slew: pitch rate down. In the editor: type a digit |
| `9` | `9` | Slew: pitch rate up. In the editor: type a digit |
| `0` | `0` | In the editor: type a digit |
| `,` | `,` | Decrease the selected item (radio, transponder, OBS, ADF, mixture, fuel tank). Radar: zoom out |
| `.` | `.` | Increase the selected item. Radar: zoom in |
| `/` | `/` | The next throttle key goes straight to full or idle |
| `Space` | `SPACE` | Brakes on the ground; guns in the air (Europe 1917) |
| `Return` | `RETURN` | Magnetos and mixture: then 1-5 sets the magnetos (OFF, R, L, BOTH, START), , and . the mixture. In the editor: next line (accepts the number typed) |
| `;` | `;` | Throttle up. Slew: altitude rate up |
| `'` | `:` | Throttle down. Slew: altitude rate down. In the editor: delete the last digit |
| `=` | `+` | Recall the current mode (start the flight over from its settings). In the editor: recall the current mode |
| `-` | `-` | In the editor: previous line |
| `[` | `@` | No function in the game |
| `]` | `*` | No function in the game |
| `\` | `£` | No function in the game |
| `` ` `` | `←` | Throttle down. Slew: altitude rate down. In the editor: delete the last digit |
| `§` | `←` | Throttle down. Slew: altitude rate down. In the editor: delete the last digit |
| `Esc` | `RUN/STOP` | Pause (the next key resumes) |
| `Home (fn ←)` | `CLR/HOME` | Open the editor (the mode settings screens) |
| `Delete` | `INST/DEL` | Throttle down. Slew: altitude rate down. In the editor: delete the last digit |
| `Help / Insert` | `INST (SHIFT + INST/DEL)` | Throttle down. Slew: altitude rate down. In the editor: delete the last digit |
| `End (fn →)` | `↑` | In the editor: previous line |
| `Forward Delete (fn Delete)` | `=` | No function in the game |
| `Left Control` | `CTRL` | Hold for the Control combinations below (the C64's CTRL commands) |
| `Right Control` | `CTRL` | Hold for the Control combinations below (the C64's CTRL commands) |
| `Left Shift` | `RIGHT SHIFT` | Nothing (the game ignores it) |
| `Right Shift` | `RIGHT SHIFT` | Nothing (the game ignores it) |
| `Left Option` | `C=` | No function in the game |
| `Right Option` | `C=` | No function in the game |
| `→` | `CRSR →` | No function in the game |
| `↓` | `CRSR ↓` | No function in the game |
| `←` | `CRSR ← (SHIFT + CRSR →)` | No function in the game |
| `↑` | `CRSR ↑ (SHIFT + CRSR ↓)` | No function in the game |
| `Page Up (fn ↑)` | `;` | Throttle up. Slew: altitude rate up |
| `Page Down (fn ↓)` | `:` | Throttle down. Slew: altitude rate down. In the editor: delete the last digit |
| `F1` | `F1` | No function in the game |
| `F2` | `F2 (SHIFT + F1)` | No function in the game |
| `F3` | `F3` | No function in the game |
| `F4` | `F4 (SHIFT + F3)` | No function in the game |
| `F5` | `F5` | No function in the game |
| `F6` | `F6 (SHIFT + F5)` | No function in the game |
| `F7` | `F7` | No function in the game |
| `F8` | `F8 (SHIFT + F7)` | No function in the game |
| `Keypad .` | `.` | Increase the selected item. Radar: zoom in |
| `Keypad *` | `*` | No function in the game |
| `Keypad /` | `/` | The next throttle key goes straight to full or idle |
| `Keypad =` | `=` | No function in the game |
| `Keypad Clear` | `CLR/HOME` | Open the editor (the mode settings screens) |

### Control combinations

| Mac | Commodore 64 | In Flight Simulator II |
|---|---|---|
| `Control-A` | `CTRL + A` | ADF: select the first frequency digit; quick repeats select the next digits, then the fuel tank |
| `Control-B` | `CTRL + B` | Recalibrate the altimeter (clears its drift) |
| `Control-C` | `CTRL + C` | COM radio: select the MHz; a quick second press selects the kHz |
| `Control-D` | `CTRL + D` | Realign the heading indicator (DG) with the compass |
| `Control-E` | `CTRL + E` | Database info screen (the scenery areas on the disk) |
| `Control-F` | `CTRL + F` | Select the fuel tank (, and . switch tanks) |
| `Control-H` | `CTRL + H` | Throttle down. Slew: altitude rate down. In the editor: delete the last digit |
| `Control-I` | `CTRL + I` | Carburetor heat on/off |
| `Control-L` | `CTRL + L` | Lights on/off |
| `Control-M` | `CTRL + M` | Magnetos and mixture: then 1-5 sets the magnetos (OFF, R, L, BOTH, START), , and . the mixture. In the editor: next line (accepts the number typed) |
| `Control-N` | `CTRL + N` | NAV radio: select the MHz (then 1 or 2 picks NAV 1 or NAV 2); a quick second press selects the kHz |
| `Control-Esc` | `CTRL + RUN/STOP` | Pause (the next key resumes) |
| `Control-P` | `CTRL + P` | Pause (the next key resumes) |
| `Control-T` | `CTRL + T` | Transponder: select the digits (as Control-X). Slew: copy the view angles back into the attitude |
| `Control-U` | `CTRL + U` | Throttle up. Slew: altitude rate up |
| `Control-V` | `CTRL + V` | OBS: select the course (then 1 or 2 picks OBS 1 or OBS 2) |
| `Control-X` | `CTRL + X` | Transponder: select the first digit; quick repeats select the next digits, then the OBS. In the editor: load the mode library file |
| `Control-Z` | `CTRL + Z` | In the editor: save the mode library file |

### Keypad as joystick (Settings)

| Mac | Commodore 64 | In Flight Simulator II |
|---|---|---|
| `Keypad 8` | `Joystick 1 up` | Nose down (like T) (keypad-as-joystick off: 8) |
| `Keypad 2` | `Joystick 1 down` | Nose up (like B) (keypad-as-joystick off: 2) |
| `Keypad 4` | `Joystick 1 left` | Bank left (like F) (keypad-as-joystick off: 4) |
| `Keypad 6` | `Joystick 1 right` | Bank right (like H) (keypad-as-joystick off: 6) |
| `Keypad 7` | `Joystick 1 up+left` | Nose down (like T), bank left (like F) (keypad-as-joystick off: 7) |
| `Keypad 9` | `Joystick 1 up+right` | Nose down (like T), bank right (like H) (keypad-as-joystick off: 9) |
| `Keypad 1` | `Joystick 1 down+left` | Nose up (like B), bank left (like F) (keypad-as-joystick off: 1) |
| `Keypad 3` | `Joystick 1 down+right` | Nose up (like B), bank right (like H) (keypad-as-joystick off: 3) |
| `Keypad 5` | `Joystick 1 fire` | View select (like 5) (keypad-as-joystick off: 5) |
| `Keypad 0` | `Joystick 1 fire` | View select (like 5) (keypad-as-joystick off: 0) |
| `Keypad +` | `Joystick 2 up` | Throttle up (keypad-as-joystick off: +) |
| `Keypad -` | `Joystick 2 down` | Throttle down (keypad-as-joystick off: -) |
| `Keypad Enter` | `Joystick 2 fire` | Guns (Europe 1917) (keypad-as-joystick off: RETURN) |

### Game controller

| Mac | Commodore 64 | In Flight Simulator II |
|---|---|---|
| `Left stick or D-pad` | `Joystick 1` | The yoke: nose down/up (like T/B), bank left/right (like F/H) |
| `A button` | `Joystick 1 fire` | View select (like 5) |
| `Right stick up / down` | `Joystick 2 up / down` | Throttle up / down |
| `B button or right trigger` | `Joystick 2 fire` | Guns (Europe 1917) |

### Prompts and menus in the game

| Mac | Commodore 64 | In Flight Simulator II |
|---|---|---|
| `A / B` | `A / B` | Title, WHAT DISPLAY ARE YOU USING?: A color, B black and white |
| `A / B` | `A / B` | SELECT OPERATING MODE: A the demo (any key takes over), B regular flight |
| `A to E` | `A to E` | Course plotter menu (Q): A record, B show the plot, C precise recording, D off, E back to flight |
| `Any key` | `Any key` | Ends the pause and the database info screen (the key is used up) |

### Mac shortcuts

| Mac | Commodore 64 | In Flight Simulator II |
|---|---|---|
| `⌘P` | `—` | Pause or resume the whole machine, sound included (Machine ▸ Pause) |
| `⌘R` | `RUN/STOP + RESTORE` | Restart the program: back to the title after the reload (Machine ▸ Restart) |
| `⇧⌘R` | `Power off and on` | Cold start without the disk loading wait (Machine ▸ Reset) |
| `⌘/` | `—` | This keyboard reference |
| `⌥⌘/` | `—` | Flight Simulator II Help |

### Not mapped

| Mac | Commodore 64 | In Flight Simulator II |
|---|---|---|
| `(none)` | `LEFT SHIFT` | LEFT SHIFT gives the same code as CTRL-A (ADF select), so both Mac Shift keys act as RIGHT SHIFT, which the game ignores. The ADF stays on A. |

<!-- END KEYBOARD REFERENCE -->

Notes on the tables:

- **Keypad as joystick** is on by default (**Settings ▸ Use the keypad as joysticks**); turned off,
  the keypad types the C64 keys shown in parentheses. Joystick 1 is the yoke; joystick 2 is the
  throttle and the guns.
- **Strict joystick** (**Settings**, off by default): on the C64 a deflected joystick blocks the
  keyboard, so keys pressed while you steer are lost. Off, the app keeps the keys working while a
  stick is held; on, it behaves exactly like the original.
- **Game controllers** are any controllers macOS supports as extended gamepads; a stick counts as
  pushed past half its travel, like the digital joystick the game expects.

## Menus

- **Flight Simulator II**: About, Settings… (⌘,): the keypad as joysticks, strict joystick, game
  controllers, sound and volume.
- **File**: Import Disk Image… (⌘O), Import Character ROM…, Import Mode Library…, Export Mode
  Library…, Close Window (⌘W; closing the game's window quits, since the window is the machine).
- **View**:
  - **Zoom 2× to 6×** (⌘2 to ⌘6): integer scaling with sharp pixels. **Fit Window** (⌘0) scales the
    picture to the window (resizing the window by hand turns it on), with sharp bilinear
    filtering for fractional sizes. **Enter Full Screen** (⌃⌘F).
  - **Aspect**: **NTSC TV (0.75 Pixel Aspect)** shows the C64's pixels narrower than tall, as on a
    US television (exact at zoom 3 and 6); **Square Pixels**.
  - **Pacing**: **Authentic** or **Smooth (60 fps)**, below.
  - **Display**: **Color Monitor** or **Black & White Monitor**. This is presentation only: the
    black-and-white monitor shows every color as its VIC-II luma gray. It is separate from the
    game's own B answer at the title, which switches the game to its black-and-white palette (shown
    in gray automatically).
- **Machine**: **Pause** (⌘P) stops the whole machine and its sound. **Restart (RUN/STOP +
  RESTORE)** (⌘R) presses those keys the way a player would; the program reloads at the original
  disk speed (about 73 seconds) and comes back to the title. **Reset (Cold Start)** (⇧⌘R) starts
  a fresh machine and skips the loading. **Demo Mode** gives the mode prompt's demo answer (A)
  from regular flight; any key takes over, as in the original. **Keyboard Reference…** (⌘/).
- **Help**: Flight Simulator II Help (⌥⌘/), Keyboard Reference. ⇧⌘/ (⌘?) is macOS's Help menu
  search.

### Pacing: Authentic and Smooth

The C64 version has no frame sync. Its main loop draws the out-the-window view as fast as it can,
and the window shows a new picture only when a pass is complete. Measured in the lab, which runs
the original program: at Meigs on the ground a pass takes about 1.2 million cycles, about 70 NTSC
frames, so the window changes **about 0.85 times a second**. Over a take-off and climb the mean was
79 frames a pass (0.76 pictures a second) and the fastest 46 frames (1.3 a second).

- **Authentic** (the default) keeps that: each pass costs the original's cycles on the port's
  virtual NTSC clock (1,022,727 Hz, 17,095 cycles a frame, 59.83 frames a second), and the app
  shows the frames at the C64's rate.
- **Smooth** keeps the same simulation (the memory at every main-loop pass is identical to an
  Authentic run; this is tested) but redraws the window at **every display frame, 59.83 times a
  second**, on a scratch copy of the machine, with the camera interpolated between the last two
  passes. A redraw costs about 70 µs in a release build, so Smooth holds the full frame rate: a
  headless run of 339 virtual seconds took 4.8 s with Smooth and 3.9 s without. It runs one pass
  behind, as the original's window does, and the screens the game draws into the window itself
  (the ATIS teletype, the crash message, the course plotter menu, the database screen) appear at
  the authentic cadence.

## The mode library

User modes 10 to 24 live in the C64's memory, as in the original: **S** saves the situation as a
user mode; in the editor (**E**), typing 110 to 124 into USER MODE saves to mode 10 to 24, and 0 to
24 recalls a mode. To keep them:

- In the editor, **Control-Z** saves all user modes to `~/Library/Application Support/FS2/ModeLibrary.bin`,
  the 1024-byte image of logical block 64 of the original's library disk (975 bytes used). The
  previous file is kept as `ModeLibrary.bak`. The original formatted the floppy in the drive and
  wrote the block there; the port writes the file and formats nothing.
- In the editor, **Control-X** loads them back. With no library file (or a file of another size)
  the editor shows its own disk-error line, as the original did without a library disk.
- **File ▸ Import Mode Library…** replaces the file (the previous one becomes the backup), so the
  next Control-X loads it; **Export Mode Library…** copies it out.

Headless runs keep their library in memory unless `--mode-library <path>` names a file.

## Known deviations from the original

- **The call to $FD00 is a no-op.** In Europe 1917, R makes the main loop call `$FD00`, the
  war-mode hook. On the disk that memory is empty, and on a C64 the call runs into uninitialized
  memory (a chain of break interrupts that runs into a buffer whose contents depend on how the
  lights were used at night). That is undefined behavior, not part of the game's design, so the
  port returns at once. See `re/docs/excluded.md`.
- **NTSC only**, like version 1.0: the NTSC CPU clock and 60 Hz frame timing. PAL disks are not
  supported.
- **Disk speed.** At launch and on Reset the app skips the boot's 65 seconds of loading.
  Everything else loads at the original 1541 speed, as on the C64: scenery blocks while flying
  (about 1.6 s each; the picture holds meanwhile), the editor and Europe 1917 overlays, and the
  reload after Restart or after leaving Europe 1917 (about 73 seconds back to the title).
- **No disk errors.** Blocks come from the imported copy, so the original's disk-error prompt and
  error screen are not part of the port. The mode library's errors show the editor's own
  disk-error line.
- **Not ported:** SubLogic's copy protection, its disk loader, its debug monitor and build
  leftovers, and anything a modified copy of the disk adds (`re/docs/excluded.md`).
- **LEFT SHIFT has no Mac key.** On the C64 it gives the same code as CTRL-A (ADF select), so both
  Mac Shift keys act as RIGHT SHIFT, which the game ignores. The ADF is on A.
- **Shared joystick lines.** Unless Strict joystick is on, the keyboard keeps working while a
  joystick is deflected.
- **RESTORE** is taken at the program's next poll point (where it checks for its tenth-of-a-second
  tick), not at the exact cycle. Machine ▸ Restart holds RUN/STOP, which pauses the game in a key
  wait that polls all the time, so the restart follows within a frame.
- **Character set.** Without an imported character ROM the editor uses a look-alike font.
- **Smooth pacing** is an addition; Authentic is the original's behavior.

## Web version

The same port runs in a browser, online at <https://www.heatonresearch.com/c64-sublogic-fs2/>. `fs2.wasm` (the core, the shared host and a WebAssembly entry
point) runs in a Web Worker; a small page (`web/`, plain modules, no build step) draws the frames,
plays the SID through an AudioWorklet and passes the keyboard on. WebAssembly has no threads, so
the engine runs **inline**: the translated program runs on the worker's own stack, and at every
frame end it hands over to the same host step the Mac app's engine thread uses (`FS2Host`), which
applies the controls, posts the picture and the sound, and sleeps (`Atomics.wait`) until the next
frame is due. Inline and threaded runs compute exactly the same frames, sound and memory
(`NativeEngineInlineTests`, `InlineHostTests`), and so do the native and wasm builds
(`make web-check`).

It needs a desktop browser with a keyboard: a current Chrome, Edge, Firefox or Safari. The page
uses `SharedArrayBuffer`, which needs cross-origin isolation: a server that sends the COOP and COEP
headers, or, on hosts that cannot (GitHub Pages), the page's service worker (`isolation-sw.js`),
which adds them and reloads the page once on the first visit. Private windows that block service
workers cannot run it there.

### Building it

The wasm build uses swift.org's toolchain through [swiftly](https://www.swift.org/install/macos/)
(Xcode's cannot build for WebAssembly) and the matching Swift SDK, pinned in `web/toolchain.env`:

```sh
swiftly install 6.4.1
swiftly run +6.4.1 swift sdk install <WASM_SDK_URL> --checksum <WASM_SDK_CHECKSUM>   # web/toolchain.env
brew install binaryen   # wasm-opt: fs2.wasm 13 MB to 5 MB (optional)

make web-disk    # the deploy disk, from $FS2_D64 or the app's imported copy
make web         # build/web: the page, fs2.wasm and the deploy disk
make web-serve   # http://localhost:8064
make web-audit   # the shipping audits on fs2.wasm and the deploy disk
make web-check   # native and wasm compute the same, and 30 nested restarts as wasm (needs Node)
make web-core    # only the core modules for wasm: the portability check after core changes
```

`make web-disk` writes a 35-track image with only the 656 sectors behind the port's 164 logical
blocks (no directory, no BAM, nothing of a modified copy's boot loader) and the modified copy's
text blanked with the rule the cold start applies. The port builds exactly the same machine from
it (`DeployDiskTests`); it is no use outside the port. Without a disk next to it, the page asks
for the visitor's own, checks it like the Mac app and keeps it in the browser.

### Deploying to GitHub Pages

`.github/workflows/web.yml` (Actions ▸ Deploy web build ▸ Run workflow) builds the page and
`fs2.wasm`, downloads the deploy disk from a release, checks its SHA-256 and publishes the folder.
Run `make web-audit` and `make web-check` first. One-time setup:

1. Settings ▸ Pages ▸ Source: **GitHub Actions**. Pages for a private repository needs a paid
   plan; the published site is public either way.
2. A release holding the `FlightSimulatorII.d64` that `make web-disk` wrote, tagged `web-disk` in
   this repository (release files are not in git, and they are as visible as the repository). For
   a public repository, use a separate private one instead: set the variable `FS2_ASSETS_REPO`
   (owner/name, and `FS2_ASSETS_TAG` if not `web-disk`) and the secret `FS2_ASSETS_TOKEN`, a
   fine-grained token with read access to its contents.
3. The variable `FS2_DISK_SHA256`: the SHA-256 that `make web-disk` prints.

### Known limits

- Windows and Linux browsers keep Ctrl+N, Ctrl+T and Ctrl+W for themselves, so the NAV radio
  and transponder commands (Ctrl+N, Ctrl+T) do not reach the game there; in full screen, Chrome and
  Edge pass them on (Keyboard Lock). Browsers on macOS use ⌘ and are not affected.
- Esc is RUN/STOP. In full screen, Chrome and Edge pass it on too (hold Esc to leave full
  screen); other browsers leave full screen.
- Not yet in the web version: game controllers, the character ROM import, and importing or
  exporting the mode library (the library the editor saves is kept in the browser).

## Development

The port is checked against the original program at every level. These are the tools.

### Layout

| Path | What |
|---|---|
| `Sources/C64Kit` | C64 hardware models: palette, VIC-II frame presenter, 6581 SID, keyboard matrix, D64 reader |
| `Sources/FS2Data` | SubLogic's 1 KB logical-block disk format, the cold-start memory image, disk validation |
| `Sources/FS2Core` | The port: translated routines working on the original memory layout (`Machine`), and `NativeEngine`, which runs them |
| `Sources/FS2Host` | What every host of the engine shares: key map and timing, keyboard reference, restart sequence, demo, SID renderer, frame pacing and the per-frame host step |
| `Sources/FS2App` | The Mac app: window, menus, audio output, game controllers, settings, first run, headless mode |
| `Sources/FS2Web`, `Sources/CFS2Web`, `web/` | The web version: `fs2.wasm`'s entry point, the page's imports, and the page |
| `Sources/fs2disk`, `Sources/fs2check` | The web deploy's disk image, and the native-versus-wasm determinism check |
| `Sources/M6502`, `Sources/FS2LabKit`, `Sources/fs2lab` | The **lab**, a dev-only verification oracle |
| `Packaging` | Info.plist, the icon generator, the bundle checker |
| `Tests` | Unit tests, the app's tests, the differential tests and the shipping audits |
| `Scripts` | `capped` (the wall-clock cap for test runs, below) and the screenshot gallery (`Scripts/gallery/gallery.sh`) |
| `re/` | The reverse-engineering corpus (below) |

### The lab

`fs2lab` is a cycle-counted 6502 core with a C64 bus (a VIC-II line model, CIA keyboard,
joysticks and time of day, a SID register log) and a virtual 1541 that serves SubLogic's own
loader calls from the imported blocks. It starts from the state SubLogic's stage 2 leaves (no other
boot code on the disk runs) and runs the original program. It is the oracle the port is compared
with; playing the game does not use it.

The lab exists only in development builds. `swift build`, `swift run` and `swift test` link it
(the package trait `Lab`, on by default), and so does `make lab`; `make app` builds the app with
`--disable-default-traits`, so the shipped app contains no lab code and has no `--engine lab`.

```sh
make lab
.build/release/fs2lab run "$D64" out/ @re/sessions/takeoff.txt       # play a session, write screenshots
.build/release/fs2lab loop "$D64" @re/sessions/takeoff.txt           # main-loop pass timing
.build/release/fs2lab profile "$D64" @re/sessions/regular.txt 600    # where the cycles go
.build/release/fs2lab call <snapshot> <addr> a=.. x=.. y=..          # run one original routine
# also: record (replay logs), coverage, listing (annotated disassembly), symbols-check
```

Run it without arguments for the full usage. Sessions are scripts of steps (`wait:N`,
`key:NAME:N`, `joy1:up+fire:N`, `shot:NAME`, `snap:NAME`, `pc:ADDR`, …); the base sessions are in
`re/sessions/`. A development build of the app can run on the lab too: `FS2_ENGINE=lab` or
`--engine lab` (the window title then says so).

### Headless runs

```sh
swift build -c release --product FS2
.build/release/FS2 --headless --engine native --screenshot-dir out/ --d64 "$D64" \
    --session "pc:2250:9000 key:A:12 pc:2250:600 key:B:12 pc:204B:3000 wait:1800 shot:meigs key:;:150 wait:540 shot:roll"
# options: [--quick-boot] [--smooth] [--strict-joystick] [--mode-library <path>]
#          [--charrom <path>] [--scale WxH]
```

plays a session as fast as possible without a window and writes each `shot:` as a PNG. This is
how the port is compared with the lab frame for frame. `--session` takes the steps themselves or
`@file`. The native engine runs the steps `wait`, `key`, `joy1`/`joy2`, `down`/`up` (keys held
across steps), `nmi` (RESTORE), `shot`, `poke`, `snap`, `peek`, `until` and `text`, and `pc:` at
the two places the port can stop: `pc:2250` (the key wait) and `pc:204B` (the top of the main
loop). Any other `pc:` address is an error on the native engine (it has no program counter), and
its `until:` checks the byte between slices of the run rather than at every instruction.
`--engine lab` (development builds only) stops at any `pc:` address. The lab's instrumentation
steps `cov:` and `watch:` are skipped. So the files in `re/sessions/` run headless too, all but
`failures.txt` (which stops at `pc:EB1B`) also on the native engine. Without `--quick-boot` a
session starts at the boot's disk loads (about 3,900 frames before the title prompt), as
`fs2lab run` does. The shipped app's executable (`build/FS2.app/Contents/MacOS/FS2`) has the same
headless mode, with the native engine only. The native engine runs about 85 times faster than
real time in a release build. `FS2 --key-reference` prints the controls tables above, and
`FS2 --version` the About text.

### Differential and replay tests

- **Routine diffs** run an original routine (in the lab's 6502 core) and its translation on the
  same randomized memory states and compare the whole memory, the registers and the cycles.
- **Replay diffs** record a lab session's inputs and interrupt schedule, replay it through
  `NativeEngine` in random time slices, and compare the memory and the presented frame at every
  checkpoint.
- **Golden frames** compare screenshots of the lab and the port: zero differing pixels.

The differential tests look for the disk image in `$FS2_D64`, then the app's imported copy in
`~/Library/Application Support/FS2/`, and are skipped without one.
Always run tests with a wall-clock cap (`make test` has one): a translated routine waits on game
state the way the original does, so a test that never supplies it would spin forever instead of
failing. `Scripts/capped SECONDS COMMAND…` runs a command in its own process group and kills the
whole group when the time is up (exit status 142), so no `swiftpm-testing-helper` outlives the
cap. For one suite:

```sh
Scripts/capped 600 swift test --filter KeyReferenceTests
```

After a cap fires, `pgrep -lf swiftpm-testing-helper` should find nothing left of that run.

### Shipping audits

The shipping audits (`re/docs/excluded.md`) read the disk image at test time and write none of its
bytes. `make audit` builds the app and runs them over the repository and the app's binary.

- **Bytes.** `SubLogicBytesAuditTests` checks that no file and no part of the binary holds a run
  of 12 or more of the disk's bytes, written raw or in any common encoding: hex, decimal or binary
  byte lists, hex words and strings, base64. Quoted screen text is allowed in the notes under
  `re/`; everywhere else only a short, reviewed list of on-screen labels may be quoted (prompts, a
  menu heading, editor fields: each at most 40 characters, listed in the test with where it
  appears in the game), so the README, the help and the keyboard reference can name what the
  player sees.
- **Modified copies.** `CrackExclusionTests` checks that the text a modified copy of the disk
  adds (two title rows, a tag in the disk-error line and a boot banner) is named in no file of
  the repository and not in the binary, that the import scrub blanks it in the memory the port
  starts from, and that the port's title screen shows nothing in those two rows.
- **Instruction listings.** `SubLogicBytesAuditTests` also assembles every run of 6502
  instructions written out in any file (comments, notes, data) and fails when 12 or more of the
  resulting bytes occur in one piece on the disk. No file may hold a listing of the original's
  code: comments describe behavior in prose (`re/docs/porting-guide.md`).

The audits look for copies of the program, not for similarity to it: the port is a translation, so
its routines follow the original's logic by design.

`make web-audit` runs them on the web build: `fs2.wasm` and the deploy disk (see
[Web version](#web-version)).

### The `re/` corpus

| Path | What |
|---|---|
| `re/symbols.json`, `re/symbols.d/` | Names, types and specifications of every region, variable, routine and table (addresses and descriptions only) |
| `re/docs/` | Write-ups per subsystem. Start with `porting-guide.md` (the rules for translating a routine), then `engine.md` and `main-loop.md`; `input.md`, `editor.md`, `excluded.md` and the others cover the rest |
| `re/sessions/` | Lab and headless session scripts |
| `re/out/` | Annotated listings made by `fs2lab listing`; git-ignored, because they contain SubLogic bytes |

Nothing committed is a copy of the program or its data: no byte dumps, disassembly listings,
tables or bitmaps. The corpus describes the program by address, name and behavior.

## Legal

This is an unofficial project, not affiliated with or endorsed by the rights holders. Flight
Simulator II was written by Bruce Artwick and published by SubLogic in 1984. All rights belong to
their respective owners. Flight Simulator II and Commodore 64 are trademarks of their respective
owners and are used only to identify the original game and hardware.

The repository contains no copy of SubLogic's program or data files: no byte dumps, disassembly
listings or data tables. The port is a translation of the program into Swift, and every byte of
the original program it works on (code, tables, text, graphics) is read at run time from a disk
image you make from your own copy of the game. No disk image is included in the repository.

A deployment of the web version carries a disk image that whoever deploys it supplies from their
own copy: `make web-disk` keeps only the sectors the port reads and blanks what a modified copy
added (see [Web version](#web-version)). It is never committed.

The Commodore 64 character ROM is not included either. Text screens use a look-alike font drawn
for this port; importing a dump of the character ROM from your own C64 is optional.

Credits:

- The colors are the Colodore palette, from Philip "Pepto" Timmermann's VIC-II color
  measurements.
- The sound is a 6581 model written for this port.
- The lab's 6502 core is checked with Klaus Dormann's 6502 functional test (GPL-3). It is not
  included: download it into `build/testdata/` to run that test, which is skipped without it.

If you hold rights to Flight Simulator II and object to this project, please open an issue and it
will be taken down.
