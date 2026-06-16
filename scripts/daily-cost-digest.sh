#!/bin/bash
# Daily cost digest — sends Telegram summary of agent spending
#
# Reads trace files from .pi/traces/subagents/ and sends a daily digest.
# Run via cron: 0 20 * * * /path/to/scripts/daily-cost-digest.sh
#
# Issue: #56
set -e

# Config — read from environment or .pi/config.sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source config if available
[ -f "$PROJECT_ROOT/.pi/config.sh" ] && source "$PROJECT_ROOT/.pi/config.sh"

TG_BOT_TOKEN="${TG_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-}}"
TG_CHAT_ID="${TG_CHAT_ID:-${TELEGRAM_CHAT_ID:-}}"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
  echo "Error: TG_BOT_TOKEN and TG_CHAT_ID required"
  exit 1
fi

TRACE_DIR="$PROJECT_ROOT/.pi/traces/subagents"

if [ ! -d "$TRACE_DIR" ]; then
  echo "No traces directory — nothing to report"
  exit 0
fi

# Find today's trace files
TODAY=$(date +%Y-%m-%d)
TODAY_FILES=$(find "$TRACE_DIR" -name "*.json" -newermt "$TODAY 00:00:00" ! -newermt "$(date -v+1d +%Y-%m-%d) 00:00:00" 2>/dev/null || true)

if [ -z "$TODAY_FILES" ]; then
  # Try with -mtime for cross-platform
  TODAY_FILES=$(find "$TRACE_DIR" -name "*.json" -mtime -1 2>/dev/null || true)
fi

if [ -z "$TODAY_FILES" ]; then
  echo "No trace files from today"
  exit 0
fi

# Parse costs from trace files
TOTAL_COST=0
TOTAL_INPUT=0
TOTAL_OUTPUT=0
SUCCESS_COUNT=0
FAIL_COUNT=0
TOP_COST=0
TOP_TASK=""

for f in $TODAY_FILES; do
  # Extract cost and status from JSON trace
  COST=$(grep -o '"cost":[0-9.]*' "$f" | tail -1 | grep -o '[0-9.]*$' || echo "0")
  EXIT_CODE=$(grep -o '"exitCode":[0-9]*' "$f" | tail -1 | grep -o '[0-9]*$' || echo "1")
  AGENT=$(grep -o '"agent":"[^"]*"' "$f" | head -1 | sed 's/"agent":"//;s/"//')
  INPUT=$(grep -o '"input":[0-9]*' "$f" | tail -1 | grep -o '[0-9]*$' || echo "0")
  OUTPUT=$(grep -o '"output":[0-9]*' "$f" | tail -1 | grep -o '[0-9]*$' || echo "0")

  TOTAL_COST=$(echo "$TOTAL_COST + $COST" | bc 2>/dev/null || echo "$TOTAL_COST")
  TOTAL_INPUT=$(echo "$TOTAL_INPUT + $INPUT" | bc 2>/dev/null || echo "$TOTAL_INPUT")
  TOTAL_OUTPUT=$(echo "$TOTAL_OUTPUT + $OUTPUT" | bc 2>/dev/null || echo "$TOTAL_OUTPUT")

  if [ "$EXIT_CODE" = "0" ]; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  # Track top spender
  IS_HIGHER=$(echo "$COST > $TOP_COST" | bc 2>/dev/null || echo "0")
  if [ "$IS_HIGHER" = "1" ]; then
    TOP_COST=$COST
    TOP_TASK="$AGENT"
  fi
done

TOTAL_RUNS=$((SUCCESS_COUNT + FAIL_COUNT))

# Build message
MSG="📊 *Daily Digest — $(date +%b\\ %d)*

🚀 Runs: $TOTAL_RUNS total ($SUCCESS_COUNT ✅, $FAIL_COUNT ❌)
💰 Cost: \$$(printf '%.2f' $TOTAL_COST) USD
📈 Tokens: $(printf '%.0f' $TOTAL_INPUT) in / $(printf '%.0f' $TOTAL_OUTPUT) out"

if [ "$TOTAL_RUNS" -gt 0 ] && [ "$TOP_COST" != "0" ]; then
  MSG="$MSG
🔥 Top spender: $TOP_TASK (\$$(printf '%.2f' $TOP_COST))"
fi

# Budget check
BUDGET="${PI_DAILY_BUDGET:-5.00}"
OVER_BUDGET=$(echo "$TOTAL_COST > $BUDGET" | bc 2>/dev/null || echo "0")
if [ "$OVER_BUDGET" = "1" ]; then
  MSG="$MSG

⚠️ *Budget alert:* \$$(printf '%.2f' $TOTAL_COST) exceeds daily budget of \$$BUDGET"
fi

# Send to Telegram
curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d chat_id="$TG_CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$MSG" > /dev/null 2>&1

echo "Digest sent: $TOTAL_RUNS runs, \$$TOTAL_COST"
