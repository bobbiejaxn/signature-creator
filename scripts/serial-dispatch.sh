#!/usr/bin/env bash
# serial-dispatch.sh — Execute a plan of tasks serially, gated on PR merge
#
# Reads a plan file (one task per line) and executes them one at a time.
# After each task, waits for the PR to merge (via auto-merge CI) before
# proceeding to the next task.
#
# Plan file format (plain text, one task per line):
#   Fix ESLint errors in frontend/
#   Add unit tests for auth helpers
#   Update API types to match new schema
#
# Usage:
#   ./scripts/serial-dispatch.sh <plan-file> [--timeout 15]
#
# Requires: run-ship.sh, wait-for-merge.sh, gh CLI, PROJECT_REPO
#
# Exit codes:
#   0 = all tasks completed
#   1 = one or more tasks failed
#   2 = plan file error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR" && while [ "$(pwd)" != "/" ]; do [ -f ".pi/config.sh" ] && pwd && break; cd ..; done)"

PLAN_FILE="${1:?Usage: serial-dispatch.sh <plan-file> [--timeout minutes]}"
shift

TIMEOUT_MINUTES=15
while [ $# -gt 0 ]; do
	case "$1" in
		--timeout) TIMEOUT_MINUTES="${2:?--timeout needs a value}"; shift 2 ;;
		*) echo "Unknown arg: $1" >&2; exit 2 ;;
	esac
done

if [ ! -f "$PLAN_FILE" ]; then
	echo "ERROR: Plan file not found: $PLAN_FILE" >&2
	exit 2
fi

# Read plan, skip blank lines and comments
mapfile -t TASKS < <(grep -v '^#' "$PLAN_FILE" | grep -v '^[[:space:]]*$' || true)

if [ ${#TASKS[@]} -eq 0 ]; then
	echo "ERROR: Plan file is empty: $PLAN_FILE" >&2
	exit 2
fi

TOTAL=${#TASKS[@]}
COMPLETED=0
FAILED=0
SKIPPED=0

GH_BIN="${GH_BIN:-gh}"
REPO="${PROJECT_REPO:-}"
if [ -z "$REPO" ]; then
	REPO="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||' | sed 's|\.git$||')"
fi

echo "═══════════════════════════════════════════════════════════"
echo "  SERIAL DISPATCH: ${TOTAL} tasks"
echo "  Timeout: ${TIMEOUT_MINUTES}m per task"
echo "  Repo: ${REPO}"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Resume support ────────────────────────────────────────────────
# If a progress file exists, skip already-completed tasks
PROGRESS_FILE="${PLAN_FILE}.progress"
COMPLETED_TASKS=()
if [ -f "$PROGRESS_FILE" ]; then
	mapfile -t COMPLETED_TASKS < <(grep 'COMPLETED' "$PROGRESS_FILE" | cut -d'|' -f2- || true)
	echo "Resume: ${#COMPLETED_TASKS[@]} tasks already completed"
fi

is_completed() {
	local task="$1"
	for ct in "${COMPLETED_TASKS[@]}"; do
		[ "$ct" = "$task" ] && return 0
	done
	return 1
}

# ── Main loop ─────────────────────────────────────────────────────
for i in "${!TASKS[@]}"; do
	TASK="${TASKS[$i]}"
	TASK_NUM=$((i + 1))

	# Skip already-completed tasks (resume)
	if is_completed "$TASK"; then
		echo "⏭️  [$TASK_NUM/$TOTAL] SKIP (already completed): $TASK"
		SKIPPED=$((SKIPPED + 1))
		continue
	fi

	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo "🚀 [$TASK_NUM/$TOTAL] STARTING: $TASK"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

	# Pull latest main before each task
	git -C "$PROJECT_DIR" pull --rebase origin main 2>/dev/null || true

	# Run the ship script for this task
	# This creates a branch, implements, runs gates, creates PR
	if "$SCRIPT_DIR/run-ship.sh" "$TASK" 2>&1; then
		# Extract the PR number from the output
		PR_NUMBER=$("$GH_BIN" pr list --repo "$REPO" --head "feat/*" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

		if [ -z "$PR_NUMBER" ]; then
			# No PR created — maybe changes weren't needed
			echo "✅ [$TASK_NUM/$TOTAL] COMPLETED (no PR needed): $TASK"
			echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|COMPLETED|${TASK}" >> "$PROGRESS_FILE"
			COMPLETED=$((COMPLETED + 1))
			continue
		fi

		echo "📋 PR #$PR_NUMBER created. Waiting for CI auto-merge..."

		# Wait for the PR to merge (auto-merge via CI)
		if "$SCRIPT_DIR/wait-for-merge.sh" "$PR_NUMBER" "$TIMEOUT_MINUTES"; then
			echo "✅ [$TASK_NUM/$TOTAL] COMPLETED: $TASK (PR #$PR_NUMBER merged)"
			echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|COMPLETED|${TASK}|PR#${PR_NUMBER}" >> "$PROGRESS_FILE"
			COMPLETED=$((COMPLETED + 1))

			# Pull the merged changes before next task
			git -C "$PROJECT_DIR" pull --rebase origin main 2>/dev/null || true
		else
			WAIT_EXIT=$?
			echo "❌ [$TASK_NUM/$TOTAL] FAILED: $TASK (PR #$PR_NUMBER did not merge)"
			echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|FAILED|${TASK}|PR#${PR_NUMBER}|wait-exit=${WAIT_EXIT}" >> "$PROGRESS_FILE"
			FAILED=$((FAILED + 1))

			# Continue to next task — don't abort the whole plan
			# Pull whatever is on main (may or may not include this PR)
			git -C "$PROJECT_DIR" pull --rebase origin main 2>/dev/null || true
		fi
	else
		echo "❌ [$TASK_NUM/$TOTAL] FAILED: $TASK (run-ship.sh failed)"
		echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)|FAILED|${TASK}|ship-failed" >> "$PROGRESS_FILE"
		FAILED=$((FAILED + 1))
	fi

	echo ""
done

# ── Final report ──────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  SERIAL DISPATCH COMPLETE"
echo "  Total:    ${TOTAL}"
echo "  ✅ Done:  ${COMPLETED}"
echo "  ❌ Failed: ${FAILED}"
echo "  ⏭️  Skipped: ${SKIPPED}"
echo "═══════════════════════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
	exit 1
fi

exit 0
