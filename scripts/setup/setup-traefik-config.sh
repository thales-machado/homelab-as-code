#!/bin/bash
# Renders the Traefik dynamic config (middlewares.yml with the
# __CROWDSEC_BOUNCER_KEY__ placeholder) and copies the other versioned source
# config files to /opt/apps/traefik/, which the container mounts read-only.
# Rerun whenever CROWDSEC_BOUNCER_KEY or the versioned config changes, then
# run `docker compose up -d --force-recreate traefik`.
set -euo pipefail

REPO_DIR="/opt/homelab"
ENV_FILE="${HOMELAB_ENV:?HOMELAB_ENV is not set}"
SRC_DIR="$REPO_DIR/infra/platform/networking/traefik/config"

CROWDSEC_KEY=$(grep '^CROWDSEC_BOUNCER_KEY=' "$ENV_FILE" | cut -d'=' -f2-)
if [ -z "$CROWDSEC_KEY" ]; then
  echo "Error: CROWDSEC_BOUNCER_KEY not found in .env"
  exit 1
fi

mkdir -p /opt/apps/traefik/dynamic /opt/apps/traefik/acme

sed "s/__CROWDSEC_BOUNCER_KEY__/${CROWDSEC_KEY}/" \
  "$SRC_DIR/dynamic/middlewares.yml" > /opt/apps/traefik/dynamic/middlewares.yml
cp "$SRC_DIR/dynamic/cross-host.yml" /opt/apps/traefik/dynamic/cross-host.yml

# acme.json must exist with 0600 BEFORE the first start; Traefik refuses to
# start if the permissions are more open.
if [ ! -f /opt/apps/traefik/acme/acme.json ]; then
  touch /opt/apps/traefik/acme/acme.json
fi
chmod 600 /opt/apps/traefik/acme/acme.json

echo "✓ config rendered to /opt/apps/traefik/dynamic/"
echo "✓ acme.json permissions confirmed as 600"
echo ""
echo "OK - now start/recreate the container:"
echo "  docker compose up -d --force-recreate traefik"
echo "  docker logs traefik --tail 30"
