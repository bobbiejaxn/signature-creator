#!/usr/bin/env bash
# install-cron-linux.sh -- installs crontab entries for auto-ship on Linux VPS
# Usage: ./scripts/install-cron-linux.sh
# Designed for the Hostinger VPS (Ubuntu) where pi_launchpad lives at /root/pi_launchpad/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load project config
CONFIG_FILE="$PROJECT_DIR/.pi/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: No .pi/config.sh found. Run setup first."
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

log() { echo "[install-cron-linux] $*"; }

# Make scripts executable
chmod +x "$SCRIPT_DIR/cron-spec-writer.sh"
chmod +x "$SCRIPT_DIR/cron-auto-ship.sh"
chmod +x "$SCRIPT_DIR/autoship.sh"
chmod +x "$SCRIPT_DIR/security-gate.sh"

mkdir -p "$PROJECT_DIR/logs/cron"

# Resolve binary paths (crontab has minimal PATH)
PI_BIN="$(command -v pi || echo "/root/.local/bin/pi")"
GH_BIN="$(command -v gh || echo "/usr/local/bin/gh")"
BASH_BIN="$(command -v bash || echo "/bin/bash")"
NODE_BIN="$(command -v node || echo "/usr/local/bin/node")"

# Build PATH for crontab
CRON_PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin"

# -- Remove old entries if they exist ──────────────────────────────────────────
MARKER="# pi_launchpad autoship-${PROJECT_NAME}"
(crontab -l 2>/dev/null | grep -v "cron-spec-writer.sh" | grep -v "cron-auto-ship.sh" || true) | crontab -

# -- Add new entries ──────────────────────────────────────────────────────────
# Spec writer: 9 PM daily (UTC — adjust for VPS timezone)
# Auto-ship: 10 PM daily (UTC — adjust for VPS timezone)

(crontab -l 2>/dev/null || true; cat << EOF

${MARKER}
PATH=${CRON_PATH}
# Spec writer — 9 PM daily
0 21 * * * ${BASH_BIN} ${SCRIPT_DIR}/cron-spec-writer.sh >> ${PROJECT_DIR}/logs/cron/spec-writer-cron.log 2>&1
# Auto-ship — 10 PM daily
0 22 * * * ${BASH_BIN} ${SCRIPT_DIR}/cron-auto-ship.sh >> ${PROJECT_DIR}/logs/cron/auto-ship-cron.log 2>&1
${MARKER} END
EOF
) | crontab -

log ""
log "Installed crontab entries:"
log "  Spec writer:  21:00 daily → cron-spec-writer.sh"
log "  Auto-ship:    22:00 daily → cron-auto-ship.sh"
log ""
log "Logs: $PROJECT_DIR/logs/cron/"
log ""
log "Workflow:"
log "  1. Add 'backlog' label to issues you want specced"
log "  2. 9 PM  -> spec-writer runs pi, posts spec to GitHub, labels 'spec-ready'"
log "  3. You   -> review spec, add 'spec-approved' (or 'spec-hold' to pause)"
log "  4. 10 PM -> auto-ship picks up 'spec-approved', runs full ship workflow"
log "  5. Wake up to open PRs"
log ""
log "To uninstall: ./scripts/uninstall-cron-linux.sh"
log "To run now:   ./scripts/cron-spec-writer.sh  (or cron-auto-ship.sh)"
log "To run loop:  ./scripts/autoship.sh"
log ""
log "Current crontab:"
crontab -l
