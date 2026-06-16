#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# launch-verifier.sh — Boot a builder + verifier two-agent system
# ──────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/launch-verifier.sh                  # Generic verifier
#   ./scripts/launch-verifier.sh --agent sqlite   # SQLite domain verifier
#   ./scripts/launch-verifier.sh --agent python   # Python domain verifier
#   ./scripts/launch-verifier.sh --agent image    # Image vision verifier
#   ./scripts/launch-verifier.sh --clean          # Kill stale verifier processes
#
# The verifier runs in a separate tmux window/OS terminal. It watches the
# builder's session JSONL and sends corrective feedback via unix domain socket.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFIER_EXT="$REPO_ROOT/apps/verifier"

AGENT="verifier"  # default generic persona

for arg in "$@"; do
  case "$arg" in
    --agent) shift; AGENT="${1:-verifier}" ;;
    --clean)
      echo "Cleaning stale verifier state..."
      tmux ls 2>/dev/null | grep '^verifier-' | cut -d: -f1 | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
      rm -f /tmp/pi-verifier/*.sock 2>/dev/null || true
      rm -f "$REPO_ROOT/.pi/state/verifier-"*.sock.ref 2>/dev/null || true
      echo "Done."
      exit 0
      ;;
    --help)
      echo "Usage: ./scripts/launch-verifier.sh [--agent sqlite|python|image|verifier] [--clean]"
      echo ""
      echo "  --agent   Domain verifier persona (default: generic verifier)"
      echo "  --clean   Kill stale verifier tmux sessions, sockets, breadcrumbs"
      exit 0
      ;;
  esac
done

# Map short names to persona files
case "$AGENT" in
  sqlite) AGENT="verify_sqlite" ;;
  python|py) AGENT="verify_python" ;;
  image|img) AGENT="verify_image" ;;
esac

# Check prerequisites
if ! command -v pi &>/dev/null; then
  echo "Error: 'pi' not found on PATH. Install: npm install -g @mariozechner/pi-coding-agent"
  exit 1
fi

if ! command -v tmux &>/dev/null; then
  echo "Error: 'tmux' not found. Install: brew install tmux"
  exit 1
fi

if [ ! -f "$VERIFIER_EXT/verifiable.ts" ]; then
  echo "Error: Verifier extension not found at $VERIFIER_EXT"
  echo "Run: cd apps/verifier && npm install"
  exit 1
fi

# Check if verifier scripts exist and are executable
if [ ! -x "$REPO_ROOT/.pi/verifier/scripts/verify_sqlite.py" ] 2>/dev/null; then
  chmod +x "$REPO_ROOT/.pi/verifier/scripts/"*.py 2>/dev/null || true
fi

echo "══════════════════════════════════════════════════════"
echo "  Pi Verifier Agent System"
echo "  Domain: $AGENT"
echo "══════════════════════════════════════════════════════"
echo ""
echo "Builder Pi launches in this terminal."
echo "Verifier Pi auto-spawns in a separate window."
echo "Press Ctrl+D in the builder to shut down both."
echo ""

# Launch builder with verifier extension
pi -e "$VERIFIER_EXT/verifiable.ts" -e "$VERIFIER_EXT/cross-agent.ts" --verifiable --verifier-agent "$AGENT"
