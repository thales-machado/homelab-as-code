# Conventions

This file holds the conventions this repository follows and the reasons behind them. It started as the instructions file for an AI coding assistant working in the private repo, so it is written as a set of rules; most of them were learned from real production incidents, which are kept as short notes where they explain a rule.

## Hosts and roles

| Host | Hardware | LAN IP | Path | Role |
|---|---|---|---|---|
| `zangetsu` | Raspberry Pi 5 | `192.168.10.214` | `hosts/zangetsu/` | Platform core: Traefik, DockFlare master, primary Pi-hole, observability, Dagu, Komodo Core |
| `urahara` | GMKtec K8 (Ryzen 7 8845HS) | `192.168.10.215` | `hosts/urahara/` | Content and media: Immich, Paperless, n8n, Home Assistant, Wolf, replica Pi-hole |

Other fixed addresses: `192.168.10.248` is the Pi-hole VIP (keepalived), `192.168.10.200` the NAS.

- Each host's entry point is `hosts/<host>/compose.yaml`, whose `include:` list points to fragments in `infra/`. Run Compose commands from inside `hosts/<host>/`.
- The repo is checked out at `/opt/homelab` on each host. Each host's real `.env` lives at `/opt/homelab/hosts/<host>/.env` and is never committed (see `hosts/<host>/.env.example`).
- When adding a host, register it in this table.

### Host operations

- **Traefik label change** → `docker compose up -d --force-recreate <service>`. A change to the file provider (`infra/platform/networking/traefik/config/dynamic/`) hot-reloads, but that directory is **copied**, not bind-mounted from the repo: after `git pull`, run `bash scripts/setup/setup-traefik-config.sh` on zangetsu.
- **Pi-hole DNS reload**: `docker compose exec pi-hole pihole reloaddns` (`restartdns reload` no longer exists in Pi-hole v6).
- **Direct bind mount vs copy**: most services mount `./<folder>` from their own fragment, so `git pull` is enough. A few (`homepage`, `victoriametrics`) mount from `/opt/apps/`, outside the repo, and need their config copied there after `git pull`. Check the fragment's `volumes:` when unsure.
- **Single-file bind mounts** (e.g. `site-typewriter`'s `config/homelab-apps.json`, `keepalived.conf`): `git pull` or a setup script rewrites the file with a new inode, and the container keeps serving the old one. Always `docker compose up -d --force-recreate <service>`, never just `restart`. Whole-directory bind mounts are not affected.
- **NAS mounts (CIFS)**: units versioned in `scripts/systemd/`, installed by `bash scripts/setup/setup-nas-mounts.sh` (needs sudo). A failed mount triggers `OnFailure=` → `scripts/networking/notify-mount-failure.sh`. A `docker.service` drop-in (`scripts/systemd/docker.service.d/nas-mounts-<host>.conf`, `RequiresMountsFor=`) makes Docker wait for the mounts, so no container starts on an empty bind mount when the NAS is down at boot.
  - **Always a fixed `.mount`, never `.automount`.** An automount unmounts itself when idle; combined with `RequiresMountsFor=` that restarts Docker (and every container) on each idle cycle.
  - **Never `retrans=2` in CIFS `Options=`** (kernel 6.12): the mount reads fine but every write returns `Permission denied`. Changing mount options restarts the host's Docker through `RequiresMountsFor=`, so do one host at a time (the other Pi-hole keeps DNS up).
  - One unit per app covers all its subpaths (`mnt-media-immich.mount` → `/mnt/media/immich`). A slash in the path becomes `-` in the unit name; a literal hyphen inside a segment is escaped as `\x2d` in the installed unit name (`/mnt/games-4tb` → `mnt-games\x2d4tb.mount`, versioned as `scripts/systemd/mnt-games-4tb.mount`). Mixing them up fails with `Where= setting doesn't match unit name`.
- **Boot network delay (urahara)**: `network-online.target` was reached before the 2.5GbE link was physically up, and Docker started 31 containers with no network attached. `scripts/systemd/docker-network-delay.service` (oneshot, `sleep 120`, `Before=docker.service`) plus `scripts/systemd/docker.service.d/network-delay-urahara.conf` delays Docker until the link has negotiated. Recovery lesson: `docker restart` does not reattach a container to its network or redo its port publish; only `docker compose up -d --force-recreate <service>` does.
- **Pi-hole HA**: zangetsu is primary, urahara the replica. `keepalived` (containerized, see [Network exceptions](#network-exceptions)) holds the VIP `192.168.10.248`. Config lives in `scripts/setup/keepalived/keepalived-<host>.conf` with a `__VRRP_PASS__` placeholder; `bash scripts/setup/setup-keepalived.sh` renders it from `.env` (`KEEPALIVED_VRRP_PASS`, same on both hosts), then force-recreate `keepalived`. Pi-hole binds port 53 on `0.0.0.0`, so it answers on the VIP wherever it lands. Config sync uses Nebula Sync (Orbital Sync and Gravity Sync are archived and do not support Pi-hole v6); the replica needs `FTLCONF_webserver_api_app_sudo=true`. Router DHCP hands out the VIP as primary DNS and a public resolver as secondary.
- **Tailscale**: containerized with `network_mode: host` as a subnet router for `192.168.10.0/24` on both hosts (native multi-router failover). `TS_EXTRA_ARGS` must include `--accept-dns=false`, or tailscaled rewrites the host's `/etc/resolv.conf`. Because `tailscale0` sits outside Docker's bridges, the host `FORWARD` policy (`DROP`) silently drops traffic to other LAN hosts; `scripts/networking/tailscale-forward-rules.sh` inserts `ACCEPT` rules in `DOCKER-USER`, re-applied after every Docker restart by `scripts/systemd/tailscale-forward.service`.

## Network: dual-path

- **LAN (`*.lan.example.com`)**: Pi-hole resolves `*.lan.example.com` to the host IP (split-horizon, no public A record). Traefik terminates HTTPS with a public Let's Encrypt wildcard certificate (DNS-01 via Cloudflare). Details: `docs/traefik-dockflare.md`.
- **Internet (`*.example.com`)**: DockFlare turns Docker labels into Cloudflare Tunnel routes. The Cloudflare Access group `homelab-admin` (GitHub login + MFA) protects sensitive services; `public-default-bypass` is used only for webhook paths.

Every network is declared **only** in the host's `compose.yaml` (`name`, `subnet`, `gateway`, `driver`). A service fragment only references the network by name.

- **`cloudflare-net`**: main network for all services. Subnet and gateway differ per host.
- **`dockflare-internal`**: isolates `docker-socket-proxy`, which is not on `cloudflare-net`. Only services that need `DOCKER_HOST=tcp://docker-socket-proxy:2375` join it. Services that only query the Docker API go through the proxy; the few that cannot are listed in [Docker socket exceptions](#docker-socket-exceptions).

## Cross-host services (IP:port pattern)

Traefik, VictoriaMetrics, postgres-exporter, Dozzle and Nebula Sync run only on zangetsu, and Docker name resolution does not cross hosts. When something on zangetsu must reach a service on urahara:

- The urahara service publishes its port **bound to urahara's LAN IP only**, e.g. `"192.168.10.215:7007:7007"`, never `0.0.0.0`.
- The consumer on zangetsu targets `192.168.10.215:<port>` instead of a container name.
- Private HTTP routing does not use Traefik labels (Traefik only discovers containers on its own host). Add a router + service pointing to `http://<host-ip>:<port>` in `infra/platform/networking/traefik/config/dynamic/cross-host.yml`, and point the `pihole-dns.yaml` entry to the real host IP.
- If the fragment is host-agnostic (included on more than one host), never put `ports:` in it. Add a small override in `hosts/<host>/`, included after the fragment, containing only that host's `ports:` (examples: `hosts/urahara/observability-ports.yaml`, `hosts/urahara/pi-hole-network.yaml`).
- An `include:` override merges lists (`ports:`, `environment:`) but **not** nested maps such as `networks: <net>: ipv4_address:`; the base value always wins. For a per-host static IP use `${VAR:-default}` in the base fragment and set the variable in that host's `.env` (see `PIHOLE_STATIC_IP`).

The same pattern covers HTTP routing, metrics scraping, Postgres access and agent connections.

## DNS (Pi-hole)

Records are versioned in `infra/platform/networking/pi-hole/config/pihole-dns.yaml` and applied by `scripts/networking/sync-pihole-dns.sh`, or by GitHub Actions on commit (`.github/workflows/sync-pihole-dns.yaml`). Every new private service adds a `domain`/`ip` entry there. Ordering rules: see [Ordering rules](#ordering-rules).

## Homepage

Configured through files in `infra/utilities/homepage/config/`; it does **not** use Docker labels.

- A service with a UI gets an entry in `services.yaml` in the right group. Services with no useful UI (databases, Redis, exporters) are not added.
- `docker.yaml` has one block per host, each through that host's `docker-socket-proxy:2375`.
- Widget credentials: every variable Homepage consumes is named `HOMEPAGE_VAR_<SERVICE>_<FUNCTION>`, declared in `homepage.yaml`'s `environment:` and mapped from the `.env` variable (which follows the normal naming, without the prefix). The `HOMEPAGE_VAR_` prefix never appears in `.env`.
- API tokens for app widgets can only be generated after that app's initial onboarding; until then the variable stays empty in `.env`.

## infra/ structure

`platform/` · `observability/` · `automation/` · `content/` · `finance/` · `media-player/` · `integration/` · `smart-home/` · `utilities/`

Each fragment `infra/<category>/<service>/<service>.yaml` is self-contained.

## Storage convention

- **NAS media (synced share)**: `<share>/media/<app>/<purpose>` (e.g. `media/immich/upload`, `media/paperless/consume`), mounted at `/mnt/media/<app>/` with **one fixed CIFS `.mount` per app**. The share is synced off-site by the NAS, so it is out of Restic's scope.
- **Remote storage via rclone**: `/mnt/remote/<name>`, data that already has its own backup at the source. It does not follow `media/<app>/` and is out of Restic's scope.
- **Local game disk (urahara)**: `/mnt/games-4tb` (local ext4 by UUID, `scripts/systemd/mnt-games-4tb.mount`, `WantedBy=local-fs.target`, not part of `setup-nas-mounts.sh`), layout `retro/roms/<system>/` and `retro/bios/<system>/` with ES-DE system names. Wolf saves and states live in `/opt/apps/wolf` (Restic), not on this disk.
- New media service: follow `media/<app>/`, unless the data already lives on external storage with its own backup (then `/mnt/remote/`).
- **rclone and Samba share a host (urahara)**: the FUSE mount exists only inside the `rclone` container, so Samba, which re-exports it to SMB clients, must run on the same host.
- **rclone throttling**: the Google Drive remote uses a service account whose API quota (per GCP project + impersonated user) is shared with consumers outside this repo, none of which throttles itself. `rclone.yaml`'s `command:` therefore always sets `--tpslimit`/`--tpslimit-burst`/`--bwlimit`.
- **Consumers of another container's FUSE mount** (today: Samba reading rclone's mount) need **both**:
  1. `depends_on: <fuse-service>: condition: service_healthy` (never `service_started`); `rclone` has a `mountpoint -q` healthcheck because the mount appears seconds after the container starts.
  2. `bind: propagation: rslave` on the consumer's volume. A default (`rprivate`) bind mount only sees what was mounted when the consumer started; if rclone later remounts, the consumer silently keeps an empty directory.
  Even with both, force-recreating `rclone` orphans file handles open at that moment; restart the consumer right after.

## Observability

Metrics: VictoriaMetrics (Prometheus-compatible, viewed through Grafana). Logs: Grafana Alloy (River syntax, not YAML) → Loki, 15-day retention.

`postgres-exporter` monitors every Postgres from one container in multi-target mode (`metrics_path: /probe` + `auth_modules`, rendered by `scripts/setup/setup-postgres-exporter-config.sh`). `DATA_SOURCE_NAME` with comma-separated DSNs is not used: it only reported the first DSN, with no label to tell them apart. A new Postgres gets a new `auth_module` plus a target in `prometheus.yml` (job `postgres-exporter`), never a new exporter container.

**Mandatory checklist when adding or removing a service** (this prevents silent monitoring gaps; before it existed, an alert stayed dead for months on a removed container and about ten services were never monitored):

1. `scripts/setup/setup-uptime-kuma.py`: add/remove the entry in `MONITORS` **and run the script**. It syncs both ways (creates missing monitors, deletes orphans), but only when run. Uptime Kuma's port is not published, so run it in a throwaway container on `cloudflare-net` with `/opt/apps/uptime-kuma` mounted read-only. The script reads the monitor list from SQLite because the `uptime-kuma-api` monitor-list event hangs indefinitely; mutations still go through the API.
2. `infra/observability/metrics/victoriametrics/prometheus.yml`: add the scrape job if the service exposes metrics (Postgres: multi-target pattern above).
3. `infra/observability/metrics/grafana/provisioning/alerting/rules.yaml`: grep for the old container name before removing a service and fix any rule that depends on it.
4. Critical scheduled jobs (backup, sync) get a Healthchecks check (`terraform/healthchecks/`, see `docs/backup.md`).
5. Rerun the whole checklist after any large migration (reverse proxy, Docker manager, etc.); those are what historically left the gaps.

## Docker image policy

- Default tag `:latest`; fallback `:lts`, `:stable` or the latest version.
- New service: **check the actual latest release** (GitHub/Docker Hub API) before pinning an exact tag. Never assume a version from memory or stop at the first one that fixes a given bug (Traefik was once pinned to `v3.6` while `v3.7.x` was already the current stable).
- **Auto-update: Watchtower** (maintained fork `ghcr.io/nicholas-fedor/watchtower`; the original is archived), one instance per host through that host's `docker-socket-proxy`. Runs daily at 03:30 local time, after the backup window, with `WATCHTOWER_CLEANUP=true`. Watchtower compares image digests for the same tag, not versions.
- **Opt-in labels** (`WATCHTOWER_LABEL_ENABLE=true`): every service with a floating tag carries `com.centurylinklabs.watchtower.enable: "true"`. A deliberately pinned tag (e.g. `keepalived:2.3.4`, `cloudflared:2026.8.2`) simply has no label, so it is never auto-updated. Version bumps for pinned tags come through Renovate PRs (`renovate.json`).
- **Why not WUD**: WUD was tried and reverted. Its Docker client sends the container config as a URL query string instead of a JSON body, so `docker-socket-proxy` rejects large containers with `414`/`431`; it took down the public tunnel (`cloudflared-agent`) and Homepage (upstream `getwud/wud#621`). Do not reintroduce it until that is fixed.
- **Beware `<major>-<suffix>` tags** (`16-alpine`, `pg16`, `7-alpine`) in any tool that compares versions as strings/semver: a naive parser can "upgrade" `postgres:16-alpine` to an incompatible beta or variant, which once broke databases in production. These services stay out of auto-update on purpose.

## Service internal port

Needed for Traefik labels, DockFlare labels and Homepage widgets. Find it in this order:

1. `EXPOSE`, `command` or `healthcheck` in the service's own yaml.
2. The image's official documentation (Docker Hub, project GitHub).
3. If neither states it, confirm it on a running container (listening sockets) before writing labels. Never guess.

## Ordering rules

`pihole-dns.yaml` is organized by category banners mirroring `infra/` (e.g. `# --- Content ---`):

- Banners and the header at the top of the file are protected: never remove or reorder them.
- Within a category, entries are in alphabetical order by domain.

Private routing has no central file; routes live in each service's Traefik labels (or `cross-host.yml`).

## Mandatory conventions

**Resource limits**, on every service:

```yaml
cpus: 0.50
mem_limit: 256m
pids_limit: 64
```

Raise them only with a documented reason in a comment (e.g. Wolf's `pids_limit`, which counts GStreamer threads).

**Volumes**: bind mounts under `/opt/apps/<name>/`. Never named volumes.

**PUID/PGID**: linuxserver.io images do not default to UID 1000; without explicit values the internal user keeps the image's baked-in UID (911), and writes to a CIFS or fixed-UID bind mount fail with `Permission denied`. Always set `PUID=1000`/`PGID=1000` for these images when they write to such mounts.

**Secrets**: via `env_file: - ${HOMELAB_ENV}`. Never hardcoded.

- `HOMELAB_ENV` is set per host in `/etc/environment` and points to `/opt/homelab/hosts/<host>/.env`.
- Each `hosts/<host>/` also needs a physical `.env` in the folder: Compose interpolates `${VAR}` in YAML from the working directory's `.env`, a mechanism separate from `env_file:`. `include:` resolves relative paths against the fragment, which is why a `.env` in `infra/` would not work.
- Scripts shared between hosts read `$HOMELAB_ENV`; never hardcode `hosts/<host>/.env` in them. Scripts/DAGs that only make sense on one host may hardcode that host.
- systemd units that call these scripts need `EnvironmentFile=/etc/environment`; systemd does not inherit it the way login sessions do.

**Network**: never a `networks:` definition block in a service yaml. Only reference:

```yaml
networks:
  - cloudflare-net
```

The few exceptions are listed in [Network exceptions](#network-exceptions).

**Timezone**: every service sets `TZ=${TZ}`, never a hardcoded zone.

**Long `environment:` values**: break them with a double-quoted string, `\` at the end of the line (nothing after it) and an indented continuation:

```yaml
environment:
  - "DATA_SOURCE_NAME=postgresql://${DB_USER}:${DB_PASSWORD}@host1:5432/db1?sslmode=disable,\
    postgresql://${OTHER_USER}:${OTHER_PASSWORD}@host2:5432/db2?sslmode=disable"
```

YAML joins the lines with no extra character (verified with `docker compose config`). Without double quotes the `\` is literal and ends up in the value.

## .env naming

- **Global** (used by 2+ services): no prefix. `TZ`, `DB_USER`, `DB_PASSWORD`, `ADMIN_USER`, `ADMIN_PASSWORD`.
- **Platform**: platform prefix. `CF_API_TOKEN`, `CF_ACCOUNT_ID`, `CF_ZONE_ID`, `CF_TUNNEL_TOKEN`, `GITHUB_*`.
- **Per service**: `<SERVICE>_<FUNCTION>` in uppercase, no exceptions.
- **DockFlare exception**: the image's native unprefixed variables (`TUNNEL_NAME`, `LABEL_PREFIX`, `GRACE_PERIOD_SECONDS`, ...).

The yaml maps the `.env` name to whatever the image expects:

```yaml
environment:
  - NAME_THE_IMAGE_EXPECTS=${SERVICE_VARIABLE}
```

Wrong: `DOMAIN`, `JWT_SECRET`, `ENCRYPTION_KEY`, `ADMIN_TOKEN`.
Right: `VAULTWARDEN_DOMAIN`, `KOMODO_JWT_SECRET`, `KOMODO_PASSKEY`, `VAULTWARDEN_ADMIN_TOKEN`.

## File and folder naming

Lowercase kebab-case for every file and folder in the repo (`.yaml`, `.sh`, `.md`, ...): `sqlite-backup.yaml`, `notify-mount-failure.sh`. Never CamelCase, snake_case or UPPERCASE in a file name, even when the document's internal title uses other casing. Only names imposed by an external tool are exempt (e.g. `Dockerfile`, `README.md`, `LICENSE`).

## scripts/ layout

No script lives directly in `scripts/`. Each goes in a subfolder by **function**, not by app:

```
scripts/
├── backup/       # consistent snapshots (SQLite/Postgres) and Restic, plus restic-excludes.txt
├── setup/        # config provisioning/rendering, run manually once or when the config changes
├── networking/   # DNS sync, VPN forwarding rules, mount failure notification
├── immich/       # Immich-specific utilities
├── monitoring/   # checks for things no Prometheus exporter covers
└── systemd/      # real systemd units, referenced by scripts from several categories
```

A backup script for a new app goes in `backup/`, not a new folder. Create a subfolder only for genuinely distinct functionality. When a script moves, update every reference to it, including `command:` in Dagu DAGs (`infra/automation/dagu/dags/`) and `ExecStart=` in `scripts/systemd/` units, which use absolute paths (`/opt/homelab/scripts/<folder>/<script>`).

## Service templates

| Type | DockFlare labels + `depends_on: dockflare` | `pihole-dns.yaml` + Traefik labels |
|---|---|---|
| Private (`*.lan.example.com`) | No | Yes |
| Public (`*.example.com`) | Yes | No |
| Both | Yes | Yes (same container/port as the DockFlare labels) |

Common base: resource limits, `TZ=${TZ}`, `env_file: ${HOMELAB_ENV}` if it uses secrets, bind mount under `/opt/apps/<name>/`, only a reference to `cloudflare-net`. Fragment path: `infra/<category>/<name>/<name>.yaml`; exporters go in `infra/observability/metrics/exporters/<name>/` and get a scrape job, with no Traefik, DNS, DockFlare or Homepage entry.

Private service on zangetsu:

```yaml
services:
  <name>:
    image: <image>:latest
    container_name: <name>
    restart: unless-stopped
    cpus: 0.50
    mem_limit: 256m
    pids_limit: 64
    env_file:
      - ${HOMELAB_ENV}
    environment:
      - TZ=${TZ}
    volumes:
      - /opt/apps/<name>:/data
    networks:
      - cloudflare-net
    labels:
      com.centurylinklabs.watchtower.enable: "true"   # omit for a pinned tag
      traefik.enable: "true"
      traefik.http.routers.<name>.rule: "Host(`<name>.lan.example.com`)"
      traefik.http.routers.<name>.entrypoints: "websecure"
      traefik.http.routers.<name>.tls.certresolver: "cloudflare"
      traefik.http.routers.<name>.middlewares: "crowdsec@file,security-headers@file"
      traefik.http.services.<name>.loadbalancer.server.port: "<port>"
```

`crowdsec@file` must be listed on every router; Traefik has no global "apply to all routers". A private service on another host drops the Traefik labels and follows [Cross-host services](#cross-host-services-ipport-pattern).

Public service: same base plus

```yaml
    depends_on:
      dockflare:
        condition: service_healthy
    labels:
      dockflare.enable: "true"
      dockflare.hostname: "<name>.example.com"
      dockflare.service: "http://<name>:<port>"
      dockflare.access.group: "homelab-admin"   # set explicitly, or omit (see exceptions)
```

Webhook path exempt from Cloudflare Access (rest of the host stays behind MFA):

```yaml
      dockflare.0.hostname: "<name>.example.com"
      dockflare.0.path: "/webhook"
      dockflare.0.service: "http://<name>:<port>"
      dockflare.0.access.group: "public-default-bypass"
```

## Intentional exceptions

### Public services without `dockflare.access.group`

Services where Cloudflare Access (MFA) would break normal use. Do not add an access group to them without revisiting the reason:

- `immich`: used from the mobile app by several people.
- `vaultwarden`: shared password vault used by several people from native clients.
- `it-tools`: stateless tools, nothing to protect.
- `tandoor`: used from a mobile app (kitshn) and by non-admin accounts; protected by native login rate limiting (Tandoor 2.6.1+) and strong per-account passwords instead of platform MFA.
- `site-typewriter`, `thalesmachado-net`: public portfolio sites, must be reachable without login.

Rule: a public service is never given `homelab-admin` by assumption. If no access group is chosen, the label is omitted and the service is added to this list.

### Network exceptions

Each of these replaces `networks:` with something else for a hardware/protocol reason. Do not copy the pattern without an equivalent need.

- `pi-hole`: map-format `networks:` with a fixed `ipv4_address` (`${PIHOLE_STATIC_IP:-...}`), because DNS needs a static IP.
- `keepalived`: `network_mode: host`. VRRP (multicast + gratuitous ARP) needs the physical interface, which the `cloudflare-net` bridge does not expose.
- `tailscale`: `network_mode: host`, as recommended for subnet routers, to avoid double NAT (tailscaled's SNAT followed by Docker's masquerade).
- `home-assistant`: `network_mode: host`. Local device discovery (mDNS/SSDP for HomeKit, Chromecast, etc.) needs multicast/broadcast on the physical interface. Since Home Assistant 2026.8, reverse-proxy trust can only be set in the UI (Settings → System → Network → HTTP server); the `http: trusted_proxies` block in `configuration.yaml` validates but has no effect. Until it is set, every request through Traefik returns 400, so onboarding is done directly at `192.168.10.215:8123`.
- `wolf`: `network_mode: host`. It publishes fixed Moonlight ports (47984/47989/48010 TCP, 47999/48100/48200 UDP), announces itself via mDNS, and Moonlight clients connect straight to the host IP.

### Docker socket exceptions

The default is `docker-socket-proxy` (Homepage, Watchtower, Autoheal, DockFlare). These services mount `/var/run/docker.sock` directly, each for a stated reason; read-only wherever the service only reads:

- `traefik` (`:ro`): Docker provider for label-based routing.
- `dozzle` and `dozzle-agent` (`:ro`): Dozzle's agent mode does not work behind the socket proxy, per its official docs.
- `grafana-alloy` (`:ro`): container discovery and log collection.
- `dagu`: runs `docker.run` steps in its DAGs, which need to create containers.
- `komodo-periphery`: deploys, starts and stops stacks, so it needs full read-write control.
- `wolf`: creates and removes an app container per streaming session, and `WOLF_DOCKER_SOCKET` only supports a unix socket, not TCP.

A new service gets the socket directly only with a reason of the same kind, written as a comment next to the mount.

## Critical restrictions

- **`komodo-core`/`komodo-periphery` never go in the `include:` of a host's main `compose.yaml`** (see [Komodo deployment](#komodo-deployment)).
- Never declare a `networks:` definition block in a service yaml.
- Never use named volumes.
- Never hardcode secrets; always `${HOMELAB_ENV}`.
- New private service → `pihole-dns.yaml` entry + Traefik labels in its own yaml (or a `cross-host.yml` entry if it is not on zangetsu).
- New public service → DockFlare labels + `depends_on: dockflare`, and an explicit decision on `dockflare.access.group`.
- New "both" service → all of the above, same container/port for DockFlare and Traefik.
- **`include:` is the only source of truth for what runs.** It must match production exactly:
  - A service that moved hosts or was decommissioned has its line **removed**, not commented out. History belongs in git; the deploy workflow (`.github/workflows/deploy.yaml`) reads `include:` and depends on it reflecting reality.
  - A commented line is allowed only for a real standby with a concrete, documented reason to reactivate.
  - A fragment with no line in any `include:` is legacy or under evaluation. It gets no `pihole-dns.yaml` entry until it has an `include:` line, and compliance checks (Watchtower labels, limits, `TZ`, backup, DNS, monitoring) run only on included fragments.

## Komodo deployment

Komodo Core runs only on zangetsu (`infra/platform/management/komodo/komodo.yaml`); Periphery runs on every host (`periphery.yaml`). GitHub Actions calls each host's Stack webhook only when the push touches that host's `include:`. Full details: `docs/komodo.md`.

- A deploy that recreates Core or Periphery kills the process running the deploy (containers left in `Created`, Stack stuck in `DOWN`). Removing them from `include:` is not enough, because Komodo works at the Compose **project** level. So `hosts/<host>/komodo-periphery.yaml` and `hosts/zangetsu/komodo-core.yaml` are **separate Compose projects** (`name: komodo-periphery` / `name: komodo-core`, `cloudflare-net` as `external: true`), always deployed manually:

  ```bash
  cd hosts/<host> && docker compose -f komodo-periphery.yaml up -d
  cd hosts/zangetsu && docker compose -f komodo-core.yaml up -d
  ```

  Because Periphery is its own project, Watchtower can recreate it without colliding with a Komodo deploy in progress.
- Never use `DeployStackIfChanged` (intermittent silent hang on `include:`-heavy stacks, still present in 2.3.3). Both Stacks use `webhook_force_deploy: true`.
- Keep Core and Periphery on the same version. Upgrade with `pull` before `--force-recreate` (recreate alone does not pull).
- Each Stack's webhook secret must match the GitHub Actions secret `KOMODO_HOMELAB_<HOST>_WEBHOOK_SECRET`; a mismatch fails only as exit 22 in the Actions run.

## Database backup

Full details: `docs/backup.md`.

- Every database (SQLite, Postgres) is backed up by a **consistent snapshot** taken by a Dagu DAG before Restic runs. Restic's copy of a live database file is never trusted.
  - SQLite: `scripts/backup/backup-sqlite.sh` (`.backup`), DAG `sqlite-backup`; n8n on urahara uses `scripts/backup/backup-n8n-sqlite.sh`, DAG `n8n-backup-urahara`.
  - Postgres: `scripts/backup/backup-postgres.sh` (`pg_dump`), DAG `postgres-backup`. The runner image must be the same Postgres major as or newer than the newest server in the stack; `pg_dump` refuses newer servers.
  - Snapshots go to `/opt/apps/<app>/db-backup/`.
- A new service with its own database is added to the existing script; never a new DAG.
- `scripts/backup/restic-excludes.txt` excludes the live database files (`*.sqlite`/`*.db` + `-wal`/`-shm` directly under `/opt/apps/<app>/`, and `/opt/apps/<app>/db/`). Its patterns are non-recursive so `db-backup/` is never excluded. Edit it only for a database outside those patterns.
- Filesystem backup is Restic (`/opt` + `/etc`), one repository per host on a fixed NAS mount (`/mnt/backup/<host>`), each with its own backup + prune DAG pair. Never a central repository for several hosts.
- urahara's DAGs run from zangetsu's Dagu via `action: ssh.run`. A `command:` with `$`/`$()` must escape `\$` **and** set `shell: /bin/sh`, or the variable arrives empty.
- n8n workflows are not exported as JSON to the repo; `database.sqlite` is already backed up.
