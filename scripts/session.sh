#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Session Management — Create, switch, and archive agent sessions
# ──────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/session.sh new [name]     # Create new session (auto-generates ID)
#   ./scripts/session.sh current        # Show current session info
#   ./scripts/session.sh log <message>  # Append to conversation log
#   ./scripts/session.sh archive        # Archive current session
#   ./scripts/session.sh list           # List all sessions

set -euo pipefail

SESSIONS_DIR=".pi/sessions"
CURRENT_DIR="$SESSIONS_DIR/current"

case "${1:-help}" in
  new)
    SESSION_ID="$(date +%Y%m%d_%H%M%S)_${2:-session}"
    SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"
    mkdir -p "$SESSION_DIR/artifacts"
    touch "$SESSION_DIR/conversation.jsonl"
    # Update current symlink
    rm -rf "$CURRENT_DIR"
    ln -sf "$SESSION_ID" "$CURRENT_DIR"
    echo "Created session: $SESSION_ID"
    echo "Log: $SESSION_DIR/conversation.jsonl"
    ;;

  current)
    if [ -L "$CURRENT_DIR" ]; then
      echo "Current session: $(readlink "$CURRENT_DIR")"
      if [ -f "$CURRENT_DIR/conversation.jsonl" ]; then
        LINES=$(wc -l < "$CURRENT_DIR/conversation.jsonl" | tr -d ' ')
        echo "Conversation entries: $LINES"
      fi
    else
      echo "No active session. Run: ./scripts/session.sh new"
    fi
    ;;

  log)
    shift
    FROM="${FROM:-system}"
    TYPE="${TYPE:-system}"
    MESSAGE="$*"
    if [ -z "$MESSAGE" ]; then
      echo "Usage: FROM=agent-name TYPE=agent ./scripts/session.sh log <message>"
      exit 1
    fi
    mkdir -p "$CURRENT_DIR"
    echo "{\"from\": \"$FROM\", \"message\": \"$MESSAGE\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"type\": \"$TYPE\"}" >> "$CURRENT_DIR/conversation.jsonl"
    ;;

  archive)
    if [ -L "$CURRENT_DIR" ]; then
      SESSION_ID=$(readlink "$CURRENT_DIR")
      rm -f "$CURRENT_DIR"
      mkdir -p "$CURRENT_DIR/artifacts"
      touch "$CURRENT_DIR/conversation.jsonl"
      echo "Archived: $SESSION_ID"
      echo "New empty session ready."
    else
      echo "No active session to archive."
    fi
    ;;

  list)
    echo "Sessions:"
    for d in "$SESSIONS_DIR"/*/; do
      [ -d "$d" ] || continue
      NAME=$(basename "$d")
      [ "$NAME" = "current" ] && continue
      LINES=0
      [ -f "$d/conversation.jsonl" ] && LINES=$(wc -l < "$d/conversation.jsonl" | tr -d ' ')
      echo "  $NAME ($LINES entries)"
    done
    ;;

  *)
    echo "Usage: ./scripts/session.sh {new|current|log|archive|list}"
    ;;
esac
