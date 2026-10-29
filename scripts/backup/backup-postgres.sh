#!/bin/sh
# Consistent backup of the stack's Postgres databases via pg_dump.
#
# Postgres counterpart of backup-sqlite.sh: copying the data dir of a running
# Postgres does not guarantee a restorable snapshot (WAL/checkpoint may be
# mid-write). pg_dump connects over the network and writes a consistent
# logical dump to <app>/db-backup/, inside the Restic scope. The live data
# dir (<app>/db/) is excluded via restic-excludes.txt.
#
# Run by the Dagu DAG postgres-backup at 02:35, before the Restic backup
# (restic-backup-zangetsu, 02:40).

set -u

KEEP=7
STAMP="$(date +%Y%m%d-%H%M%S)"
FAIL=0

backup_db() {
    host="$1"
    user="$2"
    dbname="$3"
    app_dir="$4"
    port="${5:-5432}"

    dir="${app_dir}/db-backup"
    out="${dir}/${dbname}-${STAMP}.dump"

    mkdir -p "$dir"

    if ! pg_dump -h "$host" -p "$port" -U "$user" -Fc "$dbname" > "$out" 2>/tmp/pg_dump_err.$$; then
        echo "ERROR: pg_dump failed for ${host}/${dbname}: $(cat /tmp/pg_dump_err.$$)"
        rm -f "$out" /tmp/pg_dump_err.$$
        return 1
    fi
    rm -f /tmp/pg_dump_err.$$

    if [ ! -s "$out" ]; then
        echo "ERROR: empty dump at ${out}"
        return 1
    fi

    # keep only the N most recent
    ls -1t "${dir}/${dbname}"-*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

    echo "$(date -Is) backup OK: ${out} ($(du -h "$out" | cut -f1))"
}

# paperless-db runs on urahara (192.168.10.215). Container names only resolve
# on the Docker network of the same host, hence the IP instead of a hostname.
PGPASSWORD="${PAPERLESS_DBPASS}" backup_db "192.168.10.215" "${PAPERLESS_DBUSER}" "${PAPERLESS_DBNAME}" "/opt/apps/paperless" || FAIL=1
PGPASSWORD="${DB_PASSWORD}" backup_db "firefly-db" "${DB_USER}" "${FIREFLY_DB_NAME}" "/opt/apps/firefly-iii" || FAIL=1
# immich-db on urahara (192.168.10.215:5433; 5432 is paperless-db on the same host)
PGPASSWORD="${DB_PASSWORD}" backup_db "192.168.10.215" "${DB_USER}" "${IMMICH_DB_NAME}" "/opt/apps/immich" 5433 || FAIL=1
# tandoor-db on urahara (192.168.10.215:5434; 5432/5433 already taken)
PGPASSWORD="${DB_PASSWORD}" backup_db "192.168.10.215" "${DB_USER}" "${TANDOOR_DB_NAME}" "/opt/apps/tandoor" 5434 || FAIL=1
# komodo-postgres on zangetsu (Komodo's FerretDB backend); default database "postgres"
PGPASSWORD="${DB_PASSWORD}" backup_db "komodo-postgres" "${DB_USER}" "postgres" "/opt/apps/komodo" || FAIL=1
# evolution-db on urahara (192.168.10.215:5435; 5432/5433/5434 already taken)
PGPASSWORD="${EVOLUTION_DBPASS}" backup_db "192.168.10.215" "${EVOLUTION_DBUSER}" "evolution" "/opt/apps/evolution-api" 5435 || FAIL=1

exit $FAIL
