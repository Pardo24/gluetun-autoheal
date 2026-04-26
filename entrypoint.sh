#!/bin/sh

# ── Configuration ────────────────────────────────────────────────
GLUETUN_CONTAINER="${GLUETUN_CONTAINER:-gluetun}"
GLUETUN_DEPS="${GLUETUN_DEPS:-qbittorrent}"
GLUETUN_DEP_CONTAINERS="${GLUETUN_DEP_CONTAINERS:-$GLUETUN_DEPS}"
COMPOSE_FILE="${COMPOSE_FILE:-/workspace/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-/workspace/.env}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
VPN_TEST_HOST="${VPN_TEST_HOST:-1.1.1.1}"
VPN_TEST_PORT="${VPN_TEST_PORT:-443}"
VPN_TEST_TIMEOUT="${VPN_TEST_TIMEOUT:-10}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-2}"
AUTOHEAL_INTERVAL="${AUTOHEAL_INTERVAL:-30}"
AUTOHEAL_LABEL="${AUTOHEAL_LABEL:-autoheal=true}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

is_gluetun_dep() {
  for c in $GLUETUN_DEP_CONTAINERS; do
    [ "$1" = "$c" ] && return 0
  done
  return 1
}

compose_up_deps() {
  PROJECT_ARG=""
  [ -n "$COMPOSE_PROJECT_NAME" ] && PROJECT_ARG="-p $COMPOSE_PROJECT_NAME"
  # shellcheck disable=SC2086
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROJECT_ARG up -d $GLUETUN_DEPS
}

container_running() {
  docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

container_has_internet() {
  docker exec "$1" nc -z -w "$VPN_TEST_TIMEOUT" "$VPN_TEST_HOST" "$VPN_TEST_PORT" >/dev/null 2>&1
}

# ── 1. Active connectivity check (handles VPN drops, broken namespaces, suspend/resume) ──
active_check_loop() {
  log "Active check: started (interval=${CHECK_INTERVAL}s)"
  log "  Gluetun:    ${GLUETUN_CONTAINER}"
  log "  Containers: ${GLUETUN_DEP_CONTAINERS}"
  log "  Test:       ${VPN_TEST_HOST}:${VPN_TEST_PORT}"

  failures=0
  while true; do
    sleep "$CHECK_INTERVAL"

    if ! container_running "$GLUETUN_CONTAINER"; then
      log "[active] $GLUETUN_CONTAINER not running — skipping"
      continue
    fi

    if ! container_has_internet "$GLUETUN_CONTAINER"; then
      failures=$((failures + 1))
      log "[active] VPN unreachable (${failures}/${FAILURE_THRESHOLD})"
      if [ "$failures" -ge "$FAILURE_THRESHOLD" ]; then
        log "[active] VPN broken — restarting $GLUETUN_CONTAINER"
        docker restart "$GLUETUN_CONTAINER"
        failures=0
      fi
      continue
    fi
    failures=0

    for container in $GLUETUN_DEP_CONTAINERS; do
      if ! container_running "$container"; then
        log "[active] $container not running — recreating dependents"
        compose_up_deps
        break
      fi
      if ! container_has_internet "$container"; then
        log "[active] $container has no internet (broken namespace) — recreating dependents"
        compose_up_deps
        break
      fi
    done
  done
}

# ── 2. Gluetun event listener (fast reaction to recreation) ──
gluetun_event_watch() {
  log "Event listener: monitoring health events for '${GLUETUN_CONTAINER}'"
  docker events \
    --filter "container=${GLUETUN_CONTAINER}" \
    --filter event=health_status \
    --format '{{.Action}}' | \
  while read -r status; do
    if [ "$status" = "health_status: healthy" ]; then
      log "[event] gluetun healthy — recreating: $GLUETUN_DEPS"
      sleep 5
      compose_up_deps
    fi
  done
}

# ── 3. Autoheal for non-VPN containers (label=autoheal=true) ──
# VPN deps are skipped — handled by active_check_loop instead
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
      if is_gluetun_dep "$container"; then
        continue
      fi
      log "[autoheal] restarting $container"
      docker restart "$container"
    done
  done
}

active_check_loop &
gluetun_event_watch &
autoheal_loop
