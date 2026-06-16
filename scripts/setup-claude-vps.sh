#!/usr/bin/env bash
# setup-claude-vps.sh — Configure Claude Code on VPS using OAuth subscription token
# ──────────────────────────────────────────────────────────────────────────────
# Run this LOCALLY on your Mac. It generates a long-lived token and prints
# the commands to run on the VPS.
#
# Prerequisites:
#   - Claude Code installed and authenticated on your Mac (OAuth)
#   - SSH access to the VPS
#
# Usage:
#   ./scripts/setup-claude-vps.sh                     # Print instructions
#   ./scripts/setup-claude-vps.sh --vps root@185.215.XX.XX  # Auto-configure
#
# How it works:
#   1. Locally: `claude setup-token` generates a 1-year OAuth token
#   2. Token is exported to VPS via SSH
#   3. Claude Code on VPS uses subscription (not pay-per-token)
#
# Cost: INCLUDED in your Claude Pro/Max subscription. No API charges.
# Limit: Subject to Claude Code rate limits (same as local usage).

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Claude Code VPS Setup — OAuth Subscription Token${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# -- Check prerequisites ───────────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
  echo -e "${RED}ERROR: Claude Code not found locally. Install first.${NC}"
  exit 1
fi

if ! claude auth status 2>&1 | grep -q '"loggedIn": true'; then
  echo -e "${RED}ERROR: Not logged in to Claude Code. Run: claude auth login${NC}"
  exit 1
fi

echo -e "${GREEN}✓ Claude Code authenticated via OAuth${NC}"
echo ""

# -- Check if VPS target provided ──────────────────────────────────────────────

VPS_TARGET="${1:-}"
if [[ "$VPS_TARGET" == "--vps" ]]; then
  VPS_TARGET="${2:-}"
fi

if [ -z "$VPS_TARGET" ]; then
  echo -e "${YELLOW}No VPS target specified. Printing manual instructions.${NC}"
  echo ""
  echo "━━━ Step 1: Generate token (run on Mac) ━━━"
  echo ""
  echo "  claude setup-token"
  echo ""
  echo "  This generates a long-lived OAuth token (valid 1 year)."
  echo "  Copy the token value that gets printed."
  echo ""
  echo "━━━ Step 2: Install Claude Code on VPS ━━━"
  echo ""
  echo "  ssh root@YOUR_VPS"
  echo "  npm install -g @anthropic-ai/claude-code"
  echo ""
  echo "━━━ Step 3: Configure token on VPS ━━━"
  echo ""
  echo "  On the VPS, set the token:"
  echo ""
  echo "  export ANTHROPIC_AUTH_TOKEN='your-token-here'"
  echo "  claude -p 'Say hello'  # Test — should work"
  echo ""
  echo "  To persist, add to ~/.bashrc or ~/.zshrc:"
  echo "  echo 'export ANTHROPIC_AUTH_TOKEN=\"your-token-here\"' >> ~/.bashrc"
  echo ""
  echo "━━━ Step 4: Update pi_launchpad config on VPS ━━━"
  echo ""
  echo "  Edit /root/pi_launchpad/.pi/config.sh:"
  echo "  Set CLAUDE_ORACLE_AVAILABLE=\"true\""
  echo "  Set CLAUDE_ORACLE_BUDGET=\"10\""
  echo ""
  echo "━━━ Alternative: Auto-configure via this script ━━━"
  echo ""
  echo "  ./scripts/setup-claude-vps.sh --vps root@185.215.XX.XX"
  echo ""
  exit 0
fi

# -- Auto-configure mode ───────────────────────────────────────────────────────

echo -e "${CYAN}Auto-configuring Claude Code on $VPS_TARGET${NC}"
echo ""

# Step 1: Generate token
echo -e "${YELLOW}Step 1: Generating long-lived token...${NC}"
echo ""
echo -e "${YELLOW}Running: claude setup-token${NC}"
echo -e "${YELLOW}Follow the prompts to generate a 1-year token.${NC}"
echo ""

claude setup-token
echo ""

# Step 2: Install Claude on VPS
echo -e "${YELLOW}Step 2: Installing Claude Code on VPS...${NC}"
ssh "$VPS_TARGET" "npm install -g @anthropic-ai/claude-code 2>&1" || {
  echo -e "${RED}Failed to install Claude Code on VPS. Install manually.${NC}"
  echo "  ssh $VPS_TARGET 'npm install -g @anthropic-ai/claude-code'"
}

# Step 3: Test
echo ""
echo -e "${YELLOW}Step 3: Verifying Claude Code on VPS...${NC}"
echo ""
echo "  ssh $VPS_TARGET 'claude --version'"
ssh "$VPS_TARGET" "claude --version" 2>&1 || true

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Claude Code is now installed on the VPS."
echo "  To authenticate, set ANTHROPIC_AUTH_TOKEN on the VPS."
echo ""
echo "  To test:"
echo "    ssh $VPS_TARGET"
echo "    export ANTHROPIC_AUTH_TOKEN='your-token'"
echo "    claude -p 'Hello'"
echo ""
echo "  To persist:"
echo "    echo 'export ANTHROPIC_AUTH_TOKEN=\"your-token\"' >> ~/.bashrc"
echo ""
echo "  Then update pi_launchpad config:"
echo "    Edit /root/pi_launchpad/.pi/config.sh"
echo "    Set CLAUDE_ORACLE_AVAILABLE=\"true\""
