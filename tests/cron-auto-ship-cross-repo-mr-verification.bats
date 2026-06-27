#!/usr/bin/env bats
#
# tests/cron-auto-ship-cross-repo-mr-verification.bats
#
# Per-project MR_URL marker parser test for signature-creator.
# Parameterized for /root/projects/active/signature-creator/ (issue #134 / per-project repair).
#
# Validates the Check 0 block added to scripts/cron-auto-ship.sh per
# USVA spec fix-cron-auto-ship-cross-repo-mr-verification.usva.md
# (issue #88), as rolled out fleet-wide per
# cron-auto-ship-mr-url-parser-repairs.usva.md (issue #134).
#
# The parser is the new "Check 0" in the SHIP_VERIFIED block. When the
# orchestrator (pi's Phase 8 / handoff) opens a cross-repo MR (e.g. on
# git.debored.ai for hermes-admin projects), it MUST leave a comment of
# the form:
#
#     MR_URL: https://<host>/<owner>/<repo>/pulls/<n>
#
# on its own line. This test validates the parser logic in isolation by
# feeding canned comment strings through the regex and checking the
# extracted URL (or empty for negative cases).
#
# Requires:
#   - bats (https://github.com/bats-core/bats-core) on PATH
#   - bash 4+
#

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CRON_SCRIPT="$SCRIPT_DIR/scripts/cron-auto-ship.sh"
  MIRROR_SCRIPT="$SCRIPT_DIR/.pi/scripts/cron-auto-ship.sh"
  export SCRIPT_DIR CRON_SCRIPT MIRROR_SCRIPT
}

# Helper: extract MR_URL marker from a canned comments blob using the
# exact regex/parsing logic embedded in the cron script.
parse_mr_url() {
  local comments="$1"
  printf '%s\n' "$comments" \
    | grep -E '^MR_URL:[[:space:]]+https?://[^[:space:]]+$' \
    | head -n 1 \
    | sed -E 's/^MR_URL:[[:space:]]+//' \
    || true
}

# ── VC1: Cross-repo MR is recognized (positive case) ────────────────────────

@test "VC1: extracts MR_URL from a comment containing only the marker line" {
  local url
  url=$(parse_mr_url "MR_URL: https://github.com/bobbiejaxn/signature-creator/pulls/1")
  [ "$url" = "https://github.com/bobbiejaxn/signature-creator/pulls/1" ]
}

@test "VC1: extracts http:// variant (not just https://)" {
  local url
  url=$(parse_mr_url "MR_URL: http://git.debored.ai/hermes-admin/signature-creator/pulls/1")
  [ "$url" = "http://git.debored.ai/hermes-admin/signature-creator/pulls/1" ]
}

# ── VC4: Malformed marker falls through ─────────────────────────────────────

@test "VC4: empty URL after marker is ignored" {
  local url
  url=$(parse_mr_url "MR_URL: ")
  [ -z "$url" ]
}

@test "VC4: marker without URL prefix is ignored" {
  local url
  url=$(parse_mr_url "MR_URL: not-a-url")
  [ -z "$url" ]
}

@test "VC4: marker mid-sentence is ignored" {
  local url
  url=$(parse_mr_url "see MR_URL: https://example.com/owner/repo/pulls/1 for details")
  [ -z "$url" ]
}

@test "VC4: wrong-case mr_url is ignored (case-sensitive)" {
  local url
  url=$(parse_mr_url "mr_url: https://example.com/owner/repo/pulls/1")
  [ -z "$url" ]
}

# ── VC7: Parser block exists in canonical cron-auto-ship.sh ─────────────────

@test "VC7: scripts/cron-auto-ship.sh contains the MR_URL parser" {
  [ -f "$CRON_SCRIPT" ]
  run grep -c "MR_URL:" "$CRON_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ── Sanity: parser is positioned before PR_CHECK (Check 1) ──────────────────

@test "sanity: Check 0 block is positioned before PR_CHECK (Check 1)" {
  local mr_url_line
  local pr_check_line
  mr_url_line=$(grep -n 'grep -E "\^MR_URL:' "$CRON_SCRIPT" 2>/dev/null | head -n 1 | cut -d: -f1)
  pr_check_line=$(grep -n 'pr list --repo "$REPO" --state open --search' "$CRON_SCRIPT" 2>/dev/null | head -n 1 | cut -d: -f1)
  [ -n "$mr_url_line" ]
  [ -n "$pr_check_line" ]
  [ "$mr_url_line" -lt "$pr_check_line" ]
}
