#!/usr/bin/env bash
# install-cron.sh -- installs macOS launchd agents for the auto-ship cron
# Run once: ./scripts/install-cron.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

# Load project config
CONFIG_FILE="$PROJECT_DIR/.pi/config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: No .pi/config.sh found. Run setup first."
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Sanitize project name for launchd label
LABEL_PREFIX="com.$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g;s/--*/-/g;s/^-//;s/-$//')"

log() { echo "[install-cron] $*"; }

# Resolve paths for launchd (it doesn't inherit shell PATH)
NODE_DIR="$(dirname "$(command -v node)")"
PI_DIR="$(dirname "$(command -v pi)" 2>/dev/null || echo "$NODE_DIR")"
GH_DIR="$(dirname "$(command -v gh)" 2>/dev/null || echo "/opt/homebrew/bin")"
BREW_DIR="$(dirname "$(command -v brew)" 2>/dev/null || echo "/opt/homebrew/bin")"

LAUNCHD_PATH="$PI_DIR:$GH_DIR:$BREW_DIR:$NODE_DIR:/usr/local/bin:/usr/bin:/bin"

# Make scripts executable
chmod +x "$SCRIPT_DIR/cron-spec-writer.sh"
chmod +x "$SCRIPT_DIR/cron-auto-ship.sh"
chmod +x "$SCRIPT_DIR/autoship.sh"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$PROJECT_DIR/logs/cron"

# -- Spec Writer plist (runs at 9:00 PM nightly) ───────────────────────────────
SPEC_LABEL="${LABEL_PREFIX}.cron-spec-writer"
cat > "$LAUNCH_AGENTS_DIR/${SPEC_LABEL}.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SPEC_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/cron-spec-writer.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>21</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${LAUNCHD_PATH}</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$PROJECT_DIR/logs/cron/spec-writer-launchd.log</string>

    <key>StandardErrorPath</key>
    <string>$PROJECT_DIR/logs/cron/spec-writer-launchd-err.log</string>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

# -- Auto-Ship plist (runs at 10:00 PM nightly) ────────────────────────────────
SHIP_LABEL="${LABEL_PREFIX}.cron-auto-ship"
cat > "$LAUNCH_AGENTS_DIR/${SHIP_LABEL}.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SHIP_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/cron-auto-ship.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$PROJECT_DIR</string>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>22</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${LAUNCHD_PATH}</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>

    <key>StandardOutPath</key>
    <string>$PROJECT_DIR/logs/cron/auto-ship-launchd.log</string>

    <key>StandardErrorPath</key>
    <string>$PROJECT_DIR/logs/cron/auto-ship-launchd-err.log</string>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
EOF

# -- Load agents ────────────────────────────────────────────────────────────────
launchctl load "$LAUNCH_AGENTS_DIR/${SPEC_LABEL}.plist"
launchctl load "$LAUNCH_AGENTS_DIR/${SHIP_LABEL}.plist"

log ""
log "Installed and loaded:"
log "  ${SPEC_LABEL}  -- runs daily at 9:00 PM"
log "  ${SHIP_LABEL}    -- runs daily at 10:00 PM"
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
log "To uninstall: ./scripts/uninstall-cron.sh"
log "To run now:   ./scripts/cron-spec-writer.sh  (or cron-auto-ship.sh)"
log "To run loop:  ./scripts/autoship.sh"
