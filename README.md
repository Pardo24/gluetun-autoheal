# gluetun-autoheal

Automatically recovers containers that share gluetun's network namespace when gluetun is recreated or restarted.

## The problem

When you run containers like qBittorrent, Prowlarr or FlareSolverr with `network_mode: "service:gluetun"`, they share gluetun's network namespace. If gluetun is **recreated** (e.g. after `docker compose up -d gluetun` to update it), those containers lose their network — they appear running but have no connectivity.

`docker restart` cannot fix this. You must run `docker compose up -d` to recreate them.

Common symptoms:
- qBittorrent returns 502 after gluetun update
- Prowlarr/FlareSolverr lose internet connectivity after gluetun recreate
- `docker restart nubul_qbittorrent` fails silently or with a network error
- Containers show as healthy in `docker ps` but have no actual network access

## The solution

`gluetun-autoheal` watches Docker health events for gluetun. When gluetun becomes healthy, it runs `docker compose up -d` for all configured dependents — recreating them with a fresh network namespace attachment.

It also acts as a general **autoheal** for any container with the `autoheal=true` label, using `docker compose up -d` for gluetun-dependent containers and `docker restart` for everything else.

## Usage

```yaml
services:
  gluetun-autoheal:
    image: danipardo/gluetun-autoheal:latest
    container_name: gluetun_autoheal
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /path/to/your/project:/workspace:ro   # must contain docker-compose.yml and .env
    environment:
      GLUETUN_CONTAINER: gluetun              # container name of your gluetun instance
      GLUETUN_DEPS: "qbittorrent prowlarr flaresolverr"  # compose service names to recreate
      COMPOSE_FILE: /workspace/docker-compose.yml
      ENV_FILE: /workspace/.env
      AUTOHEAL_INTERVAL: "30"                 # seconds between autoheal checks
      AUTOHEAL_LABEL: autoheal=true           # label to watch for autoheal
```

Mark containers you want autoheal to monitor:

```yaml
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_healthy
    labels:
      autoheal: "true"
    healthcheck:
      test: ["CMD", "curl", "-sf", "https://1.1.1.1"]
      interval: 30s
      timeout: 15s
      retries: 3
      start_period: 30s
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GLUETUN_CONTAINER` | `gluetun` | Container name of your gluetun instance |
| `GLUETUN_DEPS` | `qbittorrent` | Space-separated compose service names that depend on gluetun's network |
| `COMPOSE_FILE` | `/workspace/docker-compose.yml` | Path to your docker-compose.yml inside the container |
| `ENV_FILE` | `/workspace/.env` | Path to your .env file inside the container |
| `AUTOHEAL_INTERVAL` | `30` | Seconds between unhealthy container checks |
| `AUTOHEAL_LABEL` | `autoheal=true` | Docker label used to opt containers into autoheal |

## How it works

Two processes run in parallel:

1. **Watchdog** — subscribes to Docker events and waits for `health_status: healthy` on the gluetun container. When triggered, runs `docker compose up -d <GLUETUN_DEPS>`.

2. **Autoheal** — polls every `AUTOHEAL_INTERVAL` seconds for containers labeled `autoheal=true` that are in `unhealthy` state. For gluetun-dependent containers it runs `docker compose up -d`; for others it runs `docker restart`.

## Why not use willfarrell/autoheal?

[willfarrell/autoheal](https://github.com/willfarrell/autoheal) uses `docker restart` internally. This works for most containers, but **fails for containers sharing a network namespace via `network_mode: "service:gluetun"`** when gluetun itself was recreated — the network namespace reference is broken and cannot be restored with a restart.

## Platforms

Built for `linux/amd64`, `linux/arm64` and `linux/arm/v7` (Raspberry Pi).
