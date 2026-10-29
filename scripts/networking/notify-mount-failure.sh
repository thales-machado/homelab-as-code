#!/bin/bash
# Notifies a NAS mount failure via the Homelab Notify (n8n) webhook.
# Usage: notify-mount-failure.sh <label>
# Called by the notify-*-mount-failure.service units via the mounts' OnFailure=.
set -euo pipefail

ENV_FILE="${HOMELAB_ENV:?HOMELAB_ENV is not set}"
MOUNT_LABEL="${1:?usage: notify-mount-failure.sh <label>}"

SECRET=$(grep '^N8N_WEBHOOK_SECRET=' "$ENV_FILE" | cut -d'=' -f2-)
NODE_HOSTNAME=$(grep '^NODE_HOSTNAME=' "$ENV_FILE" | cut -d'=' -f2-)
PAYLOAD="{\"action\":\"mount-failure\",\"mount\":\"${MOUNT_LABEL}\",\"host\":\"${NODE_HOSTNAME}\"}"

SIGNATURE="sha256=$(printf '%s' "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $2}')"

curl -s -X POST "https://n8n.lan.example.com/webhook/homelab-notify" \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: ${SIGNATURE}" \
  -d "$PAYLOAD"
