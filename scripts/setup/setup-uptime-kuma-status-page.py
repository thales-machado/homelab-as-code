#!/usr/bin/env python3
"""
Homelab - Uptime Kuma Status Page (site-typewriter)
===================================================
Reconfigures the public status page /status/homelab to expose the real
individual monitors (immich, grafana, traefik, etc.) instead of the 9
Group monitors (Management, Security, Finance...) used today for the
internal dashboard. A Group-type monitor only returns an aggregated
heartbeat via the public API (GET /api/status-page/homelab), with no list
of children - so the status page must reference the real monitors
directly, never the internal dashboard's group wrappers.

STATUS_PAGE_GROUPS below is the source of truth for what appears on the
public page - rerun whenever an app is ADDED to or MOVED in that list.
Idempotent (overwrites the whole publicGroupList on every run, no leftovers).

Usage:
  pip install uptime-kuma-api
  python3 setup-uptime-kuma-status-page.py
"""

import os
import sys

from uptime_kuma_api import UptimeKumaApi

UPTIME_KUMA_URL  = os.getenv("UK_URL",  "http://192.168.10.214:3001")
UPTIME_KUMA_USER = os.getenv("UK_USER", "admin")
UPTIME_KUMA_PASS = os.getenv("UK_PASS", "")

STATUS_PAGE_SLUG = "homelab"

# =============================================================================
# STATUS_PAGE_GROUPS
# Monitor names must match MONITORS in setup-uptime-kuma.py exactly (same
# source; the monitors already exist before this script runs). Same app set
# curated for site-typewriter.
# =============================================================================
STATUS_PAGE_GROUPS = [
    ("Plataforma", [
        "Komodo",
        "DockFlare",
        "Watchtower (zangetsu)",
        "Watchtower (urahara)",
        "Vaultwarden",
    ]),
    ("Rede", [
        "Traefik",
        "step-ca",
        "Pi-hole",
    ]),
    ("Observabilidade", [
        "Uptime Kuma",
        "Grafana",
        "VictoriaMetrics",
        "Loki",
        "Crowdsec",
    ]),
    ("Automação", [
        "N8N",
        "Dagu",
        "WA Courier",
    ]),
    ("Conteúdo", [
        "Immich",
        "Paperless-ngx",
    ]),
    ("Utilidades", [
        # The only app in the curated list with direct public access and no
        # MFA (dockflare.access.group omitted on purpose; see CONVENTIONS.md,
        # "Public services without dockflare.access.group").
        # site-typewriter can link https://it-tools.example.com as a working
        # demo, not just a status card.
        "IT-Tools",
    ]),
]

# Tailscale and Restic are in the site's curated list (README/showcase) but
# have no Uptime Kuma monitor: Tailscale is a VPN/subnet router with no simple
# HTTP/TCP endpoint to check; Restic is a batch job (Dagu), not a long-running
# service, and its status is already covered by Healthchecks (cron ping), not
# an individual heartbeat. Do not force an artificial monitor just to show up
# here; show both on the site as static cards (no live status badge) until a
# real signal exists.


def main():
    if not UPTIME_KUMA_PASS:
        print("❌ Set UK_PASS before running:\n   export UK_PASS='your-password'")
        raise SystemExit(1)

    print(f"\n🔗 Connecting to {UPTIME_KUMA_URL}...")
    api = UptimeKumaApi(UPTIME_KUMA_URL)

    print(f"🔑 Authenticating as '{UPTIME_KUMA_USER}'...")
    api.login(UPTIME_KUMA_USER, UPTIME_KUMA_PASS)
    print("✅ Authenticated!\n")

    existing = api.get_monitors()
    by_name = {m["name"]: m["id"] for m in existing}

    public_group_list = []
    missing = []
    for weight, (group_name, monitor_names) in enumerate(STATUS_PAGE_GROUPS):
        monitor_list = []
        for name in monitor_names:
            mid = by_name.get(name)
            if mid is None:
                missing.append(name)
                continue
            monitor_list.append({"id": mid})
        public_group_list.append({
            "name": group_name,
            "weight": weight,
            "monitorList": monitor_list,
        })

    if missing:
        print(f"⚠️  Monitor(s) not found, skipped: {', '.join(missing)}")
        print("    (run setup-uptime-kuma.py first if they are new)\n")

    print(f"📄 Saving status page '{STATUS_PAGE_SLUG}'...")
    api.save_status_page(STATUS_PAGE_SLUG, publicGroupList=public_group_list)

    total = sum(len(g["monitorList"]) for g in public_group_list)
    print(f"✅ {len(public_group_list)} groups, {total} individual monitors published.")
    print(f"   Check: {UPTIME_KUMA_URL.replace('3001', '80')}/status/{STATUS_PAGE_SLUG}")

    api.disconnect()


if __name__ == "__main__":
    main()
