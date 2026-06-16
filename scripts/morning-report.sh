#!/bin/bash
# Morning report — daily autonomous summary from the peer network
#
# Sends a Telegram message with: ships, cost, open issues, agent health.
# Run via cron at 08:00: 0 8 * * * /path/to/scripts/morning-report.sh
#
# Issue: #42, #60
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO="bobbiejaxn/pi_launchpad"

[ -f "$PROJECT_ROOT/.pi/config.sh" ] && source "$PROJECT_ROOT/.pi/config.sh"

TG_BOT_TOKEN="${TG_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
TG_CHAT_ID="${TG_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
  echo "Error: TG_BOT_TOKEN and TG_CHAT_ID required"
  exit 1
fi

# ── Open issues ──────────────────────────────────────────────────────
OPEN_COUNT=$(gh issue list -R "$REPO" --state open --json number -q '. | length' 2>/dev/null || echo "?")
BUG_COUNT=$(gh issue list -R "$REPO" --state open --label bug --json number -q '. | length' 2>/dev/null || echo "?")

# ── Today's cost ─────────────────────────────────────────────────────
TRACE_DIR="$PROJECT_ROOT/.pi/traces/subagents"
TOTAL_COST="0"
RUN_COUNT=0

if [ -d "$TRACE_DIR" ]; then
  for f in $(find "$TRACE_DIR" -name "*.json" -mtime -1 2>/dev/null); do
    COST=$(grep -o '"cost":[0-9.]*' "$f" | tail -1 | grep -o '[0-9.]*$' || echo "0")
    TOTAL_COST=$(echo "$TOTAL_COST + $COST" | bc 2>/dev/null || echo "$TOTAL_COST")
    RUN_COUNT=$((RUN_COUNT + 1))
  done
fi

# ── Manifest runs ────────────────────────────────────────────────────
MANIFEST_COUNT=0
MANIFEST_DIR="$PROJECT_ROOT/.pi/traces/runs"
if [ -d "$MANIFEST_DIR" ]; then
  MANIFEST_COUNT=$(find "$MANIFEST_DIR" -name "manifest.json" -mtime -1 2>/dev/null | wc -l | tr -d ' ')
fi

# ── Stale agents ─────────────────────────────────────────────────────
STALE_COUNT=0
AGENTS_LIVE="$HOME/.pi/agents-live"
if [ -d "$AGENTS_LIVE" ]; then
  for pidFile in $(find "$AGENTS_LIVE" -name "*.pid" 2>/dev/null); do
    STALE_COUNT=$((STALE_COUNT + 1))
  done
fi

# ── Build message ────────────────────────────────────────────────────
DATE=$(date +"%a, %b %d")
MSG="☀️ *Morning Report — $DATE*

📋 *Backlog*: $OPEN_COUNT open issues ($BUG_COUNT bugs)
🤖 *Runs*: $RUN_COUNT agent runs yesterday
📊 *Manifests*: $MANIFEST_COUNT session manifests
💰 *Cost*: \$(printf '%.2f' $TOTAL_COST) USD yesterday
🧹 *Stale agents*: $STALE_COUNT PID files pending cleanup"

# Add top 3 open bugs if any
if [ "$BUG_COUNT" != "0" ] && [ "$BUG_COUNT" != "?" ]; then
  TOP_BUGS=$(gh issue list -R "$REPO" --state open --label bug --limit 3 --json title,number -q '.[] | "• #" + (.number|tostring) + " " + .title' 2>/dev/null || true)
  if [ -n "$TOP_BUGS" ]; then
    MSG="$MSG

🐛 *Top bugs:*
$TOP_BUGS"
  fi
fi

# Send
curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$MSG" > /dev/null 2>&1

echo "Morning report sent"
