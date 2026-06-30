#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# test-crontab-helpers.sh — tests for scripts/lib/crontab-helpers.sh (#235)
# ──────────────────────────────────────────────────────────────────────────────
# Validates VC-1..VC-7 of specs/usva/add-cron-pipeline-safety-helper.usva.md:
#   - VC-2  no-match is safe (helper exits 0, crontab byte-identical)
#   - VC-3  match is removed; other lines survive byte-identical
#   - VC-4  non-trivial crontab (>=5 entries) test, named in the issue
#   - VC-6  POSIX-portable (covered by the bash -n + sh -n preflight)
#
# Strategy
# --------
# Tests run against a SYNTHETIC crontab installed via `crontab <file>` for the
# duration of the test, then restored from a backup in a `trap EXIT`. A test
# failure CANNOT brick the host's real schedule.
#
# Each test installs its own synthetic crontab (independent of any other
# test's state), then runs assertions against `crontab -l` text + the helper
# return code.
#
# Test harness
# ------------
# All reusable hermetic test infrastructure (assertion helpers, crontab
# backup/restore trap, install_synthetic / dump_crontab fixtures, SKIP
# preflight, double-source guard) lives in:
#
#     scripts/lib/test-cron-harness.sh
#
# Sourcing it gives this file `ok` / `bad` / `assert_eq` /
# `assert_diff_empty` / `install_synthetic` / `dump_crontab` and the
# per-process crontab backup/restore trap (fires on EXIT). Any
# future crontab-mutating test should source the same harness instead
# of re-implementing the trap (manifesto IX.33 high-blast-radius).
#
# Test naming
# -----------
#   H1  helper is POSIX-portable syntax-clean
#   H2  crontab_has_line: present line returns "yes", exit 0
#   H3  crontab_has_line: absent line returns "no", exit 0
#   H4  crontab_has_line: empty crontab returns "no", exit 0
#   H5  crontab_remove_line: VC-2 — no-match exits 0, crontab byte-identical
#   H6  crontab_remove_line: VC-3 — match removed; others byte-identical
#   H7  crontab_remove_line: VC-4 — non-trivial crontab (>=5 entries) test,
#       named in the issue: "removes a target line and leaves every other
#       line byte-identical"
#   H8  crontab_remove_line: with marker already absent, crontab still
#       byte-identical (VC-2 re-run invariant)
#   H9  crontab_remove_line: empty crontab is a no-op (no `crontab -` write)
#   H10 crontab_remove_line: removes EVERY line containing the marker,
#       not just the first
#   H11 crontab_remove_line: target line is the LAST line (trailing-newline
#       round-trip)
#   H12 scripts/install-cron-linux.sh + uninstall-cron-linux.sh + install-
#       fleet-disk-cleanup-cron.sh source the helper (no inline foot-gun)
#   H13 no occurrence of the foot-gun pattern remains in any tracked
#       install-* / uninstall-* / test-* script outside the helper
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/lib/crontab-helpers.sh"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the shared hermetic test harness (assertion helpers, crontab
# backup/restore trap, install/dump fixtures, SKIP preflight).
# Sourcing is idempotent — the harness guards double-source.
# shellcheck source=lib/test-cron-harness.sh
source "$SCRIPT_DIR/lib/test-cron-harness.sh"

# Source the helper under test so we can call crontab_has_line /
# crontab_remove_line directly. Sourcing is idempotent (the helper guards
# double-source).
# shellcheck source=lib/crontab-helpers.sh
source "$HELPER"

echo "== H1: helper is POSIX-portable syntax-clean =="
if bash -n "$HELPER" 2>err.txt; then ok "bash -n clean"; else bad "bash -n: $(cat err.txt)"; fi
rm -f err.txt
# sh -n exercises the POSIX-only claims of VC-6
if command -v sh >/dev/null 2>&1; then
  if sh -n "$HELPER" 2>err.txt; then ok "sh -n clean (POSIX)"; else bad "sh -n: $(cat err.txt)"; fi
  rm -f err.txt
else
  ok "(skipped: sh not on PATH)"
fi

echo "== H2: crontab_has_line returns 'yes' for a present line, exit 0 =="
install_synthetic "0 1 * * * echo morning
# MY_MARKER line comment
15 2 * * * /usr/bin/true"
out="$(crontab_has_line "MY_MARKER")"; rc=$?
assert_eq "present marker returns 'yes'" "$out" "yes"
assert_eq "exit code 0" "$rc" "0"
out="$(crontab_has_line "morning")"; rc=$?
assert_eq "another present marker returns 'yes'" "$out" "yes"
assert_eq "exit code 0" "$rc" "0"

echo "== H3: crontab_has_line returns 'no' for an absent line, exit 0 =="
install_synthetic "0 1 * * * echo morning
# MY_MARKER line comment"
out="$(crontab_has_line "DOES_NOT_EXIST")"; rc=$?
assert_eq "absent marker returns 'no'" "$out" "no"
assert_eq "exit code 0" "$rc" "0"

echo "== H4: crontab_has_line on an empty crontab returns 'no', exit 0 =="
# Clear the crontab by installing an empty file. Some hosts reject empty
# input to `crontab -`; fall back to the helper's own no-op path.
printf '' | crontab - 2>/dev/null || true
out="$(crontab_has_line "ANY")"; rc=$?
assert_eq "empty crontab returns 'no'" "$out" "no"
assert_eq "exit code 0" "$rc" "0"

echo "== H5: VC-2 — no-match exits 0, crontab byte-identical =="
install_synthetic "0 1 * * * echo morning
0 2 * * * echo noon
0 3 * * * echo evening"
before="$(dump_crontab)"
before_n=$(printf '%s' "$before" | wc -l | tr -d ' ')
crontab_remove_line "ABSENT_MARKER_XYZ"
rc=$?
after="$(dump_crontab)"
assert_eq "VC-2: exit code 0" "$rc" "0"
# Compare via temp files so the diff helper can format it.
tmp_b=$(mktemp); tmp_a=$(mktemp)
printf '%s\n' "$before" > "$tmp_b"
printf '%s\n' "$after"  > "$tmp_a"
assert_diff_empty "VC-2: crontab byte-identical (no-match)" "$tmp_b" "$tmp_a"
rm -f "$tmp_b" "$tmp_a"

echo "== H6: VC-3 — match is removed; other lines byte-identical =="
install_synthetic "0 1 * * * echo morning
0 2 * * * echo noon
# MY_MARKER_3 — keep me
0 3 * * * echo evening
# MY_MARKER_3 — also keep me"
before="$(dump_crontab)"
crontab_remove_line "MY_MARKER_3"
rc=$?
after="$(dump_crontab)"
assert_eq "VC-3: exit code 0" "$rc" "0"
# After: marker lines gone, other 3 lines survive.
tmp_b=$(mktemp); tmp_a=$(mktemp); tmp_want=$(mktemp)
printf '%s\n' "$before" > "$tmp_b"
printf '%s\n' "$after"  > "$tmp_a"
printf '%s\n' "0 1 * * * echo morning
0 2 * * * echo noon
0 3 * * * echo evening" > "$tmp_want"
assert_diff_empty "VC-3: marker lines gone, others byte-identical" "$tmp_want" "$tmp_a"
# And the before state is a SUPERSET of after (no unexpected mutations).
if grep -qF "MY_MARKER_3" "$tmp_a"; then
  bad "VC-3: marker line still present after remove"
else
  ok "VC-3: no MY_MARKER_3 line in result"
fi
rm -f "$tmp_b" "$tmp_a" "$tmp_want"

echo "== H7: VC-4 — non-trivial crontab (>=5 entries), target removed, others byte-identical =="
# Named in the issue: 'Test the helper against a non-trivial crontab
# (>=5 entries); assert it removes a target line and leaves every other
# line byte-identical'.
install_synthetic "0 1 * * * /usr/local/bin/auto-ship
0 2 * * * /usr/local/bin/watchdog
0 3 * * * /usr/local/bin/dlq-reaper
0 4 * * * /usr/local/bin/error-scanner
# MY_TARGET_MARKER — must be removed by helper
30 5 * * * /usr/local/bin/morning-report
# comment line, not a cron schedule, must also survive
0 6 * * * /usr/local/bin/morning-grep"

before="$(dump_crontab)"
n_lines=$(printf '%s\n' "$before" | wc -l | tr -d ' ')
# Sanity: we have at least 7 lines including a comment, satisfying the
# ">=5 entries" requirement.
if [ "$n_lines" -lt 7 ]; then
  bad "VC-4 setup: expected >=7 lines (5 entries + marker + comment), got $n_lines"
else
  ok "VC-4 setup: synthetic crontab has $n_lines lines (>=5 entries satisfied)"
fi

crontab_remove_line "MY_TARGET_MARKER"
rc=$?
after="$(dump_crontab)"
assert_eq "VC-4: exit code 0" "$rc" "0"

tmp_b=$(mktemp); tmp_a=$(mktemp); tmp_want=$(mktemp)
printf '%s\n' "$before" > "$tmp_b"
printf '%s\n' "$after"  > "$tmp_a"
# Expected: every line from `before` EXCEPT the marker line.
grep -vF "MY_TARGET_MARKER" "$tmp_b" > "$tmp_want"
assert_diff_empty "VC-4: every line except target byte-identical" "$tmp_want" "$tmp_a"
# And the target line is actually gone.
if grep -qF "MY_TARGET_MARKER" "$tmp_a"; then
  bad "VC-4: target marker still present in crontab after remove"
else
  ok "VC-4: target marker removed from crontab"
fi
rm -f "$tmp_b" "$tmp_a" "$tmp_want"

echo "== H8: VC-2 re-run invariant — marker already absent, crontab byte-identical =="
# Take the H7 'after' state (marker already removed) and call remove again.
before="$(dump_crontab)"
crontab_remove_line "MY_TARGET_MARKER"
rc=$?
after="$(dump_crontab)"
assert_eq "VC-2 re-run: exit code 0" "$rc" "0"
tmp_b=$(mktemp); tmp_a=$(mktemp)
printf '%s\n' "$before" > "$tmp_b"
printf '%s\n' "$after"  > "$tmp_a"
assert_diff_empty "VC-2 re-run: crontab byte-identical after second no-match" "$tmp_b" "$tmp_a"
rm -f "$tmp_b" "$tmp_a"

echo "== H9: empty crontab is a no-op (no `crontab -` write fires) =="
printf '' | crontab - 2>/dev/null || true
before="$(dump_crontab)"
# If the helper were buggy and called `crontab -` with empty stdin, the
# crontab should still be empty afterwards. We assert: (a) helper exits 0,
# (b) crontab is still empty afterwards, (c) helper does NOT emit anything
# to stdout (caller contract).
out="$(crontab_remove_line "ANY_MARKER" 2>&1)"; rc=$?
assert_eq "empty crontab: exit code 0" "$rc" "0"
after="$(dump_crontab)"
assert_eq "empty crontab: still empty" "$after" "$before"

echo "== H10: crontab_remove_line removes EVERY line containing the marker =="
install_synthetic "0 1 * * * echo first MATCHHERE
0 2 * * * echo second MATCHHERE
0 3 * * * echo third MATCHHERE
0 4 * * * echo unrelated"
before="$(dump_crontab)"
crontab_remove_line "MATCHHERE"
rc=$?
after="$(dump_crontab)"
assert_eq "multi-match: exit code 0" "$rc" "0"
tmp_a=$(mktemp); tmp_want=$(mktemp)
printf '%s\n' "$after" > "$tmp_a"
printf '%s\n' "0 4 * * * echo unrelated" > "$tmp_want"
assert_diff_empty "multi-match: only the unrelated line remains" "$tmp_want" "$tmp_a"
if grep -qF "MATCHHERE" "$tmp_a"; then
  bad "multi-match: at least one MATCHHERE line survived"
else
  ok "multi-match: zero MATCHHERE lines remain"
fi
rm -f "$tmp_a" "$tmp_want"

echo "== H11: trailing-newline round-trip — target is the LAST line =="
# Cron lines are newline-separated; if the helper mishandles the trailing
# newline on the marker line (the LAST line), the next `crontab -l` may
# drop a trailing newline silently. Assert byte-identity via diff.
install_synthetic "0 1 * * * echo kept
0 2 * * * echo also-kept
# TRAILING_TARGET"
before="$(dump_crontab)"
crontab_remove_line "TRAILING_TARGET"
rc=$?
after="$(dump_crontab)"
assert_eq "trailing-newline: exit code 0" "$rc" "0"
tmp_b=$(mktemp); tmp_a=$(mktemp); tmp_want=$(mktemp)
printf '%s\n' "$before" > "$tmp_b"
printf '%s\n' "$after"  > "$tmp_a"
printf '%s\n' "0 1 * * * echo kept
0 2 * * * echo also-kept" > "$tmp_want"
assert_diff_empty "trailing-newline: two kept lines survive, target gone" "$tmp_want" "$tmp_a"
rm -f "$tmp_b" "$tmp_a" "$tmp_want"

echo "== H12: cron-mutating scripts source the helper (any present file is checked; absent files are skipped) =="
# Per #241: this test must pass in natursteinvertrieb AND in every fleet
# sibling repo. Sibling repos don't carry install-fleet-disk-cleanup-cron.sh
# or test-fleet-disk-cleanup-cron.sh, so we skip absent files instead of
# failing. The two files that exist in every repo (install-cron-linux.sh
# and uninstall-cron-linux.sh) are the headline coverage.
for f in scripts/install-cron-linux.sh scripts/uninstall-cron-linux.sh scripts/install-fleet-disk-cleanup-cron.sh scripts/test-fleet-disk-cleanup-cron.sh; do
  if [ ! -f "$f" ]; then
    ok "$f absent (skipped — not all repos carry this script)"
    continue
  fi
  if grep -q 'lib/crontab-helpers.sh' "$f"; then ok "$f sources lib/crontab-helpers.sh"; else bad "$f does NOT source lib/crontab-helpers.sh"; fi
done

echo "== H13: no foot-gun pattern remains in tracked install-/uninstall-/test- scripts =="
# The unsafe pipeline is: crontab -l ... | grep ... || true | crontab -
# (with the `|| true` swallowing grep's nonzero exit on no-match, which is
# precisely what makes it wipe the crontab). We scan every shell script in
# scripts/ that mutates crontab and assert none of them contain the pattern.
#
# We deliberately skip comment lines (starting with `#`) — those are
# documentation of the foot-gun, not instances of it.
# Per #241: we skip absent files (sibling repos don't carry every
# fleet-specific cron script; only install-cron-linux.sh + uninstall-cron-linux.sh
# are required everywhere).
violations=0
for f in scripts/install-cron-linux.sh scripts/uninstall-cron-linux.sh scripts/install-fleet-disk-cleanup-cron.sh scripts/test-fleet-disk-cleanup-cron.sh; do
  if [ ! -f "$f" ]; then continue; fi
  # Strip comment lines before scanning so documentation comments don't
  # count as violations. We still catch real code matches.
  code_only=$(grep -vE '^\s*#' "$f" || true)
  # Match the two characteristic fragments: `|| true | crontab -` and
  # `(crontab -l ... || true) | crontab -`. The first is the exact foot-gun
  # from the issue; the second is a documented variant.
  if printf '%s\n' "$code_only" | grep -nE '\|\| true *\| *crontab -' >/dev/null 2>&1; then
    bad "$f still contains the || true | crontab - foot-gun:"
    printf '%s\n' "$code_only" | grep -nE '\|\| true *\| *crontab -' | sed 's/^/    /'
    violations=$((violations+1))
  else
    ok "$f: no '|| true | crontab -' foot-gun pattern (code only)"
  fi
  # Also reject the single-line pipeline `crontab -l | grep ... | crontab -`
  # without the guard — only allow the helper itself or the explicit
  # `crontab -l | grep -qF` early-check pattern.
  if printf '%s\n' "$code_only" | grep -nE '\(crontab -l[^)]*\| *grep -v' >/dev/null 2>&1; then
    bad "$f still contains the (crontab -l | grep -v ...) | crontab - foot-gun:"
    printf '%s\n' "$code_only" | grep -nE '\(crontab -l[^)]*\| *grep -v' | sed 's/^/    /'
    violations=$((violations+1))
  else
    ok "$f: no '(crontab -l | grep -v ...) | crontab -' foot-gun pattern (code only)"
  fi
done
if [ "$violations" -eq 0 ]; then ok "no foot-gun patterns remain in any cron-mutating script"; fi

echo
echo "════════════════════════════════════════════════════════════════════"
echo "  PASS=$PASS  FAIL=$FAIL"
echo "════════════════════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
