#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# with-dequeue.sh — Centralized dequeue helper for cron-auto-ship.sh
# ──────────────────────────────────────────────────────────────────────────────
# Pulls the three inlined `gh issue edit` dequeue sequences (DLQ retry-limit,
# meta-action pre-flight gate, success-path cleanup) into a single helper.
# Future queue-label changes (#215 canonical migration, new human-review /
# spec-hold / shipped variants) require editing one function instead of
# grepping three call sites across cron-auto-ship.sh.
#
# Usage:
#   ./scripts/with-dequeue.sh hold         <issue>
#   ./scripts/with-dequeue.sh human-review <issue>
#   ./scripts/with-dequeue.sh ship         <issue>
#
# Action verb → label set mapping (preserved byte-for-byte from the inlined
# calls — VC-6 of USVA #265):
#
#   hold         → remove spec-approved, spec-ready;            add spec-hold
#   human-review → remove in-progress, spec-approved, spec-ready; add human-review
#   ship         → add shipped; remove spec-approved, spec-ready, in-progress
#
# Output:
#   stdout: empty (gh output is suppressed)
#   stderr: empty unless gh fails AND the optional --strict flag is set
#
# Exit code:
#   Always 0 (graceful degradation — mirrors the `2>/dev/null || true`
#   pattern the three inlined call sites used, so the helper is idempotent
#   even on absent labels or transient gh failures).
#
# See:
#   - specs/usva/extract-duplicate-dequeue-logic-label-helper.usva.md (VC-1..VC-10)
#   - issue #265 / PR for #265
#   - scripts/with-label.sh (parallel helper for label-existence filtering)
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load REPO from project config (consistent with scripts/with-label.sh and
# other scripts in this directory).
if [ -f "$PROJECT_ROOT/.pi/config.sh" ]; then
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.pi/config.sh"
fi

# Resolve gh binary the same way cron-auto-ship.sh does — prefer an inherited
# GH_BIN (e.g. from cron), fall back to PATH lookup. Defaulting here keeps the
# helper self-contained for tests and direct invocations.
GH_BIN="${GH_BIN:-$(command -v gh)}"

if [ -z "${REPO:-}" ]; then
  # Without REPO we cannot construct a gh argv. Mirror with-label.sh's
  # graceful-degradation: log to stderr and exit 0 so the calling cron
  # does not abort the whole run on a misconfigured environment.
  echo "with-dequeue.sh: REPO not set in .pi/config.sh — skipping dequeue" >&2
  exit 0
fi

# ── Parse args ──────────────────────────────────────────────────────────────
ACTION="${1:-}"
ISSUE_NUM="${2:-}"

if [ -z "$ACTION" ] || [ -z "$ISSUE_NUM" ]; then
  echo "with-dequeue.sh: usage: $0 {hold|human-review|ship} <issue-number>" >&2
  exit 0
fi

# ── Compose argv per action verb (VC-2, VC-6) ───────────────────────────────
# Order of `--add-label` / `--remove-label` flags is preserved exactly from
# the inlined calls (success-path has --add-label first; the two
# downgrades have --remove-label first). `gh` is order-insensitive on
# flag values so the argv set is what the existing tests assert on.
case "$ACTION" in
  hold)
    # DLQ retry-limit: spec-writer added BOTH spec-approved AND spec-ready
    # when approving (see #215, #216, #261) — remove both, add spec-hold.
    "$GH_BIN" issue edit "$ISSUE_NUM" --repo "$REPO" \
      --remove-label "spec-approved" \
      --remove-label "spec-ready" \
      --add-label "spec-hold" 2>/dev/null || true
    ;;

  human-review)
    # Meta-action pre-flight gate (#254): remove in-progress + queue
    # labels, add human-review.
    "$GH_BIN" issue edit "$ISSUE_NUM" --repo "$REPO" \
      --remove-label "in-progress" \
      --remove-label "spec-approved" \
      --remove-label "spec-ready" \
      --add-label "human-review" 2>/dev/null || true
    ;;

  ship)
    # Success path (#261): add shipped, remove spec-approved, spec-ready,
    # in-progress.
    "$GH_BIN" issue edit "$ISSUE_NUM" --repo "$REPO" \
      --add-label shipped \
      --remove-label spec-approved \
      --remove-label spec-ready \
      --remove-label in-progress 2>/dev/null || true
    ;;

  *)
    echo "with-dequeue.sh: unknown action '$ACTION' (supported: hold, human-review, ship)" >&2
    exit 0
    ;;
esac

exit 0
