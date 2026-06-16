#!/usr/bin/env bash
# claude-oracle.sh — Strategic Claude Code escalation via OAuth subscription
# ──────────────────────────────────────────────────────────────────────────────
# Wraps `claude -p` with budget tracking, environment gating, and context injection.
#
# Usage:
#   source scripts/claude-oracle.sh
#   claude_oracle "Review this diff for security issues" < diff.patch
#   claude_oracle "Should we use WebSocket or SSE?" --model claude-opus-4-6
#
# Or as a command:
#   ./scripts/claude-oracle.sh "Your prompt here"
#
# Budget is tracked via CLAUDE_ORACLE_USED counter (in memory, per session).
# Set CLAUDE_ORACLE_BUDGET=0 to disable. Set CLAUDE_ORACLE_BUDGET=999 for unlimited.
#
# This script is designed to be sourced by other scripts (autoship, run-ship) or
# called directly by agents via bash.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load config if not already loaded
if [ -z "${PI_ENV_IS_VPS:-}" ]; then
  CONFIG_FILE="$PROJECT_DIR/.pi/config.sh"
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi
fi

# ── Budget check ──────────────────────────────────────────────────────────────
check_budget() {
  if [ "$CLAUDE_ORACLE_AVAILABLE" != "true" ]; then
    echo "⚠️  Claude Oracle not available (VPS or no OAuth session)" >&2
    return 1
  fi

  if [ "${CLAUDE_ORACLE_USED:-0}" -ge "${CLAUDE_ORACLE_BUDGET:-0}" ]; then
    echo "⚠️  Claude Oracle budget exhausted (${CLAUDE_ORACLE_USED:-0}/${CLAUDE_ORACLE_BUDGET:-0})" >&2
    return 1
  fi

  return 0
}

# ── Core function ─────────────────────────────────────────────────────────────
claude_oracle() {
  check_budget || return 1

  local prompt=""
  local model="${CLAUDE_ORACLE_MODEL:-claude-sonnet-4-20250514}"
  local extra_args=()

  # Parse args: first non-flag arg is the prompt, rest pass through
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|-m)
        model="$2"
        shift 2
        ;;
      --budget|-b)
        # Override budget for this call
        CLAUDE_ORACLE_BUDGET="$2"
        shift 2
        ;;
      --max-turns)
        extra_args+=("--max-turns" "$2")
        shift 2
        ;;
      --*)
        extra_args+=("$1")
        shift
        ;;
      *)
        prompt="$1"
        shift
        ;;
    esac
  done

  if [ -z "$prompt" ]; then
    echo "Usage: claude_oracle \"your prompt\" [--model MODEL] [--max-turns N]" >&2
    return 1
  fi

  # Increment counter
  CLAUDE_ORACLE_USED=$(((${CLAUDE_ORACLE_USED:-0} + 1)))
  export CLAUDE_ORACLE_USED

  local remaining=$((CLAUDE_ORACLE_BUDGET - CLAUDE_ORACLE_USED))

  echo "🔮 Claude Oracle [${CLAUDE_ORACLE_USED}/${CLAUDE_ORACLE_BUDGET}] (${remaining} remaining)" >&2
  echo "   Model: $model" >&2
  echo "   Prompt: ${prompt:0:80}..." >&2
  echo "" >&2

  # Call Claude Code
  claude -p "$prompt" \
    --model "$model" \
    "${extra_args[@]}"
}

# ── Convenience wrappers for strategic use cases ──────────────────────────────

# Final quality gate before merge
claude_oracle_security_review() {
  local diff="${1:-}"
  if [ -z "$diff" ]; then
    diff=$(git diff --cached 2>/dev/null || git diff 2>/dev/null || true)
  fi

  if [ -z "$diff" ]; then
    echo "No diff to review." >&2
    return 0
  fi

  echo "$diff" | claude_oracle \
    "You are a security reviewer. Analyze this diff for:
1. Security vulnerabilities (injection, auth bypass, data leaks)
2. Logic errors that could cause production incidents
3. Missing error handling or edge cases

Be harsh. Output format:
PASS — if clean
FAIL — if any issues found, list each with severity (CRITICAL/HIGH/MEDIUM/LOW) and file:line

Diff:
$(cat)"
}

# Architecture decision when stuck
claude_oracle_architecture() {
  local question="$1"
  local context="${2:-}"

  claude_oracle \
    "You are a senior architect. Give a clear, opinionated recommendation.

Question: $question

${context:+Context:}
${context:-}

Provide:
1. Your recommendation (pick ONE)
2. Why (3 bullets max)
3. Key tradeoff to watch for"
}

# Debug escalation after failed attempts
claude_oracle_debug() {
  local error="$1"
  local attempts="${2:-}"
  local files="${3:-}"

  claude_oracle \
    "This code has failed after $attempts attempts to fix it. Previous approaches did not work.

Error: $error

Files involved: $files

Provide:
1. Root cause analysis (most likely cause)
2. Fix approach (specific, not vague)
3. What to check if the fix doesn't work (fallback diagnostic)"
}

# Spec validation before implementation
claude_oracle_spec_review() {
  local spec_file="$1"

  if [ ! -f "$spec_file" ]; then
    echo "Spec file not found: $spec_file" >&2
    return 1
  fi

  claude_oracle \
    "Review this USVA spec for gaps before we implement it.

Check for:
1. Missing acceptance criteria (what's untestable?)
2. Missing edge cases (what breaks?)
3. RBAC blind spots (who shouldn't access this?)
4. Scope creep (what's out of scope but not stated?)
5. Ambiguity (what could be interpreted two ways?)

Spec:
$(cat "$spec_file")

Output: SPEC_VALID or SPEC_NEEDS_REVISION with specific items to fix."
}

# ── CLI mode (when called directly, not sourced) ──────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  claude_oracle "$@"
fi
