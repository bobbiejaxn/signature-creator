#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# capture-dev-logs.sh — Start dev server, capture output, detect real errors
# ──────────────────────────────────────────────────────────────────────────────
# Reads DEV_COMMAND, DEV_PORT, DEV_DIR from .pi/config.sh
#
# Usage:
#   ./scripts/capture-dev-logs.sh              # 20s capture
#   ./scripts/capture-dev-logs.sh 30           # 30s capture
#
# Exit codes:
#   0 = no real errors found
#   1 = real errors found
#   2 = dev server failed to start

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/.pi/config.sh"

CAPTURE_SECONDS="${1:-20}"
LOG_FILE="/tmp/${PROJECT_NAME}-dev-capture-$$.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

DEV_PID=""

cleanup() {
  if [ -n "$DEV_PID" ]; then
    kill "$DEV_PID" 2>/dev/null || true
    lsof -ti:"$DEV_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
  fi
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

echo "Starting dev server on port $DEV_PORT..."
echo "Capturing logs for ${CAPTURE_SECONDS}s..."
echo ""

# Start the dev server
cd "$REPO_ROOT/$DEV_DIR"
eval "$DEV_COMMAND -- --port $DEV_PORT" > "$LOG_FILE" 2>&1 &
DEV_PID=$!

# Wait for server ready (up to 30s)
READY=false
for i in $(seq 1 30); do
  sleep 1
  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$DEV_PORT" 2>/dev/null | grep -q "200\|301\|302\|304"; then
    READY=true
    break
  fi
  if ! kill -0 "$DEV_PID" 2>/dev/null; then
    echo -e "${RED}Dev server process died during startup${NC}"
    cat "$LOG_FILE"
    exit 2
  fi
done

if [ "$READY" = false ]; then
  echo -e "${RED}Dev server did not become ready within 30s${NC}"
  cat "$LOG_FILE"
  exit 2
fi

echo "Dev server ready. Capturing for ${CAPTURE_SECONDS}s..."
sleep "$CAPTURE_SECONDS"

# ─── Analyze logs ────────────────────────────────────────────────────────────

# Build ignore pattern from config
IGNORE_GREP=""
for pattern in "${LOG_NOISE_PATTERNS[@]}"; do
  IGNORE_GREP="$IGNORE_GREP -e $(printf '%q' "$pattern")"
done

# Build error pattern from config
ERROR_GREP=""
for pattern in "${LOG_ERROR_PATTERNS[@]}"; do
  ERROR_GREP="$ERROR_GREP -e $(printf '%q' "$pattern")"
done

REAL_ERRORS=""
if [ -n "$IGNORE_GREP" ] && [ -n "$ERROR_GREP" ]; then
  REAL_ERRORS=$(grep -v $IGNORE_GREP "$LOG_FILE" 2>/dev/null | grep -i $ERROR_GREP 2>/dev/null || true)
elif [ -n "$ERROR_GREP" ]; then
  REAL_ERRORS=$(grep -i $ERROR_GREP "$LOG_FILE" 2>/dev/null || true)
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "LOG CAPTURE RESULTS"
echo "═══════════════════════════════════════════════════════"
echo "Capture duration: ${CAPTURE_SECONDS}s"
echo "Port: $DEV_PORT"
echo ""

if [ -z "$REAL_ERRORS" ]; then
  echo -e "${GREEN}✓ No real errors detected in dev server logs${NC}"
  echo ""
  echo "LOG VERDICT: CLEAN"
  exit 0
else
  echo -e "${RED}✗ Real errors found in dev server logs:${NC}"
  echo ""
  echo "$REAL_ERRORS"
  echo ""
  echo "Full log excerpt (last 50 lines):"
  tail -50 "$LOG_FILE"
  echo ""
  echo "LOG VERDICT: ERRORS FOUND — fix these before claiming success"
  exit 1
fi
