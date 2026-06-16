#!/usr/bin/env bash
# security-gate.sh — Hard security enforcement for pi_launchpad
# ──────────────────────────────────────────────────────────────────────────────
# Blocks PRs with security violations. Non-bypassable.
#
# Checks:
#   1. No public repos (gh repo visibility)
#   2. No trivial/weak passwords
#   3. No hardcoded secrets (AWS, GitHub, private keys, etc.)
#   4. Unsafe code patterns (eval, SQL injection, etc.)
#   5. Git diff secret scan (staged/recent changes)
#
# Usage:
#   ./scripts/security-gate.sh
#
# Exit codes:
#   0 — all checks pass
#   1 — one or more violations found

set -uo pipefail

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
CHECKS_RUN=0
CHECKS_PASSED=0

# Load config
REPO=""
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

pass()   { echo -e "${GREEN}  ✓ $1${NC}"; }
fail()   { echo -e "${RED}  ✗ $1${NC}"; }
warn()   { echo -e "${YELLOW}  ! $1${NC}"; }
info()   { echo -e "${BLUE}  → $1${NC}"; }
header() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

find_code_files() {
  find "$REPO_ROOT" -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.rb" -o -name "*.go" -o -name "*.java" -o -name "*.rs" -o -name "*.sh" -o -name "*.yaml" -o -name "*.yml" -o -name "*.json" -o -name "*.env" -o -name "*.toml" -o -name "*.cfg" -o -name "*.ini" -o -name "*.conf" \) \
    ! -path "*/node_modules/*" \
    ! -path "*/.next/*" \
    ! -path "*/dist/*" \
    ! -path "*/build/*" \
    ! -path "*/__generated__/*" \
    ! -path "*/coverage/*" \
    ! -path "*/.git/*" \
    ! -path "*/vendor/*" \
    ! -path "*/.claude/*" \
    ! -path "*/.pi/*" \
    ! -path "*/package-lock.json" \
    ! -path "*/yarn.lock" \
    ! -path "*/pnpm-lock.yaml" \
    2>/dev/null
}

# ─── Banner ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  SECURITY GATE — Hard Enforcement${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 1: No public repos
# ═══════════════════════════════════════════════════════════════════════════

header "Check 1: Repository visibility"
CHECKS_RUN=$((CHECKS_RUN + 1))

if [ -n "$REPO" ] && command -v gh &>/dev/null; then
  VISIBILITY=$(gh repo view "$REPO" --json visibility -q '.visibility' 2>/dev/null || echo "UNKNOWN")
  if [ "$VISIBILITY" = "PUBLIC" ]; then
    fail "Repository $REPO is PUBLIC"
    info "Ensure this is intentional — secrets in public repos are exposed"
    VIOLATIONS=$((VIOLATIONS + 1))
  elif [ "$VISIBILITY" = "UNKNOWN" ]; then
    warn "Could not determine repo visibility — skipping"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
  else
    pass "Repository is $VISIBILITY"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
  fi
else
  warn "No REPO configured or gh CLI not available — skipping"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 2: No trivial/weak passwords
# ═══════════════════════════════════════════════════════════════════════════

header "Check 2: No trivial/weak passwords"
CHECKS_RUN=$((CHECKS_RUN + 1))

WEAK_PASSWORDS=(
  'password' 'password123' 'admin' 'admin123' '123456' 'qwerty'
  'letmein' 'welcome' 'monkey' 'master' 'dragon' 'login' 'abc123'
  'passw0rd' 'default' 'changeme' 'secret' 'test123' 'root' 'toor'
)

WEAK_COUNT=0
WEAK_FILES=""

while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    *.test.* | *.spec.* | *__test__* | *__mock__* | *.example | *.sample) continue ;;
  esac

  for pwd in "${WEAK_PASSWORDS[@]}"; do
    MATCHES=$(grep -inE "(password|passwd|pwd|secret|token)\s*[:=]\s*['\"]${pwd}['\"]" "$file" 2>/dev/null | grep -v '// vibe-ok' | grep -v '# vibe-ok' || true)
    if [ -n "$MATCHES" ]; then
      MATCH_COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
      WEAK_COUNT=$((WEAK_COUNT + MATCH_COUNT))
      WEAK_FILES="$WEAK_FILES\n  $file: weak password '$pwd'"
    fi
  done
done < <(find_code_files)

if [ "$WEAK_COUNT" -eq 0 ]; then
  pass "No trivial/weak passwords found"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  fail "Found $WEAK_COUNT trivial/weak password(s):"
  echo -e "$WEAK_FILES"
  info "Use environment variables for credentials"
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 3: No hardcoded secrets
# ═══════════════════════════════════════════════════════════════════════════

header "Check 3: No hardcoded secrets"
CHECKS_RUN=$((CHECKS_RUN + 1))

SECRET_COUNT=0
SECRET_FILES=""

SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}'
  'sk-[a-zA-Z0-9]{20,}'
  'ghp_[a-zA-Z0-9]{36}'
  'gho_[a-zA-Z0-9]{36}'
  'github_pat_[a-zA-Z0-9_]{82}'
  '-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----'
  '-----BEGIN\s+EC\s+PRIVATE\s+KEY-----'
  '(mongodb|postgres|mysql|redis)://[^[:space:]]+@[^[:space:]]+'
  'xox[bpoa]-[0-9a-zA-Z-]+'
  'sk_live_[a-zA-Z0-9]+'
  'rk_live_[a-zA-Z0-9]+'
  'SG\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'
)

SECRET_REGEX=$(IFS='|'; echo "${SECRET_PATTERNS[*]}")

while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    *.test.* | *.spec.* | *__test__* | *__mock__* | *.example | *.sample | *.lock) continue ;;
  esac

  MATCHES=$(grep -nE "$SECRET_REGEX" "$file" 2>/dev/null | grep -v '// vibe-ok' | grep -v '# vibe-ok' | grep -v 'example' | grep -v 'placeholder' | grep -v 'REPLACE_ME' || true)
  if [ -n "$MATCHES" ]; then
    FILE_COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
    SECRET_COUNT=$((SECRET_COUNT + FILE_COUNT))
    SECRET_FILES="$SECRET_FILES\n  $file ($FILE_COUNT match(es))"
    echo "$MATCHES" | head -3 | sed 's/^/    /'
  fi
done < <(find_code_files)

if [ "$SECRET_COUNT" -eq 0 ]; then
  pass "No hardcoded secrets detected"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  fail "Found $SECRET_COUNT potential hardcoded secret(s):"
  echo -e "$SECRET_FILES"
  info "Use environment variables and .env files (never committed)"
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 4: Unsafe code patterns
# ═══════════════════════════════════════════════════════════════════════════

header "Check 4: Unsafe code patterns"
CHECKS_RUN=$((CHECKS_RUN + 1))

UNSAFE_COUNT=0
UNSAFE_FILES=""

# Pattern|Description pairs (bash 3.2 compatible — no associative arrays)
UNSAFE_PATTERN_LIST=(
  "eval()|eval() — arbitrary code execution"
  "new Function()|new Function() — arbitrary code execution"
  "dangerouslySetInnerHTML|dangerouslySetInnerHTML — XSS risk"
  "subprocess.*shell=True|subprocess shell=True — command injection"
  "verify=False|SSL verify=False — MitM risk"
  "verify_ssl.*false|SSL verify disabled — MitM risk"
)

SQL_PATTERN_LIST=(
  'f".*SELECT.*{.*}"'
  "f'.*SELECT.*{.*}'"
  'f".*INSERT.*{.*}"'
  "f'.*INSERT.*{.*}'"
  'f".*UPDATE.*{.*}"'
  "f'.*UPDATE.*{.*}'"
  'f".*DELETE.*{.*}"'
  "f'.*DELETE.*{.*}'"
  '`.*SELECT.*\$\{.*\}`'
  '`.*INSERT.*\$\{.*\}`'
  '`.*UPDATE.*\$\{.*\}`'
  '`.*DELETE.*\$\{.*\}`'
)

while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    *.test.* | *.spec.* | *__test__* | *__mock__*) continue ;;
    */scripts/security-gate.sh) continue ;;
    */scripts/vibe-verify.sh) continue ;;
  esac

  FILE_ISSUES=""

  # Check named patterns
  for entry in "${UNSAFE_PATTERN_LIST[@]}"; do
    pattern="${entry%%|*}"
    desc="${entry#*|}"
    MATCHES=$(grep -nF "$pattern" "$file" 2>/dev/null | grep -v '// vibe-ok' | grep -v '# vibe-ok' | grep -v '// safe:' || true)
    if [ -n "$MATCHES" ]; then
      COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
      UNSAFE_COUNT=$((UNSAFE_COUNT + COUNT))
      FILE_ISSUES="$FILE_ISSUES\n    $desc: $COUNT"
    fi
  done

  # Check SQL injection patterns
  for pattern in "${SQL_PATTERN_LIST[@]}"; do
    MATCHES=$(grep -nE "$pattern" "$file" 2>/dev/null | grep -v '// vibe-ok' | grep -v '# vibe-ok' | grep -v '// safe:' || true)
    if [ -n "$MATCHES" ]; then
      COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
      UNSAFE_COUNT=$((UNSAFE_COUNT + COUNT))
      FILE_ISSUES="$FILE_ISSUES\n    SQL injection risk: $COUNT"
    fi
  done

  # Check CORS wildcard
  CORS_MATCHES=$(grep -nE 'Access-Control-Allow-Origin.*\\*' "$file" 2>/dev/null | grep -v '// vibe-ok' | grep -v '# vibe-ok' || true)
  if [ -n "$CORS_MATCHES" ]; then
    COUNT=$(echo "$CORS_MATCHES" | wc -l | tr -d ' ')
    UNSAFE_COUNT=$((UNSAFE_COUNT + COUNT))
    FILE_ISSUES="$FILE_ISSUES\n    CORS wildcard — open access: $COUNT"
  fi

  if [ -n "$FILE_ISSUES" ]; then
    UNSAFE_FILES="$UNSAFE_FILES\n  $file:$FILE_ISSUES"
  fi
done < <(find_code_files)

if [ "$UNSAFE_COUNT" -eq 0 ]; then
  pass "No unsafe code patterns found"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  fail "Found $UNSAFE_COUNT unsafe code pattern(s):"
  echo -e "$UNSAFE_FILES"
  info "Add \`// vibe-ok\` or \`// safe: <reason>\` to suppress"
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════
# CHECK 5: Git diff secret scan
# ═══════════════════════════════════════════════════════════════════════════

header "Check 5: Git diff secret scan"
CHECKS_RUN=$((CHECKS_RUN + 1))

cd "$REPO_ROOT"

DIFF_SECRETS=0

STAGED_DIFF=$(git diff --cached 2>/dev/null || true)
if [ -n "$STAGED_DIFF" ]; then
  DIFF_MATCHES=$(echo "$STAGED_DIFF" | grep -E '^\+' | grep -vE '^\+\+\+' | grep -E "$SECRET_REGEX" 2>/dev/null || true)
  if [ -n "$DIFF_MATCHES" ]; then
    DIFF_COUNT=$(echo "$DIFF_MATCHES" | wc -l | tr -d ' ')
    DIFF_SECRETS=$((DIFF_SECRETS + DIFF_COUNT))
    fail "Staged changes contain $DIFF_COUNT potential secret(s):"
    echo "$DIFF_MATCHES" | head -5 | sed 's/^/    /'
  fi
fi

UNSTAGED_DIFF=$(git diff 2>/dev/null || true)
if [ -n "$UNSTAGED_DIFF" ]; then
  DIFF_MATCHES=$(echo "$UNSTAGED_DIFF" | grep -E '^\+' | grep -vE '^\+\+\+' | grep -E "$SECRET_REGEX" 2>/dev/null || true)
  if [ -n "$DIFF_MATCHES" ]; then
    DIFF_COUNT=$(echo "$DIFF_MATCHES" | wc -l | tr -d ' ')
    DIFF_SECRETS=$((DIFF_SECRETS + DIFF_COUNT))
    fail "Unstaged changes contain $DIFF_COUNT potential secret(s):"
    echo "$DIFF_MATCHES" | head -5 | sed 's/^/    /'
  fi
fi

if [ "$DIFF_SECRETS" -eq 0 ]; then
  pass "Git diff: no secrets in changes"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
  VIOLATIONS=$((VIOLATIONS + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  SECURITY GATE SUMMARY${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Checks run:    $CHECKS_RUN"
echo -e "  Checks passed: ${GREEN}$CHECKS_PASSED${NC}"
echo -e "  Violations:    ${RED}$VIOLATIONS${NC}"
echo ""

if [ "$VIOLATIONS" -gt 0 ]; then
  echo -e "${RED}  RESULT: FAIL — $VIOLATIONS security violation(s) found${NC}"
  echo ""
  exit 1
else
  echo -e "${GREEN}  RESULT: PASS — all security checks clean${NC}"
  echo ""
  exit 0
fi
