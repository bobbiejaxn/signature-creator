#!/usr/bin/env bash
# ─── pi_launchpad Update Script ──────────────────────────────────────────────
# Syncs the latest framework files from GitHub into an existing project.
# Preserves: config.sh, specs, learnings, traces, sessions, harness-versions,
#            board-expertise scratch pads, and any local customizations.
#
# Usage:
#   ./scripts/update.sh                    # Update from GitHub (default: bobbiejaxn/pi_launchpad)
#   ./scripts/update.sh --local /path/to/pi_launchpad   # Update from local clone
#   ./scripts/update.sh --dry-run          # Preview what would change
#   ./scripts/update.sh --force            # Overwrite even protected files
#
# Safe to run repeatedly. Idempotent.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

REPO="bobbiejaxn/pi_launchpad"
BRANCH="main"
TARGET="$(pwd)"
SOURCE=""
DRY_RUN=false
FORCE=false
TEMP_DIR=""

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

heading() { echo ""; echo -e "${BLUE}━━━ $* ━━━${NC}"; }
done_msg() { echo -e "  ${GREEN}✓ $*${NC}"; }
warn() { echo -e "  ${YELLOW}! $*${NC}" >&2; }
err() { echo -e "  ${RED}✗ $*${NC}" >&2; }
info() { echo -e "  ${CYAN}→ $*${NC}"; }

# ─── Parse Args ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)   SOURCE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force)   FORCE=true; shift ;;
    --target)  TARGET="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--local /path] [--dry-run] [--force] [--target /path]"
      echo ""
      echo "  --local   Use a local clone instead of downloading from GitHub"
      echo "  --dry-run Preview changes without writing files"
      echo "  --force   Overwrite protected files (config.sh, board-expertise, etc.)"
      echo "  --target  Target project directory (default: current directory)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Pre-flight Checks ──────────────────────────────────────────────────────

if [ ! -d "$TARGET/.pi" ]; then
  err "No .pi/ directory found in $TARGET"
  err "This doesn't look like a pi_launchpad project. Run setup.sh first."
  exit 1
fi

heading "pi_launchpad Update"
info "Target: $TARGET"

# ─── Get Latest Source ──────────────────────────────────────────────────────

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

if [ -z "$SOURCE" ]; then
  # Strategy: 1) Auto-detect local clone, 2) gh CLI, 3) curl with token, 4) fail with helpful message
  
  LOCAL_CLONE="$HOME/pi_launchpad"
  if [ -d "$LOCAL_CLONE/.pi" ]; then
    SOURCE="$LOCAL_CLONE"
    done_msg "Auto-detected local clone: $SOURCE"
  else
    # Try gh CLI (handles private repos with auth)
    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
      info "Downloading via gh CLI (authenticated)..."
      TEMP_DIR=$(mktemp -d)
      if gh repo clone "$REPO" "$TEMP_DIR/repo" -- --branch="$BRANCH" --depth=1 2>/dev/null; then
        SOURCE="$TEMP_DIR/repo"
        done_msg "Downloaded via gh CLI"
      else
        err "gh repo clone failed"
        rm -rf "$TEMP_DIR"
        exit 1
      fi
    elif [ -n "${GH_TOKEN:-}" ]; then
      # Try curl with GH_TOKEN
      info "Downloading via GH_TOKEN..."
      TEMP_DIR=$(mktemp -d)
      ZIP_URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"
      HTTP_CODE=$(curl -sL -w "%{http_code}" -H "Authorization: token $GH_TOKEN" -o "$TEMP_DIR/source.zip" "$ZIP_URL")
      
      if [ "$HTTP_CODE" = "200" ]; then
        cd "$TEMP_DIR" && unzip -q source.zip
        SOURCE="$TEMP_DIR/pi_launchpad-main"
      else
        err "Failed to download (HTTP $HTTP_CODE)"
        echo ""
        echo "  The repo is private. Fix with one of:"
        echo "    1. Keep a local clone at ~/pi_launchpad (auto-detected)"
        echo "    2. Run: gh auth login (then retry)"
        echo "    3. Run: ./scripts/update.sh --local /path/to/pi_launchpad"
        rm -rf "$TEMP_DIR"
        exit 1
      fi
    else
      # Public repo fallback (curl without auth)
      TEMP_DIR=$(mktemp -d)
      ZIP_URL="https://github.com/$REPO/archive/refs/heads/$BRANCH.zip"
      
      if command -v curl &>/dev/null; then
        HTTP_CODE=$(curl -sL -w "%{http_code}" -o "$TEMP_DIR/source.zip" "$ZIP_URL")
      elif command -v wget &>/dev/null; then
        HTTP_CODE=$(wget -q -O "$TEMP_DIR/source.zip" "$ZIP_URL" 2>&1 | grep -o '[0-9]*' | tail -1)
        HTTP_CODE=${HTTP_CODE:-200}
      else
        err "Need curl or wget to download from GitHub"
        exit 1
      fi
      
      if [ "$HTTP_CODE" != "200" ]; then
        err "Failed to download (HTTP $HTTP_CODE)"
        echo ""
        echo "  The repo may be private. Fix with one of:"
        echo "    1. Keep a local clone at ~/pi_launchpad (auto-detected)"
        echo "    2. Run: gh auth login (then retry)"
        echo "    3. Run: ./scripts/update.sh --local /path/to/pi_launchpad"
        rm -rf "$TEMP_DIR"
        exit 1
      fi
      
      cd "$TEMP_DIR" && unzip -q source.zip
      SOURCE="$TEMP_DIR/pi_launchpad-main"
    fi
    
    if [ ! -d "$SOURCE" ]; then
      SOURCE=$(find "$TEMP_DIR" -maxdepth 1 -type d -not -name "$(basename "$TEMP_DIR")" | head -1)
    fi
    if [ ! -d "$SOURCE/.pi" ]; then
      err "Downloaded archive doesn't contain .pi/ directory"
      exit 1
    fi
  fi
else
  # Use specified local clone
  if [ ! -d "$SOURCE/.pi" ]; then
    err "Local source $SOURCE doesn't have .pi/ directory"
    exit 1
  fi
  done_msg "Using local source: $SOURCE"
fi

# ─── File Sync Logic ────────────────────────────────────────────────────────

# Files/dirs that are ALWAYS synced from source (framework files)
SYNC_ALWAYS=(
  ".pi/agents"
  ".pi/agents/board"
  ".pi/extensions"
  ".pi/prompts"
  ".pi/skills"
  ".pi/expertise"
  ".pi/traces/.gitkeep"
  ".pi/harness-versions/.gitkeep"
  ".pi/sessions/.gitkeep"
  ".pi/board-config.yaml"
  "scripts"
  ".pi/assets"
  "AGENTS.md"
  "README.md"
)

# Files that are PRESERVED (never overwritten unless --force)
PROTECTED=(
  ".pi/config.sh"
  ".pi/board-expertise"
  ".pi/traces"
  ".pi/harness-versions"
  ".pi/sessions"
  ".learnings"
  "specs"
  "tests"
)

# ─── Sync Function ──────────────────────────────────────────────────────────

sync_dir() {
  local src="$1"
  local dst="$2"
  local label="$3"
  
  if [ ! -d "$src" ]; then return; fi
  
  local count=0
  mkdir -p "$dst"
  
  # rsync if available (faster, shows diff)
  if command -v rsync &>/dev/null; then
    if [ "$DRY_RUN" = true ]; then
      count=$(rsync -avn --delete "$src/" "$dst/" 2>/dev/null | grep -c "^deleting\|^>" || true)
      if [ "$count" -gt 0 ]; then
        info "Would sync $count changes in $label"
        rsync -avn --delete --itemize-changes "$src/" "$dst/" 2>/dev/null | head -20
      fi
    else
      rsync -a --delete "$src/" "$dst/" 2>/dev/null
      count=$(ls -1 "$dst" 2>/dev/null | wc -l | tr -d ' ')
    fi
  else
    # Fallback: cp -r
    if [ "$DRY_RUN" = true ]; then
      count=$(find "$src" -type f | wc -l | tr -d ' ')
      info "Would copy $count files to $label"
    else
      cp -r "$src/"* "$dst/" 2>/dev/null || true
      count=$(ls -1 "$dst" 2>/dev/null | wc -l | tr -d ' ')
    fi
  fi
  
  if [ "$DRY_RUN" = false ]; then
    done_msg "$label ($count files)"
  fi
}

sync_file() {
  local src="$1"
  local dst="$2"
  local label="$3"
  
  if [ ! -f "$src" ]; then return; fi
  
  if [ "$DRY_RUN" = true ]; then
    if [ -f "$dst" ]; then
      if ! diff -q "$src" "$dst" &>/dev/null; then
        info "Would update $label (changed)"
      else
        info "No change: $label"
      fi
    else
      info "Would create $label (new)"
    fi
    return
  fi
  
  cp "$src" "$dst"
  done_msg "$label"
}

# ─── Perform Sync ────────────────────────────────────────────────────────────

heading "Syncing Framework Files"

# Core framework directories
sync_dir "$SOURCE/.pi/agents" "$TARGET/.pi/agents" "Agents (core)"
sync_dir "$SOURCE/.pi/agents/board" "$TARGET/.pi/agents/board" "Agents (board)"
sync_dir "$SOURCE/.pi/extensions" "$TARGET/.pi/extensions" "Extensions"
sync_dir "$SOURCE/.pi/prompts" "$TARGET/.pi/prompts" "Prompts"
sync_dir "$SOURCE/.pi/skills" "$TARGET/.pi/skills" "Skills"
sync_dir "$SOURCE/.pi/expertise" "$TARGET/.pi/expertise" "Expertise"
sync_dir "$SOURCE/scripts" "$TARGET/scripts" "Scripts"

# Assets (cinematic modules, fonts config, etc.)
if [ -d "$SOURCE/.pi/assets" ]; then
  sync_dir "$SOURCE/.pi/assets" "$TARGET/.pi/assets" "Assets"
fi

# Ensure trace/session/harness-version directories exist (don't overwrite contents)
mkdir -p "$TARGET/.pi/traces" "$TARGET/.pi/sessions" "$TARGET/.pi/harness-versions"

# Board config (always synced — it's framework-level)
sync_file "$SOURCE/.pi/board-config.yaml" "$TARGET/.pi/board-config.yaml" "Board config"

# Top-level docs
sync_file "$SOURCE/AGENTS.md" "$TARGET/AGENTS.md" "AGENTS.md"
sync_file "$SOURCE/README.md" "$TARGET/README.md" "README.md"

# ─── Protected Files Check ───────────────────────────────────────────────────

if [ "$FORCE" = false ]; then
  heading "Protected Files (preserved)"
  for p in "${PROTECTED[@]}"; do
    if [ -e "$TARGET/$p" ]; then
      info "$p — kept (use --force to overwrite)"
    fi
  done
fi

# ─── Learnings (merge, don't overwrite) ─────────────────────────────────────

if [ -f "$SOURCE/.learnings/LEARNINGS.md" ] && [ ! -f "$TARGET/.learnings/LEARNINGS.md" ]; then
  mkdir -p "$TARGET/.learnings"
  if [ "$DRY_RUN" = false ]; then
    cp "$SOURCE/.learnings/LEARNINGS.md" "$TARGET/.learnings/LEARNINGS.md"
    cp "$SOURCE/.learnings/ERRORS.md" "$TARGET/.learnings/ERRORS.md" 2>/dev/null || true
  fi
  done_msg "Learnings (created — not overwriting existing)"
else
  info "Learnings — kept (existing preserved)"
fi

# Research files (sync new ones, don't delete existing)
if [ -d "$SOURCE/.learnings/research" ]; then
  mkdir -p "$TARGET/.learnings/research"
  if [ "$DRY_RUN" = false ]; then
    cp -rn "$SOURCE/.learnings/research/"* "$TARGET/.learnings/research/" 2>/dev/null || true
  fi
  done_msg "Research files (new only)"
fi

# ─── Config Migration ────────────────────────────────────────────────────────

if [ "$FORCE" = true ] && [ -f "$SOURCE/.pi/config.sh" ]; then
  warn "Overwriting config.sh (--force)"
  if [ "$DRY_RUN" = false ]; then
    cp "$SOURCE/.pi/config.sh" "$TARGET/.pi/config.sh"
  fi
else
  # Check if config has new fields that the target is missing
  if [ -f "$SOURCE/.pi/config.sh" ] && [ -f "$TARGET/.pi/config.sh" ]; then
    NEW_VARS=$(comm -23 \
      <(grep -E '^[A-Z_]+=' "$SOURCE/.pi/config.sh" | sed 's/=.*//' | sort) \
      <(grep -E '^[A-Z_]+=' "$TARGET/.pi/config.sh" | sed 's/=.*//' | sort) \
      2>/dev/null || true)
    if [ -n "$NEW_VARS" ]; then
      warn "New config variables available: $(echo "$NEW_VARS" | tr '\n' ', ')"
      info "Review $SOURCE/.pi/config.sh and merge manually, or re-run with --force"
    fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

# ─── User-Level Extension Conflict Check ─────────────────────────────────────
# Pi loads extensions from both ~/.pi/agent/extensions/ and .pi/extensions/
# If the same tool is registered in both, Pi crashes on startup.
# Remove user-level duplicates since project-local ones are canonical.

USER_EXT_DIR="$HOME/.pi/agent/extensions"
if [ -d "$USER_EXT_DIR" ] && [ -d "$TARGET/.pi/extensions" ]; then
  CONFLICTS=0
  for project_ext in "$TARGET"/.pi/extensions/*/; do
    ext_name=$(basename "$project_ext")
    if [ -d "$USER_EXT_DIR/$ext_name" ]; then
      CONFLICTS=$((CONFLICTS + 1))
      if [ "$DRY_RUN" = false ]; then
        mv "$USER_EXT_DIR/$ext_name" "$USER_EXT_DIR/${ext_name}.disabled.$$" 2>/dev/null || true
        warn "Removed conflicting user extension: $ext_name (project-local version kept)"
      else
        warn "Would remove conflicting user extension: $ext_name"
      fi
    fi
    # Also clean up any previously-disabled duplicates from old runs
    if ls "$USER_EXT_DIR/${ext_name}.disabled."* >/dev/null 2>&1; then
      for old_disabled in "$USER_EXT_DIR/${ext_name}.disabled."*; do
        rm -rf "$old_disabled" 2>/dev/null || true
      done
    fi
  done
  if [ "$CONFLICTS" -gt 0 ] && [ "$DRY_RUN" = false ]; then
    done_msg "Resolved $CONFLICTS extension conflict(s) — project-local versions take precedence"
  fi
fi

heading "Update Complete"

if [ "$DRY_RUN" = true ]; then
  info "Dry run — no files were changed"
  echo ""
  echo "  Run without --dry-run to apply changes."
else
  AGENT_COUNT=$(ls "$TARGET"/.pi/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
  BOARD_COUNT=$(ls "$TARGET"/.pi/agents/board/*.md 2>/dev/null | wc -l | tr -d ' ')
  EXT_COUNT=$(ls -d "$TARGET"/.pi/extensions/*/ 2>/dev/null | wc -l | tr -d ' ')
  PROMPT_COUNT=$(ls "$TARGET"/.pi/prompts/*.md 2>/dev/null | wc -l | tr -d ' ')
  SKILL_COUNT=$(ls -d "$TARGET"/.pi/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
  SCRIPT_COUNT=$(ls "$TARGET"/scripts/*.sh 2>/dev/null | wc -l | tr -d ' ')
  
  echo ""
  echo "  Synced:"
  echo "    Agents:      $AGENT_COUNT core + $BOARD_COUNT board"
  echo "    Extensions:  $EXT_COUNT"
  echo "    Prompts:     $PROMPT_COUNT"
  echo "    Skills:      $SKILL_COUNT"
  echo "    Scripts:     $SCRIPT_COUNT"
  echo ""
  echo "  Preserved:     config.sh, learnings, traces, sessions, specs, tests"
  echo ""
  echo "  Next: Run /prime to reload context with updated agents."
fi
