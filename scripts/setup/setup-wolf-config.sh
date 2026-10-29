#!/bin/bash
# Applies the declarative part of the apps to Wolf's config.toml (urahara):
# Wolf UI, RetroArch and EmulationStation (ES-DE), with pinned image, mounts
# and CPU/memory limits. Every other app in the default config (Steam,
# Firefox, Lutris, Prismlauncher, Pegasus, Desktop, Kodi, Test ball) is
# removed: they use a floating :edge image with no limits, and opening them
# would download several GB unchecked.
# config.toml is Wolf state (it stores paired clients in [[paired_clients]]
# and the uuid), so it is not versioned whole: the script only edits these
# apps' blocks and keeps the rest.
# App containers are created by Wolf, outside compose, so the limits go in
# base_create_json (HostConfig), not in yaml cpus/mem_limit.
# ES-DE launches RetroArch as a subprocess inside its own container, so it
# gets the same limits. It reuses the RetroArch profile (cores, BIOS, shaders,
# saves and retroarch.cfg) mounted at ~/.config/retroarch: a single
# provisioning step (setup-wolf-retroarch.sh), no drift between the two apps.
# Only one session runs at a time, so there are no concurrent writes.
# The MAME BIOS (e.g. neogeo.zip) lives in its own NAS mount
# (retro/bios/mame → /bios-mame, read-only, outside both apps' $HOME) instead
# of being copied into the local profile: the user manages the file directly
# on the NAS, with no SSH access to the host needed for each change.
# Real quirk: the ES-DE image's setup-de.sh runs "chown -R $HOME/.config"
# under set -e on every start. If the mount were inside $HOME (e.g. directly
# at system/mame/bios), chown would fail on the first read-only NAS file and
# kill the container (RetroArch is not affected; it has no such script). So
# the mount goes to /bios-mame (outside $HOME) and setup-wolf-retroarch.sh
# creates a symlink at system/mame/bios pointing there: chown -R does not
# follow symlinks when recursing (it only changes the link's own owner), so it
# never enters the read-only mount.
# Restarts wolf (dropping any open session), so it aborts if an app container
# is running; FORCE=1 skips the check.
# First-deploy order: start wolf (creates config.toml), run this script, then
# setup-wolf-retroarch.sh. Idempotent. Requires sudo.
set -euo pipefail

CONFIG="/opt/apps/wolf/cfg/config.toml"
WOLFUI_IMAGE="ghcr.io/games-on-whales/wolf-ui@sha256:cd6de1158b29068e4a4d4ce6312976067517239be97200a391be758a6ddfcf9b"
RA_IMAGE="ghcr.io/games-on-whales/retroarch@sha256:bbcf4523e589fc7177b522ce56ba9507c6530caaf1999e37b37062a189f18cf2"
ESDE_IMAGE="ghcr.io/games-on-whales/es-de@sha256:f5d1037e9dd6ff7406e190e00457152d0a9dcb4adbc32fe2132585cb5bbe7829"
RETRO_NAS="/mnt/games-4tb/retro"
RA_PROFILE_CFG="/opt/apps/wolf/profile-data/user/WolfRetroarch/.config/retroarch"
ESDE_MEDIA="/opt/apps/wolf/es-de-media"
ESDE_PROFILE="/opt/apps/wolf/profile-data/user/WolfES-DE"
EMU_NANO_CPUS=4000000000
EMU_MEMORY_BYTES=3221225472
UI_NANO_CPUS=1000000000
UI_MEMORY_BYTES=536870912

if ! sudo test -f "$CONFIG"; then
  echo "Error: $CONFIG does not exist - start wolf first (docker compose up -d wolf)"
  exit 1
fi

# App containers (Wolf-UI, WolfRetroarch_*, WolfES-DE_*) only exist while a
# client is connected; stopping wolf with one of them up ends the session.
APP_CONTAINERS="$(sudo docker ps --format '{{.Names}}' | grep '^Wolf' || true)"
if [[ -n "$APP_CONTAINERS" && "${FORCE:-0}" != "1" ]]; then
  echo "Error: a Wolf session is open ($(echo "$APP_CONTAINERS" | tr '\n' ' '))."
  echo "Close Moonlight and run again (or FORCE=1 to skip the check)."
  exit 1
fi

# ES-DE scraper covers/videos (MediaDirectory=/media in the image). Must be
# writable by the app's UID; the ROM folder is read-only.
sudo install -d -o 1000 -g 1000 "$ESDE_MEDIA" "$RA_PROFILE_CFG"
# Docker would create the ES-DE profile's .config as root when mounting
# retroarch inside it, and the app (UID 1000) could not write sway/waybar.
sudo install -d -o 1000 -g 1000 "$ESDE_PROFILE" "$ESDE_PROFILE/.config"

# Wolf rewrites config.toml when pairing a client and on startup; stopping it
# first keeps it from overwriting the edit with its in-memory state.
WAS_RUNNING=false
if sudo docker ps --format '{{.Names}}' | grep -qx wolf; then
  WAS_RUNNING=true
  sudo docker stop wolf >/dev/null
  echo "✓ wolf stopped"
fi

sudo cp "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d-%H%M%S)"

sudo WOLFUI_IMAGE="$WOLFUI_IMAGE" RA_IMAGE="$RA_IMAGE" ESDE_IMAGE="$ESDE_IMAGE" \
  RETRO_NAS="$RETRO_NAS" RA_PROFILE_CFG="$RA_PROFILE_CFG" ESDE_MEDIA="$ESDE_MEDIA" \
  EMU_NANO_CPUS="$EMU_NANO_CPUS" EMU_MEMORY_BYTES="$EMU_MEMORY_BYTES" \
  UI_NANO_CPUS="$UI_NANO_CPUS" UI_MEMORY_BYTES="$UI_MEMORY_BYTES" \
  CONFIG="$CONFIG" python3 - <<'PY'
import json
import os
import re

path = os.environ["CONFIG"]
text = open(path, encoding="utf-8").read()
nas = os.environ["RETRO_NAS"]

# mounts=None keeps the mounts the default config already has (Wolf UI uses
# Wolf's own socket).
APPS = {
    "Wolf UI": {
        "image": os.environ["WOLFUI_IMAGE"],
        "mounts": None,
        "nano_cpus": int(os.environ["UI_NANO_CPUS"]),
        "memory": int(os.environ["UI_MEMORY_BYTES"]),
    },
    "RetroArch": {
        "image": os.environ["RA_IMAGE"],
        "mounts": [
            f"{nas}/roms:/roms:ro",
            f"{nas}/bios/mame:/bios-mame:ro",
        ],
        "nano_cpus": int(os.environ["EMU_NANO_CPUS"]),
        "memory": int(os.environ["EMU_MEMORY_BYTES"]),
    },
    "EmulationStation": {
        "image": os.environ["ESDE_IMAGE"],
        "mounts": [
            f"{nas}/roms:/ROMs:ro",
            f"{nas}/bios:/bioses:ro",
            f"{os.environ['RA_PROFILE_CFG']}:/home/retro/.config/retroarch",
            f"{nas}/bios/mame:/bios-mame:ro",
            f"{os.environ['ESDE_MEDIA']}:/media",
        ],
        "nano_cpus": int(os.environ["EMU_NANO_CPUS"]),
        "memory": int(os.environ["EMU_MEMORY_BYTES"]),
    },
}

TITLE_RE = r"(?m)^\s*title\s*=\s*['\"]([^'\"]*)['\"]"
APP_HEADER_RE = r"^\s*\[\[profiles\.apps\]\]"


def make_patch_json(spec):
    def patch_json(m):
        quote, body = m.group(2), m.group(3)
        # Wolf's default config.toml ends the string with a "\" line (TOML
        # line-ending backslash, which the parser discards); without this the JSON breaks
        body = body.strip().rstrip("\\").strip()
        data = json.loads(body)
        host = data.setdefault("HostConfig", {})
        host["NanoCpus"] = spec["nano_cpus"]
        host["Memory"] = spec["memory"]
        host["MemorySwap"] = spec["memory"]
        return f"{m.group(1)}{quote}{json.dumps(data, indent=2)}\n{quote}"
    return patch_json


# Split into blocks at the [[profiles]] / [[profiles.apps]] headers
parts = re.split(r"(?m)^(?=\s*\[\[profiles(?:\.apps)?\]\])", text)

for title, spec in APPS.items():
    idx = [i for i, p in enumerate(parts)
           if re.match(APP_HEADER_RE, p)
           and (t := re.search(TITLE_RE, p)) and t.group(1) == title]
    if len(idx) != 1:
        raise SystemExit(f"Error: expected 1 block for app {title}, found {len(idx)}")
    block = parts[idx[0]]

    block = re.sub(r"(?m)^(\s*image\s*=\s*)['\"][^'\"]*['\"]",
                   lambda m: f"{m.group(1)}'{spec['image']}'", block, count=1)
    if spec["mounts"] is not None:
        mounts = ", ".join(f"'{m}'" for m in spec["mounts"])
        block = re.sub(r"(?m)^(\s*mounts\s*=\s*)\[[^\]]*\]",
                       lambda m: f"{m.group(1)}[ {mounts} ]", block, count=1)

    block, n = re.subn(r"(?s)(base_create_json\s*=\s*)('''|\"\"\")(.*?)\2",
                       make_patch_json(spec), block, count=1)
    if n != 1:
        raise SystemExit(f"Error: base_create_json for {title} not found")

    parts[idx[0]] = block
    print(f"OK: {title} block updated")

# Remove apps not in the list. [[profiles.apps]] blocks always come last in
# each profile (paired_clients comes before [[profiles]]), so dropping a part
# never takes a table of another kind with it.
kept = []
for p in parts:
    if re.match(APP_HEADER_RE, p):
        t = re.search(TITLE_RE, p)
        if t and t.group(1) not in APPS:
            print(f"removed: {t.group(1)}")
            continue
    kept.append(p)

open(path, "w", encoding="utf-8").write("".join(kept))
PY

if [[ "$WAS_RUNNING" == true ]]; then
  sudo docker start wolf >/dev/null
  echo "✓ wolf started"
fi
echo "OK - verify: sudo grep -E \"title = |image = |mounts = \" $CONFIG"
