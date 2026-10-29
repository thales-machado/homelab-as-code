#!/bin/sh
# Consistent backup of the SQLite databases of apps running on urahara.
#
# Same logic as backup-sqlite.sh (zangetsu), kept separate because that
# script uses absolute local paths (/opt/apps/...) and only works for apps on
# the SAME host as Dagu (zangetsu). SQLite apps on urahara (e.g. Home
# Assistant) must run via ssh.run + a remote docker run on urahara itself
# (see infra/automation/dagu/dags/sqlite-backup-urahara.yaml, same
# cross-host pattern as restic-backup-urahara.yaml).
#
# Run by the Dagu DAG sqlite-backup-urahara, before Restic.

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
    /opt/apps/home-assistant/config/home-assistant_v2.db \
    /opt/apps/trilium/document.db \
    /opt/apps/crowdsec/data/crowdsec.db \
    /opt/apps/vikunja/db/vikunja.db
do
    backup_db "$db" || FAIL=1
done

exit $FAIL
