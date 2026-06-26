#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# lib/spec-writer-discovery.sh — single source of truth for spec-writer issue
# discovery. Sourced by every project's scripts/cron-spec-writer.sh.
# ──────────────────────────────────────────────────────────────────────────────
#
# Per USVA spec centralized-spec-writer-discovery-drift-prevention.usva.md
# (issue #83) — Option 2 of spec #78 rollout. This file replaces the drift-
# prone mirror-copy pattern (scripts/cron-spec-writer.sh ↔ .pi/scripts/
# cron-spec-writer.sh) with a single function every project sources.
#
# Public API:
#   spec_writer_discovery <owner/repo> <candidates_file>
#     Exits 0 if at least one eligible issue was found (numbers on stdout).
#     Exits 1 if no eligible issues (caller's "no work" path).
#     Exits 2 on fatal error (gh missing, repo unreachable, jq parse failure).
#
# Eligibility rules (mirrors the fix in issue #68 / PR #76 + #77):
#   - state: open
#   - label includes: backlog OR spec-hold
#   - label excludes: spec-ready, spec-approved, in-progress, out-of-scope,
#                      shipped, blocker, human-review
#   - EXCEPTION: if issue carries `spec-hold`, it is retained regardless of
#     other negative labels (per issue #216 / spec-hold-wins invariant).
#
# Side effects:
#   - Truncates and writes the candidates file at <candidates_file>
#     (one JSON object per line; same shape `gh issue list --json` emits).
#   - Prints discovery count + per-issue `[#NN] <title>` to stderr (cron's
#     existing logging style — matches `cron-spec-writer.sh`'s output).
#   - On success, prints bare issue numbers to stdout, one per line.
#
# This file MUST stay byte-identical across all vendored copies in projects
# that cannot reach the centralized lib at runtime (see VC2 of the spec).
# Drift between copies is caught by the CI guard per project (VC3).
#
# Compatible with bash 4+. Requires gh CLI and jq on PATH.
# ──────────────────────────────────────────────────────────────────────────────

spec_writer_discovery() {
  local repo="$1"
  local candidates_file="$2"

  if [ -z "$repo" ]; then
    echo "spec_writer_discovery: missing <repo> argument" >&2
    return 2
  fi
  if [ -z "$candidates_file" ]; then
    echo "spec_writer_discovery: missing <candidates_file> argument" >&2
    return 2
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "spec_writer_discovery: gh not found on PATH" >&2
    return 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "spec_writer_discovery: jq not found on PATH" >&2
    return 2
  fi

  # Phase 1: fetch — two --label passes (one per label) merged into a single
  # JSONL candidates file. Avoids GitHub's search-DSL foot-gun (issues #68,
  # #75) where `label:foo,bar` is parsed as AND, not OR. See USVA spec
  # fix-cron-spec-writer-search-filter.usva.md.
  : > "$candidates_file" || {
    echo "spec_writer_discovery: cannot write $candidates_file" >&2
    return 2
  }

  for lbl in backlog spec-hold; do
    if ! gh issue list --repo "$repo" --state open --label "$lbl" \
         --json number,title,labels,body --limit 100 \
         >> "$candidates_file" 2>/dev/null; then
      echo "spec_writer_discovery: gh issue list failed for $repo label=$lbl" >&2
      return 2
    fi
  done

  # Phase 2: filter — dedupe by issue number, then apply the spec-hold-wins
  # eligibility rule. Issues with `spec-hold` are retained regardless of other
  # negative labels (per issue #216). Other negative-label-only issues are
  # dropped.
  local eligible
  eligible=$(jq -s '
    map(.[]) |
    unique_by(.number) |
    map(select(
      ((.labels | map(.name) | contains(["spec-hold"])) or
       (.labels | map(.name) | (contains(["spec-ready"]) or contains(["spec-approved"]) or contains(["in-progress"]) or contains(["out-of-scope"]) or contains(["shipped"]) or contains(["blocker"]) or contains(["human-review"])) | not))
    ))
  ' "$candidates_file" 2>/dev/null) || {
    echo "spec_writer_discovery: jq parse failed on $candidates_file" >&2
    return 2
  }

  local count
  count=$(echo "$eligible" | jq 'length' 2>/dev/null) || {
    echo "spec_writer_discovery: jq length query failed" >&2
    return 2
  }

  if [ "$count" -eq 0 ]; then
    echo "spec_writer_discovery: no eligible issues in $repo" >&2
    return 1
  fi

  # Logging — match cron-spec-writer.sh's existing style so existing log
  # scrapers and dashboards keep working unchanged.
  echo "spec_writer_discovery: $count eligible issue(s) in $repo:" >&2
  echo "$eligible" | jq -r '.[] | "  [#\(.number)] \(.title)"' >&2

  # Caller payload: bare issue numbers, one per line, on stdout.
  echo "$eligible" | jq -r '.[].number'
  return 0
}