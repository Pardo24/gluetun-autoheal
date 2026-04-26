# gluetun-autoheal

All-in-one watchdog that keeps containers using `network_mode: "service:gluetun"` alive across gluetun recreations, VPN drops, host suspend/resume, and broken network namespaces.

## The problem

When you run containers like qBittorrent, Prowlarr or FlareSolverr with `network_mode: "service:gluetun"`, they share gluetun's network namespace. Several common scenarios break them silently:

- **Gluetun is recreated** (e.g. after `docker compose up -d gluetun`) — dependents lose their namespace reference and `docker restart` cannot fix it
- **VPN provider drops the tunnel** — gluetun stays "running" but has no internet
- **Host PC suspended/resumed** — Docker may leave dependents in a half-broken state
- **Mullvad/Wireguard hiccup** — gluetun reconnects but dependents remain stuck on the old tunnel

Symptoms: qBittorrent returns 502, Prowlarr indexers fail with timeouts, containers show healthy in `docker ps` but have no actual network access.

## The solution

This image runs three coordinated mechanisms in a single container:

1. **Active connectivity check** (every `CHECK_INTERVAL` seconds) — actively tests if gluetun and each dependent container can reach the internet via TCP. If a dependent has no connectivity, it is recreated with `docker compose up -d`. If gluetun itself can't reach the internet for `FAILURE_THRESHOLD` consecutive checks, gluetun is restarted.

2. **Gluetun health event listener** — reacts immediately when Docker fires a `health_status: healthy` event for gluetun (typically right after a recreation). Recreates all configured dependents.

3. **Autoheal for non-VPN containers** — for any container with the `autoheal=true` label that is not in the gluetun dep list, restarts it via `docker restart` when it becomes unhealthy. (VPN deps are skipped here — they're already covered by the active check.)

## Usage

```yaml
services:
  gluetun-autoheal:
    image: danipal/gluetun-autoheal:latest
    container_name: gluetun_autoheal
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /path/to/your/project:/workspace:ro   # must contain docker-compose.yml and .env
    environment:
      GLUETUN_CONTAINER: gluetun              # container name of your gluetun instance
      GLUETUN_DEPS: "qbittorrent prowlarr flaresolverr"             # compose service names to recreate
      GLUETUN_DEP_CONTAINERS: "qbittorrent prowlarr flaresolverr"   # container names to actively check
      COMPOSE_FILE: /workspace/docker-compose.yml
      ENV_FILE: /workspace/.env
      COMPOSE_PROJECT_NAME: myproject         # required if your project folder isn't the compose project name
      CHECK_INTERVAL: "60"                    # seconds between active connectivity checks
      AUTOHEAL_INTERVAL: "30"                 # seconds between autoheal label checks (non-VPN containers)
      AUTOHEAL_LABEL: autoheal=true           # label opting non-VPN containers into autoheal
```

### VPN-dependent containers (qBittorrent, Prowlarr, FlareSolverr, etc.)

Just declare them with `network_mode: "service:gluetun"` as usual. **No `autoheal=true` label needed** — they're recovered automatically by the active connectivity check and the event listener, both of which use `docker compose up -d` (the only command that works after a namespace break).

```yaml
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_healthy
    # no autoheal label here — VPN deps are handled by active check
```

### Non-VPN containers you want auto-restarted on unhealthy

Add the `autoheal=true` label and a healthcheck. Standard `willfarrell/autoheal` semantics apply:

```yaml
  immich-server:
    image: ghcr.io/immich-app/immich-server
    labels:
      autoheal: "true"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:2283"]
      interval: 30s
      timeout: 10s
      retries: 3
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GLUETUN_CONTAINER` | `gluetun` | Container name of your gluetun instance |
| `GLUETUN_DEPS` | `qbittorrent` | Space-separated compose service names that depend on gluetun's network |
| `COMPOSE_FILE` | `/workspace/docker-compose.yml` | Path to your docker-compose.yml inside the container |
| `ENV_FILE` | `/workspace/.env` | Path to your .env file inside the container |
| `GLUETUN_DEP_CONTAINERS` | _(falls back to `GLUETUN_DEPS`)_ | Space-separated container names of dependents (used to test connectivity from inside each one). Set this if container names differ from compose service names (e.g. `myproject_qbittorrent`) |
| `CHECK_INTERVAL` | `60` | Seconds between active connectivity checks |
| `VPN_TEST_HOST` | `1.1.1.1` | Host used for the TCP connectivity test |
| `VPN_TEST_PORT` | `443` | Port used for the TCP connectivity test |
| `VPN_TEST_TIMEOUT` | `10` | Timeout in seconds for each connectivity test |
| `FAILURE_THRESHOLD` | `2` | Consecutive VPN failures before restarting gluetun itself |
| `AUTOHEAL_INTERVAL` | `30` | Seconds between unhealthy container checks (non-VPN) |
| `AUTOHEAL_LABEL` | `autoheal=true` | Docker label used to opt non-VPN containers into autoheal |
| `COMPOSE_PROJECT_NAME` | _(empty)_ | Set this if your compose project name differs from the mounted folder name. When the compose file is mounted at `/workspace`, Docker Compose defaults to project name `workspace` — set this to your actual project name (e.g. `myproject`) to avoid conflicts |

## How it works

Three processes run in parallel:

1. **Active connectivity check** — every `CHECK_INTERVAL` seconds, runs `nc -z VPN_TEST_HOST:VPN_TEST_PORT` from inside the gluetun container and inside each dep container. If gluetun fails repeatedly, gluetun is restarted. If a dep fails (broken namespace), all deps are recreated with `docker compose up -d`.

2. **Event listener** — subscribes to Docker events and waits for `health_status: healthy` on the gluetun container. When triggered, runs `docker compose up -d <GLUETUN_DEPS>` to immediately reattach dependents.

3. **Autoheal loop** — polls every `AUTOHEAL_INTERVAL` seconds for containers labeled `autoheal=true` that are unhealthy. Restarts them with `docker restart`. VPN-dependent containers are skipped here (already covered by the active check).

## Troubleshooting / does this fix my problem?

If you've hit any of the following, this image is what you want:

- `qBittorrent WebUI returns 502 Bad Gateway after gluetun update`
- `Prowlarr / Sonarr "All indexers are unavailable due to failures"` after a gluetun restart
- `FlareSolverr / Byparr returns timeout` despite the container being "running"
- `nubul_qbittorrent | Up X days (unhealthy)` while the container looks fine in `docker ps`
- `docker restart nubul_qbittorrent` succeeds but the container still has no internet
- `wget: download timed out` when running `docker exec qbittorrent wget https://1.1.1.1`
- After Docker Desktop / host PC suspend-resume, VPN-dependent containers stop downloading
- Mullvad / NordVPN / Surfshark Wireguard tunnel reconnects but containers stay broken
- Containers using `network_mode: "service:gluetun"` show no traffic and torrent trackers all show "operation not permitted"

## Why not use willfarrell/autoheal?

[willfarrell/autoheal](https://github.com/willfarrell/autoheal) uses `docker restart` internally. This works for most containers, but **fails for containers sharing a network namespace via `network_mode: "service:gluetun"`** when gluetun itself was recreated — the network namespace reference is broken and cannot be restored with a restart.

## Security notes

Docker Hub's vulnerability scanner may report CVEs in this image. These originate from the Docker CLI binary (Go dependencies such as `google.golang.org/grpc`) included in the `docker:cli` base image — they are not introduced by this project's code. The Docker CLI binary is required to run `docker compose` commands and cannot be replaced. Fixes depend on Docker Inc. updating their Go dependencies.

The image uses a multi-stage build to keep the Alpine base minimal and up to date.

## Platforms

Built for `linux/amd64`, `linux/arm64` and `linux/arm/v7` (Raspberry Pi).

## Keywords

gluetun, qbittorrent behind vpn, network_mode service:gluetun, gluetun watchdog, gluetun autoheal, qbittorrent gluetun recreate, qbittorrent 502 vpn, prowlarr indexer unavailable vpn, flaresolverr no internet, byparr no internet, mullvad qbittorrent, wireguard docker container loses network, docker namespace broken after restart, vpn killswitch container, willfarrell autoheal alternative gluetun, docker compose up vs restart network namespace
