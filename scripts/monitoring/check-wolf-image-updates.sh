#!/bin/sh
# Compares the pinned digests of the Wolf stack (wolf, wolf-ui, retroarch,
# es-de) with the current digest of each tag on GHCR and alerts via
# Healthchecks when one changed. Updates nothing: the pins are deliberate and
# bumping them requires a stream test.
# The "wolf-image-check" check is created via the Healthchecks API
# (idempotent via unique=name); requires a write-enabled HEALTHCHECKS_API_KEY.
# Runs in the Dagu container (docker.run, alpine + curl + jq) with the repo
# and zangetsu's .env mounted. DRY_RUN=1 only compares and prints, without
# contacting Healthchecks.
set -eu

REPO_DIR="${REPO_DIR:-/opt/homelab}"
ENV_FILE="${HOMELAB_ENV:-$REPO_DIR/hosts/zangetsu/.env}"
HC_URL="${HC_URL:-http://healthchecks:8000}"
DRY_RUN="${DRY_RUN:-0}"
ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"

PING_URL=""
on_exit() {
  status=$?
  if [ "$status" -ne 0 ] && [ -n "$PING_URL" ]; then
    curl -fsS -m 10 -o /dev/null --data-raw "error checking images (see the DAG log)" "$PING_URL/fail" || true
  fi
}
trap on_exit EXIT

if [ "$DRY_RUN" != "1" ]; then
  HC_KEY="$(grep '^HEALTHCHECKS_API_KEY=' "$ENV_FILE" | cut -d= -f2-)"
  PING_URL="$(curl -fsS -H "X-Api-Key: $HC_KEY" -H 'Content-Type: application/json' \
    -d '{"name":"wolf-image-check","slug":"wolf-image-check","tags":"homelab","desc":"Wolf pinned digests vs. GHCR (monthly)","timeout":2764800,"grace":172800,"unique":["name"]}' \
    "$HC_URL/api/v3/checks/" | jq -r '.ping_url // empty')"
  if [ -z "$PING_URL" ]; then
    echo "Error: the Healthchecks API returned no ping_url (HEALTHCHECKS_API_KEY must be write-enabled)"
    exit 1
  fi
fi

updates=""
# image name | tracked tag | file where the digest is pinned
while read -r name tag file; do
  [ -z "$name" ] && continue
  pinned="$(grep -oE "games-on-whales/${name}@sha256:[0-9a-f]{64}" "$REPO_DIR/$file" | head -1 | sed 's/.*@//')"
  token="$(curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:games-on-whales/${name}:pull" | jq -r .token)"
  latest="$(curl -fsSI -H "Authorization: Bearer $token" -H "Accept: $ACCEPT" \
    "https://ghcr.io/v2/games-on-whales/${name}/manifests/${tag}" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')"
  if [ -z "$pinned" ] || [ -z "$latest" ]; then
    echo "Error: could not resolve the digest of ${name}:${tag} (pinned='${pinned}', current='${latest}')"
    exit 1
  fi
  if [ "$pinned" = "$latest" ]; then
    echo "ok: ${name}:${tag} up to date"
  else
    echo "NEW: ${name}:${tag} pinned=${pinned} current=${latest}"
    updates="$updates ${name}:${tag}"
  fi
done <<EOF
wolf stable infra/media-player/wolf/wolf.yaml
wolf-ui main scripts/setup/setup-wolf-config.sh
retroarch edge scripts/setup/setup-wolf-config.sh
es-de edge scripts/setup/setup-wolf-config.sh
EOF

[ "$DRY_RUN" = "1" ] && exit 0

if [ -n "$updates" ]; then
  curl -fsS -m 10 -o /dev/null --data-raw "New digest on GHCR (update manually, with a stream test):$updates" "$PING_URL/fail"
else
  curl -fsS -m 10 -o /dev/null "$PING_URL"
fi
