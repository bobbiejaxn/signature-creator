#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Apply a harness evolution proposal
# ──────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/apply-proposal.sh <number>          # Apply a specific proposal
#   ./scripts/apply-proposal.sh --all-pending     # Apply all PENDING/PROPOSED
#   ./scripts/apply-proposal.sh --status          # Show status of all proposals
#   ./scripts/apply-proposal.sh --mark-applied <N># Mark as applied
#   ./scripts/apply-proposal.sh --reject <N>      # Mark as rejected

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROPOSALS_DIR="$PROJECT_ROOT/.pi/traces/analysis/proposals"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

status_report() {
  echo -e "${BLUE}=== Harness Proposal Status ===${NC}"
  echo ""

  local applied=0 pending=0 proposed=0 deferred=0 superseded=0 unknown=0 total=0

  for f in "$PROPOSALS_DIR"/proposal-*.md; do
    [ -f "$f" ] || continue
    total=$((total + 1))
    local name
    name=$(basename "$f")
    local title
    title=$(grep "^# " "$f" 2>/dev/null | head -1 | sed 's/# //')
    local status
    status=$(grep -i "status" "$f" 2>/dev/null | grep -oi "applied\|pending\|proposed\|deferred\|rejected\|superseded" | head -1) || true

    case "$status" in
      Applied|APPLIED|applied)     echo -e "  ${GREEN}✅ $name${NC} | $title"; applied=$((applied + 1)) ;;
      Pending|PENDING|pending)     echo -e "  ${YELLOW}⏳ $name${NC} | $title"; pending=$((pending + 1)) ;;
      Proposed|PROPOSED|proposed)  echo -e "  ${YELLOW}📋 $name${NC} | $title"; proposed=$((proposed + 1)) ;;
      Deferred|DEFERRED|deferred)  echo -e "  ${BLUE}⏸️  $name${NC} | $title"; deferred=$((deferred + 1)) ;;
      Superseded|superseded)       echo -e "  🔀 $name | $title"; superseded=$((superseded + 1)) ;;
      Rejected|rejected)           echo -e "  ${RED}❌ $name${NC} | $title"; unknown=$((unknown + 1)) ;;
      *)                           echo -e "  ❓ $name | $title"; unknown=$((unknown + 1)) ;;
    esac
  done

  echo ""
  echo "Total: $total | ✅ $applied | ⏳ $pending | 📋 $proposed | ⏸️ $deferred | 🔀 $superseded | ❓ $unknown"
}

mark_status() {
  local num="$1"
  local new_status="$2"

  local file
  file=$(ls "$PROPOSALS_DIR"/proposal-${num}*.md 2>/dev/null | head -1)
  if [ -z "$file" ]; then
    echo "Proposal $num not found."
    exit 1
  fi

  local name
  name=$(basename "$file")

  if grep -qi "^\*\*Status\*\*" "$file"; then
    sed -i '' -E "s/\*\*Status\*\*:.*$/\*\*Status\*\*: $new_status/" "$file"
  elif grep -qi "^Status:" "$file"; then
    sed -i '' -E "s/^Status:.*$/Status: $new_status/" "$file"
  else
    sed -i '' "/^# /a\\
\\
**Status**: $new_status" "$file"
  fi

  echo -e "${GREEN}✅ Marked $name as $new_status${NC}"
}

apply_single() {
  local num="$1"

  local file
  file=$(ls "$PROPOSALS_DIR"/proposal-${num}*.md 2>/dev/null | head -1)
  if [ -z "$file" ]; then
    echo "Proposal $num not found."
    exit 1
  fi

  local name
  name=$(basename "$file")

  echo -e "${BLUE}=== Applying $name ===${NC}"
  echo ""

  # Snapshot before applying
  "$SCRIPT_DIR/harness-version.sh" snapshot 2>/dev/null || true

  echo "Reading proposal..."
  cat "$file"
  echo ""
  echo "─────────────────────────────────────────"
  echo ""

  if command -v pi &>/dev/null; then
    echo -e "${YELLOW}Applying via harness-evolver agent...${NC}"

    TASK="Read the proposal at $file and apply its recommended changes to the actual harness files. The proposal tells you exactly which files to modify and what changes to make. Apply ONLY the changes described in the proposal. After applying: verify changes compile, update the Status line in $file to Applied, and report what you changed. If already applied, just update the status."

    pi --agent harness-evolver --no-interactive "$TASK"

    echo ""
    echo -e "${GREEN}Done. Check $file for updated status.${NC}"
  else
    echo -e "${YELLOW}pi CLI not found. Apply manually based on the proposal above.${NC}"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --status)
    status_report
    ;;
  --mark-applied)
    [ -z "${2:-}" ] && { echo "Usage: $0 --mark-applied <number>"; exit 1; }
    mark_status "$2" "Applied"
    ;;
  --reject)
    [ -z "${2:-}" ] && { echo "Usage: $0 --reject <number>"; exit 1; }
    mark_status "$2" "Rejected"
    ;;
  --all-pending)
    echo -e "${BLUE}=== Applying all pending/proposed proposals ===${NC}"
    for f in "$PROPOSALS_DIR"/proposal-*.md; do
      [ -f "$f" ] || continue
      local_status=$(grep -i "status" "$f" 2>/dev/null | grep -oi "pending\|proposed" | head -1)
      if [ -n "$local_status" ]; then
        num=$(basename "$f" | grep -oE '[0-9]+' | head -1)
        echo ""
        echo -e "${YELLOW}Found pending: $(basename "$f")${NC}"
        apply_single "$num"
      fi
    done
    ;;
  --help|-h)
    echo "Usage:"
    echo "  $0 <number>           Apply a specific proposal"
    echo "  $0 --all-pending      Apply all PENDING/PROPOSED proposals"
    echo "  $0 --status           Show status of all proposals"
    echo "  $0 --mark-applied <N> Mark proposal N as applied"
    echo "  $0 --reject <N>       Mark proposal N as rejected"
    ;;
  *)
    [ -z "${1:-}" ] && { echo "Usage: $0 <proposal-number|--status|--all-pending>"; exit 1; }
    apply_single "$1"
    ;;
esac
