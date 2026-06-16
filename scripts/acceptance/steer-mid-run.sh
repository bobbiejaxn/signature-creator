#!/bin/bash
# Acceptance test: Steer mid-run course correction (#58)
#
# Starts a subagent, sends a steer message, verifies the agent
# received it and adjusted its behavior.
#
# Exit codes:
#   0 = PASS (steer consumed + agent acknowledged)
#   1 = FAIL (steer not consumed or agent didn't adjust)
#   2 = ERROR (setup failure)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_ID="acceptance-steer-$(date +%s)"
AGENT_NAME="acceptance-worker"
STEER_DIR="$HOME/.pi/steer/$RUN_ID"
OUTPUT_FILE="/tmp/steer-acceptance-output.txt"

echo "=== Steer Mid-Run Acceptance Test ==="
echo "Run ID: $RUN_ID"

# Cleanup from previous runs
mkdir -p "$STEER_DIR"

# Start a subagent that will make multiple tool calls
export TRACE_RUN_ID="$RUN_ID"
export TRACE_AGENT_NAME="$AGENT_NAME"

pi --mode json -p --no-session \
  -e "$PROJECT_ROOT/.pi/extensions/steer/index.ts" \
  "Read the files README.md, docs/agents.md, and docs/extensions.md one at a time. After each read, output a summary line. At the end, output DONE or STEERED depending on whether you received any mid-run instructions." \
  > "$OUTPUT_FILE" 2>&1 &
PI_PID=$!

echo "Started pi PID=$PI_PID"

# Wait for first tool call to fire
sleep 8

# Write steer file
echo "STEERED! Include the word STEERED in your final output." > "$STEER_DIR/$AGENT_NAME.md"
echo "Steer file written at $(date -u +%H:%M:%S)"

# Wait for process to complete
wait $PI_PID 2>/dev/null || true
EXIT_CODE=$?
echo "Process exited (code=$EXIT_CODE) at $(date -u +%H:%M:%S)"

# Check results
echo ""
echo "=== Checking Results ==="
FAILURES=0

if [ ! -f "$OUTPUT_FILE" ]; then
  echo "FAIL: No output file"
  exit 2
fi

# The steer file should have been consumed
if [ -f "$STEER_DIR/$AGENT_NAME.md" ]; then
  echo "FAIL: Steer file was NOT consumed (still exists)"
  cat "$STEER_DIR/$AGENT_NAME.md"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: Steer file was consumed"
fi

# Check output for STEERED keyword
if grep -q "STEERED" "$OUTPUT_FILE"; then
  echo "PASS: Agent acknowledged steer in output"
else
  echo "FAIL: 'STEERED' not found in output — agent did not comply with steer"
  FAILURES=$((FAILURES + 1))
fi

# Cleanup
rm -rf "$STEER_DIR" "$OUTPUT_FILE" 2>/dev/null || true

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "=== ALL CHECKS PASSED ==="
  exit 0
else
  echo "=== $FAILURES FAILURES ==="
  exit 1
fi
