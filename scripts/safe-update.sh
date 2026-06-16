#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# safe-update.sh — Snapshot → update → verify → auto-rollback
# ──────────────────────────────────────────────────────────────────────────────
# Wraps any update command with a safety net:
#   1. Snapshots current state (git sha, changed files, systemd services)
#   2. Runs the update command (default: git pull)
#   3. Verifies pi_launchpad still works
#   4. If broken → rolls back to snapshot automatically
#
# Usage:
#   ./scripts/safe-update.sh                        # git pull + verify
#   ./scripts/safe-update.sh "bun install"          # custom update command
#   ./scripts/safe-update.sh --rollback             # rollback last update
#   ./scripts/safe-update.sh --status               # show last snapshot info
#
# Works on both Mac (local) and VPS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SNAPSHOT_DIR="$REPO_ROOT/.pi/snapshots"
mkdir -p "$SNAPSHOT_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0;0m'

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_status() {
  local latest=$(ls -t "$SNAPSHOT_DIR"/*.json 2>/dev/null | head -1)
  if [ -z "$latest" ]; then
    echo -e "${YELLOW}No snapshots found.${NC}"
    return
  fi
  echo -e "${CYAN}Latest snapshot: $(basename $latest)${NC}"
  cat "$latest"
}

cmd_rollback() {
  local latest=$(ls -t "$SNAPSHOT_DIR"/*.json 2>/dev/null | head -1)
  if [ -z "$latest" ]; then
    echo -e "${RED}No snapshot to rollback to.${NC}"
    exit 1
  fi

  local sha=$(grep '"git_sha"' "$latest" | head -1 | sed 's/.*: "//;s/".*//')
  local ts=$(grep '"timestamp"' "$latest" | head -1 | sed 's/.*: "//;s/".*//')

  echo -e "${YELLOW}Rolling back to $sha (from $ts)${NC}"

  # Reset git
  git reset --hard "$sha" 2>/dev/null || {
    echo -e "${RED}Git reset failed. Manual recovery:${NC}"
    echo "  git reset --hard $sha"
    exit 1
  }

  # Restore changed files from snapshot
  local changes_tar="$SNAPSHOT_DIR/$(basename $latest .json)-files.tar.gz"
  if [ -f "$changes_tar" ]; then
    tar xzf "$changes_tar" -C "$REPO_ROOT" 2>/dev/null || true
    echo -e "${GREEN}  Restored uncommitted changes${NC}"
  fi

  # Restore systemd services on VPS
  if [ -d "$SNAPSHOT_DIR/$(basename $latest .json)-services" ]; then
    local svc_dir="$SNAPSHOT_DIR/$(basename $latest .json)-services"
    for svc in "$svc_dir"/*.service; do
      [ -f "$svc" ] && cp "$svc" /etc/systemd/system/ 2>/dev/null && echo -e "${GREEN}  Restored $(basename $svc)${NC}"
    done
    systemctl daemon-reload 2>/dev/null || true
  fi

  echo -e "${GREEN}Rollback complete.${NC}"
  echo -e "${DIM}Run: ./scripts/safe-update.sh --status${NC}"
}

# ── Snapshot ──────────────────────────────────────────────────────────────────

take_snapshot() {
  local ts=$(date +%Y%m%d-%H%M%S)
  local sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  local branch=$(git branch --show-current 2>/dev/null || echo "unknown")
  local snap_file="$SNAPSHOT_DIR/snap-$ts.json"
  local snap_label="snap-$ts"

  echo -e "${CYAN}━━━ SNAPSHOT ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  SHA:     $sha"
  echo -e "  Branch:  $branch"
  echo -e "  Time:    $ts"

  # Record metadata
  cat > "$snap_file" << EOF
{
  "timestamp": "$ts",
  "git_sha": "$sha",
  "branch": "$branch",
  "hostname": "$(hostname)",
  "command": "${1:-git pull}",
  "files_changed": $(git diff --name-only 2>/dev/null | wc -l | tr -d ' '),
  "uncommitted": $(git diff --stat 2>/dev/null | tail -1 | grep -o '[0-9]*' | head -1 || echo 0)
}
EOF

  # Snapshot uncommitted changes
  local changed_files=$(git diff --name-only 2>/dev/null)
  local staged_files=$(git diff --cached --name-only 2>/dev/null)
  local untracked=$(git ls-files --others --exclude-standard 2>/dev/null)

  local all_files="$changed_files"$'\n'"$staged_files"$'\n'"$untracked"
  local file_count=$(echo "$all_files" | grep -c '.' 2>/dev/null || echo 0)

  if [ "$file_count" -gt 0 ]; then
    echo "$all_files" | grep '.' | tar czf "$SNAPSHOT_DIR/$snap_label-files.tar.gz" -T - -C "$REPO_ROOT" 2>/dev/null || true
    echo -e "  Files:   $file_count saved"
  else
    echo -e "  Files:   clean (nothing to snapshot)"
  fi

  # Snapshot systemd services (VPS only)
  if [ -d /etc/systemd/system ]; then
    local svc_dir="$SNAPSHOT_DIR/$snap_label-services"
    mkdir -p "$svc_dir"
    for svc in coms-net-server hermes-coms-bridge coms-heartbeat hermes-gateway; do
      [ -f "/etc/systemd/system/${svc}.service" ] && cp "/etc/systemd/system/${svc}.service" "$svc_dir/"
    done
  fi

  # Keep only last 10 snapshots
  ls -t "$SNAPSHOT_DIR"/snap-*.json 2>/dev/null | tail -n +11 | while read f; do
    label=$(basename "$f" .json)
    rm -f "$f" "$SNAPSHOT_DIR/${label}-files.tar.gz" 2>/dev/null
    rm -rf "$SNAPSHOT_DIR/${label}-services" 2>/dev/null
  done

  echo -e "${GREEN}  ✓ Snapshot saved${NC}"
  echo ""
}

# ── Verify ────────────────────────────────────────────────────────────────────

verify() {
  echo -e "${CYAN}━━━ VERIFY ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  local pass=0
  local fail=0

  # Check 1: Git is clean
  echo -ne "  git status... "
  if git status --porcelain 2>/dev/null | head -1 > /dev/null 2>&1; then
    echo -e "${YELLOW}dirty (ok after update)${NC}"
  else
    echo -e "${GREEN}clean${NC}"
  fi

  # Check 2: Config loads
  echo -ne "  config.sh... "
  if source "$REPO_ROOT/.pi/config.sh" 2>/dev/null; then
    echo -e "${GREEN}ok${NC}"
    pass=$((pass + 1))
  else
    echo -e "${RED}FAIL${NC}"
    fail=$((fail + 1))
  fi

  # Check 3: Agent files exist
  echo -ne "  agents (min 50)... "
  local agent_count=$(ls "$REPO_ROOT/.pi/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
  if [ "$agent_count" -ge 50 ]; then
    echo -e "${GREEN}$agent_count${NC}"
    pass=$((pass + 1))
  else
    echo -e "${RED}only $agent_count${NC}"
    fail=$((fail + 1))
  fi

  # Check 4: Scripts exist
  echo -ne "  scripts (min 40)... "
  local script_count=$(ls "$REPO_ROOT/scripts/"*.sh "$REPO_ROOT/scripts/"*.ts 2>/dev/null | wc -l | tr -d ' ')
  if [ "$script_count" -ge 40 ]; then
    echo -e "${GREEN}$script_count${NC}"
    pass=$((pass + 1))
  else
    echo -e "${RED}only $script_count${NC}"
    fail=$((fail + 1))
  fi

  # Check 5: Coms hub reachable (VPS only, if running)
  echo -ne "  coms hub... "
  if command -v systemctl > /dev/null 2>&1 && systemctl is-active coms-net-server > /dev/null 2>&1; then
    if curl -sS "http://localhost:8090/health" --max-time 3 2>/dev/null | grep -q '"ok":true'; then
      echo -e "${GREEN}healthy${NC}"
      pass=$((pass + 1))
    else
      echo -e "${RED}unreachable${NC}"
      fail=$((fail + 1))
    fi
  else
    echo -e "${DIM}skipped (not VPS or hub not running)${NC}"
  fi

  # Check 6: Hermes bridge (VPS only)
  echo -ne "  hermes bridge... "
  if command -v systemctl > /dev/null 2>&1 && systemctl is-active hermes-coms-bridge > /dev/null 2>&1; then
    echo -e "${GREEN}running${NC}"
    pass=$((pass + 1))
  else
    echo -e "${DIM}skipped${NC}"
  fi

  echo ""
  if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}━━━ ALL CHECKS PASSED ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    return 0
  else
    echo -e "${RED}━━━ $fail CHECKS FAILED ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    return 1
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

case "${1:-update}" in
  --status)
    cmd_status
    ;;
  --rollback)
    cmd_rollback
    ;;
  *)
    UPDATE_CMD="${1:-git pull}"

    # 1. Snapshot
    take_snapshot "$UPDATE_CMD"

    # 2. Update
    echo -e "${CYAN}━━━ UPDATE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Running: $UPDATE_CMD"
    echo ""

    if ! eval "$UPDATE_CMD" 2>&1; then
      echo ""
      echo -e "${RED}Update command failed.${NC}"
      echo -e "${YELLOW}Rolling back...${NC}"
      cmd_rollback
      exit 1
    fi
    echo ""

    # 3. Verify
    if ! verify; then
      echo ""
      echo -e "${RED}Verification failed after update.${NC}"
      echo -e "${YELLOW}Rolling back automatically...${NC}"
      cmd_rollback
      echo ""
      echo -e "${YELLOW}Re-running verify after rollback...${NC}"
      verify || true
      exit 1
    fi

    echo ""
    echo -e "${GREEN}Update successful. Snapshot preserved for rollback.${NC}"
    echo -e "${DIM}Rollback: ./scripts/safe-update.sh --rollback${NC}"
    ;;
esac
