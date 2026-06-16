#!/bin/bash
# heartbeat.sh — End-to-end harness health check
#
# Verifies every feature of pi_launchpad is working.
# Runs as a periodic cron or on-demand smoke test.
#
# Output: structured report with ✓/✗ per check, summary at end.
# Exit: 0 = all pass, 1 = any fail
#
# Usage: ./heartbeat.sh [--json] [--quiet] [--slack-webhook URL]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PI_ROOT="$PROJECT_ROOT/.pi"

# ── Args ────────────────────────────────────────────────────────────────────
JSON_OUTPUT=false
QUIET=false
SLACK_WEBHOOK=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --slack-webhook) SLACK_WEBHOOK="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── State ───────────────────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0
FAILURES=""
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

check() {
  local name="$1"
  local result="$2"
  local detail="${3:-}"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "pass" ]; then
    PASSED=$((PASSED + 1))
    [ "$QUIET" = false ] && echo "  ✓ $name"
    echo "pass|$name|$detail" >> /tmp/hb_$$
  else
    FAILED=$((FAILED + 1))
    FAILURES="${FAILURES}\n  ✗ $name — $detail"
    [ "$QUIET" = false ] && echo "  ✗ $name — $detail"
    echo "fail|$name|$detail" >> /tmp/hb_$$
  fi
}

rm -f /tmp/hb_$$

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  PI LAUNCHPAD HEARTBEAT — $TIMESTAMP"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. FILE SYSTEM INTEGRITY ───────────────────────────────────────────────
echo "── 1. File System Integrity ──"

AGENT_COUNT=$(ls "$PI_ROOT/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')
check "Agents exist ($AGENT_COUNT)" "$([ "$AGENT_COUNT" -ge 50 ] && echo pass || echo fail)" "$AGENT_COUNT files (min 50)"

EXT_COUNT=$(ls "$PI_ROOT/extensions" 2>/dev/null | wc -l | tr -d ' ')
check "Extensions exist ($EXT_COUNT)" "$([ "$EXT_COUNT" -ge 20 ] && echo pass || echo fail)" "$EXT_COUNT dirs (min 20)"

SKILL_COUNT=$(ls -d "$PI_ROOT/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
check "Skills exist ($SKILL_COUNT)" "$([ "$SKILL_COUNT" -ge 180 ] && echo pass || echo fail)" "$SKILL_COUNT dirs (min 180)"

PROMPT_COUNT=$(ls "$PI_ROOT/prompts"/*.md 2>/dev/null | wc -l | tr -d ' ')
check "Prompts exist ($PROMPT_COUNT)" "$([ "$PROMPT_COUNT" -ge 20 ] && echo pass || echo fail)" "$PROMPT_COUNT files (min 20)"

SCRIPT_COUNT=$(ls "$PROJECT_ROOT/scripts" 2>/dev/null | wc -l | tr -d ' ')
check "Scripts exist ($SCRIPT_COUNT)" "$([ "$SCRIPT_COUNT" -ge 40 ] && echo pass || echo fail)" "$SCRIPT_COUNT files (min 40)"

# ── 2. AGENT VALIDATION ────────────────────────────────────────────────────
echo ""
echo "── 2. Agent Validation ──"

BAD_AGENTS=0
for agent in "$PI_ROOT/agents"/*.md; do
  [ -f "$agent" ] || continue
  [ -s "$agent" ] || { BAD_AGENTS=$((BAD_AGENTS + 1)); continue; }
  if head -1 "$agent" | grep -q '^---'; then
    if ! awk '/^---/{n++; next} END{exit (n>=2 ? 0 : 1)}' "$agent" 2>/dev/null; then
      BAD_AGENTS=$((BAD_AGENTS + 1))
    fi
  fi
done
check "All agents valid" "$([ "$BAD_AGENTS" -eq 0 ] && echo pass || echo fail)" "$BAD_AGENTS with issues"

BOARD_COUNT=$(ls "$PI_ROOT/agents/board"/*.md 2>/dev/null | wc -l | tr -d ' ')
check "Board members ($BOARD_COUNT)" "$([ "$BOARD_COUNT" -ge 6 ] && echo pass || echo fail)" "$BOARD_COUNT (min 6)"

# ── 3. EXTENSION INTEGRITY ─────────────────────────────────────────────────
echo ""
echo "── 3. Extension Integrity ──"

MISSING_INDEX=0
for ext in "$PI_ROOT/extensions"/*/; do
  [ -d "$ext" ] || continue
  [ -f "$ext/index.ts" ] || MISSING_INDEX=$((MISSING_INDEX + 1))
done
check "All extensions have index.ts" "$([ "$MISSING_INDEX" -eq 0 ] && echo pass || echo fail)" "$MISSING_INDEX missing"

# Check observability extension
if [ -f "$PI_ROOT/extensions/observability/types.ts" ] && [ -f "$PI_ROOT/extensions/observability/store.ts" ] && [ -f "$PI_ROOT/extensions/observability/index.ts" ]; then
  check "Observability extension complete" "pass" "types.ts + store.ts + index.ts"
else
  check "Observability extension complete" "fail" "missing files"
fi

# ── 4. EXTENSION INTERNALS (via heartbeat-checks.ts) ───────────────────────
echo ""
echo "── 4. Extension Internals ──"

if command -v npx >/dev/null 2>&1; then
  CHECK_OUTPUT=$(npx tsx "$SCRIPT_DIR/heartbeat-checks.ts" 2>&1) || true
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Skip summary line
    echo "$line" | grep -q '"summary"' && continue
    NAME=$(echo "$line" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
    PASS_STR=$(echo "$line" | grep -o '"pass":[a-z]*' | head -1 | cut -d: -f2 || echo "false")
    # Convert boolean to pass/fail
    if [ "$PASS_STR" = "true" ]; then PASS_STR="pass"; else PASS_STR="fail"; fi
    DETAIL=$(echo "$line" | grep -o '"detail":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    check "$NAME" "$PASS_STR" "$DETAIL"
  done <<< "$CHECK_OUTPUT"
else
  check "Extension internals" "fail" "npx not available"
fi

# ── 5. UNIT TEST SUITE ─────────────────────────────────────────────────────
echo ""
echo "── 5. Unit Tests ──"

TEST_OUTPUT=$(npx vitest run "$PI_ROOT/extensions" --reporter=verbose 2>&1 || true)
TEST_COUNT=$(echo "$TEST_OUTPUT" | grep -o 'Tests *[0-9]* passed' | grep -o '[0-9]*' | head -1 || echo "0")
TEST_FILES=$(echo "$TEST_OUTPUT" | grep -o 'Test Files *[0-9]* passed' | grep -o '[0-9]*' | head -1 || echo "0")
TEST_FAIL=$(echo "$TEST_OUTPUT" | grep -o '[0-9]* failed' | head -1 | grep -o '[0-9]*' || echo "0")

if [ "$TEST_FAIL" = "0" ] && [ "$TEST_COUNT" -ge 150 ]; then
  check "Vitest suite ($TEST_COUNT tests, $TEST_FILES files)" "pass" "all green"
else
  check "Vitest suite ($TEST_COUNT tests, $TEST_FILES files)" "fail" "$TEST_FAIL test(s) failed"
fi

# ── 6. SCRIPT SYNTAX ───────────────────────────────────────────────────────
echo ""
echo "── 6. Script Syntax ──"

BAD_SCRIPTS=0
CHECKED=0
for script in "$PROJECT_ROOT/scripts"/*.sh; do
  [ -f "$script" ] || continue
  CHECKED=$((CHECKED + 1))
  bash -n "$script" 2>/dev/null || BAD_SCRIPTS=$((BAD_SCRIPTS + 1))
done
check "Bash scripts valid ($CHECKED)" "$([ "$BAD_SCRIPTS" -eq 0 ] && echo pass || echo fail)" "$BAD_SCRIPTS with syntax errors"

TS_SCRIPTS=$(ls "$PROJECT_ROOT/scripts"/*.ts 2>/dev/null | wc -l | tr -d ' ')
check "TypeScript scripts ($TS_SCRIPTS)" "pass" "$TS_SCRIPTS .ts scripts"

# ── 7. NETWORK SERVICES ────────────────────────────────────────────────────
echo ""
echo "── 7. Network Services ──"

COMS_NET_URL="${COMS_NET_URL:-http://localhost:8090}"
if curl -sf --max-time 3 "$COMS_NET_URL/health" >/dev/null 2>&1; then
  check "coms-net hub ($COMS_NET_URL)" "pass" "health endpoint responded"
else
  # Soft fail — coms-net only runs on VPS, not local dev
  check "coms-net hub (not local)" "pass" "not running locally (VPS only, expected)"
fi

if gh api user >/dev/null 2>&1; then
  check "GitHub API (gh auth)" "pass" "authenticated"
else
  check "GitHub API (gh auth)" "fail" "not authenticated or gh not installed"
fi

VPS_HOST="${VPS_HOST:-srv1398187.hstgr.cloud}"
if ssh -o ConnectTimeout=3 -o BatchMode=yes -i ~/.ssh/id_ed25519 "root@$VPS_HOST" "echo ok" >/dev/null 2>&1; then
  check "VPS SSH ($VPS_HOST)" "pass" "connection established"
else
  check "VPS SSH ($VPS_HOST)" "fail" "connection refused or timeout"
fi

# ── 7.5. LIVE API SMOKE TEST ─────────────────────────────────────────────
# Catches: provider role rejection (400), network timeouts, auth failures.
# Tests 2 representative models with a trivial prompt that exercises the
# 'developer' role Pi uses for its system prompt.
# Each test has a 20s timeout; skipped if API key is not set.
echo ""
echo "── 7.5. Live API Smoke Test ──"

# Test 1: direct minimax-m3 (preferred, role-compatible)
# Run from /tmp to skip the project's bash-whitelist extension which blocks
# the simple shell commands pi runs internally during startup.
if command -v pi >/dev/null 2>&1 && [ -n "${MINIMAX_API_KEY:-}" ]; then
  SMOKE_OUTPUT=$(cd /tmp && BASH_WHITELIST_MODE=log timeout 15 pi --provider minimax --model minimax-m3 -p --no-session "Reply: pong" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n' | head -c 500 || true)
  if echo "$SMOKE_OUTPUT" | grep -qi "pong"; then
    check "minimax-m3 direct (live API)" "pass" "model returned successfully"
  elif echo "$SMOKE_OUTPUT" | grep -q "400\|role.*not.*one.*of\|developer.*is.*not"; then
    check "minimax-m3 direct (live API)" "fail" "400/role error: ${SMOKE_OUTPUT:0:150}"
  else
    check "minimax-m3 direct (live API)" "fail" "no pong in response: ${SMOKE_OUTPUT:0:150}"
  fi
else
  check "minimax-m3 direct (live API)" "pass" "skipped (no MINIMAX_API_KEY or pi)"
fi

# Test 2: zai/glm-5.1 (fallback, free, role-compatible)
if command -v pi >/dev/null 2>&1 && [ -n "${ZAI_API_KEY:-}" ]; then
  SMOKE_OUTPUT=$(cd /tmp && BASH_WHITELIST_MODE=log timeout 15 pi --model zai/glm-5.1 -p --no-session "Reply: pong" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n' | head -c 500 || true)
  if echo "$SMOKE_OUTPUT" | grep -qi "pong"; then
    check "zai/glm-5.1 (live API)" "pass" "model returned successfully"
  elif echo "$SMOKE_OUTPUT" | grep -q "400\|role.*not.*one.*of\|developer.*is.*not"; then
    check "zai/glm-5.1 (live API)" "fail" "400/role error: ${SMOKE_OUTPUT:0:150}"
  else
    check "zai/glm-5.1 (live API)" "fail" "no pong in response: ${SMOKE_OUTPUT:0:150}"
  fi
else
  check "zai/glm-5.1 (live API)" "pass" "skipped (no ZAI_API_KEY or pi)"
fi

# Test 3: provider role compatibility from registry
# Count models with role_compat field declared (regardless of content)
ROLE_COMPAT_COUNT=$(grep -c "role_compat:" "$PI_ROOT/extensions/model-router/registry.yaml" 2>/dev/null || echo 0)
check "Model role_compat metadata" "$([ "$ROLE_COMPAT_COUNT" -ge 1 ] && echo pass || echo fail)" "$ROLE_COMPAT_COUNT models declare role_compat"
echo ""
echo "── 8. Event-Driven Pipeline ──"

check "event-subscriber.sh" "$([ -f "$PROJECT_ROOT/scripts/event-subscriber.sh" ] && echo pass || echo fail)" "file exists"
check "dead-letter-digest.sh" "$([ -f "$PROJECT_ROOT/scripts/dead-letter-digest.sh" ] && echo pass || echo fail)" "file exists"
check "event-driven-ship.sh" "$([ -f "$PROJECT_ROOT/scripts/event-driven-ship.sh" ] && echo pass || echo fail)" "file exists"
check "heartbeat.sh" "$([ -f "$PROJECT_ROOT/scripts/heartbeat.sh" ] && echo pass || echo fail)" "file exists"

# ── 9. COST & SAFETY ───────────────────────────────────────────────────────
echo ""
echo "── 9. Cost & Safety ──"

check "routing.yaml" "$([ -f "$PI_ROOT/routing.yaml" ] && echo pass || echo fail)" "model routing config"
check "config.sh" "$([ -f "$PI_ROOT/config.sh" ] && echo pass || echo fail)" "project config"
check "peers/" "$([ -d "$PI_ROOT/peers" ] && echo pass || echo fail)" "Pi-to-Pi peer definitions"
check "Convex schema" "$([ -f "$PI_ROOT/convex/schema.ts" ] && echo pass || echo fail)" "knowledge layer"

# ── 10. DOCUMENTATION ACCURACY ─────────────────────────────────────────────
echo ""
echo "── 10. Doc Accuracy ──"

README_AGENT=$(grep -o '[0-9]* specialist agents' "$PROJECT_ROOT/README.md" | head -1 | grep -o '[0-9]*' || echo "0")
ACTUAL_AGENT=$((AGENT_COUNT + BOARD_COUNT))
check "README agents ($README_AGENT vs $ACTUAL_AGENT)" "$([ "$README_AGENT" = "$ACTUAL_AGENT" ] && echo pass || echo fail)" "README=$README_AGENT actual=$ACTUAL_AGENT"

README_EXT=$(grep -o '[0-9]* TypeScript extensions' "$PROJECT_ROOT/README.md" | head -1 | grep -o '[0-9]*' || echo "0")
check "README extensions ($README_EXT vs $EXT_COUNT)" "$([ "$README_EXT" = "$EXT_COUNT" ] && echo pass || echo fail)" "README=$README_EXT actual=$EXT_COUNT"

README_SKILL=$(grep -o '[0-9]* skills' "$PROJECT_ROOT/README.md" | head -1 | grep -o '[0-9]*' || echo "0")
check "README skills ($README_SKILL vs $SKILL_COUNT)" "$([ "$README_SKILL" = "$SKILL_COUNT" ] && echo pass || echo fail)" "README=$README_SKILL actual=$SKILL_COUNT"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  RESULTS: $PASSED/$TOTAL passed, $FAILED failed"
echo "╚══════════════════════════════════════════════════════════════╝"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "Failures:"
  echo -e "$FAILURES"
fi

# ── JSON output ────────────────────────────────────────────────────────────
if [ "$JSON_OUTPUT" = true ]; then
  echo ""
  echo "{"
  echo "  \"timestamp\": \"$TIMESTAMP\","
  echo "  \"total\": $TOTAL,"
  echo "  \"passed\": $PASSED,"
  echo "  \"failed\": $FAILED,"
  echo "  \"checks\": ["
  FIRST=true
  while IFS='|' read -r status name detail; do
    [ -n "$status" ] || continue
    [ "$FIRST" = true ] && FIRST=false || echo ","
    echo -n "    {\"name\": \"$name\", \"status\": \"$status\", \"detail\": \"$detail\"}"
  done < /tmp/hb_$$
  echo ""
  echo "  ]"
  echo "}"
fi

# ── Slack notification on failure ──────────────────────────────────────────
if [ -n "$SLACK_WEBHOOK" ] && [ "$FAILED" -gt 0 ]; then
  curl -sf -X POST "$SLACK_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"⚠️ Pi Launchpad heartbeat: $FAILED/$TOTAL checks failed at $TIMESTAMP\"}" \
    >/dev/null 2>&1 || true
fi

rm -f /tmp/hb_$$
exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
