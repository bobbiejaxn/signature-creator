#!/usr/bin/env bash
# uninstall-cron-linux.sh -- removes crontab entries installed by install-cron-linux.sh
# Usage: ./scripts/uninstall-cron-linux.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load project config
CONFIG_FILE="$PROJECT_DIR/.pi/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: No .pi/config.sh found."
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

BEFORE=$(crontab -l 2>/dev/null | wc -l | tr -d ' ')

# Remove our entries
(crontab -l 2>/dev/null | grep -v "cron-spec-writer.sh" | grep -v "cron-auto-ship.sh" | grep -v "pi_launchpad autoship" || true) | crontab -

AFTER=$(crontab -l 2>/dev/null | wc -l | tr -d ' ')

REMOVED=$((BEFORE - AFTER))

echo ""
if [ $REMOVED -gt 0 ]; then
  echo "  ✅ Removed $REMOVED crontab line(s). Logs preserved at: logs/cron/"
else
  echo "  ℹ️  No pi_launchpad cron entries found."
fi
