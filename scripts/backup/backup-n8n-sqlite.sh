#!/bin/sh
# Consistent backup of the n8n SQLite DB. Runs on urahara via ssh.run (see
# DAG n8n-backup-urahara). Same mechanism as backup-sqlite.sh (which covers
# the SQLite DBs still local to zangetsu); kept separate because this one
# runs remotely via ssh.run instead of a local docker.run.

set -u

DB=/opt/apps/n8n/database.sqlite
DIR=/opt/apps/n8n/db-backup
KEEP=7
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ ! -f "$DB" ]; then
    echo "ERROR: ${DB} not found"
    exit 1
fi

out="${DIR}/database-${STAMP}.sqlite3"
mkdir -p "$DIR"
sqlite3 "$DB" ".backup '${out}'" || { echo "ERROR: .backup failed for ${DB}"; exit 1; }

check="$(sqlite3 "$out" "PRAGMA integrity_check;")"
if [ "$check" != "ok" ]; then
    echo "ERROR: integrity_check failed for ${out}: ${check}"
    exit 1
fi

ls -1t "${DIR}"/database-*.sqlite3 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "$(date -Is) backup OK: ${out} ($(du -h "$out" | cut -f1))"

# The official n8n image does not expose `sh` in its entrypoint (it only
# accepts `n8n` subcommands as direct argv), so the next DAG step
# (export-n8n-workflows) cannot run its own `mkdir -p`/`chown`. The directory
# must already exist and be owned by uid 1000 (the image's "node" user)
# before that step runs.
mkdir -p "${DIR}/workflows-json"
chown -R 1000:1000 "${DIR}/workflows-json"
