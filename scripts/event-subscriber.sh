#!/bin/bash
# event-subscriber.sh — SSE push + Convex poll fallback
#
# Subscribes to coms-net SSE events and dispatches handlers.
# Falls back to Convex polling if SSE disconnects.
#
# Usage: ./event-subscriber.sh [--poll-only] [--convex-url URL]
#
# Exit codes: 0 = graceful shutdown, 1 = fatal error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POLL_ONLY=false
CONVEX_URL=""
COMS_NET_URL=""
AUTH_TOKEN=""
POLL_INTERVAL=30  # seconds between Convex polls when SSE is down
PID_FILE="/tmp/event-subscriber.pid"

# ── Args ────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --poll-only) POLL_ONLY=true; shift ;;
    --convex-url) CONVEX_URL="$2"; shift 2 ;;
    --coms-url) COMS_NET_URL="$2"; shift 2 ;;
    --auth) AUTH_TOKEN="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# ── Config ──────────────────────────────────────────────────────────────────
ENV_FILE="$HOME/pi-infra/config/coms-net.env"
if [ -f "$ENV_FILE" ]; then
  # Source env vars (COMS_NET_URL, COMS_AUTH_TOKEN, CONVEX_URL)
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    value="${value%\"}" ; value="${value#\"}"
    case "$key" in
      COMS_NET_URL) COMS_NET_URL="${COMS_NET_URL:-$value}" ;;
      COMS_AUTH_TOKEN) AUTH_TOKEN="${AUTH_TOKEN:-$value}" ;;
      CONVEX_URL) CONVEX_URL="${CONVEX_URL:-$value}" ;;
    esac
  done < "$ENV_FILE"
fi

COMS_NET_URL="${COMS_NET_URL:-http://localhost:8090}"
AUTH_TOKEN="${AUTH_TOKEN:-}"
CONVEX_URL="${CONVEX_URL:-}"

if [ -z "$AUTH_TOKEN" ]; then
  echo "ERROR: No auth token. Set COMS_AUTH_TOKEN in $ENV_FILE or pass --auth" >&2
  exit 1
fi

# ── Signal handling ─────────────────────────────────────────────────────────
RUNNING=true
trap 'echo "Shutting down..."; RUNNING=false' SIGTERM SIGINT

# ── Write PID file ─────────────────────────────────────────────────────────
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

# ── Handler dispatch ────────────────────────────────────────────────────────
dispatch_handler() {
  local event_type="$1"
  local event_data="$2"

  echo "[$(date -u +%H:%M:%S)] Event: $event_type"

  case "$event_type" in
    issue.created|issue.labeled)
      # Dispatch to auto-ship pipeline
      if [ -x "$SCRIPT_DIR/cron-auto-ship.sh" ]; then
        echo "  → Dispatching to cron-auto-ship.sh"
        # Extract issue number and repo from event data
        local issue_num=$(echo "$event_data" | grep -o '"issue_number":"[0-9]*"' | head -1 | grep -o '[0-9]*' || true)
        local repo=$(echo "$event_data" | grep -o '"repo":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        if [ -n "$issue_num" ] && [ -n "$repo" ]; then
          nohup "$SCRIPT_DIR/cron-auto-ship.sh" --issue "$issue_num" --repo "$repo" >/dev/null 2>&1 &
        fi
      fi
      ;;
    deploy.requested)
      # Dispatch to deploy handler
      local project=$(echo "$event_data" | grep -o '"project":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      if [ -n "$project" ] && [ -x "$SCRIPT_DIR/deploy-handler.sh" ]; then
        echo "  → Dispatching deploy for $project"
        nohup "$SCRIPT_DIR/deploy-handler.sh" "$project" >/dev/null 2>&1 &
      fi
      ;;
    schedule.*)
      # Scheduled events — log only for now
      echo "  → Scheduled event (no handler)"
      ;;
    *)
      echo "  → Unknown event type: $event_type"
      ;;
  esac
}

# ── SSE subscription ────────────────────────────────────────────────────────
subscribe_sse() {
  echo "[$(date -u +%H:%M:%S)] Connecting to SSE at $COMS_NET_URL/v1/events"

  # Use curl for SSE — stream individual lines
  curl -sS -N \
    -H "Authorization: Bearer $AUTH_TOKEN" \
    -H "Accept: text/event-stream" \
    "$COMS_NET_URL/v1/events" 2>/dev/null | while IFS= read -r line; do
      # Parse SSE format: "event: type" then "data: {...}"
      if [[ "$line" =~ ^event:\ (.*)$ ]]; then
        CURRENT_EVENT_TYPE="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^data:\ (.*)$ ]]; then
        dispatch_handler "${CURRENT_EVENT_TYPE:-unknown}" "${BASH_REMATCH[1]}"
        CURRENT_EVENT_TYPE=""
      elif [[ "$line" == "" ]]; then
        # End of SSE event
        :
      fi
    done

  local exit_code=$?
  echo "[$(date -u +%H:%M:%S)] SSE disconnected (exit: $exit_code)"
  return $exit_code
}

# ── Convex poll fallback ────────────────────────────────────────────────────
poll_convex() {
  if [ -z "$CONVEX_URL" ]; then
    echo "No CONVEX_URL configured — skipping poll fallback" >&2
    return 1
  fi

  echo "[$(date -u +%H:%M:%S)] Polling Convex for unprocessed events..."

  # Query Convex for events with status="pending"
  local response=$(curl -sS \
    -H "Content-Type: application/json" \
    "$CONVEX_URL/api/query" \
    -d '{"path": "events:list", "args": {"status": "pending", "limit": 10}}' 2>/dev/null || echo '{"value":[]}')

  local events=$(echo "$response" | grep -o '"value":\[.*\]' | head -1 || echo '[]')

  # Parse and dispatch each event
  echo "$events" | grep -o '"_id":"[^"]*"' | while read -r id_field; do
    local event_id=$(echo "$id_field" | cut -d'"' -f4)
    local event_type=$(echo "$response" | grep -o "\"type\":\"[^\"]*\"" | head -1 | cut -d'"' -f4 || echo "unknown")
    dispatch_handler "$event_type" "$response"
  done
}

# ── Main loop ───────────────────────────────────────────────────────────────
SSE_RETRIES=0
MAX_SSE_RETRIES=10

echo "=== Event Subscriber Started ==="
echo "  SSE: $COMS_NET_URL"
echo "  Convex: ${CONVEX_URL:-not configured}"
echo "  Poll-only: $POLL_ONLY"
echo ""

while $RUNNING; do
  if [ "$POLL_ONLY" = true ]; then
    poll_convex || true
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Try SSE first
  subscribe_sse
  SSE_RETRIES=$((SSE_RETRIES + 1))

  if [ $SSE_RETRIES -ge $MAX_SSE_RETRIES ]; then
    echo "[$(date -u +%H:%M:%S)] SSE failed $MAX_SSE_RETRIES times — falling back to polling"
    POLL_ONLY=true
    continue
  fi

  # Brief backoff before SSE reconnect
  echo "[$(date -u +%H:%M:%S)] Reconnecting SSE in 5s (attempt $SSE_RETRIES/$MAX_SSE_RETRIES)..."
  sleep 5
done

echo "=== Event Subscriber Stopped ==="
