#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# scripts/lib/crontab-helpers.sh — Safe crontab mutation helpers
# ──────────────────────────────────────────────────────────────────────────────
# Public API:
#   crontab_has_line MARKER     → echoes "yes" or "no"; always exits 0
#   crontab_remove_line MARKER  → removes every line containing MARKER from
#                                 the current user's crontab. If MARKER is
#                                 not present, the crontab is left UNCHANGED
#                                 (no spurious "crontab -" write).
#
# Why this file exists (#235)
# ---------------------------
# The pattern
#
#   crontab -l | grep -v MARKER || true | crontab -
#
# is a silent crontab-wiper: when grep finds no match it exits 1 with empty
# stdout, the `|| true` swallows the exit code but NOT the empty stream, and
# `crontab -` treats empty stdin as a valid (empty) crontab. Every other
# entry in the user's crontab is wiped without warning.
#
# The fix is two-fold:
#   1. A single helper (`crontab_remove_line`) that NEVER writes a possibly-
#      empty stream to `crontab -`. It early-returns when the crontab is
#      unchanged (or empty) so the foot-gun path is unreachable.
#   2. Every cron-mutating script in the repo sources this file and calls
#      `crontab_remove_line` instead of inlining the pipeline. The safe path
#      becomes the only path.
#
# Conventions
# -----------
# - POSIX-portable: uses only POSIX sh + POSIX grep + POSIX printf. No bash-
#   only features, no `[[`, no arrays, no `awk` extensions beyond standard
#   `awk`. Tested on Debian / Ubuntu / macOS /busybox sh.
# - Always exits 0 on success / no-op. Returns non-zero only when the
#   underlying `crontab -` (the actual write) fails.
# - Always restores the crontab byte-identical when MARKER is absent or
#   when no line containing MARKER is present. No trim of trailing
#   whitespace, no comment collapse, no blank-line strip.
#
# Test
# ----
# scripts/test-crontab-helpers.sh exercises both helpers against a synthetic
# crontab (>=5 entries) and asserts byte-identity on the no-match path.

# Source guard: prevent double-sourcing from running the body twice.
if [ -n "${__CRONTAB_HELPERS_SOURCED:-}" ]; then
  return 0
fi
__CRONTAB_HELPERS_SOURCED=1

# ── Internal helpers ──────────────────────────────────────────────────────────

# _crontab_read: echoes the current user's crontab (empty string if none).
# Treats "no crontab for user" (exit 1) as "empty" — that is the canonical
# state and `crontab -` accepts empty input, so it must round-trip safely.
_crontab_read() {
  crontab -l 2>/dev/null || true
}

# _crontab_lines_containing MARKER < stdin: echoes lines (one per \n) that
# contain MARKER. Empty result means MARKER is absent. Used to decide whether
# a write is actually required.
_crontab_lines_containing() {
  grep -F "$1" || true
}

# ── Public API ────────────────────────────────────────────────────────────────

# crontab_has_line MARKER
#   Echoes "yes" if any line of the current crontab contains MARKER,
#   "no" otherwise. Always exits 0.
crontab_has_line() {
  if [ $# -lt 1 ]; then
    echo "usage: crontab_has_line MARKER" >&2
    return 2
  fi
  local marker="$1"
  local current
  current="$(_crontab_read)"
  if [ -z "$current" ]; then
    echo "no"
    return 0
  fi
  # Use printf %s\n so a crontab without a trailing newline still round-trips.
  if printf '%s\n' "$current" | _crontab_lines_containing "$marker" | grep -q .; then
    echo "yes"
  else
    echo "no"
  fi
}

# crontab_remove_line MARKER
#   Remove every line containing MARKER from the current user's crontab.
#   If MARKER is not present, the crontab is left UNCHANGED (no write to
#   `crontab -` happens, so the foot-gun cannot fire).
#   Exits 0 on success / no-op. Exits non-zero only if `crontab -` itself
#   fails (the only real failure mode).
crontab_remove_line() {
  if [ $# -lt 1 ]; then
    echo "usage: crontab_remove_line MARKER" >&2
    return 2
  fi
  local marker="$1"

  # Snapshot the current crontab once. _crontab_read treats "no crontab"
  # as empty string — that is the canonical empty state.
  local current
  current="$(_crontab_read)"

  # If the marker is absent, do NOTHING. This is the headline fix: never
  # write a possibly-empty stream to `crontab -`.
  if [ -z "$current" ]; then
    return 0
  fi
  if ! printf '%s\n' "$current" | _crontab_lines_containing "$marker" | grep -q .; then
    return 0
  fi

  # Marker is present: filter it out (grep -vF = fixed-string, not regex)
  # and pipe the result to `crontab -`. Use printf %s\n on the result so
  # the trailing-newline invariant is preserved even if the filter leaves
  # the crontab without a final newline.
  local filtered
  filtered="$(printf '%s\n' "$current" | grep -vF "$marker" || true)"

  # Defensive: if the filter produced nothing (e.g. crontab was a single
  # matching line), still write an empty crontab — that is what the user
  # asked for. `crontab -` accepts empty stdin.
  printf '%s\n' "$filtered" | crontab -
}
