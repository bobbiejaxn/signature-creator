#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Harness Report — Dashboard showing harness performance over time
# ──────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/harness-report.sh           # Full report
#   ./scripts/harness-report.sh brief     # One-line summary

set -euo pipefail

TRACES_DIR=".pi/traces"
INDEX_FILE="$TRACES_DIR/index.json"
VERSIONS_DIR=".pi/harness-versions"
PROPOSALS_DIR="$TRACES_DIR/analysis/proposals"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

if [ "${1:-}" = "brief" ]; then
  # One-line summary
  if [ ! -f "$INDEX_FILE" ]; then
    echo "No traces yet."
    exit 0
  fi
  python3 -c "
import json
data = json.load(open('$INDEX_FILE'))
runs = len(data)
cost = sum(r.get('total_cost_usd',0) for r in data)
errors = sum(1 for r in data if r.get('total_errors',0) > 0)
ok = runs - errors
rate = (ok/runs*100) if runs > 0 else 0
print(f'{runs} runs | {rate:.0f}% clean | \${cost:.2f} total')
" 2>/dev/null || echo "?"
  exit 0
fi

echo -e "${CYAN}━━━ Harness Performance Report ━━━${NC}"
echo ""

# ── Current version ──
CURRENT_VER=$(cat "$VERSIONS_DIR/current" 2>/dev/null || echo "none")
if [ "$CURRENT_VER" != "none" ]; then
  echo -e "${BOLD}Harness Version:${NC} v$CURRENT_VER"
  VER_FILE="$VERSIONS_DIR/v${CURRENT_VER}.json"
  if [ -f "$VER_FILE" ]; then
    python3 -c "
import json
d = json.load(open('$VER_FILE'))
label = d.get('label','')
print(f'  Created: {d.get(\"created\",\"?\")}')
if label: print(f'  Label: {label}')
print(f'  Agents: {d.get(\"agent_count\",\"?\")}  |  Skills: {d.get(\"skill_count\",\"?\")}')
" 2>/dev/null
  fi
else
  echo -e "${YELLOW}No harness version tracked. Run: ./scripts/harness-version.sh snapshot${NC}"
fi
echo ""

# ── Trace summary ──
if [ ! -f "$INDEX_FILE" ]; then
  echo -e "${YELLOW}No traces recorded yet. Traces are captured during /ship and /fix workflows.${NC}"
  exit 0
fi

python3 -c "
import json
from collections import Counter

data = json.load(open('$INDEX_FILE'))
if not data:
    print('No runs recorded.')
    exit()

runs = len(data)
total_cost = sum(r.get('total_cost_usd',0) for r in data)
total_tokens = sum(r.get('total_tokens_in',0) + r.get('total_tokens_out',0) for r in data)
error_runs = [r for r in data if r.get('total_errors',0) > 0]
clean_runs = runs - len(error_runs)
pass_rate = (clean_runs / runs * 100) if runs > 0 else 0

# Cost per run
avg_cost = total_cost / runs if runs > 0 else 0

# Agent frequency
agent_counter = Counter()
agent_costs = Counter()
for r in data:
    for a in r.get('agents', []):
        agent_counter[a] += 1

print(f'\033[1mRuns:\033[0m {runs}  |  \033[32mClean: {clean_runs}\033[0m  |  \033[31mWith errors: {len(error_runs)}\033[0m  |  Pass rate: {pass_rate:.0f}%')
print(f'\033[1mCost:\033[0m \${total_cost:.2f} total  |  \${avg_cost:.3f} avg/run  |  {total_tokens:,} tokens')
print()

# Agent usage
print('\033[1mAgent Usage:\033[0m')
for agent, count in agent_counter.most_common():
    bar = '█' * min(count, 30)
    print(f'  {agent:25s} {count:3d} runs  {bar}')
print()

# Error patterns
if error_runs:
    print('\033[1mRuns with Errors:\033[0m')
    for r in error_runs[-5:]:
        agents = ', '.join(r.get('agents',[]))
        print(f'  {r[\"run_id\"]:40s}  {r[\"total_errors\"]} errors  [{agents}]')
    if len(error_runs) > 5:
        print(f'  ... and {len(error_runs)-5} more')
    print()

# Trend (first 5 vs last 5 runs)
if runs >= 10:
    first5 = data[:5]
    last5 = data[-5:]
    first_err = sum(1 for r in first5 if r.get('total_errors',0) > 0)
    last_err = sum(1 for r in last5 if r.get('total_errors',0) > 0)
    first_cost = sum(r.get('total_cost_usd',0) for r in first5) / 5
    last_cost = sum(r.get('total_cost_usd',0) for r in last5) / 5
    
    print('\033[1mTrend (first 5 → last 5 runs):\033[0m')
    err_arrow = '↓' if last_err < first_err else ('↑' if last_err > first_err else '→')
    cost_arrow = '↓' if last_cost < first_cost else ('↑' if last_cost > first_cost else '→')
    print(f'  Error runs:  {first_err}/5 → {last_err}/5  {err_arrow}')
    print(f'  Avg cost:    \${first_cost:.3f} → \${last_cost:.3f}  {cost_arrow}')
    print()
" 2>/dev/null

# ── Proposals ──
PROPOSAL_COUNT=$(ls "$PROPOSALS_DIR"/proposal-*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$PROPOSAL_COUNT" -gt 0 ]; then
  echo -e "${BOLD}Evolution Proposals:${NC} $PROPOSAL_COUNT"
  for f in "$PROPOSALS_DIR"/proposal-*.md; do
    NAME=$(basename "$f" .md)
    TITLE=$(head -1 "$f" | sed 's/^#\s*//')
    echo "  $NAME: $TITLE"
  done
  echo ""
fi

# ── Version history ──
VER_COUNT=$(ls "$VERSIONS_DIR"/v*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$VER_COUNT" -gt 1 ]; then
  echo -e "${BOLD}Version History:${NC} $VER_COUNT snapshots"
  "$0/../harness-version.sh" list 2>/dev/null | grep "^  v" || true
  echo ""
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
