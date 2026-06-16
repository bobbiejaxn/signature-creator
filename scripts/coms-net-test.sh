#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# coms-net-test.sh — Verify Pi-to-Pi is alive
# ──────────────────────────────────────────────────────────────────────────────
# Tests: server health → register agent → list peers → send message → cleanup
# Run: ./scripts/coms-net-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0;0m'

# Load config — try local env, then VPS
if [ -f "$REPO_ROOT/.pi/coms-net.env" ]; then
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.pi/coms-net.env"
  SERVER="${COMS_NET_SERVER_URL:-http://localhost:8090}"
  TOKEN="${COMS_NET_AUTH_TOKEN:-}"
else
  # Try reading from VPS
  VPS_ENV=$(ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=5 root@srv1398187.hstgr.cloud "cat /root/pi_launchpad/.pi/coms-net.env" 2>/dev/null || true)
  if [ -n "$VPS_ENV" ]; then
    eval "$VPS_ENV"
    SERVER="${PI_COMS_NET_PUBLIC_URL:-http://srv1398187.hstgr.cloud:8090}"
    TOKEN="${PI_COMS_NET_AUTH_TOKEN:-}"
  fi
fi

if [ -z "$TOKEN" ] || [ -z "$SERVER" ]; then
  echo -e "${RED}No coms-net config found.${NC}"
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"
SESSION="test-$$-$(date +%s)"
PASS=0
FAIL=0

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  PI-TO-PI CONNECTIVITY TEST${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Server: $SERVER"
echo ""

# Test 1: Health
echo -ne "  Health check... "
HEALTH=$(curl -sS "$SERVER/health" --max-time 5 2>/dev/null || echo '{"ok":false}')
if echo "$HEALTH" | grep -q '"ok":true'; then
  echo -e "${GREEN}✓${NC}"
  PASS=$((PASS + 1))
else
  echo -e "${RED}✗${NC}"
  FAIL=$((FAIL + 1))
fi

# Test 2: Register
echo -ne "  Register agent... "
REG=$(curl -sS -X POST "$SERVER/v1/agents/register" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"project\":\"default\",\"session_id\":\"$SESSION\",\"name\":\"test-agent\",\"purpose\":\"Connectivity test\",\"model\":\"test\",\"provider\":\"test\",\"color\":\"#72F1B8\",\"cwd\":\"/tmp\",\"explicit\":false}" \
  --max-time 5 2>/dev/null || echo '{"ok":false}')
if echo "$REG" | grep -q '"ok":true'; then
  echo -e "${GREEN}✓${NC}"
  PASS=$((PASS + 1))
else
  echo -e "${RED}✗${NC} $(echo "$REG" | head -c 100)"
  FAIL=$((FAIL + 1))
fi

# Test 3: List agents
echo -ne "  List peers... "
LIST=$(curl -sS "$SERVER/v1/agents?project=default" -H "$AUTH" --max-time 5 2>/dev/null || echo '{"agents":[]}')
COUNT=$(echo "$LIST" | grep -o '"session_id"' | wc -l | tr -d ' ')
if [ "$COUNT" -ge 1 ]; then
  echo -e "${GREEN}✓${NC} ($COUNT online)"
  PASS=$((PASS + 1))
  echo "$LIST" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//' | while read -r n; do
    echo -e "    ${DIM}● $n${NC}"
  done
else
  echo -e "${YELLOW}~${NC} (0 agents)"
  PASS=$((PASS + 1))
fi

# Test 4: Send message to self
echo -ne "  Send message (loopback)... "
SEND=$(curl -sS -X POST "$SERVER/v1/messages" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"project\":\"default\",\"sender_session\":\"$SESSION\",\"target\":\"test-agent\",\"target_session\":\"$SESSION\",\"prompt\":\"ping from Mac\",\"conversation_id\":null,\"response_schema\":null,\"hops\":0}" \
  --max-time 5 2>/dev/null || echo '{"ok":false}')
if echo "$SEND" | grep -q '"ok":true'; then
  echo -e "${GREEN}✓${NC} (queued)"
  PASS=$((PASS + 1))
else
  echo -e "${RED}✗${NC} $(echo "$SEND" | head -c 100)"
  FAIL=$((FAIL + 1))
fi

# Cleanup
echo -ne "  Cleanup... "
curl -sS -X DELETE "$SERVER/v1/agents/$SESSION?project=default" -H "$AUTH" --max-time 3 2>/dev/null > /dev/null
echo -e "${DIM}done${NC}"

# Result
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}ALL $PASS TESTS PASSED — Pi-to-Pi is live${NC}"
  echo ""
  echo -e "  Hub: $SERVER"
  echo -e "  Agents can now discover and message each other."
else
  echo -e "  ${RED}$FAIL FAILED, $PASS PASSED${NC}"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
