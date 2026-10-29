#!/bin/bash
# Allows forwarding for the tailscale0 interface in the DOCKER-USER chain.
#   Real quirk: with the tailscale container in network_mode: host (subnet
#   router), tailscale0 lives outside any Docker network, and Docker only
#   creates automatic ACCEPT rules in DOCKER-FORWARD for its own bridges. The
#   host's FORWARD chain has a DROP policy by default, so traffic arriving on
#   tailscale0 for another LAN host (e.g. zangetsu, not urahara itself) is
#   silently dropped. Symptom: the IP of the host running the subnet router
#   works (it answers locally, no real forwarding needed), but any other LAN
#   IP times out.
# DOCKER-USER is the chain Docker officially recommends for custom rules
# (never overwritten by normal daemon reloads), but it IS recreated empty on
# every docker.service restart/reboot. That is why this script runs as a
# systemd oneshot (scripts/systemd/tailscale-forward.service) after
# docker.service, not just once by hand.
# Idempotent: checks with `iptables -C` before inserting; safe to run any
# number of times (boot, service restart, manual run).
set -euo pipefail

IFACE="tailscale0"

add_rule() {
  local args=("$@")
  if ! iptables -C DOCKER-USER "${args[@]}" 2>/dev/null; then
    iptables -I DOCKER-USER "${args[@]}"
    echo "✓ rule added: ${args[*]}"
  else
    echo "= rule already exists: ${args[*]}"
  fi
}

add_rule -o "$IFACE" -j ACCEPT
add_rule -i "$IFACE" -j ACCEPT
