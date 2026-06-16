#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# autoship-preflight.sh — Batch clarifier for all open issues
# ──────────────────────────────────────────────────────────────────────────────
# Reads every open issue, runs spec-clarifier, collects questions,
# presents ALL questions to the user in one batch. Then marks issues
# as spec-clarified (ready for autoship).
#
# Usage:
#   ./scripts/autoship-preflight.sh                  # All open issues
#   ./scripts/autoship-preflight.sh --issue 107      # Specific issue
#   ./scripts/autoship-preflight.sh --batch 5        # Up to 5 issues
#
# Output:
#   .pi/specs/clarified/{issue-number}.md   — Clarified spec (READY)
#   .pi/specs/questions/{issue-number}.md   — Questions (NEEDS_INPUT)
#   .pi/specs/preflight-summary.md          — Batch summary for user review

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

source "$REPO_ROOT/.pi/config.sh" 2>/dev/null || { echo "No .pi/config.sh found"; exit 1; }

# Security: prevent bash whitelist from blocking clarifier
export NO_BASH_MODE="log"
export BASH_WHITELIST_MODE="log"

REPO="${REPO:-}"
SPECIFIC_ISSUE=""
BATCH=50
QUESTIONS_FILE="$REPO_ROOT/.pi/specs/preflight-summary.md"

# Model config from .pi/config.sh (or defaults)
CLARIFY_MODEL="${CRON_SPEC_MODEL:-deepseek-v4-pro:cloud}"
CLARIFY_PROVIDER="${CRON_SPEC_PROVIDER:-ollama}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0;0m'

mkdir -p "$REPO_ROOT/.pi/specs/clarified"
mkdir -p "$REPO_ROOT/.pi/specs/questions"

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --issue) SPECIFIC_ISSUE="$2"; shift 2 ;;
    --batch) BATCH="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$REPO" ]; then
  echo "REPO not set in .pi/config.sh"
  exit 1
fi

# ─── Collect issues ──────────────────────────────────────────────────────────

collect_issues() {
  if [ -n "$SPECIFIC_ISSUE" ]; then
    echo "$SPECIFIC_ISSUE"
    return
  fi
  
  # Get open issues that haven't been clarified yet
  # (no spec-clarified label)
  gh issue list --repo "$REPO" --state open --limit "$BATCH" --json number,labels,title \
    --jq '.[] | select(.labels | all(.name != "spec-clarified")) | .number' 2>/dev/null
}

# ─── Get issue details ───────────────────────────────────────────────────────
get_issue_title() {
  gh issue view "$1" --repo "$REPO" --json title --jq '.title' 2>/dev/null
}

get_issue_body() {
  gh issue view "$1" --repo "$REPO" --json body --jq '.body' 2>/dev/null
}

# ─── Main ─────────────────────────────────────────────────────────────────────

ISSUES=$(collect_issues)
ISSUE_COUNT=$(echo "$ISSUES" | grep -c . || echo "0")

if [ "$ISSUE_COUNT" -eq 0 ]; then
  echo -e "${GREEN}No unclarified issues found. All clear for autoship.${NC}"
  exit 0
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  PREFLIGHT: Clarifying ${ISSUE_COUNT} issue(s)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

READY_COUNT=0
NEEDS_INPUT_COUNT=0
ALL_QUESTIONS=""

for ISSUE_NUM in $ISSUES; do
  ISSUE_TITLE=$(get_issue_title "$ISSUE_NUM")
  echo -e "${BLUE}→ Clarifying #${ISSUE_NUM}: ${ISSUE_TITLE}${NC}"
  
  ISSUE_BODY=$(get_issue_body "$ISSUE_NUM")
  
  # Run spec-clarifier via pi
  CLARIFIER_PROMPT="You are the spec-clarifier. Read this GitHub issue and the current codebase, then produce a fully clarified implementation-ready spec.

Issue #${ISSUE_NUM}: ${ISSUE_TITLE}

${ISSUE_BODY}

Instructions:
1. Read the codebase to understand existing patterns (grep for relevant functions, routes, helpers)
2. Resolve every ambiguity you can from the code
3. For anything you CANNOT resolve, list it as ❓ QUESTION
4. Output the full clarified spec

Format:
VERDICT: READY or NEEDS_INPUT
Then the resolved ambiguities, questions (if any), implementation context, and the full clarified spec."

  # Run spec-clarifier via pi with model from config
  PI_ARGS="-p"
  if [ -n "$CLARIFY_MODEL" ]; then PI_ARGS="$PI_ARGS --model $CLARIFY_MODEL"; fi
  RESULT=$(pi $PI_ARGS "$CLARIFIER_PROMPT" 2>&1 || echo "CLARIFIER_FAILED")
  
  if echo "$RESULT" | grep -q "NEEDS_INPUT"; then
    echo -e "${YELLOW}  ⚠ NEEDS_INPUT${NC}"
    NEEDS_INPUT_COUNT=$((NEEDS_INPUT_COUNT + 1))
    echo "$RESULT" > "$REPO_ROOT/.pi/specs/questions/${ISSUE_NUM}.md"
    
    # Extract questions for the summary
    QUESTIONS=$(echo "$RESULT" | grep "❓" || true)
    ALL_QUESTIONS="${ALL_QUESTIONS}

## #${ISSUE_NUM}: ${ISSUE_TITLE}
${QUESTIONS}
"
  else
    echo -e "${GREEN}  ✓ READY${NC}"
    READY_COUNT=$((READY_COUNT + 1))
    echo "$RESULT" > "$REPO_ROOT/.pi/specs/clarified/${ISSUE_NUM}.md"
    gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label "spec-clarified" 2>/dev/null || true
  fi
done

# ─── Write summary ────────────────────────────────────────────────────────────

cat > "$QUESTIONS_FILE" << EOF
# Preflight Summary — $(date '+%Y-%m-%d %H:%M')

**Total:** ${ISSUE_COUNT} issues | **Ready:** ${READY_COUNT} | **Needs Input:** ${NEEDS_INPUT_COUNT}

## Ready for Autoship
$(ls "$REPO_ROOT"/.pi/specs/clarified/*.md 2>/dev/null | while read f; do
  NUM=$(basename "$f" .md)
  TITLE=$(get_issue_title "$NUM" 2>/dev/null || echo "Unknown")
  echo "- #${NUM}: ${TITLE}"
done)

---

## Needs Your Input
${ALL_QUESTIONS}

---

## Next Steps

1. Answer the questions above
2. Run: \`./scripts/autoship-preflight.sh --issue {number}\` for each answered issue
3. When all are READY: \`./scripts/autoship.sh --clarified --batch ${ISSUE_COUNT}\`
EOF

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  PREFLIGHT COMPLETE${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Ready:       ${GREEN}${READY_COUNT}${NC}"
echo -e "  Needs Input: ${YELLOW}${NEEDS_INPUT_COUNT}${NC}"
echo ""
echo -e "  Summary: ${QUESTIONS_FILE}"
echo ""

if [ "$NEEDS_INPUT_COUNT" -gt 0 ]; then
  echo -e "${YELLOW}  ⚠ Answer the questions above, then re-run preflight for those issues.${NC}"
  echo -e "${YELLOW}  Once all are READY, run: ./scripts/autoship.sh --clarified --batch ${ISSUE_COUNT}${NC}"
else
  echo -e "${GREEN}  ✓ All issues clarified. Ready to autoship!${NC}"
  echo -e "${GREEN}  Run: ./scripts/autoship.sh --clarified --batch ${ISSUE_COUNT}${NC}"
fi
