#!/bin/bash
# event-driven-ship.sh — Event-driven replacement for cron-auto-ship.sh
#
# Proof of concept for migrating cron → event-driven architecture.
# Instead of polling GitHub for issues on a timer, this script:
#   1. Subscribes to coms-net SSE for "issue.labeled" events
#   2. When a "spec-approved" label event arrives, immediately ships
#   3. Falls back to GitHub polling if SSE is disconnected
#
# This is a drop-in replacement for cron-auto-ship.sh.
# Migrate by pointing the cron entry at this script instead.
#
# Usage: ./event-driven-ship.sh [--fallback-poll SECONDS]
#
# Exit codes: 0 = success, 1 = error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Config ──────────────────────────────────────────────────────────────────
ENV_FILE="$HOME/pi-infra/config/coms-net.env"
COMS_NET_URL=""
AUTH_TOKEN=""
REPO=""
FALLBACK_POLL=300  # 5 min fallback poll when SSE is down

while IFS='=' read -r key value; do
  [[ "$key" =~ ^#.*$ ]] && continue
  [[ -z "$key" ]] && continue
  value="${value%\"}" ; value="${value#\"}"
  case "$key" in
    COMS_NET_URL) COMS_NET_URL="${COMS_NET_URL:-$value}" ;;
    COMS_AUTH_TOKEN) AUTH_TOKEN="${AUTH_TOKEN:-$value}" ;;
    REPO) REPO="${REPO:-$value}" ;;
  esac
done < "$ENV_FILE" 2>/dev/null || true

# Override from args
while [[ $# -gt 0 ]]; do
  case $1 in
    --fallback-poll) FALLBACK_POLL="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --coms-url) COMS_NET_URL="$2"; shift 2 ;;
    --auth) AUTH_TOKEN="$2"; shift 2 ;;
    *) shift ;;
  esac
done

COMS_NET_URL="${COMS_NET_URL:-http://localhost:8090}"

if [ -z "$REPO" ]; then
  echo "ERROR: No REPO configured. Set in $ENV_FILE or pass --repo owner/name" >&2
  exit 1
fi

# ── Logging ─────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/event-driven-ship"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d).log"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

# ── Signal handling ─────────────────────────────────────────────────────────
RUNNING=true
trap 'log "Shutting down..."; RUNNING=false' SIGTERM SIGINT

# ── Ship a single issue ────────────────────────────────────────────────────
# Reuses the existing auto-ship infrastructure
ship_issue() {
  local issue_number="$1"
  local source="${2:-event}"

  log "[$source] Shipping issue #$issue_number from $REPO"

  if [ -x "$SCRIPT_DIR/cron-auto-ship.sh" ]; then
    # Delegate to existing auto-ship with a single issue
    ISSUE_NUMBER="$issue_number" "$SCRIPT_DIR/cron-auto-ship.sh" --single-issue "$issue_number"
    return $?
  else
    log "ERROR: cron-auto-ship.sh not found at $SCRIPT_DIR"
    return 1
  fi
}

# ── Fallback: poll GitHub for spec-approved issues ──────────────────────────
fallback_poll() {
  log "[POLL] Checking for spec-approved issues..."

  local issues=$(/usr/bin/gh issue list \
    --repo "$REPO" \
    --label spec-approved \
    --state open \
    --json number,labels \
    --limit 5 \
    --jq '[.[] | select(
      (.labels | map(.name) | contains(["in-progress"]) | not) and
      (.labels | map(.name) | contains(["shipped"]) | not) and
      (.labels | map(.name) | contains(["spec-hold"]) | not)
    ) | .number] | .[]' 2>/dev/null || true)

  if [ -z "$issues" ]; then
    log "[POLL] No issues to ship"
    return 0
  fi

  for issue_num in $issues; do
    if ! $RUNNING; then break; fi
    ship_issue "$issue_num" "poll" || true
  done
}

# ── SSE subscription ────────────────────────────────────────────────────────
subscribe_and_dispatch() {
  log "[SSE] Connecting to $COMS_NET_URL/v1/events"

  local current_event_type=""

  curl -sS -N \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H "Accept: text/event-stream" \
    "$COMS_NET_URL/v1/events" 2>/dev/null | while IFS= read -r line; do
      if [[ "$line" =~ ^event:\ (.*)$ ]]; then
        current_event_type="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^data:\ (.*)$ ]]; then
        local data="${BASH_REMATCH[1]}"

        # Only handle issue.labeled events for spec-approved
        if [ "$current_event_type" = "issue.labeled" ]; then
          local label=$(echo "$data" | grep -o '"label":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
          if [ "$label" = "spec-approved" ]; then
            local issue_num=$(echo "$data" | grep -o '"issue_number":"[0-9]*"' | head -1 | grep -o '[0-9]*' || true)
            local repo=$(echo "$data" | grep -o '"repo":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

            if [ "$repo" = "$REPO" ] && [ -n "$issue_num" ]; then
              ship_issue "$issue_num" "event" || true
            fi
          fi
        fi

        current_event_type=""
      fi
    done

  return $?
}

# ── Main loop: SSE with fallback polling ────────────────────────────────────
SSE_RETRIES=0
MAX_SSE_RETRIES=5
LAST_POLL=0

log "=== Event-Driven Ship Started ==="
log "  Repo: $REPO"
log "  SSE: $COMS_NET_URL"
log "  Fallback poll: every ${FALLBACK_POLL}s"

while $RUNNING; do
  # Try SSE
  subscribe_and_dispatch
  SSE_RETRIES=$((SSE_RETRIES + 1))

  if [ $SSE_RETRIES -ge $MAX_SSE_RETRIES ]; then
    log "[SSE] Failed $MAX_SSE_RETRIES times — switching to poll mode"

    # Poll loop until SSE reconnects
    while $RUNNING; do
      local now=$(date +%s)
      if [ $((now - LAST_POLL)) -ge "$FALLBACK_POLL" ]; then
        fallback_poll || true
        LAST_POLL=$now
      fi
      sleep 30
    done
  fi

  # Brief backoff before SSE reconnect
  log "[SSE] Reconnecting in 5s (attempt $SSE_RETRIES/$MAX_SSE_RETRIES)..."
  sleep 5
done

log "=== Event-Driven Ship Stopped ==="
