#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# validate-brief.sh — Validate a deliberation brief against required sections
# ──────────────────────────────────────────────────────────────────────────────
# Usage: ./scripts/validate-brief.sh <path-to-brief.md>
# Exit 0 if valid, exit 1 if missing sections (prints what's missing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BRIEF_PATH="${1:-}"

if [[ -z "$BRIEF_PATH" ]]; then
  echo "Usage: ./scripts/validate-brief.sh <path-to-brief.md>"
  exit 1
fi

if [[ ! -f "$BRIEF_PATH" ]]; then
  echo "❌ Brief not found: $BRIEF_PATH"
  exit 1
fi

# Required sections (case-insensitive matching)
REQUIRED_SECTIONS=(
  "## Situation"
  "## Stakes"
  "## Constraints"
  "## Key Question"
)

DESCRIPTIONS=(
  "What is happening right now? State the technical or product facts. No opinion."
  "What's at risk? What breaks if we get this wrong? What do we gain if we get it right?"
  "Timeline, team size, existing tech stack, budget, backwards compatibility requirements."
  "The single most important question you want the board to answer. Be specific."
)

BRIEF_CONTENT=$(cat "$BRIEF_PATH")
BRIEF_LOWER=$(echo "$BRIEF_CONTENT" | tr '[:upper:]' '[:lower:]')

MISSING=()
MISSING_DESC=()

for i in "${!REQUIRED_SECTIONS[@]}"; do
  section="${REQUIRED_SECTIONS[$i]}"
  section_lower=$(echo "$section" | tr '[:upper:]' '[:lower:]')
  if ! echo "$BRIEF_LOWER" | grep -q "$section_lower"; then
    MISSING+=("$section")
    MISSING_DESC+=("${DESCRIPTIONS[$i]}")
  fi
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
  echo "✅ Brief is valid: $BRIEF_PATH"
  echo "   All required sections present."
  exit 0
else
  echo "❌ Brief is missing required sections:"
  echo ""
  for i in "${!MISSING[@]}"; do
    echo "   ${MISSING[$i]}"
    echo "   → ${MISSING_DESC[$i]}"
    echo ""
  done
  echo "Add these sections to: $BRIEF_PATH"
  exit 1
fi
