#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# should-deliberate.sh — Determine if a feature should trigger board deliberation
# ──────────────────────────────────────────────────────────────────────────────
# Analyzes a feature description against complexity triggers from board-config.yaml.
# Returns exit 0 (should deliberate) or exit 1 (skip deliberation).
#
# Usage: ./scripts/should-deliberate.sh "Feature description"
#        ./scripts/should-deliberate.sh --brief specs/briefs/my-brief/brief.md
#
# Triggers (any one = deliberate):
#   - Feature touches >= 3 domains
#   - Introduces a new external dependency
#   - Changes data model, API contracts, or system boundaries
#   - Estimated implementation >= 5 days

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Parse input ──────────────────────────────────────────────────────────────

FEATURE_DESC=""
BRIEF_PATH=""

if [[ "${1:-}" == "--brief" ]]; then
  BRIEF_PATH="${2:-}"
  if [[ -n "$BRIEF_PATH" && -f "$BRIEF_PATH" ]]; then
    FEATURE_DESC=$(cat "$BRIEF_PATH")
  else
    echo "Brief not found: $BRIEF_PATH"
    exit 1
  fi
else
  FEATURE_DESC="${1:-}"
fi

if [[ -z "$FEATURE_DESC" ]]; then
  echo "Usage: ./scripts/should-deliberate.sh \"Feature description\""
  echo "       ./scripts/should-deliberate.sh --brief <path-to-brief.md>"
  exit 1
fi

# ─── Check auto_deliberate.enabled in board-config.yaml ──────────────────────

CONFIG_FILE="$REPO_ROOT/.pi/board-config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "⏭️ No board-config.yaml found — skipping deliberation"
  exit 1
fi

# Simple YAML check for enabled flag
if grep -A1 "auto_deliberate:" "$CONFIG_FILE" | grep -q "enabled: true"; then
  : # auto-deliberation is enabled
else
  echo "⏭️ Auto-deliberation disabled in board-config.yaml"
  exit 1
fi

# ─── Domain analysis ─────────────────────────────────────────────────────────

FEATURE_LOWER=$(echo "$FEATURE_DESC" | tr '[:upper:]' '[:lower:]')
DOMAINS_HIT=0

# Common software domains
DOMAIN_KEYWORDS=(
  "auth|authentication|authorization|login|session|jwt|oauth"
  "payment|billing|stripe|subscription|pricing"
  "api|endpoint|rest|graphql|rpc|webhook"
  "database|schema|migration|model|table|index"
  "ui|frontend|component|page|layout|css|style"
  "deploy|ci|cd|pipeline|docker|kubernetes|infrastructure"
  "security|encryption|cors|csrf|xss|injection"
  "notification|email|sms|push|webhook"
  "storage|file|upload|s3|blob|cdn"
  "realtime|websocket|sse|pubsub|event"
  "search|elasticsearch|algolia|full-text"
  "cache|redis|memcache|cdn"
  "test|e2e|integration|unit|playwright|jest"
  "monitoring|logging|metrics|alerting|observability"
)

for pattern in "${DOMAIN_KEYWORDS[@]}"; do
  if echo "$FEATURE_LOWER" | grep -qE "$pattern"; then
    DOMAINS_HIT=$((DOMAINS_HIT + 1))
  fi
done

# ─── Dependency check ────────────────────────────────────────────────────────

NEW_DEPENDENCY=false
if echo "$FEATURE_LOWER" | grep -qE "new (dependency|package|library|module)|install |add .*(dep|package)|npm install|bun add|pip install"; then
  NEW_DEPENDENCY=true
fi

# ─── Architecture change check ───────────────────────────────────────────────

ARCH_CHANGE=false
if echo "$FEATURE_LOWER" | grep -qE "migrat|refactor|rewrite|new (api|endpoint|service|microservice)|schema change|data model|break.*change|architecture|system (design|boundary)"; then
  ARCH_CHANGE=true
fi

# ─── Estimate check ─────────────────────────────────────────────────────────

LARGE_ESTIMATE=false
if echo "$FEATURE_LOWER" | grep -qE "[5-9] days|[1-9][0-9]+ days|week|sprint|major|large|complex|epic"; then
  LARGE_ESTIMATE=true
fi

# ─── Decision ─────────────────────────────────────────────────────────────────

REASONS=()

if [[ $DOMAINS_HIT -ge 3 ]]; then
  REASONS+=("Touches $DOMAINS_HIT domains (threshold: 3)")
fi
if [[ "$NEW_DEPENDENCY" == "true" ]]; then
  REASONS+=("Introduces new dependency")
fi
if [[ "$ARCH_CHANGE" == "true" ]]; then
  REASONS+=("Involves architecture change")
fi
if [[ "$LARGE_ESTIMATE" == "true" ]]; then
  REASONS+=("Large estimated effort")
fi

if [[ ${#REASONS[@]} -gt 0 ]]; then
  echo "🏛️ Board deliberation recommended:"
  for reason in "${REASONS[@]}"; do
    echo "   • $reason"
  done
  exit 0
else
  echo "⏭️ Complexity below threshold — skipping deliberation"
  echo "   Domains: $DOMAINS_HIT/3, Dependency: $NEW_DEPENDENCY, Arch: $ARCH_CHANGE, Large: $LARGE_ESTIMATE"
  exit 1
fi
