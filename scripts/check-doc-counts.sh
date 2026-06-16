#!/usr/bin/env bash
# check-doc-counts.sh — Verify documentation counts match actual file state.
# Run as part of pre-commit or CI to prevent stale counts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Actual counts
CORE_AGENTS=$(ls .pi/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
BOARD_AGENTS=$(ls .pi/agents/board/*.md 2>/dev/null | wc -l | tr -d ' ')
TOTAL_AGENTS=$((CORE_AGENTS + BOARD_AGENTS))
EXTENSIONS=$(ls -d .pi/extensions/*/ 2>/dev/null | wc -l | tr -d ' ')
SKILLS=$(ls -d .pi/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
PROMPTS=$(ls .pi/prompts/*.md 2>/dev/null | wc -l | tr -d ' ')
SCRIPTS=$(ls scripts/*.sh 2>/dev/null | wc -l | tr -d ' ')

ERRORS=0

# Check README.md
check_count() {
  local file="$1" label="$2" actual="$3"
  local found
  found=$(grep -oE "[0-9]+ ${label}" "$file" | head -1 | grep -oE '^[0-9]+')
  if [ -z "$found" ]; then
    echo "WARN: Could not find count for '${label}' in ${file}"
    return
  fi
  if [ "$found" != "$actual" ]; then
    echo "FAIL: ${file} says ${found} ${label}, but actual count is ${actual}"
    ERRORS=$((ERRORS + 1))
  fi
}

check_count "README.md" "specialist AI agents" "$TOTAL_AGENTS"
check_count "README.md" "TypeScript extensions" "$EXTENSIONS"
check_count "README.md" "composable behaviors" "$SKILLS"
check_count "README.md" "slash commands" "$PROMPTS"
check_count "README.md" "enforcement and automation scripts" "$SCRIPTS"

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "Doc counts are stale. Run /sync-docs to fix."
  echo "  Agents:    ${TOTAL_AGENTS}"
  echo "  Extensions: ${EXTENSIONS}"
  echo "  Skills:    ${SKILLS}"
  echo "  Prompts:   ${PROMPTS}"
  echo "  Scripts:   ${SCRIPTS}"
  exit 1
fi

echo "Doc counts OK: ${TOTAL_AGENTS} agents, ${EXTENSIONS} extensions, ${SKILLS} skills, ${PROMPTS} prompts, ${SCRIPTS} scripts"
exit 0
