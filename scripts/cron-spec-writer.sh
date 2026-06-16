#!/usr/bin/env bash
# cron-spec-writer.sh — v3 pattern
# Fetches issues labeled 'backlog' OR 'spec-hold', runs pi to produce a USVA
# spec for each, posts the spec as a GitHub comment, and labels the issue
# 'spec-ready'.
#
# Defense layers against empty commits:
#   Layer 1 — Prompt instructs agent to use `write` tool (not bash) and NOT commit
#   Layer 2 — Pre-commit guard verifies spec file exists before committing
#   Layer 3 — Post-run audit summarizes successes and failures

set -euo pipefail
export BASH_WHITELIST_MODE="log"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Auto-detect project root (works from any nesting level)
PROJECT_DIR="$(cd "$SCRIPT_DIR" && while [ "$(pwd)" != "/" ]; do [ -f ".pi/config.sh" ] && pwd && break; cd ..; done)"

CONFIG_FILE="$PROJECT_DIR/.pi/config.sh"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
else
  echo "ERROR: No .pi/config.sh found. Run setup first."
  exit 1
fi

# Derive REPO for gh CLI (owner/repo format)
REPO="${REPO:-$(echo "$PROJECT_REPO" | sed "s|https://github.com/||" | sed "s|\\.git$||")}"

# Auto-detect default branch (works for both main and master repos)
DEFAULT_BRANCH="$(git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || git -C "$PROJECT_DIR" remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo main)"

LOG_DIR="$PROJECT_DIR/logs/cron"
LOG_FILE="$LOG_DIR/spec-writer-$(date +%Y%m%d-%H%M%S).log"
MAX_ISSUES="${CRON_MAX_SPEC_ISSUES:-3}"
PI_TIMEOUT="${PI_TIMEOUT:-300}"  # 5 min default per issue

# Resolve binaries
PI_BIN="${PI_BIN:-$(command -v pi || echo "pi")}"
GH_BIN="${GH_BIN:-$(command -v gh)}"

# -- Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$PROJECT_DIR/specs/usva"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "========================================"
log "  SPEC WRITER CRON -- $(date)"
log "========================================"

cd "$PROJECT_DIR"

LOCKFILE="/tmp/cron-spec-writer-${PROJECT_NAME}.lock"
if [ -f "$LOCKFILE" ]; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "unknown")
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    log "[SKIP] cron already running (PID $LOCK_PID, lockfile at $LOCKFILE)"
    exit 0
  fi
  log "[STALE] Removing stale lockfile (PID $LOCK_PID no longer running)"
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# -- Fetch eligible issues ─────────────────────────────────────────────────────
# Per the 2026-06-09 policy change, spec-hold is no longer a blocking state.
# We use --search with GitHub's label:foo,bar syntax (comma = OR) to match
# issues labeled 'backlog' OR 'spec-hold'. The --search filter also excludes
# already-processed states. The jq filter below is kept as a defense-in-depth
# check against any issue that slips through.
log "Fetching issues labeled 'backlog' or 'spec-hold'..."

ISSUES=$("$GH_BIN" issue list \
  --repo "$REPO" \
  --state open \
  --search 'label:backlog,spec-hold -label:spec-ready -label:spec-approved -label:in-progress' \
  --json number,title,labels \
  --limit 50 \
  --jq '[.[] | select(
    (.labels | map(.name) | contains(["spec-ready"]) | not) and
    (.labels | map(.name) | contains(["spec-approved"]) | not) and
    (.labels | map(.name) | contains(["in-progress"]) | not)
  ) | .number] | .[]' 2>/dev/null)

if [ -z "$ISSUES" ]; then
  log "No eligible backlog issues found. Exiting."
  exit 0
fi

ISSUE_COUNT=$(echo "$ISSUES" | wc -l | tr -d ' ')
log "Found $ISSUE_COUNT issue(s) to process: $(echo "$ISSUES" | tr '\n' ' ')"

# Pre-flight: kill orphan pi processes from previous runs
ORPHANS=$(pgrep -f "pi.*--no-session" 2>/dev/null || true)
if [ -n "$ORPHANS" ]; then
  log "[CLEANUP] Killing orphan pi processes: $ORPHANS"
  echo "$ORPHANS" | xargs kill 2>/dev/null || true
  sleep 2
fi

# -- derive_slug() — converts an issue title to the expected spec filename ─
# Mirrors the agent's slug derivation heuristic from the prompt below. Used
# by Layer 2 to detect existing spec files (issue #179).
derive_slug() {
  local title="$1"
  local slug="$title"
  # Strip leading bracketed type prefixes: [IMPROVE], [BUG], [FEAT], [FOLLOWUP], [REFACTOR]
  slug=$(echo "$slug" | sed -E 's/^\[[^]]+\]\s*//')
  # Strip trailing parenthesised tags
  slug=$(echo "$slug" | sed -E 's/\s*\([^)]+\)\s*$//')
  # Lowercase, kebab-case
  slug=$(echo "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g')
  # Truncate to 80 chars
  slug="${slug:0:80}"
  # Drop trailing hyphen after truncation
  slug="${slug%-}"
  echo "$slug"
}

# -- Counters for post-run audit (Layer 3) ────────────────────────────────────
NEW_COUNT=0
VERIFIED_COUNT=0
FAIL_COUNT=0

# -- Process each issue ────────────────────────────────────────────────────────
for ISSUE_NUMBER in $ISSUES; do
  log "----------------------------------------"
  log "Processing issue #$ISSUE_NUMBER..."

  # Ensure specs directory exists (defensive)
  mkdir -p "$PROJECT_DIR/specs/usva"

  # Record timestamp before pi run to detect new files
  PRE_RUN_MARKER="$PROJECT_DIR/specs/usva/.pre-run-$ISSUE_NUMBER"
  touch "$PRE_RUN_MARKER"

  ISSUE_CONTENT=$("$GH_BIN" issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body,labels \
    --jq '"#\(.number // '"$ISSUE_NUMBER"') \(.title)\n\n\(.body)"' 2>&1) || {
    log "ERROR: Failed to fetch issue #$ISSUE_NUMBER. Skipping."
    rm -f "$PRE_RUN_MARKER"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  }

  log "Running pi spec writer on issue #$ISSUE_NUMBER..."

  # Heartbeat: log every 60s while pi is running
  HEARTBEAT_PID=""
  start_heartbeat() {
    local pid=$1
    local start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
      sleep 60
      local elapsed=$(( $(date +%s) - start ))
      log "[HEARTBEAT] pi still running after ${elapsed}s on issue #${ISSUE_NUMBER}"
    done
  }

  # Layer 1: Prompt instructs agent to use `write` tool and NOT commit
  # Uses --no-extensions with explicit -e flags for controlled tool access
  setsid timeout --kill-after=5 "$PI_TIMEOUT" "$PI_BIN" --no-extensions \
    -e .pi/extensions/subagent/index.ts \
    -e .pi/extensions/model-router/index.ts \
    -e .pi/extensions/github-tools/index.ts \
    -p "You are the spec writer for the ${PROJECT_NAME} codebase at $PROJECT_DIR.

Your task: create a USVA spec for GitHub issue #$ISSUE_NUMBER, then post it to GitHub and label the issue.

Issue content:
$(printf "%s" "$ISSUE_CONTENT")

Steps to execute:
1. Derive a CLEAN, HUMAN-READABLE feature slug from the issue title. The slug should be short and meaningful (max ~50 chars), not a verbose machine-generated one. Apply these rules in order:
   a. Strip leading type prefixes in brackets, e.g. '[IMPROVE]', '[BUG]', '[FEAT]', '[FOLLOWUP]', '[REFACTOR]'.
   b. Strip trailing type tags in brackets, e.g. 'for auto-ship pipeline', '(orchestration)'.
   c. Lowercase, kebab-case the remaining text.
   d. Drop connector words that don't aid uniqueness: 'into', 'for', 'the', 'a', 'an', 'to', 'of'.
   e. Keep the most identifying words (action verb + key noun phrase). Examples:
      - '[IMPROVE] Split Phase 0 (#5) into smaller shippable sub-issues for auto-ship pipeline' -> 'split-phase0-into-subissues' (NOT 'improve-split-phase-0-5-into-smaller-shippable-sub-issues-for-auto-ship-pipeline')
      - '[BUG] GitHub webhook delivering with tls internal error (500)' -> 'fix-github-webhook-tls-error'
      - '[FEAT] Add localbusiness JSONLD schema' -> 'add-localbusiness-jsonld-schema'
   f. The slug must be unique among files in specs/usva/. If a collision exists, append a disambiguator from the issue body.

2. Use the write tool (NOT bash) to create specs/usva/[slug].usva.md with the complete USVA spec covering:
   - User Story (As a... I want... So that...)
   - Validation Criteria (testable acceptance criteria)
   - Scope (in-scope, out-of-scope, dependencies)
   - Architecture Notes (implementation approach)
   Do NOT use bash cat/echo/heredoc for file creation. Use the write tool.

3. After writing, use the read tool to verify the file exists and contains all sections.
4. Post a comment on the issue with the spec content. Use the read tool to load the spec file you just wrote (you derived the slug in step 1, so you know the exact filename). Then post the content as a comment:
   Run bash: $GH_BIN issue comment $ISSUE_NUMBER --repo $REPO --body \"<the spec content you just read>\"

5. Do NOT commit the file yourself. The cron script handles git commit after verifying the file exists.

6. Label the issue spec-approved (auto-approved, no human gate required) and remove backlog:
   Run bash: $GH_BIN issue edit $ISSUE_NUMBER --repo $REPO --add-label 'spec-approved' --add-label 'spec-ready' --remove-label 'backlog'

7. Report: 'DONE: spec written for #$ISSUE_NUMBER -> specs/usva/[slug].usva.md'

Important: run autonomously to completion, do not ask for confirmation." 2>&1 &
  PI_PID=$!
  start_heartbeat $PI_PID &
  HEARTBEAT_PID=$!
  wait $PI_PID 2>/dev/null
  EXIT_CODE=$?
  if [ -n "$HEARTBEAT_PID" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
  fi

  if [ $EXIT_CODE -eq 124 ]; then
    log "[TIMEOUT] pi was killed after ${PI_TIMEOUT}s on issue #$ISSUE_NUMBER"
    pkill -f "pi.*--no-session.*$ISSUE_NUMBER" 2>/dev/null || true
  fi

  if [ $EXIT_CODE -eq 0 ]; then
    log "Issue #$ISSUE_NUMBER -- pi exited successfully"
  else
    log "Issue #$ISSUE_NUMBER -- pi exited with code $EXIT_CODE"
  fi

  # -- Layer 2: Pre-commit guard ------------------------------------------
  NEW_SPEC=""
  NEWER_SPECS=$(find "$PROJECT_DIR/specs/usva" -name '*.usva.md' -newer "$PRE_RUN_MARKER" -type f 2>/dev/null || true)
  if [ -n "$NEWER_SPECS" ]; then
    NEW_SPEC=$(echo "$NEWER_SPECS" | head -1)
  fi
  if [ -z "$NEW_SPEC" ]; then
    UNTRACKED=$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard -- 'specs/usva/*.usva.md' | head -1 || true)
    if [ -n "$UNTRACKED" ]; then
      NEW_SPEC="$PROJECT_DIR/$UNTRACKED"
    fi
  fi

  rm -f "$PRE_RUN_MARKER"

  # -- Layer 2: Three-tier pre-commit guard (issue #179) --------------------
  # Tier 1: NEW spec — find -newer detected a freshly created spec
  # Tier 2: EXISTING spec — find -newer empty, but specs/usva/<slug>.usva.md
  #         already exists on disk and is non-empty (issue reprocessed after
  #         spec was previously written). Counted as success; no commit needed.
  # Tier 3: NO SPEC — neither path matched, true failure.
  if [ -z "$NEW_SPEC" ]; then
    ISSUE_TITLE=$("$GH_BIN" issue view "$ISSUE_NUMBER" --repo "$REPO" --jq '.title' 2>/dev/null || true)
    if [ -n "$ISSUE_TITLE" ]; then
      EXPECTED_SLUG=$(derive_slug "$ISSUE_TITLE")
      EXPECTED_SPEC="$PROJECT_DIR/specs/usva/${EXPECTED_SLUG}.usva.md"
      if [ -f "$EXPECTED_SPEC" ] && [ -s "$EXPECTED_SPEC" ]; then
        # Tier 2: existing spec — verified success, skip commit
        log "[EXISTING] Spec already exists for issue #$ISSUE_NUMBER: $EXPECTED_SPEC"
        VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
        log "Issue #$ISSUE_NUMBER -- existing spec verified (no commit needed)"
        continue
      fi
      # AC4: spec file exists but is empty — still a failure
      if [ -f "$EXPECTED_SPEC" ] && [ ! -s "$EXPECTED_SPEC" ]; then
        log "[ERROR] Empty spec file for issue #$ISSUE_NUMBER: $EXPECTED_SPEC. Skipping commit."
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
      fi
    fi
    # Tier 3: no spec at all
    log "[ERROR] No spec file written for issue #$ISSUE_NUMBER. Skipping commit."
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  SPEC_SIZE=$(wc -c < "$NEW_SPEC" | tr -d ' ')
  if [ "$SPEC_SIZE" -eq 0 ]; then
    log "[ERROR] Spec file is empty (0 bytes) for issue #$ISSUE_NUMBER. Skipping commit."
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  git -C "$PROJECT_DIR" add "$NEW_SPEC"
  STAGED_FILES=$(git -C "$PROJECT_DIR" diff --cached --name-only)
  if [ -z "$STAGED_FILES" ]; then
    log "[ERROR] No files staged after git add for issue #$ISSUE_NUMBER. Skipping commit."
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  log "Spec file detected and staged: $NEW_SPEC ($SPEC_SIZE bytes)"
  git -C "$PROJECT_DIR" commit -m "feat: USVA spec for #$ISSUE_NUMBER"
  git -C "$PROJECT_DIR" push origin "$DEFAULT_BRANCH" 2>&1 || true
  NEW_COUNT=$((NEW_COUNT + 1))
  log "Issue #$ISSUE_NUMBER -- spec committed successfully"
done

# -- Layer 3: Post-run audit ──────────────────────────────────────────────────
SUCCESS_COUNT=$((NEW_COUNT + VERIFIED_COUNT))
log "========================================"
log "  SPEC WRITER CRON COMPLETE"
log "  Summary: $NEW_COUNT new, $VERIFIED_COUNT verified, $FAIL_COUNT failure(s)"
log "========================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
  log "[AUDIT] $FAIL_COUNT issue(s) failed (spec file not written to disk)."
  log "[AUDIT] Review logs above for write-tool failures."
fi
if [ "$VERIFIED_COUNT" -gt 0 ]; then
  log "[AUDIT] $VERIFIED_COUNT issue(s) had existing specs — verified, no new commit needed."
fi