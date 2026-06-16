#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# peer-registry.sh — Manage Pi-to-Pi peer definitions
# ──────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/peer-registry.sh list              # Show all registered peers
#   ./scripts/peer-registry.sh ping              # Health check all peers
#   ./scripts/peer-registry.sh status            # Check who's online (via coms)
#   ./scripts/peer-registry.sh add <name>        # Add peer from template
#   ./scripts/peer-registry.sh remove <name>     # Remove a peer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PEERS_DIR="$REPO_ROOT/.pi/peers"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0;0m'

mkdir -p "$PEERS_DIR"

cmd_list() {
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  PI-TO-PI PEER REGISTRY${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [ -z "$(ls "$PEERS_DIR"/*.yaml 2>/dev/null)" ]; then
    echo "No peers registered."
    echo "Add peers: ./scripts/peer-registry.sh add <name>"
    return
  fi

  printf "%-15s %-10s %-25s %-8s %s\n" "NAME" "ROLE" "HOST" "PORT" "CAPABILITIES"
  echo "─────────────────────────────────────────────────────────────────────────────"

  for peer in "$PEERS_DIR"/*.yaml; do
    name=$(grep "^name:" "$peer" | awk '{print $2}')
    role=$(grep "^role:" "$peer" | awk '{print $2}')
    host=$(grep "^host:" "$peer" | awk '{print $2}')
    port=$(grep "^port:" "$peer" | awk '{print $2}')
    caps=$(grep "^  - " "$peer" | tr '\n' ',' | sed 's/^  - //;s/  - /,/g;s/,$//')
    printf "%-15s %-10s %-25s %-8s %s\n" "$name" "$role" "$host" "$port" "$caps"
  done
  echo ""
}

cmd_ping() {
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  PINGING ALL PEERS${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  for peer in "$PEERS_DIR"/*.yaml; do
    [ -f "$peer" ] || continue
    name=$(grep "^name:" "$peer" | awk '{print $2}')
    host=$(grep "^host:" "$peer" | awk '{print $2}')
    port=$(grep "^port:" "$peer" | awk '{print $2}')

    # Ping the coms server on that host
    if curl -sS -o /dev/null -w "%{http_code}" "http://${host}:${port:-8090}/v1/health" --max-time 3 2>/dev/null | grep -q "200"; then
      echo -e "  ${GREEN}✓${NC} $name ($host:$port) — reachable"
    else
      echo -e "  ${RED}✗${NC} $name ($host:$port) — unreachable"
    fi
  done
  echo ""
}

cmd_status() {
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  PEER STATUS (live from coms server)${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  source "$REPO_ROOT/.pi/config.sh" 2>/dev/null || true
  SERVER_URL="${COMS_NET_PUBLIC_URL:-http://localhost:${COMS_NET_PORT:-8090}}"
  TOKEN="${COMS_NET_AUTH_TOKEN:-}"

  if [ -n "$TOKEN" ]; then
    AUTH_HEADER="-H \"Authorization: Bearer $TOKEN\""
  else
    AUTH_HEADER=""
  fi

  # Try to get agents list from the server
  RESPONSE=$(curl -sS "$SERVER_URL/v1/agents?project=default" $AUTH_HEADER --max-time 5 2>/dev/null || echo '{"error":"unreachable"}')

  if echo "$RESPONSE" | grep -q '"error"'; then
    echo -e "  ${RED}Server unreachable at $SERVER_URL${NC}"
    echo "  Start the server: ./scripts/coms-net-server.sh --daemon"
    return
  fi

  AGENT_COUNT=$(echo "$RESPONSE" | grep -o '"session_id"' | wc -l | tr -d ' ')
  echo "  Agents online: $AGENT_COUNT"
  echo ""

  # Show agent names
  echo "$RESPONSE" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//' | while read name; do
    echo -e "  ${GREEN}●${NC} $name"
  done
  echo ""
}

cmd_add() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: ./scripts/peer-registry.sh add <name>"
    echo "Templates: local-dev, reviewer, monitor"
    exit 1
  fi

  local target="$PEERS_DIR/$name.yaml"
  if [ -f "$target" ]; then
    echo "Peer '$name' already exists: $target"
    exit 1
  fi

  cat > "$target" << EOF
name: $name
host: localhost
port: 8090
role: worker
capabilities:
  - implement
model: zai/glm-5.1
machine: local
auto_start: false
EOF

  echo -e "${GREEN}✓${NC} Created $target"
  echo "Edit it to configure host, capabilities, and model."
}

cmd_remove() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: ./scripts/peer-registry.sh remove <name>"
    exit 1
  fi

  local target="$PEERS_DIR/$name.yaml"
  if [ ! -f "$target" ]; then
    echo "Peer '$name' not found in $PEERS_DIR/"
    exit 1
  fi

  rm "$target"
  echo -e "${GREEN}✓${NC} Removed peer '$name'"
}

case "${1:-help}" in
  list)   cmd_list ;;
  ping)   cmd_ping ;;
  status) cmd_status ;;
  add)    cmd_add "${2:-}" ;;
  remove) cmd_remove "${2:-}" ;;
  help|*)
    echo "Pi-to-Pi Peer Registry"
    echo ""
    echo "Commands:"
    echo "  list              Show all registered peers"
    echo "  ping              Health check all peers (HTTP)"
    echo "  status            Show live agents on coms server"
    echo "  add <name>        Add a new peer"
    echo "  remove <name>     Remove a peer"
    ;;
esac
