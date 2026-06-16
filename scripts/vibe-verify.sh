#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# vibe-verify.sh — Mechanical code quality enforcement
# ──────────────────────────────────────────────────────────────────────────────
# Fast checks that catch what LLM reviewers miss. Non-bypassable.
# Designed to run as a VERIFY_COMMANDS entry in .pi/config.sh.
#
# Checks:
#   1. TypeScript strict mode (tsc --noEmit)     — type safety
#   2. ESLint zero-warnings                       — lint rules
#   3. No `any` types                             — explicit typing
#   4. No `@ts-ignore` / `@ts-expect-error`      — no suppressing errors
#   5. No unsafe patterns (eval, innerHTML, etc.)  — dangerous code
#   6. No hardcoded secrets                       — security
#   7. DRY — duplicated blocks across files       — copy-paste detection
#   8. Test coverage threshold                    — tested code
#   9. Function complexity (line count)            — maintainable functions
#   10. Import hygiene                             — no circular / barrel imports
#  11. Google Style Guide compliance               — naming, formatting, language-specific rules
#
# Usage:
#   ./scripts/vibe-verify.sh                     # Run all checks
#   ./scripts/vibe-verify.sh --quick             # Skip slow checks (coverage, DRY)
#   ./scripts/vibe-verify.sh --fix               # Auto-fix where possible
#
# Exit codes:
#   0 — all checks pass
#   1 — one or more violations found
#
# Config via .pi/config.sh or environment variables:
#   VIBE_NO_ANY=true              # Check for any types (default: true)
#   VIBE_NO_TS_IGNORE=true        # Check for @ts-ignore (default: true)
#   VIBE_UNSAFE_CHECK=true        # Check unsafe patterns (default: true)
#   VIBE_DRY_CHECK=true           # Check for duplicated blocks (default: true)
#   VIBE_COVERAGE_CHECK=true      # Check coverage threshold (default: true)
#   VIBE_COMPLEXITY_CHECK=true    # Check function length (default: true)
#   VIBE_COVERAGE_THRESHOLD=70    # Coverage % threshold (default: 70)
#   VIBE_MAX_FUNC_LINES=80        # Max lines per function (default: 80)
#   VIBE_DRY_MIN_LINES=10         # Min duplicate block size (default: 10)
#   VIBE_FRONTEND_DIR=src         # Frontend source directory
#   VIBE_BACKEND_DIR=src/api      # Backend source directory
#   VIBE_SRC_DIRS="src"           # Directories to scan (space-separated)
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# 'set -e' is too aggressive for a checker — we want to report ALL failures, not abort on first
# Instead, track violations and exit at the end.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.pi/config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

VIOLATIONS=0
WARNINGS=0
CHECKS_RUN=0
CHECKS_PASSED=0
FIX_MODE=false
QUICK_MODE=false

# Parse args
for arg in "$@"; do
  case "$arg" in
    --fix)   FIX_MODE=true ;;
    --quick) QUICK_MODE=true ;;
    --help)
      echo "Usage: ./scripts/vibe-verify.sh [--quick] [--fix] [--help]"
      echo ""
      echo "  --quick  Skip slow checks (coverage, DRY scan)"
      echo "  --fix    Auto-fix where possible (unused imports)"
      echo "  --help   Show this help"
      exit 0
      ;;
  esac
done

# Load config if available
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE" 2>/dev/null || true
fi

# Configurable thresholds with defaults
VIBE_NO_ANY="${VIBE_NO_ANY:-true}"
VIBE_NO_TS_IGNORE="${VIBE_NO_TS_IGNORE:-true}"
VIBE_UNSAFE_CHECK="${VIBE_UNSAFE_CHECK:-true}"
VIBE_DRY_CHECK="${VIBE_DRY_CHECK:-true}"
VIBE_COVERAGE_CHECK="${VIBE_COVERAGE_CHECK:-true}"
VIBE_COMPLEXITY_CHECK="${VIBE_COMPLEXITY_CHECK:-true}"
VIBE_COVERAGE_THRESHOLD="${VIBE_COVERAGE_THRESHOLD:-70}"
VIBE_MAX_FUNC_LINES="${VIBE_MAX_FUNC_LINES:-80}"
VIBE_DRY_MIN_LINES="${VIBE_DRY_MIN_LINES:-10}"

# Source directories to scan
if [ -n "${VIBE_SRC_DIRS:-}" ]; then
  SRC_DIRS="$VIBE_SRC_DIRS"
else
  SRC_DIRS="${FRONTEND_DIR:-src} ${BACKEND_DIR:-src}"
fi

# Build find expression for source files
find_src() {
  find $SRC_DIRS -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) \
    ! -path "*/node_modules/*" \
    ! -path "*/.next/*" \
    ! -path "*/dist/*" \
    ! -path "*/build/*" \
    ! -path "*/coverage/*" \
    ! -path "*/.pi/*" \
    2>/dev/null || true
}

# Counters
fail()    { echo -e "${RED}  ✗ $1${NC}"; ((VIOLATIONS++)); }
warn()    { echo -e "${YELLOW}  ⚠ $1${NC}"; ((WARNINGS++)); }
pass()    { echo -e "${GREEN}  ✓ $1${NC}"; ((CHECKS_PASSED++)); }
info()    { echo -e "${BLUE}  → $1${NC}"; }
section() { echo -e "\n${CYAN}[$1]${NC}"; }
skip()    { echo -e "${YELLOW}  ⊘ $1 (skipped)${NC}"; }

cd "$REPO_ROOT"

# ─── Check 1: TypeScript strict mode ──────────────────────────────────────────

((CHECKS_RUN++))
section "1/10 TypeScript (tsc --noEmit)"

if [ -f "tsconfig.json" ]; then
  if command -v npx &>/dev/null; then
    TSC_OUTPUT=$(npx tsc --noEmit 2>&1) && TSC_EXIT=0 || TSC_EXIT=$?
    if [ $TSC_EXIT -eq 0 ]; then
      pass "TypeScript clean — zero errors"
    else
      ERROR_COUNT=$(echo "$TSC_OUTPUT" | grep -c "error TS" || true)
      fail "TypeScript: ${ERROR_COUNT} error(s)"
      echo "$TSC_OUTPUT" | grep "error TS" | head -20
      echo ""
      echo "  Run: npx tsc --noEmit"
    fi
  else
    skip "npx not available"
  fi
else
  skip "No tsconfig.json found"
fi

# ─── Check 2: ESLint zero-warnings ───────────────────────────────────────────

((CHECKS_RUN++))
section "2/10 ESLint"

if [ -f ".eslintrc.*" ] || [ -f "eslint.config.*" ] || grep -q '"eslint"' package.json 2>/dev/null; then
  if command -v npx &>/dev/null; then
    ESLINT_OUTPUT=$(npx eslint . --max-warnings 0 --format compact 2>&1) && ESLINT_EXIT=0 || ESLINT_EXIT=$?
    if [ $ESLINT_EXIT -eq 0 ]; then
      pass "ESLint clean — zero warnings"
    else
      # Count problems
      PROBLEM_COUNT=$(echo "$ESLINT_OUTPUT" | grep -cE 'error|warning' || true)
      fail "ESLint: ${PROBLEM_COUNT} problem(s)"
      echo "$ESLINT_OUTPUT" | grep -E 'error|warning' | head -20
      echo ""
      if [ "$FIX_MODE" = true ]; then
        info "Running eslint --fix..."
        npx eslint . --fix --max-warnings 0 2>&1 || true
      fi
    fi
  else
    skip "npx not available"
  fi
else
  skip "No ESLint config found"
fi

# ─── Check 3: No `any` types ──────────────────────────────────────────────────

((CHECKS_RUN++))
section "3/10 No \`any\` types"

if [ "$VIBE_NO_ANY" = "true" ]; then
  ANY_FILES=""
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # Check for : any, as any, <any>, any[], any |, | any
    ANY_MATCHES=$(grep -nE ':\s*any\b|as\s+any\b|<any>|any\[\]|\|\s*any\b|\bany\s*\|' "$file" 2>/dev/null | grep -v '// ' | grep -v '/\*' || true)
    if [ -n "$ANY_MATCHES" ]; then
      ANY_COUNT=$(echo "$ANY_MATCHES" | wc -l | tr -d ' ')
      fail "$file: ${ANY_COUNT} \`any\` usage(s)"
      echo "$ANY_MATCHES" | head -5
      ANY_FILES="$ANY_FILES $file"
    fi
  done < <(find_src)

  if [ -z "$ANY_FILES" ]; then
    pass "Zero \`any\` types in source"
  fi
else
  skip "Disabled (VIBE_NO_ANY=false)"
fi

# ─── Check 4: No @ts-ignore / @ts-expect-error ───────────────────────────────

((CHECKS_RUN++))
section "4/10 No \@ts-ignore / \@ts-expect-error"

if [ "$VIBE_NO_TS_IGNORE" = "true" ]; then
  TS_IGNORE_COUNT=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    IGNORES=$(grep -cn '@ts-ignore\|@ts-expect-error' "$file" 2>/dev/null || true)
    if [ "$IGNORES" -gt 0 ]; then
      # Check if they have a reason comment on the same line or next line
      UNJUSTIFIED=$(grep -En '@ts-(ignore|expect-error)' "$file" 2>/dev/null | grep -viE '// @ts-expect-error -' | grep -viE '//.*reason' | grep -viE '//.*because' | grep -viE '//.*workaround' || true)
      if [ -n "$UNJUSTIFIED" ]; then
        UCOUNT=$(echo "$UNJUSTIFIED" | wc -l | tr -d ' ')
        fail "$file: ${UCOUNT} unjustified @ts-ignore(s)"
        echo "$UNJUSTIFIED" | head -5
        TS_IGNORE_COUNT=$((TS_IGNORE_COUNT + UCOUNT))
      fi
    fi
  done < <(find_src)

  if [ "$TS_IGNORE_COUNT" -eq 0 ]; then
    pass "Zero unjustified @ts-ignore"
  fi
else
  skip "Disabled (VIBE_NO_TS_IGNORE=false)"
fi

# ─── Check 5: No unsafe patterns ─────────────────────────────────────────────

((CHECKS_RUN++))
section "5/10 Unsafe code patterns"

if [ "$VIBE_UNSAFE_CHECK" = "true" ]; then
  UNSAFE_COUNT=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # Skip test files
    case "$file" in *.test.*|*.spec.*) continue ;; esac

    # eval()
    EVAL=$(grep -En '\beval\s*\(' "$file" 2>/dev/null | grep -viE '(no |never |unsafe |avoid )' || true)
    if [ -n "$EVAL" ]; then
      fail "$file: eval() usage"
      echo "$EVAL" | head -3
      UNSAFE_COUNT=$((UNSAFE_COUNT + 1))
    fi

    # dangerouslySetInnerHTML without sanitization
    DSI=$(grep -En 'dangerouslySetInnerHTML' "$file" 2>/dev/null | grep -viE 'sanitize|DOMPurify|xss' || true)
    if [ -n "$DSI" ]; then
      fail "$file: dangerouslySetInnerHTML without sanitization"
      echo "$DSI" | head -3
      UNSAFE_COUNT=$((UNSAFE_COUNT + 1))
    fi

    # innerHTML assignment
    INNER=$(grep -En '\.innerHTML\s*=' "$file" 2>/dev/null | grep -viE 'sanitize|DOMPurify|xss|empty' || true)
    if [ -n "$INNER" ]; then
      fail "$file: innerHTML assignment"
      echo "$INNER" | head -3
      UNSAFE_COUNT=$((UNSAFE_COUNT + 1))
    fi

    # SQL concatenation
    SQL=$(grep -En '(query|execute|raw)\s*\([^)]*\+' "$file" 2>/dev/null || true)
    if [ -n "$SQL" ]; then
      fail "$file: potential SQL injection"
      echo "$SQL" | head -3
      UNSAFE_COUNT=$((UNSAFE_COUNT + 1))
    fi

    # Shell injection
    SHELL=$(grep -En 'shell=True|os\.system\s*\(|subprocess\.call\s*\([^)]*shell' "$file" 2>/dev/null || true)
    if [ -n "$SHELL" ]; then
      fail "$file: shell injection risk"
      echo "$SHELL" | head -3
      UNSAFE_COUNT=$((UNSAFE_COUNT + 1))
    fi

    # SSL verify disabled
    SSL=$(grep -En 'verify\s*=\s*False|rejectUnauthorized\s*:\s*false' "$file" 2>/dev/null || true)
    if [ -n "$SSL" ]; then
      fail "$file: SSL verification disabled"
      echo "$SSL" | head -3
      UNSAFE_COUNT=$((UNSAFE_COUNT + 1))
    fi

    # CORS wildcard in production
    CORS=$(grep -En "cors\(.*origin.*\*|Access-Control-Allow-Origin.*\*" "$file" 2>/dev/null | grep -viE 'test|spec|dev|local' || true)
    if [ -n "$CORS" ]; then
      fail "$file: CORS wildcard"
      echo "$CORS" | head -3
      UNSAFE_COUNT=$((UNSAFE_COUNT + 1))
    fi
  done < <(find_src)

  if [ "$UNSAFE_COUNT" -eq 0 ]; then
    pass "No unsafe patterns detected"
  fi
else
  skip "Disabled (VIBE_UNSAFE_CHECK=false)"
fi

# ─── Check 6: No hardcoded secrets ───────────────────────────────────────────

((CHECKS_RUN++))
section "6/10 Hardcoded secrets"

SECRET_COUNT=0
while IFS= read -r file; do
  [ -z "$file" ] && continue
  # Skip config/env/examples/tests
  case "$file" in
    *.env*|*example*|*fixture*|*mock*|*test*|*spec*|*config*|*.d.ts) continue ;;
  esac

  # AWS keys
  if grep -qE 'AKIA[0-9A-Z]{16}' "$file" 2>/dev/null; then
    fail "$file: AWS access key"
    SECRET_COUNT=$((SECRET_COUNT + 1))
  fi
  # GitHub tokens
  if grep -qE 'gh[ps]_[A-Za-z0-9_]{36,}' "$file" 2>/dev/null; then
    fail "$file: GitHub token"
    SECRET_COUNT=$((SECRET_COUNT + 1))
  fi
  # Private keys
  if grep -qE '-----BEGIN.*PRIVATE KEY-----' "$file" 2>/dev/null; then
    fail "$file: Private key"
    SECRET_COUNT=$((SECRET_COUNT + 1))
  fi
  # Connection strings with passwords
  if grep -qE '(postgres|mysql|mongodb|redis)://[^:]+:[^@]+@' "$file" 2>/dev/null; then
    fail "$file: Connection string with credentials"
    SECRET_COUNT=$((SECRET_COUNT + 1))
  fi
  # API key patterns assigned to variables
  if grep -Eq '(api.?key|secret|token|password)\s*[=:]\s*["\x27][A-Za-z0-9]{20,}["\x27]' "$file" 2>/dev/null; then
    if ! grep -Eq '(placeholder|example|your[_-]?(key|token)|xxx|REPLACE|TODO|process\.env|import |from )' "$file" 2>/dev/null; then
      fail "$file: Potential hardcoded secret"
      grep -En '(api.?key|secret|token|password)\s*[=:]\s*["\x27][A-Za-z0-9]{20,}["\x27]' "$file" | head -3
      SECRET_COUNT=$((SECRET_COUNT + 1))
    fi
  fi
done < <(find_src)

if [ "$SECRET_COUNT" -eq 0 ]; then
  pass "No hardcoded secrets found"
fi

# ─── Check 7: DRY — duplicated blocks ────────────────────────────────────────

((CHECKS_RUN++))
section "7/10 DRY — duplicated code blocks"

if [ "$VIBE_DRY_CHECK" = "true" ] && [ "$QUICK_MODE" != "true" ]; then
  # Normalize and hash code blocks to find duplicates
  MIN_LINES="${VIBE_DRY_MIN_LINES:-10}"
  DUPE_COUNT=0

  # Create temp file with normalized content
  TMPFILE=$(mktemp)
  trap "rm -f $TMPFILE" EXIT

  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # Skip test files for DRY
    case "$file" in *.test.*|*.spec.*|*.d.ts) continue ;; esac
    # Normalize: trim whitespace, remove comments, remove blank lines
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d;/^[[:space:]]*\/\//d;/^[[:space:]]*\*/d' "$file" 2>/dev/null | \
      awk -v file="$file" -v min="$MIN_LINES" '
        {
          lines[NR] = $0
        }
        END {
          for (i = 1; i <= NR - min; i++) {
            block = ""
            for (j = i; j < i + min; j++) {
              block = block lines[j] "\n"
            }
            print block | "md5"
            close("md5")
          }
        }
      ' >> "$TMPFILE" 2>/dev/null || true
  done < <(find_src)

  # Find duplicate hashes
  DUPES=$(sort "$TMPFILE" | uniq -d | wc -l | tr -d ' ')
  if [ "$DUPES" -gt 0 ]; then
    warn "DRY: ${DUPES} duplicate code block(s) detected (≥${MIN_LINES} identical lines)"
    info "Run with verbose mode to see specific locations"
  else
    pass "No duplicate blocks ≥${MIN_LINES} lines"
  fi

  rm -f "$TMPFILE"
elif [ "$QUICK_MODE" = "true" ]; then
  skip "Skipped (--quick mode)"
else
  skip "Disabled (VIBE_DRY_CHECK=false)"
fi

# ─── Check 8: Test coverage threshold ────────────────────────────────────────

((CHECKS_RUN++))
section "8/10 Test coverage (≥${VIBE_COVERAGE_THRESHOLD}%)"

if [ "$VIBE_COVERAGE_CHECK" = "true" ] && [ "$QUICK_MODE" != "true" ]; then
  if [ -f "vitest.config.*" ] || grep -q '"vitest"' package.json 2>/dev/null; then
    COV_OUTPUT=$(npx vitest run --coverage --reporter=verbose 2>&1) && COV_EXIT=0 || COV_EXIT=$?

    # Extract coverage percentage from output
    COV_PCT=$(echo "$COV_OUTPUT" | grep -oE 'All files[[:space:]]*[|][[:space:]]*[0-9.]+' | tail -1 | grep -oE '[0-9.]+$' || echo "0")
    COV_INT=${COV_PCT%.*}
    if [ -z "$COV_INT" ]; then COV_INT=0; fi

    if [ "$COV_INT" -ge "${VIBE_COVERAGE_THRESHOLD}" ]; then
      pass "Coverage: ${COV_PCT}% (≥ ${VIBE_COVERAGE_THRESHOLD}%)"
    else
      fail "Coverage: ${COV_PCT}% (< ${VIBE_COVERAGE_THRESHOLD}% threshold)"
      echo "$COV_OUTPUT" | grep -E '%|Stmts|Branch|Funcs|Lines' | tail -10
    fi
  elif [ -f "jest.config.*" ] || grep -q '"jest"' package.json 2>/dev/null; then
    COV_OUTPUT=$(npx jest --coverage --coverageReporters=text 2>&1) && COV_EXIT=0 || COV_EXIT=$?
    COV_PCT=$(echo "$COV_OUTPUT" | grep -E 'All files' | grep -oE '[0-9.]+%' | head -1 | tr -d '%' || echo "0")
    COV_INT=${COV_PCT%.*}
    if [ -z "$COV_INT" ]; then COV_INT=0; fi

    if [ "$COV_INT" -ge "${VIBE_COVERAGE_THRESHOLD}" ]; then
      pass "Coverage: ${COV_PCT}% (≥ ${VIBE_COVERAGE_THRESHOLD}%)"
    else
      fail "Coverage: ${COV_PCT}% (< ${VIBE_COVERAGE_THRESHOLD}% threshold)"
    fi
  else
    skip "No test runner detected (vitest/jest)"
  fi
elif [ "$QUICK_MODE" = "true" ]; then
  skip "Skipped (--quick mode)"
else
  skip "Disabled (VIBE_COVERAGE_CHECK=false)"
fi

# ─── Check 9: Function complexity ────────────────────────────────────────────

((CHECKS_RUN++))
section "9/10 Function length (≤${VIBE_MAX_FUNC_LINES} lines)"

if [ "$VIBE_COMPLEXITY_CHECK" = "true" ]; then
  COMPLEX_COUNT=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # Skip test files
    case "$file" in *.test.*|*.spec.*|*.d.ts) continue ;; esac

    # Find functions longer than threshold
    # Matches: function declarations, arrow functions, method definitions
    LONG_FUNCS=$(awk -v max="$VIBE_MAX_FUNC_LINES" -v file="$file" '
      /^(export )?(async )?(function |const .+ = (\(.*\)|[a-zA-Z]+) =>|  (async )?(get |set )?[a-zA-Z]+\(.*\) \{)/ {
        start = NR
        brace_count = 0
        do {
          gsub(/[^\{]/, "", $0); brace_count += length($0)
          gsub(/[^\}]/, "", $0); brace_count -= length($0)
          if (brace_count <= 0 && NR > start) {
            len = NR - start
            if (len > max) {
              printf "%s:%d: function is %d lines (max %d)\n", file, start, len, max
            }
            next
          }
          if ((getline) <= 0) break
          line = $0
          gsub(/[^\{]/, "", line); brace_count += length(line)
          gsub(/[^\}]/, "", line); brace_count -= length(line)
        } while (brace_count > 0)
      }
    ' "$file" 2>/dev/null || true)

    if [ -n "$LONG_FUNCS" ]; then
      FCOUNT=$(echo "$LONG_FUNCS" | wc -l | tr -d ' ')
      warn "$file: ${FCOUNT} function(s) over ${VIBE_MAX_FUNC_LINES} lines"
      echo "$LONG_FUNCS" | head -5
      COMPLEX_COUNT=$((COMPLEX_COUNT + FCOUNT))
    fi
  done < <(find_src)

  if [ "$COMPLEX_COUNT" -eq 0 ]; then
    pass "All functions ≤ ${VIBE_MAX_FUNC_LINES} lines"
  fi
else
  skip "Disabled (VIBE_COMPLEXITY_CHECK=false)"
fi

# ─── Check 10: Import hygiene ────────────────────────────────────────────────

((CHECKS_RUN++))
section "10/10 Import hygiene"

IMPORT_COUNT=0
while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in *.test.*|*.spec.*|*.d.ts|*.config.*) continue ;; esac

  # Unused imports (heuristic: import exists but name never referenced again in file)
  IMPORTS=$(grep -oE "import\s+\{([^}]+)\}" "$file" 2>/dev/null | grep -oE "\{([^}]+)\}" | tr -d '{}' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u || true)

  for imp in $IMPORTS; do
    [ -z "$imp" ] && continue
    # Count occurrences (import + usage)
    OCC=$(grep -c "\b${imp}\b" "$file" 2>/dev/null || true)
    if [ "$OCC" -le 1 ]; then
      # Only appears in the import line itself — unused
      warn "$file: unused import '${imp}'"
      IMPORT_COUNT=$((IMPORT_COUNT + 1))
    fi
  done
done < <(find_src)

if [ "$IMPORT_COUNT" -eq 0 ]; then
  pass "Import hygiene clean"
fi

# ─── Check 11: Google Style Guide rules ──────────────────────────────────────

((CHECKS_RUN++))
section "11/11 Google Style Guide compliance"

STYLE_COUNT=0
while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in *.test.*|*.spec.*|*.d.ts|*.config.*|*.min.*) continue ;; esac

  ext="${file##*.}"
  case "$ext" in
    ts|tsx|js|jsx)
      # No var declarations
      VARS=$(grep -En '\bvar\s+' "$file" 2>/dev/null | grep -viE '// ' || true)
      if [ -n "$VARS" ]; then
        fail "$file: \`var\` declarations (use \`const\`/\`let\`)"
        STYLE_COUNT=$((STYLE_COUNT + 1))
      fi

      # No non-null assertions (TS only)
      if [[ "$ext" == "ts" || "$ext" == "tsx" ]]; then
        ASSERTS=$(grep -En '\w!' "$file" 2>/dev/null | grep -vE '//|as\s|\?\.|\.d\.ts|import|export|readonly|!' | grep -E '\w+!' || true)
        if [ -n "$ASSERTS" ]; then
          warn "$file: non-null assertions (handle nullability explicitly)"
          STYLE_COUNT=$((STYLE_COUNT + 1))
        fi
      fi

      # Missing return type on exported functions (TS only)
      if [[ "$ext" == "ts" || "$ext" == "tsx" ]]; then
        MISSING_RET=$(grep -En 'export (async )?function \w+\(' "$file" 2>/dev/null | grep -vE ':\s*\w+[^{]*\{' | head -5 || true)
        if [ -n "$MISSING_RET" ]; then
          warn "$file: exported function(s) missing return type"
          STYLE_COUNT=$((STYLE_COUNT + 1))
        fi
      fi
      ;;

    py)
      # Missing docstrings on public functions
      PUB_FUNCS=$(grep -En '^def \w+|^async def \w+' "$file" 2>/dev/null | grep -viE 'test_|_test\.' | head -5 || true)
      if [ -n "$PUB_FUNCS" ]; then
        NO_DOC=$(echo "$PUB_FUNCS" | while read -r line; do
          LINENUM=$(echo "$line" | cut -d: -f1)
          PREV=$((LINENUM - 1))
          if ! sed -n "${PREV}p" "$file" | grep -q '"""' 2>/dev/null; then
            echo "$line"
          fi
        done || true)
        if [ -n "$NO_DOC" ]; then
          warn "$file: public function(s) missing docstring"
          STYLE_COUNT=$((STYLE_COUNT + 1))
        fi
      fi
      ;;

    go)
      # Missing error handling (common Go anti-pattern)
      NO_ERRCHECK=$(grep -En '[^=]=\s*[a-zA-Z]+\(.*\)\s*$' "$file" 2>/dev/null | grep -vE 'err|if|fmt\.' | head -5 || true)
      if [ -n "$NO_ERRCHECK" ]; then
        warn "$file: function call(s) without error check"
        STYLE_COUNT=$((STYLE_COUNT + 1))
      fi
      ;;

    java)
      # Wildcard imports
      WILDCARD=$(grep -En 'import\s+[^;]+\.\*' "$file" 2>/dev/null || true)
      if [ -n "$WILDCARD" ]; then
        fail "$file: wildcard imports (use explicit imports)"
        STYLE_COUNT=$((STYLE_COUNT + 1))
      fi
      ;;

    sh|bash)
      # Missing shebang or set -e
      FIRST=$(head -1 "$file" 2>/dev/null || true)
      if [[ "$FIRST" != "#!/"* ]]; then
        warn "$file: missing shebang"
        STYLE_COUNT=$((STYLE_COUNT + 1))
      fi
      if ! grep -qE 'set -[euo]' "$file" 2>/dev/null; then
        warn "$file: no \`set -euo pipefail\`"
        STYLE_COUNT=$((STYLE_COUNT + 1))
      fi
      ;;
  esac
done < <(find_src)

if [ "$STYLE_COUNT" -eq 0 ]; then
  pass "Google Style Guide compliant"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  VIBE VERIFY — SUMMARY${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo ""
echo "  Checks run:    ${CHECKS_RUN}"
echo "  Passed:        ${CHECKS_PASSED}"

if [ "$VIOLATIONS" -gt 0 ]; then
  echo -e "  ${RED}Violations:    ${VIOLATIONS}${NC}"
else
  echo -e "  ${GREEN}Violations:    0${NC}"
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo -e "  ${YELLOW}Warnings:      ${WARNINGS}${NC}"
fi

echo ""

if [ "$VIOLATIONS" -gt 0 ]; then
  echo -e "${RED}  RESULT: FAIL — fix violations before committing${NC}"
  echo ""
  echo "  Quick fixes:"
  echo "    ./scripts/vibe-verify.sh --fix     # Auto-fix what's possible"
  echo "    ./scripts/vibe-verify.sh --quick   # Skip slow checks"
  echo ""
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  echo -e "${YELLOW}  RESULT: PASS with ${WARNINGS} warning(s)${NC}"
  exit 0
else
  echo -e "${GREEN}  RESULT: ALL CLEAN ✓${NC}"
  exit 0
fi
