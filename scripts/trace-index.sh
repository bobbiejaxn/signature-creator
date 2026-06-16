#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Trace Index — Rebuild or query the trace index
# ──────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/trace-index.sh rebuild           # Rebuild index from all runs
#   ./scripts/trace-index.sh summary           # Print summary of all runs
#   ./scripts/trace-index.sh failures          # Show runs with gate failures
#   ./scripts/trace-index.sh costly            # Show most expensive runs
#   ./scripts/trace-index.sh agent <name>      # Show all traces for an agent

set -euo pipefail

TRACES_DIR=".pi/traces"
RUNS_DIR="$TRACES_DIR/runs"
INDEX_FILE="$TRACES_DIR/index.json"

case "${1:-summary}" in
  rebuild)
    echo "Rebuilding trace index..."
    ENTRIES="["
    FIRST=true
    for run_dir in "$RUNS_DIR"/*/; do
      [ -d "$run_dir" ] || continue
      MANIFEST="$run_dir/manifest.json"
      [ -f "$MANIFEST" ] || continue
      
      RUN_ID=$(basename "$run_dir")
      
      # Aggregate from manifest (array of agent entries), but also
      # parse JSONL files when manifest data is empty (session_end never fires)
      AGENTS=$(python3 -c "
import json, sys, os, glob
try:
    data = json.load(open('$MANIFEST'))
    if not isinstance(data, list): data = [data]
    agents = [d.get('agent','?') for d in data]
    cost = sum(d.get('cost_usd',0) for d in data)
    tok_in = sum(d.get('tokens_in',0) for d in data)
    tok_out = sum(d.get('tokens_out',0) for d in data)
    tools = sum(d.get('tool_calls',0) for d in data)
    errors = sum(d.get('errors',0) for d in data)
    started = data[0].get('started','')
    ended = data[-1].get('ended','') or ''
    phase = data[0].get('phase','')

    # If manifest has no real data, enrich from JSONL files
    if tools == 0 and tok_in == 0:
        run_dir = '$run_dir'
        for jsonl in glob.glob(os.path.join(run_dir, '*.jsonl')):
            agent_name = os.path.basename(jsonl).replace('.jsonl','')
            if agent_name not in agents:
                agents.append(agent_name)
            with open(jsonl) as f:
                for line in f:
                    try:
                        ev = json.loads(line)
                        t = ev.get('type','')
                        if t == 'tool_call': tools += 1
                        elif t == 'message':
                            d = ev.get('data',{})
                            tok_in += d.get('tokensIn',0)
                            tok_out += d.get('tokensOut',0)
                            cost += d.get('cost',0)
                        if not started and ev.get('timestamp'):
                            started = ev['timestamp']
                        if ev.get('timestamp'):
                            ended = ev['timestamp']
                    except: pass

    print(json.dumps({
        'run_id': '$RUN_ID', 'phase': phase, 'started': started, 'ended': ended,
        'agents': agents, 'total_cost_usd': round(cost,4),
        'total_tokens_in': tok_in, 'total_tokens_out': tok_out,
        'total_tool_calls': tools, 'total_errors': errors
    }))
except Exception as e: pass
" 2>/dev/null)
      
      if [ -n "$AGENTS" ]; then
        if [ "$FIRST" = true ]; then
          FIRST=false
        else
          ENTRIES="$ENTRIES,"
        fi
        ENTRIES="$ENTRIES$AGENTS"
      fi
    done
    ENTRIES="$ENTRIES]"
    echo "$ENTRIES" | python3 -m json.tool > "$INDEX_FILE"
    echo "Index rebuilt: $(echo "$ENTRIES" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') runs"
    ;;

  summary)
    if [ ! -f "$INDEX_FILE" ]; then
      echo "No trace index found. Run: ./scripts/trace-index.sh rebuild"
      exit 0
    fi
    python3 -c "
import json
data = json.load(open('$INDEX_FILE'))
print(f'Total runs: {len(data)}')
total_cost = sum(r.get('total_cost_usd',0) for r in data)
total_errors = sum(r.get('total_errors',0) for r in data)
total_tools = sum(r.get('total_tool_calls',0) for r in data)
all_agents = set()
for r in data:
    for a in r.get('agents',[]):
        all_agents.add(a)
print(f'Total cost: \${total_cost:.2f}')
print(f'Total tool calls: {total_tools}')
print(f'Total errors: {total_errors}')
print(f'Unique agents: {len(all_agents)} ({", ".join(sorted(all_agents))})')
print()
print('Recent runs:')
for r in data[-10:]:
    agents = \", \".join(r.get('agents',[]))
    cost = r.get('total_cost_usd',0)
    errors = r.get('total_errors',0)
    err_flag = ' ⚠' if errors > 0 else ''
    print(f'  {r[\"run_id\"]:40s}  \${cost:.3f}  [{agents}]{err_flag}')
" 2>/dev/null || echo "Error reading index"
    ;;

  failures)
    if [ ! -f "$INDEX_FILE" ]; then echo "No index. Run rebuild first."; exit 0; fi
    python3 -c "
import json
data = json.load(open('$INDEX_FILE'))
failures = [r for r in data if r.get('total_errors',0) > 0]
print(f'Runs with errors: {len(failures)}/{len(data)}')
for r in failures:
    print(f'  {r[\"run_id\"]:40s}  {r[\"total_errors\"]} errors  [{\"|\".join(r.get(\"agents\",[]))}]')
"
    ;;

  costly)
    if [ ! -f "$INDEX_FILE" ]; then echo "No index. Run rebuild first."; exit 0; fi
    python3 -c "
import json
data = json.load(open('$INDEX_FILE'))
data.sort(key=lambda r: r.get('total_cost_usd',0), reverse=True)
print('Most expensive runs:')
for r in data[:10]:
    print(f'  {r[\"run_id\"]:40s}  \${r[\"total_cost_usd\"]:.3f}  [{\"|\".join(r.get(\"agents\",[]))}]')
"
    ;;

  agent)
    AGENT="${2:-}"
    if [ -z "$AGENT" ]; then echo "Usage: ./scripts/trace-index.sh agent <name>"; exit 1; fi
    echo "Traces for agent: $AGENT"
    for run_dir in "$RUNS_DIR"/*/; do
      TRACE="$run_dir/${AGENT}.jsonl"
      if [ -f "$TRACE" ]; then
        LINES=$(wc -l < "$TRACE" | tr -d ' ')
        RUN_ID=$(basename "$run_dir")
        echo "  $RUN_ID  ($LINES entries)"
      fi
    done
    ;;

  *)
    echo "Usage: ./scripts/trace-index.sh {rebuild|summary|failures|costly|agent <name>}"
    ;;
esac
