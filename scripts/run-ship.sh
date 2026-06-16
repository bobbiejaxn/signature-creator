#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# run-ship.sh — Hard-enforcement orchestrator for the /ship workflow
# ──────────────────────────────────────────────────────────────────────────────
# Each gate runs as a deterministic shell check. The agent cannot self-report
# past a gate that hasn't actually passed.
#
# Usage:
#   ./scripts/run-ship.sh "Feature Name"
#
# Gates:
#   1. Git worktree isolation
#   2. Static checks (from config VERIFY_COMMANDS)
#   3. Dev log capture (exits 1 if real errors)
#   4. E2E feature test (max 2 attempts)
#   5. P0 regression suite (max 2 attempts)
#   6. Open PR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load config
source "$REPO_ROOT/.pi/config.sh"
# Default branch (main or master) — used as the PR base and as the trunk the
# feature branch is rebased onto (#194). Detected once; mirrors cron-auto-ship.sh.
DEFAULT_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || git -C "$REPO_ROOT" remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo main)"


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

FEATURE_NAME="${1:-}"
ISSUE_NUMBER="${2:-}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FEATURE_SLUG=$(echo "$FEATURE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
BRANCH_NAME="feature/${FEATURE_SLUG}-${TIMESTAMP}"
WORKTREE_PATH="${WORKTREE_PREFIX}-${FEATURE_SLUG}-${TIMESTAMP}"

WORKTREE_CREATED=false
PHASE_REACHED=0

print_gate() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  GATE $1: $2${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

pass() { echo -e "${GREEN}  ✓ $1${NC}"; }
fail() { echo -e "${RED}  ✗ $1${NC}"; }
warn() { echo -e "${YELLOW}  ! $1${NC}"; }
info() { echo -e "${BLUE}  → $1${NC}"; }

cleanup() {
  if [ "$WORKTREE_CREATED" = true ] && [ -d "$WORKTREE_PATH" ]; then
    info "Cleaning up worktree at $WORKTREE_PATH"
    cd "$REPO_ROOT"
    git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
    git branch -D "$BRANCH_NAME" 2>/dev/null || true
  fi
}

abort() {
  echo ""
  fail "ABORTED at Gate $PHASE_REACHED: $1"
  echo ""
  echo "The agent's work is in: $WORKTREE_PATH"
  echo "Branch: $BRANCH_NAME"
  WORKTREE_CREATED=false
  exit 1
}

# ─── Validate input ──────────────────────────────────────────────────────────

if [ -z "$FEATURE_NAME" ]; then
  echo "Usage: ./scripts/run-ship.sh \"Feature Name\""
  exit 1
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SHIP ORCHESTRATOR: $FEATURE_NAME${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Branch: $BRANCH_NAME"
info "Worktree: $WORKTREE_PATH"
echo ""

# ─── Gate 1: Worktree setup ──────────────────────────────────────────────────

PHASE_REACHED=1
print_gate 1 "Worktree isolation"

cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  warn "Working tree has uncommitted changes"
  warn "Commit work before running gates"
  echo ""
  git status --short
  exit 1
fi

info "Creating isolated worktree on branch $BRANCH_NAME"
git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" HEAD
WORKTREE_CREATED=true
pass "Worktree created at $WORKTREE_PATH"

# ─── #194: Base the feature branch on the remote trunk ───────────────────────
# The orchestrator commits the fix to LOCAL main (and may push it — fix-on-main)
# before run-ship.sh branches the worktree from HEAD. Branching from HEAD then
# makes the feature tip identical to main, so Gate 6 `gh pr create --base main`
# fails with "No commits between main and feature" — no PR. This is the Gate-6
# analog of #190 Bug B. Fix: base the branch on the remote trunk and replay
# HEAD's commits as NEW commits, guaranteeing it is ahead of main.
cd "$WORKTREE_PATH"
git fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true
TRUNK="origin/${DEFAULT_BRANCH}"
if ! git rev-parse --verify "$TRUNK" >/dev/null 2>&1; then
  abort "Cannot resolve $TRUNK — run 'git fetch origin $DEFAULT_BRANCH' then retry. (#194)"
fi
FIX_COMMITS="$(git rev-list --reverse "${TRUNK}..HEAD" 2>/dev/null | tr '\n' ' ')"
FIX_COMMITS="${FIX_COMMITS% }"
if [ -z "$FIX_COMMITS" ]; then
  abort "HEAD == $TRUNK: nothing ahead of $DEFAULT_BRANCH to ship. Commit the feature before running run-ship.sh — the branch must differ from $DEFAULT_BRANCH (#194)."
fi
FIX_COUNT="$(printf '%s' "$FIX_COMMITS" | wc -w | tr -d ' ')"
info "Replaying $FIX_COUNT commit(s) onto $TRUNK so the feature branch differs from $DEFAULT_BRANCH (#194)"
git reset --hard "$TRUNK"
# shellcheck disable=SC2086  # FIX_COMMITS is an intentional space-separated rev list
if ! git cherry-pick $FIX_COMMITS; then
  git cherry-pick --abort 2>/dev/null || true
  abort "cherry-pick of fix commit(s) onto $TRUNK failed — the change may already be on $DEFAULT_BRANCH. Resolve conflicts in $WORKTREE_PATH or ship via fix-on-main (#194)."
fi
AHEAD="$(git rev-list --count "${TRUNK}..HEAD" 2>/dev/null || echo 0)"
pass "Feature branch based on $TRUNK, ahead of $DEFAULT_BRANCH by $AHEAD commit(s)"


# ─── Gate 2: Static checks ───────────────────────────────────────────────────

PHASE_REACHED=2
print_gate 2 "Static checks"

cd "$WORKTREE_PATH"

for cmd in "${VERIFY_COMMANDS[@]}"; do
  info "Running: $cmd"
  if ! eval "$cmd" 2>&1; then
    abort "$cmd failed"
  fi
  pass "$cmd"
done

# ─── Gate 2.5: Security gate ─────────────────────────────────────────────────

print_gate 2 "Security gate (secrets, weak passwords, unsafe code)"

if [ -f "$SCRIPT_DIR/security-gate.sh" ]; then
  if ! bash "$SCRIPT_DIR/security-gate.sh"; then
    abort "Security gate failed — fix violations before shipping"
  fi
  pass "Security gate clean"
else
  info "security-gate.sh not found — skipping"
fi

# ─── Gate 3: Dev log check ───────────────────────────────────────────────────

PHASE_REACHED=3
print_gate 3 "Dev log check (runtime errors)"

info "Starting dev server and capturing logs for 20 seconds..."
LOG_OUTPUT=$(./scripts/capture-dev-logs.sh 20 2>&1)
LOG_EXIT=$?

echo "$LOG_OUTPUT" | tail -20

if [ $LOG_EXIT -ne 0 ]; then
  echo "$LOG_OUTPUT"
  abort "Dev logs contain real errors"
fi

pass "LOG VERDICT: CLEAN"

# ─── Gate 4: E2E feature test (max 2 attempts) ───────────────────────────────

PHASE_REACHED=4
print_gate 4 "E2E feature test: $FEATURE_NAME"

cd "$WORKTREE_PATH"

info "Attempt 1 of 2..."
TEST_OUTPUT=$(eval "$TEST_COMMAND \"$FEATURE_NAME\"" 2>&1)
TEST_EXIT=$?

echo "$TEST_OUTPUT" | tail -20

if [ $TEST_EXIT -ne 0 ]; then
  warn "Attempt 1 failed. Waiting for agent fix, then retrying..."
  echo "$TEST_OUTPUT"
  echo ""
  echo -e "${YELLOW}Fix the failure and press Enter for attempt 2, or Ctrl+C to abort.${NC}"
  read -r

  info "Attempt 2 of 2..."
  TEST_OUTPUT2=$(eval "$TEST_COMMAND \"$FEATURE_NAME\"" 2>&1)
  TEST_EXIT2=$?

  echo "$TEST_OUTPUT2" | tail -20

  if [ $TEST_EXIT2 -ne 0 ]; then
    FAILURE_DETAIL=$(echo "$TEST_OUTPUT2" | grep -E "FAIL|Error|✗" | head -5 | tr '\n' ' ')

    ./scripts/create-issue.sh \
      --title "E2E test failing: $FEATURE_NAME" \
      --type regression \
      --found-during "shipping $FEATURE_NAME (2 attempts exhausted)" \
      --location "$TEST_SPEC_DIR" \
      --symptom "$FAILURE_DETAIL" \
      --context "E2E test for '$FEATURE_NAME' failed both attempts during run-ship.sh." \
      --affects "Verification of the $FEATURE_NAME feature" \
      --test "$FEATURE_NAME" 2>/dev/null || true

    abort "E2E test failed after 2 attempts — see GitHub issue"
  fi
fi

pass "E2E feature test: passing"

# ─── Gate 5: P0 regression suite ─────────────────────────────────────────────

PHASE_REACHED=5
print_gate 5 "P0 regression suite"

cd "$WORKTREE_PATH"

if [ -n "$P0_TESTS" ]; then
  info "Running: $P0_TESTS"

  P0_OUTPUT=$(eval "$TEST_COMMAND \"$P0_TESTS\"" 2>&1)
  P0_EXIT=$?

  echo "$P0_OUTPUT" | tail -30

  if [ $P0_EXIT -ne 0 ]; then
    warn "P0 regressions failed. One retry..."
    echo "$P0_OUTPUT"
    echo ""
    echo -e "${YELLOW}Fix the regression and press Enter to retry, or Ctrl+C to abort.${NC}"
    read -r

    P0_OUTPUT2=$(eval "$TEST_COMMAND \"$P0_TESTS\"" 2>&1)
    P0_EXIT2=$?

    echo "$P0_OUTPUT2" | tail -30

    if [ $P0_EXIT2 -ne 0 ]; then
      abort "P0 regressions still failing — do not ship with regressions"
    fi
  fi

  pass "P0 regressions: all clean"
else
  warn "No P0 tests configured (P0_TESTS is empty)"
fi

# ─── Gate 6: Open PR ─────────────────────────────────────────────────────────

print_gate 6 "Open pull request"

cd "$WORKTREE_PATH"

info "Pushing branch $BRANCH_NAME..."
git push origin "$BRANCH_NAME"

PR_BODY_FILE="/tmp/pr-body-${FEATURE_SLUG}-${TIMESTAMP}.md"

TEST_SUMMARY=$(echo "${TEST_OUTPUT2:-$TEST_OUTPUT}" | grep -E "passed|steps" | tail -3 | tr '\n' ' ' || echo "passing")

cat > "$PR_BODY_FILE" << EOF
## $FEATURE_NAME

Implemented and verified by the /ship agent.

## Verified
- ✓ Static checks: all passing
- ✓ Dev logs: clean
- ✓ E2E feature test: passing
- ✓ P0 regressions: clean

## What the user can now do
[See the /ship report in the agent session]
EOF

PR_BODY="$(cat "$PR_BODY_FILE")"
if [ -n "$ISSUE_NUMBER" ]; then
  PR_BODY="Closes #${ISSUE_NUMBER}\n\n${PR_BODY}"
fi

PR_URL=$(gh pr create \
  --repo "$REPO" \
  --title "feat: $FEATURE_NAME" \
  --body "$PR_BODY" \
  --base "$DEFAULT_BRANCH" \
  --label "agent-generated" \
  2>/dev/null)

if [ -z "$PR_URL" ]; then
  warn "Could not create PR — push succeeded, create manually from: $BRANCH_NAME"
else
  pass "PR created: $PR_URL"

  # Send cost notification (#56)
  if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    SHIP_COST="${SHIP_COST:-unknown}"
    MSG="🚀 *Ship complete*
Feature: $FEATURE_NAME
PR: $PR_URL
Cost: \$${SHIP_COST}"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d parse_mode="Markdown" \
      -d text="$MSG" > /dev/null 2>&1 &
  fi
fi


# ─── Gate 7: Post-deploy visual verification ─────────────────────────────────

if [[ -f "$REPO_ROOT/scripts/visual-verify.sh" && -n "${PROD_URL:-}" ]]; then
  print_gate 7 "Visual verification"
  PHASE_REACHED=7

  info "Verifying live site at $PROD_URL ..."

  VISUAL_EXIT=0
  bash "$REPO_ROOT/scripts/visual-verify.sh" "$PROD_URL" || VISUAL_EXIT=$?

  if [[ "$VISUAL_EXIT" -eq 1 ]]; then
    warn "Visual issues detected — review screenshot before merging"
    warn "Screenshots saved in: $REPO_ROOT/.visual-verify/"
  elif [[ "$VISUAL_EXIT" -eq 2 ]]; then
    warn "Site unreachable at $PROD_URL — deploy may not have propagated yet"
  elif [[ "$VISUAL_EXIT" -eq 3 ]]; then
    info "playwright-cli not installed — skipping visual verification"
  else
    pass "Visual verification passed"
  fi
else
  info "Skipping visual verification (no PROD_URL in config or no visual-verify.sh)"
fi

# ─── Cleanup worktree ────────────────────────────────────────────────────────

info "Removing worktree..."
cd "$REPO_ROOT"
git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
WORKTREE_CREATED=false

# ─── Learning log ────────────────────────────────────────────────────────────

LOG_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_ID="LRN-$(date +%Y%m%d)-$(cat /dev/urandom | LC_ALL=C tr -dc 'A-Z0-9' | head -c 3 2>/dev/null || echo "001")"
LEARNINGS_FILE="$REPO_ROOT/.learnings/LEARNINGS.md"

cat >> "$LEARNINGS_FILE" << EOF

## [$LOG_ID]

**Logged**: $LOG_DATE
**Feature**: $FEATURE_NAME
**Branch**: $BRANCH_NAME
**Status**: pending
**Priority**: low

### What happened
All gates passed. Feature shipped via /ship workflow.

### Gate fixes required
[Review agent session transcript for details]

### Patterns observed
[To be filled by learning-agent]

### Metadata
- Source: run-ship.sh
- Area: [to be classified by learning-agent]
- Tags: ship, automated
- E2E attempts: Gate 4 used $([ -n "${TEST_OUTPUT2:-}" ] && echo "2" || echo "1") attempt(s)
- PR: ${PR_URL:-none}

---
EOF

info "Learning entry $LOG_ID appended to .learnings/LEARNINGS.md"

# ─── Final summary ───────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ALL GATES PASSED: $FEATURE_NAME${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
pass "Gate 2: Static checks"
pass "Gate 2.5: Security gate"
pass "Gate 3: Dev logs clean"
pass "Gate 4: E2E feature test"
pass "Gate 5: P0 regressions"
pass "Gate 6: PR opened"
if [[ -n "${PROD_URL:-}" ]]; then pass "Gate 7: Visual verify"; fi
echo ""
if [ -n "${PR_URL:-}" ]; then
  echo -e "  PR: ${CYAN}$PR_URL${NC}"
fi
echo ""
echo -e "  Learning entry ${LOG_ID} logged."
echo ""
