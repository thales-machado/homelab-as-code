#!/bin/bash
# Enables the hardware watchdog (systemd pets /dev/watchdog) as last-resort
# self-healing for kernel hangs (e.g. an RCU livelock under looping OOM; a
# real incident on urahara left SSH/Docker dead for 4h until a manual reboot).
# While the kernel responds, systemd "feeds" the watchdog periodically; if the
# system truly hangs (nothing runs, not even SSH), nobody feeds it and the
# chip forces a hardware reboot on its own.
#
# Only covers a whole-KERNEL hang. Not to be confused with the container
# auto-restart on OOM (Grafana alert "container-oom" -> webhook -> n8n
# "Homelab Notify" -> "Homelab | Ops - Commands" action=restart-container),
# which reacts BEFORE the system hangs.
#
# Requires sudo; run manually:
#   sudo bash scripts/setup/setup-watchdog.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root (sudo bash scripts/setup/setup-watchdog.sh)"
  exit 1
fi

if [ ! -e /dev/watchdog ]; then
  echo "Error: /dev/watchdog does not exist on this host - no kernel-supported hardware watchdog."
  echo "Check the driver (e.g. sp5100_tco on AMD chipsets, iTCO_wdt on Intel) before proceeding."
  exit 1
fi

CONF=/etc/systemd/system.conf
RUNTIME_LINE="RuntimeWatchdogSec=1min"
REBOOT_LINE="RebootWatchdogSec=10min"

for line in "$RUNTIME_LINE" "$REBOOT_LINE"; do
  key="${line%%=*}"
  if grep -qE "^${key}=" "$CONF"; then
    sed -i "s/^${key}=.*/${line}/" "$CONF"
  elif grep -qE "^#${key}=" "$CONF"; then
    sed -i "s/^#${key}=.*/${line}/" "$CONF"
  else
    echo "$line" >> "$CONF"
  fi
done

echo "✓ $CONF updated:"
grep -E '^(RuntimeWatchdogSec|RebootWatchdogSec)=' "$CONF"

# Re-exec PID 1 to apply without a reboot; systemd rereads system.conf during this operation.
systemctl daemon-reexec

ACTIVE=$(systemctl show -p RuntimeWatchdogUSec --value)
echo "✓ RuntimeWatchdogUSec active: ${ACTIVE}"
if [ "$ACTIVE" = "0" ]; then
  echo "Warning: still shows 0 - confirm with 'systemctl show -p RuntimeWatchdogUSec' after a few seconds."
fi

echo "OK - if the kernel hangs (nothing responds, not even SSH) for more than ~1min without feeding the watchdog, the host reboots on its own."
