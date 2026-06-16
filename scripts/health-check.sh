#!/usr/bin/env bash
# health-check.sh — Per-project harness integrity check
# ──────────────────────────────────────────────────────────────────────────────
# Verifies a single project's pi_launchpad harness is intact and not silently
# broken (the bug class that caused "Extension path does not exist" in 11
# projects on 2026-06-09).
#
# Usage:
#   ./scripts/health-check.sh                  # Check the project in $PWD
#   ./scripts/health-check.sh /path/to/proj   # Check a specific project
#
# Exit codes:
#   0  All checks passed (silent on stdout, summary on stderr)
#   1  One or more checks failed (issue list on stdout)
#
# Output contract (used by fleet-extension-health.sh):
#   - Stdout: only printed when there are issues. Format is one line per issue.
#   - Stderr: human-readable summary, always printed.
#
# Checks performed:
#   1. Required extension files exist:
#        .pi/extensions/{subagent,model-router,github-tools}/index.ts
#   2. .pi/config.sh has no `{{` placeholder (setup incomplete)
#   3. CRON_SHIP_MODEL does not reference ollama (the silent-fail model)
#   4. Auto-ship scripts (cron-auto-ship.sh, autoship.sh) have a pre-flight check
#   5. specs/dlq has ≤ 5 entries (otherwise the auto-ship is silently DLQ-ing)
#   6. .pi/agents/ is non-empty (project has at least 1 agent)
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# ── Crash protection ───────────────────────────────────────────────────────
_completed_normally=0
_emergency_handler() {
    local _ec=$?
    if [[ $_completed_normally -eq 0 ]]; then
        echo "SCRIPT_ERROR: health-check.sh crashed with exit $_ec" >&2
    fi
    exit "$_ec"
}
trap _emergency_handler EXIT

# ── Args ───────────────────────────────────────────────────────────────────
TARGET="${1:-$PWD}"
if [[ ! -d "$TARGET" ]]; then
    echo "SCRIPT_ERROR: target directory not found: $TARGET" >&2
    exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"
PROJECT="$(basename "$TARGET")"

# ── Counters ───────────────────────────────────────────────────────────────
issues=()
checks=0

# ── Check 1: Required extension files ──────────────────────────────────────
for ext in subagent model-router github-tools; do
    checks=$((checks+1))
    if [[ ! -f "$TARGET/.pi/extensions/$ext/index.ts" ]]; then
        issues+=("missing .pi/extensions/$ext/index.ts")
    fi
done

# ── Check 2: config.sh has no unfilled placeholder ─────────────────────────
if [[ -f "$TARGET/.pi/config.sh" ]]; then
    checks=$((checks+1))
    if grep -qE '\{\{[A-Z][A-Z_0-9]+\}\}' "$TARGET/.pi/config.sh"; then
        issues+=(".pi/config.sh has unfilled {{PLACEHOLDER}} — setup incomplete")
    fi
fi

# ── Check 3: CRON_SHIP_MODEL not ollama ────────────────────────────────────
if [[ -f "$TARGET/.pi/config.sh" ]]; then
    checks=$((checks+1))
    if grep -qE '^[[:space:]]*CRON_SHIP_MODEL=.*ollama' "$TARGET/.pi/config.sh"; then
        issues+=("CRON_SHIP_MODEL still references ollama (silent-fail model)")
    fi
fi

# ── Check 4: cron-auto-ship.sh has pre-flight check (the script that runs `pi`) ──
# autoship.sh is just a wrapper that delegates to cron-auto-ship.sh via `bash ...`,
# so the pre-flight belongs in cron-auto-ship.sh. Check both possible locations.
preflight_found=0
for script in \
    "$TARGET/scripts/cron-auto-ship.sh" \
    "$TARGET/.pi/scripts/cron-auto-ship.sh"; do
    [[ -f "$script" ]] || continue
    checks=$((checks+1))
    if grep -qE 'pre.flight|preflight|extension.*exist|--no-extensions' "$script"; then
        preflight_found=1
    else
        issues+=("$(realpath --relative-to="$TARGET" "$script" 2>/dev/null || echo "$script") missing pre-flight check")
    fi
done

# ── Check 5: DLQ size ≤ 5 ──────────────────────────────────────────────────
DLQ_WARN=5
if [[ -d "$TARGET/specs/dlq" ]]; then
    checks=$((checks+1))
    dlq_count=$(find "$TARGET/specs/dlq" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dlq_count" -gt "$DLQ_WARN" ]]; then
        issues+=("specs/dlq has $dlq_count items (>$DLQ_WARN)")
    fi
fi

# ── Check 6: .pi/agents/ non-empty ─────────────────────────────────────────
if [[ -d "$TARGET/.pi/agents" ]]; then
    checks=$((checks+1))
    agent_count=$(find "$TARGET/.pi/agents" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$agent_count" -eq 0 ]]; then
        issues+=(".pi/agents/ is empty (no specialist agents installed)")
    fi
fi

# ── Report ─────────────────────────────────────────────────────────────────
# Summary on stderr (always). Issues on stdout (only if any).
# fleet-extension-health.sh greps stdout for the issue list; cron delivery
# surfaces stdout as the Telegram message when non-empty.

if [[ ${#issues[@]} -eq 0 ]]; then
    echo "  ✓ $PROJECT: $checks/$checks checks passed" >&2
    _completed_normally=1
    exit 0
fi

# Print issues to stdout (Telegram message body)
echo "  ✗ $PROJECT: ${#issues[@]} issue(s) of $checks checks:"
for issue in "${issues[@]}"; do
    echo "      • $issue"
done

# Mirror to stderr for human log
echo "  ✗ $PROJECT: ${#issues[@]} issue(s) of $checks checks" >&2

_completed_normally=1
exit 1
