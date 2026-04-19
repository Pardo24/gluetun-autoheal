#!/bin/sh

# ── Configuration ────────────────────────────────────────────────
GLUETUN_CONTAINER="${GLUETUN_CONTAINER:-gluetun}"
GLUETUN_DEPS="${GLUETUN_DEPS:-qbittorrent}"
COMPOSE_FILE="${COMPOSE_FILE:-/workspace/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-/workspace/.env}"
AUTOHEAL_INTERVAL="${AUTOHEAL_INTERVAL:-30}"
AUTOHEAL_LABEL="${AUTOHEAL_LABEL:-autoheal=true}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Returns 0 if container name matches any gluetun dep service name
is_gluetun_dep() {
  for dep in $GLUETUN_DEPS; do
    case "$1" in *"$dep"*) return 0 ;; esac
  done
  return 1
}

compose_up_deps() {
  # shellcheck disable=SC2086
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d $GLUETUN_DEPS
}

# ── Autoheal loop ────────────────────────────────────────────────
autoheal_loop() {
  log "Autoheal: started (interval=${AUTOHEAL_INTERVAL}s, label=${AUTOHEAL_LABEL})"
  while true; do
    sleep "$AUTOHEAL_INTERVAL"
    unhealthy=$(docker ps \
      --filter "label=${AUTOHEAL_LABEL}" \
      --filter "health=unhealthy" \
      --format "{{.Names}}" 2>/dev/null)
    [ -z "$unhealthy" ] && continue
    for container in $unhealthy; do
      log "Autoheal: $container is unhealthy"
      if is_gluetun_dep "$container"; then
        log "  → gluetun-dependent, using compose up..."
        compose_up_deps
      else
        log "  → restarting $container..."
        docker restart "$container"
      fi
    done
  done
}

# ── Gluetun watchdog ─────────────────────────────────────────────
gluetun_watch() {
  log "Watchdog: monitoring health events for '${GLUETUN_CONTAINER}'..."
  log "  Deps: ${GLUETUN_DEPS}"
  docker events \
    --filter "container=${GLUETUN_CONTAINER}" \
    --filter event=health_status \
    --format '{{.Status}}' | \
  while read -r status; do
    if [ "$status" = "health_status: healthy" ]; then
      log "gluetun healthy — recreating: $GLUETUN_DEPS"
      sleep 3
      compose_up_deps
      log "Done."
    fi
  done
}

autoheal_loop &
gluetun_watch
