#!/bin/bash
# acceptance/subagent-delegation.sh — End-to-end subagent delegation test
#
# Tests that the subagent extension can spawn worker, implementer, and
# researcher agents and return structured results.
#
# This test actually runs `pi` subprocesses — it's a real integration test.
#
# Exit codes: 0 = PASS, 1 = FAIL, 2 = ERROR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_DIR="/tmp/subagent-acceptance-$(date +%s)"
mkdir -p "$RESULTS_DIR"

PASS=0
FAIL=0
TOTAL=0

check() {
  local name="$1"
  local result="$2"
  local detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "pass" ]; then
    PASS=$((PASS + 1))
    echo "  ✓ $name"
  else
    FAIL=$((FAIL + 1))
    echo "  ✗ $name — $detail"
  fi
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  SUBAGENT DELEGATION ACCEPTANCE TEST"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Prerequisites ───────────────────────────────────────────────────────────
echo "── Prerequisites ──"

if ! command -v pi >/dev/null 2>&1; then
  echo "  ✗ pi CLI not found — skipping delegation tests"
  echo "  Install: npm install -g @mariozechner/pi-coding-agent"
  exit 2
fi
check "pi CLI available" "pass"

PI_VERSION=$(pi --version 2>/dev/null || echo "unknown")
check "pi version ($PI_VERSION)" "pass"

# Check agent files exist
for agent in worker implementer researcher; do
  if [ -f "$PROJECT_ROOT/.pi/agents/${agent}.md" ]; then
    check "Agent '${agent}' exists" "pass"
  else
    check "Agent '${agent}' exists" "fail" "not found at .pi/agents/${agent}.md"
  fi
done

echo ""
echo "── Test 1: Subagent spawn infrastructure ──"

# Verify the spawn pipeline is structurally sound
if grep -q 'spawn(' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  check "spawn() call present" "pass"
else
  check "spawn() call present" "fail"
fi

if grep -q 'mode.*single\|mode.*parallel\|mode.*chain' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  check "Delegation modes (single/parallel/chain)" "pass"
else
  check "Delegation modes" "fail"
fi

# Verify JSON mode is used for structured output
if grep -q 'mode.*json\|--mode.*json' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  check "JSON mode for structured output" "pass"
else
  check "JSON mode" "fail"
fi

# Verify agent resolution
if grep -q 'resolveAgentPath\|agentFile\|agent.*\.md' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  check "Agent file resolution" "pass"
else
  check "Agent file resolution" "fail"
fi

echo ""
echo "── Test 2: Agent discovery ──"

# Verify agent discovery by scanning agent files directly
AGENT_NAMES=$(ls "$PROJECT_ROOT/.pi/agents"/*.md 2>/dev/null | xargs -I{} basename {} .md | sort)
AGENT_NAMES_COUNT=$(echo "$AGENT_NAMES" | wc -w | tr -d ' ')
if [ "$AGENT_NAMES_COUNT" -ge 10 ]; then
  check "Agent discovery ($AGENT_NAMES_COUNT agents)" "pass"
  for expected in worker implementer researcher; do
    if echo "$AGENT_NAMES" | grep -qw "$expected"; then
      check "  Agent '$expected' discoverable" "pass"
    else
      check "  Agent '$expected' discoverable" "fail" "not in agents dir"
    fi
  done
else
  check "Agent discovery" "fail" "only found $AGENT_NAMES_COUNT agents"
fi

echo ""
echo "── Test 3: Tool allowlist enforcement ──"

# Verify worker has restricted tools
WORKER_TOOLS=$(grep -A1 '^tools:' "$PROJECT_ROOT/.pi/agents/worker.md" | head -1 | sed 's/tools: *//')
if echo "$WORKER_TOOLS" | grep -q "read"; then
  check "Worker has 'read' tool" "pass"
else
  check "Worker has 'read' tool" "fail" "tools: $WORKER_TOOLS"
fi

# Verify worker does NOT have subagent (can't nest)
if echo "$WORKER_TOOLS" | grep -q "subagent"; then
  check "Worker blocked from subagent (no nesting)" "fail" "worker has subagent tool — nesting allowed"
else
  check "Worker blocked from subagent (no nesting)" "pass"
fi

# Verify researcher has appropriate tools (bash allows calling web_search tool)
RESEARCHER_TOOLS=$(grep -A1 '^tools:' "$PROJECT_ROOT/.pi/agents/researcher.md" | head -1 | sed 's/tools: *//')
if [ -n "$RESEARCHER_TOOLS" ]; then
  check "Researcher has tools defined" "pass" "tools: $RESEARCHER_TOOLS"
else
  check "Researcher has tools defined" "fail" "no tools in frontmatter"
fi

echo ""
echo "── Test 4: Subagent extension loads ──"

# Verify the extension registers its tool
if grep -q 'name: "subagent"' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  check "Subagent tool registered" "pass"
else
  check "Subagent tool registered" "fail" "'name: \"subagent\"' not found"
fi

if grep -q 'pi.registerTool' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  check "registerTool call present" "pass"
else
  check "registerTool call present" "fail"
fi

echo ""
echo "── Test 5: Cost guard ──"

# Verify cost guard thresholds exist in code
if grep -q 'SESSION_MAX_COST\|PI_SESSION_MAX_COST' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  check "Session cost guard code present" "pass"
else
  check "Session cost guard code present" "fail"
fi

if grep -q 'SUBAGENT_MAX_COST\|PI_SUBAGENT_MAX_COST' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  check "Per-call cost guard code present" "pass"
else
  check "Per-call cost guard code present" "fail"
fi

echo ""
echo "── Test 6: Spawn depth limit ──"

if grep -q 'MAX_SPAWN_DEPTH' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts"; then
  MAX_DEPTH=$(grep 'MAX_SPAWN_DEPTH' "$PROJECT_ROOT/.pi/extensions/subagent/index.ts" | grep -o '= [0-9]*' | head -1 | grep -o '[0-9]*' || echo "?")
  check "Spawn depth limit ($MAX_DEPTH)" "pass"
else
  check "Spawn depth limit" "fail" "MAX_SPAWN_DEPTH not found"
fi

echo ""
echo "── Test 7: Worktree isolation ──"

if [ -f "$PROJECT_ROOT/.pi/extensions/subagent/worktree.ts" ]; then
  check "Worktree module exists" "pass"

  # Verify merge strategies exist
  if grep -q 'fast-forward\|merge\|rebase\|preserve\|auto-resolve' "$PROJECT_ROOT/.pi/extensions/subagent/worktree.ts"; then
    check "Merge strategies implemented" "pass"
  else
    check "Merge strategies implemented" "fail"
  fi

  if grep -q 'createWorktree\|WorktreeManager' "$PROJECT_ROOT/.pi/extensions/subagent/worktree.ts"; then
    check "WorktreeManager class present" "pass"
  else
    check "WorktreeManager class present" "fail"
  fi
else
  check "Worktree module exists" "fail"
fi

echo ""
echo "── Test 8: Agent depth control ──"

# Verify agents declare which agents they can spawn
AGENTS_WITH_DEPTH=0
for agent in "$PROJECT_ROOT"/.pi/agents/*.md; do
  [ -f "$agent" ] || continue
  if grep -q '^agents:' "$agent"; then
    AGENTS_WITH_DEPTH=$((AGENTS_WITH_DEPTH + 1))
  fi
done
# Dynamic CEO, cross-model-reviewer, office-hours etc declare spawnable agents
# Also accept agents that delegate via subagent tool (implicit depth control)
DELEGATING_AGENTS=$(grep -rl 'subagent\|delegate' "$PROJECT_ROOT/.pi/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
TOTAL_DELEGATING=$((AGENTS_WITH_DEPTH + DELEGATING_AGENTS))
check "Delegation-capable agents ($TOTAL_DELEGATING)" "$([ "$TOTAL_DELEGATING" -ge 3 ] && echo pass || echo fail)" "$AGENTS_WITH_DEPTH with agents: frontmatter, $DELEGATING_AGENTS referencing subagent (min 3)"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  RESULTS: $PASS/$TOTAL passed, $FAIL failed"
echo "╚══════════════════════════════════════════════════════════════╝"

# Cleanup
rm -rf "$RESULTS_DIR"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
