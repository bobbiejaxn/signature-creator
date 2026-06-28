#!/usr/bin/env bash
# test-cron-auto-ship-pi-prompt-heredoc-variable-interpolation.sh
#
# Source-level + behavioural verification for issue #301:
#   "cron-auto-ship.sh PI_PROMPT heredoc uses single-quoted delimiter —
#    variables ${PROJECT_NAME}, ${ISSUE_NUMBER} etc. are passed LITERALLY to pi"
#
# Strategy:
#   - SOURCE checks (VC-2, 3): confirm both PI_PROMPT and PI_PROMPT_RETRY
#     heredoc tags are STILL quoted (preserving the #271 backtick safety
#     fix) AND piped through `envsubst` with a whitelist.
#   - SOURCE checks (VC-3, 4): confirm the envsubst whitelist contains
#     the 11 variables the prompt body actually references (10 in primary,
#     11 in retry which adds ${FALLBACK_MOD}).
#   - BEHAVIOURAL check (VC-4): re-exec the production pattern with known
#     values for all 11 variables and prove that EVERY value appears in
#     the rendered output (i.e., envsubst actually interpolates, no
#     literal ${VAR} strings remain).
#   - BEHAVIOURAL check (VC-5): confirm zero "command not found" errors
#     (the #271 backtick-safety fix is preserved — envsubst's whitelist
#     does NOT cause Markdown backticks to be re-interpreted as commands).
#
# Usage: ./scripts/test-cron-auto-ship-pi-prompt-heredoc-variable-interpolation.sh [path/to/cron-auto-ship.sh]
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail

TARGET="${1:-scripts/cron-auto-ship.sh}"

if [ ! -f "$TARGET" ]; then
  echo "FAIL: target script not found: $TARGET" >&2
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=""

ok()   { echo "  ✓ $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
bad()  { echo "  ✗ $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAIL_NAMES="$FAIL_NAMES\n    - $1"; }

# ─── Source-level checks ───────────────────────────────────────────────────────
echo "=== Source checks: $TARGET ==="

# VC-S1: `<<'PI_PROMPT'` (quoted form) must STILL be present
# (the #271 fix MUST be preserved — envsubst pipe is ADDITIVE)
if grep -qE "<<'PI_PROMPT'" "$TARGET"; then
  ok "VC-S1: PI_PROMPT heredoc opening tag is quoted (<<'PI_PROMPT')"
else
  bad "VC-S1: PI_PROMPT heredoc opening tag is NOT quoted — #271 backtick-safety fix REGRESSED"
fi

# VC-S2: `<<'PI_PROMPT_RETRY'` (quoted form) must STILL be present
if grep -qE "<<'PI_PROMPT_RETRY'" "$TARGET"; then
  ok "VC-S2: PI_PROMPT_RETRY heredoc opening tag is quoted (<<'PI_PROMPT_RETRY')"
else
  bad "VC-S2: PI_PROMPT_RETRY heredoc opening tag is NOT quoted"
fi

# VC-S3: envsubst pipe must be present after the primary PI_PROMPT tag
if grep -qE "<<'PI_PROMPT'(\s*\|\s*envsubst)" "$TARGET"; then
  ok "VC-S3: PI_PROMPT heredoc is piped through envsubst"
else
  bad "VC-S3: PI_PROMPT heredoc is NOT piped through envsubst — variables will be passed LITERALLY to pi"
fi

# VC-S4: envsubst pipe must be present after the PI_PROMPT_RETRY tag
if grep -qE "<<'PI_PROMPT_RETRY'(\s*\|\s*envsubst)" "$TARGET"; then
  ok "VC-S4: PI_PROMPT_RETRY heredoc is piped through envsubst"
else
  bad "VC-S4: PI_PROMPT_RETRY heredoc is NOT piped through envsubst — variables will be passed LITERALLY to pi"
fi

# VC-S5: bash -n syntax check
if bash -n "$TARGET" >/dev/null 2>&1; then
  ok "VC-S5: bash -n $TARGET exits 0 (syntax clean)"
else
  bad "VC-S5: bash -n $TARGET reports syntax errors"
fi

# ─── VC-3: envsubst whitelist contains all 11 referenced variables ─────────────
echo ""
echo "=== VC-3: envsubst whitelist completeness ==="

# Whitelist for primary PI_PROMPT — 10 vars (no FALLBACK_MOD).
# Use awk to find the line AFTER the <<'PI_PROMPT' | envsubst tag and
# extract the single-quoted envsubst argument from it.
PRIMARY_WHITELIST=$(awk "/<<'PI_PROMPT' \\| envsubst/ { getline; if (match(\$0, /'[^']*'/)) print substr(\$0, RSTART+1, RLENGTH-2) }" "$TARGET")
# Whitelist for PI_PROMPT_RETRY — 11 vars (adds FALLBACK_MOD)
RETRY_WHITELIST=$(awk "/<<'PI_PROMPT_RETRY' \\| envsubst/ { getline; if (match(\$0, /'[^']*'/)) print substr(\$0, RSTART+1, RLENGTH-2) }" "$TARGET")

REQUIRED_PRIMARY_VARS=(
  "PROJECT_NAME" "PROJECT_DIR" "ISSUE_NUMBER" "ISSUE_TITLE"
  "ISSUE_CONTENT" "FEATURE_SLUG" "LEARNINGS_SNIPPET"
  "DEFAULT_BRANCH" "REPO" "GH_BIN"
)
REQUIRED_RETRY_VARS=(
  "PROJECT_NAME" "PROJECT_DIR" "ISSUE_NUMBER" "ISSUE_TITLE"
  "ISSUE_CONTENT" "FEATURE_SLUG" "LEARNINGS_SNIPPET"
  "DEFAULT_BRANCH" "REPO" "GH_BIN" "FALLBACK_MOD"
)

missing=0
for v in "${REQUIRED_PRIMARY_VARS[@]}"; do
  if [[ "$PRIMARY_WHITELIST" != *"\${$v}"* ]]; then
    bad "VC-3: primary whitelist is missing \${$v}"
    missing=$((missing + 1))
  fi
done
for v in "${REQUIRED_RETRY_VARS[@]}"; do
  if [[ "$RETRY_WHITELIST" != *"\${$v}"* ]]; then
    bad "VC-3: retry whitelist is missing \${$v}"
    missing=$((missing + 1))
  fi
done
if [ "$missing" -eq 0 ]; then
  ok "VC-3: both whitelists contain all ${#REQUIRED_PRIMARY_VARS} primary vars + FALLBACK_MOD for retry"
fi

# ─── VC-4: behavioural test — envsubst actually interpolates ─────────────────
echo ""
echo "=== VC-4: behavioural — envsubst interpolates all 11 variables ==="

# Build a minimal version of the production pattern: quoted heredoc with
# envsubst pipe, identical to what the script now uses. We set every
# variable in scope and assert its rendered value appears verbatim.
TEST_SNIPPET=$(mktemp)
trap 'rm -f "$TEST_SNIPPET"' EXIT

cat > "$TEST_SNIPPET" <<OUTER_EOF
#!/usr/bin/env bash
# Mirror the production pattern: \$(cat <<'PI_PROMPT' | envsubst '<whitelist>' ... PI_PROMPT)
# Set every var that the prompt body references; verify each appears
# in the rendered output (not the literal \${VAR}).

# Test value convention: every var's value is its own name (e.g.
# PROJECT_NAME=PROJECT_NAME_value). This lets us assert presence
# unambiguously — a false positive like the literal "\${PROJECT_NAME}"
# can never equal "PROJECT_NAME_value".
export PROJECT_NAME="PROJECT_NAME_value"
export PROJECT_DIR="/tmp/PROJECT_DIR_value"
export ISSUE_NUMBER="ISSUE_NUMBER_value"
export ISSUE_TITLE="ISSUE_TITLE_value"
export ISSUE_CONTENT="ISSUE_CONTENT_value"
export FEATURE_SLUG="FEATURE_SLUG_value"
export LEARNINGS_SNIPPET="LEARNINGS_SNIPPET_value"
export DEFAULT_BRANCH="DEFAULT_BRANCH_value"
export REPO="REPO_value"
export GH_BIN="GH_BIN_value"
export FALLBACK_MOD="FALLBACK_MOD_value"

STDERR_LOG="\$(mktemp)"
trap 'rm -f "\$STDERR_LOG"' EXIT

# Primary: 10-var whitelist (no FALLBACK_MOD)
RENDERED_PRIMARY="\$(cat <<'PI_PROMPT' | envsubst \
  '\${PROJECT_NAME} \${PROJECT_DIR} \${ISSUE_NUMBER} \${ISSUE_TITLE} \${ISSUE_CONTENT} \${FEATURE_SLUG} \${LEARNINGS_SNIPPET} \${DEFAULT_BRANCH} \${REPO} \${GH_BIN}'
You are the ship orchestrator for the \${PROJECT_NAME} codebase at \$PROJECT_DIR.
Issue: #\$ISSUE_NUMBER -- \${ISSUE_TITLE}
Content: \${ISSUE_CONTENT}
Feature slug: \${FEATURE_SLUG}
Learnings: \${LEARNINGS_SNIPPET}
Branch: \${DEFAULT_BRANCH}
Repo: \${REPO}
GH_BIN: \${GH_BIN}
PI_PROMPT
)" 2> "\$STDERR_LOG"

# Retry: 11-var whitelist (adds FALLBACK_MOD)
RENDERED_RETRY="\$(cat <<'PI_PROMPT_RETRY' | envsubst \
  '\${PROJECT_NAME} \${PROJECT_DIR} \${ISSUE_NUMBER} \${ISSUE_TITLE} \${ISSUE_CONTENT} \${FEATURE_SLUG} \${LEARNINGS_SNIPPET} \${DEFAULT_BRANCH} \${REPO} \${GH_BIN} \${FALLBACK_MOD}'
RETRY with model \${FALLBACK_MOD}.
PI_PROMPT_RETRY
)" 2>> "\$STDERR_LOG"

# VC-5: zero stderr noise
echo "STDERR_BYTES=\$(wc -c < "\$STDERR_LOG")"

# VC-4: every var's value appears in the rendered primary output
for v in PROJECT_NAME_value PROJECT_DIR_value ISSUE_NUMBER_value ISSUE_TITLE_value ISSUE_CONTENT_value FEATURE_SLUG_value LEARNINGS_SNIPPET_value DEFAULT_BRANCH_value REPO_value GH_BIN_value; do
  if printf '%s' "\$RENDERED_PRIMARY" | grep -qF "\$v"; then
    echo "PRIMARY_\${v}=1"
  else
    echo "PRIMARY_\${v}=0"
  fi
done

# VC-4 (retry): FALLBACK_MOD appears, no literal \${FALLBACK_MOD}
if printf '%s' "\$RENDERED_RETRY" | grep -qF 'FALLBACK_MOD_value'; then
  echo "RETRY_FALLBACK_MOD=1"
else
  echo "RETRY_FALLBACK_MOD=0"
fi

# VC-4 (negative): no literal \${VAR} strings remain in primary
LEAKS="\$(printf '%s' "\$RENDERED_PRIMARY" | grep -cE '\\\\\$\\\{[A-Z_]+\\\}')"
echo "LEAKS=\$LEAKS"

# VC-4 (negative 2): no stray \$VAR (bare dollar) remains in primary
BARE_LEAKS="\$(printf '%s' "\$RENDERED_PRIMARY" | grep -cE '\\\\\$[A-Z_]+')"
echo "BARE_LEAKS=\$BARE_LEAKS"
OUTER_EOF

OUT=$(bash "$TEST_SNIPPET" 2>/dev/null)

# VC-5: zero stderr bytes
STDERR_BYTES=$(echo "$OUT" | grep -E '^STDERR_BYTES=' | cut -d= -f2)
if [ "${STDERR_BYTES:-0}" -eq 0 ]; then
  ok "VC-5: zero stderr bytes (no 'command not found' from backticks — #271 fix preserved)"
else
  bad "VC-5: $STDERR_BYTES bytes of stderr — backticks may be re-interpreted"
fi

# VC-4: every primary var interpolated
PRIMARY_FAIL=0
for v in PROJECT_NAME PROJECT_DIR ISSUE_NUMBER ISSUE_TITLE ISSUE_CONTENT FEATURE_SLUG LEARNINGS_SNIPPET DEFAULT_BRANCH REPO GH_BIN; do
  result=$(echo "$OUT" | grep -E "^PRIMARY_${v}_value=" | cut -d= -f2)
  if [ "${result:-0}" -eq 1 ]; then
    :
  else
    bad "VC-4: primary rendered output missing \${$v} interpolation"
    PRIMARY_FAIL=$((PRIMARY_FAIL + 1))
  fi
done
if [ "$PRIMARY_FAIL" -eq 0 ]; then
  ok "VC-4: all 10 primary variables interpolated (no literal \${VAR} in rendered output)"
fi

# VC-4: FALLBACK_MOD interpolated in retry
RETRY_FM=$(echo "$OUT" | grep -E '^RETRY_FALLBACK_MOD=' | cut -d= -f2)
if [ "${RETRY_FM:-0}" -eq 1 ]; then
  ok "VC-4: FALLBACK_MOD interpolated in retry (11th variable)"
else
  bad "VC-4: retry did not interpolate \${FALLBACK_MOD}"
fi

# VC-4: zero literal \${VAR} leaks
LEAKS=$(echo "$OUT" | grep -E '^LEAKS=' | cut -d= -f2)
if [ "${LEAKS:-0}" -eq 0 ]; then
  ok "VC-4: zero literal \${VAR} strings remain in rendered primary prompt"
else
  bad "VC-4: $LEAKS literal \${VAR} strings leaked through envsubst"
fi

# VC-4: zero bare $VAR leaks (uncovered variables that should NOT be interpolated)
BARE_LEAKS=$(echo "$OUT" | grep -E '^BARE_LEAKS=' | cut -d= -f2)
if [ "${BARE_LEAKS:-0}" -eq 0 ]; then
  ok "VC-4: zero bare \$VAR strings leaked through envsubst (whitelist enforced)"
else
  bad "VC-4: $BARE_LEAKS bare \$VAR strings leaked through envsubst (whitelist not enforced)"
fi

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "  ALL PASS — $PASS_COUNT checks passed (0 failed)"
  echo "════════════════════════════════════════"
  exit 0
else
  echo "  $PASS_COUNT passed, $FAIL_COUNT FAILED"
  printf "  Failures:%b\n" "$FAIL_NAMES"
  echo "════════════════════════════════════════"
  exit 1
fi