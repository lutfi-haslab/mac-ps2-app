# mac-ps2-app

Turn PS2 ISO files into **self-contained macOS `.app` bundles** that boot
straight into the game — no emulator frontend to navigate.

The generated app embeds the **ARMSX2** engine, the ISO, a matching BIOS, a
tuned PCSX2 config, a cover icon, and a small native launcher. Controller
mappings are shared globally across all generated apps.

Tested on Apple Silicon M1, macOS 15.5, ARMSX2 2.6.0.

## Features

- Detects the game title from the ISO filename and the disc serial/region.
- Picks a matching **PAL / NTSC-U / NTSC-J** BIOS automatically.
- Boots directly with `-nogui -fullscreen -fastboot` (no ARMSX2 main window).
- Tuned defaults: Metal, 3× internal resolution, 16:9 widescreen patch, VSync,
  emulator pause menu/OSD disabled.
- Per-game data directory and memory cards.
- **Global controller mapping** synced from the ARMSX2 global config on every
  launch.
- Cover art → `.icns` icon when a cover is available.
- Ad-hoc code signing with ARMSX2's JIT entitlements.

## Requirements

- Apple Silicon Mac (arm64), macOS 13 or newer.
- [ARMSX2](https://github.com/ARMSX2/ARMSX2) 2.6.0 installed at
  `~/Applications/ARMSX2.app` (or pass `--engine`).
- Xcode Command Line Tools (`clang`, `codesign`, `sips`, `iconutil`).
- `python3`.
- PS2 BIOS files in `~/Library/Application Support/ARMSX2/bios`
  (or `~/ps2_bios`, or pass `--bios`).
- Your own PS2 ISO and BIOS dump.

No ISO, BIOS, or emulator binary is included in this repository.

## Install

```sh
git clone https://github.com/lutfi-haslab/mac-ps2-app.git
cd mac-ps2-app
chmod +x make-ps2-app.sh
```

Already have ARMSX2? Run it once, set **Settings → Controllers**, and point its
BIOS folder at your dumps. Then:

```sh
./make-ps2-app.sh --help
```

## Usage

```sh
# simplest: name, region, BIOS, and cover detected automatically
./make-ps2-app.sh "/path/to/Game.iso"

# choose the output directory and a custom name
./make-ps2-app.sh "~/Games/God of War (USA).iso" \
  --name "God of War" --out ~/Desktop

# custom cover and 4x internal resolution
./make-ps2-app.sh game.iso --icon cover.png --upscale 4

# force a BIOS
./make-ps2-app.sh game.iso --bios ~/ps2_bios/scph39001.bin

# inspect detection without building
./make-ps2-app.sh game.iso --dry-run
```

The app is written as `<Name>.app` in the current directory (or `--out`).
Double-click it, or:

```sh
open "Game.app"
```

## Options

| Option | Description |
|---|---|
| `--name <title>` | App/game name (default: derived from the ISO filename) |
| `--out <dir>` | Output directory (default: current directory) |
| `--bios <file>` | Force a BIOS file |
| `--icon <file>` | Cover PNG/JPG or `.icns` |
| `--upscale <n>` | Internal resolution multiplier (default: 3) |
| `--engine <app>` | ARMSX2.app to embed (default: `~/Applications/ARMSX2.app`) |
| `--template <ini>` | PCSX2.ini template (default: global ARMSX2 config) |
| `--force` | Replace an existing app |
| `--no-sign` | Skip ad-hoc signing (not recommended) |
| `--dry-run` | Detect name/serial/region/BIOS and exit |
| `-h`, `--help` | Show help |

## How it works

1. Mounts the ISO read-only and reads `SYSTEM.CNF` / root serial files.
2. Detects region from the serial:
   - `SLES`/`SCES` → PAL
   - `SLUS`/`SCUS` → NTSC-U
   - `SLPS`/`SLPM`/`SCPS` → NTSC-J
3. Selects a BIOS from the global BIOS folders (or `--bios`).
4. Copies the ARMSX2 engine, ISO, and BIOS into a new `.app` bundle.
5. Writes a tuned per-game `default-PCSX2.ini`.
6. Builds a native launcher that:
   - creates `~/Library/Application Support/<Name>/ARMSX2`;
   - links the bundled BIOS folder;
   - copies `[Pad1]`/`[Pad2]` from
     `~/Library/Application Support/ARMSX2/inis/PCSX2.ini`;
   - execs `ARMSX2-bin -nogui -fullscreen -fastboot -- game.iso`.
7. Creates the icon, writes `Info.plist`, and ad-hoc signs the app.

## Controller mapping is global

Configure controllers once:

1. Open `~/Applications/ARMSX2.app`.
2. **Settings → Controllers**.
3. Pick **Port 1** / **Port 2**, choose the device, and use **Automatic
   Mapping** or bind manually.
4. Close ARMSX2.

Every generated app copies `[Pad1]`/`[Pad2]` from
`~/Library/Application Support/ARMSX2/inis/PCSX2.ini` on launch.

> **Important:** close ARMSX2 before launching a generated game app. Only one
> emulator process can own the controller; otherwise `SDL-0/...` bindings may be
> reported as invalid.

ARMSX2 2.6.0 uses positional face-button names. If you see
`Invalid binding: SDL-0/...`, use **Automatic Mapping** in the global ARMSX2
app, or use `FaceSouth` (A), `FaceEast` (B), `FaceWest` (X), `FaceNorth` (Y).

## Output and data

- Per-game data: `~/Library/Application Support/<Name>/ARMSX2/`
  - `memcards/`, `sstates/`, `inis/PCSX2.ini`, `logs/emulog.txt`
- Global controller config:
  `~/Library/Application Support/ARMSX2/inis/PCSX2.ini`
- Global BIOS folder: `~/Library/Application Support/ARMSX2/bios/`

Each generated app is around 1.6 GB (engine + ISO). The engine is copied into
each bundle so the app has its own name/icon and is portable.

## Notes

- The app is ad-hoc signed, not notarized. If Gatekeeper blocks it on another
  Mac, right-click → **Open**.
- Use ISOs and BIOS dumps you own. Do not redistribute copyrighted game data.
- ARMSX2 is licensed under the GPLv3. See its repository for details.
- Some games need per-game settings (resolution, patches). Edit the per-game
  `inis/PCSX2.ini` or add the game to the global ARMSX2 app and tune it there.

## Bahasa Indonesia

Panduan lengkap dalam bahasa Indonesia: [README-id.md](README-id.md).
