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

# ── Email alerts (optional) ──
ALERT_EMAIL_TO="${ALERT_EMAIL_TO:-}"
ALERT_EMAIL_FROM="${ALERT_EMAIL_FROM:-$ALERT_EMAIL_TO}"
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-465}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
ALERT_AFTER_RESTARTS="${ALERT_AFTER_RESTARTS:-1}"
ALERT_FOLLOWUP_INTERVAL="${ALERT_FOLLOWUP_INTERVAL:-10800}"
ALERT_REFERRAL_NAME="${ALERT_REFERRAL_NAME:-}"
ALERT_REFERRAL_URL="${ALERT_REFERRAL_URL:-}"

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
  # --force-recreate is required because docker compose otherwise sees the
  # containers as "running" and skips them, even when their network namespace
  # is broken (which is exactly the case we're trying to fix)
  # shellcheck disable=SC2086
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" $PROJECT_ARG up -d --force-recreate $GLUETUN_DEPS
}

container_running() {
  docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

format_duration() {
  s="$1"
  h=$((s / 3600))
  m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then
    echo "${h}h ${m}m"
  else
    echo "${m}m"
  fi
}

referral_section() {
  if [ -n "$ALERT_REFERRAL_URL" ] && [ -n "$ALERT_REFERRAL_NAME" ]; then
    cat <<EOF


Looking for a reliable VPN provider? I personally recommend ${ALERT_REFERRAL_NAME}:
${ALERT_REFERRAL_URL}
(referral link — supports this project at no cost to you)
EOF
  fi
}

send_alert() {
  subject="$1"
  body="$2"

  if [ -z "$ALERT_EMAIL_TO" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASSWORD" ]; then
    return 0
  fi

  log "[alert] sending email: $subject"
  mail_file=$(mktemp)
  cat > "$mail_file" <<EOF
From: $ALERT_EMAIL_FROM
To: $ALERT_EMAIL_TO
Subject: [gluetun-autoheal] $subject

$body
$(referral_section)

---
Sent automatically by gluetun-autoheal.
Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S')
EOF

  if curl --silent --show-error --ssl-reqd \
       --url "smtps://${SMTP_HOST}:${SMTP_PORT}" \
       --mail-from "$ALERT_EMAIL_FROM" \
       --mail-rcpt "$ALERT_EMAIL_TO" \
       --upload-file "$mail_file" \
       --user "${SMTP_USER}:${SMTP_PASSWORD}" 2>&1; then
    log "[alert] sent OK"
  else
    log "[alert] failed to send"
  fi
  rm -f "$mail_file"
}

build_initial_body() {
  duration_str="$1"
  cat <<EOF
Your VPN tunnel through gluetun stopped working ${duration_str} ago.
Auto-recovery has been attempted (gluetun was restarted) but the VPN tunnel did not come back up.

Possible causes:
  1. VPN subscription expired or payment failed → check your provider account
  2. VPN server outage → try changing SERVER_COUNTRIES in your gluetun config
  3. Invalid credentials → verify your WIREGUARD_PRIVATE_KEY and WIREGUARD_ADDRESSES (or OpenVPN credentials)
  4. ISP blocking the VPN protocol → try a different port, server, or protocol type

The watchdog will keep trying to recover. You will receive a follow-up email every $(format_duration "$ALERT_FOLLOWUP_INTERVAL") if the issue persists, or no further emails once recovered.
EOF
}

build_followup_body() {
  duration_str="$1"
  restarts="$2"
  cat <<EOF
The VPN has now been down for ${duration_str}.
Auto-recovery has restarted gluetun ${restarts} times without success — manual intervention is needed.

Most likely: VPN provider issue (subscription, server, or credentials).
Less likely: networking problem on the host.

Next steps:
  - Log in to your VPN provider account and check subscription status
  - Try a different server / country
  - Verify credentials in your gluetun configuration
EOF
}

container_has_internet() {
  # Try nc, then curl, then wget — whichever the container image provides.
  # Returns 0 if any succeeds, 1 only if a tool exists AND fails.
  # If no tool is available, returns 0 (can't determine, assume OK).
  c="$1"
  if docker exec "$c" sh -c 'command -v nc' >/dev/null 2>&1; then
    docker exec "$c" nc -z -w "$VPN_TEST_TIMEOUT" "$VPN_TEST_HOST" "$VPN_TEST_PORT" >/dev/null 2>&1
    return $?
  fi
  if docker exec "$c" sh -c 'command -v curl' >/dev/null 2>&1; then
    docker exec "$c" curl -sf --max-time "$VPN_TEST_TIMEOUT" "https://${VPN_TEST_HOST}" >/dev/null 2>&1
    return $?
  fi
  if docker exec "$c" sh -c 'command -v wget' >/dev/null 2>&1; then
    docker exec "$c" wget -qO- --timeout="$VPN_TEST_TIMEOUT" "https://${VPN_TEST_HOST}" >/dev/null 2>&1
    return $?
  fi
  return 0
}

# ── 1. Active connectivity check (handles VPN drops, broken namespaces, suspend/resume) ──
active_check_loop() {
  log "Active check: started (interval=${CHECK_INTERVAL}s)"
  log "  Gluetun:    ${GLUETUN_CONTAINER}"
  log "  Containers: ${GLUETUN_DEP_CONTAINERS}"
  log "  Test:       ${VPN_TEST_HOST}:${VPN_TEST_PORT}"

  failures=0
  consecutive_restarts=0
  failure_start=0
  last_alert=0
  alert_count=0
  while true; do
    sleep "$CHECK_INTERVAL"

    if ! container_running "$GLUETUN_CONTAINER"; then
      log "[active] $GLUETUN_CONTAINER not running — skipping"
      continue
    fi

    if ! container_has_internet "$GLUETUN_CONTAINER"; then
      failures=$((failures + 1))
      [ "$failure_start" -eq 0 ] && failure_start=$(date +%s)
      log "[active] VPN unreachable (${failures}/${FAILURE_THRESHOLD})"
      if [ "$failures" -ge "$FAILURE_THRESHOLD" ]; then
        log "[active] VPN broken — restarting $GLUETUN_CONTAINER"
        docker restart "$GLUETUN_CONTAINER"
        failures=0
        consecutive_restarts=$((consecutive_restarts + 1))

        if [ "$consecutive_restarts" -ge "$ALERT_AFTER_RESTARTS" ]; then
          now=$(date +%s)
          duration=$((now - failure_start))
          duration_str=$(format_duration "$duration")
          if [ "$alert_count" -eq 0 ]; then
            send_alert "VPN connection lost" "$(build_initial_body "$duration_str")"
            last_alert=$now
            alert_count=1
          elif [ "$((now - last_alert))" -ge "$ALERT_FOLLOWUP_INTERVAL" ]; then
            send_alert "VPN still down — ${duration_str} failing" \
                       "$(build_followup_body "$duration_str" "$consecutive_restarts")"
            last_alert=$now
            alert_count=$((alert_count + 1))
          fi
        fi
      fi
      continue
    fi
    if [ "$alert_count" -gt 0 ]; then
      now=$(date +%s)
      total=$(format_duration "$((now - failure_start))")
      send_alert "VPN recovered after ${total}" \
                 "Good news — the VPN tunnel through ${GLUETUN_CONTAINER} is back up. Total outage: ${total}. Restart attempts: ${consecutive_restarts}."
    fi
    failures=0
    consecutive_restarts=0
    failure_start=0
    last_alert=0
    alert_count=0

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
