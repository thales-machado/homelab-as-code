#!/bin/bash
# =============================================================================
# sync-pihole-dns.sh — Syncs DNS records to Pi-hole v6 via its API
# =============================================================================
# Usage: bash scripts/networking/sync-pihole-dns.sh
# Requires: curl, jq, python3
# Endpoint: PATCH /api/config with a hosts array in "IP hostname" format
# =============================================================================

set -uo pipefail

# =============================================================================
# Settings
# =============================================================================
HOMELAB_ENV="/opt/homelab/hosts/zangetsu/.env"
PIHOLE_URL="http://172.22.0.240"
DNS_FILE="/opt/homelab/infra/platform/networking/pi-hole/config/pihole-dns.yaml"

if [ ! -f "$HOMELAB_ENV" ]; then
  echo "❌ .env file not found: $HOMELAB_ENV"
  exit 1
fi

PIHOLE_PASSWORD=$(grep '^ADMIN_PASSWORD=' "$HOMELAB_ENV" | cut -d'=' -f2)

if [ -z "$PIHOLE_PASSWORD" ]; then
  echo "❌ ADMIN_PASSWORD not found in $HOMELAB_ENV"
  exit 1
fi

# =============================================================================
# Check dependencies
# =============================================================================
for cmd in curl jq python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Missing dependency: $cmd"
    exit 1
  fi
done

if [ ! -f "$DNS_FILE" ]; then
  echo "❌ File not found: $DNS_FILE"
  exit 1
fi

# =============================================================================
# Authenticate
# =============================================================================
echo "🔐 Authenticating to Pi-hole..."
AUTH_RESPONSE=$(curl -s -X POST "${PIHOLE_URL}/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"password\": \"${PIHOLE_PASSWORD}\"}" || true)

if [ -z "$AUTH_RESPONSE" ]; then
  echo "❌ No response from Pi-hole at ${PIHOLE_URL}"
  exit 1
fi

TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.session.sid' 2>/dev/null || true)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "❌ Authentication failed. Response: $AUTH_RESPONSE"
  exit 1
fi

echo "✅ Authenticated successfully"

# =============================================================================
# Read records from the yaml (single source of truth)
# =============================================================================
echo "🔄 Processing records from the yaml..."
MERGED=$(python3 - << PYEOF
import yaml, json, sys

try:
    with open('${DNS_FILE}') as f:
        data = yaml.safe_load(f)
    hosts = []
    for r in data.get('records', []):
        if r.get('domain') and r.get('ip'):
            hosts.append(f"{r['ip']} {r['domain']}")
    print(json.dumps(hosts))
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

if [ -z "$MERGED" ]; then
  echo "❌ Failed to process the yaml file"
  exit 1
fi

TOTAL=$(echo "$MERGED" | jq 'length')
echo "📦 Total records to apply: ${TOTAL}"

# =============================================================================
# Apply via PATCH
# =============================================================================
echo "🚀 Applying records to Pi-hole..."
PATCH_RESPONSE=$(curl -s -X PATCH "${PIHOLE_URL}/api/config" \
  -H "Content-Type: application/json" \
  -H "X-FTL-SID: ${TOKEN}" \
  -d "{\"config\": {\"dns\": {\"hosts\": ${MERGED}}}}" || true)

if [ -z "$PATCH_RESPONSE" ]; then
  echo "❌ No response while applying records"
  exit 1
fi

APPLIED=$(echo "$PATCH_RESPONSE" | jq -r '.config.dns.hosts | length' 2>/dev/null || echo "0")

if [ "$APPLIED" = "0" ]; then
  echo "❌ Failed to apply records. Response: $(echo "$PATCH_RESPONSE" | jq -r '.error // "unknown"')"
  exit 1
fi

# =============================================================================
# Close the session
# =============================================================================
curl -s -X DELETE "${PIHOLE_URL}/api/auth" \
  -H "X-FTL-SID: ${TOKEN}" > /dev/null || true

echo ""
echo "✅ Sync complete — ${APPLIED} active records in Pi-hole"

# =============================================================================
# Propagate to the replica. Nebula Sync runs every 6h; without this the
# replica diverges until its next internal CRON cycle. nebula-sync has no
# HTTP trigger and only reruns the full sync on process startup, hence the
# container restart.
# =============================================================================
echo "🔁 Propagating to the replica via Nebula Sync..."
if docker restart nebula-sync > /dev/null 2>&1; then
  echo "✅ Nebula Sync triggered"
else
  echo "⚠️  Could not restart nebula-sync - the replica may stay stale until the next cycle (6h)"
fi
