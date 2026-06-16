#!/usr/bin/env bash
# scripts/ship.sh — invoke the /ship pipeline correctly
#
# Background:
#   pi has no slash-command system. `pi -p "/ship ..."` sends literal text
#   to the LLM, which then ignores .pi/prompts/ship.md. This wrapper
#   injects ship.md as a system prompt so the orchestrator rules actually bind.
#
# Usage:
#   scripts/ship.sh "<feature description>"
#
# See: .ralph/harness-hardening.md "Phase 4 Findings" for the diagnosis.

set -euo pipefail

PROMPT_FILE="$(dirname "$0")/../.pi/prompts/ship.md"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "error: ship prompt not found at $PROMPT_FILE" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  echo "usage: $0 \"<feature description>\"" >&2
  exit 2
fi

pi -p --append-system-prompt "$(cat "$PROMPT_FILE")" "Ship: $*"
