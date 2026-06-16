#!/usr/bin/env bash
# dynamic-cron-manager.sh
# Manages cron entries dynamically based on CEO OKRs and priorities.
# The dynamic-ceo calls this script to create, update, and remove cron jobs
# as priorities change.
#
# Commands:
#   list                          — show all pi_launchpad managed crons
#   add <name> <schedule> <cmd>   — add/update a cron entry
#   remove <name>                 — remove a cron entry by name
#   sync <okrs-file>              — sync crons from CEO_OKRs.json
#   clear                         — remove ALL managed crons

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MARKER="# pi_launchpad dynamic-cron"
LOG_DIR="$PROJECT_DIR/logs/cron"
mkdir -p "$LOG_DIR"

# Detect OS
IS_MACOS="$(uname -s | grep -q Darwin && echo true || echo false)"
IS_LINUX="$(uname -s | grep -q Linux && echo true || echo false)"

# Resolve binary paths
PI_BIN="${PI_BIN:-$(command -v pi || echo "pi")}"
BASH_BIN="$(command -v bash || echo "/bin/bash")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [dynamic-cron] $*"; }

# ── Crontab management (Linux) ──────────────────────────────────────────

get_crontab() {
  crontab -l 2>/dev/null || echo ""
}

set_crontab() {
  local content="$1"
  echo "$content" | crontab -
}

# ── Launchd management (macOS) ──────────────────────────────────────────

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
CONFIG_FILE="$PROJECT_DIR/.pi/config.sh"

get_label_prefix() {
  local project_name="launchpad"
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    project_name="${PROJECT_NAME:-launchpad}"
  fi
  echo "com.$(echo "$project_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g;s/--*/-/g;s/^-//;s/-$//')"
}

# ── Commands ─────────────────────────────────────────────────────────────

cmd_list() {
  log "Managed cron entries:"
  if [ "$IS_LINUX" = "true" ]; then
    local tab
    tab="$(get_crontab)"
    echo "$tab" | grep -A0 "$MARKER" | grep -v "^$" || log "(none)"
  else
    local prefix
    prefix="$(get_label_prefix)"
    ls "$LAUNCH_AGENTS_DIR"/${prefix}.dynamic-*.* 2>/dev/null || log "(none)"
  fi
}

cmd_add() {
  local name="$1"
  local schedule="$2"
  local cmd="$3"

  if [ "$IS_LINUX" = "true" ]; then
    cmd_add_linux "$name" "$schedule" "$cmd"
  else
    cmd_add_macos "$name" "$schedule" "$cmd"
  fi
}

cmd_add_linux() {
  local name="$1"
  local schedule="$2"
  local cmd="$3"
  local entry_name="dynamic-${name}"

  # Remove existing entry with same name
  local tab
  tab="$(get_crontab)"
  tab="$(echo "$tab" | grep -v "$entry_name" || true)"

  # Add new entry
  local marker_start="${MARKER} ${entry_name} START"
  local marker_end="${MARKER} ${entry_name} END"
  local entry="${schedule} ${BASH_BIN} ${cmd} >> ${LOG_DIR}/${name}-$(date +%Y%m%d).log 2>&1"

  set_crontab "$tab

${marker_start}
${entry}
${marker_end}"

  log "Added cron '${name}': ${schedule} → ${cmd}"
}

cmd_add_macos() {
  local name="$1"
  local schedule="$2"
  local cmd="$3"
  local prefix
  prefix="$(get_label_prefix)"
  local plist_name="${prefix}.dynamic-${name}"
  local plist_path="$LAUNCH_AGENTS_DIR/${plist_name}.plist"

  # Parse schedule (minute hour day month weekday)
  local minute hour day month weekday
  read -r minute hour day month weekday <<< "$schedule"

  mkdir -p "$LAUNCH_AGENTS_DIR"

  cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${plist_name}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${cmd}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${PROJECT_DIR}</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key>
        <integer>${minute}</integer>
        <key>Hour</key>
        <integer>${hour}</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/${name}.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/${name}.log</string>
</dict>
</plist>
EOF

  launchctl unload "$plist_path" 2>/dev/null || true
  launchctl load "$plist_path"
  log "Added launchd '${name}': ${schedule} → ${cmd}"
}

cmd_remove() {
  local name="$1"

  if [ "$IS_LINUX" = "true" ]; then
    local entry_name="dynamic-${name}"
    local tab
    tab="$(get_crontab)"
    tab="$(echo "$tab" | grep -v "$entry_name" || true)"
    set_crontab "$tab"
    log "Removed cron '${name}'"
  else
    local prefix
    prefix="$(get_label_prefix)"
    local plist_name="${prefix}.dynamic-${name}"
    local plist_path="$LAUNCH_AGENTS_DIR/${plist_name}.plist"
    launchctl unload "$plist_path" 2>/dev/null || true
    rm -f "$plist_path"
    log "Removed launchd '${name}'"
  fi
}

cmd_sync() {
  local okrs_file="$1"

  if [ ! -f "$okrs_file" ]; then
    log "No OKRs file at ${okrs_file} — nothing to sync"
    return
  fi

  # Parse OKRs for scheduled tasks
  # The dynamic CEO writes tasks with optional "schedule" field:
  # {"id": "T-1", "schedule": "0 22 * * *", "script": "cron-auto-ship.sh", ...}
  log "Syncing crons from ${okrs_file}..."

  # Remove all existing dynamic crons first
  cmd_clear

  # Extract scheduled tasks from OKRs
  # This uses basic text parsing — jq if available, grep otherwise
  local has_jq
  has_jq="$(command -v jq >/dev/null 2>&1 && echo true || echo false)"

  if [ "$has_jq" = "true" ]; then
    local count
    count="$(jq '.delegatedTasks // [] | map(select(.schedule != null)) | length' "$okrs_file" 2>/dev/null || echo 0)"
    local i=0
    while [ "$i" -lt "$count" ]; do
      local task_id schedule script
      task_id="$(jq -r ".delegatedTasks[$i].id" "$okrs_file")"
      schedule="$(jq -r ".delegatedTasks[$i].schedule" "$okrs_file")"
      script="$(jq -r ".delegatedTasks[$i].script" "$okrs_file")"
      if [ "$schedule" != "null" ] && [ "$script" != "null" ]; then
        cmd_add "$task_id" "$schedule" "$SCRIPT_DIR/$script"
      fi
      i=$((i + 1))
    done
    log "Synced ${count} scheduled tasks"
  else
    log "jq not available — skipping sync. Install jq for dynamic cron management."
  fi
}

cmd_clear() {
  log "Clearing all dynamic crons..."

  if [ "$IS_LINUX" = "true" ]; then
    local tab
    tab="$(get_crontab)"
    tab="$(echo "$tab" | grep -v "$MARKER" || true)"
    set_crontab "$tab"
  else
    local prefix
    prefix="$(get_label_prefix)"
    for plist in "$LAUNCH_AGENTS_DIR"/${prefix}.dynamic-*.plist; do
      [ -f "$plist" ] || continue
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
    done
  fi

  log "All dynamic crons cleared"
}

# ── Main ─────────────────────────────────────────────────────────────────

case "${1:-list}" in
  list)   cmd_list ;;
  add)    cmd_add "$2" "$3" "$4" ;;
  remove) cmd_remove "$2" ;;
  sync)   cmd_sync "${2:-$PROJECT_DIR/.pi/ceo-sessions/CEO_OKRs.json}" ;;
  clear)  cmd_clear ;;
  *)
    echo "Usage: $0 {list|add|remove|sync|clear}"
    echo ""
    echo "  list                          Show managed crons"
    echo "  add <name> <schedule> <cmd>   Add cron (schedule: 'min hr day mon wkday')"
    echo "  remove <name>                 Remove cron by name"
    echo "  sync [okrs-file]              Sync crons from CEO_OKRs.json"
    echo "  clear                         Remove ALL dynamic crons"
    exit 1
    ;;
esac
