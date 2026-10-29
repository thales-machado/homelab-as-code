#!/bin/bash
# Renders the keepalived config (Pi-hole HA VIP) for the container.
#   Source config is versioned in scripts/setup/keepalived/keepalived-<host>.conf
#   with a __VRRP_PASS__ placeholder; never commit the real password. This
#   script replaces the placeholder with the .env value and writes the result
#   to /opt/apps/keepalived/keepalived.conf, which the container
#   (network_mode: host, infra/platform/networking/keepalived/keepalived.yaml)
#   mounts read-only.
# Rerun whenever the VRRP password or the versioned config changes, then run
# `docker compose up -d --force-recreate keepalived` (single-file bind mount:
# the container does not see the new content until it is recreated).
set -euo pipefail

REPO_DIR="/opt/homelab"
ENV_FILE="${HOMELAB_ENV:?HOMELAB_ENV is not set}"
# the OS hostname can differ from the name used in the repo (e.g. zangetsu
# is "lemon-pi5" in the OS), so derive it from the HOMELAB_ENV path
# (hosts/<name>/.env, the real source of truth) instead of `hostname -s`
HOSTNAME_SHORT="$(basename "$(dirname "$ENV_FILE")")"

CONF_SRC="$REPO_DIR/scripts/setup/keepalived/keepalived-${HOSTNAME_SHORT}.conf"
if [ ! -f "$CONF_SRC" ]; then
  echo "Error: no versioned config for this host (${HOSTNAME_SHORT})."
  echo "Expected: $CONF_SRC"
  exit 1
fi

VRRP_PASS=$(grep '^KEEPALIVED_VRRP_PASS=' "$ENV_FILE" | cut -d'=' -f2-)
if [ -z "$VRRP_PASS" ]; then
  echo "Error: KEEPALIVED_VRRP_PASS not found in .env (must match on both hosts)"
  exit 1
fi

mkdir -p /opt/apps/keepalived
sed "s/__VRRP_PASS__/${VRRP_PASS}/" "$CONF_SRC" > /opt/apps/keepalived/keepalived.conf
echo "✓ config rendered to /opt/apps/keepalived/keepalived.conf"

echo "OK - now start/recreate the container:"
echo "  docker compose up -d --force-recreate keepalived"
echo "  docker logs keepalived --tail 30"
echo "  ip -o -4 addr show | grep 192.168.10.248   # should only show up on the MASTER host (zangetsu)"
