#!/usr/bin/env bash
# test-cron-auto-ship-pi-prompt-heredoc-variable-export.sh
#
# Regression guard for issue #317:
#   "cron-auto-ship.sh envsubst heredoc gets empty values —
#    ISSUE_NUMBER/FEATURE_SLUG not exported before subshell"
#
# BUG MECHANISM
# -------------
# scripts/cron-auto-ship.sh assigns 9 variables with plain `VAR=value`
# (NO `export`) and then renders the pi prompt via:
#
#     "$(cat <<'PI_PROMPT' | envsubst '${VAR1} ${VAR2} ...'
#     ...${ISSUE_NUMBER}...${FEATURE_SLUG}...$LEARNINGS_SNIPPET...
#     PI_PROMPT
#     )"
#
# `envsubst` is a CHILD PROCESS. A child only inherits EXPORTED variables
# in its environment — plain shell variables are invisible to it. So every
# whitelisted `${VAR}` that was not `export`ed is substituted with the
# EMPTY STRING. The prompt that reaches pi has empty `## Issue`,
# `## Feature slug`, and `## Injected learnings` sections, so the ship
# orchestrator runs blind.
#
# WHY THE SIBLING TEST DOES NOT CATCH THIS
# ----------------------------------------
# test-cron-auto-ship-pi-prompt-heredoc-variable-interpolation.sh (issue
# #301) verifies that envsubst interpolates a SYNTHESIZED snippet — but
# that snippet sets every variable with an explicit `export VAR=value`,
# which masks the production bug. This test exercises the REAL production
# shape (no explicit export in the test harness — it mirrors whatever the
# script does) so a missing `export` is caught.
#
# STRATEGY
# --------
#   VC-S1: bash -n syntax check on the target script.
#   VC-S2: SOURCE check — every assignment of the 9 named variables in
#          the real script MUST start with `export`. Catches the bug
#          directly at the source.
#   VC-S3: BEHAVIOURAL control — quoted heredoc + UNEXPORTED vars fed to
#          envsubst yields EMPTY output. Proves the mechanism and that
#          this test CAN observe a missing export. (Always passes — it
#          is the bug-demonstration sanity check.)
#   VC-S4: BEHAVIOURAL control — same shape with EXPORTED vars yields the
#          values. Proves `export` is the fix. (Always passes.)
#   VC-S5: BEHAVIOURAL on the REAL heredoc — extract the actual PI_PROMPT
#          body + envsubst whitelist from the script, set the 10 vars
#          with MIRRORED export status (sentinel values), render via
#          envsubst, assert every sentinel appears. Fails today (bug
#          present); passes once the implementer adds `export`.
#
# Usage: ./scripts/test-cron-auto-ship-pi-prompt-heredoc-variable-export.sh [path/to/cron-auto-ship.sh]
# Exit:  0 = all pass, 1 = any fail.

set -uo pipefail

# Robust to parent-env pollution: if the orchestrator already has the 9
# bug vars exported (as it does during cron-auto-ship runs), the test's
# control (VC-S3: unexported vars → empty envsubst output) fails because
# envsubst inherits the parent's exported values. Unset all bug vars at
# test entry so VC-S3 / VC-S4 / VC-S5 observe a clean baseline.
unset PROJECT_DIR DEFAULT_BRANCH REPO GH_BIN \
      ISSUE_NUMBER LEARNINGS_SNIPPET ISSUE_CONTENT \
      ISSUE_TITLE FEATURE_SLUG PROJECT_NAME 2>/dev/null || true

TARGET="${1:-scripts/cron-auto-ship.sh}"

if [ ! -f "$TARGET" ]; then
  echo "FAIL: target script not found: $TARGET" >&2
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=""

ok()  { echo "  ✓ $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad() {
  echo "  ✗ $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  if [ -z "$FAIL_NAMES" ]; then
    FAIL_NAMES="    - $1"
  else
    FAIL_NAMES="$FAIL_NAMES
    - $1"
  fi
}

# ─── Temp workspace + cleanup ─────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
BODY_FILE="$TMP_DIR/heredoc-body.txt"
HARNESS_FILE="$TMP_DIR/render-harness.sh"
VC_S3_FILE="$TMP_DIR/vc-s3-unexported.sh"
VC_S4_FILE="$TMP_DIR/vc-s4-exported.sh"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# The 9 variables issue #317 names — assigned in cron-auto-ship.sh WITHOUT
# `export` before the envsubst subshell runs. PROJECT_NAME is intentionally
# NOT in this list: it is exported by .pi/config.sh (line 9) and is never
# assigned inside cron-auto-ship.sh, so it is out of scope for this bug.
BUG_VARS=(
  PROJECT_DIR DEFAULT_BRANCH REPO GH_BIN
  ISSUE_NUMBER LEARNINGS_SNIPPET ISSUE_CONTENT ISSUE_TITLE FEATURE_SLUG
)

# ═══════════════════════════════════════════════════════════════════════════════
# VC-S1: bash -n syntax check on the target script
# ═══════════════════════════════════════════════════════════════════════════════
echo "=== VC-S1: bash -n syntax check ==="
if bash -n "$TARGET" >/dev/null 2>&1; then
  ok "VC-S1: bash -n $TARGET exits 0 (syntax clean)"
else
  bad "VC-S1: bash -n $TARGET reports syntax errors"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# VC-S2: every assignment of the 9 bug vars MUST start with `export`
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== VC-S2: all 9 variable assignments use \`export\` (issue #317) ==="
for var in "${BUG_VARS[@]}"; do
  # Assignment occurrences: `VAR=` at the start of a line (after optional
  # whitespace), with or without an `export ` prefix. Matches both
  # `VAR=value` and `export VAR=value`. Deliberately does NOT match
  # `${VAR}` / `$VAR` references or comment lines (`# VAR=`).
  total=$(grep -cE "^[[:space:]]*(export[[:space:]]+)?${var}[[:space:]]*=" "$TARGET" || true)
  exported=$(grep -cE "^[[:space:]]*export[[:space:]]+${var}[[:space:]]*=" "$TARGET" || true)
  if [ "${total:-0}" -gt 0 ] && [ "${exported:-0}" -eq "${total:-0}" ]; then
    ok "VC-S2: ${var} — ${exported}/${total} assignment(s) use export"
  else
    bad "VC-S2: ${var} — ${exported:-0}/${total:-0} assignment(s) use export (envsubst subshell cannot see unexported vars)"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════════
# VC-S3: behavioural control — quoted heredoc + UNEXPORTED vars → empty
# Proves envsubst (a child process) cannot read unexported shell vars.
# This is the exact mechanism behind issue #317. This check ALWAYS passes —
# it is the sanity that proves this test harness can observe a missing
# `export`. If it ever fails, the test itself is broken.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== VC-S3: control — unexported vars → envsubst output is empty ==="
cat > "$VC_S3_FILE" <<'OUTER'
#!/usr/bin/env bash
set -uo pipefail
# NOT exported — mirrors the production bug exactly.
ISSUE_NUMBER="317"
FEATURE_SLUG="export-bug"
LEARNINGS_SNIPPET="learned-it"
cat <<'PI_PROMPT' | envsubst '${ISSUE_NUMBER} ${FEATURE_SLUG} ${LEARNINGS_SNIPPET}'
## Issue
${ISSUE_NUMBER}
## Feature slug
${FEATURE_SLUG}
## Injected learnings
${LEARNINGS_SNIPPET}
PI_PROMPT
OUTER
VC_S3_RESULT=$(bash "$VC_S3_FILE" 2>/dev/null)
if printf '%s' "$VC_S3_RESULT" | grep -qE '317|export-bug|learned-it'; then
  bad "VC-S3: envsubst saw unexported vars — mechanism check broken (test cannot catch the bug)"
else
  ok "VC-S3: envsubst produced empty values for unexported vars (mechanism confirmed — missing export is observable)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# VC-S4: behavioural control — quoted heredoc + EXPORTED vars → values present
# Proves `export` is the fix. This check ALWAYS passes.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== VC-S4: control — exported vars → envsubst output has values ==="
cat > "$VC_S4_FILE" <<'OUTER'
#!/usr/bin/env bash
set -uo pipefail
export ISSUE_NUMBER="317"
export FEATURE_SLUG="export-bug"
export LEARNINGS_SNIPPET="learned-it"
cat <<'PI_PROMPT' | envsubst '${ISSUE_NUMBER} ${FEATURE_SLUG} ${LEARNINGS_SNIPPET}'
## Issue
${ISSUE_NUMBER}
## Feature slug
${FEATURE_SLUG}
## Injected learnings
${LEARNINGS_SNIPPET}
PI_PROMPT
OUTER
VC_S4_RESULT=$(bash "$VC_S4_FILE" 2>/dev/null)
VC_S4_MISSING=0
for needle in "317" "export-bug" "learned-it"; do
  if ! printf '%s' "$VC_S4_RESULT" | grep -qF "$needle"; then
    bad "VC-S4: envsubst output missing '$needle' despite export (mechanism check broken)"
    VC_S4_MISSING=$((VC_S4_MISSING + 1))
  fi
done
if [ "$VC_S4_MISSING" -eq 0 ]; then
  ok "VC-S4: envsubst saw all exported vars (export is the fix)"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# VC-S5: REAL PI_PROMPT heredoc renders with the script's actual export status
#
# Extract the real envsubst whitelist + heredoc body from the script, build a
# harness that sets every variable with a sentinel value MIRRORING the script's
# per-variable export behaviour, then run envsubst as a child of that harness
# (exactly the production shape). Only the variables the script actually
# `export`s are visible to envsubst — so if any of the 9 is missing `export`,
# its sentinel is absent from the rendered output and this check fails.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== VC-S5: real PI_PROMPT heredoc renders under the script's export status ==="

# Extract the envsubst whitelist for the primary PI_PROMPT — the
# single-quoted argument on the SAME line or the line AFTER `<<'PI_PROMPT' | envsubst`.
# Two shapes are supported (matches both natursteinvertrieb and ai-trader layouts):
#   Shape A (whitelist on next line, backslash continuation):
#       "$(cat <<'PI_PROMPT' | envsubst \
#         '${WHITELIST}'
#   Shape B (whitelist inline on same line):
#       "$(cat <<'PI_PROMPT' | envsubst '${WHITELIST}'
# Both shapes extract the quoted whitelist for downstream rendering checks.
PRIMARY_WHITELIST=$(awk "
  /<<'PI_PROMPT' \\| envsubst/ {
    # Try inline shape first (Shape B): look for a single-quoted string on
    # the current line AFTER the `envsubst` token.
    if (match(\$0, /envsubst[[:space:]]+'[^']*'/)) {
      rest = substr(\$0, RSTART)
      # Strip the leading `envsubst ` and find the quoted string.
      sub(/^envsubst[[:space:]]+/, \"\", rest)
      if (match(rest, /'[^']*'/)) {
        print substr(rest, RSTART+1, RLENGTH-2)
        next
      }
    }
    # Fall back to separate-line shape (Shape A): read next line.
    if (getline next_line > 0 && match(next_line, /'[^']*'/)) {
      print substr(next_line, RSTART+1, RLENGTH-2)
    }
  }
" "$TARGET")

if [ -z "$PRIMARY_WHITELIST" ]; then
  bad "VC-S5: could not extract PI_PROMPT envsubst whitelist from $TARGET"
else
  # Extract the real heredoc body: every line after the whitelist line, up to
  # (not including) the closing `PI_PROMPT` tag. The closing tag sits at column 0
  # because the heredoc opener is `<<'PI_PROMPT'` (not the indented `<<-` form).
  # Handles two shapes:
  #   Shape A (inline whitelist): body starts on the line immediately after
  #     `<<'PI_PROMPT' | envsubst '${WL}'`.
  #   Shape B (separate whitelist): body starts two lines after the marker
  #     (line is `<<'PI_PROMPT' | envsubst \`, next line is the `${WL}`, then body).
  awk '
    /<<.PI_PROMPT./ && /envsubst/ {
      # Detect inline shape: whitelist `'\''<vars>'\''` is on the matched line.
      if (match($0, /envsubst[[:space:]]+'\''[^'\'']*'\''/)) {
        # Inline shape: body starts on the NEXT line.
        while ((getline line) > 0) {
          if (line ~ /^PI_PROMPT$/) exit
          print line
        }
      } else {
        # Separate shape: skip the whitelist line first, then read body.
        getline
        while ((getline line) > 0) {
          if (line ~ /^PI_PROMPT$/) exit
          print line
        }
      }
      exit
    }
  ' "$TARGET" > "$BODY_FILE"

  if [ ! -s "$BODY_FILE" ]; then
    bad "VC-S5: could not extract PI_PROMPT heredoc body from $TARGET"
  else
    # Build the harness. PROJECT_NAME is exported by .pi/config.sh (out of
    # scope), so it is always exported here. Each var the whitelist actually
    # references (extracted from PRIMARY_WHITELIST via a ${VAR} scan) is set
    # with sentinel value and the SAME export status the real script uses
    # (exported if the script exports the var OR if the script exports its
    # _P_-prefixed alias). If the script does not `export` it, neither does
    # this harness, and envsubst will not see it — that's the bug catcher.
    {
      echo '#!/usr/bin/env bash'
      echo 'set -uo pipefail'
      echo "export PROJECT_NAME='PROJECT_NAME_VC_S5'"
      # Extract every ${VAR} reference from the whitelist and unique-sort.
      # This handles both natursteinvertrieb's unprefixed shape and ai-trader's
      # _P_-prefixed shape (the work-around for issue #317 / #323).
      WHITELIST_VARS=$(printf '%s' "$PRIMARY_WHITELIST" | grep -oE '\$\{[A-Za-z_][A-Za-z_0-9]*\}' | sed 's/[${}]//g' | sort -u)
      for var in $WHITELIST_VARS; do
        # Determine the export status. The var is considered "exported" if
        # EITHER:
        #   1. The script has `export $var=...` (direct export), OR
        #   2. The script has `export ${var}_P_...=` or `export _P_${var}=`
        #      — i.e., the var is exported under a different name via the
        #      canonical _P_* workaround.
        is_exported="false"
        if grep -qE "^[[:space:]]*export[[:space:]]+${var}[[:space:]]*=" "$TARGET"; then
          is_exported="true"
        elif [[ "$var" == _P_* ]] && grep -qE "^[[:space:]]*export[[:space:]]+${var}[[:space:]]*=" "$TARGET"; then
          # _P_* var is directly exported in the script (the canonical
          # workaround shape used by ai-trader).
          is_exported="true"
        fi
        sentinel="${var}_VC_S5"
        if [[ "$is_exported" == "true" ]]; then
          printf "export %s='%s'\n" "$var" "$sentinel"
        else
          printf "%s='%s'\n" "$var" "$sentinel"
        fi
      done
      # Render the REAL body through envsubst with the REAL whitelist.
      # The whitelist contains `${VAR}` tokens and no single quotes, so it is
      # safe to single-quote. BODY_FILE is a mktemp path with no single quotes.
      printf "envsubst '%s' < '%s'\n" "$PRIMARY_WHITELIST" "$BODY_FILE"
    } > "$HARNESS_FILE"

    VC_S5_RENDER=$(bash "$HARNESS_FILE" 2>/dev/null)

    # Assert every whitelisted variable's sentinel appears in the rendered
    # output. This is the real bug catcher: a variable the script failed to
    # `export` is invisible to envsubst, so its sentinel is missing here.
    # We iterate the same WHITELIST_VARS list the harness used (not the
    # hardcoded BUG_VARS) so ai-trader's _P_-prefixed whitelist is also covered.
    VC_S5_MISSING=0
    for var in $WHITELIST_VARS; do
      sentinel="${var}_VC_S5"
      if printf '%s' "$VC_S5_RENDER" | grep -qF "$sentinel"; then
        :
      else
        bad "VC-S5: \${$var} rendered empty — not exported before envsubst subshell (issue #317)"
        VC_S5_MISSING=$((VC_S5_MISSING + 1))
      fi
    done
    if [ "$VC_S5_MISSING" -eq 0 ]; then
      WHITELIST_COUNT=$(echo "$WHITELIST_VARS" | wc -l | tr -d ' ')
      ok "VC-S5: all ${WHITELIST_COUNT} whitelisted vars rendered (script exports every var the heredoc references)"
    fi

    # Secondary sanity: no literal `${VAR}` leaks remain. NOTE this is weaker
    # than the sentinel check — envsubst substitutes a missing var with the
    # empty string (not the literal `${VAR}`), so a leak count of 0 only proves
    # envsubst RAN over the whitelist, not that the values were present.
    VC_S5_LEAKS=$(printf '%s' "$VC_S5_RENDER" | grep -cE '\$\{(PROJECT_NAME|PROJECT_DIR|ISSUE_NUMBER|ISSUE_TITLE|ISSUE_CONTENT|FEATURE_SLUG|LEARNINGS_SNIPPET|DEFAULT_BRANCH|REPO|GH_BIN)\}' || true)
    if [ "${VC_S5_LEAKS:-0}" -eq 0 ]; then
      ok "VC-S5: zero literal \${VAR} leaks in rendered output (envsubst ran over the whitelist)"
    else
      bad "VC-S5: ${VC_S5_LEAKS} literal \${VAR} strings leaked (envsubst whitelist mismatch)"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "══════════════════════════════════════════"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "  ALL PASS — $PASS_COUNT checks passed (0 failed)"
  echo "══════════════════════════════════════════"
  exit 0
else
  echo "  FAIL — $FAIL_COUNT checks failed:"
  printf "%s\n" "$FAIL_NAMES"
  echo "══════════════════════════════════════════"
  exit 1
fi
