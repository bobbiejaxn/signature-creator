#!/bin/bash
set -e

# Configuration
LIBRARY_CENTRAL="${PI_LIBRARY_CENTRAL:-$HOME/.pi/library-central}"
BOOTSTRAP_DIR="$HOME/.pi/bootstrap-temp"
REPOS=(
  "https://github.com/bobbiejaxn/convex-agent-skillz"
  "https://github.com/bobbiejaxn/claude-seo"
  "https://github.com/bobbiejaxn/everything-claude-code"
  "https://github.com/shipkitai/adk-agent-saas"
  "https://github.com/bobbiejaxn/tac-5-nl-sql-interface"
  "https://github.com/bobbiejaxn/ecommerce-subagent-template"
)

echo "🔄 Bootstrapping Pi Launchpad Library"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Initialize library if not exists
if [ ! -d "$LIBRARY_CENTRAL" ]; then
  echo "📦 Initializing library-central..."
  mkdir -p "$LIBRARY_CENTRAL"
  cd "$LIBRARY_CENTRAL"
  git init

  # Create structure
  mkdir -p skills agents prompts workflows mcp-configs extensions learnings/patterns

  # Create initial catalog
  cat > catalog.yaml <<'CATALOG'
metadata:
  owner: $(whoami)
  created: $(date -I)
  version: 1.0.0
  description: "Bootstrapped from existing repositories"

artifact_types:
  skills: skills/
  agents: agents/
  prompts: prompts/
  workflows: workflows/
  mcp_configs: mcp-configs/
  extensions: extensions/
  learnings: learnings/

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
CATALOG

  git add -A
  git commit -m "chore: initialize library structure"
  echo "✓ Library initialized"
  echo ""
fi

# 2. Clone repositories (sparse checkout for efficiency)
echo "📥 Cloning repositories (sparse checkout - .pi/ only)..."
mkdir -p "$BOOTSTRAP_DIR"
cd "$BOOTSTRAP_DIR"

CLONED=0
for repo in "${REPOS[@]}"; do
  repo_name=$(basename "$repo" .git)

  if [ -d "$repo_name" ]; then
    echo "  ⚠️  $repo_name already exists, pulling..."
    cd "$repo_name"
    git pull -q 2>/dev/null || echo "  ⚠️  Failed to pull $repo_name"
    cd ..
  else
    echo "  → Cloning $repo_name (sparse: .pi + .cursor only)..."

    # Use sparse checkout to only get .pi/ and .cursor/ directories
    # This saves bandwidth and disk space by not downloading full repo
    git clone --depth=1 --filter=blob:none --sparse -q "$repo" 2>/dev/null || {
      echo "  ⚠️  Sparse clone failed, trying full shallow clone..."
      git clone --depth=1 -q "$repo" 2>/dev/null || {
        echo "  ⚠️  Failed to clone $repo_name (may be private)"
        continue
      }
    }

    # If sparse clone succeeded, configure sparse checkout
    if [ -d "$repo_name/.git" ]; then
      cd "$repo_name"
      if git sparse-checkout list >/dev/null 2>&1; then
        git sparse-checkout init --cone 2>/dev/null
        # Only checkout .pi/ (proven to exist in all repos)
        # Note: .cursor/ support exists for future repos, but none currently have it
        git sparse-checkout set .pi 2>/dev/null || {
          # If sparse-checkout fails, we have a shallow clone which is still better than full
          echo "  → Using shallow clone (sparse-checkout not supported)"
        }
      fi
      cd ..
    fi
  fi

  if [ -d "$repo_name" ]; then
    ((CLONED++))
  fi
done

echo "✓ Cloned/updated $CLONED repositories"
echo ""

# Show space savings
if command -v du >/dev/null 2>&1; then
  total_size=$(du -sh "$BOOTSTRAP_DIR" 2>/dev/null | awk '{print $1}')
  echo "📊 Bootstrap size: $total_size (sparse checkout saved bandwidth)"
  echo ""
fi

# 3. Extract artifacts by type
echo "🔍 Discovering artifacts..."
echo ""

TOTAL_SKILLS=0
TOTAL_AGENTS=0
TOTAL_LEARNINGS=0
TOTAL_PROMPTS=0
TOTAL_MCP=0
TOTAL_EXTENSIONS=0

# Skills
echo "📚 Skills:"
for repo_dir in */; do
  repo_name=${repo_dir%/}
  if [ -d "$repo_dir/.pi/skills" ]; then
    for skill_dir in "$repo_dir/.pi/skills"/*/; do
      if [ -f "$skill_dir/SKILL.md" ]; then
        skill_name=$(basename "$skill_dir")
        echo "  → $skill_name (from $repo_name)"

        # Copy to library
        mkdir -p "$LIBRARY_CENTRAL/skills/$skill_name"
        cp -r "$skill_dir"/* "$LIBRARY_CENTRAL/skills/$skill_name/" 2>/dev/null || true
        ((TOTAL_SKILLS++))
      fi
    done
  fi
done
echo "  Found: $TOTAL_SKILLS skills"
echo ""

# Agents
echo "🤖 Agents:"
for repo_dir in */; do
  repo_name=${repo_dir%/}
  if [ -d "$repo_dir/.pi/agents" ]; then
    for agent_file in "$repo_dir/.pi/agents"/*.md; do
      if [ -f "$agent_file" ]; then
        agent_name=$(basename "$agent_file" .md)
        echo "  → $agent_name (from $repo_name)"

        # Copy to library
        cp "$agent_file" "$LIBRARY_CENTRAL/agents/" 2>/dev/null || true
        ((TOTAL_AGENTS++))
      fi
    done
  fi
done
echo "  Found: $TOTAL_AGENTS agents"
echo ""

# Prompts
echo "📝 Prompts:"
for repo_dir in */; do
  repo_name=${repo_dir%/}
  if [ -d "$repo_dir/.pi/prompts" ]; then
    for prompt_file in "$repo_dir/.pi/prompts"/*.md; do
      if [ -f "$prompt_file" ]; then
        prompt_name=$(basename "$prompt_file" .md)
        echo "  → $prompt_name (from $repo_name)"

        # Copy to library
        cp "$prompt_file" "$LIBRARY_CENTRAL/prompts/" 2>/dev/null || true
        ((TOTAL_PROMPTS++))
      fi
    done
  fi
done
echo "  Found: $TOTAL_PROMPTS prompts"
echo ""

# Learnings
echo "🧠 Learnings:"
for repo_dir in */; do
  repo_name=${repo_dir%/}
  if [ -d "$repo_dir/.pi/learnings/patterns" ]; then
    for pattern_file in "$repo_dir/.pi/learnings/patterns"/*.md; do
      if [ -f "$pattern_file" ]; then
        pattern_name=$(basename "$pattern_file" .md)
        echo "  → $pattern_name (from $repo_name)"

        # Copy to library
        cp "$pattern_file" "$LIBRARY_CENTRAL/learnings/patterns/" 2>/dev/null || true
        ((TOTAL_LEARNINGS++))
      fi
    done
  fi
done
echo "  Found: $TOTAL_LEARNINGS patterns"
echo ""

# MCP Configs
echo "🔌 MCP Configs:"
for repo_dir in */; do
  repo_name=${repo_dir%/}
  if [ -f "$repo_dir/.pi/mcp.json" ]; then
    echo "  → mcp.json (from $repo_name)"

    # Copy to library with repo name
    cp "$repo_dir/.pi/mcp.json" "$LIBRARY_CENTRAL/mcp-configs/$repo_name-mcp.json" 2>/dev/null || true
    ((TOTAL_MCP++))
  fi
done
echo "  Found: $TOTAL_MCP MCP configs"
echo ""

# Extensions
echo "🔧 Extensions:"
for repo_dir in */; do
  repo_name=${repo_dir%/}
  if [ -d "$repo_dir/.pi/extensions" ]; then
    for ext_dir in "$repo_dir/.pi/extensions"/*/; do
      if [ -d "$ext_dir" ]; then
        ext_name=$(basename "$ext_dir")
        echo "  → $ext_name (from $repo_name)"

        # Copy to library
        mkdir -p "$LIBRARY_CENTRAL/extensions/$ext_name"
        cp -r "$ext_dir"/* "$LIBRARY_CENTRAL/extensions/$ext_name/" 2>/dev/null || true
        ((TOTAL_EXTENSIONS++))
      fi
    done
  fi
done
echo "  Found: $TOTAL_EXTENSIONS extensions"
echo ""


# 4. Update catalog
echo "📊 Updating catalog..."
cd "$LIBRARY_CENTRAL"

cat > catalog.yaml <<CATALOG
metadata:
  owner: $(whoami)
  created: $(date -I)
  last_updated: $(date -I)
  version: 1.0.0
  description: "Bootstrapped from existing repositories"
  source_repos:
    - convex-agent-skillz
    - claude-seo
    - everything-claude-code
    - adk-agent-saas
    - tac-5-nl-sql-interface
    - ecommerce-subagent-template

artifact_types:
  skills: skills/
  agents: agents/
  prompts: prompts/
  workflows: workflows/
  mcp_configs: mcp-configs/
  extensions: extensions/
  learnings: learnings/

# TODO: Populate with actual artifact metadata
skills: []
agents: []
prompts: []
workflows: []
mcp_configs: []
extensions: []
learnings: []

dependencies: {}

stats:
  total_skills: $TOTAL_SKILLS
  total_agents: $TOTAL_AGENTS
  total_prompts: $TOTAL_PROMPTS
  total_workflows: 0
  total_mcp_configs: $TOTAL_MCP
  total_extensions: $TOTAL_EXTENSIONS
  total_learnings: $TOTAL_LEARNINGS
  last_sync: $(date -I)
  bootstrap_date: $(date -I)
CATALOG

echo "✓ Catalog updated"
echo ""

# 5. Commit to library
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "feat: bootstrap library from existing repositories

Imported artifacts:
- Skills: $TOTAL_SKILLS
- Agents: $TOTAL_AGENTS
- Prompts: $TOTAL_PROMPTS
- MCP Configs: $TOTAL_MCP
- Extensions: $TOTAL_EXTENSIONS
- Learnings: $TOTAL_LEARNINGS

Sources:
- convex-agent-skillz
- claude-seo
- everything-claude-code
- adk-agent-saas
- tac-5-nl-sql-interface
- ecommerce-subagent-template
" || echo "⚠️  Nothing to commit"

  echo "✓ Changes committed"
else
  echo "✓ No changes to commit"
fi
echo ""

# 6. Summary
echo "✅ Bootstrap Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Library location: $LIBRARY_CENTRAL"
echo ""
echo "Imported artifacts:"
echo "  Skills:        $TOTAL_SKILLS"
echo "  Agents:        $TOTAL_AGENTS"
echo "  Prompts:       $TOTAL_PROMPTS"
echo "  MCP Configs:   $TOTAL_MCP"
echo "  Extensions:    $TOTAL_EXTENSIONS"
echo "  Learnings:     $TOTAL_LEARNINGS"
echo ""
echo "Next steps:"
echo ""
echo "  1. Review artifacts:"
echo "     cd $LIBRARY_CENTRAL && ls -la skills/ agents/ learnings/patterns/"
echo ""
echo "  2. Sync to current project:"
echo "     cd $(pwd) && /library sync"
echo ""
echo "  3. Start using orchestrator:"
echo "     /orchestrator run \"Show available skills\""
echo ""
echo "Optional cleanup:"
echo "  rm -rf $BOOTSTRAP_DIR"
echo ""
