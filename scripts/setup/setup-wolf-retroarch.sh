#!/bin/bash
# Provisions the persistent RetroArch profile in Wolf (urahara): cores, .info,
# Dolphin Sys, GLSL shaders, PS2 BIOS, core options, controller hotkeys in
# retroarch.cfg and per-core overrides (Run-Ahead, CRT shader, automatic save
# state on 2D cores).
# The GoW RetroArch image (apt from the libretro/stable PPA) ships with no
# cores, an empty Core Downloader and no .info files (without them the file
# browser filters out every ROM), so all of that is provisioned here.
# Everything is pinned by version/commit/sha256: reruns always give the same result.
# Idempotent. Requires sudo. Aborts if a Wolf session is open (RetroArch
# rewrites the .opt/.cfg files when the core closes and would overwrite the
# merge); FORCE=1 skips the check.
# To add/remove a core, edit the CORES array and rerun.
set -euo pipefail

REPO_DIR="/opt/homelab"
WOLF_DIR="/opt/apps/wolf"
PROFILE="$WOLF_DIR/profile-data/user/WolfRetroarch/.config/retroarch"
CACHE="$WOLF_DIR/cache"
OPTS_SRC="$REPO_DIR/infra/media-player/wolf/config/core-options"
BIOS_SRC="/mnt/games-4tb/retro/bios/pcsx2"
APP_UID=1000
APP_GID=1000

RA_IMAGE="ghcr.io/games-on-whales/retroarch@sha256:bbcf4523e589fc7177b522ce56ba9507c6530caaf1999e37b37062a189f18cf2"
CORES_URL="https://buildbot.libretro.com/stable/1.22.2/linux/x86_64/RetroArch_cores.7z"
CORES_SHA256="4b7ed8dc97d4bf035fce182c64b5658c7662e2e9e5d42129538afbd4b6096307"
INFO_TAG="v1.22.2"
# MAME is taken from outside the "stable" pack (that channel is locked to the
# RetroArch version; 1.22.2 only ships MAME 0.282, with no new stable in
# sight). The buildbot "nightly" channel only serves "latest" (no dated
# snapshot, no way to pin by URL), so it is downloaded once, pinned to this
# exact sha256 and named with the date: reruns always use this exact binary
# from the cache (download() only re-downloads if the cache is gone), never
# whatever is live that day. Version bump = delete the cache, rerun to fetch
# the current nightly, test it in a real session and update this sha256/date.
MAME_NIGHTLY_URL="https://buildbot.libretro.com/nightly/linux/x86_64/latest/mame_libretro.so.zip"
MAME_NIGHTLY_SHA256="4f4ccc4b6e6d3ed5129246cd0e0c7d84b73a9d01c45d648ae496bb81f3fa7c06"
MAME_NIGHTLY_CACHE_NAME="mame_libretro-nightly-2026-10-04.so.zip"  # MAME 0.289 (9069f393)
DOLPHIN_TAG="2609"
SHADERS_COMMIT="f8e23ff880668f0f0e837a05a316534d82a7f31b"
# LRPS2's GameIndex.yaml: database of per-game hardware fixes. The core treats
# it as a required file (firmware1 in the .info); without it no per-game fix is
# applied and games like Gran Turismo 4 render with corrupted textures.
GAMEINDEX_COMMIT="6eabf2242d451ee2e6d52b1e3f10efb77143ed05"
GAMEINDEX_SHA256="371f2f310e652c955b0553480d227409efeed5a4cc1b1bbfc4e00c6d5c9f5d6c"

# One core per system (some with an alternative). Cores that need their own
# BIOS (swanstation, mednafen_saturn, melonds, flycast, ppsspp with assets)
# run with limitations or do not start without it; BIOS is not provisioned here.
# MAME is not listed here: it comes from the nightly channel (see
# MAME_NIGHTLY_* above) and is installed in a separate block further down.
CORES=(
  fceumm nestopia
  snes9x
  genesis_plus_gx picodrive
  gambatte mgba
  pcsx_rearmed swanstation
  mupen64plus_next
  melonds desmume
  ppsspp
  flycast
  mednafen_saturn
  fbneo
  dolphin
  pcsx2
)

# 2D cores (low CPU cost) get Run-Ahead, CRT shader and automatic save state;
# PS2/GameCube/N64/PSP are left out (Run-Ahead would double the cost).
# Names = corename from the .info, which is how RetroArch names config/<name>/.
CORE_DIRS_2D=("Snes9x" "FCEUmm" "Nestopia" "Genesis Plus GX" "PicoDrive" "Gambatte" "mGBA")
CORE_DIRS_SHADER_ONLY=("FinalBurn Neo")
CFG_SRC="$REPO_DIR/infra/media-player/wolf/config/retroarch"
CORE_OVR_SRC="$REPO_DIR/infra/media-player/wolf/config/core-overrides"

as_app() { sudo install -d -o "$APP_UID" -g "$APP_GID" "$@"; }

# RetroArch rewrites retroarch.cfg and the .opt files on exit, and ES-DE uses
# it too: with a session open the merge would be overwritten or half-read.
APP_CONTAINERS="$(sudo docker ps --format '{{.Names}}' | grep '^Wolf' || true)"
if [[ -n "$APP_CONTAINERS" && "${FORCE:-0}" != "1" ]]; then
  echo "Error: a Wolf session is open ($(echo "$APP_CONTAINERS" | tr '\n' ' '))."
  echo "Close Moonlight and run again (or FORCE=1 to skip the check)."
  exit 1
fi

download() {
  local url="$1" dest="$2" sha="${3:-}"
  if [[ -f "$dest" && -n "$sha" ]] && echo "$sha  $dest" | sha256sum -c --status; then
    echo "✓ cache ok: $(basename "$dest")"
    return
  fi
  sudo curl -fsSL -o "$dest" "$url"
  if [[ -n "$sha" ]]; then
    echo "$sha  $dest" | sha256sum -c --status || {
      echo "Error: sha256 mismatch for $(basename "$dest")"
      exit 1
    }
  fi
  echo "✓ downloaded: $(basename "$dest")"
}

merge_opts() {
  local src="$1" dst="$2" line key
  as_app "$(dirname "$dst")"
  sudo touch "$dst"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key="${line%% = *}"
    if sudo grep -q "^${key} = " "$dst"; then
      sudo sed -i "s|^${key} = .*|${line}|" "$dst"
    else
      echo "$line" | sudo tee -a "$dst" >/dev/null
    fi
  done < "$src"
  echo "✓ options applied: $dst"
}

as_app "$WOLF_DIR/profile-data/user/WolfRetroarch/.config" "$PROFILE" \
  "$PROFILE/cores" "$PROFILE/shaders/shaders_glsl" \
  "$PROFILE/system/dolphin-emu" "$PROFILE/system/pcsx2/bios" "$PROFILE/system/pcsx2/resources"
sudo install -d -m 755 "$CACHE"

# MAME BIOS: the NAS mount lands at /bios-mame (outside $HOME, see
# setup-wolf-config.sh) and the core expects it at system/mame/bios, hence the
# symlink instead of mounting there directly (ES-DE's init chown -R would break).
as_app "$PROFILE/system/mame"
if [[ -e "$PROFILE/system/mame/bios" && ! -L "$PROFILE/system/mame/bios" ]]; then
  echo "Error: $PROFILE/system/mame/bios exists and is not a symlink - remove it manually"
  exit 1
fi
sudo ln -sfn /bios-mame "$PROFILE/system/mame/bios"
sudo chown -h "$APP_UID:$APP_GID" "$PROFILE/system/mame/bios"
echo "✓ symlink system/mame/bios -> /bios-mame"

# --- Cores (buildbot stable pack, matching the image's RetroArch version) ---
download "$CORES_URL" "$CACHE/RetroArch_cores.7z" "$CORES_SHA256"
PATTERNS=()
for core in "${CORES[@]}"; do
  PATTERNS+=("${core}_libretro.so")
done
# 7z from the RetroArch image itself (p7zip-full): no new host dependency.
# -r matches the name at any depth (a "*/cores/" pattern did not match).
# -mmt=1: multithreaded, p7zip intermittently reported "CRC Failed" on random
# files in the solid block (package sha256 ok); single-threaded it does not.
sudo docker run --rm --entrypoint 7z \
  -v "$CACHE:/in:ro" -v "$PROFILE/cores:/out" "$RA_IMAGE" \
  e -y -r -mmt=1 -o/out /in/RetroArch_cores.7z "${PATTERNS[@]}" >/dev/null
for core in "${CORES[@]}"; do
  sudo test -f "$PROFILE/cores/${core}_libretro.so" || {
    echo "Error: core ${core} was not extracted from the package"
    exit 1
  }
done
echo "✓ cores extracted: ${#CORES[@]}"

# --- Core .info files (without them the file browser filters out every ROM) ---
download "https://github.com/libretro/libretro-core-info/archive/refs/tags/${INFO_TAG}.tar.gz" \
  "$CACHE/libretro-core-info-${INFO_TAG}.tar.gz"
INFO_PATTERNS=()
for core in "${CORES[@]}"; do
  INFO_PATTERNS+=("*/${core}_libretro.info")
done
sudo tar -xzf "$CACHE/libretro-core-info-${INFO_TAG}.tar.gz" \
  --strip-components=1 -C "$PROFILE/cores" --wildcards "${INFO_PATTERNS[@]}"
# mame_libretro.info does not change between core versions (it does not
# reference the MAME version), so it still comes from the .info pack pinned
# above; only the MAME .so comes from nightly.
sudo tar -xzf "$CACHE/libretro-core-info-${INFO_TAG}.tar.gz" \
  --strip-components=1 -C "$PROFILE/cores" --wildcards "*/mame_libretro.info"
echo "✓ .info files extracted"

# --- MAME core (nightly, see MAME_NIGHTLY_* at the top) ---
download "$MAME_NIGHTLY_URL" "$CACHE/$MAME_NIGHTLY_CACHE_NAME" "$MAME_NIGHTLY_SHA256"
sudo docker run --rm --entrypoint 7z \
  -v "$CACHE:/in:ro" -v "$PROFILE/cores:/out" "$RA_IMAGE" \
  e -y -mmt=1 -o/out "/in/$MAME_NIGHTLY_CACHE_NAME" mame_libretro.so >/dev/null
sudo test -f "$PROFILE/cores/mame_libretro.so" || {
  echo "Error: mame_libretro.so was not extracted from the nightly package"
  exit 1
}
echo "✓ mame core (nightly) extracted"

# --- Dolphin Sys (codehandler.bin etc.; the core requires the folder) ---
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
git clone -q --depth 1 --branch "$DOLPHIN_TAG" --filter=blob:none --sparse \
  https://github.com/dolphin-emu/dolphin "$TMP_DIR/dolphin"
git -C "$TMP_DIR/dolphin" sparse-checkout set Data/Sys
sudo rm -rf "$PROFILE/system/dolphin-emu/Sys"
sudo cp -r "$TMP_DIR/dolphin/Data/Sys" "$PROFILE/system/dolphin-emu/Sys"
echo "✓ Dolphin Sys (tag $DOLPHIN_TAG)"

# --- GLSL shaders (RetroArch's video driver here is gl) ---
download "https://github.com/libretro/glsl-shaders/archive/${SHADERS_COMMIT}.tar.gz" \
  "$CACHE/glsl-shaders-${SHADERS_COMMIT}.tar.gz"
sudo tar -xzf "$CACHE/glsl-shaders-${SHADERS_COMMIT}.tar.gz" \
  --strip-components=1 -C "$PROFILE/shaders/shaders_glsl"
echo "✓ GLSL shaders"

# --- PS2 BIOS (from the NAS, dumped from the owner's console) ---
# Only loose files at the folder root (per-region subfolders, if any, are skipped).
if [[ -n "$(find "$BIOS_SRC" -maxdepth 1 -type f 2>/dev/null | head -1)" ]]; then
  find "$BIOS_SRC" -maxdepth 1 -type f -exec sudo cp -u {} "$PROFILE/system/pcsx2/bios/" \;
  echo "✓ PS2 BIOS copied from $BIOS_SRC"
else
  echo "! no BIOS in $BIOS_SRC - the PS2 core will not start until the files are placed there"
fi

# --- LRPS2 GameIndex.yaml (per-game hardware fixes; pinned by commit + sha256) ---
download "https://raw.githubusercontent.com/libretro/ps2/${GAMEINDEX_COMMIT}/bin/resources/GameIndex.yaml" \
  "$CACHE/GameIndex-${GAMEINDEX_COMMIT}.yaml" "$GAMEINDEX_SHA256"
sudo install -o "$APP_UID" -g "$APP_GID" -m 644 "$CACHE/GameIndex-${GAMEINDEX_COMMIT}.yaml" \
  "$PROFILE/system/pcsx2/resources/GameIndex.yaml"
echo "✓ LRPS2 GameIndex.yaml (commit ${GAMEINDEX_COMMIT:0:8})"

# --- Core options (merge: only the versioned keys, the rest stays as is) ---
merge_opts "$OPTS_SRC/LRPS2.opt" "$PROFILE/config/LRPS2/LRPS2.opt"
merge_opts "$OPTS_SRC/dolphin-emu.opt" "$PROFILE/config/dolphin-emu/dolphin-emu.opt"

# --- Global retroarch.cfg (exit/menu hotkey on the controller) ---
# merge_opts works here too: retroarch.cfg uses the same key = "value" format.
merge_opts "$CFG_SRC/retroarch-overrides.cfg" "$PROFILE/retroarch.cfg"

# --- Per-core overrides (config/<corename>/<corename>.cfg and .glslp) ---
# RetroArch automatically loads a .glslp with this name for the core.
for dir in "${CORE_DIRS_2D[@]}"; do
  merge_opts "$CORE_OVR_SRC/cores-2d.cfg" "$PROFILE/config/$dir/$dir.cfg"
done
for dir in "${CORE_DIRS_2D[@]}" "${CORE_DIRS_SHADER_ONLY[@]}"; do
  as_app "$PROFILE/config/$dir"
  sudo install -o "$APP_UID" -g "$APP_GID" -m 644 \
    "$CORE_OVR_SRC/crt-shader.glslp" "$PROFILE/config/$dir/$dir.glslp"
done
echo "✓ per-core overrides applied"

sudo chown -R "$APP_UID:$APP_GID" "$WOLF_DIR/profile-data/user/WolfRetroarch"
echo "OK - open RetroArch from Wolf UI and use Load Core/Load Content."
