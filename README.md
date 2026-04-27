# gluetun-autoheal

All-in-one watchdog that keeps containers using `network_mode: "service:gluetun"` alive across gluetun recreations, VPN drops, host suspend/resume, and broken network namespaces.

## The problem

When you run containers like qBittorrent, Prowlarr or FlareSolverr with `network_mode: "service:gluetun"`, they share gluetun's network namespace. Several common scenarios break them silently:

- **Gluetun is recreated** (e.g. after `docker compose up -d gluetun`): dependents lose their namespace reference and `docker restart` cannot fix it.
- **VPN provider drops the tunnel**: gluetun stays "running" but has no internet.
- **Host PC suspended/resumed**: Docker may leave dependents in a half-broken state.
- **Mullvad/Wireguard hiccup**: gluetun reconnects but dependents remain stuck on the old tunnel.

Symptoms: qBittorrent returns 502, Prowlarr indexers fail with timeouts, containers show healthy in `docker ps` but have no actual network access.

## The solution

This image runs three coordinated mechanisms in a single container:

1. **Active connectivity check** (every `CHECK_INTERVAL` seconds): actively tests if gluetun and each dependent container can reach the internet. If a dependent has no connectivity, it is recreated with `docker compose up -d`. If gluetun itself can't reach the internet for `FAILURE_THRESHOLD` consecutive checks, gluetun is restarted.

2. **Gluetun health event listener**: reacts immediately when Docker fires a `health_status: healthy` event for gluetun (typically right after a recreation). Recreates all configured dependents.

3. **Autoheal for non-VPN containers**: for any container with the `autoheal=true` label that is not in the gluetun dep list, restarts it via `docker restart` when it becomes unhealthy. VPN deps are skipped here, since they're already covered by the active check.

Optional: **email alerts** when the VPN can't be recovered automatically (subscription expired, server outage, bad credentials), with optional referral link to monetize alerts.

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

Just declare them with `network_mode: "service:gluetun"` as usual. **No `autoheal=true` label needed**: they're recovered automatically by the active connectivity check and the event listener, both of which use `docker compose up -d` (the only command that works after a namespace break).

```yaml
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_healthy
    # no autoheal label here, VPN deps are handled by active check
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
| `GLUETUN_DEP_CONTAINERS` | _(falls back to `GLUETUN_DEPS`)_ | Space-separated container names of dependents (used to test connectivity from inside each one). Set this if container names differ from compose service names (e.g. `myproject_qbittorrent`) |
| `COMPOSE_FILE` | `/workspace/docker-compose.yml` | Path to your docker-compose.yml inside the container |
| `ENV_FILE` | `/workspace/.env` | Path to your .env file inside the container |
| `COMPOSE_PROJECT_NAME` | _(empty)_ | Set this if your compose project name differs from the mounted folder name. When the compose file is mounted at `/workspace`, Docker Compose defaults to project name `workspace`, so set this to your actual project name (e.g. `myproject`) to avoid conflicts |
| `CHECK_INTERVAL` | `60` | Seconds between active connectivity checks |
| `VPN_TEST_HOST` | `1.1.1.1` | Host used for the TCP connectivity test |
| `VPN_TEST_PORT` | `443` | Port used for the TCP connectivity test |
| `VPN_TEST_TIMEOUT` | `10` | Timeout in seconds for each connectivity test |
| `FAILURE_THRESHOLD` | `2` | Consecutive VPN failures before restarting gluetun itself |
| `AUTOHEAL_INTERVAL` | `30` | Seconds between unhealthy container checks (non-VPN) |
| `AUTOHEAL_LABEL` | `autoheal=true` | Docker label used to opt non-VPN containers into autoheal |
| `ALERT_EMAIL_TO` | _(empty)_ | If set, send email alert when VPN fails repeatedly. Disabled by default. |
| `ALERT_EMAIL_FROM` | _(falls back to `ALERT_EMAIL_TO`)_ | "From" address on alert emails |
| `SMTP_HOST` | `smtp.gmail.com` | SMTP server hostname |
| `SMTP_PORT` | `465` | SMTP port (use 465 for SMTPS) |
| `SMTP_USER` | _(empty)_ | SMTP username (usually your full email) |
| `SMTP_PASSWORD` | _(empty)_ | SMTP password. For Gmail use an [App Password](https://myaccount.google.com/apppasswords), not your account password |
| `ALERT_AFTER_RESTARTS` | `1` | Send first alert after N consecutive gluetun restarts that didn't restore the VPN |
| `ALERT_FOLLOWUP_INTERVAL` | `10800` | Seconds between follow-up alerts during a sustained outage (default: 3 hours) |
| `ALERT_REFERRAL_NAME` | _(empty)_ | Optional VPN provider name to recommend in alert emails (e.g. `ProtonVPN`) |
| `ALERT_REFERRAL_URL` | _(empty)_ | Optional referral URL appended to alert emails. Lets you monetize alerts when users' current VPN fails, since they're already in the mindset to switch providers |

## How it works

Three processes run in parallel:

1. **Active connectivity check**: every `CHECK_INTERVAL` seconds, runs a TCP probe (`nc`, `curl` or `wget`, whichever the container has) from inside the gluetun container and inside each dep container. If gluetun fails repeatedly, gluetun is restarted. If a dep fails (broken namespace), all deps are recreated with `docker compose up -d`.

2. **Event listener**: subscribes to Docker events and waits for `health_status: healthy` on the gluetun container. When triggered, runs `docker compose up -d <GLUETUN_DEPS>` to immediately reattach dependents.

3. **Autoheal loop**: polls every `AUTOHEAL_INTERVAL` seconds for containers labeled `autoheal=true` that are unhealthy. Restarts them with `docker restart`. VPN-dependent containers are skipped here (already covered by the active check).

## Email alerts

The watchdog can recover from gluetun recreations, transient VPN drops and broken namespaces. But if your VPN provider account expires, the server is down, or your credentials are wrong, no amount of restarts will help. To know when to act, configure email alerts:

```yaml
    environment:
      ALERT_EMAIL_TO: you@example.com
      SMTP_HOST: smtp.gmail.com
      SMTP_PORT: "465"
      SMTP_USER: you@gmail.com
      SMTP_PASSWORD: xxxxxxxxxxxxxxxx   # Gmail App Password, not your account password
      ALERT_AFTER_RESTARTS: "1"          # alert after first failed gluetun restart (~2 min)
      ALERT_FOLLOWUP_INTERVAL: "10800"   # follow-up email every 3 hours if still down
      # Optional: monetize alerts via referral
      ALERT_REFERRAL_NAME: "ProtonVPN"
      ALERT_REFERRAL_URL: "https://pr.tn/ref/YOUR_CODE"
```

**For Gmail**: generate an [App Password](https://myaccount.google.com/apppasswords) (your account must have 2FA enabled). Don't use your real password.

You'll receive three types of email:

1. **First alert**: when the VPN starts failing and a recovery attempt has already failed (typically within ~2 minutes of the outage).
2. **Follow-up**: every `ALERT_FOLLOWUP_INTERVAL` seconds (default 3h) while the outage continues, with the running duration so you know how long it's been down.
3. **Recovery**: once when the VPN comes back online, with total outage duration and restart count.

Leave `ALERT_EMAIL_TO` empty to disable alerts entirely.

### Optional: VPN referral monetization

When the user's current VPN fails repeatedly, they're in the perfect mindset to consider switching. If you operate a self-hosted setup for others (or want to support development of this image), set `ALERT_REFERRAL_NAME` and `ALERT_REFERRAL_URL`. Every alert email will include a referral block recommending your chosen VPN provider. Most VPN providers run affiliate programs that pay 30-100% of the first subscription:

- **ProtonVPN**: pays ~50% of first sub, jurisdiction Switzerland, open source.
- **NordVPN**: pays up to 100% of first sub.
- **Surfshark**: 40% recurring commission.
- **AirVPN**: has affiliate program, more technical.
- **Mullvad**: does not run an affiliate program (deliberate, by their philosophy).

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

[willfarrell/autoheal](https://github.com/willfarrell/autoheal) uses `docker restart` internally. This works for most containers, but **fails for containers sharing a network namespace via `network_mode: "service:gluetun"`** when gluetun itself was recreated. The network namespace reference is broken and cannot be restored with a restart. This image uses `docker compose up -d` instead, which forces a clean re-attachment.

## Security notes

Docker Hub's vulnerability scanner may report CVEs in this image. These originate from the Docker CLI binary (Go dependencies such as `google.golang.org/grpc`) included in the `docker:cli` base image, they are not introduced by this project's code. The Docker CLI binary is required to run `docker compose` commands and cannot be replaced. Fixes depend on Docker Inc. updating their Go dependencies.

The image uses a multi-stage build to keep the Alpine base minimal and up to date.

## Platforms

Built for `linux/amd64` and `linux/arm64` (covers x86 servers and modern Raspberry Pi 3/4/5 running 64-bit OS).

## License

MIT, see [LICENSE](LICENSE).

## Keywords

gluetun, qbittorrent behind vpn, network_mode service:gluetun, gluetun watchdog, gluetun autoheal, qbittorrent gluetun recreate, qbittorrent 502 vpn, prowlarr indexer unavailable vpn, flaresolverr no internet, byparr no internet, mullvad qbittorrent, wireguard docker container loses network, docker namespace broken after restart, vpn killswitch container, willfarrell autoheal alternative gluetun, docker compose up vs restart network namespace
