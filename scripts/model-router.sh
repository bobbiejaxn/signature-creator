#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# model-router.sh — Centralized model routing with rate-limit tracking
# ──────────────────────────────────────────────────────────────────────────────
# Source this file in CEO scripts and other automation to get dynamic model
# fallback. Straico is excluded from coding chains (web search only).
#
# Usage:
#   source /root/pi_launchpad/scripts/model-router.sh
#   MODELS=($(get_model_chain))
#   best=$(get_best_model)
#   mark_rate_limited zai 300
#   show_status
# ──────────────────────────────────────────────────────────────────────────────

MODEL_ROUTER_STATE_FILE="${MODEL_ROUTER_STATE_FILE:-/tmp/model-router-state.json}"
MODEL_ROUTER_DEFAULT_COOLDOWN="${MODEL_ROUTER_DEFAULT_COOLDOWN:-300}"

# Load Hermes env if not already loaded
if [[ -z "${GLM_API_KEY:-}" ]] && [[ -f /root/.hermes/.env ]]; then
  export $(grep -v "^#" /root/.hermes/.env | grep -v "^$" | xargs) 2>/dev/null
fi

# Map GLM_API_KEY to ZAI_API_KEY (pi expects ZAI_API_KEY)
export ZAI_API_KEY="${GLM_API_KEY:-${ZAI_API_KEY:-}}"

# ── Coding fallback chain (order matters) ────────────────────────────────────
# Each entry: "provider/model:ENV_VAR_FOR_KEY"
_CODING_CHAIN=(
  "zai/glm-5.1:ZAI_API_KEY"
  "minimax/MiniMax-M2.7:MINIMAX_API_KEY"
  "anthropic/claude-opus-4-6:ANTHROPIC_API_KEY"
)

# ── State file helpers ───────────────────────────────────────────────────────

_ensure_state_file() {
  if [[ ! -f "$MODEL_ROUTER_STATE_FILE" ]]; then
    echo '{}' > "$MODEL_ROUTER_STATE_FILE"
  fi
}

_get_cooldown_expiry() {
  local provider="$1"
  _ensure_state_file
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
with open('$MODEL_ROUTER_STATE_FILE') as f:
    state = json.load(f)
entry = state.get('$provider', {})
print(entry.get('expires', 0))
" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

_extract_provider() {
  # "zai/glm-5.1" → "zai"
  echo "${1%%/*}"
}

# ── Public API ───────────────────────────────────────────────────────────────

is_provider_available() {
  # Check if a provider has a valid API key and is not on cooldown.
  # Usage: is_provider_available "zai"
  local provider="$1"
  local now
  now=$(date +%s)

  # Check cooldown
  local expiry
  expiry=$(_get_cooldown_expiry "$provider")
  if [[ "$expiry" -gt "$now" ]]; then
    return 1
  fi

  # Check API key
  for entry in "${_CODING_CHAIN[@]}"; do
    local prov="${entry%%/*}"
    if [[ "$prov" == "$provider" ]]; then
      local env_var="${entry##*:}"
      if [[ -z "${!env_var:-}" ]]; then
        return 1
      fi
      return 0
    fi
  done

  return 1
}

mark_rate_limited() {
  # Mark a provider as rate-limited for N seconds.
  # Usage: mark_rate_limited "zai" 300
  local provider="$1"
  local seconds="${2:-$MODEL_ROUTER_DEFAULT_COOLDOWN}"
  local now
  now=$(date +%s)
  local expires=$((now + seconds))

  _ensure_state_file

  if command -v python3 &>/dev/null; then
    python3 -c "
import json
with open('$MODEL_ROUTER_STATE_FILE') as f:
    state = json.load(f)
state['$provider'] = {'expires': $expires, 'marked_at': $now, 'cooldown': $seconds}
with open('$MODEL_ROUTER_STATE_FILE', 'w') as f:
    json.dump(state, f)
" 2>/dev/null
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S') - Rate limited: $provider for ${seconds}s" >> /tmp/model-router.log
}

get_model_chain() {
  # Return the available model chain (provider/model pairs), skipping
  # providers without keys or on cooldown.
  # Usage: MODELS=($(get_model_chain))
  local result=()
  for entry in "${_CODING_CHAIN[@]}"; do
    local provider_model="${entry%%:*}"
    local provider="${provider_model%%/*}"
    if is_provider_available "$provider"; then
      result+=("$provider_model")
    fi
  done

  if [[ ${#result[@]} -eq 0 ]]; then
    # Emergency: return full chain regardless of cooldowns
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: All providers unavailable, returning full chain" >> /tmp/model-router.log
    for entry in "${_CODING_CHAIN[@]}"; do
      local provider_model="${entry%%:*}"
      local env_var="${entry##*:}"
      if [[ -n "${!env_var:-}" ]]; then
        result+=("$provider_model")
      fi
    done
  fi

  echo "${result[@]}"
}

get_best_model() {
  # Return the single best available model (first in chain not on cooldown).
  # Usage: model=$(get_best_model)
  local chain
  chain=($(get_model_chain))
  if [[ ${#chain[@]} -gt 0 ]]; then
    echo "${chain[0]}"
  fi
}

show_status() {
  # Print human-readable status of all providers.
  local now
  now=$(date +%s)

  echo "Model Router Status ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo "─────────────────────────────────────────────────"
  printf "%-30s %-10s %-10s %s\n" "MODEL" "KEY" "STATUS" "COOLDOWN"
  echo "─────────────────────────────────────────────────"

  for entry in "${_CODING_CHAIN[@]}"; do
    local provider_model="${entry%%:*}"
    local provider="${provider_model%%/*}"
    local env_var="${entry##*:}"
    local has_key="missing"
    local status="unavail"
    local cooldown_info="-"

    if [[ -n "${!env_var:-}" ]]; then
      has_key="set"
    fi

    local expiry
    expiry=$(_get_cooldown_expiry "$provider")
    if [[ "$expiry" -gt "$now" ]]; then
      local remaining=$((expiry - now))
      status="cooldown"
      cooldown_info="${remaining}s left"
    elif [[ "$has_key" == "set" ]]; then
      status="ready"
    fi

    printf "%-30s %-10s %-10s %s\n" "$provider_model" "$has_key" "$status" "$cooldown_info"
  done

  echo ""
  echo "Best model: $(get_best_model)"
  echo "State file: $MODEL_ROUTER_STATE_FILE"
}
