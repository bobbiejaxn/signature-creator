#!/bin/bash
# CEO with automatic model fallback on rate limits
# Runs CEO agent directly via pi in non-interactive mode
# Usage: ./ceo-with-fallback.sh "<goal>" [project-dir]

set -e

GOAL="$1"
PROJECT_DIR="${2:-$(pwd)}"
MAX_RETRIES=3

# Source centralized model router (loads env, sets up chain)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/model-router.sh"

# Build model chain dynamically (skips providers without keys or on cooldown)
MODELS=($(get_model_chain))

if [[ ${#MODELS[@]} -eq 0 ]]; then
  echo "❌ No models available (all keys missing)"
  exit 1
fi

# Run CEO agent directly with pi
run_ceo_with_model() {
  local model="$1"
  local attempt="$2"
  local provider
  provider=$(_extract_provider "$model")

  echo "$(date '+%Y-%m-%d %H:%M:%S') - Attempt $attempt with model: $model" >> /tmp/ceo-fallback.log

  cd "$PROJECT_DIR"

  # CEO agent system prompt
  local ceo_prompt="You are the CEO of an autonomous software development team.

Goal: $GOAL

Your role:
1. PLAN - Analyze the goal and create a task breakdown
2. DELEGATE - Assign tasks to workers (architect, implementer, reviewer, fixer, test-writer)
3. REVIEW - Check worker output for quality
4. ITERATE - Refine until goal is achieved
5. VERIFY - Confirm the solution works end-to-end
6. COMPLETE - Report final status

Available workers:
- architect: System design, schemas, API contracts
- implementer: Write code from plan
- reviewer: Code quality review
- security-reviewer: Security audit
- test-writer: E2E/integration tests
- fixer: Fix issues from review
- debug-agent: Diagnose failures

Decision principles:
- Start with architecture before implementation
- Parallelize independent work when possible
- Review before moving to next task
- Fail fast: if a task fails twice, try different approach
- Be cost-conscious: act on what you know

Report progress clearly. When done, say 'GOAL COMPLETE' and summarize what was achieved."

  # Run with timeout and capture output
  local output
  local exit_code

  output=$(timeout 3600 pi -p --no-session --model "$model" "$ceo_prompt" 2>&1) && exit_code=$? || exit_code=$?

  # Log output for debugging
  local safe_model_name="${model//\//-}"
  echo "$output" >> "/tmp/ceo-output-${safe_model_name}.log"

  # Check for timeout
  if [[ $exit_code -eq 124 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Timeout on $model" >> /tmp/ceo-fallback.log
    return 1
  fi

  # Check for rate limit errors
  if echo "$output" | grep -qE "429|rate.?limit|1302|速率限制|quota exceeded"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Rate limited on $model" >> /tmp/ceo-fallback.log
    echo "$output" >> /tmp/ceo-rate-limits.log
    mark_rate_limited "$provider" "$MODEL_ROUTER_DEFAULT_COOLDOWN"
    return 1
  fi

  # Check for transient server errors (HTTP 500/502/503)
  if echo "$output" | grep -qE "500|Internal Server Error|Bad Gateway|502|503|Service Unavailable"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Transient server error on $model (HTTP 5xx)" >> /tmp/ceo-fallback.log
    # Transient error -- retry is worthwhile, don't skip this model entirely
    return 1
  fi

  # Check for auth errors
  if echo "$output" | grep -qE "No API key found|Authentication Fails|401|invalid.*key"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Auth error on $model" >> /tmp/ceo-fallback.log
    return 1
  fi

  # Check for model-not-found errors
  if echo "$output" | grep -qE "model.*not found|does not exist|invalid model"; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Model not found: $model" >> /tmp/ceo-fallback.log
    return 1
  fi

  # Check for other errors
  if [[ $exit_code -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error (exit $exit_code) on $model" >> /tmp/ceo-fallback.log
    return 1
  fi

  # Success - check for actual completion indicators
  if echo "$output" | grep -qE "GOAL COMPLETE|MISSION COMPLETE|All tasks complete|PR created successfully"; then
    echo "$output"
    return 0
  fi

  # If output is substantial, assume progress
  if [[ ${#output} -gt 1000 ]]; then
    echo "$output"
    return 0
  fi

  return 1
}

# Main loop with fallback
echo "🚀 Starting CEO session: $GOAL"
echo "📁 Project: $PROJECT_DIR"
echo "🔗 Model chain: ${MODELS[*]}"
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting CEO: $GOAL" >> /tmp/ceo-fallback.log

for model in "${MODELS[@]}"; do
  for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
    if run_ceo_with_model "$model" "$attempt"; then
      echo ""
      echo "✅ CEO completed successfully with $model"
      echo "$(date '+%Y-%m-%d %H:%M:%S') - Success with $model" >> /tmp/ceo-fallback.log
      exit 0
    fi

    # If rate limited, skip remaining retries for this model
    if ! is_provider_available "$(_extract_provider "$model")"; then
      echo "⏭️ $model on cooldown, trying next fallback..."
      break
    fi

    # If not last attempt, exponential backoff
    if [[ $attempt -lt $MAX_RETRIES ]]; then
      sleep $((2 ** attempt))
    else
      echo "⏭️ Max retries reached for $model, trying next fallback..."
    fi
  done
done

echo ""
echo "❌ All models exhausted. CEO session failed."
echo "$(date '+%Y-%m-%d %H:%M:%S') - All models exhausted" >> /tmp/ceo-fallback.log
echo "📋 Check logs: /tmp/ceo-fallback.log, /tmp/ceo-rate-limits.log"
show_status

# Create GitHub issue for escalation
if command -v gh &> /dev/null; then
  cd "$PROJECT_DIR"
  gh issue create \
    --title "CEO Session Failed: All Models Exhausted" \
    --body "Goal: $GOAL

All fallback models failed:
${MODELS[*]}

Check logs:
- /tmp/ceo-fallback.log
- /tmp/ceo-rate-limits.log" \
    --label "ceo-escalation,blocked" 2>/dev/null || true
fi

exit 1
