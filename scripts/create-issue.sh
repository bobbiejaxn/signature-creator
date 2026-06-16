#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# create-issue.sh — Creates a structured GitHub issue for out-of-scope problems
# ──────────────────────────────────────────────────────────────────────────────
# Reads REPO from .pi/config.sh
#
# Usage:
#   ./scripts/create-issue.sh \
#     --title "Dashboard crashes when user has no items" \
#     --type bug \
#     --found-during "shipping Create Item feature" \
#     --location "src/pages/dashboard.tsx" \
#     --symptom "TypeError: Cannot read properties of undefined" \
#     --context "Query returns undefined instead of []. Page calls .map() without null check." \
#     --affects "Any user with zero items sees a crash" \
#     --test "Dashboard"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/.pi/config.sh"

TITLE=""
TYPE=""
FOUND_DURING=""
LOCATION=""
SYMPTOM=""
CONTEXT=""
AFFECTS=""
TEST_NAME=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --title)         TITLE="$2";         shift 2 ;;
    --type)          TYPE="$2";          shift 2 ;;
    --found-during)  FOUND_DURING="$2";  shift 2 ;;
    --location)      LOCATION="$2";      shift 2 ;;
    --symptom)       SYMPTOM="$2";       shift 2 ;;
    --context)       CONTEXT="$2";       shift 2 ;;
    --affects)       AFFECTS="$2";       shift 2 ;;
    --test)          TEST_NAME="$2";     shift 2 ;;
    --dry-run)       DRY_RUN=true;       shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Validate required fields
MISSING=""
[ -z "$TITLE" ]        && MISSING="$MISSING --title"
[ -z "$TYPE" ]         && MISSING="$MISSING --type"
[ -z "$FOUND_DURING" ] && MISSING="$MISSING --found-during"
[ -z "$LOCATION" ]     && MISSING="$MISSING --location"
[ -z "$SYMPTOM" ]      && MISSING="$MISSING --symptom"
[ -z "$CONTEXT" ]      && MISSING="$MISSING --context"
[ -z "$AFFECTS" ]      && MISSING="$MISSING --affects"

if [ -n "$MISSING" ]; then
  echo "Missing required arguments:$MISSING"
  exit 1
fi

case "$TYPE" in
  bug|regression|log-error|enhancement) ;;
  *) echo "Invalid --type '$TYPE'. Use: bug, regression, log-error, enhancement"; exit 1 ;;
esac

case "$TYPE" in
  bug)         LABELS="bug,needs-fix,out-of-scope" ;;
  regression)  LABELS="regression,needs-fix,out-of-scope" ;;
  log-error)   LABELS="log-error,bug,needs-fix,out-of-scope" ;;
  enhancement) LABELS="enhancement,out-of-scope" ;;
esac

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
CURRENT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Read verification commands from config
VERIFY_BLOCK=""
for cmd in "${VERIFY_COMMANDS[@]}"; do
  VERIFY_BLOCK="$VERIFY_BLOCK\n   $cmd"
done

BODY="## Found During
$FOUND_DURING

## Location
\`$LOCATION\`

## Symptom
\`\`\`
$SYMPTOM
\`\`\`

## Context
$CONTEXT

## Who Is Affected
$AFFECTS
$([ -n "$TEST_NAME" ] && echo "
## E2E Test Coverage
The **$TEST_NAME** test covers this area and should be run after fixing." || true)

## Fix Instructions for Agent

1. Read this issue fully before touching any code
2. Read the files in **Location** and understand the current behaviour
3. Fix the root cause — not the symptom
4. Run verification:
   \`\`\`bash$(echo -e "$VERIFY_BLOCK")
   ./scripts/capture-dev-logs.sh 20
   \`\`\`
5. Run E2E test: \`$(echo "$TEST_COMMAND") \"$([ -n "$TEST_NAME" ] && echo "$TEST_NAME" || echo "$P0_TESTS")\"\`
6. All checks must be clean before closing this issue
7. Close with: \`fixes #[issue-number]\` in the commit message

---
*Found by agent on branch \`$CURRENT_BRANCH\` at commit \`$CURRENT_COMMIT\`. Out of scope for current feature.*"

if [ "$DRY_RUN" = true ]; then
  echo "=== DRY RUN ==="
  echo "Title:  $TITLE"
  echo "Labels: $LABELS"
  echo "Body:"
  echo "$BODY"
  exit 0
fi

ISSUE_URL=$(gh issue create \
  --repo "$REPO" \
  --title "$TITLE" \
  --body "$BODY" \
  --label "$LABELS" \
  2>/dev/null)

if [ -z "$ISSUE_URL" ]; then
  echo "Failed to create issue"
  exit 1
fi

ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')

echo "Issue created: $ISSUE_URL"
echo "Issue number: #$ISSUE_NUMBER"
echo ""
echo "To fix this issue later, run:"
echo "  /fix $ISSUE_NUMBER"
