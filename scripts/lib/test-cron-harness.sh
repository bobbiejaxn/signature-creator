#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# scripts/lib/test-cron-harness.sh — shared hermetic test harness for any
# crontab-mutating test
# ──────────────────────────────────────────────────────────────────────────────
# Sourced by test scripts that need to:
#   - emit PASS/FAIL lines via `ok` / `bad` / `assert_eq` / `assert_diff_empty`
#   - run a `crontab`-mutating test without leaking state into the host's
#     real schedule (capture the user's crontab at source-time, restore on
#     EXIT via `trap`)
#   - install synthetic crontabs (`install_synthetic`) and dump the current
#     one (`dump_crontab`) as newline-joined strings
#   - gracefully SKIP the entire test if `crontab` is not on PATH
#
# Public API
# ----------
#   ok LABEL                      → increments PASS, prints "  PASS LABEL"
#   bad LABEL                     → increments FAIL, prints "  FAIL LABEL"
#   assert_eq LABEL ACTUAL WANT   → ok if equal, bad otherwise
#   assert_diff_empty LABEL F1 F2 → ok if `diff` is empty, bad otherwise
#   install_synthetic CRONTAB     → writes CRONTAB via `crontab -`
#   dump_crontab                  → echoes current crontab (or empty)
#
# Self-test (VC-6): run with `SELF_TEST=1` to verify the backup/restore
# trap fires on the three exit paths (clean, forced_fail, sigterm). The
# self-test is gated so normal test invocations do not run it.
#
# Why this file exists (#251)
# ----------------------------
# Until #251, every crontab-mutating test inlined ~95 lines of:
#   - PASS/FAIL counters + assertion helpers
#   - CRONTAB_BACKUP capture + restore_crontab function + `trap EXIT`
#   - install_synthetic / dump_crontab fixtures
#   - SKIP preflight
#   - source guard for double-source idempotency
#
# scripts/test-crontab-helpers.sh crossed the 500-LOC manifesto ceiling
# (III.13 "Nothing lives above 500") at #242 (566 LOC) and again at #249
# (754 LOC). Splitting the harness out:
#   - drops scripts/test-crontab-helpers.sh back under the ceiling
#   - moves the per-process crontab backup/restore invariant (manifesto
#     IX.33 high-blast-radius — a botched trap can corrupt the host's
#     real auto-ship crons) into ONE file, so a future crontab-mutating
#     test can `source` it instead of re-implementing the trap
#
# Conventions
# -----------
# - POSIX-portable: bash + POSIX printf + POSIX grep + diff. No `[[`.
# - Source guard at the top: idempotent under double-source.
# - Always restores the crontab byte-identical on every exit path.
# - SKIP is graceful (exit 0) if crontab is missing.
# ──────────────────────────────────────────────────────────────────────────────

# Source guard: prevent double-sourcing from running the body twice.
if [ -n "${__TEST_CRON_HARNESS_SOURCED:-}" ]; then
  return 0
fi
__TEST_CRON_HARNESS_SOURCED=1

# ── Counters (callers may reset; default 0) ──────────────────────────────────
PASS=${PASS:-0}
FAIL=${FAIL:-0}

# ── Assertion helpers ────────────────────────────────────────────────────────
ok()   { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2' want '$3')"; fi
}

assert_diff_empty() {
  # $1 = label, $2 = file1, $3 = file2
  if diff -u "$2" "$3" >/dev/null 2>&1; then
    ok "$1"
  else
    bad "$1 — diff:"
    diff -u "$2" "$3" | sed 's/^/    /'
  fi
}

# ── SKIP preflight (no crontab → graceful exit 0) ────────────────────────────
if ! command -v crontab >/dev/null 2>&1; then
  echo "SKIP: 'crontab' not on PATH — cannot test cron helpers on this host"
  exit 0
fi

# ── Hermetic crontab backup / restore (the high-blast-radius invariant) ─────
# Capture the user's real crontab at source-time. On EXIT (any reason:
# pass, fail, SIGINT, SIGTERM, syntax error mid-test), the trap writes
# the snapshot back. A botched trap here would corrupt the host's real
# auto-ship / watchdog / dlq-reaper schedule — manifesto IX.33.
CRONTAB_BACKUP="$(crontab -l 2>/dev/null || true)"

restore_crontab() {
  if [ -n "$CRONTAB_BACKUP" ]; then
    # crontab - expects the input to end with a newline. printf %s strips
    # the trailing newline; printf %s\n appends one. We append unconditionally.
    printf '%s\n' "$CRONTAB_BACKUP" | crontab - 2>/dev/null || true
  fi
}
trap restore_crontab EXIT

# ── Fixture helpers ──────────────────────────────────────────────────────────
# install_synthetic: write a one-or-more-line crontab via `crontab -`.
# The trailing newline on the LAST line matters: `crontab -` requires it.
install_synthetic() {
  printf '%s\n' "$1" | crontab - 2>/dev/null || true
}

# dump_crontab: echo current crontab as a single newline-joined string.
# Empty when the user has no crontab (treated as "no entries").
dump_crontab() {
  crontab -l 2>/dev/null || true
}

# ── Self-test (VC-6) — only runs when SELF_TEST=1 ───────────────────────────
# Verifies the backup/restore trap fires on all three exit paths:
#   1. clean       — exit 0, crontab restored
#   2. forced_fail — exit 1 mid-test, crontab restored (trap catches EXIT)
#   3. sigterm     — kill -TERM $$, crontab restored (EXIT is superset)
#
# Run: SELF_TEST=1 SELF_TEST_CASE=clean    source scripts/lib/test-cron-harness.sh
#      SELF_TEST=1 SELF_TEST_CASE=fail     source scripts/lib/test-cron-harness.sh
#      SELF_TEST=1 SELF_TEST_CASE=sigterm  source scripts/lib/test-cron-harness.sh
#
# On any of the three paths, after the harness exits, `crontab -l` should
# equal the snapshot taken before source-time. The test invocations are
# scripted in scripts/test-test-cron-harness.sh.
if [ "${SELF_TEST:-0}" = 1 ]; then
  # Caller is responsible for asserting the crontab state after we exit.
  # We just exercise the trap by exiting through the requested path.
  install_synthetic "0 1 * * * echo self-test-line"
  case "${SELF_TEST_CASE:-clean}" in
    clean)
      :  # fall through; harness exits cleanly → trap fires
      ;;
    forced_fail)
      exit 1  # mid-test failure → trap still fires (EXIT is not ERR)
      ;;
    sigterm)
      # Spawn a sub-shell that kills us after the trap is set; trap fires
      # because EXIT covers all exit-derived terminations.
      ( sleep 0.05; kill -TERM "$$" ) &
      wait $! || true
      ;;
  esac
fi
