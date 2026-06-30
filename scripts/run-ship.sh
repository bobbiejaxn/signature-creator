#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# run-ship.sh — Hard-enforcement orchestrator for the /ship workflow
# ──────────────────────────────────────────────────────────────────────────────
# Each gate runs as a deterministic shell check. The agent cannot self-report
# past a gate that hasn't actually passed.
#
# Usage:
#   ./scripts/run-ship.sh "Feature Name"
#
# Gates:
#   1. Git worktree isolation
#   2. Static checks (from config VERIFY_COMMANDS)
#   3. Dev log capture (exits 1 if real errors)
#   4. E2E feature test (max 2 attempts)
#   5. P0 regression suite (max 2 attempts)
#   6. Open PR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load config
source "$REPO_ROOT/.pi/config.sh"

# Default branch (main or master) — used as the PR base and as the trunk the
# feature branch is rebased onto (#194). Detected once; mirrors cron-auto-ship.sh.
DEFAULT_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || git -C "$REPO_ROOT" remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}' || echo main)"

# ── Lockfile guard: defense-in-depth against concurrent orchestrators (#205, #236) ──
# autoship.sh + cron-auto-ship.sh already serialize the outer loops with atomic
# flock locks, but run-ship.sh previously had NO lock of its own, so a bypassed
# outer guard could let two orchestrators collide on git commit / gh pr create /
# the git index. This atomic flock guard makes that impossible.
#
# Stale-lock reaper (#236): the simple flock block auto-releases on process exit
# (normal/SIGTERM/SIGINT/crash) for the PARENT. But when the orchestrator spawns
# the dev server (npm run dev → sh -c → node → next-server), the child inherits
# the open FD 202 holding the flock via shell FD inheritance. If the parent is
# then killed (SIGKILL during Gate 4 capture-dev-logs, OOM, system reboot,
# kill -9 from cron-spec-writer etc.), the children still hold FD 202 open and
# the kernel cannot release the flock until every FD closes. The lock is held
# indefinitely by an orphan child, and every subsequent run-ship.sh invocation
# prints "SKIP run-ship already running" and exits 0 — wedging the pipeline
# until a human runs lsof /proc/*/fd/202 and kill the orphan (as happened on #229).
#
# Fix: after flock -n fails, inspect (a) the PID the lockfile claims to hold,
# (b) the lockfile mtime, and (c) the configured RUN_SHIP_LOCK_TTL_SECONDS
# threshold (default 1800s = 30 min, see .pi/config.sh). If the holder PID is
# dead AND the mtime exceeds the TTL, log a "reaped stale lock" line, re-open
# FD 202 on the lockfile, re-acquire flock -n, and proceed. Otherwise keep the
# existing skip-and-exit-0 behavior — VC-2: never steal from a live holder.
#
# Do NOT unlink the lockfile on exit (unlinking mid-exit lets a later opener
# create a fresh inode and bypass this holder). PROJECT_NAME comes from the
# sourced config.sh.

# ── Recovery: stale run-ship lock wedged by orphan dev-server ──
# If you see "SKIP run-ship already running" but the holder PID is dead and
# the lock is held by an orphan (npm → sh → node → next-server) that inherited
# FD 202, run the diagnostic + kill commands below BEFORE waiting for the TTL
# to elapse. Diagnostic:
#
#   cat /tmp/run-ship-${PROJECT_NAME}.lock                            # holder PID
#   ps -o pid,ppid,etime,cmd -p <PID>                                 # confirm PPID=1 (orphan)
#   lsof /proc/*/fd/202 2>/dev/null                                   # all FDs holding the lock
#   ls -l /proc/<PID>/fd/202 2>/dev/null                              # confirm orphan holds FD 202
#
# Kill (graceful first; SIGKILL only if unresponsive):
#
#   kill <orphan PID>                                                 # graceful
#   kill -9 <orphan PID>                                              # last resort
#
# Then re-run run-ship.sh. The #467 reap-orphan reaper will also recover
# automatically once the lockfile mtime exceeds RUN_SHIP_LOCK_TTL_SECONDS
# (default 1800s = 30 min) AND it will kill any orphan process still holding
# FD 202 on the lockfile — see VC-1 of the #467 USVA spec. If you cannot
# wait for the TTL to elapse, the manual recovery commands above still apply.

# Helper functions MUST be defined BEFORE the lock guard so the stale-lock
# reaper can call warn/fail/info without "command not found" (latent bug
# fixed by #467: functions were previously defined AFTER the guard, so any
# actual reaper execution printed `warn: command not found` instead of the
# diagnostic message).
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_gate() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  GATE $1: $2${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

pass() { echo -e "${GREEN}  ✓ $1${NC}"; }
fail() { echo -e "${RED}  ✗ $1${NC}"; }
warn() { echo -e "${YELLOW}  ! $1${NC}"; }
info() { echo -e "${BLUE}  → $1${NC}"; }

RUN_SHIP_LOCKFILE="/tmp/run-ship-${PROJECT_NAME}.lock"
exec 202>>"$RUN_SHIP_LOCKFILE"
if ! flock -n 202; then
  RUN_SHIP_PID=$(cat "$RUN_SHIP_LOCKFILE" 2>/dev/null || echo "unknown")
  # ── Stale-lock decision (#236, #467) ──
  # Gate on (a) PID liveness — never steal from a live holder (VC-2) — and
  # (b) lockfile mtime vs the configured TTL. If both conditions hold (holder
  # is dead AND mtime exceeds TTL), the #467 reap-orphan reaper walks
  # /proc/*/fd/202 (or `lsof -t <lockfile>`) to find every PID still holding
  # FD 202 on the lockfile, sends SIGTERM with a bounded grace window,
  # escalates to SIGKILL on unresponsive processes, then closes the
  # orchestrator's stale FD 202, opens a fresh FD on the lockfile inode,
  # and re-acquires `flock -n 202`. This is required because the kernel
  # flock is held until every FD referencing the open file description
  # closes — the orchestrator closing its own FD does NOT release the
  # orphan's inherited FD, so without killing the orphan(s) the new
  # `flock -n 202` keeps failing (the original #236 symptom).
  RUN_SHIP_HOLDER_ALIVE=false
  if [ -n "$RUN_SHIP_PID" ] && [ "$RUN_SHIP_PID" != "unknown" ] \
     && kill -0 "$RUN_SHIP_PID" 2>/dev/null; then
    RUN_SHIP_HOLDER_ALIVE=true
  fi
  RUN_SHIP_LOCK_MTIME=$(stat -c %Y "$RUN_SHIP_LOCKFILE" 2>/dev/null || stat -f %m "$RUN_SHIP_LOCKFILE" 2>/dev/null || echo 0)
  RUN_SHIP_NOW=$(date +%s)
  RUN_SHIP_LOCK_AGE=$(( RUN_SHIP_NOW - RUN_SHIP_LOCK_MTIME ))
  if [ "$RUN_SHIP_HOLDER_ALIVE" = false ] \
     && [ "$RUN_SHIP_LOCK_AGE" -gt "${RUN_SHIP_LOCK_TTL_SECONDS:-1800}" ]; then
    warn "Stale run-ship lock detected: holder=$RUN_SHIP_PID (dead), age=${RUN_SHIP_LOCK_AGE}s, ttl=${RUN_SHIP_LOCK_TTL_SECONDS:-1800}s — reaping orphan FDs (#467)"
    # Enumerate orphan PIDs still holding FD 202 on the lockfile. Prefer
    # lsof for clarity; fall back to /proc/*/fd walk if lsof is missing
    # (VC-9: /proc is always available on Linux; lsof is the nicer path).
    RUN_SHIP_ORPHAN_PIDS=""
    if command -v lsof >/dev/null 2>&1; then
      RUN_SHIP_ORPHAN_PIDS=$(lsof -t "$RUN_SHIP_LOCKFILE" 2>/dev/null | tr '\n' ' ' || true)
    else
      warn "[#467] lsof not found — falling back to /proc/*/fd walk (install util-linux / lsof for nicer diagnostics)"
      for fd_link in /proc/[0-9]*/fd/*; do
        [ -L "$fd_link" ] || continue
        target=$(readlink "$fd_link" 2>/dev/null || true)
        case "$target" in
          socket:*) continue ;;
        esac
        if [ "$target" = "$RUN_SHIP_LOCKFILE" ]; then
          pid=$(echo "$fd_link" | awk -F/ '{print $3}')
          RUN_SHIP_ORPHAN_PIDS="$RUN_SHIP_ORPHAN_PIDS $pid"
        fi
      done
      RUN_SHIP_ORPHAN_PIDS=$(echo "$RUN_SHIP_ORPHAN_PIDS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    fi
    # Filter out the dead holder PID itself (kill -0 already returned non-zero
    # for it — kill would be a no-op, but the loop is cleaner without it) AND
    # the current orchestrator's PID (`$$` — the script's own bash process,
    # which holds the FD 202 it just opened for flock -n 202 and must NOT be
    # killed, otherwise the reaper would kill its own parent shell). Also
    # filter out any PID that is already dead (VC-6: idempotent under
    # concurrent invocation).
    RUN_SHIP_ORPHAN_KILL_GRACE_SECONDS="${RUN_SHIP_ORPHAN_KILL_GRACE_SECONDS:-5}"
    for orphan_pid in $RUN_SHIP_ORPHAN_PIDS; do
      [ -n "$orphan_pid" ] || continue
      [ "$orphan_pid" = "$RUN_SHIP_PID" ] && continue
      [ "$orphan_pid" = "$$" ] && continue
      if kill -0 "$orphan_pid" 2>/dev/null; then
        warn "Sending SIGTERM to orphan PID $orphan_pid holding FD 202 (grace=${RUN_SHIP_ORPHAN_KILL_GRACE_SECONDS}s) (#467)"
        kill "$orphan_pid" 2>/dev/null || true
        _reap_wait=0
        while [ "$_reap_wait" -lt "$RUN_SHIP_ORPHAN_KILL_GRACE_SECONDS" ] && kill -0 "$orphan_pid" 2>/dev/null; do
          sleep 1
          _reap_wait=$(( _reap_wait + 1 ))
        done
        if kill -0 "$orphan_pid" 2>/dev/null; then
          warn "Orphan PID $orphan_pid did not exit within ${RUN_SHIP_ORPHAN_KILL_GRACE_SECONDS}s — escalating to SIGKILL (#467)"
          kill -9 "$orphan_pid" 2>/dev/null || true
          sleep 1
        else
          pass "Orphan PID $orphan_pid exited after ${_reap_wait}s (#467)"
        fi
      fi
    done
    # Re-open the lockfile on a fresh FD and re-acquire. With all orphan
    # FDs now closed, `flock -n 202` on a fresh FD can succeed atomically.
    exec 202>&- 2>/dev/null || true
    exec 202>>"$RUN_SHIP_LOCKFILE"
    if ! flock -n 202; then
      fail "Could not re-acquire run-ship lock after reaping stale holder from PID $RUN_SHIP_PID — orphan chain may include a process we cannot kill (PID 1 / kernel-owned); inspect /proc/$RUN_SHIP_PID/fd/202 (#467)"
      exit 1
    fi
    pass "Reaped stale run-ship lock after killing orphan FD-holders; acquired fresh flock (#467)"
  else
    echo "  SKIP run-ship already running (PID $RUN_SHIP_PID, age=${RUN_SHIP_LOCK_AGE}s, holder_alive=${RUN_SHIP_HOLDER_ALIVE}) — exiting to avoid git/PR collision (#205)"
    exit 0
  fi
fi
echo $$ > "$RUN_SHIP_LOCKFILE"   # advisory diagnostic only; the lock is the kernel flock

FEATURE_NAME="${1:-}"
ISSUE_NUMBER="${2:-}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
FEATURE_SLUG=$(echo "$FEATURE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
BRANCH_NAME="feature/${FEATURE_SLUG}-${TIMESTAMP}"
WORKTREE_PATH="${WORKTREE_PREFIX}-${FEATURE_SLUG}-${TIMESTAMP}"

WORKTREE_CREATED=false
PHASE_REACHED=0

cleanup() {
  if [ "$WORKTREE_CREATED" = true ] && [ -d "$WORKTREE_PATH" ]; then
    info "Cleaning up worktree at $WORKTREE_PATH"
    cd "$REPO_ROOT"
    git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
    git branch -D "$BRANCH_NAME" 2>/dev/null || true
  fi
}

abort() {
  echo ""
  fail "ABORTED at Gate $PHASE_REACHED: $1"
  echo ""
  echo "The agent's work is in: $WORKTREE_PATH"
  echo "Branch: $BRANCH_NAME"
  WORKTREE_CREATED=false
  exit 1
}

# ─── preflight_fleet_policy_check — Fleet-wide policy compliance scan ────────
# Walks all repos under ${FLEET_POLICY_FLEET_BASE:-/root/projects/active} and
# greps for the pipe-delimited patterns in FLEET_POLICY_PATTERNS inside the
# files listed in FLEET_POLICY_TARGET_FILES. Prints a warning if any repo
# contains a non-compliant match. NEVER blocks the pipeline — the operator
# decides whether to proceed. Opt-in via FLEET_POLICY_CHECK=true.
#
# Use case: applied to fleet-wide policy changes (e.g. spec-hold, auto-approve)
# where a single repo update can silently leak across the other 18 repos.
#
# Config (in .pi/config.sh):
#   FLEET_POLICY_CHECK=true                 # enable
#   FLEET_POLICY_PATTERNS="spec-hold|..."   # pipe-delimited regex
#   FLEET_POLICY_FLEET_BASE=/root/projects/active
#   FLEET_POLICY_TARGET_FILES=(scripts/cron-spec-writer.sh scripts/cron-auto-ship.sh scripts/autoship.sh)
preflight_fleet_policy_check() {
  # Opt-in gate (VC-4)
  if [[ "${FLEET_POLICY_CHECK:-false}" != "true" ]]; then
    return 0
  fi

  local patterns="${FLEET_POLICY_PATTERNS:-}"
  # No patterns → no-op (VC-5)
  if [[ -z "$patterns" ]]; then
    return 0
  fi

  local fleet_base="${FLEET_POLICY_FLEET_BASE:-/root/projects/active}"
  # Missing base → no repos to scan, treat as compliant
  if [[ ! -d "$fleet_base" ]]; then
    return 0
  fi

  local target_files=()
  if [[ ${#FLEET_POLICY_TARGET_FILES[@]} -gt 0 ]]; then
    target_files=("${FLEET_POLICY_TARGET_FILES[@]}")
  else
    target_files=("scripts/cron-spec-writer.sh" "scripts/cron-auto-ship.sh" "scripts/autoship.sh")
  fi

  local repos_scanned=0
  local non_compliant_repos=0
  local total_matches=0
  local violators=""

  # Iterate over all repos (VC-2). Use nullglob to safely handle empty globs.
  local repo
  for repo in "$fleet_base"/*/; do
    # Skip if not a directory
    [[ -d "$repo" ]] || continue
    repos_scanned=$((repos_scanned + 1))

    local repo_violations=""
    local file
    for file in "${target_files[@]}"; do
      local target="$repo$file"
      # VC-6: silently skip missing files
      [[ -f "$target" ]] || continue

      # grep -nP: line number, Perl regex (needed for alternation)
      local matches
      matches=$(grep -nP "$patterns" "$target" 2>/dev/null || true)
      if [[ -n "$matches" ]]; then
        local m
        while IFS= read -r m; do
          [[ -z "$m" ]] && continue
          repo_violations="${repo_violations}    ${target}:${m}"$'\n'
          total_matches=$((total_matches + 1))
        done <<< "$matches"
      fi
    done

    if [[ -n "$repo_violations" ]]; then
      non_compliant_repos=$((non_compliant_repos + 1))
      violators="${violators}  - ${repo%/}"$'\n'
      violators="${violators}${repo_violations}"
    fi
  done

  # VC-3: report results
  if [[ $non_compliant_repos -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  ⚠️  FLEET POLICY CHECK: ${non_compliant_repos} repo(s) out of compliance${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Scanned ${repos_scanned} repos. ${total_matches} match(es) found for pattern(s): ${patterns}${NC}"
    echo ""
    echo -e "${YELLOW}Non-compliant repos:${NC}"
    printf '%s' "$violators"
    echo ""
    echo -e "${YELLOW}Review these repos before declaring this policy change complete.${NC}"
    echo -e "${YELLOW}(This is a warning — the pipeline will continue.)${NC}"
    echo ""
  else
    echo -e "${GREEN}  ✓ FLEET POLICY CHECK: All ${repos_scanned} repos compliant (no matches for: ${patterns})${NC}"
  fi
}

# ─── Validate input ──────────────────────────────────────────────────────────

if [ -z "$FEATURE_NAME" ]; then
  echo "Usage: ./scripts/run-ship.sh \"Feature Name\""
  exit 1
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SHIP ORCHESTRATOR: $FEATURE_NAME${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "Branch: $BRANCH_NAME"
info "Worktree: $WORKTREE_PATH"
echo ""

# ─── Pre-flight: fleet policy compliance check (opt-in) ──────────────────────
# Scans all 19 fleet repos for non-compliant policy patterns. Warning-only.
# Controlled by FLEET_POLICY_CHECK + FLEET_POLICY_PATTERNS in .pi/config.sh.
preflight_fleet_policy_check

# ─── Gate 1: Worktree setup ──────────────────────────────────────────────────

PHASE_REACHED=1
print_gate 1 "Worktree isolation"

cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  warn "Working tree has uncommitted changes"
  warn "Commit work before running gates"
  echo ""
  git status --short
  exit 1
fi

info "Creating isolated worktree on branch $BRANCH_NAME"
git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" HEAD
WORKTREE_CREATED=true
pass "Worktree created at $WORKTREE_PATH"

# ─── #194: Base the feature branch on the remote trunk ───────────────────────
# The orchestrator commits the fix to LOCAL main (and may push it — fix-on-main)
# before run-ship.sh branches the worktree from HEAD. Branching from HEAD then
# makes the feature tip identical to main, so Gate 6 `gh pr create --base main`
# fails with "No commits between main and feature" — no PR. This is the Gate-6
# analog of #190 Bug B. Fix: base the branch on the remote trunk and replay
# HEAD's commits as NEW commits, guaranteeing it is ahead of main.
cd "$WORKTREE_PATH"
git fetch origin "$DEFAULT_BRANCH" 2>/dev/null || true
TRUNK="origin/${DEFAULT_BRANCH}"
if ! git rev-parse --verify "$TRUNK" >/dev/null 2>&1; then
  abort "Cannot resolve $TRUNK — run 'git fetch origin $DEFAULT_BRANCH' then retry. (#194)"
fi
FIX_COMMITS="$(git rev-list --reverse "${TRUNK}..HEAD" 2>/dev/null | tr '\n' ' ')"
FIX_COMMITS="${FIX_COMMITS% }"
if [ -z "$FIX_COMMITS" ]; then
  abort "HEAD == $TRUNK: nothing ahead of $DEFAULT_BRANCH to ship. Commit the feature before running run-ship.sh — the branch must differ from $DEFAULT_BRANCH (#194)."
fi
FIX_COUNT="$(printf '%s' "$FIX_COMMITS" | wc -w | tr -d ' ')"
info "Replaying $FIX_COUNT commit(s) onto $TRUNK so the feature branch differs from $DEFAULT_BRANCH (#194)"
git reset --hard "$TRUNK"
# shellcheck disable=SC2086  # FIX_COMMITS is an intentional space-separated rev list
if ! git cherry-pick $FIX_COMMITS; then
  git cherry-pick --abort 2>/dev/null || true
  abort "cherry-pick of fix commit(s) onto $TRUNK failed — the change may already be on $DEFAULT_BRANCH. Resolve conflicts in $WORKTREE_PATH or ship via fix-on-main (#194)."
fi
AHEAD="$(git rev-list --count "${TRUNK}..HEAD" 2>/dev/null || echo 0)"
pass "Feature branch based on $TRUNK, ahead of $DEFAULT_BRANCH by $AHEAD commit(s)"

# Bootstrap dependencies: node_modules is gitignored, so a fresh worktree
# has no installed packages. Symlink from the main repo if present (fast path),
# otherwise run `npm ci`. This prevents Gate 2 tsc from spuriously failing
# on "Cannot find module 'react'" etc.
if [ -d "$REPO_ROOT/storefront/node_modules" ] && [ ! -e "$WORKTREE_PATH/storefront/node_modules" ]; then
  ln -s "$REPO_ROOT/storefront/node_modules" "$WORKTREE_PATH/storefront/node_modules"
  pass "Symlinked storefront/node_modules into worktree"
elif [ ! -d "$WORKTREE_PATH/storefront/node_modules" ] && [ -f "$WORKTREE_PATH/storefront/package.json" ]; then
  info "Installing storefront dependencies in worktree..."
  (cd "$WORKTREE_PATH/storefront" && npm ci --silent 2>&1 | tail -5) || warn "npm ci failed — Gate 2 may fail on missing modules"
fi
if [ -d "$REPO_ROOT/storefront/convex/node_modules" ] && [ ! -e "$WORKTREE_PATH/storefront/convex/node_modules" ]; then
  ln -s "$REPO_ROOT/storefront/convex/node_modules" "$WORKTREE_PATH/storefront/convex/node_modules" 2>/dev/null || true
fi

# Bootstrap .pi/fleet.yaml: it's gitignored (operator-local fleet manifest),
# so the worktree won't have it. Without it, scripts that read FLEET_FILE
# (e.g., audit-dequeue-sites.sh #292, audit-fleet-issue-labels.sh #269)
# exit 2 (manifest_not_found) and surface as spurious test failures in the
# worktree. Copy the host's manifest into the worktree.
if [ -f "$REPO_ROOT/.pi/fleet.yaml" ] && [ ! -e "$WORKTREE_PATH/.pi/fleet.yaml" ]; then
  cp "$REPO_ROOT/.pi/fleet.yaml" "$WORKTREE_PATH/.pi/fleet.yaml"
  pass "Copied .pi/fleet.yaml into worktree"
fi

# ─── Gate 2: Static checks ───────────────────────────────────────────────────

PHASE_REACHED=2
print_gate 2 "Static checks"

cd "$WORKTREE_PATH"

for cmd in "${VERIFY_COMMANDS[@]}"; do
  info "Running: $cmd"
  if ! eval "$cmd" 2>&1; then
    abort "$cmd failed"
  fi
  pass "$cmd"
done

# ─── Gate 2b: scripts/ ↔ .pi/scripts/ byte-identity lint (USVA #354) ──────────
# Warning-only during the rollout period. The lint reads the fleet +
# byte_identity_canonical_mirrors sections from repo-mapping.yaml
# dynamically (post-#337 pattern), walks each fleet repo, and reports
# MISSING_MIRROR / BYTE_DIFF / BROKEN_SYMLINK / WRONG_SYMLINK_TARGET /
# ORPHAN_MIRROR violations. Default posture: log warnings, do not block.
# Promote to blocking with RUN_SHIP_BLOCK_BYTE_IDENTITY=1 (Phase C rollout).
#
# See scripts/ci-lint-scripts-pi-mirror-byte-identity.sh + docs/fleet/byte-identity-rollout.md.
print_gate 2 "scripts/ ↔ .pi/scripts/ byte-identity lint (USVA #354)"
if [ -x "$REPO_ROOT/scripts/ci-lint-scripts-pi-mirror-byte-identity.sh" ]; then
  # Capture both stdout and exit code without `set -e` aborting on non-zero.
  # The lint exits 1 when violations are present — that's expected (warning-
  # only by default), not a run-ship failure. PIPESTATUS doesn't survive across
  # command substitution in bash (the subshell's $? clobbers it), so we run
  # the lint in a separate statement first to capture $? before the
  # substitution clobbers it.
  set +e
  LINT_OUTPUT=$("$REPO_ROOT/scripts/ci-lint-scripts-pi-mirror-byte-identity.sh" --check 2>&1)
  LINT_EXIT=$?
  set -e
  if [ "$LINT_EXIT" -eq 1 ]; then
    if [ "${RUN_SHIP_BLOCK_BYTE_IDENTITY:-0}" = "1" ]; then
      echo "$LINT_OUTPUT"
      abort "byte-identity lint reported findings (RUN_SHIP_BLOCK_BYTE_IDENTITY=1 — blocking). Set RUN_SHIP_BLOCK_BYTE_IDENTITY=0 to silence for this run, or fix the findings. See docs/fleet/byte-identity-rollout.md."
    else
      echo "$LINT_OUTPUT"
      warn "byte-identity lint reported findings above (USVA #354, warning-only — see docs/fleet/byte-identity-rollout.md for Phase B repair recipe)."
      warn "After the rollout period elapses, set RUN_SHIP_BLOCK_BYTE_IDENTITY=1 to make Gate 2b blocking."
    fi
  elif [ "$LINT_EXIT" -eq 0 ]; then
    pass "byte-identity lint: all fleet repos compliant"
  else
    # Exit 2/4/5 — error modes the lint uses (FLEET_DIR missing, unknown flag,
    # JSON parse error). Surface the error but do not block — these are
    # infrastructure issues, not spec violations.
    warn "byte-identity lint exited $LINT_EXIT (infrastructure error; not blocking — see docs/fleet/byte-identity-rollout.md)"
    echo "$LINT_OUTPUT"
  fi
else
  warn "scripts/ci-lint-scripts-pi-mirror-byte-identity.sh not found or not executable — skipping (run from a clean clone or reinstall via /ship workflow)"
fi

# ─── Gate 2c: canonical workflows EOF trailing-newline enforcer (USVA #402) ─
# The pre-commit `end-of-file-fixer` hook in fleet siblings' .pre-commit-config.yaml
# auto-appends `\n` to any staged file lacking one, which silently breaks byte-
# identity with library-central (the `sync-scripts` propagation layer). The
# fix at the canonical layer (per #402 option a) is to require every
# ~/.pi/library-central/workflows/*.sh to end with a single trailing 0x0a byte;
# this enforcer is the post-hoc check that catches regressions where the
# canonical file is edited directly (bypassing the runtime guard in
# scripts/library-manager.sh `cmd_sync_scripts`). Warning-only by default,
# matching the Gate 2b pattern; promote to blocking via
# RUN_SHIP_BLOCK_EOF_TRAILING_NEWLINE=1.
#
# See scripts/verify-fleet-policy-eof-trailing-newline.sh +
# specs/usva/fix-precommit-eof-fixer-byte-drift.usva.md.
print_gate 2 "canonical workflows EOF trailing-newline enforcer (USVA #402)"
if [ -x "$REPO_ROOT/scripts/verify-fleet-policy-eof-trailing-newline.sh" ]; then
  set +e
  EOF_OUTPUT=$("$REPO_ROOT/scripts/verify-fleet-policy-eof-trailing-newline.sh" 2>&1)
  EOF_EXIT=$?
  set -e
  if [ "$EOF_EXIT" -eq 1 ]; then
    if [ "${RUN_SHIP_BLOCK_EOF_TRAILING_NEWLINE:-0}" = "1" ]; then
      echo "$EOF_OUTPUT"
      abort "canonical EOF trailing-newline enforcer reported findings (RUN_SHIP_BLOCK_EOF_TRAILING_NEWLINE=1 — blocking). Set RUN_SHIP_BLOCK_EOF_TRAILING_NEWLINE=0 to silence for this run, or fix the canonical files (printf '\\n' >> ~/.pi/library-central/workflows/<name>.sh + ./scripts/library-manager.sh sync-scripts). See specs/usva/fix-precommit-eof-fixer-byte-drift.usva.md."
    else
      echo "$EOF_OUTPUT"
      warn "canonical EOF trailing-newline enforcer reported findings above (USVA #402, warning-only — see specs/usva/fix-precommit-eof-fixer-byte-drift.usva.md for repair recipe)."
      warn "After the rollout period elapses, set RUN_SHIP_BLOCK_EOF_TRAILING_NEWLINE=1 to make Gate 2c blocking."
    fi
  elif [ "$EOF_EXIT" -eq 0 ]; then
    pass "canonical EOF trailing-newline enforcer: all workflows compliant"
  elif [ "$EOF_EXIT" -eq 2 ]; then
    # Library-central not initialised — skip silently (consistent with Gate 2b's
    # graceful-degradation for missing infra).
    info "canonical EOF trailing-newline enforcer skipped (library-central not initialised)"
  else
    # Exit 4 (unknown flag) or other — infrastructure error, not blocking.
    warn "canonical EOF trailing-newline enforcer exited $EOF_EXIT (infrastructure error; not blocking — see specs/usva/fix-precommit-eof-fixer-byte-drift.usva.md)"
    echo "$EOF_OUTPUT"
  fi
else
  warn "scripts/verify-fleet-policy-eof-trailing-newline.sh not found or not executable — skipping (run from a clean clone or reinstall via /ship workflow)"
fi

# ─── Gate 2d: with-dequeue.sh ↔ library-central drift lint (USVA #400) ──────
# Closes the drift window between natursteinvertrieb's local copy of
# scripts/with-dequeue.sh and the library-central canonical copy that #288
# promoted. The drift was flagged in #288 Architecture Notes § 'Risk:
# drift between library-central and natursteinvertrieb'. Without this gate,
# a future PR that edits scripts/with-dequeue.sh without mirroring to
# ~/.pi/library-central/workflows/with-dequeue.sh would silently ship and
# be reverted by `library-manager.sh sync-scripts` on its next run.
#
# Two layers of defense at preflight time:
#   1. Default: canonical pair only (natursteinvertrieb ↔ library-central).
#   2. RUN_SHIP_FLEET_WIDE_WITH_DEQUEUE_DRIFT=1: extend to every fleet
#      sibling in repo-mapping.yaml's fleet: section (same surface that
#      verify-fleet-policy.sh --workflow with-dequeue audits).
#
# Warning-only during the rollout period. Promote to blocking with
# RUN_SHIP_BLOCK_WITH_DEQUEUE_DRIFT=1 (Phase C per
# docs/fleet/with-dequeue-drift-rollout.md).
#
# See scripts/ci-lint-with-dequeue-library-central-drift.sh +
# .github/workflows/ci-lint-with-dequeue-library-central-drift.yml
# (path-filtered PR-merge-time check).
print_gate 2 "with-dequeue.sh ↔ library-central drift lint (USVA #400)"
if [ -x "$REPO_ROOT/scripts/ci-lint-with-dequeue-library-central-drift.sh" ]; then
  # Default scope: canonical pair. Optional --fleet-wide via env var.
  LINT_ARGS="--check"
  if [ "${RUN_SHIP_FLEET_WIDE_WITH_DEQUEUE_DRIFT:-0}" = "1" ]; then
    LINT_ARGS="--check --fleet-wide"
  fi
  set +e
  DRIFT_OUTPUT=$("$REPO_ROOT/scripts/ci-lint-with-dequeue-library-central-drift.sh" $LINT_ARGS 2>&1)
  DRIFT_EXIT=$?
  set -e
  if [ "$DRIFT_EXIT" -eq 1 ]; then
    if [ "${RUN_SHIP_BLOCK_WITH_DEQUEUE_DRIFT:-0}" = "1" ]; then
      echo "$DRIFT_OUTPUT"
      abort "with-dequeue drift lint reported findings (RUN_SHIP_BLOCK_WITH_DEQUEUE_DRIFT=1 — blocking). Set RUN_SHIP_BLOCK_WITH_DEQUEUE_DRIFT=0 to silence for this run, or fix the findings. See docs/fleet/with-dequeue-drift-rollout.md."
    else
      echo "$DRIFT_OUTPUT"
      warn "with-dequeue drift lint reported findings above (USVA #400, warning-only — see docs/fleet/with-dequeue-drift-rollout.md for repair recipe)."
      warn "After the rollout period elapses, set RUN_SHIP_BLOCK_WITH_DEQUEUE_DRIFT=1 to make Gate 2d blocking."
      if [ "${RUN_SHIP_FLEET_WIDE_WITH_DEQUEUE_DRIFT:-0}" = "1" ]; then
        warn "RUN_SHIP_FLEET_WIDE_WITH_DEQUEUE_DRIFT=1 enabled — findings include fleet siblings vs. library-central."
      fi
    fi
  elif [ "$DRIFT_EXIT" -eq 0 ]; then
    pass "with-dequeue drift lint: canonical pair (and fleet siblings, if --fleet-wide) compliant"
  else
    # Exit 2/4/5 — error modes the lint uses (CONFIG_ERROR, unknown flag,
    # JSON parse error). Surface the error but do not block — these are
    # infrastructure issues, not spec violations.
    warn "with-dequeue drift lint exited $DRIFT_EXIT (infrastructure error; not blocking — see docs/fleet/with-dequeue-drift-rollout.md)"
    echo "$DRIFT_OUTPUT"
  fi
else
  warn "scripts/ci-lint-with-dequeue-library-central-drift.sh not found or not executable — skipping (run from a clean clone or reinstall via /ship workflow)"
fi

# ─── Gate 2.5: Security gate ─────────────────────────────────────────────────

print_gate 2 "Security gate (secrets, weak passwords, unsafe code)"

if [ -f "$SCRIPT_DIR/security-gate.sh" ]; then
  if ! bash "$SCRIPT_DIR/security-gate.sh"; then
    abort "Security gate failed — fix violations before shipping"
  fi
  pass "Security gate clean"
else
  info "security-gate.sh not found — skipping"
fi

# ─── Gate 3: Dev log check ───────────────────────────────────────────────────

PHASE_REACHED=3
print_gate 3 "Dev log check (runtime errors)"

cd "$WORKTREE_PATH"

info "Starting dev server and capturing logs for 20 seconds..."
LOG_OUTPUT=$(./scripts/capture-dev-logs.sh 20 2>&1)
LOG_EXIT=$?

echo "$LOG_OUTPUT" | tail -20

if [ $LOG_EXIT -ne 0 ]; then
  echo "$LOG_OUTPUT"
  abort "Dev logs contain real errors"
fi

pass "LOG VERDICT: CLEAN"

# Initialise E2E test outputs up-front so the PR-body step (and every other
# reference) is safe under `set -u` even when Gate 4 auto-skips E2E for a
# non-UI change (#190). The skip branch never assigns these, which previously
# emitted `TEST_OUTPUT: unbound variable` and relied on `|| echo "passing"`
# to mask a failed pipeline — fragile and noisy.
TEST_OUTPUT=""
TEST_OUTPUT2=""

# ─── Gate 4: E2E feature test (max 2 attempts) ───────────────────────────────

PHASE_REACHED=4
print_gate 4 "E2E feature test: $FEATURE_NAME"

cd "$WORKTREE_PATH"

# Check if diff contains UI/frontend files — skip E2E for infra-only changes (#185)
# Compare against origin/main (shared trunk), NOT local main: the orchestrator
# may have already committed the fix to local main before run-ship.sh branches
# from HEAD, which makes `git diff main...HEAD` always empty and ALWAYS skips
# E2E — even for genuine UI changes (#190).
git fetch origin main 2>/dev/null || true
DIFF_BASE="origin/main"
if ! git rev-parse --verify "$DIFF_BASE" >/dev/null 2>&1; then
  abort "Cannot resolve $DIFF_BASE for Gate 4 diff — run 'git fetch origin main' or check the remote."
fi
UI_FILE_COUNT=$(git diff "${DIFF_BASE}...HEAD" --name-only 2>/dev/null | grep -cE '\.(tsx|ts|css|html|astro|jsx|svelte|vue)$' || true)
if [ "$UI_FILE_COUNT" -eq 0 ]; then
  warn "No UI/frontend files in diff (vs $DIFF_BASE) — skipping E2E gate (non-UI change)"
  pass "E2E gate: skipped (non-UI changes)"
else
  info "Attempt 1 of 2..."
  # Canonical pattern from LRN-20260628: PIPESTATUS / $? after $() is clobbered
  # by command substitution in a `set -e` context. Disable -e for the
  # assignment, capture $? immediately, re-enable -e.
  # Selector resolution (USVA #466): prefer TEST_FILE (space-separated list of
  # playwright test file paths) when the operator sets it; otherwise fall back
  # to FEATURE_NAME (treated as a regex by playwright, which is fragile for
  # natural-language titles — this commit also adds multi-path TEST_FILE
  # support to avoid #292's "No tests found" AND the #284 workaround that
  # hand-rolled a single alternation regex across multiple spec files).
  if [ -n "${TEST_FILE:-}" ]; then
    # Tokenise on unquoted whitespace. Quoted segments (e.g.
    # 'path with spaces.spec.ts') stay as one token via xargs -n1. An empty
    # result aborts loudly (VC-4).
    # shellcheck disable=SC2207 # intentional word-split on $TEST_FILE
    TEST_SELECTORS=( $(printf '%s\n' "$TEST_FILE" | xargs -n1 printf '%s\n' 2>/dev/null \
                      | awk 'NF') )
    if [ "${#TEST_SELECTORS[@]}" -eq 0 ]; then
      abort "TEST_FILE is set but parsed to zero selectors: '$TEST_FILE'"
    fi
    if [ "${#TEST_SELECTORS[@]}" -eq 1 ]; then
      info "Using TEST_FILE selector: ${TEST_SELECTORS[0]}"
    else
      info "Using TEST_FILE selectors (${#TEST_SELECTORS[@]} files):"
      for _s in "${TEST_SELECTORS[@]}"; do
        info "  - $_s"
      done
    fi
  else
    TEST_SELECTORS=( "$FEATURE_NAME" )
    info "Using FEATURE_NAME selector: $FEATURE_NAME"
  fi

  # Per-spec loop: invoke Playwright once per selector so multi-path runs
  # execute every listed spec individually. Aggregate stdout/stderr across
  # specs, with TEST_EXIT reflecting the last failing per-spec exit code
  # (any per-spec failure -> Gate 4 fails, matching the single-spec contract).
  # Also tracks per-spec failure list so the PR-body summary (VC-5) can
  # report WHICH spec(s) failed in a multi-file run.
  set +e
  TEST_OUTPUT=""
  TEST_EXIT=0
  PER_SPEC_FAILED=()
  for _selector in "${TEST_SELECTORS[@]}"; do
    _chunk=$(eval "$TEST_COMMAND \"$_selector\"" 2>&1)
    _chunk_exit=$?
    if [ "${#TEST_SELECTORS[@]}" -gt 1 ]; then
      TEST_OUTPUT="${TEST_OUTPUT}${_chunk}
----- per-spec boundary -----
"
    else
      TEST_OUTPUT="${TEST_OUTPUT}${_chunk}"
    fi
    if [ "$_chunk_exit" -ne 0 ]; then
      TEST_EXIT=$_chunk_exit
      PER_SPEC_FAILED+=( "$_selector" )
    fi
  done
  set -e

  # Emit a structured multi-spec summary line so the operator / log can see
  # exactly which specs ran (VC-5).
  if [ "${#TEST_SELECTORS[@]}" -gt 1 ]; then
    if [ "${#PER_SPEC_FAILED[@]}" -eq 0 ]; then
      info "E2E gate: ${#TEST_SELECTORS[@]} specs passed (${TEST_SELECTORS[*]})"
    else
      info "E2E gate: $(( ${#TEST_SELECTORS[@]} - ${#PER_SPEC_FAILED[@]} )) specs passed, ${#PER_SPEC_FAILED[@]} failed (${PER_SPEC_FAILED[*]})"
    fi
  fi

  echo "$TEST_OUTPUT" | tail -20

  if [ $TEST_EXIT -ne 0 ]; then
    warn "Attempt 1 failed. Waiting for agent fix, then retrying..."
    echo "$TEST_OUTPUT"
    echo ""
    echo -e "${YELLOW}Fix the failure and press Enter for attempt 2, or Ctrl+C to abort.${NC}"
    if [ -t 0 ]; then
      read -r
    else
      abort "E2E test failed and no TTY available for interactive retry (non-interactive/CI mode)"
    fi

    info "Attempt 2 of 2..."
    # Per-spec loop, attempt 2 — same semantics as attempt 1 (each selector
    # invoked individually, exit aggregated, per-spec failure list rebuilt).
    set +e
    TEST_OUTPUT2=""
    TEST_EXIT2=0
    PER_SPEC_FAILED2=()
    for _selector in "${TEST_SELECTORS[@]}"; do
      _chunk=$(eval "$TEST_COMMAND \"$_selector\"" 2>&1)
      _chunk_exit=$?
      if [ "${#TEST_SELECTORS[@]}" -gt 1 ]; then
        TEST_OUTPUT2="${TEST_OUTPUT2}${_chunk}
----- per-spec boundary -----
"
      else
        TEST_OUTPUT2="${TEST_OUTPUT2}${_chunk}"
      fi
      if [ "$_chunk_exit" -ne 0 ]; then
        TEST_EXIT2=$_chunk_exit
        PER_SPEC_FAILED2+=( "$_selector" )
      fi
    done
    set -e

    if [ "${#TEST_SELECTORS[@]}" -gt 1 ]; then
      if [ "${#PER_SPEC_FAILED2[@]}" -eq 0 ]; then
        info "E2E gate (attempt 2): ${#TEST_SELECTORS[@]} specs passed (${TEST_SELECTORS[*]})"
      else
        info "E2E gate (attempt 2): $(( ${#TEST_SELECTORS[@]} - ${#PER_SPEC_FAILED2[@]} )) specs passed, ${#PER_SPEC_FAILED2[@]} failed (${PER_SPEC_FAILED2[*]})"
      fi
    fi

    echo "$TEST_OUTPUT2" | tail -20

    if [ $TEST_EXIT2 -ne 0 ]; then
      FAILURE_DETAIL=$(echo "$TEST_OUTPUT2" | grep -E "FAIL|Error|✗" | head -5 | tr '\n' ' ')
      FAILED_LIST=""
      if [ "${#PER_SPEC_FAILED2[@]}" -gt 0 ]; then
        FAILED_LIST=" Failed specs: ${PER_SPEC_FAILED2[*]}."
      fi

      ./scripts/create-issue.sh \
        --title "E2E test failing: $FEATURE_NAME" \
        --type regression \
        --found-during "shipping $FEATURE_NAME (2 attempts exhausted)" \
        --location "$TEST_SPEC_DIR" \
        --symptom "$FAILURE_DETAIL" \
        --context "E2E test for '$FEATURE_NAME' failed both attempts during run-ship.sh.${FAILED_LIST}" \
        --affects "Verification of the $FEATURE_NAME feature" \
        --test "$FEATURE_NAME" 2>/dev/null || true

      abort "E2E test failed after 2 attempts — see GitHub issue"
    fi
  fi

  pass "E2E feature test: passing"
fi

# ─── Gate 5: P0 regression suite ─────────────────────────────────────────────

PHASE_REACHED=5
print_gate 5 "P0 regression suite"

cd "$WORKTREE_PATH"

if [ -n "$P0_TESTS" ]; then
  info "Running: $P0_TESTS"

  set +e
  P0_OUTPUT=$(eval "$TEST_COMMAND \"$P0_TESTS\"" 2>&1)
  P0_EXIT=$?
  set -e

  echo "$P0_OUTPUT" | tail -30

  if [ $P0_EXIT -ne 0 ]; then
    warn "P0 regressions failed. One retry..."
    echo "$P0_OUTPUT"
    echo ""
    echo -e "${YELLOW}Fix the regression and press Enter to retry, or Ctrl+C to abort.${NC}"
    if [ -t 0 ]; then
      read -r
    else
      abort "P0 regressions failed and no TTY available for interactive retry (non-interactive/CI mode)"
    fi

    set +e
    P0_OUTPUT2=$(eval "$TEST_COMMAND \"$P0_TESTS\"" 2>&1)
    P0_EXIT2=$?
    set -e

    echo "$P0_OUTPUT2" | tail -30

    if [ $P0_EXIT2 -ne 0 ]; then
      abort "P0 regressions still failing — do not ship with regressions"
    fi
  fi

  pass "P0 regressions: all clean"
else
  warn "No P0 tests configured (P0_TESTS is empty)"
fi

# ─── Gate 6: Open PR ─────────────────────────────────────────────────────────

print_gate 6 "Open pull request"

cd "$WORKTREE_PATH"

info "Pushing branch $BRANCH_NAME..."
git push origin "$BRANCH_NAME"

PR_BODY_FILE="/tmp/pr-body-${FEATURE_SLUG}-${TIMESTAMP}.md"

if [ -z "${TEST_OUTPUT:-}" ] && [ -z "${TEST_OUTPUT2:-}" ]; then
  TEST_SUMMARY="skipped (non-UI change — no UI/frontend files in diff)"
else
  TEST_SUMMARY="$(echo "${TEST_OUTPUT2:-${TEST_OUTPUT:-}}" | grep -E "passed|steps" | tail -3 | tr '\n' ' ')"
  if [ -z "$TEST_SUMMARY" ]; then
    TEST_SUMMARY="passing"
  fi
fi

cat > "$PR_BODY_FILE" << EOF
## $FEATURE_NAME

Implemented and verified by the /ship agent.

## Verified
- ✓ Static checks: all passing
- ✓ Dev logs: clean
- ✓ E2E feature test: ${TEST_SUMMARY}
- ✓ P0 regressions: clean

## What the user can now do
[See the /ship report in the agent session]
EOF

PR_BODY="$(cat "$PR_BODY_FILE")"
if [ -n "$ISSUE_NUMBER" ]; then
  PR_BODY="Closes #${ISSUE_NUMBER}\n\n${PR_BODY}"
fi

PR_URL=$(gh pr create \
  --repo "$REPO" \
  --title "feat: $FEATURE_NAME" \
  --body "$PR_BODY" \
  --base "$DEFAULT_BRANCH" \
  --label "agent-generated" \
  2>/dev/null)

if [ -z "$PR_URL" ]; then
  warn "Could not create PR — push succeeded, create manually from: $BRANCH_NAME"
else
  pass "PR created: $PR_URL"

  # Send cost notification (#56)
  if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    SHIP_COST="${SHIP_COST:-unknown}"
    MSG="🚀 *Ship complete*
Feature: $FEATURE_NAME
PR: $PR_URL
Cost: \$${SHIP_COST}"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d chat_id="$TG_CHAT_ID" \
      -d parse_mode="Markdown" \
      -d text="$MSG" > /dev/null 2>&1 &
  fi
fi


# ─── Gate 7: Post-deploy visual verification ─────────────────────────────────

if [[ -f "$REPO_ROOT/scripts/visual-verify.sh" && -n "${PROD_URL:-}" ]]; then
  print_gate 7 "Visual verification"
  PHASE_REACHED=7

  info "Verifying live site at $PROD_URL ..."

  VISUAL_EXIT=0
  bash "$REPO_ROOT/scripts/visual-verify.sh" "$PROD_URL" || VISUAL_EXIT=$?

  if [[ "$VISUAL_EXIT" -eq 1 ]]; then
    warn "Visual issues detected — review screenshot before merging"
    warn "Screenshots saved in: $REPO_ROOT/.visual-verify/"
  elif [[ "$VISUAL_EXIT" -eq 2 ]]; then
    warn "Site unreachable at $PROD_URL — deploy may not have propagated yet"
  elif [[ "$VISUAL_EXIT" -eq 3 ]]; then
    info "playwright-cli not installed — skipping visual verification"
  else
    pass "Visual verification passed"
  fi
else
  info "Skipping visual verification (no PROD_URL in config or no visual-verify.sh)"
fi

# ─── Cleanup worktree ────────────────────────────────────────────────────────

info "Removing worktree..."
cd "$REPO_ROOT"
git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
WORKTREE_CREATED=false

# ─── Learning log ────────────────────────────────────────────────────────────

LOG_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOG_ID="LRN-$(date +%Y%m%d)-$(cat /dev/urandom | LC_ALL=C tr -dc 'A-Z0-9' | head -c 3 2>/dev/null || echo "001")"
LEARNINGS_FILE="$REPO_ROOT/.learnings/LEARNINGS.md"

cat >> "$LEARNINGS_FILE" << EOF

## [$LOG_ID]

**Logged**: $LOG_DATE
**Feature**: $FEATURE_NAME
**Branch**: $BRANCH_NAME
**Status**: pending
**Priority**: low

### What happened
All gates passed. Feature shipped via /ship workflow.

### Gate fixes required
[Review agent session transcript for details]

### Patterns observed
[To be filled by learning-agent]

### Metadata
- Source: run-ship.sh
- Area: [to be classified by learning-agent]
- Tags: ship, automated
- E2E attempts: Gate 4 used $([ -n "${TEST_OUTPUT2:-}" ] && echo "2" || echo "1") attempt(s)
- PR: ${PR_URL:-none}

---
EOF

info "Learning entry $LOG_ID appended to .learnings/LEARNINGS.md"

# ─── Final summary ───────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ALL GATES PASSED: $FEATURE_NAME${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
pass "Gate 2: Static checks"
pass "Gate 2.5: Security gate"
pass "Gate 3: Dev logs clean"
pass "Gate 4: E2E feature test"
pass "Gate 5: P0 regressions"
pass "Gate 6: PR opened"
if [[ -n "${PROD_URL:-}" ]]; then pass "Gate 7: Visual verify"; fi
echo ""
if [ -n "${PR_URL:-}" ]; then
  echo -e "  PR: ${CYAN}$PR_URL${NC}"
fi
echo ""
echo -e "  Learning entry ${LOG_ID} logged."
echo ""
