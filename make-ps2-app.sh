#!/bin/bash
#
# make-ps2-app.sh — turn a PS2 ISO into a self-contained macOS .app
#
# The generated app embeds the ARMSX2 engine, the ISO, a matching BIOS, a
# tuned PCSX2 config, an icon, and a native launcher. The launcher boots the
# game directly (no emulator frontend) and syncs [Pad1]/[Pad2] from the global
# ARMSX2 config on every launch, so controller mappings stay global.
#
# Requirements: macOS (Apple Silicon), ARMSX2.app, python3, Xcode tools.
#
# Examples:
#   ./make-ps2-app.sh "~/Games/God of War (USA).iso" --name "God of War"
#   ./make-ps2-app.sh "/Volumes/Discs/Okami.iso" --out ~/Desktop
#   ./make-ps2-app.sh game.iso --bios "~/hasdev/ps2_bios/scph39001.bin"
#   ./make-ps2-app.sh game.iso --icon ~/Pictures/cover.png --upscale 4
#   ./make-ps2-app.sh game.iso --dry-run
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENGINE_DEFAULT="$HOME/Applications/ARMSX2.app"
GLOBAL_DATA="$HOME/Library/Application Support/ARMSX2"
BIOS_DIRS=("$GLOBAL_DATA/bios" "$HOME/ps2_bios" "$SCRIPT_DIR/bios")

ISO=""
NAME=""
OUT="$(pwd)"
BIOS_ARG=""
ICON_ARG=""
ENGINE="$ENGINE_DEFAULT"
TEMPLATE=""
UPSCALE=3
FORCE=0
DO_SIGN=1
DRY_RUN=0

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }
expand_path() {
  case "$1" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <game.iso> [options]

Options:
  --name <title>       App/game name (default: derived from the ISO filename)
  --out <dir>          Output directory (default: current directory)
  --bios <file>        Override BIOS selection
  --icon <image>       Cover image (PNG/JPG) or .icns
  --upscale <n>        Internal resolution multiplier (default: 3)
  --engine <app>       ARMSX2.app to embed (default: ~/Applications/ARMSX2.app)
  --template <ini>     PCSX2.ini template (default: global ARMSX2 config)
  --force              Replace an existing .app
  --no-sign            Skip ad-hoc code signing (not recommended)
  --dry-run            Detect name/region/BIOS and exit
  -h, --help           Show this help

The generated app writes per-game data to:
  ~/Library/Application Support/<title>/ARMSX2

Controller mapping is global:
  ~/Library/Application Support/ARMSX2/inis/PCSX2.ini

Note: close ARMSX2.app before launching a generated game app. Only one
emulator process can own the controller at a time; otherwise SDL-0 bindings
may be reported as invalid.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)     NAME="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --bios)     BIOS_ARG="$2"; shift 2 ;;
    --icon)     ICON_ARG="$2"; shift 2 ;;
    --engine)   ENGINE="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --upscale)  UPSCALE="$2"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    --no-sign)  DO_SIGN=0; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          [ -z "$ISO" ] || die "only one ISO can be given"; ISO="$1"; shift ;;
  esac
done

[ -n "$ISO" ] || { usage; exit 1; }
ISO=$(expand_path "$ISO")
OUT=$(expand_path "$OUT")
ENGINE=$(expand_path "$ENGINE")
if [ -n "$BIOS_ARG" ]; then BIOS_ARG=$(expand_path "$BIOS_ARG"); fi
if [ -n "$ICON_ARG" ]; then ICON_ARG=$(expand_path "$ICON_ARG"); fi
if [ -n "$TEMPLATE" ]; then TEMPLATE=$(expand_path "$TEMPLATE"); fi
[ -f "$ISO" ] || die "ISO not found: $ISO"
ISO=$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")
[ -d "$ENGINE" ] || die "ARMSX2 engine not found: $ENGINE"

need python3
need clang
need hdiutil
need sips
need iconutil
need codesign
need ditto
need plutil

TMPDIR_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/ps2app.XXXXXX")
MNT=""
cleanup() {
  [ -n "$MNT" ] && hdiutil detach "$MNT" >/dev/null 2>&1 || true
  rm -rf "$TMPDIR_BUILD"
}
trap cleanup EXIT

# --- name -------------------------------------------------------------------
if [ -z "$NAME" ]; then
  base=$(basename "$ISO")
  base=${base%.*}
  NAME=$(printf '%s' "$base" | sed -E 's/\[[^]]*\]//g; s/\([^)]*\)//g; s/[._]+/ /g; s/  +/ /g; s/^ +| +$//g')
  [ -n "$NAME" ] || NAME="PS2 Game"
fi
SAFE_NAME=$(printf '%s' "$NAME" | sed -E "s/[^A-Za-z0-9 ._()'-]//g; s/^ +| +$//g")
[ -n "$SAFE_NAME" ] || SAFE_NAME="PS2 Game"
SLUG=$(printf '%s' "$SAFE_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')
[ -n "$SLUG" ] || SLUG="ps2-game"
DATA_NAME="$SAFE_NAME"
case "$DATA_NAME" in ARMSX2|PCSX2) DATA_NAME="$DATA_NAME PS2" ;; esac

ext=$(printf '%s' "${ISO##*.}" | tr '[:upper:]' '[:lower:]')
case "$ext" in
  iso|chd|cso|zso) GAME_FILE="game.$ext" ;;
  *) warn "unusual ISO extension .$ext; copying as game.iso"; GAME_FILE="game.iso" ;;
esac

# --- region / serial detection ---------------------------------------------
REGION="PAL"
SERIAL=""
MNT="$TMPDIR_BUILD/mnt"
mkdir -p "$MNT"
if hdiutil attach -readonly -nobrowse -mountpoint "$MNT" "$ISO" >/dev/null 2>&1; then
  CNF=$(find "$MNT" -maxdepth 1 -iname 'SYSTEM.CNF' -print -quit 2>/dev/null || true)
  if [ -n "$CNF" ]; then
    SERIAL=$(grep -Eio 'S[CL][A-Z0-9]{2}_[0-9]{3}\.[0-9]{2}' "$CNF" | head -1 | tr '[:lower:]' '[:upper:]' || true)
  fi
  if [ -z "$SERIAL" ]; then
    SERIAL=$(find "$MNT" -maxdepth 1 -type f -print 2>/dev/null | sed 's|.*/||' \
      | grep -Eio 'S[CL][A-Z0-9]{2}_[0-9]{3}\.[0-9]{2}' | head -1 | tr '[:lower:]' '[:upper:]' || true)
  fi
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  MNT=""
fi
case "$SERIAL" in
  SLES*|SCES*|SLED*|SCED*) REGION="PAL" ;;
  SLUS*|SCUS*)             REGION="NTSC-U" ;;
  SLPS*|SLPM*|SCPS*|SLAJ*|SLKA*) REGION="NTSC-J" ;;
  *)
    lower="$(printf '%s %s' "$NAME" "$(basename "$ISO")" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      *europe*|*pal*)  REGION="PAL" ;;
      *usa*|*ntsc*)    REGION="NTSC-U" ;;
      *japan*|*jpn*)   REGION="NTSC-J" ;;
    esac
    ;;
esac

# --- BIOS selection ---------------------------------------------------------
BIOS_PATH=""
if [ -n "$BIOS_ARG" ]; then
  BIOS_PATH=$(cd "$(dirname "$BIOS_ARG")" && pwd)/$(basename "$BIOS_ARG")
  [ -f "$BIOS_PATH" ] || die "BIOS not found: $BIOS_ARG"
else
  case "$REGION" in
    PAL)    CANDIDATES=("SCPH-70004_BIOS_V12_PAL_200.BIN" "PS2 Bios 30004R V6 Pal.bin" "scph70004.bin") ;;
    NTSC-U) CANDIDATES=("scph39001.bin" "SCPH-70012_BIOS_V12_USA_200.BIN" "scph70012.bin") ;;
    NTSC-J) CANDIDATES=("scph10000.bin" "SCPH-70000_BIOS_V12_JAP_200.BIN" "scph70000.bin") ;;
  esac
  for d in "${BIOS_DIRS[@]}"; do
    [ -d "$d" ] || continue
    for c in "${CANDIDATES[@]}"; do
      f=$(find "$d" -maxdepth 1 -type f -iname "$c" -print -quit 2>/dev/null || true)
      if [ -n "$f" ]; then BIOS_PATH="$f"; break 2; fi
    done
  done
  if [ -z "$BIOS_PATH" ]; then
    for d in "${BIOS_DIRS[@]}"; do
      [ -d "$d" ] || continue
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        low=$(basename "$f" | tr '[:upper:]' '[:lower:]')
        case "$REGION:$low" in
          PAL:*pal*|PAL:*europe*)        BIOS_PATH="$f" ;;
          NTSC-U:*usa*|NTSC-U:*ntsc*)    BIOS_PATH="$f" ;;
          NTSC-J:*jap*|NTSC-J:*japan*)   BIOS_PATH="$f" ;;
        esac
        [ -n "$BIOS_PATH" ] && break
      done < <(find "$d" -maxdepth 1 -type f -iname '*.bin' 2>/dev/null)
      [ -n "$BIOS_PATH" ] && break
    done
  fi
  if [ -z "$BIOS_PATH" ]; then
    for d in "${BIOS_DIRS[@]}"; do
      [ -d "$d" ] || continue
      BIOS_PATH=$(find "$d" -maxdepth 1 -type f -iname '*.bin' -print -quit 2>/dev/null || true)
      [ -n "$BIOS_PATH" ] && break
    done
  fi
  [ -n "$BIOS_PATH" ] || die "no PS2 BIOS found; use --bios <file>"
fi
BIOS_BASENAME=$(basename "$BIOS_PATH")

# --- template ---------------------------------------------------------------
if [ -n "$TEMPLATE" ]; then
  [ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
elif [ -f "$GLOBAL_DATA/inis/PCSX2.ini" ]; then
  TEMPLATE="$GLOBAL_DATA/inis/PCSX2.ini"
else
  die "no config template found: run ARMSX2 once to create the global config, or pass --template <PCSX2.ini>"
fi

# --- icon -------------------------------------------------------------------
ICON_SRC=""
if [ -n "$ICON_ARG" ]; then
  ICON_SRC=$(cd "$(dirname "$ICON_ARG")" && pwd)/$(basename "$ICON_ARG")
  [ -f "$ICON_SRC" ] || die "icon not found: $ICON_ARG"
else
  for p in \
    "$GLOBAL_DATA/covers/$SAFE_NAME.png" \
    "$GLOBAL_DATA/covers/$SAFE_NAME.jpg" \
    "$HOME/Library/Application Support/AetherSX2/covers/$SAFE_NAME.png" \
    "$HOME/Library/Application Support/AetherSX2/covers/$SAFE_NAME.jpg" \
    "$SCRIPT_DIR/covers/$SLUG.png" \
    "$SCRIPT_DIR/covers/$SLUG.jpg"; do
    if [ -f "$p" ]; then ICON_SRC="$p"; break; fi
  done
fi

# --- summary ----------------------------------------------------------------
printf '\nPS2 app build\n'
printf '  ISO       : %s\n' "$ISO"
printf '  Name      : %s\n' "$SAFE_NAME"
printf '  Serial    : %s\n' "${SERIAL:-unknown}"
printf '  Region    : %s\n' "$REGION"
printf '  BIOS      : %s\n' "$BIOS_PATH"
printf '  Engine    : %s\n' "$ENGINE"
printf '  Template  : %s\n' "$TEMPLATE"
printf '  Data dir  : %s\n' "$HOME/Library/Application Support/$DATA_NAME"
printf '  Upscale   : %sx\n' "$UPSCALE"
printf '  Icon      : %s\n' "${ICON_SRC:-ARMSX2 default}"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '\nDry run only; no app created.\n'
  exit 0
fi

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
APP="$OUT/$SAFE_NAME.app"
if [ -e "$APP" ]; then
  [ "$FORCE" -eq 1 ] || die "app already exists: $APP (use --force)"
  rm -rf "$APP"
fi

printf '\n[1/6] copying ARMSX2 engine...\n'
ditto "$ENGINE" "$APP"
ENGINE_EXE=$(plutil -extract CFBundleExecutable raw "$ENGINE/Contents/Info.plist" 2>/dev/null || echo ARMSX2)
[ -f "$APP/Contents/MacOS/$ENGINE_EXE" ] || die "engine executable not found: $ENGINE/Contents/MacOS/$ENGINE_EXE"
mv "$APP/Contents/MacOS/$ENGINE_EXE" "$APP/Contents/MacOS/ARMSX2-bin"
mkdir -p "$APP/Contents/Resources/Data/bios"
cp "$BIOS_PATH" "$APP/Contents/Resources/Data/bios/"
for nvm in "${BIOS_PATH%.*}.NVM" "${BIOS_PATH%.*}.nvm"; do
  [ -f "$nvm" ] && cp "$nvm" "$APP/Contents/Resources/Data/bios/" && break
done

printf '[2/6] copying ISO...\n'
if ! cp -c "$ISO" "$APP/Contents/Resources/Data/$GAME_FILE" 2>/dev/null; then
  cp "$ISO" "$APP/Contents/Resources/Data/$GAME_FILE"
fi

printf '[3/6] writing config...\n'
cp "$TEMPLATE" "$APP/Contents/Resources/Data/default-PCSX2.ini"
python3 - "$APP/Contents/Resources/Data/default-PCSX2.ini" "$BIOS_BASENAME" "$UPSCALE" <<'PY'
import re, sys
path, bios, upscale = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()

def setkey(s, sec, key, val):
    m = re.search(r'(?m)^\[' + re.escape(sec) + r'\]\n(.*?)(?=\n\[|\Z)', s, re.S)
    if not m:
        return s
    body = m.group(1)
    if re.search(r'(?m)^' + re.escape(key) + r' = .*$', body):
        body = re.sub(r'(?m)^' + re.escape(key) + r' = .*$', f'{key} = {val}', body)
    else:
        body += f'\n{key} = {val}'
    return s[:m.start(1)] + body + s[m.end(1):]

ui = {
 'SetupWizardIncomplete':'false','StartFullscreen':'true','HideMainWindowWhenRunning':'true',
 'DoubleClickTogglesFullscreen':'false','DisableWindowResize':'true','PauseOnFocusLoss':'false',
 'ConfirmShutdown':'false','HideMouseCursor':'true','InhibitScreensaver':'true','StartPaused':'false'}
for k,v in ui.items(): s=setkey(s,'UI',k,v)
for k,v in {'EnableWideScreenPatches':'true','EnableNoInterlacingPatches':'true',
            'EnableDiscordPresence':'false','InhibitScreensaver':'true'}.items():
    s=setkey(s,'EmuCore',k,v)
for k,v in {'VsyncEnable':'true','AspectRatio':'16:9','upscale_multiplier':upscale,
            'MaxAnisotropy':'16','SyncToHostRefreshRate':'true'}.items():
    s=setkey(s,'EmuCore/GS',k,v)
# Disable every boolean OSD show flag
s = re.sub(r'(?mi)^(OsdShow[A-Za-z]*) = .*$', r'\1 = false', s)
for k,v in {'OpenPauseMenu':'Keyboard/F13','ToggleOSD':'Keyboard/F13','TogglePause':'Keyboard/F13',
            'ToggleTurbo':'Keyboard/F13','HoldTurbo':'Keyboard/F13','ToggleSlowMotion':'Keyboard/F13',
            'ToggleFrameLimit':'Keyboard/F13','ToggleSoftwareRendering':'Keyboard/F13',
            'ToggleMipmapMode':'Keyboard/F13','CycleAspectRatio':'Keyboard/F13',
            'CycleInterlaceMode':'Keyboard/F13'}.items():
    s=setkey(s,'Hotkeys',k,v)
s=setkey(s,'Filenames','BIOS',bios)
s=setkey(s,'Folders','Bios','bios')
open(path,'w').write(s)
PY

printf '[4/6] writing launcher...\n'
cat > "$TMPDIR_BUILD/launcher.c" <<EOF
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

#define APP_DATA_NAME "$DATA_NAME"
#define GAME_FILE "$GAME_FILE"

static void mkdirp(const char *path) {
  char tmp[PATH_MAX]; snprintf(tmp, sizeof(tmp), "%s", path);
  for (char *p = tmp + 1; *p; p++) { if (*p == '/') { *p = 0; mkdir(tmp, 0755); *p = '/'; } }
  mkdir(tmp, 0755);
}
static int copyfile(const char *src, const char *dst) {
  FILE *in = fopen(src, "rb"); if (!in) return -1;
  FILE *out = fopen(dst, "wb"); if (!out) { fclose(in); return -1; }
  char buf[65536]; size_t n;
  while ((n = fread(buf, 1, sizeof(buf), in)) > 0) if (fwrite(buf, 1, n, out) != n) { fclose(in); fclose(out); return -1; }
  fclose(in); fclose(out); return 0;
}
static char *read_file(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb"); if (!f) return NULL;
  fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
  if (sz < 0) { fclose(f); return NULL; }
  char *buf = malloc((size_t)sz + 1); if (!buf) { fclose(f); return NULL; }
  size_t n = fread(buf, 1, (size_t)sz, f); fclose(f); buf[n] = 0; if (len) *len = n; return buf;
}
static char *find_pad_block(char *s, size_t *len) {
  char *p = strstr(s, "[Pad1]"); if (!p) return NULL;
  while (p > s && p[-1] != '\n') { p = strstr(p + 1, "[Pad1]"); if (!p) return NULL; }
  char *q = strstr(p, "[Pad2]"); if (!q) return NULL;
  while (q > s && q[-1] != '\n') { q = strstr(q + 1, "[Pad2]"); if (!q) return NULL; }
  char *r = strstr(q, "\n[");
  *len = r ? (size_t)(r - p + 1) : strlen(p);
  return p;
}
static int sync_pad_block(const char *global_path, const char *local_path) {
  size_t glen = 0, plen = 0, gblen = 0, pblen = 0;
  char *g = read_file(global_path, &glen); if (!g) return -1;
  char *p = read_file(local_path, &plen); if (!p) { free(g); return -1; }
  char *gb = find_pad_block(g, &gblen); char *pb = find_pad_block(p, &pblen);
  if (!gb || !pb) { free(g); free(p); return 0; }
  size_t pre = (size_t)(pb - p);
  size_t tail = plen - pre - pblen;
  size_t newlen = pre + gblen + tail;
  char *out = malloc(newlen + 1); if (!out) { free(g); free(p); return -1; }
  memcpy(out, p, pre); memcpy(out + pre, gb, gblen); memcpy(out + pre + gblen, pb + pblen, tail); out[newlen] = 0;
  char tmp[PATH_MAX]; snprintf(tmp, sizeof(tmp), "%s.tmp", local_path);
  FILE *f = fopen(tmp, "wb"); if (!f) { free(out); free(g); free(p); return -1; }
  fwrite(out, 1, newlen, f); fclose(f);
  int rc = rename(tmp, local_path);
  free(out); free(g); free(p); return rc;
}
int main(int argc, char **argv) {
  char exe[PATH_MAX]; uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) != 0) return 1;
  char *s = strrchr(exe, '/'); if (!s) return 1; *s = 0;
  s = strrchr(exe, '/'); if (!s) return 1; *s = 0;
  char contents[PATH_MAX], bin[PATH_MAX], data[PATH_MAX], iso[PATH_MAX], bios[PATH_MAX], defini[PATH_MAX];
  snprintf(contents, sizeof(contents), "%s", exe);
  snprintf(bin, sizeof(bin), "%s/MacOS/ARMSX2-bin", contents);
  snprintf(data, sizeof(data), "%s/Resources/Data", contents);
  snprintf(iso, sizeof(iso), "%s/%s", data, GAME_FILE);
  snprintf(bios, sizeof(bios), "%s/bios", data);
  snprintf(defini, sizeof(defini), "%s/default-PCSX2.ini", data);
  const char *home = getenv("HOME"); if (!home) home = "/tmp";
  char appsup[PATH_MAX], root[PATH_MAX], inis[PATH_MAX], inifile[PATH_MAX], link[PATH_MAX], globalini[PATH_MAX];
  snprintf(appsup, sizeof(appsup), "%s/Library/Application Support/%s", home, APP_DATA_NAME);
  snprintf(root, sizeof(root), "%s/ARMSX2", appsup);
  snprintf(inis, sizeof(inis), "%s/inis", root);
  snprintf(inifile, sizeof(inifile), "%s/PCSX2.ini", inis);
  snprintf(link, sizeof(link), "%s/bios", root);
  snprintf(globalini, sizeof(globalini), "%s/Library/Application Support/ARMSX2/inis/PCSX2.ini", home);
  mkdirp(appsup); mkdirp(root);
  const char *dirs[] = { "inis", "memcards", "sstates", "logs", "cheats", "patches", "textures", "snaps", "cache", "videos", "inputprofiles", "resources", "covers", "gamesettings", NULL };
  for (int i = 0; dirs[i]; i++) { char d[PATH_MAX]; snprintf(d, sizeof(d), "%s/%s", root, dirs[i]); mkdirp(d); }
  struct stat lst;
  if (lstat(link, &lst) == 0) { if (S_ISDIR(lst.st_mode)) rmdir(link); else unlink(link); }
  symlink(bios, link);
  struct stat st;
  if (stat(inifile, &st) != 0) copyfile(defini, inifile);
  sync_pad_block(globalini, inifile);
  if (argc > 1 && strcmp(argv[1], "--sync-only") == 0) return 0;
  char *args[] = { bin, "-nogui", "-fullscreen", "-fastboot", "-datapath", appsup, "--", iso, NULL };
  execv(bin, args);
  fprintf(stderr, "PS2 app: failed to start emulator: %s\n", strerror(errno));
  return 1;
}
EOF
clang -O2 -arch arm64 "$TMPDIR_BUILD/launcher.c" -o "$APP/Contents/MacOS/Launcher"

printf '[5/6] writing Info.plist and icon...\n'
python3 - "$APP/Contents/Info.plist" "$SAFE_NAME" "$SLUG" <<'PY'
import plistlib, sys
path, name, slug = sys.argv[1], sys.argv[2], sys.argv[3]
d = plistlib.load(open(path, 'rb'))
d['CFBundleExecutable'] = 'Launcher'
d['CFBundleName'] = name
d['CFBundleDisplayName'] = name
d['CFBundleIdentifier'] = f'com.local.ps2.{slug}'
d['CFBundleIconFile'] = 'Game.icns'
d['CFBundleShortVersionString'] = '1.0'
d['CFBundleVersion'] = '1.0'
d['LSApplicationCategoryType'] = 'public.app-category.games'
d['LSMultipleInstancesProhibited'] = True
d['NSHighResolutionCapable'] = True
d.pop('CFBundleDocumentTypes', None)
plistlib.dump(d, open(path, 'wb'))
PY

make_icns() {
  src="$1"; dst="$2"; setdir="$TMPDIR_BUILD/icon.iconset"
  rm -rf "$setdir"; mkdir -p "$setdir"
  sips -p 1024 1024 --padColor 000000 "$src" --out "$TMPDIR_BUILD/icon_square.png" >/dev/null 2>&1 || return 1
  gen() { sips -z "$1" "$1" "$TMPDIR_BUILD/icon_square.png" --out "$setdir/$2" >/dev/null 2>&1 || return 1; }
  gen 16 icon_16x16.png; gen 32 icon_16x16@2x.png; gen 32 icon_32x32.png; gen 64 icon_32x32@2x.png
  gen 128 icon_128x128.png; gen 256 icon_128x128@2x.png; gen 256 icon_256x256.png; gen 512 icon_256x256@2x.png
  gen 512 icon_512x512.png; gen 1024 icon_512x512@2x.png
  iconutil -c icns "$setdir" -o "$dst" >/dev/null 2>&1
}
ICON_OUT="$APP/Contents/Resources/Game.icns"
icon_ok=0
if [ -n "$ICON_SRC" ]; then
  case "$(printf '%s' "$ICON_SRC" | tr '[:upper:]' '[:lower:]')" in
    *.icns) cp "$ICON_SRC" "$ICON_OUT"; icon_ok=1 ;;
    *) make_icns "$ICON_SRC" "$ICON_OUT" && icon_ok=1 || warn "could not build icon from $ICON_SRC" ;;
  esac
fi
if [ "$icon_ok" -eq 0 ]; then
  if [ -f "$APP/Contents/Resources/ARMSX2.icns" ]; then
    cp "$APP/Contents/Resources/ARMSX2.icns" "$ICON_OUT"
  else
    warn "no icon available; app will use a generic icon"
    rm -f "$APP/Contents/Resources/Game.icns"
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
  fi
fi

if [ "$DO_SIGN" -eq 1 ]; then
  printf '[6/6] signing (ad-hoc)...\n'
  cat > "$TMPDIR_BUILD/ent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.device.camera</key><true/>
</dict></plist>
EOF
  rm -rf "$APP/Contents/_CodeSignature" "$APP/Contents/CodeResources"
  codesign --force --sign - --options runtime --entitlements "$TMPDIR_BUILD/ent.plist" "$APP/Contents/MacOS/ARMSX2-bin" >/dev/null 2>&1
  codesign --force --sign - --options runtime --entitlements "$TMPDIR_BUILD/ent.plist" "$APP/Contents/MacOS/Launcher" >/dev/null 2>&1
  codesign --force --deep --sign - --options runtime --entitlements "$TMPDIR_BUILD/ent.plist" "$APP" >/dev/null 2>&1
  codesign --verify --deep --strict "$APP" || warn "codesign verification failed"
else
  printf '[6/6] skipping signing (--no-sign)\n'
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

printf '\nDone: %s\n' "$APP"
printf 'Size : %s\n' "$(du -sh "$APP" | cut -f1)"
printf 'Data : %s\n' "$HOME/Library/Application Support/$DATA_NAME"
printf 'BIOS : %s\n' "$BIOS_BASENAME"
printf 'Region: %s %s\n' "$REGION" "${SERIAL:-}"
printf '\nController mapping is synced from:\n  %s\n' "$GLOBAL_DATA/inis/PCSX2.ini"
printf 'Change controllers in the global ARMSX2 app: Settings -> Controllers.\n'
printf 'NOTE: close ARMSX2.app before launching this app (controller is exclusive).\n'
printf 'Launch: open "%s"\n' "$APP"
