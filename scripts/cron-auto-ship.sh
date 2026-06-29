#!/usr/bin/env bash
# cron-auto-ship.sh
# Fetches ONE issue labeled spec-approved (auto-approved), runs the full /ship workflow
# (PM spec confirmed → architect → implementer + tests → reviewer → gates → PR),
# then labels the issue 'shipped'.
#
# Runs nightly (e.g. 10pm — 1h after spec-writer).
# One issue per run — ship is slow and needs full attention.
#
# ── Meta-action gate (#254, supplements #247) ─────────────────────────────────
# Defense-in-depth: even if cron-spec-writer.sh mis-tags a meta-action issue
# as spec-approved, this script re-checks for the same three signal classes
# (MG ACTION: title / CEO-cannot-do-this &c. body / out-of-scope|blocker|
# human-review label set) immediately before invoking the pi orchestrator.
# Matches are routed to the `human-review` label (NOT `blocker`), a DLQ
# entry is written so the issue is not retried in a tight loop, and the
# loop continues to the next candidate. See #254 (this issue), #247
# (parent meta-action-gate spec), #243 (the 2026-06-23 incident).

set -euo pipefail


# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Auto-detect project root (works from any nesting level)
export PROJECT_DIR="$(cd "$SCRIPT_DIR" && while [ "$(pwd)" != "/" ]; do [ -f ".pi/config.sh" ] && pwd && break; cd ..; done)"

# Load project config
source "$PROJECT_DIR/.pi/config.sh"


# Auto-detect default branch (works for both main and master repos)
export DEFAULT_BRANCH="$(cd "$PROJECT_DIR" && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo main)"

# Derive REPO for gh CLI (owner/repo format)
export REPO="${REPO:-$(echo "$PROJECT_REPO" | sed "s|https://github.com/||" | sed "s|\.git$||")}"
export BASH_WHITELIST_MODE="log"

LOG_DIR="$PROJECT_DIR/logs/cron"
LOG_FILE="$LOG_DIR/auto-ship-$(date +%Y%m%d-%H%M%S).log"

# ── DLQ (Dead Letter Queue) ────────────────────────────────────────────────────
DLQ_DIR="/root/.hermes/dlq"
DLQ_DEAD_DIR="$DLQ_DIR/dead"
DLQ_MAX_RETRIES=3  # After this many failures, move issue to spec-hold

# ── Check if an issue has exceeded max DLQ retries ────────────────────────────
check_dlq_retry_limit() {
  local issue_num="$1"
  local project_name="${PROJECT_NAME:-auto-ship}"
  # Count DLQ entries for this issue (filenames contain project-issue_number)
  local dlq_count=$(find "$DLQ_DIR" -maxdepth 1 -name "*-${project_name}-${issue_num}*" 2>/dev/null | wc -l)
  if [ "$dlq_count" -ge "$DLQ_MAX_RETRIES" ]; then
    log "[DLQ-LIMIT] Issue #$issue_num has $dlq_count failed attempts (limit: $DLQ_MAX_RETRIES). Moving to spec-hold."
    # Dual-removal (#216, #261): spec-writer adds BOTH spec-approved AND
    # spec-ready when approving a spec. Dequeue must clear every queue label
    # the query could match on, otherwise the issue re-enters the queue
    # under search eventual-consistency or future query-label migration (#215).
    # gh --remove-label is idempotent — safe on already-absent labels.
    "$GH_BIN" issue edit "$issue_num" --repo "$REPO" \
      --remove-label "spec-approved" \
      --remove-label "spec-ready" \
      --add-label "spec-hold" 2>/dev/null || true
    "$GH_BIN" issue comment "$issue_num" --repo "$REPO" --body "⚠️ Auto-ship paused: $dlq_count consecutive failures. Moved to \`spec-hold\`. Needs human review before re-queueing. Last errors in DLQ." 2>/dev/null || true
    # Move DLQ entries to dead folder
    for f in "$DLQ_DIR"/*-${project_name}-${issue_num}*; do
      [ -f "$f" ] && mv "$f" "$DLQ_DEAD_DIR/" 2>/dev/null || true
    done
    return 0  # Issue was handled (moved to hold)
  fi
  return 1  # Issue has not exceeded limit, can proceed
}

write_dlq() {
  local job_name="$1"
  local error_msg="$2"
  local issue_num="${3:-}"
  mkdir -p "$DLQ_DIR" "$DLQ_DEAD_DIR"
  local ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local dlq_ts=$(date -u +%Y-%m-%dT%H%M%S)
  local dlq_file="$DLQ_DIR/${dlq_ts}-${job_name}.json"
  # Avoid overwriting existing
  if [ -f "$dlq_file" ]; then
    dlq_file="$DLQ_DIR/${dlq_ts}-${job_name}-$$.json"
  fi
  cat > "$dlq_file" <<DQL_JSON
{
  "job_name": "$job_name",
  "timestamp": "$ts",
  "error": $(printf '%s' "$error_msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()[:1000]))'),
  "project": "${PROJECT_NAME:-unknown}",
  "issue_number": "${issue_num}",
  "repo": "${REPO:-unknown}",
  "provider_chain": [],
  "retry_count": 0,
  "last_attempt": "$ts",
  "log_file": "$LOG_FILE"
}
DQL_JSON
  log "DLQ entry written: $dlq_file"
}

# Resolve binaries — prefer config, fall back to PATH
PI_TIMEOUT="${PI_TIMEOUT:-1800}"  # 15 min default per issue (was 30 min; hanging subagents shouldn't burn that long)
PI_SUBAGENT_TIMEOUT_MS="${PI_SUBAGENT_TIMEOUT_MS:-600000}"  # 10 min per subagent call
PI_STEP_TIMEOUT="${PI_STEP_TIMEOUT:-300}"  # 5 min with no JSONL output → kill pi and report failure
export PI_SUBAGENT_TIMEOUT_MS  # propagate to pi orchestrator so child processes get killed faster
PI_BIN="${PI_BIN:-$(command -v pi)}"
export GH_BIN="${GH_BIN:-$(command -v gh)}"

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "════════════════════════════════════════"
log "  AUTO-SHIP CRON — $(date)"
log "════════════════════════════════════════"

cd "$PROJECT_DIR"

# ── Lockfile guard ──────────────────────────────────────────────────────────
# Atomic flock-based lock (fixes TOCTOU race, #205). The old guard was a
# non-atomic check-then-rm-then-write: overlapping cron ticks could all read
# an empty/stale lockfile and all proceed. flock -n acquires atomically or
# fails, and auto-releases on process exit (normal/SIGTERM/SIGINT/crash) — so no
# lockfile unlink-on-exit is needed (or wanted: unlinking mid-exit lets a later
# opener create a fresh inode and bypass this holder).
LOCKFILE="/tmp/cron-auto-ship-${PROJECT_NAME}.lock"
exec 201>>"$LOCKFILE"
if ! flock -n 201; then
  LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "unknown")
  log "[SKIP] cron already running (PID $LOCK_PID, lockfile at $LOCKFILE)"
  exit 0
fi
echo $$ > "$LOCKFILE"   # advisory diagnostic only; the lock is the kernel flock

# ── Cleanup trap: on any exit, return to master + remove in-progress label ──────
TRAPPED_ISSUE=""
STASH_CREATED=0   # set to 1 by recover_clean_state() when it stashes; restored by cleanup()
cleanup() {
  local EXIT_CODE=$?
  # Kill only THIS PROJECT'S orphan pi/timeout processes (not system-wide!)
  # Use PID tracking to avoid killing other projects' pi processes
  if [ -n "${PI_PID:-}" ]; then
    kill "$PI_PID" 2>/dev/null || true
    # Also kill the timeout wrapper if it exists
    local timeout_pid
    timeout_pid=$(ps -o ppid= -p "$PI_PID" 2>/dev/null | tr -d ' ')
    [ -n "$timeout_pid" ] && kill "$timeout_pid" 2>/dev/null || true
  fi
  # Kill step_timeout_watcher background for this script only
  if [ -n "${STEP_WATCHER_PID:-}" ]; then
    kill "$STEP_WATCHER_PID" 2>/dev/null || true
  fi
  if [ -n "${HEARTBEAT_PID:-}" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  sleep 1
  if [ $EXIT_CODE -ne 0 ] && [ -n "$TRAPPED_ISSUE" ]; then
    log "Cleanup trap: removing in-progress label from #$TRAPPED_ISSUE"
    "$GH_BIN" issue edit "$TRAPPED_ISSUE" --repo "$REPO" --remove-label "in-progress" 2>/dev/null || true
  fi
  # Always return to master with a clean tree for the next run
  if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$DEFAULT_BRANCH" ]; then
    git checkout "$DEFAULT_BRANCH" 2>/dev/null || true
  fi
  if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    git add .learnings/ 2>/dev/null && git commit -m "chore: learnings cleanup on exit" 2>/dev/null || true
    # NOTE: do NOT re-stash here — that orphaned a SECOND stash (issue #180).
    # recover_clean_state() stashed runtime state at start (STASH_CREATED=1);
    # we restore it via the single coordinated pop below instead of orphaning again.
  fi
  # Restore runtime-state stash created by recover_clean_state() (issue #180).
  # Pop on EVERY exit path (success / failure / timeout) so state files do not drift
  # into an unreachable stash. Best-effort: a conflict must never block lockfile removal.
  if [ "${STASH_CREATED:-0}" = "1" ]; then
    git stash pop 2>/dev/null || log "Warning: could not pop stash"
  fi
  # Lock auto-released by flock on process exit (#205). Do NOT unlink the
  # lockfile here — unlinking mid-exit lets a concurrent opener create a fresh
  # inode and bypass this holder. The flock on fd 201 is the source of truth.
}
trap cleanup EXIT

# ── Recovery: always land on master with a clean tree ───────────────────────────
recover_clean_state() {
  log "Recovering clean state..."

  # 1. If on a feature branch, commit any learnings then return to master
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]; then
    log "On branch '$CURRENT_BRANCH' — returning to master"

    # Commit .learnings if dirty (safe, never breaks anything)
    if ! git diff --quiet -- .learnings/ || ! git diff --cached --quiet -- .learnings/; then
      git add .learnings/ 2>/dev/null || true
      git commit -m "chore: learnings from previous auto-ship session" 2>/dev/null || true
      log "Committed dirty learnings on feature branch"
    fi

    git checkout "$DEFAULT_BRANCH" 2>/dev/null || { log "ERROR: could not checkout $DEFAULT_BRANCH"; exit 1; }
  fi

  # 2. On master — handle any remaining dirty files
  if ! git diff --quiet || ! git diff --cached --quiet; then
    # Commit .learnings if that's all that's dirty
    DIRTY_FILES=$(git diff --name-only; git diff --cached --name-only)
    ONLY_LEARNINGS=$(echo "$DIRTY_FILES" | grep -v "^\.learnings/" | wc -l | tr -d ' ')

    if [ "$ONLY_LEARNINGS" -eq 0 ]; then
      git add .learnings/
      git commit -m "chore: learnings from previous auto-ship session"
      log "Committed dirty learnings on master — tree now clean"
    else
      # Unknown dirty files — stash to preserve work, don't abort
      log "Stashing uncommitted changes to clean working tree..."
      git stash push -m "auto-ship-cron stash $(date +%Y%m%d-%H%M%S)"
      STASH_CREATED=1
      log "Stashed. Will pop on exit."
    fi
  fi

  # 3. Verify clean
  if ! git diff --quiet || ! git diff --cached --quiet; then
    log "ERROR: Could not recover clean state. git status:"
    git status
    exit 1
  fi

  log "Clean state confirmed on branch: $(git rev-parse --abbrev-ref HEAD)"
}

recover_clean_state

# ── Fix stuck in-progress labels from previous failed runs ────────────────────
STUCK_ISSUES=$("$GH_BIN" issue list --repo "$REPO" --label in-progress --state open --json number --jq '.[].number' 2>/dev/null || true)
if [ -n "$STUCK_ISSUES" ]; then
  log "[CLEANUP] Found stuck in-progress labels from previous runs, removing..."
  for STUCK_NUM in $STUCK_ISSUES; do
    log "[CLEANUP] Removing in-progress label from stale issue #$STUCK_NUM"
    "$GH_BIN" issue edit "$STUCK_NUM" --repo "$REPO" --remove-label "in-progress" 2>/dev/null || true
  done
fi

# ── Loop: ship all spec-approved issues in queue ───────────────────────────
SHIPPED_COUNT=0
SKIPPED_ISSUES=""  # Track DLQ-skipped issue numbers to prevent infinite loops
EXIT_CODE=0  # initialise so cleanup trap never sees unbound variable

while true; do
  log "Fetching next issue labeled spec-approved (auto-approved)..."

  export ISSUE_NUMBER=$("$GH_BIN" issue list \
    --repo "$REPO" \
    --label spec-approved \
    --state open \
    --json number,labels \
    --limit 10 \
    --jq '[.[] | select(
      (.labels | map(.name) | contains(["in-progress"]) | not) and
      (.labels | map(.name) | contains(["shipped"]) | not) and
      # spec-hold filter REMOVED 2026-06-09 per MG: no human review bottleneck
      (.labels | map(.name) | contains(["blocker"]) | not) and
      # human-review filter (#254): a meta-action issue that was routed by
      # cron-spec-writer.sh is never re-picked as a ship candidate.
      (.labels | map(.name) | contains(["human-review"]) | not)
    ) | .number] | first // empty' 2>/dev/null)

  if [ -z "$ISSUE_NUMBER" ]; then
    log "No more spec-approved issues in queue. Done. (Shipped: $SHIPPED_COUNT)"
    break
  fi

  # Check if this issue was already skipped (DLQ limit, label change failed, etc.)
  if echo " $SKIPPED_ISSUES " | grep -q " $ISSUE_NUMBER "; then
    log "Issue #$ISSUE_NUMBER was already skipped this run but the queue query still returns it. This should be unreachable (DLQ dequeue removes all queue labels — see #216). Stopping the loop to avoid burning cycles on rework."
    break
  fi

  log "Found issue #$ISSUE_NUMBER — starting ship workflow"
  TRAPPED_ISSUE="$ISSUE_NUMBER"

  # ── Skip issues that have exceeded DLQ retry limit ────────────────────────
  if check_dlq_retry_limit "$ISSUE_NUMBER"; then
    log "Skipping issue #$ISSUE_NUMBER — exceeded DLQ retry limit, moved to spec-hold"
    SKIPPED_ISSUES="$SKIPPED_ISSUES $ISSUE_NUMBER"
    TRAPPED_ISSUE=""
    continue
  fi

  # Pre-flight: kill orphan pi and timeout processes from previous runs
  ORPHANS=$(pgrep -f "pi.*--no-session" 2>/dev/null || true)
  TIMEOUT_ORPHANS=$(pgrep -f "timeout.*pi" 2>/dev/null || true)
  if [ -n "$ORPHANS" ] || [ -n "$TIMEOUT_ORPHANS" ]; then
    log "[CLEANUP] Killing orphan processes: pi=$ORPHANS timeout=$TIMEOUT_ORPHANS"
    for PID in $ORPHANS $TIMEOUT_ORPHANS; do
      # Only kill processes from this project directory
      PID_CWD=$(readlink -f /proc/$PID/cwd 2>/dev/null || echo "")
      if [ "$PID_CWD" = "$PROJECT_DIR" ] || [ -z "$PID_CWD" ]; then
        kill "$PID" 2>/dev/null || true
      fi
    done
    sleep 2
  fi

  # Mark in-progress immediately so concurrent runs don't double-pick.
  # Defense-in-depth for VC-7 (#205): the outer flock (top of this script) now
  # serializes the whole ship loop, so only ONE run ever reaches selection — the
  # select-then-claim TOCTOU window that let 2 runs both pick #196 has collapsed.
  # This claim stays as belt-and-suspenders for any future bypass.
  "$GH_BIN" issue edit "$ISSUE_NUMBER" --repo "$REPO" --add-label "in-progress" 2>&1 || true

  # ── Load learnings context ──────────────────────────────────────────────────
  LEARNINGS_FILE="$PROJECT_DIR/.learnings/LEARNINGS.md"
  if [ -f "$LEARNINGS_FILE" ]; then
    export LEARNINGS_SNIPPET=$(tail -80 "$LEARNINGS_FILE")
  else
    export LEARNINGS_SNIPPET="No learnings file found."
  fi

  # ── Fetch issue + spec ──────────────────────────────────────────────────────
  export ISSUE_CONTENT=$("$GH_BIN" issue view "$ISSUE_NUMBER" --repo "$REPO" \
    --json number,title,body --jq '"#\(.number) \(.title)\n\n\(.body)"' 2>&1)

  export ISSUE_TITLE=$("$GH_BIN" issue view "$ISSUE_NUMBER" --repo "$REPO" \
    --json title --jq '.title' 2>&1)

  # Derive slug from title (strip prefix, kebab-case)
  export FEATURE_SLUG=$(echo "$ISSUE_TITLE" \
    | sed 's/^feat: //;s/^fix: //;s/^refactor: //;s/^chore: //' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g;s/--*/-/g;s/^-//;s/-$//' \
    | cut -c1-50)

  log "Issue: $ISSUE_TITLE"
  log "Slug:  $FEATURE_SLUG"

  # ── Meta-action pre-flight gate (#254) ──────────────────────────────────────
  # Defense-in-depth: re-check the same three signal classes from
  # cron-spec-writer.sh (MG ACTION: title / CEO-cannot-do-this &c. body /
  # out-of-scope|blocker|human-review label set) immediately before the pi
  # orchestrator is invoked. Matches are routed to `human-review` (NOT
  # `blocker`), spec-approved is removed, a DLQ entry is written so the
  # issue does not enter a tight retry loop, and the loop continues to the
  # next candidate. Idempotent: an already-correctly-labelled human-review
  # issue short-circuits before any label churn (no DLQ, no transition).
  # See #254.
  AUTO_SHIP_META_REASON=""
  # Signal 1: title matches /^MG ACTION:/i
  if echo "$ISSUE_TITLE" | grep -qiE '^MG ACTION:'; then
    AUTO_SHIP_META_REASON="title matches /MG ACTION:/i"
  fi
  # Signal 2: body matches a meta-action phrase (case-insensitive)
  if [ -z "$AUTO_SHIP_META_REASON" ] && \
     echo "$ISSUE_CONTENT" | grep -qiE 'CEO cannot do this|requires MG decision|DATA PROTECTION RULE'; then
    AUTO_SHIP_META_REASON="body matches meta-action phrase (CEO cannot do this / requires MG decision / DATA PROTECTION RULE)"
  fi
  # Signal 3: fetch labels once and inspect. human-review on the label set
  # is the IDEMPOTENT no-op state (already correctly routed by the
  # spec-writer layer — skip without DLQ). out-of-scope is a regression
  # marker (a spec-writer bug — fire the gate + DLQ + transition).
  AUTO_SHIP_LABELS=$("$GH_BIN" issue view "$ISSUE_NUMBER" --repo "$REPO" \
    --json labels --jq '.labels[].name' 2>/dev/null | tr '\n' ' ' || echo "")
  if [ -z "$AUTO_SHIP_META_REASON" ] && echo "$AUTO_SHIP_LABELS" | grep -qw 'human-review'; then
    log "[PREFLIGHT-NOOP] issue #$ISSUE_NUMBER already labelled human-review — no transition, no DLQ (idempotent)"
    SKIPPED_ISSUES="$SKIPPED_ISSUES $ISSUE_NUMBER"
    TRAPPED_ISSUE=""
    continue
  fi
  if [ -z "$AUTO_SHIP_META_REASON" ] && echo "$AUTO_SHIP_LABELS" | grep -qw 'out-of-scope'; then
    AUTO_SHIP_META_REASON="issue labelled out-of-scope"
  fi

  if [ -n "$AUTO_SHIP_META_REASON" ]; then
    log "[PREFLIGHT-BLOCK] issue #$ISSUE_NUMBER: $AUTO_SHIP_META_REASON — downgrading to human-review and writing DLQ entry"
    "$GH_BIN" issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --remove-label "in-progress" \
      --remove-label "spec-approved" \
      --remove-label "spec-ready" \
      --add-label "human-review" 2>/dev/null || true
    "$GH_BIN" issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "🛑 Auto-ship pre-flight detected meta-action issue ($AUTO_SHIP_META_REASON). Downgraded to \`human-review\`. Ship aborted before pi orchestrator. See #254." 2>/dev/null || true
    write_dlq "cron-auto-ship-meta-action" "$AUTO_SHIP_META_REASON (issue #$ISSUE_NUMBER; spec-writer regression or mis-tag)" "$ISSUE_NUMBER" 2>/dev/null || true
    SKIPPED_ISSUES="$SKIPPED_ISSUES $ISSUE_NUMBER"
    TRAPPED_ISSUE=""
    continue
  fi

  # ── Ship model (configurable via config.sh) ─────────────────────────────────
  SHIP_PROVIDER="${CRON_SHIP_PROVIDER:-anthropic}"
  SHIP_MODEL="${CRON_SHIP_MODEL:-claude-sonnet-4-5}"
  SHIP_MODEL_SECONDARY="${CRON_SHIP_MODEL_SECONDARY:-}"

  # ── Pre-flight model health check ────────────────────────────────────────────
  # CRON_SHIP_HEALTH_URL (env var) controls pre-flight probe. Empty = skip (relying on pi error reporting).
  # The retired :9099 failover proxy (issue #1370) was removed 2026-06-15.
  check_model_health() {
    local model="$1"
    local health_url="${CRON_SHIP_HEALTH_URL:-}"
    if [ -z "$health_url" ]; then
      log "[HEALTH] No CRON_SHIP_HEALTH_URL set — skipping pre-flight probe (pi will report errors itself)"
      return 0
    fi
    local max_retries=3
    local retry=0
    while [ $retry -lt $max_retries ]; do
      local http_code
      http_code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$health_url" 2>/dev/null || echo "000")
      if [ "$http_code" = "200" ]; then
        log "[HEALTH] Provider reachable (HTTP $http_code) — model: $model"
        return 0
      fi
      retry=$((retry + 1))
      log "[HEALTH] Provider unreachable (HTTP $http_code), retry ${retry}/${max_retries}..."
      sleep 5
    done
    log "[HEALTH] Provider failed all ${max_retries} checks"
    return 1
  }

  if ! check_model_health "$SHIP_MODEL"; then
    if [ -n "$SHIP_MODEL_SECONDARY" ]; then
      log "[FALLBACK] Primary model proxy unreachable, switching to secondary: $SHIP_MODEL_SECONDARY"
      SHIP_MODEL="$SHIP_MODEL_SECONDARY"
    else
      log "[SKIP] Model proxy unreachable and no secondary model configured — skipping issue #$ISSUE_NUMBER"
      "$GH_BIN" issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "in-progress" 2>/dev/null || true
      "$GH_BIN" issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "⚠️ Auto-ship skipped: model proxy unreachable after 3 retries and no fallback model configured." 2>/dev/null || true
      continue
    fi
  fi

  # ── Run the ship workflow via pi --mode json ─────────────────────────────────
  log "Launching pi orchestrator..."

  # Record HEAD before pi runs. The post-run ship verification (Check 3 below)
  # compares this to the HEAD after pi exits to detect a direct commit to the
  # default branch (fix-on-main). Without this, a successful direct-to-main
  # commit reports SHIP_VERIFIED=false → bogus DLQ + "Shipped: 0" (issue #184).
  PRE_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")

  # JSONL output file for incremental progress capture
  PI_OUTPUT_FILE="$LOG_DIR/pi-output-$ISSUE_NUMBER.jsonl"
  : > "$PI_OUTPUT_FILE"

  # ── Parse pi JSONL status for heartbeat ─────────────────────────────────────
  parse_pi_jsonl_status() {
    local jsonl_file="$1"
    local last_n="${2:-50}"
    if [ ! -f "$jsonl_file" ] || [ ! -s "$jsonl_file" ]; then
      echo "no output yet"
      return
    fi
    # Check file modification time — if stale, report STALLED
    local now=$(date +%s)
    local mtime=$(stat -c %Y "$jsonl_file" 2>/dev/null || stat -f %m "$jsonl_file" 2>/dev/null || echo "$now")
    local stale_s=$(( now - mtime ))
    # Parse pi JSONL status via a bounded TAIL read (VC-2): never slurp the whole
    # file (a 475MB GLM output would be loaded into RAM every tick). Seek to EOF,
    # read the last 256KB, scan for event types. GLM-dominant thinking events are
    # recognized (VC-1); oversized lines are truncated, not failed (VC-3).
    # pi --mode json events: tool_execution_start (toolName, args),
    # message_end (usage), thinking/thinking_delta/message_update (GLM thinking).
    local parsed
    parsed=$(python3 -c "
jsonl_file = '$jsonl_file'
last_n = $last_n

import json, os

TAIL_BYTES = 262144   # 256KB tail window — bounds memory/time (VC-2)
LINE_MAX = 65536      # 64KB — oversized lines skip full json.loads (VC-3)

size = 0
window = ''
try:
    with open(jsonl_file, 'rb') as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        fh.seek(max(0, size - TAIL_BYTES), os.SEEK_SET)
        window = fh.read().decode('utf-8', errors='replace')
except Exception:
    pass   # leave window empty — handled by the empty-window fallback below

window_lines = window.splitlines()
# Drop the leading partial line when we did not start reading from offset 0
if size > TAIL_BYTES and window_lines:
    window_lines = window_lines[1:]
# Honor last_n: only the last N candidate lines of the window
window_lines = window_lines[-last_n:]

def get_type(line):
    # Universal, size-independent type extraction (VC-3). Uses chr(34) for the
    # double-quote char to stay safe inside the bash "..." wrapper string.
    if len(line) <= LINE_MAX:
        try:
            return json.loads(line).get('type', '')
        except Exception:
            pass
    dq = chr(34)
    needle = dq + 'type' + dq
    i = line.find(needle)
    if i < 0:
        return ''
    rest = line[i + len(needle):].lstrip(': \t')
    if not rest or rest[0] != dq:
        return ''
    end = rest.find(dq, 1)
    return rest[1:end] if end > 0 else ''

def line_obj(line):
    # Full payload only for normal-sized lines; oversized lines are almost
    # always thinking/thinking_delta with no tool/usage payload we need.
    if len(line) <= LINE_MAX:
        try:
            return json.loads(line)
        except Exception:
            return {}
    return {}

phase = ''
last_tool = ''
tokens_in = 0
tokens_out = 0
turn_count = 0
thinking_count = 0   # GLM-dominant types keep thinking-heavy runs visible (VC-1)
events_seen = 0      # any line we successfully typed

for line in window_lines:
    line = line.strip()
    if not line:
        continue
    etype = get_type(line)
    if etype:
        events_seen += 1
    # GLM/thinking-heavy event types (VC-1)
    if etype == 'thinking' or etype == 'thinking_delta' or etype == 'message_update':
        thinking_count += 1
    # Tool / phase / token events — preserved unchanged for compact models (VC-5)
    if etype == 'tool_execution_start':
        d = line_obj(line)
        last_tool = d.get('toolName', last_tool)
        args = d.get('args', {}) or {}
        agent = args.get('agent', '')
        if agent:
            phase = agent
    if etype == 'message_end':
        d = line_obj(line)
        usage = d.get('message', {}).get('usage', {}) or {}
        ti = usage.get('input', 0) or usage.get('input_tokens', 0) or 0
        to = usage.get('output', 0) or usage.get('output_tokens', 0) or 0
        if isinstance(ti, int): tokens_in += ti
        if isinstance(to, int): tokens_out += to
        turn_count += 1
    if etype == 'turn_end':
        turn_count += 1
    if etype == 'agent_end':
        phase = (phase + ' (DONE)') if phase else 'DONE'

parts = []
if phase: parts.append('Phase: ' + phase)
if last_tool: parts.append('Tool: ' + last_tool)
if turn_count: parts.append('Turns: ' + str(turn_count))
if tokens_in or tokens_out: parts.append('Tokens: ' + str(tokens_in) + 'in/' + str(tokens_out) + 'out')
if thinking_count: parts.append('Thinking: ' + str(thinking_count))

if parts:
    print(' | '.join(parts))
elif events_seen == 0:
    # Tail window had zero parseable JSON lines — file just started or mid-write (VC-4)
    print('running (no parseable events yet)')
else:
    # File is non-empty/growing but no recognized or thinking types surfaced (VC-4)
    print('running (' + str(events_seen) + ' events in tail)')
" 2>/dev/null || echo "parse error")
    # If file hasn't been modified for >120s, report STALLED regardless of parsed content
    if [ "$stale_s" -gt 120 ]; then
      echo "STALLED (no new events for ${stale_s}s) [${parsed}]"
      return
    fi
    echo "$parsed"
  }

  # Start heartbeat monitor (with JSONL progress) — runs in background, uses sentinel file
  HEARTBEAT_PID=""
  HEARTBEAT_SENTINEL="/tmp/pi-done-${ISSUE_NUMBER}-$$"

  start_heartbeat() {
    local sentinel="$1"
    local start_ts=$(date +%s)
    local last_output_mtime=""
    local stall_warning_logged=0
    while [ ! -f "$sentinel" ]; do
      sleep 60
      local elapsed=$(( $(date +%s) - start_ts ))
      local status
      status=$(parse_pi_jsonl_status "$PI_OUTPUT_FILE" 10)
      log "[HEARTBEAT] pi running ${elapsed}s on issue #${TRAPPED_ISSUE} — $status"
      # Track JSONL file modification time for stall detection
      if [ -f "$PI_OUTPUT_FILE" ]; then
        local current_mtime=$(stat -c %Y "$PI_OUTPUT_FILE" 2>/dev/null || stat -f %m "$PI_OUTPUT_FILE" 2>/dev/null || echo "0")
        if [ -n "$last_output_mtime" ] && [ "$current_mtime" = "$last_output_mtime" ]; then
          local output_stale_s=$(( $(date +%s) - current_mtime ))
          if [ "$output_stale_s" -ge 180 ] && [ "$stall_warning_logged" -eq 0 ]; then
            log "[HEARTBEAT] WARNING: No new pi output for ${output_stale_s}s on issue #${TRAPPED_ISSUE} — process may be stalled"
            stall_warning_logged=1
          fi
        else
          # File was updated, reset stall tracking
          last_output_mtime="$current_mtime"
          stall_warning_logged=0
        fi
      fi
    done
  }

  # Start heartbeat in background BEFORE pi
  start_heartbeat "$HEARTBEAT_SENTINEL" &
  HEARTBEAT_PID=$!

  # Step-timeout watcher: kill pi if no JSONL output for PI_STEP_TIMEOUT seconds
  # On timeout: try fallback model once before giving up
  step_timeout_watcher() {
    local jsonl_file="$1"
    local step_timeout="$2"
    local sentinel="$3"
    local fallback_model="$4"
    local fallback_provider="$5"
    local last_size=0
    local last_change=$(date +%s)
    while [ ! -f "$sentinel" ]; do
      sleep 10
      if [ -f "$sentinel" ]; then break; fi
      local current_size=0
      if [ -f "$jsonl_file" ]; then
        current_size=$(stat -c %s "$jsonl_file" 2>/dev/null || stat -f %z "$jsonl_file" 2>/dev/null || echo "0")
      fi
      local now=$(date +%s)
      if [ "$current_size" != "$last_size" ]; then
        last_size="$current_size"
        last_change="$now"
      elif [ $(( now - last_change )) -ge "$step_timeout" ]; then
        log "[STEP-TIMEOUT] No new JSONL output for ${step_timeout}s — killing pi process"
        # Kill only our own pi process (not system-wide!)
        if [ -n "${PI_PID:-}" ]; then
          kill "$PI_PID" 2>/dev/null || true
        fi
        # Kill the timeout wrapper parent of our pi process
        pkill -P $$ "timeout" 2>/dev/null || true
        # Signal heartbeat to stop so the main loop doesn't keep running
        touch "$sentinel" 2>/dev/null || true
        # If fallback model available, record it for main loop to retry
        if [ -n "$fallback_model" ]; then
          echo "${fallback_provider}:${fallback_model}" > /tmp/pi-fallback-$$ 2>/dev/null || true
          log "[STEP-TIMEOUT] Fallback model available: ${fallback_provider}/${fallback_model}"
        fi
        return
      fi
    done
  }
  # Derive fallback model from CRON_SHIP_MODEL_SECONDARY or hardcode sensible default
  FALLBACK_MODEL="${CRON_SHIP_MODEL_SECONDARY:-glm-5.2}"
  FALLBACK_PROVIDER="${CRON_SHIP_PROVIDER_SECONDARY:-zai}"
  step_timeout_watcher "$PI_OUTPUT_FILE" "$PI_STEP_TIMEOUT" "$HEARTBEAT_SENTINEL" "$FALLBACK_MODEL" "$FALLBACK_PROVIDER" &
  STEP_WATCHER_PID=$!

  _RUN_START=$(date +%s)
  timeout --kill-after=5 "$PI_TIMEOUT" "$PI_BIN" --no-extensions -e .pi/extensions/subagent/index.ts -e .pi/extensions/model-router/index.ts -e .pi/extensions/github-tools/index.ts --mode json --no-session \
    --provider "$SHIP_PROVIDER" \
    --model "$SHIP_MODEL" \
    "$(cat <<'PI_PROMPT' | envsubst \
      '${PROJECT_NAME} ${PROJECT_DIR} ${ISSUE_NUMBER} ${ISSUE_TITLE} ${ISSUE_CONTENT} ${FEATURE_SLUG} ${LEARNINGS_SNIPPET} ${DEFAULT_BRANCH} ${REPO} ${GH_BIN}'
You are the ship orchestrator for the ${PROJECT_NAME} codebase at $PROJECT_DIR.

Your job: execute the full ship workflow for GitHub issue #$ISSUE_NUMBER end-to-end.
'Done' is defined by run-ship.sh passing all gates — not by you.

## Issue
$ISSUE_CONTENT

## Feature slug
$FEATURE_SLUG

## Injected learnings (apply to every specialist agent)
$LEARNINGS_SNIPPET

## Critical active warnings
- Schema migrations: new fields on populated tables MUST be optional first
- No .filter() after .withIndex() — use compound indexes
- Test files: zero any, zero eslint-disable — use as unknown as T patterns
- git stash + verify clean tree BEFORE running run-ship.sh

---

## Workflow to execute

IMPORTANT: Do NOT close the GitHub issue yourself. The PR will auto-close it when merged (via 'Closes #N' in the PR description). Never run `gh issue close`.

### Phase 1 — Read the confirmed USVA spec
Run bash to find the spec: find specs/usva -name '*${FEATURE_SLUG}*' 2>/dev/null
If found, read it. If not found, use the issue content directly as the spec.
USVA spec path (likely): specs/usva/${FEATURE_SLUG}.usva.md

### Phase 2 — Architect
Use the subagent tool:
- agent: architect
- agentScope: project
- confirmProjectAgents: false
- cwd: $PROJECT_DIR
- task: Read the confirmed USVA spec and produce a complete implementation plan. USVA spec path: specs/usva/${FEATURE_SLUG}.usva.md. Feature slug: ${FEATURE_SLUG}. Run: ./scripts/build-context.sh architect "${FEATURE_SLUG}" "specs/usva/${FEATURE_SLUG}.usva.md". Learnings to apply: $LEARNINGS_SNIPPET

### Phase 3+4 — Test writer + Implementer (PARALLEL)
Use the subagent tool in parallel mode (tasks array):

1. agent: unit-test-writer
   task: Write fully typed unit tests for ${FEATURE_SLUG}. USVA spec: specs/usva/${FEATURE_SLUG}.usva.md. Zero any. Zero eslint-disable. Use as unknown as T patterns. Paste architect plan + learnings.

2. agent: implementer
   task: Execute the implementation plan exactly. USVA spec: specs/usva/${FEATURE_SLUG}.usva.md. Feature slug: ${FEATURE_SLUG}. Run: ./scripts/build-context.sh implementer "${FEATURE_SLUG}". Paste full architect plan and learnings.

### Phase 4.5 — UI Review (frontend changes only)
Check if the diff contains any frontend file changes:
Run bash: git diff "$DEFAULT_BRANCH"...HEAD --name-only | grep -E '\.tsx$|\.css$' | head -5

If frontend files changed, use the subagent tool:
- agent: ui-reviewer
- agentScope: project
- confirmProjectAgents: false
- task: Review this frontend diff for UI quality, responsive design, mobile UX, and design system compliance. Feature slug: ${FEATURE_SLUG}. Run: ./scripts/build-context.sh reviewer "${FEATURE_SLUG}"

If ui-reviewer returns UI FAIL, delegate fixes back to implementer with the specific findings, then re-run ui-reviewer. Max 2 rounds.
If no frontend files changed, skip this phase.

### Phase 5 — Reviewer loop (max 3 rounds)
Use the subagent tool in chain mode: reviewer then implementer (if FAIL) then reviewer again.
Stop when reviewer returns PASS.
reviewer task: Review the diff against project rules. Return PASS or FAIL. Feature slug: ${FEATURE_SLUG}. Run: ./scripts/build-context.sh reviewer "${FEATURE_SLUG}". Learnings: $LEARNINGS_SNIPPET

### Phase 6 — Run the gates
BEFORE running gates:
1. Commit all changes: git add -A && git commit -m "feat: [feature name] — closes #${ISSUE_NUMBER}"
2. Stash check: git stash then git stash pop if nothing to stash
3. Verify: git status must be clean except untracked
4. Run: ./scripts/run-ship.sh "${ISSUE_TITLE}"

IMPORTANT (#194): run-ship.sh branches from origin/${DEFAULT_BRANCH} and replays your
local commit as a NEW commit, so the PR always has a diff vs ${DEFAULT_BRANCH}. For
this to work your commit must be AHEAD of origin/${DEFAULT_BRANCH} locally. Do NOT run
`git push` on ${DEFAULT_BRANCH} yourself — pushing the "closes #N" commit lands the
fix directly on ${DEFAULT_BRANCH} (auto-closing the issue) AND makes the feature
branch identical to ${DEFAULT_BRANCH}, so Gate 6 fails with "No commits between
main and feature". Commit locally, then let run-ship.sh open the PR.

If a gate fails, delegate to debug-agent:
- agent: debug-agent
- task: Fix gate failure. Gate: [N] — [name]. Failure: [paste output]. Feature slug: ${FEATURE_SLUG}. Run: ./scripts/build-context.sh debug-agent "${FEATURE_SLUG}"
Max 2 debug attempts per gate.

### Phase 7 — Label shipped
LABELS ARE ALREADY CLEANED UP BY cron-auto-ship.sh THE MOMENT IT CONFIRMS
SHIP_VERIFIED=true (see the success-path cleanup block — issue #261).
This section is documentation only. Do NOT re-run `gh issue edit` to add
`shipped` / remove `spec-approved` / `spec-ready` / `in-progress` here —
the script has already done it. If the script says "Dequeueing issue
#${ISSUE_NUMBER}" in the log, that is your confirmation.
Do NOT close the issue — the PR will auto-close it on merge (Closes #N in
the PR description / commit message handles that).

### Phase 8 — Capture out-of-scope ideas
During implementation, the architect, implementer, and reviewer may surface ideas, edge cases, or adjacent improvements that are out of scope for this issue. Capture each one as a GitHub issue and label it backlog so it enters the next cron cycle.

For each idea, run bash using ./scripts/create-issue.sh with flags: --type enhancement, --found-during set to the current issue title and number, plus --location, --symptom, --context, --affects. All flag values must be shell-quoted strings. After creating each issue, immediately run: ${GH_BIN} issue edit [new-number] --repo ${REPO} --add-label backlog

If no ideas surfaced, skip this phase.

### Phase 9 — Log learnings
Use the subagent tool:
- agent: learning-agent
- agentScope: project
- confirmProjectAgents: false
- task: Mode: session-end. Log this cron-auto-ship session. Feature: ${ISSUE_TITLE} (#${ISSUE_NUMBER}). Run via: cron-auto-ship.sh

### Final report
Print a summary:
- Issue: #${ISSUE_NUMBER} — ${ISSUE_TITLE}
- PR: [URL]
- Gates: all passed / [which failed + fixed]
- Status: SHIPPED or FAILED

Important: use confirmProjectAgents: false in ALL subagent calls.
Do not ask for confirmation at any step — run autonomously to completion.
PI_PROMPT
  )" > "$PI_OUTPUT_FILE" 2>"$LOG_DIR/pi-stderr-$ISSUE_NUMBER.log" &
  PI_PID=$!
  wait $PI_PID 2>/dev/null && EXIT_CODE=0 || EXIT_CODE=$?

  # ── Fallback retry: if step-timeout fired and a fallback model was recorded ──
  FALLBACK_FILE="/tmp/pi-fallback-$$"
  if [ -f "$FALLBACK_FILE" ]; then
    FALLBACK_INFO=$(cat "$FALLBACK_FILE" 2>/dev/null)
    rm -f "$FALLBACK_FILE"
    if [ -n "$FALLBACK_INFO" ]; then
      FALLBACK_PROV="${FALLBACK_INFO%%:*}"
      FALLBACK_MOD="${FALLBACK_INFO#*:}"
      log "[FALLBACK-RETRY] Step-timeout fired on primary model. Retrying once with: ${FALLBACK_PROV}/${FALLBACK_MOD}"
      "$GH_BIN" issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "in-progress" 2>/dev/null || true
      rm -f "$HEARTBEAT_SENTINEL" 2>/dev/null || true
      : > "$PI_OUTPUT_FILE"
      SHIP_PROVIDER="$FALLBACK_PROV"
      SHIP_MODEL="$FALLBACK_MOD"

      HEARTBEAT_SENTINEL="/tmp/pi-done-${ISSUE_NUMBER}-$$"
      start_heartbeat "$HEARTBEAT_SENTINEL" &
      HEARTBEAT_PID=$!
      step_timeout_watcher "$PI_OUTPUT_FILE" "$PI_STEP_TIMEOUT" "$HEARTBEAT_SENTINEL" "" "" &
      STEP_WATCHER_PID=$!

      timeout --kill-after=5 "$PI_TIMEOUT" "$PI_BIN" --no-extensions \
        -e .pi/extensions/subagent/index.ts \
        -e .pi/extensions/model-router/index.ts \
        -e .pi/extensions/github-tools/index.ts \
        --mode json --no-session \
        --provider "$SHIP_PROVIDER" \
        --model "$SHIP_MODEL" \
        "$(cat <<'PI_PROMPT_RETRY' | envsubst \
          '${PROJECT_NAME} ${PROJECT_DIR} ${ISSUE_NUMBER} ${ISSUE_TITLE} ${ISSUE_CONTENT} ${FEATURE_SLUG} ${LEARNINGS_SNIPPET} ${DEFAULT_BRANCH} ${REPO} ${GH_BIN} ${FALLBACK_MOD}'
RETRY: The primary model timed out. This is a fallback attempt with model ${FALLBACK_MOD}.
You are the ship orchestrator for the ${PROJECT_NAME} codebase at $PROJECT_DIR.
Your job: execute the full ship workflow for GitHub issue #$ISSUE_NUMBER end-to-end.
## Issue
$ISSUE_CONTENT
## Feature slug
$FEATURE_SLUG
## Injected learnings
$LEARNINGS_SNIPPET
## Workflow
Follow the standard ship workflow: spec to architect to implementer+tests to reviewer to gates to PR.
Use confirmProjectAgents: false in ALL subagent calls. Run autonomously to completion.
PI_PROMPT_RETRY
      )" > "$PI_OUTPUT_FILE" 2>>"$LOG_DIR/pi-stderr-$ISSUE_NUMBER.log" &
      PI_PID=$!
      wait $PI_PID 2>/dev/null && EXIT_CODE=0 || EXIT_CODE=$?
      touch "$HEARTBEAT_SENTINEL" 2>/dev/null || true
      kill "$HEARTBEAT_PID" 2>/dev/null || true
      kill "$STEP_WATCHER_PID" 2>/dev/null || true
      rm -f "$HEARTBEAT_SENTINEL" 2>/dev/null || true
      log "[FALLBACK-RETRY] Fallback attempt completed with exit code $EXIT_CODE"
    fi
  fi

  # Signal heartbeat and step-timeout watcher to stop (sentinel file)
  touch "$HEARTBEAT_SENTINEL" 2>/dev/null || true

  # Kill heartbeat and step-timeout watcher on pi exit (safety net — sentinel should stop them naturally)
  if [ -n "$HEARTBEAT_PID" ]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  if [ -n "$STEP_WATCHER_PID" ]; then
    kill "$STEP_WATCHER_PID" 2>/dev/null || true
  fi
  rm -f "$HEARTBEAT_SENTINEL" 2>/dev/null || true

  # ── Extract final response from JSONL ──────────────────────────────────────
  PI_FINAL_TEXT_FILE="$LOG_DIR/pi-final-$ISSUE_NUMBER.txt"
  if [ -f "$PI_OUTPUT_FILE" ] && [ -s "$PI_OUTPUT_FILE" ]; then
    # Extract text from the last 'message' or 'result' event in the JSONL
    # pi --mode json emits events: message (with content), usage, tool_call, etc.
    # The final response text is in the last message event's content field.
    python3 -c '
import json, sys
final_text = ""
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        # message events have content arrays
        if d.get("type") == "message" or d.get("role") in ("assistant",):
            content = d.get("content", [])
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        final_text = block.get("text", final_text)
            elif isinstance(content, str):
                final_text = content
        # result events
        if "result" in d and isinstance(d["result"], str):
            final_text = d["result"]
        # fallback: text field at top level
        if "text" in d and isinstance(d["text"], str) and d.get("type","") != "tool_call":
            final_text = d["text"]
    except (json.JSONDecodeError, KeyError):
        continue
if final_text:
    print(final_text)
' "$PI_OUTPUT_FILE" > "$PI_FINAL_TEXT_FILE" 2>/dev/null || true
    if [ -s "$PI_FINAL_TEXT_FILE" ]; then
      log "Final pi response saved to $PI_FINAL_TEXT_FILE ($(wc -l < "$PI_FINAL_TEXT_FILE") lines)"
    else
      # Fallback: just log that JSONL was captured even if text extraction failed
      log "JSONL output captured at $PI_OUTPUT_FILE ($(wc -l < "$PI_OUTPUT_FILE") lines)"
    fi
  fi

  # Handle timeout exit code 124
  if [ $EXIT_CODE -eq 124 ]; then
    RUN_START="${_RUN_START:-$(date +%s)}"
    TOTAL_RUNTIME=$(( $(date +%s) - RUN_START ))
    log "[TIMEOUT] pi was killed after ${PI_TIMEOUT}s on issue #$ISSUE_NUMBER (total runtime: ${TOTAL_RUNTIME}s)"
    # Log last known status from JSONL before it was killed
    if [ -f "$PI_OUTPUT_FILE" ]; then
      LAST_STATUS=$(parse_pi_jsonl_status "$PI_OUTPUT_FILE" 20)
      log "[TIMEOUT] Last status before timeout: $LAST_STATUS"
      log "[TIMEOUT] JSONL output preserved at $PI_OUTPUT_FILE"
    else
      LAST_STATUS="unknown (no output file)"
    fi
    # Log stderr if captured
    STDERR_FILE="$LOG_DIR/pi-stderr-$ISSUE_NUMBER.log"
    if [ -f "$STDERR_FILE" ] && [ -s "$STDERR_FILE" ]; then
      log "[TIMEOUT] Last 20 lines of stderr:"
      tail -20 "$STDERR_FILE" >> "$LOG_FILE" 2>/dev/null || true
    fi
    # Kill any surviving child processes — use PID tracking to avoid cross-project kills
    if [ -n "${PI_PID:-}" ]; then
      kill "$PI_PID" 2>/dev/null || true
    fi
    # Also check for orphan pi processes within this project directory only
    for PID in $(pgrep -f "pi.*--no-session" 2>/dev/null || true); do
      PID_CWD=$(readlink -f /proc/$PID/cwd 2>/dev/null || echo "")
      if [ "$PID_CWD" = "$PROJECT_DIR" ]; then
        kill "$PID" 2>/dev/null || true
      fi
    done
    # Remove in-progress label on timeout cleanup
    "$GH_BIN" issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "in-progress" 2>/dev/null || true
    # Write timeout error summary to DLQ
    LAST_LINES=""
    if [ -f "$PI_OUTPUT_FILE" ]; then
      LAST_LINES=$(tail -5 "$PI_OUTPUT_FILE" 2>/dev/null || echo "(could not read)")
    fi
    TIMEOUT_SUMMARY="TIMEOUT after ${PI_TIMEOUT}s (total runtime: ${TOTAL_RUNTIME}s). Phase: ${LAST_STATUS}. Last JSONL lines: ${LAST_LINES}"
    log "[TIMEOUT] $TIMEOUT_SUMMARY"
    write_dlq "${PROJECT_NAME:-auto-ship}-$ISSUE_NUMBER" "$TIMEOUT_SUMMARY" "$ISSUE_NUMBER"
  fi

  # ── Verify actual ship success (not just pi exit code 0) ──────────────
  # Pi exits 0 even when model fails after auto-retry. Check for real evidence.
  SHIP_VERIFIED=false
  if [ $EXIT_CODE -eq 0 ]; then
    # Check if pi created a PR referencing this issue
    PR_CHECK=$("$GH_BIN" pr list --repo "$REPO" --state open --search "$ISSUE_NUMBER" --json number --jq ".[0].number" 2>/dev/null || echo "")
    if [ -n "$PR_CHECK" ]; then
      log "Issue #$ISSUE_NUMBER shipped successfully — PR #$PR_CHECK"
      SHIP_VERIFIED=true
    else
      # Check if any new commits exist on feature branches
      NEW_COMMITS=$(git log "$DEFAULT_BRANCH"..HEAD --oneline 2>/dev/null | wc -l)
      if [ "$NEW_COMMITS" -gt 0 ] 2>/dev/null; then
        log "Issue #$ISSUE_NUMBER shipped successfully — $NEW_COMMITS commits"
        SHIP_VERIFIED=true
      fi
    fi
  fi

  # ── Check 3: HEAD advanced during the run (pi committed directly to main) ──
  # When pi pushes directly to the default branch (fix-on-main) instead of
  # opening a PR, Checks 1 & 2 above both fail: no PR exists, and
  # `git log main..HEAD` is empty because HEAD IS main. Comparing the HEAD
  # recorded before pi launched (PRE_HEAD) to the current HEAD detects the
  # commit. Fixes issue #184.
  if [ $EXIT_CODE -eq 0 ] && [ "$SHIP_VERIFIED" != true ]; then
    POST_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$PRE_HEAD" ] && [ -n "$POST_HEAD" ] && [ "$PRE_HEAD" != "$POST_HEAD" ]; then
      log "Issue #$ISSUE_NUMBER shipped successfully — HEAD advanced ($PRE_HEAD → $POST_HEAD, direct push to $DEFAULT_BRANCH)"
      SHIP_VERIFIED=true
    fi
  fi

  # ── Check 4: issue auto-closed during the run (closes #N keyword) ─────────
  # A successful fix-on-main commit carries a "closes #N" keyword that GitHub
  # auto-applies on push, closing the issue mid-run. A closed issue is
  # unambiguous evidence the ship landed — strong backstop if the HEAD
  # comparison above was somehow defeated (e.g. PRE_HEAD read too late).
  if [ $EXIT_CODE -eq 0 ] && [ "$SHIP_VERIFIED" != true ]; then
    ISSUE_STATE=$("$GH_BIN" issue view "$ISSUE_NUMBER" --repo "$REPO" --json state --jq ".state" 2>/dev/null || echo "")
    if [ "$ISSUE_STATE" = "CLOSED" ]; then
      log "Issue #$ISSUE_NUMBER shipped successfully — auto-closed during run (state: CLOSED)"
      SHIP_VERIFIED=true
    fi
  fi

  if [ "$SHIP_VERIFIED" = true ]; then
    SHIPPED_COUNT=$((SHIPPED_COUNT + 1))
    # ── Dequeue the shipped issue (issue #261) ─────────────────────────────────
    # The pi subagent previously ran Phase 7 itself — delegated to a
    # long-running subprocess that could crash / time out / run out of
    # context BEFORE applying the label transition. That left the issue
    # carrying spec-approved (queue-matching) + in-progress + spec-ready,
    # so the next cron iteration re-picked the already-shipped issue and
    # burned a 30-minute compute budget per orphan. The script owns the
    # queue (it runs `--label spec-approved` at line ~249) so the script
    # must also own the dequeue. Idempotent (gh --remove-label on an
    # absent label is a no-op), so safe even if pi ALSO runs the same
    # cleanup redundantly. spec-writer adds BOTH spec-approved and
    # spec-ready when approving — remove both, forward-compatible with
    # #215's queue-label migration.
    log "Dequeueing issue #$ISSUE_NUMBER — shipped label applied"
    "$GH_BIN" issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --add-label shipped \
      --remove-label spec-approved \
      --remove-label spec-ready \
      --remove-label in-progress 2>/dev/null || true
  else
    log "Issue #$ISSUE_NUMBER — pi exited with code $EXIT_CODE"
    "$GH_BIN" issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "in-progress" 2>&1 || true
    log "Removed in-progress label — issue will retry on next run"
    # Write to DLQ so the reaper can retry later
    ERROR_SUMMARY="pi exited with code $EXIT_CODE"
    write_dlq "${PROJECT_NAME:-auto-ship}-$ISSUE_NUMBER" "$ERROR_SUMMARY" "$ISSUE_NUMBER"
  fi

  TRAPPED_ISSUE=""

  # Reset clean state between issues before fetching the next one
  recover_clean_state

done  # ── end queue loop

log "════════════════════════════════════════"
log "  AUTO-SHIP CRON COMPLETE — Shipped: $SHIPPED_COUNT"
log "════════════════════════════════════════"

exit $EXIT_CODE
