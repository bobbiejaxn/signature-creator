#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Harness Evolver — Analyze traces and propose improvements
# ──────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/evolve-harness.sh              # General evolution pass
#   ./scripts/evolve-harness.sh cost         # Focus on cost reduction
#   ./scripts/evolve-harness.sh gates        # Focus on gate pass rate
#   ./scripts/evolve-harness.sh speed        # Focus on speed
#   ./scripts/evolve-harness.sh <run-id>     # Diagnose specific run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TRACES_DIR="$PROJECT_ROOT/.pi/traces"
INDEX_FILE="$TRACES_DIR/index.json"
PROPOSALS_DIR="$TRACES_DIR/analysis/proposals"

# Ensure structure exists
mkdir -p "$PROPOSALS_DIR"

# Check prerequisites
if [ ! -f "$INDEX_FILE" ]; then
  echo "No trace index found. Run some /ship or /fix workflows first."
  echo "Then: ./scripts/trace-index.sh rebuild"
  exit 1
fi

RUN_COUNT=$(python3 -c "import json; print(len(json.load(open('$INDEX_FILE'))))" 2>/dev/null || echo "0")
if [ "$RUN_COUNT" = "0" ]; then
  echo "No runs in trace index. Nothing to evolve yet."
  exit 0
fi

# Count existing proposals
NEXT_NUM=$(ls "$PROPOSALS_DIR"/proposal-*.md 2>/dev/null | wc -l | tr -d ' ')
NEXT_NUM=$((NEXT_NUM + 1))
PROPOSAL_NUM=$(printf "%03d" $NEXT_NUM)

# Determine focus
FOCUS="${1:-general}"
case "$FOCUS" in
  cost)
    TASK="Focus on reducing token costs. Read .pi/traces/index.json to find the most expensive agents and runs. Propose model downgrades or context reductions that won't hurt quality. Check agent mental models and skill compositions for bloat."
    ;;
  gates)
    TASK="Focus on improving gate pass rate. Read .pi/traces/index.json to find runs with errors. Grep the failing agent traces for specific error messages. Diagnose which harness decision caused each failure. Propose the single highest-impact fix."
    ;;
  speed)
    TASK="Focus on reducing execution time. Read .pi/traces/index.json for duration data. Identify bottleneck agents. Propose parallelization, model downgrades for non-critical agents, or context size reduction."
    ;;
  general)
    TASK="Perform a general harness optimization pass. Read .pi/traces/index.json for the overview. Identify the single most impactful improvement opportunity — whether it's a failure pattern, cost issue, or missing skill. Diagnose the root cause from traces. Propose one targeted fix."
    ;;
  *)
    # Assume it's a run ID
    if [ -d "$TRACES_DIR/runs/$FOCUS" ]; then
      TASK="Diagnose why run $FOCUS had issues. Read its manifest at .pi/traces/runs/$FOCUS/manifest.json. Read each agent's trace JSONL. Identify the root cause. Propose a harness change to prevent this failure in future runs."
    else
      echo "Unknown focus '$FOCUS'. Use: general, cost, gates, speed, or a valid run-id."
      exit 1
    fi
    ;;
esac

# Snapshot current harness before making changes
echo "📸 Snapshotting current harness..."
"$SCRIPT_DIR/harness-version.sh" snapshot 2>/dev/null || true

echo "🔬 Running harness evolver (focus: $FOCUS)..."
echo "   Proposal will be written to: proposals/proposal-$PROPOSAL_NUM.md"
echo ""

FULL_TASK="$TASK

Write your proposal to .pi/traces/analysis/proposals/proposal-$PROPOSAL_NUM.md using this format:

# Proposal $PROPOSAL_NUM: <title>

## Diagnosis
<What trace evidence led you here — cite specific run IDs, agents, error messages>

## Root Cause  
<Which harness decision caused the issue>

## Change
<Exactly what to modify — one change only>

## Expected Impact
<What should improve and by how much>

## Rollback Plan
<How to undo: ./scripts/harness-version.sh rollback>

After writing the proposal, apply the change to the actual harness files."

# Check if pi is available
if command -v pi &>/dev/null; then
  echo "$FULL_TASK" | pi --agent harness-evolver --no-interactive 2>/dev/null || {
    echo "⚠ pi agent execution failed. You can run the evolver manually:"
    echo "  Read: .pi/traces/index.json"
    echo "  Focus: $FOCUS"
    echo "  Write proposal to: .pi/traces/analysis/proposals/proposal-$PROPOSAL_NUM.md"
  }
else
  echo "pi CLI not found. Run the evolver manually via subagent:"
  echo ""
  echo "Task for harness-evolver agent:"
  echo "$FULL_TASK"
fi

echo ""
echo "Done. Check proposals at: $PROPOSALS_DIR/"
