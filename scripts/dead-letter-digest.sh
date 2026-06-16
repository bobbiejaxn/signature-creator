#!/bin/bash
# dead-letter-digest.sh — DLQ digest + Telegram notification
#
# Scans the dead letter queue for entries exceeding retry limits,
# sends a Telegram digest, and optionally retries via callback.
#
# Usage: ./dead-letter-digest.sh [--retry] [--dry-run]
#
# Exit codes: 0 = success, 1 = error
set -euo pipefail

DLQ_DIR="${DLQ_DIR:-/root/.hermes/dlq}"
DLQ_DEAD_DIR="$DLQ_DIR/dead"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
LOG_FILE="/var/log/dlq-digest.log"
DRY_RUN=false
RETRY=false

# ── Args ────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --retry) RETRY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# ── Logging ─────────────────────────────────────────────────────────────────
log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE" 2>/dev/null || echo "$1"
}

# ── Load Telegram config from env file ──────────────────────────────────────
ENV_FILE="$HOME/pi-infra/config/coms-net.env"
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    value="${value%\"}" ; value="${value#\"}"
    case "$key" in
      TELEGRAM_BOT_TOKEN) TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$value}" ;;
      TELEGRAM_CHAT_ID) TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-$value}" ;;
    esac
  done < "$ENV_FILE"
fi

send_telegram() {
  local message="$1"
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "Telegram not configured — skipping notification"
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would send Telegram: ${message:0:100}..."
    return 0
  fi
  # Escape markdown special chars
  local escaped=$(echo "$message" | sed 's/[_*[\]()~`>#+-=|{}.!]/\\&/g')
  curl -sS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${TELEGRAM_CHAT_ID}\", \"text\": \"${escaped}\", \"parse_mode\": \"MarkdownV2\"}" \
    >/dev/null 2>&1 || log "WARNING: Telegram send failed"
}

# ── Scan DLQ ────────────────────────────────────────────────────────────────
log "=== DLQ Digest Started ==="

# Ensure directories exist
mkdir -p "$DLQ_DIR" "$DLQ_DEAD_DIR"

# Count active DLQ entries (not yet moved to dead/)
ACTIVE_COUNT=0
DEAD_COUNT=0
DIGEST_LINES=""

# Process active DLQ entries
for dlq_file in "$DLQ_DIR"/*.json; do
  [ -f "$dlq_file" ] || continue
  ACTIVE_COUNT=$((ACTIVE_COUNT + 1))

  # Extract fields from JSON
  local job_name=$(grep -o '"job_name": *"[^"]*"' "$dlq_file" | head -1 | cut -d'"' -f4 || echo "unknown")
  local issue_num=$(grep -o '"issue_number": *"[^"]*"' "$dlq_file" | head -1 | cut -d'"' -f4 || echo "?")
  local project=$(grep -o '"project": *"[^"]*"' "$dlq_file" | head -1 | cut -d'"' -f4 || echo "unknown")
  local error=$(grep -o '"error": *"[^"]*"' "$dlq_file" | head -1 | cut -d'"' -f4 || echo "unknown error")
  local timestamp=$(grep -o '"timestamp": *"[^"]*"' "$dlq_file" | head -1 | cut -d'"' -f4 || echo "?")

  # Truncate error for digest
  error="${error:0:80}"

  DIGEST_LINES="${DIGEST_LINES}
• ${project}#${issue_num}: ${error}
  Job: ${job_name} | Time: ${timestamp}"

  # If --retry flag, attempt retry for entries that haven't exceeded limit
  if [ "$RETRY" = true ] && [ "$DRY_RUN" = false ]; then
    log "Retrying DLQ entry: $job_name"
    # Re-queue by removing DLQ entry — the cron will pick it up again
    mv "$dlq_file" "$DLQ_DIR/retried-$(basename "$dlq_file")" 2>/dev/null || true
  fi
done

# Count dead entries
for dead_file in "$DLQ_DEAD_DIR"/*.json; do
  [ -f "$dead_file" ] || continue
  DEAD_COUNT=$((DEAD_COUNT + 1))
done

# ── Build digest message ───────────────────────────────────────────────────
if [ "$ACTIVE_COUNT" -eq 0 ] && [ "$DEAD_COUNT" -eq 0 ]; then
  log "DLQ is empty — no digest needed"
  exit 0
fi

MESSAGE="📋 *DLQ Digest*

Active failures: ${ACTIVE_COUNT}
Dead (exceeded retry limit): ${DEAD_COUNT}"

if [ -n "$DIGEST_LINES" ]; then
  MESSAGE="${MESSAGE}

*Active entries:*
${DIGEST_LINES}"
fi

if [ "$DEAD_COUNT" -gt 0 ]; then
  MESSAGE="${MESSAGE}

⚠️ ${DEAD_COUNT} entries in dead letter queue — manual review needed"
fi

# ── Send notification ───────────────────────────────────────────────────────
log "Sending digest: ${ACTIVE_COUNT} active, ${DEAD_COUNT} dead"
send_telegram "$MESSAGE"

# ── Cleanup old dead entries (older than 30 days) ───────────────────────────
CLEANUP_COUNT=0
if [ -d "$DLQ_DEAD_DIR" ]; then
  for f in "$DLQ_DEAD_DIR"/*.json; do
    [ -f "$f" ] || continue
    # Check file age
    if [ "$(find "$f" -mtime +30 2>/dev/null)" ]; then
      rm -f "$f"
      CLEANUP_COUNT=$((CLEANUP_COUNT + 1))
    fi
  done
fi
[ "$CLEANUP_COUNT" -gt 0 ] && log "Cleaned up $CLEANUP_COUNT dead entries older than 30 days"

log "=== DLQ Digest Complete ==="
exit 0
