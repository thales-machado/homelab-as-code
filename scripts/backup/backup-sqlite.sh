#!/bin/sh
# Consistent backup of the stack's SQLite databases.
#
# Restic copies /opt/apps "hot", so a backed-up copy of a SQLite DB in use can
# be inconsistent. This script uses SQLite's own .backup (consistent snapshot
# even while the service runs) and writes to <app>/db-backup/, which is inside
# the Restic scope. The live databases are excluded via restic-excludes.txt.
#
# Run by the Dagu DAG sqlite-backup at 02:30, before the Restic backup
# (restic-backup-zangetsu, 02:40).

set -u

KEEP=7
STAMP="$(date +%Y%m%d-%H%M%S)"
FAIL=0

backup_db() {
    db="$1"
    if [ ! -f "$db" ]; then
        echo "ERROR: ${db} not found"
        return 1
    fi

    dir="$(dirname "$db")/db-backup"
    name="$(basename "$db")"
    name="${name%.*}"
    out="${dir}/${name}-${STAMP}.sqlite3"

    mkdir -p "$dir"
    sqlite3 "$db" ".backup '${out}'" || { echo "ERROR: .backup failed for ${db}"; return 1; }

    check="$(sqlite3 "$out" "PRAGMA integrity_check;")"
    if [ "$check" != "ok" ]; then
        echo "ERROR: integrity_check failed for ${out}: ${check}"
        return 1
    fi

    # keep only the N most recent
    ls -1t "${dir}/${name}"-*.sqlite3 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

    echo "$(date -Is) backup OK: ${out} ($(du -h "$out" | cut -f1))"
}

for db in \
    /opt/apps/vaultwarden/db.sqlite3 \
    /opt/apps/grafana/grafana.db \
    /opt/apps/uptime-kuma/kuma.db \
    /opt/apps/healthchecks/hc.sqlite \
    /opt/apps/scrutiny/scrutiny.db
do
    backup_db "$db" || FAIL=1
done

exit $FAIL
