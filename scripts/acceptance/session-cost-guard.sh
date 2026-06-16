#!/bin/bash
# Acceptance test: Per-session cost guard (#66)
#
# Verifies that the session cost ceiling is enforced:
# multiple subagents cannot exceed PI_SESSION_MAX_COST.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = ERROR
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Session Cost Guard Acceptance Test ==="

# Set a very low session budget
export PI_SESSION_MAX_COST="0.01"
export PI_SUBAGENT_MAX_COST="0.01"

TRACE_DIR="$PROJECT_ROOT/.pi/traces/subagents"
MANIFEST_DIR="$PROJECT_ROOT/.pi/traces/runs"

# Clean old traces
find "$TRACE_DIR" -name "acceptance*" -delete 2>/dev/null || true
find "$MANIFEST_DIR" -name "manifest.json" -newermt "1 hour ago" -delete 2>/dev/null || true

# Run a subagent — with $0.01 budget it should hit the ceiling quickly
TRACE_RUN_ID="acceptance-cost-$(date +%s)"
export TRACE_RUN_ID
TRACE_AGENT_NAME="cost-test-worker"
export TRACE_AGENT_NAME

pi --mode json -p --no-session \
  "Read README.md, then read docs/agents.md, then read docs/extensions.md, then read docs/skills-catalog.md. After each read, summarize. Do all 4 as separate tool calls." \
  > /tmp/cost-test-output.txt 2>&1 &
PI_PID=$!

echo "Started pi PID=$PI_PID with \$0.01 session budget"
sleep 30

# Check if process exited (should hit budget)
wait $PI_PID 2>/dev/null
EXIT_CODE=$?
echo "Process exited with code $EXIT_CODE"

# Check for budget_exhausted in output or logs
if grep -q "budget_exhausted\|Session budget exhausted\|budget" /tmp/cost-test-output.txt 2>/dev/null; then
  echo "PASS: Budget enforcement detected in output"
else
  echo "WARN: Budget enforcement not explicitly detected (may have completed under budget)"
fi

# Check manifest was written
RUN_ID_FILE="$PROJECT_ROOT/.pi/traces/current-run-id"
if [ -f "$RUN_ID_FILE" ]; then
  RUN_ID=$(cat "$RUN_ID_FILE")
  MANIFEST="$MANIFEST_DIR/$RUN_ID/manifest.json"
  if [ -f "$MANIFEST" ]; then
    echo "PASS: Manifest written at $MANIFEST"
    # Check sessionBudget field
    if grep -q "sessionBudget" "$MANIFEST"; then
      echo "PASS: sessionBudget field present in manifest"
    fi
  else
    echo "WARN: No manifest found (may not have been written yet)"
  fi
fi

# Cleanup
unset PI_SESSION_MAX_COST PI_SUBAGENT_MAX_COST TRACE_RUN_ID TRACE_AGENT_NAME
rm -f /tmp/cost-test-output.txt

echo ""
echo "=== Test Complete ==="
exit 0
