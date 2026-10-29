#!/bin/bash
# Merges into ES-DE's es_settings.xml (WolfES-DE profile) the keys versioned in
# infra/media-player/wolf/config/es-de/es-settings-overrides.txt (format
# "<type> <Key> <value>", one per line). Only touches the listed keys; the rest
# of the file stays as is.
# Also installs the custom PCSX2 find rule (es_find_rules.xml) and the wrapper
# it points to (pcsx2-launch.sh). Without them the per-game Alternative
# emulator "PCSX2" (e.g. Gran Turismo 4, which renders corrupted on the LRPS2
# core) fails with "emulator not found", because ES-DE's default find rule
# looks for the AppImage in ~/Applications and Wolf's stock launcher does not
# pass %ROM% to the AppImage.
# es_settings.xml stores the ScreenScraper credentials in plain text, so it is
# never versioned and the script rejects any credential key.
# ES-DE rewrites the file on exit, so the script aborts if a Wolf session is
# open; FORCE=1 skips the check. Idempotent. Requires sudo.
set -euo pipefail

REPO_DIR="/opt/homelab"
PROFILE="/opt/apps/wolf/profile-data/user/WolfES-DE"
SETTINGS="$PROFILE/ES-DE/settings/es_settings.xml"
OVERRIDES="$REPO_DIR/infra/media-player/wolf/config/es-de/es-settings-overrides.txt"
FIND_RULES_SRC="$REPO_DIR/infra/media-player/wolf/config/es-de/es_find_rules.xml"
PCSX2_LAUNCH_SRC="$REPO_DIR/infra/media-player/wolf/config/es-de/pcsx2-launch.sh"

if ! sudo test -f "$SETTINGS"; then
  echo "Error: $SETTINGS does not exist - open ES-DE once through Moonlight first"
  exit 1
fi

APP_CONTAINERS="$(sudo docker ps --format '{{.Names}}' | grep '^Wolf' || true)"
if [[ -n "$APP_CONTAINERS" && "${FORCE:-0}" != "1" ]]; then
  echo "Error: a Wolf session is open ($(echo "$APP_CONTAINERS" | tr '\n' ' '))."
  echo "Close Moonlight and run again (or FORCE=1 to skip the check)."
  exit 1
fi

sudo install -d -o 1000 -g 1000 "$PROFILE/ES-DE/custom_systems" "$PROFILE/bin"
sudo install -o 1000 -g 1000 -m 644 "$FIND_RULES_SRC" "$PROFILE/ES-DE/custom_systems/es_find_rules.xml"
sudo install -o 1000 -g 1000 -m 755 "$PCSX2_LAUNCH_SRC" "$PROFILE/bin/pcsx2-launch.sh"
echo "✓ es_find_rules.xml and pcsx2-launch.sh installed"

sudo cp -p "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"

sudo SETTINGS="$SETTINGS" OVERRIDES="$OVERRIDES" python3 - <<'PY'
import os
import re

settings = os.environ["SETTINGS"]
text = open(settings, encoding="utf-8").read()

for raw in open(os.environ["OVERRIDES"], encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    kind, name, value = line.split(None, 2)
    if kind not in ("bool", "int", "string"):
        raise SystemExit(f"Error: invalid type in '{line}'")
    if re.search(r"password|username|token|secret|key", name, re.I):
        raise SystemExit(f"Error: credential keys are not allowed: {name}")
    entry = f'<{kind} name="{name}" value="{value}" />'
    pattern = rf'<(?:bool|int|string) name="{re.escape(name)}" value="[^"]*" />'
    if re.search(pattern, text):
        text = re.sub(pattern, lambda m: entry, text, count=1)
    else:
        text = text.rstrip("\n") + "\n" + entry + "\n"
    print(f"✓ {name} = {value}")

open(settings, "w", encoding="utf-8").write(text)
PY

sudo chown 1000:1000 "$SETTINGS"
echo "OK - open ES-DE through Moonlight to check."
