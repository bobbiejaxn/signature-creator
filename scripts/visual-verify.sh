#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# visual-verify.sh — Post-deploy visual verification via playwright-cli
# ──────────────────────────────────────────────────────────────────────────────
# Opens the live site in a headless browser, takes a screenshot, analyzes
# the page structure via accessibility snapshot, and checks for common
# visual regressions (blank pages, missing content, broken layouts).
#
# Built on the Bowser pattern (github.com/disler/bowser):
#   playwright-cli for token-efficient browser automation
#   Accessibility tree for structural analysis (not pixel guessing)
#   Screenshots for human review
#
# Usage:
#   ./scripts/visual-verify.sh                    # uses PROD_URL from config
#   ./scripts/visual-verify.sh https://example.com
#   ./scripts/visual-verify.sh https://example.com /path/to/golden.png
#
# Exit codes:
#   0 = visual check passed
#   1 = visual issues detected
#   2 = site unreachable
#   3 = playwright-cli not available (soft skip)
#
# Config (.pi/config.sh):
#   PROD_URL          — production URL to verify (required)
#   GOLDEN_SCREENSHOT — path to reference screenshot for comparison (optional)
#   VISUAL_VERIFY     — set to "false" to skip (default: true)
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/.pi/config.sh" 2>/dev/null || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Config
URL="${1:-${PROD_URL:-}}"
GOLDEN="${2:-${GOLDEN_SCREENSHOT:-}}"
VISUAL_VERIFY="${VISUAL_VERIFY:-true}"
PROJECT_SLUG="${PROJECT_NAME:-$(basename "$REPO_ROOT")}"
VERIFY_DIR="${VERIFY_DIR:-$REPO_ROOT/.visual-verify}"
SESSION_NAME="verify-${PROJECT_SLUG}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SCREENSHOT_PATH="$VERIFY_DIR/screenshot-${TIMESTAMP}.png"
SNAPSHOT_PATH="$VERIFY_DIR/snapshot-${TIMESTAMP}.txt"
RESULT_PATH="$VERIFY_DIR/result-${TIMESTAMP}.txt"

mkdir -p "$VERIFY_DIR"

# ─── Preflight ────────────────────────────────────────────────────────────────

if [[ "$VISUAL_VERIFY" == "false" ]]; then
    echo -e "${YELLOW}[visual-verify] Skipped (VISUAL_VERIFY=false)${NC}"
    exit 0
fi

if [[ -z "$URL" ]]; then
    echo -e "${YELLOW}[visual-verify] Skipped — no PROD_URL in config and no URL argument${NC}"
    exit 0
fi

if ! command -v playwright-cli &> /dev/null; then
    echo -e "${YELLOW}[visual-verify] playwright-cli not found — install with: npm install -g @playwright/cli${NC}"
    exit 3
fi

# ─── Check site is reachable ─────────────────────────────────────────────────

echo -e "${CYAN}[visual-verify] Checking $URL ...${NC}"

HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "$URL" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "000" ]]; then
    echo -e "${RED}[visual-verify] FAIL — site unreachable: $URL${NC}"
    echo "STATUS=unreachable" > "$RESULT_PATH"
    exit 2
fi

echo -e "${GREEN}[visual-verify] Site reachable (HTTP $HTTP_CODE)${NC}"

# ─── Open browser and navigate ───────────────────────────────────────────────

echo -e "${CYAN}[visual-verify] Opening browser session: $SESSION_NAME${NC}"

# Clean up any previous session
playwright-cli -s="$SESSION_NAME" close 2>/dev/null || true

# Open and navigate
playwright-cli -s="$SESSION_NAME" open "$URL" 2>/dev/null

# Wait for page to load
sleep 5

# ─── Take screenshot ─────────────────────────────────────────────────────────

echo -e "${CYAN}[visual-verify] Taking screenshot...${NC}"
playwright-cli -s="$SESSION_NAME" screenshot "$SCREENSHOT_PATH" 2>/dev/null || true

# ─── Get accessibility snapshot ──────────────────────────────────────────────

echo -e "${CYAN}[visual-verify] Capturing accessibility snapshot...${NC}"
playwright-cli -s="$SESSION_NAME" snapshot > "$SNAPSHOT_PATH" 2>/dev/null || true

# ─── Close browser ───────────────────────────────────────────────────────────

playwright-cli -s="$SESSION_NAME" close 2>/dev/null || true

# ─── Analyze results ─────────────────────────────────────────────────────────

ISSUES=()

# Check 1: Screenshot file size (blank pages are small)
if [[ -f "$SCREENSHOT_PATH" ]]; then
    FILESIZE=$(stat -c%s "$SCREENSHOT_PATH" 2>/dev/null || stat -f%z "$SCREENSHOT_PATH" 2>/dev/null || echo "0")
    if [[ "$FILESIZE" -lt 30000 ]]; then
        ISSUES+=("BLANK_PAGE: Screenshot only ${FILESIZE} bytes — page is likely mostly blank/white")
    elif [[ "$FILESIZE" -lt 80000 ]]; then
        ISSUES+=("SPARSE_CONTENT: Screenshot only ${FILESIZE} bytes — may be missing images or content")
    fi
    echo -e "${GREEN}[visual-verify] Screenshot: $SCREENSHOT_PATH (${FILESIZE} bytes)${NC}"
else
    ISSUES+=("NO_SCREENSHOT: Failed to capture screenshot")
fi

# Check 2: Accessibility snapshot analysis
if [[ -f "$SNAPSHOT_PATH" && -s "$SNAPSHOT_PATH" ]]; then
    SNAP_LINES=$(wc -l < "$SNAPSHOT_PATH")

    # A healthy page has many elements (> 20 lines in snapshot)
    if [[ "$SNAP_LINES" -lt 10 ]]; then
        ISSUES+=("EMPTY_DOM: Only $SNAP_LINES elements in accessibility tree — page may be blank or broken")
    fi

    # Check for error indicators in the snapshot
    if grep -qi "error\|exception\|crashed\|500\|404.*not found" "$SNAPSHOT_PATH" 2>/dev/null; then
        ERROR_TEXT=$(grep -i "error\|exception\|crashed\|500\|404.*not found" "$SNAPSHOT_PATH" | head -3)
        ISSUES+=("ERROR_VISIBLE: Error text found on page: $ERROR_TEXT")
    fi

    # Check for loading spinners still present (page didn't finish loading)
    if grep -qi "loading\|spinner\|skeleton" "$SNAPSHOT_PATH" 2>/dev/null; then
        LOADING_COUNT=$(grep -ci "loading\|spinner\|skeleton" "$SNAPSHOT_PATH")
        if [[ "$LOADING_COUNT" -gt 3 ]]; then
            ISSUES+=("STILL_LOADING: $LOADING_COUNT loading/spinner elements — page may not have finished loading")
        fi
    fi

    echo -e "${GREEN}[visual-verify] Snapshot: $SNAPSHOT_PATH ($SNAP_LINES elements)${NC}"
else
    ISSUES+=("NO_SNAPSHOT: Failed to capture accessibility snapshot")
fi

# Check 3: Golden comparison
if [[ -n "$GOLDEN" && -f "$GOLDEN" && -f "$SCREENSHOT_PATH" ]]; then
    GOLDEN_SIZE=$(stat -c%s "$GOLDEN" 2>/dev/null || stat -f%z "$GOLDEN" 2>/dev/null || echo "0")
    CURRENT_SIZE=$FILESIZE
    if [[ "$GOLDEN_SIZE" -gt 0 ]]; then
        SIZE_DIFF=$(( (CURRENT_SIZE - GOLDEN_SIZE) * 100 / GOLDEN_SIZE ))
        SIZE_DIFF_ABS=${SIZE_DIFF#-}
        if [[ "$SIZE_DIFF_ABS" -gt 50 ]]; then
            ISSUES+=("GOLDEN_MISMATCH: Screenshot differs ${SIZE_DIFF_ABS}% from reference (current: ${CURRENT_SIZE}b, golden: ${GOLDEN_SIZE}b)")
        else
            echo -e "${GREEN}[visual-verify] Within ${SIZE_DIFF_ABS}% of golden reference${NC}"
        fi
    fi
fi

# ─── Report ──────────────────────────────────────────────────────────────────

{
    echo "URL=$URL"
    echo "HTTP_CODE=$HTTP_CODE"
    echo "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "SCREENSHOT=$SCREENSHOT_PATH"
    echo "SNAPSHOT=$SNAPSHOT_PATH"
    echo "SCREENSHOT_SIZE=${FILESIZE:-0}"
    echo "SNAPSHOT_LINES=${SNAP_LINES:-0}"
    echo "ISSUE_COUNT=${#ISSUES[@]}"
} > "$RESULT_PATH"

if [[ ${#ISSUES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  VISUAL VERIFY FAILED: $URL${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    for issue in "${ISSUES[@]}"; do
        echo -e "  ${RED}✗${NC} $issue"
        echo "ISSUE=$issue" >> "$RESULT_PATH"
    done
    echo ""
    echo -e "  Screenshot: $SCREENSHOT_PATH"
    echo -e "  Snapshot:   $SNAPSHOT_PATH"
    echo ""
    echo "RESULT=FAIL" >> "$RESULT_PATH"
    exit 1
else
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  VISUAL VERIFY PASSED: $URL${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  HTTP:       $HTTP_CODE"
    echo -e "  Screenshot: ${FILESIZE:-?} bytes"
    echo -e "  DOM:        ${SNAP_LINES:-?} elements"
    echo ""
    echo "RESULT=PASS" >> "$RESULT_PATH"
    exit 0
fi
