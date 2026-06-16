#!/bin/bash
# pi-steer — Send a mid-run course correction to a running agent
# Usage: pi-steer <agent-name> "<message>"
#
# Issue: #58
set -e

if [ $# -lt 2 ]; then
  echo "Usage: pi-steer <agent-name> \"<message>\""
  echo "  Sends a course correction to a running subagent."
  echo "  The message is injected at the agent's next tool_result or turn_start."
  exit 1
fi

AGENT="$1"
MESSAGE="$2"

# Discover run ID
RUN_ID="${TRACE_RUN_ID:-}"
if [ -z "$RUN_ID" ] && [ -f ".pi/traces/current-run-id" ]; then
  RUN_ID="$(cat .pi/traces/current-run-id)"
fi

if [ -z "$RUN_ID" ]; then
  echo "Error: Cannot determine run ID. Set TRACE_RUN_ID or run from a project with active traces."
  exit 1
fi

STEER_DIR="$HOME/.pi/steer/$RUN_ID"
STEER_FILE="$STEER_DIR/${AGENT}.md"

# Check if agent appears to be running
TRACE_DIR=".pi/traces/subagents"
AGENT_RUNNING=false
if [ -d "$TRACE_DIR" ]; then
  # Find recent trace files for this agent (within last 15 minutes)
  RECENT=$(find "$TRACE_DIR" -name "*${AGENT}*.json" -mmin -15 2>/dev/null | head -1)
  if [ -n "$RECENT" ]; then
    AGENT_RUNNING=true
  fi
fi

if [ "$AGENT_RUNNING" = false ]; then
  echo "Warning: Agent '$AGENT' does not appear to be running (no recent trace). Delivering anyway."
fi

# Atomic write
mkdir -p "$STEER_DIR"
TMP_FILE="${STEER_FILE}..tmp"
echo "$MESSAGE" > "$TMP_FILE"
mv "$TMP_FILE" "$STEER_FILE"
chmod 600 "$STEER_FILE"

echo "Steer delivered to '$AGENT' (run: $RUN_ID)"
echo "Message will be injected at next tool_result, then consumed."
