#!/usr/bin/env bash
# uninstall-cron.sh -- removes macOS launchd agents installed by install-cron.sh
# Usage: ./scripts/uninstall-cron.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

# Load project config
CONFIG_FILE="$PROJECT_DIR/.pi/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: No .pi/config.sh found."
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

LABEL_PREFIX="com.$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g;s/--*/-/g;s/^-//;s/-$//')"

SPEC_LABEL="${LABEL_PREFIX}.cron-spec-writer"
SHIP_LABEL="${LABEL_PREFIX}.cron-auto-ship"

REMOVED=0

# Unload spec-writer
if launchctl list | grep -q "$SPEC_LABEL" 2>/dev/null; then
  launchctl unload "$LAUNCH_AGENTS_DIR/${SPEC_LABEL}.plist" 2>/dev/null || true
  echo "  Unloaded: $SPEC_LABEL"
  REMOVED=$((REMOVED + 1))
fi

# Unload auto-ship
if launchctl list | grep -q "$SHIP_LABEL" 2>/dev/null; then
  launchctl unload "$LAUNCH_AGENTS_DIR/${SHIP_LABEL}.plist" 2>/dev/null || true
  echo "  Unloaded: $SHIP_LABEL"
  REMOVED=$((REMOVED + 1))
fi

# Remove plist files
if [ -f "$LAUNCH_AGENTS_DIR/${SPEC_LABEL}.plist" ]; then
  rm "$LAUNCH_AGENTS_DIR/${SPEC_LABEL}.plist"
  echo "  Removed: ${SPEC_LABEL}.plist"
fi

if [ -f "$LAUNCH_AGENTS_DIR/${SHIP_LABEL}.plist" ]; then
  rm "$LAUNCH_AGENTS_DIR/${SHIP_LABEL}.plist"
  echo "  Removed: ${SHIP_LABEL}.plist"
fi

# Check for running PID file
PID_FILE="$PROJECT_DIR/logs/cron/autoship.pid"
if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    echo "  Killed running autoship process: $PID"
  fi
  rm -f "$PID_FILE"
fi

echo ""
if [ $REMOVED -gt 0 ]; then
  echo "  ✅ Uninstalled $REMOVED cron job(s). Logs preserved at: logs/cron/"
else
  echo "  ℹ️  No cron jobs were running."
fi
