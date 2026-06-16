#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# build-context.sh — Pre-filters codebase context per specialist agent
# ──────────────────────────────────────────────────────────────────────────────
# Returns only the files and sections relevant to each agent's job.
#
# Usage:
#   ./scripts/build-context.sh <agent> <feature-slug> [usva-path]
#
# Agents: architect, implementer, reviewer, test-writer, debug-agent

set -euo pipefail

AGENT="${1:-}"
FEATURE_SLUG="${2:-}"
USVA_PATH="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load project config
source "$REPO_ROOT/.pi/config.sh"

if [ -z "$AGENT" ] || [ -z "$FEATURE_SLUG" ]; then
  echo "Usage: ./scripts/build-context.sh <agent> <feature-slug> [usva-path]"
  echo "Agents: architect, implementer, reviewer, test-writer, debug-agent, gate-skeptic"
  exit 1
fi

cd "$REPO_ROOT"

# ─── Helpers ──────────────────────────────────────────────────────────────────

extract_section() {
  local heading="$1"
  local file="$2"
  awk -v h="$heading" '
    $0 ~ "^## " h { found=1; print; next }
    found && /^## / { exit }
    found { print }
  ' "$file"
}

find_related_files() {
  local keyword="$1"
  local dir="$2"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    grep -rl "$keyword" "$dir" --include="*.ts" --include="*.tsx" --include="*.py" --include="*.js" 2>/dev/null | head -10
  fi
}

get_learnings() {
  local area="$1"
  if [ -f ".learnings/LEARNINGS.md" ]; then
    awk -v area="$area" '
      /^## \[LRN-/ { entry=""; collecting=1 }
      collecting { entry = entry "\n" $0 }
      collecting && /^---$/ {
        if (entry ~ "Area.*" area || entry ~ "Tags.*" area) {
          if (entry ~ "Status.*pending" || entry ~ "Priority.*high") {
            print entry
          }
        }
        collecting=0
      }
    ' .learnings/LEARNINGS.md 2>/dev/null | head -80
  fi
}

# ─── Agent-specific context ──────────────────────────────────────────────────

case "$AGENT" in

  architect)
    echo "=== CONTEXT FOR ARCHITECT: $FEATURE_SLUG ==="
    echo ""
    echo "--- AGENTS.md: Key rules ---"
    extract_section "Code Style" AGENTS.md 2>/dev/null | head -30
    extract_section "Key Architecture" AGENTS.md 2>/dev/null | head -20
    echo ""

    if [ -n "$SCHEMA_DIR" ] && [ -d "$SCHEMA_DIR" ]; then
      echo "--- Schema files ---"
      ls "$SCHEMA_DIR"/*.ts "$SCHEMA_DIR"/*.prisma "$SCHEMA_DIR"/*.py 2>/dev/null || true
      echo ""
      echo "--- Related schema content ---"
      for f in $(find_related_files "$FEATURE_SLUG" "$SCHEMA_DIR"); do
        echo "--- $f ---"
        head -60 "$f" 2>/dev/null
      done
    fi
    echo ""

    if [ -n "$AUTH_FILE" ] && [ -f "$AUTH_FILE" ]; then
      echo "--- Auth helper (exports) ---"
      grep "^export " "$AUTH_FILE" 2>/dev/null | head -20
    fi
    echo ""

    if [ -n "$FRONTEND_DIR" ] && [ -d "$FRONTEND_DIR" ]; then
      echo "--- Related frontend files ---"
      find_related_files "$FEATURE_SLUG" "$FRONTEND_DIR" | head -5
    fi
    echo ""

    if [ -n "$BACKEND_DIR" ] && [ -d "$BACKEND_DIR" ]; then
      echo "--- Related backend files ---"
      find_related_files "$FEATURE_SLUG" "$BACKEND_DIR" | head -10
    fi
    echo ""

    echo "--- Learnings (backend + schema) ---"
    get_learnings "backend"
    get_learnings "schema"
    echo ""

    if [ -n "$USVA_PATH" ] && [ -f "$USVA_PATH" ]; then
      echo "--- USVA spec ---"
      cat "$USVA_PATH"
    fi
    ;;

  implementer)
    echo "=== CONTEXT FOR IMPLEMENTER: $FEATURE_SLUG ==="
    echo ""
    echo "--- AGENTS.md: Hard rules ---"
    extract_section "Code Guardian" AGENTS.md 2>/dev/null | head -40
    extract_section "Key Architecture" AGENTS.md 2>/dev/null | head -20
    echo ""

    if [ -n "$AUTH_FILE" ] && [ -f "$AUTH_FILE" ]; then
      echo "--- Auth helper (usage pattern) ---"
      grep -A3 "^export " "$AUTH_FILE" 2>/dev/null | head -30
    fi
    echo ""

    echo "--- Learnings (backend + frontend) ---"
    get_learnings "backend"
    get_learnings "frontend"
    echo ""

    echo "--- Existing pattern example ---"
    if [ -n "$BACKEND_DIR" ] && [ -d "$BACKEND_DIR" ]; then
      EXAMPLE_FILE=$(find "$BACKEND_DIR" -name "*.ts" -o -name "*.py" 2>/dev/null | head -1)
      if [ -n "$EXAMPLE_FILE" ]; then
        echo "--- $EXAMPLE_FILE (first 50 lines) ---"
        head -50 "$EXAMPLE_FILE"
      fi
    fi
    ;;

  reviewer)
    echo "=== CONTEXT FOR REVIEWER ==="
    echo ""
    echo "--- AGENTS.md: Hard rules ---"
    extract_section "Code Guardian" AGENTS.md 2>/dev/null | head -40
    echo ""
    echo "--- Hard rules from config ---"
    for rule in "${HARD_RULES[@]}"; do
      echo "  - $rule"
    done
    echo ""
    echo "--- Git diff ---"
    git diff HEAD~1 --unified=3 2>/dev/null || git diff --cached --unified=3 2>/dev/null || echo "no diff available"
    echo ""
    echo "--- Learnings (review patterns) ---"
    get_learnings "review"
    echo ""
    echo "=== REMINDER: Apply ALL rules above to every file in the diff. ==="
    echo "Hard rules recap:"
    for rule in "${HARD_RULES[@]}"; do
      echo "  - $rule"
    done
    ;;

  test-writer)
    echo "=== CONTEXT FOR TEST-WRITER: $FEATURE_SLUG ==="
    echo ""
    if [ -n "$USVA_PATH" ] && [ -f "$USVA_PATH" ]; then
      echo "--- USVA spec (full) ---"
      cat "$USVA_PATH"
    fi
    echo ""
    echo "--- Existing test spec (format reference) ---"
    if [ -n "$TEST_SPEC_DIR" ] && [ -d "$TEST_SPEC_DIR" ]; then
      REFERENCE_SPEC=$(ls "$TEST_SPEC_DIR"/*.md "$TEST_SPEC_DIR"/*.ts "$TEST_SPEC_DIR"/*.spec.ts 2>/dev/null | head -1)
      if [ -n "$REFERENCE_SPEC" ]; then
        echo "--- $REFERENCE_SPEC ---"
        head -40 "$REFERENCE_SPEC"
      fi
    fi
    echo ""
    echo "--- Test runner config ---"
    echo "Test runner: $TEST_RUNNER"
    echo "Test command: $TEST_COMMAND"
    echo "Spec dir: $TEST_SPEC_DIR"
    echo ""
    echo "--- Learnings (tests + selectors) ---"
    get_learnings "tests"
    ;;

  debug-agent)
    echo "=== CONTEXT FOR DEBUG-AGENT: $FEATURE_SLUG ==="
    echo ""
    echo "--- Recent changes ---"
    git diff HEAD~1 --stat 2>/dev/null || echo "no diff available"
    echo ""
    echo "--- Learnings (recent fixes) ---"
    get_learnings "backend"
    get_learnings "frontend"
    get_learnings "tests"
    ;;

  gate-skeptic)
    echo "=== CONTEXT FOR GATE-SKEPTIC: $FEATURE_SLUG ==="
    echo ""
    echo "--- Git diff ---"
    git diff HEAD~1 --unified=3 2>/dev/null || git diff --cached --unified=3 2>/dev/null || echo "no diff available"
    echo ""
    echo "--- Files changed ---"
    git diff HEAD~1 --name-only 2>/dev/null || echo "no diff available"
    echo ""
    echo "--- Hard rules from config ---"
    for rule in "${HARD_RULES[@]}"; do
      echo "  - $rule"
    done
    echo ""
    echo "--- Verification commands ---"
    for cmd in "${VERIFY_COMMANDS[@]}"; do
      echo "  - $cmd"
    done
    echo ""
    echo "--- Learnings (review + recent fixes) ---"
    get_learnings "review"
    get_learnings "backend"
    get_learnings "frontend"
    ;;

  *)
    echo "Unknown agent: $AGENT"
    echo "Valid agents: architect, implementer, reviewer, test-writer, debug-agent, gate-skeptic"
    exit 1
    ;;
esac
