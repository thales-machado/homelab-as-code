#!/bin/sh
# Filesystem backup (/opt + /etc) via Restic.
#
# The repository is a local path (CIFS mount of the NAS share lemon-drive,
# mounted by the host at /mnt/backup/<host> and passed to the container as
# /repo). No remote storage credentials, only RESTIC_PASSWORD (repo encryption).
#
# Run by the Dagu DAGs restic-backup-zangetsu/restic-backup-urahara, after
# sqlite-backup/postgres-backup (which write consistent database snapshots to
# <app>/db-backup/; this backup picks them up like any other file).
#
# Usage: backup-restic.sh <host-tag>

set -eu

HOST_TAG="${1:?usage: backup-restic.sh <host-tag>}"
EXCLUDE_FILE="/opt/homelab/scripts/backup/restic-excludes.txt"

export RESTIC_REPOSITORY="/repo"

# Idempotent bootstrap: the first run initializes the repo (the NAS folder
# starts empty); later runs only confirm it exists.
if ! restic cat config > /dev/null 2>&1; then
    echo "Empty repository - initializing..."
    restic init
fi

# Fixed --host: the ephemeral container (alpine:3) gets a random hostname
# from Docker on every run. Without it restic never finds the previous
# snapshot as parent (parent is selected by hostname+paths), loses the
# optimization that skips files with unchanged mtime/size, and rehashes
# everything every time. (Real bug: the first production run took 18 min for
# 58 GB because of this and exceeded the healthcheck grace period.)
restic backup /source/opt /source/etc \
    --host "$HOST_TAG" \
    --exclude-file="$EXCLUDE_FILE" \
    --tag "$HOST_TAG"
