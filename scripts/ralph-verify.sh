#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Ralph Pre-Completion Verification
# ──────────────────────────────────────────────────────────────────────────────
# Run this before declaring a Ralph loop COMPLETE.
# Checks all VERIFY_COMMANDS from config, plus basic sanity checks.
#
# Usage:
#   ./scripts/ralph-verify.sh                    # Run all checks
#   ./scripts/ralph-verify.sh --task <task.md>   # Also check task file has verification

set -euo pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $name"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $name"
    FAIL=$((FAIL + 1))
  fi
}

warn() {
  local name="$1"
  echo -e "  ${YELLOW}⚠${NC} $name"
  WARN=$((WARN + 1))
}

echo "━━━ Ralph Pre-Completion Verification ━━━"
echo ""

# ── 1. Run VERIFY_COMMANDS from config ──
if [ -f .pi/config.sh ]; then
  source .pi/config.sh
  echo "Static checks (from config):"
  for cmd in "${VERIFY_COMMANDS[@]}"; do
    check "$cmd" bash -c "$cmd"
  done
  echo ""
fi

# ── 2. Check for merge conflicts ──
echo "Sanity checks:"
if grep -rn "<<<<<<< " --include="*.ts" --include="*.tsx" --include="*.js" --include="*.svelte" --include="*.vue" --include="*.py" . 2>/dev/null | grep -v node_modules | grep -v .git; then
  echo -e "  ${RED}✗${NC} No merge conflicts"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}✓${NC} No merge conflicts"
  PASS=$((PASS + 1))
fi

# ── 3. Check task file has verification section ──
TASK_FILE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [ -n "$TASK_FILE" ] && [ -f "$TASK_FILE" ]; then
  echo ""
  echo "Task file verification ($TASK_FILE):"
  
  if grep -q "## Verification" "$TASK_FILE"; then
    echo -e "  ${GREEN}✓${NC} Has ## Verification section"
    PASS=$((PASS + 1))
    
    # Check for actual evidence
    if grep -q "\[x\]" "$TASK_FILE"; then
      CHECKED=$(grep -c "\[x\]" "$TASK_FILE")
      echo -e "  ${GREEN}✓${NC} $CHECKED items verified"
      PASS=$((PASS + 1))
    else
      warn "No [x] checked items in verification section"
    fi
  else
    echo -e "  ${RED}✗${NC} Missing ## Verification section — add verification evidence"
    FAIL=$((FAIL + 1))
  fi
  
  # Check all checklist items are done
  UNCHECKED=$(grep -c "\[ \]" "$TASK_FILE" 2>/dev/null || echo "0")
  if [ "$UNCHECKED" -gt 0 ]; then
    echo -e "  ${RED}✗${NC} $UNCHECKED checklist items still unchecked"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}✓${NC} All checklist items complete"
    PASS=$((PASS + 1))
  fi
fi

# ── Summary ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}  ${YELLOW}Warnings: $WARN${NC}"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo -e "  ${RED}DO NOT declare COMPLETE — $FAIL check(s) failed.${NC}"
  exit 1
else
  echo ""
  echo -e "  ${GREEN}All checks passed. Safe to declare COMPLETE.${NC}"
  exit 0
fi
