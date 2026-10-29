#!/bin/bash
# Renders the postgres_exporter config (auth_modules for multi-target mode
# via /probe) for the container.
#   Source config is versioned in
#   infra/observability/metrics/exporters/postgres-exporter/config/postgres_exporter.yml
#   with placeholders __DB_USER__/__DB_PASSWORD__/__PAPERLESS_DBUSER__/
#   __PAPERLESS_DBPASS__; never commit a real password. This script replaces
#   them with the .env values and writes the result to
#   /opt/apps/postgres-exporter/postgres_exporter.yml, which the container
#   (postgres-exporter.yaml) mounts read-only.
# Rerun whenever a DB password or the versioned config changes (e.g. a new
# database is added), then run
# `docker compose up -d --force-recreate postgres-exporter` (single-file bind
# mount: same quirk as keepalived, the container does not see the new
# content until it is recreated).
# Runs only on zangetsu: the single postgres-exporter instance reaches the
# urahara databases via IP:port (network).
set -euo pipefail

REPO_DIR="/opt/homelab"
ENV_FILE="${HOMELAB_ENV:?HOMELAB_ENV is not set}"

CONF_SRC="$REPO_DIR/infra/observability/metrics/exporters/postgres-exporter/config/postgres_exporter.yml"
if [ ! -f "$CONF_SRC" ]; then
  echo "Error: source config not found at $CONF_SRC"
  exit 1
fi

get_var() {
  val=$(grep "^${1}=" "$ENV_FILE" | cut -d'=' -f2-)
  if [ -z "$val" ]; then
    echo "Error: ${1} not found in .env" >&2
    exit 1
  fi
  echo "$val"
}

DB_USER=$(get_var DB_USER)
DB_PASSWORD=$(get_var DB_PASSWORD)
PAPERLESS_DBUSER=$(get_var PAPERLESS_DBUSER)
PAPERLESS_DBPASS=$(get_var PAPERLESS_DBPASS)
EVOLUTION_DBUSER=$(get_var EVOLUTION_DBUSER)
EVOLUTION_DBPASS=$(get_var EVOLUTION_DBPASS)

mkdir -p /opt/apps/postgres-exporter
sed \
  -e "s/__DB_USER__/${DB_USER}/" \
  -e "s/__DB_PASSWORD__/${DB_PASSWORD}/" \
  -e "s/__PAPERLESS_DBUSER__/${PAPERLESS_DBUSER}/" \
  -e "s/__PAPERLESS_DBPASS__/${PAPERLESS_DBPASS}/" \
  -e "s/__EVOLUTION_DBUSER__/${EVOLUTION_DBUSER}/" \
  -e "s/__EVOLUTION_DBPASS__/${EVOLUTION_DBPASS}/" \
  "$CONF_SRC" > /opt/apps/postgres-exporter/postgres_exporter.yml

echo "✓ config rendered to /opt/apps/postgres-exporter/postgres_exporter.yml"
echo
echo "OK - now start/recreate the container:"
echo "  docker compose up -d --force-recreate postgres-exporter"
echo "  docker logs postgres-exporter --tail 30"
