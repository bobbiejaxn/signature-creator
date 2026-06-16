#!/usr/bin/env bash
# wait-for-merge.sh — Poll a PR until it's merged, closed, or timed out
#
# Usage: ./scripts/wait-for-merge.sh <pr-number> [timeout-minutes]
#
# Exit codes:
#   0 = merged
#   1 = closed without merging
#   2 = timeout
#   3 = error
#
# Requires: gh CLI, GITHUB_TOKEN

set -euo pipefail

PR_NUMBER="${1:?Usage: wait-for-merge.sh <pr-number> [timeout-minutes]}"
TIMEOUT_MINUTES="${2:-15}"
POLL_INTERVAL=15  # seconds

REPO="${PROJECT_REPO:-}"
if [ -z "$REPO" ]; then
	REPO="$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||' | sed 's|\.git$||')"
fi

if [ -z "$REPO" ]; then
	echo "ERROR: Cannot determine repo. Set PROJECT_REPO or run from a git repo." >&2
	exit 3
fi

GH_BIN="${GH_BIN:-gh}"

elapsed=0
timeout_seconds=$((TIMEOUT_MINUTES * 60))

while [ $elapsed -lt $timeout_seconds ]; do
	# Get PR state
	state=$("$GH_BIN" pr view "$PR_NUMBER" --repo "$REPO" --json state,mergedAt --jq '.state' 2>/dev/null || echo "ERROR")

	case "$state" in
		MERGED)
			echo "MERGED: PR #$PR_NUMBER merged successfully"
			exit 0
			;;
		CLOSED)
			echo "CLOSED: PR #$PR_NUMBER was closed without merging"
			exit 1
			;;
		ERROR)
			echo "ERROR: Cannot fetch PR #$PR_NUMBER status" >&2
			exit 3
			;;
		OPEN)
			# Check if CI checks are still running
			checks=$("$GH_BIN" pr checks "$PR_NUMBER" --repo "$REPO" 2>/dev/null || echo "no checks")
			# Count passing/failing
			pass=$(echo "$checks" | grep -c "pass" 2>/dev/null || echo "0")
			fail=$(echo "$checks" | grep -c "fail" 2>/dev/null || echo "0")
			pending=$(echo "$checks" | grep -c "pending" 2>/dev/null || echo "0")

			minutes=$((elapsed / 60))
			remaining=$((timeout_seconds / 60 - minutes))
			echo "WAITING: PR #$PR_NUMBER — ${pass} pass, ${fail} fail, ${pending} pending (${remaining}m remaining)"

			if [ "$fail" -gt 0 ]; then
				echo "CI FAILED on PR #$PR_NUMBER. Waiting for potential re-run..."
			fi
			;;
	esac

	sleep "$POLL_INTERVAL"
	elapsed=$((elapsed + POLL_INTERVAL))
done

echo "TIMEOUT: PR #$PR_NUMBER not merged after ${TIMEOUT_MINUTES} minutes"
exit 2
