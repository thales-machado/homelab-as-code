#!/bin/sh
# Renames the JSON files produced by `n8n export:workflow --backup` (named
# only by ID) to <sanitized-name>__<id>.json, using the n8n API as the
# id->name map. Runs after the export step in the same n8n-backup-urahara DAG.
#
# Requires curl+jq in the container (installed in the DAG's command:) and
# N8N_API_KEY exported in the environment before this script is called.

set -u

DIR="/opt/apps/n8n/db-backup/workflows-json"

if [ -z "${N8N_API_KEY:-}" ]; then
    echo "ERROR: N8N_API_KEY is not set"
    exit 1
fi

if [ ! -d "$DIR" ]; then
    echo "ERROR: ${DIR} not found — did the export fail before this step?"
    exit 1
fi

map="$(curl -fsS -H "X-N8N-API-KEY: ${N8N_API_KEY}" "http://n8n:5678/api/v1/workflows?limit=250" \
    | jq -r '.data[] | "\(.id)\t\(.name)"')" || { echo "ERROR: failed to query the n8n API"; exit 1; }

FAIL=0
for f in "$DIR"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json)"
    # already renamed in a previous run (contains "__"): skip
    case "$id" in *__*) continue ;; esac

    nome="$(printf '%s\n' "$map" | awk -F'\t' -v id="$id" '$1 == id { print $2; exit }')"
    if [ -z "$nome" ]; then
        echo "WARNING: workflow ${id} not found in the API (deleted?) — keeping old name"
        continue
    fi

    slug="$(printf '%s' "$nome" | tr -c 'A-Za-z0-9' '-' | tr -s '-' | sed 's/^-//;s/-$//')"
    novo="${DIR}/${slug}__${id}.json"
    mv "$f" "$novo" || { echo "ERROR: failed to rename ${f}"; FAIL=1; continue; }
    echo "renamed: ${id} -> $(basename "$novo")"
done

# remove leftovers from previous runs whose workflow no longer exists in the API
for f in "$DIR"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json | sed 's/^.*__//')"
    if ! printf '%s\n' "$map" | awk -F'\t' -v id="$id" '$1 == id { found=1 } END { exit !found }'; then
        echo "removing orphan (workflow deleted): $(basename "$f")"
        rm -f "$f"
    fi
done

exit $FAIL
