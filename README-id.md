# make-ps2-app.sh — ISO PS2 → app macOS

Script untuk mengubah file ISO PS2 menjadi `.app` macOS yang **langsung boot ke
game** (tanpa frontend emulator), lengkap dengan engine ARMSX2, BIOS, config,
icon, dan controller global.

## Lokasi

Setelah clone repo:

```sh
git clone https://github.com/lutfi-haslab/mac-ps2-app.git
cd mac-ps2-app
```

Script: `./make-ps2-app.sh`

## Requirement

- Apple Silicon Mac, macOS 13+
- `~/Applications/ARMSX2.app` (2.6.0 atau versi kompatibel)
- Xcode Command Line Tools (`clang`, `codesign`, `sips`, `iconutil`)
- `python3`
- File BIOS PS2 (PAL/NTSC) di:
  - `~/Library/Application Support/ARMSX2/bios`
  - atau `~/ps2_bios`
  - atau lewat `--bios`

## Pemakaian

```sh
# paling sederhana: nama & region/BIOS dideteksi otomatis
./make-ps2-app.sh "~/Games/God of War (USA).iso" --out ~/Desktop

# nama custom + icon cover
./make-ps2-app.sh "~/Games/Okami.iso" \
  --name "Okami" \
  --icon ~/Pictures/okami.png \
  --out ~/Desktop

# paksa BIOS tertentu
./make-ps2-app.sh game.iso --bios ~/ps2_bios/scph39001.bin

# cek dulu tanpa membuat app
./make-ps2-app.sh game.iso --dry-run
```

Hasilnya: `~/Desktop/<Nama Game>.app`. Drag ke Applications kalau suka.

## Opsi

| Opsi | Arti |
|---|---|
| `--name <judul>` | Nama app/game (default dari nama file ISO) |
| `--out <dir>` | Folder output (default: current directory) |
| `--bios <file>` | Paksa file BIOS tertentu |
| `--icon <file>` | Cover PNG/JPG atau `.icns` |
| `--upscale <n>` | Internal resolution (default 3×) |
| `--engine <app>` | ARMSX2.app yang dipakai (default `~/Applications/ARMSX2.app`) |
| `--template <ini>` | Template `PCSX2.ini` (default config global) |
| `--force` | Timpa app yang sudah ada |
| `--no-sign` | Lewati ad-hoc signing (tidak disarankan) |
| `--dry-run` | Deteksi nama/serial/region/BIOS, tidak membuat app |
| `-h`, `--help` | Bantuan |

## Yang dilakukan script

1. Membaca ISO (mount read-only), mendeteksi serial (`SLES`/`SLUS`/`SLPS`/…)
   dan region (PAL / NTSC-U / NTSC-J).
2. Memilih BIOS yang cocok dari folder BIOS global; bisa dioverride `--bios`.
3. Meng-copy engine ARMSX2 + ISO + BIOS ke bundle `.app`.
4. Menulis config per-game: Metal, 3× upscale, 16:9 widescreen, VSync, OSD dan
   pause menu emulator dimatikan.
5. Membuat launcher native yang:
   - membuat data dir per-game di
     `~/Library/Application Support/<Nama Game>/ARMSX2`;
   - menyambungkan folder BIOS;
   - **menyalin `[Pad1]`/`[Pad2]` dari config global**
     `~/Library/Application Support/ARMSX2/inis/PCSX2.ini`;
   - menjalankan `ARMSX2-bin -nogui -fullscreen -fastboot -- game.iso`.
6. Membuat icon dari cover (kalau ada) atau icon ARMSX2.
7. Ad-hoc sign + verifikasi.

## Controller global

Semua app yang dibuat memakai mapping controller dari config global ARMSX2.
Ubah sekali di **`ARMSX2.app` → Settings → Controllers**, lalu app game akan
menyalin mapping itu setiap kali dibuka.

> **Penting:** tutup `ARMSX2.app` sebelum membuka app game. Hanya satu proses
> yang bisa memegang controller; kalau ARMSX2 global masih terbuka, binding
> `SDL-0/...` bisa dianggap invalid dan game langsung keluar.

ARMSX2 2.6.0 memakai nama tombol posisional. Kalau muncul
`Invalid binding: SDL-0/...`, gunakan **Automatic Mapping** di ARMSX2 global,
atau nama posisional: `FaceSouth` (A), `FaceEast` (B), `FaceWest` (X),
`FaceNorth` (Y).

## Data & konfigurasi

- Data per-game: `~/Library/Application Support/<Nama Game>/ARMSX2/`
  - `memcards/`, `sstates/`, `inis/PCSX2.ini`, `logs/emulog.txt`
- Controller global: `~/Library/Application Support/ARMSX2/inis/PCSX2.ini`
- BIOS global: `~/Library/Application Support/ARMSX2/bios/`

Mau ubah resolusi/widescreen per game? Edit
`~/Library/Application Support/<Nama Game>/ARMSX2/inis/PCSX2.ini`, atau hapus
folder itu untuk reset dari template app.

## Catatan

- Ukuran tiap app sekitar **1.6 GB** (engine 165 MB + ISO). Engine di-copy ke
  tiap app supaya self-contained dan nama/icon app benar.
- App di-ad-hoc sign, bukan notarized. Kalau dipindah ke Mac lain dan Gatekeeper
  menolak, klik kanan → **Open**.
- Script tidak menyediakan ISO/BIOS; gunakan salinan yang kamu miliki.
- Kalau ada game yang butuh setting khusus (mis. 4× atau patch tertentu), pakai
  `--upscale` atau edit INI per-game.
- ARMSX2 adalah software GPLv3; lihat repo aslinya untuk detail lisensi.
