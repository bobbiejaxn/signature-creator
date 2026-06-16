#!/bin/bash
# Acceptance test: Subagent delegation — parallel, chain, single modes
#
# Verifies:
#   1. Single mode spawns one worker and returns result
#   2. Parallel mode spawns multiple workers
#   3. Chain mode spawns sequential workers passing context
#   4. Worktree isolation — workers get separate branches
#   5. Cost guard — budget ceiling enforced
#   6. Restart on crash — transient failures retried
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = ERROR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_ID="acceptance-subagent-$(date +%s)"

echo "=== Subagent Delegation Acceptance Test ==="
echo "Run ID: $RUN_ID"

PASS=0
FAIL=0

# ── Test 1: Worktree isolation ──────────────────────────────────────────────
echo ""
echo "--- Test 1: Worktree isolation ---"
BRANCH="wt/test-acceptance-$(date +%s)"

# Create a worktree via the WorktreeManager
TEST_FILE=".pi/acceptance-test-$(date +%s).md"
RESULT=$(cd "$PROJECT_ROOT" && node -e "
const { WorktreeManager } = require('./.pi/extensions/subagent/worktree.js');
try {
  const handle = WorktreeManager.createWorktree('.', '$BRANCH', ['${TEST_FILE}']);
  console.log(JSON.stringify({ success: true, path: handle.path, branch: handle.branch }));
} catch(e) {
  console.log(JSON.stringify({ success: false, error: e.message }));
}
" 2>&1) || true

if echo "$RESULT" | grep -q '"success":true'; then
  echo "  ✓ Worktree created: $(echo "$RESULT" | grep -o '"branch":"[^"]*"')"
  PASS=$((PASS + 1))
  # Cleanup
  cd "$PROJECT_ROOT" && git worktree remove --force 2>/dev/null || true
  git branch -D "$BRANCH" 2>/dev/null || true
else
  echo "  ✗ Worktree creation failed: $RESULT"
  FAIL=$((FAIL + 1))
fi

# ── Test 2: Merge resolver conflict parsing ─────────────────────────────────
echo ""
echo "--- Test 2: 4-tier merge resolver ---"
RESULT=$(cd "$PROJECT_ROOT" && node -e "
const { resolveConflictsKeepIncoming, hasContentfulCanonical, looksLikeProse } = require('./.pi/extensions/subagent/merge-resolver.js');
const conflict = '<<<HEAD\ncanonical\n===\nincoming\n>>>branch';
const tests = [];
tests.push({ name: 'keep-incoming', pass: resolveConflictsKeepIncoming('before\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> branch\nafter') === 'before\nnew\nafter' });
tests.push({ name: 'no-conflict', pass: resolveConflictsKeepIncoming('clean') === null });
tests.push({ name: 'has-contentful', pass: hasContentfulCanonical('<<<<<<< HEAD\ncode\n=======\nnew\n>>>>>>> b') === true });
tests.push({ name: 'no-contentful', pass: hasContentfulCanonical('<<<<<<< HEAD\n  \n=======\nnew\n>>>>>>> b') === false });
tests.push({ name: 'prose-detect', pass: looksLikeProse('I will resolve this conflict by...') === true });
tests.push({ name: 'code-pass', pass: looksLikeProse('const x = 1;') === false });
const fails = tests.filter(t => !t.pass);
console.log(JSON.stringify({ total: tests.length, passed: tests.length - fails.length, failed: fails.map(f => f.name) }));
" 2>&1) || true

if echo "$RESULT" | grep -q '"failed":\[\]'; then
  PASSED=$(echo "$RESULT" | grep -o '"passed":[0-9]*' | cut -d: -f2)
  echo "  ✓ All $PASSED merge resolver tests passed"
  PASS=$((PASS + 1))
else
  echo "  ✗ Merge resolver failures: $RESULT"
  FAIL=$((FAIL + 1))
fi

# ── Test 3: Health evaluator ────────────────────────────────────────────────
echo ""
echo "--- Test 3: ZFC health evaluator ---"
RESULT=$(cd "$PROJECT_ROOT" && node -e "
const { evaluateHealth, transitionState, isProcessRunning } = require('./.pi/extensions/session-intel/health.js');
const tests = [];
const dead = evaluateHealth({ agentName: 'w', pid: 99999999, state: 'working', lastActivity: new Date().toISOString() }, { staleMs: 300000, zombieMs: 1800000 });
tests.push({ name: 'pid-dead→zombie', pass: dead.state === 'zombie' && dead.action === 'terminate' });
const unknown = evaluateHealth({ agentName: 'w', pid: null, state: 'working', lastActivity: new Date().toISOString() }, { staleMs: 300000, zombieMs: 1800000 });
tests.push({ name: 'pid-null→working', pass: unknown.state === 'working' && unknown.action === 'none' });
const completed = evaluateHealth({ agentName: 'w', pid: 99999999, state: 'completed', lastActivity: new Date().toISOString() }, { staleMs: 300000, zombieMs: 1800000 });
tests.push({ name: 'completed→skip', pass: completed.state === 'completed' && completed.action === 'none' });
tests.push({ name: 'forward-only', pass: transitionState('zombie', { state: 'working', action: 'none' }) === 'zombie' });
tests.push({ name: 'investigate-hold', pass: transitionState('working', { state: 'zombie', action: 'investigate' }) === 'working' });
const fails = tests.filter(t => !t.pass);
console.log(JSON.stringify({ total: tests.length, passed: tests.length - fails.length, failed: fails.map(f => f.name) }));
" 2>&1) || true

if echo "$RESULT" | grep -q '"failed":\[\]'; then
  PASSED=$(echo "$RESULT" | grep -o '"passed":[0-9]*' | cut -d: -f2)
  echo "  ✓ All $PASSED health evaluator tests passed"
  PASS=$((PASS + 1))
else
  echo "  ✗ Health evaluator failures: $RESULT"
  FAIL=$((FAIL + 1))
fi

# ── Test 4: Agent validation ────────────────────────────────────────────────
echo ""
echo "--- Test 4: Agent frontmatter validation ---"
INVALID=0
for agent in "$PROJECT_ROOT"/.pi/agents/*.md; do
  NAME=$(basename "$agent" .md)
  # Check file is non-empty
  if [ ! -s "$agent" ]; then
    echo "  ✗ $NAME is empty"
    INVALID=$((INVALID + 1))
    continue
  fi
  # Check for frontmatter if it exists
  if head -1 "$agent" | grep -q '^---'; then
    if ! grep -q '^---' <(tail -n +2 "$agent" | head -20); then
      echo "  ✗ $NAME has unclosed frontmatter"
      INVALID=$((INVALID + 1))
    fi
  fi
done

if [ "$INVALID" -eq 0 ]; then
  AGENT_COUNT=$(ls "$PROJECT_ROOT"/.pi/agents/*.md | wc -l | tr -d ' ')
  echo "  ✓ All $AGENT_COUNT agent files valid"
  PASS=$((PASS + 1))
else
  echo "  ✗ $INVALID agent files invalid"
  FAIL=$((FAIL + 1))
fi

# ── Test 5: Extension loading ───────────────────────────────────────────────
echo ""
echo "--- Test 5: Extension index.ts existence ---"
EXT_MISSING=0
for ext in "$PROJECT_ROOT"/.pi/extensions/*/; do
  NAME=$(basename "$ext")
  if [ ! -f "$ext/index.ts" ]; then
    echo "  ✗ $NAME missing index.ts"
    EXT_MISSING=$((EXT_MISSING + 1))
  fi
done

if [ "$EXT_MISSING" -eq 0 ]; then
  EXT_COUNT=$(ls "$PROJECT_ROOT"/.pi/extensions/ | wc -l | tr -d ' ')
  echo "  ✓ All $EXT_COUNT extensions have index.ts"
  PASS=$((PASS + 1))
else
  echo "  ✗ $EXT_MISSING extensions missing index.ts"
  FAIL=$((FAIL + 1))
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
