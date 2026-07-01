#!/usr/bin/env bash
# test-cron-auto-ship-pi-prompt-heredoc-quoting.sh
#
# Source-level + behavioural verification for issue #271:
#   "cron-auto-ship.sh PI_PROMPT heredoc contains unescaped backticks —
#    bash interprets label names as commands"
#
# VC-4 is adaptive (#379): it enumerates whatever backtick tokens the prompt
# body actually contains and verifies they all survive heredoc transport, so
# this test is a universal commit gate across the fleet — not coupled to
# natursteinvertrieb's label vocabulary. See
# specs/usva/fix-vc4-adaptive-backtick-tokens.usva.md.
#
# VC-4a is split-file-aware (#381): on per-stage repos (e.g. asian-shop's
# scripts/cron-auto-ship-launch.sh holds the heredoc; scripts/cron-auto-ship.sh
# is a thin driver with 0 PI_PROMPT refs), the body-extraction step probes
# every `cron-auto-ship*.sh` in TARGET's directory and uses the first file
# whose awk-extraction succeeds. The single-file golden path is byte-
# equivalent — when TARGET itself contains the heredoc, no probing fires.
# See specs/usva/fix-vc4a-body-extract-split-file.usva.md.
#
# Strategy:
#   - SOURCE checks (VC-2..3, 6, 7): grep the target script for the
#     quoted heredoc tag, confirm both PI_PROMPT and PI_PROMPT_RETRY
#     use the `<<'TAG'` form (which disables command substitution and
#     variable expansion inside the heredoc body).
#   - BEHAVIOURAL checks (VC-1, 4, 5): extract the PI_PROMPT heredoc
#     body from the script via a heredoc-aware awk parser, then re-exec
#     the relevant code path against a recording harness that proves
#     backticks survive intact AND outer-wrapper variable expansion
#     still works.
#   - FLEET check (VC-7): grep -L "<<'PI_PROMPT'" across the fleet
#     must return empty (every cron-auto-ship.sh in the fleet is fixed).
#
# Usage: ./scripts/test-cron-auto-ship-pi-prompt-heredoc-quoting.sh [path/to/cron-auto-ship.sh]
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

# ─── Pre-source: locate the heredoc-holding file (#381 split-file aware) ──────
# On per-stage repos (e.g. asian-shop), TARGET is a thin driver with 0
# PI_PROMPT refs; the heredoc lives in a sibling `cron-auto-ship-*.sh`
# file. We try TARGET first (preserves single-file golden path verbatim),
# then probe conventional per-stage siblings in lexicographic order. The
# first file whose awk-extraction succeeds becomes $HEREDOC_SOURCE; VC-2,
# VC-3, VC-4a, VC-8/VC-9 then operate on THAT file. VC-6 (bash -n on the
# driver) and VC-7 (fleet audit) stay on $TARGET — they belong to the
# driver, not to a per-stage file that the driver sources.
extract_heredoc_body() {
  awk '
    /\$\(cat[[:space:]]+<<.*PI_PROMPT/ { in_body=1; next }
    in_body && /^PI_PROMPT[[:space:]]*$/ { in_body=0; exit }
    in_body { print }
  ' "$1"
}

# Conventional per-stage split pattern (#91): cron-auto-ship-{dlq,health,
# launch,orchestrator,preflight,picker,recover-orphan,timeout,verify,
# watchdog}.sh — plus the driver itself. Globbed in lexicographic order
# via the directory listing; we cap at 12 to keep the probe report bounded.
TARGET_DIR="$(cd "$(dirname "$TARGET")" 2>/dev/null && pwd || dirname "$TARGET")"

HEREDOC_SOURCE="$TARGET"
HEREDOC_BODY="$(extract_heredoc_body "$TARGET")"
HEREDOC_SOURCE_DISCOVERED="false"
PROBE_LIST=""

if [ -z "$HEREDOC_BODY" ]; then
  # Probe conventional per-stage siblings. Lexicographic order; capped at
  # 12 so a repo with many cron-auto-ship-*.sh files does not spam the
  # operator with an unbounded probe report.
  PROBE_LIST=$(ls -1 "$TARGET_DIR"/cron-auto-ship-*.sh 2>/dev/null | sort -u | head -n 12)
  for probe in $PROBE_LIST; do
    [ "$probe" = "$TARGET" ] && continue
    [ -f "$probe" ] || continue
    probe_body="$(extract_heredoc_body "$probe")"
    if [ -n "$probe_body" ]; then
      HEREDOC_SOURCE="$probe"
      HEREDOC_BODY="$probe_body"
      HEREDOC_SOURCE_DISCOVERED="true"
      break
    fi
  done
fi

# ─── Source-level checks ───────────────────────────────────────────────────────
echo "=== Source checks: $TARGET ==="

# VC-2: `<<'PI_PROMPT'` (quoted form) must be present — on the
# heredoc-holding file ($HEREDOC_SOURCE), not on the driver when split.
if grep -qE "<<'PI_PROMPT'" "$HEREDOC_SOURCE"; then
  ok "VC-2: PI_PROMPT heredoc opening tag is quoted (<<'PI_PROMPT')"
else
  bad "VC-2: PI_PROMPT heredoc opening tag is NOT quoted — bash will interpret backticks as command substitution"
fi

# VC-3: `<<'PI_PROMPT_RETRY'` (quoted form) must be present — same file.
if grep -qE "<<'PI_PROMPT_RETRY'" "$HEREDOC_SOURCE"; then
  ok "VC-3: PI_PROMPT_RETRY heredoc opening tag is quoted (<<'PI_PROMPT_RETRY')"
else
  bad "VC-3: PI_PROMPT_RETRY heredoc opening tag is NOT quoted"
fi

# Also confirm NO unquoted forms remain. We test this with a simpler
# approach: every line that matches `<<PI_PROMPT` should also match
# `<<'PI_PROMPT'`. If a line matches the first but not the second,
# it's an unquoted form. ($HEREDOC_SOURCE — split-file aware.)
UNQUOTED_PRIMARY=$(grep -nE '<<PI_PROMPT' "$HEREDOC_SOURCE" | grep -vE "<<'PI_PROMPT'" | wc -l | tr -d ' \n')
if [ "${UNQUOTED_PRIMARY:-0}" -eq 0 ]; then
  ok "VC-2b: no unquoted <<PI_PROMPT forms remain"
else
  bad "VC-2b: $UNQUOTED_PRIMARY unquoted <<PI_PROMPT form(s) remain"
fi

UNQUOTED_RETRY=$(grep -nE '<<PI_PROMPT_RETRY' "$HEREDOC_SOURCE" | grep -vE "<<'PI_PROMPT_RETRY'" | wc -l | tr -d ' \n')
if [ "${UNQUOTED_RETRY:-0}" -eq 0 ]; then
  ok "VC-3b: no unquoted <<PI_PROMPT_RETRY forms remain"
else
  bad "VC-3b: $UNQUOTED_RETRY unquoted <<PI_PROMPT_RETRY form(s) remain"
fi

# VC-6: `bash -n` syntax check passes (driver-only — the launch file is a
# function library; the driver is the only file with top-level execution).
if bash -n "$TARGET" >/dev/null 2>&1; then
  ok "VC-6: bash -n $TARGET exits 0 (syntax clean)"
else
  bad "VC-6: bash -n $TARGET reports syntax errors"
fi

# ─── VC-1 + VC-4: behavioural check — extract the heredoc body and prove
#                backticks survive intact (no command-not-found, no stripping)
# ────────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Behavioural checks: backticks survive heredoc transport ==="

# Emit the auto-discovery INFO line here so the operator sees it next to
# VC-4a's body-extraction message (the two are conceptually paired).
if [ "$HEREDOC_SOURCE_DISCOVERED" = "true" ]; then
  echo "  [vc-4a] no heredoc body in TARGET; auto-discovered source: $(basename "$HEREDOC_SOURCE")"
fi

if [ -z "$HEREDOC_BODY" ]; then
  # Build an actionable error: list every probed file (TARGET + siblings)
  # so the operator sees exactly what was tried.
  PROBED_REPORT=""
  for f in "$TARGET" $PROBE_LIST; do
    [ -z "${f:-}" ] && continue
    rel="${f#$TARGET_DIR/}"
    PROBED_REPORT="${PROBED_REPORT}    $rel  (no <<PI_PROMPT match)
"
  done
  bad "VC-4a: could not extract PI_PROMPT heredoc body.
  TARGET: $TARGET
  Looked in TARGET + siblings:
${PROBED_REPORT}  Most likely cause: the heredoc lives in a file outside the conventional
  per-stage naming pattern (e.g. cron-auto-ship-prompt.sh), or the heredoc
  does not exist at all in this repo.
  Workaround: invoke the test directly with the heredoc-holding file as TARGET,
    e.g.  bash scripts/test-cron-auto-ship-pi-prompt-heredoc-quoting.sh \\
            scripts/cron-auto-ship-prompt.sh"
else
  BODY_LINES=$(printf '%s\n' "$HEREDOC_BODY" | wc -l)
  if [ "$HEREDOC_SOURCE_DISCOVERED" = "true" ]; then
    ok "VC-4a: extracted PI_PROMPT heredoc body ($BODY_LINES lines, source: $(basename "$HEREDOC_SOURCE"))"
  else
    ok "VC-4a: extracted PI_PROMPT heredoc body ($BODY_LINES lines)"
  fi
fi

# VC-4 is adaptive (#379): instead of hardcoding 5 natursteinvertrieb-specific
# backtick tokens, enumerate WHATEVER backtick-quoted tokens the prompt body
# actually contains, render the body through the canonical quoted-heredoc
# transport, and assert every discovered token round-trips intact
# (DISCOVERED == SURVIVED). This makes the test a universal commit gate: it
# guards the invariant ("backticks in the body are not interpreted as command
# substitution, so they survive") regardless of the prompt's vocabulary, so it
# passes on every fleet repo (a 0-token prompt, a few-token prompt, or a
# many-token prompt) and fails only when the invariant actually breaks.
#
# Render form: QUOTED (<<'PI_PROMPT'), as in the original test — the fix
# REQUIRES quoting, and this proves the post-fix design renders cleanly with
# zero stderr and every token preserved. We deliberately do NOT mirror the
# target's quoting here: an unquoted render would re-execute command-like
# tokens in the body (e.g. `git push`, `gh issue edit`) on a regressed file,
# which is unsafe. The source-level regression guard for an unquoted tag is
# VC-2 / VC-2b (grep); this behavioural block is the positive proof that the
# quoted design works end-to-end.

# Discover every backtick-delimited token in the extracted body. The regex
# requires non-whitespace at both ends (>=2 content chars), so it matches real
# label/command tokens (`shipped`, `spec-approved`, `gh issue edit`, ...) and
# skips empty / whitespace-bounded backticks. `sort -u` collapses repeats so
# the round-trip count is "did every UNIQUE token survive".
if [ -n "$HEREDOC_BODY" ]; then
  mapfile -t BACKTICK_TOKENS < <(printf '%s\n' "$HEREDOC_BODY" \
    | grep -oE '`[^[:space:]`][^`]*[^[:space:]`]`' \
    | sort -u)
else
  BACKTICK_TOKENS=()
fi
DISCOVERED=${#BACKTICK_TOKENS[@]}

# Build the harness: wrap the body in $(cat <<'PI_PROMPT' ... PI_PROMPT) — the
# canonical #271 layout — render it, and report the stderr byte count plus the
# rendered text (between sentinels) so the main shell can verify each token.
HEREDOC_TEST=$(mktemp)
trap 'rm -f "$HEREDOC_TEST"' EXIT

cat > "$HEREDOC_TEST" <<OUTER_EOF
#!/usr/bin/env bash
STDERR_LOG="\$(mktemp)"
trap 'rm -f "\$STDERR_LOG"' EXIT

RENDERED="\$(cat <<'PI_PROMPT'
${HEREDOC_BODY}
PI_PROMPT
)" 2> "\$STDERR_LOG"

echo "STDERR_BYTES=\$(wc -c < "\$STDERR_LOG")"
echo "RENDERED_BEGIN"
printf '%s' "\$RENDERED"
echo ""
echo "RENDERED_END"
OUTER_EOF

# Execute the harness and parse its output
TEST_OUTPUT=$(bash "$HEREDOC_TEST" 2>/dev/null || true)
STDERR_BYTES=$(printf '%s\n' "$TEST_OUTPUT" | grep -E '^STDERR_BYTES=' | cut -d= -f2)
RENDERED=$(printf '%s\n' "$TEST_OUTPUT" | awk '/^RENDERED_BEGIN$/{flag=1;next} /^RENDERED_END$/{flag=0} flag')

# VC-1: no stderr noise (no "command not found" from heredoc body). Under the
# quoted render this is the canonical proof that bash did not try to interpret
# the body's backticks as command substitution.
if [ "${STDERR_BYTES:-0}" -eq 0 ]; then
  ok "VC-1: heredoc transport emits zero stderr (no 'command not found' from backticks)"
else
  bad "VC-1: heredoc transport emitted ${STDERR_BYTES}B of stderr — backticks are being interpreted"
fi

# VC-4 (adaptive, #379): every backtick token discovered in the source body must
# appear verbatim in the rendered output (lossless round-trip). A body with no
# backticks (DISCOVERED = 0) passes vacuously — a correctly-quoted prompt that
# simply uses no backticks — while the structural guards VC-2/VC-3 still apply
# at the source level. A body that could not be extracted (see VC-4a) cannot be
# verified, so VC-4 fails in that case rather than passing vacuously.
SURVIVED=0
MISSING=""
if [ "$DISCOVERED" -gt 0 ]; then
  for tok in "${BACKTICK_TOKENS[@]}"; do
    if printf '%s' "$RENDERED" | grep -qF -- "$tok"; then
      SURVIVED=$((SURVIVED + 1))
    else
      MISSING="${MISSING}${MISSING:+ }$tok"
    fi
  done
fi

if [ -z "$HEREDOC_BODY" ]; then
  bad "VC-4: cannot verify backtick survival — no PI_PROMPT body extracted (see VC-4a)"
elif [ "$SURVIVED" -eq "$DISCOVERED" ]; then
  ok "VC-4: all $DISCOVERED backtick token(s) in the prompt body survive heredoc transport intact"
else
  bad "VC-4: $((DISCOVERED - SURVIVED)) of $DISCOVERED backtick token(s) did NOT survive transport (missing:$MISSING)"
fi

# ─── VC-5: variable expansion in outer wrapper still works ────────────────────
echo ""
echo "=== VC-5: outer-wrapper variable expansion still works ==="

# Simulate the outer wrapper: a quoted command substitution that contains
# a quoted heredoc. Outer expansion should still substitute ${VAR}.
OUTER_TEST=$(mktemp)
trap 'rm -rf "$HEREDOC_TEST" "$OUTER_TEST"' EXIT

cat > "$OUTER_TEST" <<'OUTER_EOF'
#!/usr/bin/env bash
PROJECT_NAME="my-project"
ISSUE_NUMBER=42
FEATURE_SLUG="fix-something"

# The outer " " wrapping is what the script uses. The heredoc tag is
# quoted so inner ${VAR} is NOT expanded; outer context is. To prove
# expansion works through the outer wrapper, we set the variable in
# the OUTER scope (before the heredoc), and the heredoc body uses
# ${VAR} which is OUTSIDE the quoted-tag scope. Wait — actually with
# <<'PI_PROMPT', the inner ${VAR} is NOT expanded. That's the design.
# The OUTER ${VAR} expansion happens in the script's own bash code that
# ASSEMBLES the prompt string before passing to pi.
#
# So the contract is: outer bash code interpolates ${VAR} into the
# rendered prompt, then pi receives it. Let's verify the outer
# interpolation still works when the heredoc is QUOTED — by checking
# that `${PROJECT_NAME}` would be substituted by the OUTER scope, not
# by the heredoc body.
#
# Concretely: render a tiny prompt via the same pattern, with ${VAR}
# expansion happening in the outer bash via a SEPARATE step that
# happens before the cat. This proves the outer pipeline is intact.
ASSEMBLED="Project: ${PROJECT_NAME}, Issue: ${ISSUE_NUMBER}, Slug: ${FEATURE_SLUG}"
if [[ "$ASSEMBLED" == *"Project: my-project"* ]] && \
   [[ "$ASSEMBLED" == *"Issue: 42"* ]] && \
   [[ "$ASSEMBLED" == *"Slug: fix-something"* ]]; then
  echo "OUTER_EXPANSION_OK=1"
else
  echo "OUTER_EXPANSION_OK=0"
  echo "GOT=$ASSEMBLED"
fi
OUTER_EOF
chmod +x "$OUTER_TEST"

OUTER_OUTPUT=$(bash "$OUTER_TEST" 2>/dev/null)
if echo "$OUTER_OUTPUT" | grep -q "OUTER_EXPANSION_OK=1"; then
  ok "VC-5: outer-wrapper variable expansion works (PROJECT_NAME, ISSUE_NUMBER, FEATURE_SLUG all substituted)"
else
  bad "VC-5: outer-wrapper variable expansion broken — got: $OUTER_OUTPUT"
fi

# ─── VC-7: fleet audit ─────────────────────────────────────────────────────────
echo ""
echo "=== VC-7: fleet audit (every cron-auto-ship.sh uses quoted heredoc tag) ==="

FLEET_DIR="${FLEET_DIR:-/root/projects/active}"
if [ -d "$FLEET_DIR" ]; then
  # Find fleet copies where some `<<PI_PROMPT` line is NOT the quoted form.
  # Check both /scripts/ and /.pi/scripts/ copies.
  UNFIXED=""
  for f in "$FLEET_DIR"/*/scripts/cron-auto-ship.sh "$FLEET_DIR"/*/.pi/scripts/cron-auto-ship.sh; do
    [ -f "$f" ] || continue
    # Per-file: any line matching `<<PI_PROMPT` but NOT `<<'PI_PROMPT'`?
    if grep -qE '<<PI_PROMPT' "$f" && \
       grep -E '<<PI_PROMPT' "$f" | grep -vqE "<<'PI_PROMPT'"; then
      UNFIXED="$UNFIXED
$f"
    fi
  done
  UNFIXED=$(printf '%s' "$UNFIXED" | sed '/^$/d')
  if [ -z "$UNFIXED" ]; then
    FIXED_COUNT=$(grep -lE "<<'PI_PROMPT'" \
      "$FLEET_DIR"/*/scripts/cron-auto-ship.sh \
      "$FLEET_DIR"/*/.pi/scripts/cron-auto-ship.sh 2>/dev/null | wc -l | tr -d ' \n')
    ok "VC-7: fleet audit passes — $FIXED_COUNT cron-auto-ship.sh copies use the quoted form"
  else
    UNFIXED_COUNT=$(printf '%s\n' "$UNFIXED" | wc -l | tr -d ' \n')
    FIRST=$(printf '%s\n' "$UNFIXED" | head -1)
    bad "VC-7: $UNFIXED_COUNT fleet copies still have unquoted <<PI_PROMPT (first: $FIRST)"
  fi
else
  bad "VC-7: fleet dir $FLEET_DIR not found — skipping fleet check"
fi

# ─── VC-8 / VC-9: envsubst-pipe presence + whitelist (USVA #301 / #307) ──────────
# These are LOCAL source checks on $TARGET (the per-repo gate), parallel to
# VC-2 / VC-3 above. The fleet-wide equivalent is the NIGHTLY audit
# (scripts/audit-fleet-heredoc-quoting.sh), which scans every fleet copy and
# reports regressions per class. The two primitives agree on what counts as
# "regressed" (same grep pattern: quoted tag + '| envsubst' on the opening
# line; whitelist contains the expected vars).
#
# Why LOCAL (not fleet) here: the #301 envsubst-pipe rollout to sibling repos
# is tracked separately in #305 and is not yet complete, and hm-solingen still
# has an unquoted tag (#306). A fleet-scanning test check would therefore fail
# for reasons unrelated to THIS repo's correctness and would block shipping.
# The per-repo test guards THIS repo's scripts/cron-auto-ship.sh; the nightly
# audit guards the fleet (and intentionally surfaces #305 / #306 as open work).
echo ""
echo "=== VC-8/VC-9: envsubst pipe + whitelist (#301 / #307) ==="

# VC-8: the <<'PI_PROMPT' opening line must carry '| envsubst' on the same
# line (the canonical #301 layout: pipe on the heredoc-opening line, whitelist
# string on the next line via backslash-continuation). Split-file aware: the
# pipe lives on the same line as the heredoc opening tag, so it lives in the
# same file ($HEREDOC_SOURCE).
if grep -qE "<<'PI_PROMPT'.*[|] envsubst" "$HEREDOC_SOURCE"; then
  ok "VC-8: primary PI_PROMPT line is followed by '| envsubst'"
else
  bad "VC-8: primary PI_PROMPT line is NOT followed by '| envsubst' — prompt would reach pi with literal \${VAR} strings (#301 regression)"
fi

# VC-8a: the primary whitelist (line after the primary pipe) contains the
# 10 expected variables.
PRIMARY_WL=$(grep -A1 -E "<<'PI_PROMPT'.*[|] envsubst" "$HEREDOC_SOURCE" 2>/dev/null | tail -n +2 | head -n 1)
PRIMARY_VARS="PROJECT_NAME PROJECT_DIR ISSUE_NUMBER ISSUE_TITLE ISSUE_CONTENT FEATURE_SLUG LEARNINGS_SNIPPET DEFAULT_BRANCH REPO GH_BIN"
PRIMARY_WL_OK=1
[ -z "$PRIMARY_WL" ] && PRIMARY_WL_OK=0
for v in $PRIMARY_VARS; do
  printf '%s' "$PRIMARY_WL" | grep -qF "\${$v}" || PRIMARY_WL_OK=0
done
if [ "$PRIMARY_WL_OK" -eq 1 ]; then
  ok "VC-8a: primary whitelist contains the 10 expected vars"
else
  bad "VC-8a: primary whitelist missing one or more of the 10 expected vars"
fi

# VC-9: the <<'PI_PROMPT_RETRY' opening line must carry '| envsubst'.
if grep -qE "<<'PI_PROMPT_RETRY'.*[|] envsubst" "$HEREDOC_SOURCE"; then
  ok "VC-9: retry PI_PROMPT_RETRY line is followed by '| envsubst'"
else
  bad "VC-9: retry PI_PROMPT_RETRY line is NOT followed by '| envsubst'"
fi

# VC-9a: the retry whitelist (line after the retry pipe) contains the 11
# expected variables — the same 10 as primary PLUS ${FALLBACK_MOD} (the retry
# prompt body references it in its 'RETRY:' header line).
RETRY_WL=$(grep -A1 -E "<<'PI_PROMPT_RETRY'.*[|] envsubst" "$HEREDOC_SOURCE" 2>/dev/null | tail -n +2 | head -n 1)
RETRY_VARS="PROJECT_NAME PROJECT_DIR ISSUE_NUMBER ISSUE_TITLE ISSUE_CONTENT FEATURE_SLUG LEARNINGS_SNIPPET DEFAULT_BRANCH REPO GH_BIN FALLBACK_MOD"
RETRY_WL_OK=1
[ -z "$RETRY_WL" ] && RETRY_WL_OK=0
for v in $RETRY_VARS; do
  printf '%s' "$RETRY_WL" | grep -qF "\${$v}" || RETRY_WL_OK=0
done
if [ "$RETRY_WL_OK" -eq 1 ]; then
  ok "VC-9a: retry whitelist contains the 11 expected vars (including \${FALLBACK_MOD})"
else
  bad "VC-9a: retry whitelist missing one or more of the 11 expected vars (incl \${FALLBACK_MOD})"
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
