#!/usr/bin/env python3
"""
Homelab - Uptime Kuma Monitor Setup
====================================
Syncs the Uptime Kuma monitors via the API from MONITORS: creates what is
missing and removes orphan monitors (names no longer in the list - service
renamed/removed). Always run it after editing MONITORS; never just edit the
file and leave it there - this list is the source of truth, and Uptime Kuma
must reflect it both ways (create AND delete).

Usage (needs the API socket AND the kuma.db file mounted read-only, since
the listing reads SQLite directly - see the comment about get_monitors()):
  docker run --rm --network cloudflare-net \
    -v /opt/apps/uptime-kuma:/app/data:ro \
    -e UK_URL=http://uptime-kuma:3001 -e UK_PASS=... \
    python:3-slim sh -c "pip install -q uptime-kuma-api && python3 setup-uptime-kuma.py"

Settings below in CONFIG.
"""

import os
import sqlite3
import sys
from uptime_kuma_api import UptimeKumaApi, MonitorType, NotificationType

# api.get_monitors() (Event.MONITOR_LIST via socket.io broadcast) hangs
# indefinitely in production even with a successful login and a high timeout.
# Confirmed real bug (login always succeeds, get_monitors() always hangs;
# tested with several library versions). So the list is read straight from
# SQLite (read-only, the same DB the backup scripts use) instead of relying
# on that event. Mutations (add/edit/delete) still go through the API; those
# work fine on their own.
KUMA_DB_PATH = os.getenv("UK_DB_PATH", "/app/data/kuma.db")

# =============================================================================
# CONFIG — use environment variables, or edit here as a fallback
# =============================================================================
UPTIME_KUMA_URL  = os.getenv("UK_URL",  "http://192.168.10.214:3001")
UPTIME_KUMA_USER = os.getenv("UK_USER", "admin")
UPTIME_KUMA_PASS = os.getenv("UK_PASS", "")

# Default check interval (seconds)
DEFAULT_INTERVAL     = 60
DEFAULT_RETRIES      = 3
DEFAULT_RETRY_INTERVAL = 20

# Default notification: WhatsApp via the n8n "Homelab Notify" workflow.
# Uses urahara's published IP:port: n8n runs on urahara and Uptime Kuma on
# zangetsu. Different hosts mean different Docker networks, and container
# names do not resolve across them.
# n8n recognizes Uptime Kuma's native payload (heartbeat + monitor + msg)
# without a custom header/secret (same limitation as
# Watchtower/Healthchecks.io; see "Validate Origin" in the workflow).
NOTIFICATION_NAME = "WhatsApp - Homelab Notify"
NOTIFICATION_WEBHOOK_URL = "http://192.168.10.215:8097/webhook/homelab-notify"

# =============================================================================
# MONITORS
# Each entry: (name, url, group, interval, optional accepted_statuscodes)
# Uses internal Docker hostnames (same cloudflare-net network)
# =============================================================================
MONITORS = [
    # --- Management ---
    ("Komodo",           "http://komodo-core:9120",       "Management",    60),
    ("DockFlare",        "http://dockflare:5000/ping",    "Management",    60),
    # Watchtower's HTTP API requires a token on almost every route (WATCHTOWER_HTTP_API_TOKEN)
    # and has no unauthenticated root endpoint; a TCP check avoids false negatives (same pattern as Crowdsec).
    ("Watchtower (zangetsu)", "watchtower",       "Management", 60, None, False, 8080),
    ("Watchtower (urahara)",  "192.168.10.215",   "Management", 60, None, False, 8084),

    # --- Security ---
    ("Vaultwarden",      "https://vaultwarden.example.com", "Security",  120),

    # --- Finance ---
    ("Firefly III",      "http://firefly-iii:8080",       "Finance",       60),
    ("FIDI",             "http://fidi:8080",              "Finance",       60),

    # --- Automation ---
    # Published IP:port (192.168.10.215:8097): n8n runs on urahara, and
    # container names do not resolve across hosts/networks.
    ("N8N",              "http://192.168.10.215:8097/healthz", "Automation", 60),
    ("Dagu",              "http://dagu:8080",             "Automation",    60),

    # --- Integration ---
    ("Evolution API",    "http://192.168.10.215:8094",    "Integration",   60),

    # --- Network ---
    # Traefik: TCP check on port 443 avoids internal TLS/SNI issues
    ("Traefik",           "traefik",                      "Network",       30,  None, False, 443),
    ("Pi-hole",          "http://pi-hole:80/admin",       "Network",       60),
    # /ready returns 200 only when a tunnel connection is actually registered:
    # a direct signal from the cloudflared process, not from a public app behind it.
    ("Cloudflare Tunnel", "http://cloudflared-agent-lemonpi-5-tunel:2000/ready", "Network", 60),
    # only port 53 is published on the host; with no web admin exposed, TCP is the only direct check possible
    ("Pi-hole (urahara)", "192.168.10.215", "Network", 60, None, False, 53),
    # keepalived itself has no endpoint (VRRP, no HTTP/TCP), so monitor the
    # result it produces (the VIP answering), not the process. This covers the
    # whole HA layer (keepalived + failover) end to end.
    # Real DNS query, not HTTP:80: that port is only published on the host's
    # real IP, never on the VIP, so HTTP would fail even with a healthy VIP.
    # Real incident: FTL hung internally while Docker reported "healthy" (the
    # image's shallow healthcheck); only a real DNS query against the VIP
    # catches this kind of failure.
    ("Pi-hole VIP (HA)",  "pihole.lan.example.com", "Network", 60, None, False, None, "192.168.10.248"),
    # dockflare-agent exposes no endpoint of its own and only talks to the
    # master; TCP on docker-socket-proxy is the closest indirect signal available.
    ("DockFlare Agent (urahara)", "192.168.10.215", "Network", 60, None, False, 2375),

    # --- Observability ---
    ("Dozzle",           "http://dozzle:8080",            "Observability", 60),
    ("Uptime Kuma",      "http://uptime-kuma:3001",       "Observability", 30),
    ("Grafana",           "http://grafana:3000/api/health", "Observability", 60),
    ("VictoriaMetrics",   "http://victoriametrics:8428/health", "Observability", 60),
    ("Loki",              "http://loki:3100/ready",       "Observability", 60),
    ("Scrutiny",          "http://scrutiny:8080",         "Observability", 60),
    ("Healthchecks",      "http://healthchecks:8000",     "Observability", 60),
    # Crowdsec LAPI requires X-Api-Key on almost every route; a TCP check avoids false negatives
    ("Crowdsec",         "192.168.10.215",                "Observability", 60, None, False, 8082),

    # --- Utilities ---
    ("Homepage",         "http://homepage:3000",          "Utilities",     60),
    ("OpenSpeedTest",     "http://openspeedtest:3000",    "Utilities",     60),
    # IT-Tools runs on urahara; its container name does not resolve from here, so use IP:port
    ("IT-Tools",         "http://192.168.10.215:8092",    "Utilities",     60),
    ("Vikunja",          "http://192.168.10.215:3456",    "Utilities",     60),
    ("TriliumNext",      "http://192.168.10.215:8091",    "Utilities",     60),
    # Wolf: TCP on 47989 (pairing HTTP); the stream itself is UDP/RTSP, with
    # no useful HTTP endpoint to check
    ("Wolf",             "192.168.10.215",                "Utilities",     60, None, False, 47989),

    # --- Content (all on urahara) ---
    ("Immich",            "http://192.168.10.215:2283",   "Content",       60),
    ("Paperless-ngx",     "http://192.168.10.215:8000",   "Content",       60),
    ("Stirling PDF",      "http://192.168.10.215:8080",   "Content",       60),
    # Samba is plain SMB, no HTTP: TCP check on 445
    ("Samba",             "192.168.10.215",               "Content",       60, None, False, 445),
    ("TandoorRecipes",    "http://192.168.10.215:8083",   "Content",       60),

    # --- Smart Home ---
    ("Home Assistant",    "http://192.168.10.215:8123",   "Smart Home",    60),

    # --- External / Public ---
    ("N8N (público)",         "https://n8n.example.com",          "External", 120),
    ("Vaultwarden (público)", "https://vaultwarden.example.com",  "External", 120),
    # no internal *.lan.example.com route; these only exist publicly, unlike
    # the private/public pairs above
    ("example.com",           "https://example.com",              "External", 60),
    ("site-typewriter",       "https://site.example.com",         "External", 60),
]

# =============================================================================
# SCRIPT
# =============================================================================

def list_monitors_db(db_path=KUMA_DB_PATH):
    """Read id/name/type/parent of every monitor straight from SQLite
    (read-only) - replaces api.get_monitors(), which hangs (see the comment
    at the top of the file)."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT id, name, type, parent FROM monitor").fetchall()
    conn.close()
    return [dict(r) for r in rows]


def delete_all_monitors(api):
    """Delete every existing monitor and group."""
    monitors = list_monitors_db()
    if not monitors:
        print("  ℹ️  No monitors to delete.")
        return
    for m in monitors:
        api.delete_monitor(m["id"])
        print(f"  🗑️  Deleted: {m['name']} (id={m['id']})")
    print(f"  ✅ {len(monitors)} monitors deleted.\n")


def create_group(api, name):
    """Create a monitor group if it does not exist."""
    for m in list_monitors_db():
        if m.get("type") == "group" and m.get("name") == name:
            return m["id"]
    result = api.add_monitor(
        type=MonitorType.GROUP,
        name=name,
    )
    print(f"  ✅ Group created: {name} (id={result['monitorID']})")
    return result["monitorID"]


def create_notification(api):
    """Create the default (WhatsApp) notification if it does not exist,
    applied by default to every monitor (new and existing)."""
    existing = api.get_notifications()
    for n in existing:
        if n.get("name") == NOTIFICATION_NAME:
            return n["id"]
    result = api.add_notification(
        name=NOTIFICATION_NAME,
        type=NotificationType.WEBHOOK,
        webhookURL=NOTIFICATION_WEBHOOK_URL,
        webhookContentType="json",
        isDefault=True,
        applyExisting=True,
    )
    print(f"  ✅ Notification created: {NOTIFICATION_NAME} (id={result['id']})")
    return result["id"]


def find_monitor(api, name):
    """Return the monitor by name, or None if it does not exist."""
    return next((m for m in list_monitors_db() if m.get("name") == name), None)


def prune_stale_monitors(api):
    """Remove orphan monitors - present in Uptime Kuma but no longer in
    MONITORS (renamed or decommissioned service). The normal run only adds
    what is missing and never deleted leftovers - the real cause of zombie
    monitors (Arcane/Caddy/Jellyfin surviving for months after being replaced
    by Komodo/Traefik or removed). Never touches groups (MonitorType.GROUP)."""
    current_names = {m[0] for m in MONITORS}
    existing = list_monitors_db()
    pruned = 0
    for m in existing:
        if m.get("type") == "group":
            continue
        if m["name"] not in current_names:
            api.delete_monitor(m["id"])
            print(f"  🗑️  Orphan removed: {m['name']} (id={m['id']})")
            pruned += 1
    if pruned == 0:
        print("  ✅ No orphan monitors found")
    return pruned


def main():
    reset = "--reset" in sys.argv

    if not UPTIME_KUMA_PASS:
        print("❌ Set UK_PASS before running:\n   export UK_PASS='your-password'")
        raise SystemExit(1)

    print(f"\n🔗 Connecting to {UPTIME_KUMA_URL}...")
    # the library's default timeout is 10s. With dozens of monitors, the
    # Event.MONITOR_LIST payload via polling (not a real WebSocket) takes
    # longer than that, causing a Timeout even after a successful login (real
    # production error: login succeeded but get_monitors() hit the default
    # timeout).
    api = UptimeKumaApi(UPTIME_KUMA_URL, timeout=30)

    print(f"🔑 Authenticating as '{UPTIME_KUMA_USER}'...")
    api.login(UPTIME_KUMA_USER, UPTIME_KUMA_PASS)
    print("✅ Authenticated!\n")

    if reset:
        print("🗑️  --reset: deleting all monitors...")
        delete_all_monitors(api)

    print("🧹 Checking for orphan monitors...")
    prune_stale_monitors(api)

    print("🔔 Configuring notification...")
    create_notification(api)

    groups = {}
    unique_groups = list(dict.fromkeys(m[2] for m in MONITORS))
    print("📁 Creating groups...")
    for group_name in unique_groups:
        gid = create_group(api, group_name)
        groups[group_name] = gid

    print("\n📡 Creating monitors...")
    created = 0
    skipped = 0

    for entry in MONITORS:
        name, url, group, interval = entry[0], entry[1], entry[2], entry[3]
        statuscodes = entry[4] if len(entry) > 4 else ["200-299"]
        ignore_tls  = entry[5] if len(entry) > 5 else False
        tcp_port    = entry[6] if len(entry) > 6 else None
        dns_server  = entry[7] if len(entry) > 7 else None

        existing_monitor = find_monitor(api, name)
        if existing_monitor:
            # Re-check the parent even for an existing monitor. The creation
            # block below only sets it once, at creation time; if the parent
            # is lost later (actually seen with Komodo, which ended up outside
            # the Management group unnoticed), the script never fixed it
            # because it only touched what it had just created. Idempotent:
            # no-op if already correct.
            expected_group_id = groups.get(group)
            if expected_group_id and existing_monitor.get("parent") != expected_group_id:
                api.edit_monitor(existing_monitor["id"], parent=expected_group_id)
                print(f"  🔧 Parent fixed: {name} → group '{group}'")
            else:
                print(f"  ⏭️  Already exists: {name}")
            skipped += 1
            continue

        if dns_server:
            # DNS monitor (real query): used when HTTP/TCP on the target does
            # not prove actual resolution (e.g. HA VIP without a published port 80)
            result = api.add_monitor(
                type=MonitorType.DNS,
                name=name,
                hostname=url,
                port=53,
                dns_resolve_server=dns_server,
                dns_resolve_type="A",
                interval=interval,
                maxretries=DEFAULT_RETRIES,
                retryInterval=DEFAULT_RETRY_INTERVAL,
            )
        elif tcp_port:
            # TCP monitor (port check) for services with internal TLS
            result = api.add_monitor(
                type=MonitorType.PORT,
                name=name,
                hostname=url,
                port=tcp_port,
                interval=interval,
                maxretries=DEFAULT_RETRIES,
                retryInterval=DEFAULT_RETRY_INTERVAL,
            )
        else:
            result = api.add_monitor(
                type=MonitorType.HTTP,
                name=name,
                url=url,
                interval=interval,
                maxretries=DEFAULT_RETRIES,
                retryInterval=DEFAULT_RETRY_INTERVAL,
                accepted_statuscodes=statuscodes,
                ignoreTls=ignore_tls,
            )
        mid = result["monitorID"]

        # move to the group in a second step (more reliable than passing parent at creation)
        group_id = groups.get(group)
        if group_id:
            edit_result = api.edit_monitor(mid, parent=group_id)
            # check that parent was actually saved
            saved = api.get_monitor(mid)
            print(f"  ✅ Created: {name} (id={mid}) → group '{group}' | accepted statuses: {statuscodes}")
        else:
            print(f"  ⚠️  Created: {name} (id={mid}) — group '{group}' not found!")
        created += 1

    api.disconnect()
    print(f"\n🎉 Done! {created} monitors created, {skipped} skipped.")


if __name__ == "__main__":
    main()
