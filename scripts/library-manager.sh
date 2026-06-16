#!/bin/bash
set -e

# Library Manager - Bidirectional sync between library-central and projects
# Usage: ./library-manager.sh [command] [args]

LIBRARY_CENTRAL="${PI_LIBRARY_CENTRAL:-$HOME/.pi/library-central}"
PROJECT_PI=".pi"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
info() { echo -e "${BLUE}ℹ${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warning() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

# Check if library-central exists
check_library_exists() {
  if [ ! -d "$LIBRARY_CENTRAL" ]; then
    error "Library-central not found at $LIBRARY_CENTRAL

Run one of:
  1. Bootstrap from repos: ./scripts/bootstrap-library.sh
  2. Initialize empty: $0 init"
  fi
}

# Initialize library-central
cmd_init() {
  if [ -d "$LIBRARY_CENTRAL" ]; then
    warning "Library-central already exists at $LIBRARY_CENTRAL"
    return 0
  fi

  echo "📦 Initializing library-central..."
  mkdir -p "$LIBRARY_CENTRAL"
  cd "$LIBRARY_CENTRAL"

  git init

  # Create structure
  mkdir -p skills agents prompts workflows mcp-configs extensions learnings/patterns

  # Create initial catalog
  cat > catalog.yaml <<'EOF'
metadata:
  owner: $(whoami)
  created: $(date -I)
  version: 1.0.0
  description: "Pi Launchpad library"

artifact_types:
  skills: skills/
  agents: agents/
  prompts: prompts/
  workflows: workflows/
  mcp_configs: mcp-configs/
  extensions: extensions/
  learnings: learnings/patterns/

skills: []
agents: []
prompts: []
workflows: []
mcp_configs: []
extensions: []
learnings: []

dependencies: {}

stats:
  total_skills: 0
  total_agents: 0
  total_prompts: 0
  total_workflows: 0
  total_mcp_configs: 0
  total_extensions: 0
  total_learnings: 0
EOF

  git add -A
  git commit -m "chore: initialize library structure"

  success "Library-central initialized at $LIBRARY_CENTRAL"
  echo ""
  echo "Next steps:"
  echo "  1. Bootstrap from repos: ./scripts/bootstrap-library.sh"
  echo "  2. Or create artifacts manually in $LIBRARY_CENTRAL"
}

# Check for conflicts and handle them
handle_conflict() {
  local source=$1
  local dest=$2
  local item_name=$3

  # Check if dest exists
  if [ ! -e "$dest" ]; then
    return 0  # No conflict, proceed
  fi

  # Compare files/directories
  local has_diff=false

  if [ -d "$source" ] && [ -d "$dest" ]; then
    # Compare directories
    if ! diff -qr "$source" "$dest" > /dev/null 2>&1; then
      has_diff=true
    fi
  elif [ -f "$source" ] && [ -f "$dest" ]; then
    # Compare files
    if ! diff -q "$source" "$dest" > /dev/null 2>&1; then
      has_diff=true
    fi
  fi

  if [ "$has_diff" = false ]; then
    return 0  # Files are identical, proceed
  fi

  # Conflict detected
  echo ""
  warning "Conflict detected: $item_name"
  echo "  Library version differs from local"
  echo ""
  echo "Options:"
  echo "  1. Keep local (skip update)"
  echo "  2. Use library (overwrite local)"
  echo "  3. Show diff"
  echo "  4. Skip for now"
  echo ""
  read -p "Choice [1-4]: " choice

  case $choice in
    1)
      info "Keeping local version"
      return 1  # Skip sync
      ;;
    2)
      info "Using library version (overwriting local)"
      return 0  # Proceed with sync
      ;;
    3)
      echo ""
      echo "Diff (library on left, local on right):"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      if [ -f "$source" ] && [ -f "$dest" ]; then
        if command -v colordiff &> /dev/null; then
          colordiff -u "$source" "$dest" || diff -u "$source" "$dest"
        else
          diff -u "$source" "$dest"
        fi
      else
        diff -ur "$source" "$dest" 2>/dev/null || echo "Cannot show diff for directories"
      fi
      echo ""
      read -p "Use library version? (y/n): " use_lib
      if [ "$use_lib" = "y" ]; then
        return 0  # Proceed with sync
      else
        return 1  # Skip sync
      fi
      ;;
    4|*)
      info "Skipping"
      return 1  # Skip sync
      ;;
  esac
}

# Parse dependencies from an artifact file
parse_dependencies() {
  local file=$1
  local deps=()

  if [ ! -f "$file" ]; then
    echo ""
    return
  fi

  # Extract dependencies from YAML frontmatter
  local in_frontmatter=false
  local in_deps=false

  while IFS= read -r line; do
    # Check for frontmatter boundaries
    if [ "$line" = "---" ]; then
      if [ "$in_frontmatter" = false ]; then
        in_frontmatter=true
      else
        break  # End of frontmatter
      fi
      continue
    fi

    if [ "$in_frontmatter" = true ]; then
      # Check for dependencies section
      if [[ "$line" =~ ^dependencies: ]]; then
        in_deps=true
        continue
      fi

      # Extract dependency items
      if [ "$in_deps" = true ]; then
        if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.*) ]]; then
          dep="${BASH_REMATCH[1]}"
          deps+=("$dep")
        elif [[ ! "$line" =~ ^[[:space:]]+ ]]; then
          # End of dependencies section
          in_deps=false
        fi
      fi
    fi
  done < "$file"

  # Output dependencies comma-separated
  if [ ${#deps[@]} -gt 0 ]; then
    printf '%s\n' "${deps[@]}"
  fi
}

# Resolve and sync dependencies recursively
resolve_dependencies() {
  local artifact_type=$1
  local artifact_name=$2
  local visited_deps=("${@:3}")  # Track visited to avoid cycles

  # Build artifact ID
  local artifact_id="${artifact_type%%s}:$artifact_name"

  # Check if already visited
  for visited in "${visited_deps[@]}"; do
    if [ "$visited" = "$artifact_id" ]; then
      return  # Avoid circular dependencies
    fi
  done

  # Add to visited
  visited_deps+=("$artifact_id")

  # Determine file path
  local file=""
  case "$artifact_type" in
    skills) file="$LIBRARY_CENTRAL/skills/$artifact_name/SKILL.md" ;;
    agents) file="$LIBRARY_CENTRAL/agents/$artifact_name.md" ;;
    prompts) file="$LIBRARY_CENTRAL/prompts/$artifact_name.md" ;;
    *) return ;;  # Other types don't have dependencies
  esac

  if [ ! -f "$file" ]; then
    warning "Dependency file not found: $artifact_id"
    return
  fi

  # Parse dependencies
  mapfile -t deps < <(parse_dependencies "$file")

  if [ ${#deps[@]} -eq 0 ]; then
    return  # No dependencies
  fi

  # Sync each dependency
  for dep in "${deps[@]}"; do
    # Parse dependency format (e.g., "skill:commit" or "agent:implementer")
    if [[ "$dep" =~ ^([^:]+):(.+)$ ]]; then
      local dep_type="${BASH_REMATCH[1]}"
      local dep_name="${BASH_REMATCH[2]}"

      # Map singular to plural
      case "$dep_type" in
        skill) dep_type_plural="skills" ;;
        agent) dep_type_plural="agents" ;;
        prompt) dep_type_plural="prompts" ;;
        *) continue ;;
      esac

      # Check if dependency exists in library
      local dep_source="$LIBRARY_CENTRAL/$dep_type_plural/$dep_name"
      if [ "$dep_type" = "skill" ]; then
        dep_source="$dep_source/SKILL.md"
      else
        dep_source="$dep_source.md"
      fi

      if [ ! -e "$dep_source" ]; then
        warning "Dependency not found in library: $dep"
        continue
      fi

      # Check if already synced locally
      local local_path="$PROJECT_PI/$dep_type_plural/$dep_name"
      if [ "$dep_type" = "skill" ]; then
        local_path="$local_path/SKILL.md"
      else
        local_path="$local_path.md"
      fi

      if [ -f "$local_path" ]; then
        continue  # Already synced
      fi

      # Sync dependency
      info "Installing dependency: $dep"
      mkdir -p "$PROJECT_PI/$dep_type_plural"

      if [ "$dep_type" = "skill" ]; then
        # Copy entire skill directory
        cp -r "$LIBRARY_CENTRAL/$dep_type_plural/$dep_name" "$PROJECT_PI/$dep_type_plural/"
      else
        # Copy single file
        cp "$LIBRARY_CENTRAL/$dep_type_plural/$dep_name.md" "$PROJECT_PI/$dep_type_plural/"
      fi

      # Recursively resolve dependencies of this dependency
      resolve_dependencies "$dep_type_plural" "$dep_name" "${visited_deps[@]}"
    fi
  done
}

# Sync artifacts from library-central to project
cmd_sync() {
  check_library_exists

  local artifact_type="${1:-all}"

  echo "🔄 Syncing from library-central..."
  echo ""

  # Create .pi structure if missing
  mkdir -p "$PROJECT_PI"/{skills,agents,prompts,workflows,mcp-configs,extensions,learnings/patterns}

  local total_synced=0

  # Helper function to sync a type
  sync_type() {
    local type=$1
    local source_dir=$2
    local dest_dir=$3

    if [ "$artifact_type" != "all" ] && [ "$artifact_type" != "$type" ]; then
      return 0
    fi

    local synced=0

    if [ ! -d "$LIBRARY_CENTRAL/$source_dir" ]; then
      return 0
    fi

    for item in "$LIBRARY_CENTRAL/$source_dir"/*; do
      if [ ! -e "$item" ]; then
        continue
      fi

      item_name=$(basename "$item")
      dest="$PROJECT_PI/$dest_dir/$item_name"

      # Handle conflicts if file exists
      if ! handle_conflict "$item" "$dest" "$item_name"; then
        continue  # User chose to skip
      fi

      # Copy to project
      if [ -d "$item" ]; then
        mkdir -p "$dest"
        cp -r "$item"/* "$dest/" 2>/dev/null || true
      else
        cp "$item" "$dest" 2>/dev/null || true
      fi

      # Resolve dependencies for this artifact
      resolve_dependencies "$source_dir" "$item_name"

      ((synced++))
    done

    if [ $synced -gt 0 ]; then
      success "$type: $synced synced"
    fi

    ((total_synced += synced))
  }

  # Sync all types
  sync_type "Skills" "skills" "skills"
  sync_type "Agents" "agents" "agents"
  sync_type "Prompts" "prompts" "prompts"
  sync_type "Workflows" "workflows" "workflows"
  sync_type "MCP Configs" "mcp-configs" "mcp-configs"
  sync_type "Extensions" "extensions" "extensions"
  sync_type "Learnings" "learnings/patterns" "learnings/patterns"

  echo ""
  if [ $total_synced -eq 0 ]; then
    info "Everything up to date"
  else
    update_catalog_on_sync $total_synced
    success "Sync complete! ($total_synced artifacts)"
  fi
}

# Update catalog.yaml on push
update_catalog_on_push() {
  local type=$1
  local name=$2
  local catalog="$LIBRARY_CENTRAL/catalog.yaml"

  if [ ! -f "$catalog" ]; then
    warning "Catalog not found, skipping update"
    return
  fi

  # Map type to plural for catalog
  local type_plural
  case $type in
    skill) type_plural="skills" ;;
    agent) type_plural="agents" ;;
    prompt) type_plural="prompts" ;;
    pattern|learning) type_plural="learnings" ;;
    workflow) type_plural="workflows" ;;
    extension|ext) type_plural="extensions" ;;
    mcp|mcp-config) type_plural="mcp_configs" ;;
  esac

  # Update stats
  local current_count=$(grep "total_${type_plural}:" "$catalog" | sed 's/.*: //')
  local new_count=$((current_count + 1))

  # Update count in catalog
  sed -i.bak "s/total_${type_plural}: .*/total_${type_plural}: $new_count/" "$catalog" 2>/dev/null || \
    sed -i '' "s/total_${type_plural}: .*/total_${type_plural}: $new_count/" "$catalog" 2>/dev/null
  rm -f "$catalog.bak"

  # Update last_updated date
  local today=$(date -I 2>/dev/null || date +%Y-%m-%d)
  sed -i.bak "s/last_updated: .*/last_updated: $today/" "$catalog" 2>/dev/null || \
    sed -i '' "s/last_updated: .*/last_updated: $today/" "$catalog" 2>/dev/null
  rm -f "$catalog.bak"

  info "Updated catalog stats"
}

# Update catalog.yaml on sync
update_catalog_on_sync() {
  local synced_count=$1
  local catalog="$LIBRARY_CENTRAL/catalog.yaml"

  if [ ! -f "$catalog" ]; then
    return
  fi

  # Update last_sync timestamp
  local today=$(date -I 2>/dev/null || date +%Y-%m-%d)
  sed -i.bak "s/last_sync: .*/last_sync: $today/" "$catalog" 2>/dev/null || \
    sed -i '' "s/last_sync: .*/last_sync: $today/" "$catalog" 2>/dev/null
  rm -f "$catalog.bak"
}

# Push artifact from project to library-central
cmd_push() {
  check_library_exists

  local artifact_spec=$1

  if [ -z "$artifact_spec" ]; then
    error "Usage: $0 push <type:name>

Examples:
  $0 push skill:my-skill
  $0 push agent:implementer
  $0 push pattern:my-pattern"
  fi

  local type=${artifact_spec%%:*}
  local name=${artifact_spec#*:}

  # Map type to directory
  case $type in
    skill) source_dir="skills"; dest_dir="skills" ;;
    agent) source_dir="agents"; dest_dir="agents" ;;
    prompt) source_dir="prompts"; dest_dir="prompts" ;;
    pattern|learning) source_dir="learnings/patterns"; dest_dir="learnings/patterns" ;;
    workflow) source_dir="workflows"; dest_dir="workflows" ;;
    extension|ext) source_dir="extensions"; dest_dir="extensions" ;;
    mcp|mcp-config) source_dir="mcp-configs"; dest_dir="mcp-configs" ;;
    *)
      error "Unknown artifact type: $type

Valid types: skill, agent, prompt, pattern, workflow, extension, mcp"
      ;;
  esac

  local source="$PROJECT_PI/$source_dir/$name"

  if [ ! -e "$source" ]; then
    # Try with .md extension
    if [ -f "$source.md" ]; then
      source="$source.md"
      name="$name.md"
    else
      error "Artifact not found: $source

Available in .pi/$source_dir/:
$(ls -1 "$PROJECT_PI/$source_dir/" 2>/dev/null || echo "  (empty)")"
    fi
  fi

  echo "📤 Pushing to library-central..."
  echo ""

  local dest="$LIBRARY_CENTRAL/$dest_dir/$name"

  # Copy to library-central
  if [ -d "$source" ]; then
    mkdir -p "$dest"
    cp -r "$source"/* "$dest/" 2>/dev/null || true
  else
    mkdir -p "$(dirname "$dest")"
    cp "$source" "$dest" 2>/dev/null || true
  fi

  info "$type:$name → library-central"

  # Update catalog
  cd "$LIBRARY_CENTRAL"
  update_catalog_on_push "$type" "$name"

  # Commit to library-central
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "feat: add $type:${name%.md} from $(basename "$(pwd)")"
    success "Committed to library-central"
  else
    info "No changes to commit"
  fi

  echo ""
  success "Push complete! Artifact now available to all projects."
  echo ""
  echo "Next: Run '$0 sync' in other projects to get this artifact."
}

# Show status - compare library-central vs project
cmd_status() {
  check_library_exists

  echo "📊 Library Status"
  echo ""
  echo "Library-central: $LIBRARY_CENTRAL"
  echo "Local: $(pwd)/$PROJECT_PI"
  echo ""

  # Helper to check status of a type
  check_type() {
    local type_name=$1
    local lib_dir=$2
    local local_dir=$3

    local lib_count=0
    local local_count=0
    local missing_local=()
    local local_only=()

    if [ -d "$LIBRARY_CENTRAL/$lib_dir" ]; then
      lib_count=$(find "$LIBRARY_CENTRAL/$lib_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    fi

    if [ -d "$PROJECT_PI/$local_dir" ]; then
      local_count=$(find "$PROJECT_PI/$local_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    fi

    echo "$type_name:"
    echo "  Library: $lib_count | Local: $local_count"

    # Find missing locally
    if [ -d "$LIBRARY_CENTRAL/$lib_dir" ]; then
      for item in "$LIBRARY_CENTRAL/$lib_dir"/*; do
        if [ ! -e "$item" ]; then
          continue
        fi
        item_name=$(basename "$item")
        if [ ! -e "$PROJECT_PI/$local_dir/$item_name" ]; then
          echo "  → $item_name (in library, not local)"
        fi
      done
    fi

    # Find local-only
    if [ -d "$PROJECT_PI/$local_dir" ]; then
      for item in "$PROJECT_PI/$local_dir"/*; do
        if [ ! -e "$item" ]; then
          continue
        fi
        item_name=$(basename "$item")
        if [ ! -e "$LIBRARY_CENTRAL/$lib_dir/$item_name" ]; then
          echo "  → $item_name (local only - consider pushing)"
        fi
      done
    fi

    echo ""
  }

  check_type "Skills" "skills" "skills"
  check_type "Agents" "agents" "agents"
  check_type "Prompts" "prompts" "prompts"
  check_type "Learnings" "learnings/patterns" "learnings/patterns"
  check_type "Workflows" "workflows" "workflows"
  check_type "Extensions" "extensions" "extensions"
  check_type "MCP Configs" "mcp-configs" "mcp-configs"

  echo "Run '$0 sync' to pull missing artifacts."
  echo "Run '$0 push <type:name>' to share local artifacts."
}

# Search for artifacts
cmd_search() {
  check_library_exists

  local query=$1

  if [ -z "$query" ]; then
    error "Usage: $0 search <query>

Example: $0 search convex"
  fi

  echo "🔍 Searching library-central for: $query"
  echo ""

  local found=0

  # Search in each artifact type
  search_in() {
    local type=$1
    local dir=$2
    local matches=()

    if [ ! -d "$LIBRARY_CENTRAL/$dir" ]; then
      return
    fi

    for item in "$LIBRARY_CENTRAL/$dir"/*; do
      if [ ! -e "$item" ]; then
        continue
      fi

      item_name=$(basename "$item")

      # Check if name matches
      if echo "$item_name" | grep -qi "$query"; then
        matches+=("$item_name")
      elif [ -f "$item" ] && grep -qi "$query" "$item" 2>/dev/null; then
        matches+=("$item_name")
      fi
    done

    if [ ${#matches[@]} -gt 0 ]; then
      echo "$type (${#matches[@]} matches):"
      for match in "${matches[@]}"; do
        local in_local=""
        if [ -e "$PROJECT_PI/$dir/$match" ]; then
          in_local=" ${GREEN}✓ in local${NC}"
        else
          in_local=" (NOT in local - run '$0 sync')"
        fi
        echo -e "  → $match$in_local"
      done
      echo ""
      ((found += ${#matches[@]}))
    fi
  }

  search_in "Skills" "skills"
  search_in "Agents" "agents"
  search_in "Prompts" "prompts"
  search_in "Learnings" "learnings/patterns"
  search_in "Workflows" "workflows"
  search_in "Extensions" "extensions"
  search_in "MCP Configs" "mcp-configs"

  if [ $found -eq 0 ]; then
    warning "No matches found for: $query"
  else
    success "Found $found matches"
  fi
}

# Bootstrap library from repositories
cmd_bootstrap() {
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local bootstrap_script="$script_dir/bootstrap-library.sh"

  if [ ! -f "$bootstrap_script" ]; then
    error "Bootstrap script not found: $bootstrap_script

Please ensure bootstrap-library.sh exists in the same directory as library-manager.sh"
  fi

  echo "📦 Bootstrapping library from repositories..."
  echo ""

  # Execute bootstrap script
  bash "$bootstrap_script" "$@"

  local exit_code=$?

  if [ $exit_code -eq 0 ]; then
    echo ""
    success "Bootstrap complete!"
    echo ""
    echo "Next: Run '$0 sync' in your projects to pull these artifacts."
  else
    error "Bootstrap failed with exit code: $exit_code"
  fi
}

# Main command dispatcher
main() {
  local command=${1:-help}
  shift || true

  case $command in
    init)
      cmd_init "$@"
      ;;
    bootstrap)
      cmd_bootstrap "$@"
      ;;
    sync)
      cmd_sync "$@"
      ;;
    push)
      cmd_push "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    search)
      cmd_search "$@"
      ;;
    help|--help|-h)
      cat <<EOF
Library Manager - Bidirectional sync between library-central and projects

Usage: $0 <command> [args]

Commands:
  init                Initialize library-central (empty)
  bootstrap           Bootstrap library from your repositories
  sync [type]         Pull artifacts from library-central to project
  push <type:name>    Push artifact from project to library-central
  status              Compare library-central vs project
  search <query>      Search for artifacts in library-central
  help                Show this help message

Examples:
  # First time setup
  $0 bootstrap            # Clone repos and populate library-central

  # Per-project usage
  $0 sync                 # Pull all artifacts to current project
  $0 sync skills          # Pull only skills
  $0 push skill:my-skill  # Share your skill with other projects
  $0 push pattern:my-pattern

  # Management
  $0 status               # Compare library vs local
  $0 search convex        # Find artifacts

Environment:
  PI_LIBRARY_CENTRAL    Path to library-central (default: ~/.pi/library-central)

For detailed guides, see: .pi/skills/library/cookbook/
EOF
      ;;
    *)
      error "Unknown command: $command

Run '$0 help' for usage."
      ;;
  esac
}

main "$@"
