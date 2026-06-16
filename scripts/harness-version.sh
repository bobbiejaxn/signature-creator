#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# Harness Versioning — Snapshot, rollback, compare, and export harness configs
# ──────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/harness-version.sh snapshot [label]   # Save current harness state
#   ./scripts/harness-version.sh rollback            # Revert to previous version
#   ./scripts/harness-version.sh list                # List all versions
#   ./scripts/harness-version.sh compare v1 v2       # Diff two versions
#   ./scripts/harness-version.sh export [version]    # Export for setup.sh --config
#   ./scripts/harness-version.sh current             # Show current version

set -euo pipefail

VERSIONS_DIR=".pi/harness-versions"
mkdir -p "$VERSIONS_DIR"

# Get next version number
next_version() {
  local max=0
  for f in "$VERSIONS_DIR"/v*.json; do
    [ -f "$f" ] || continue
    num=$(basename "$f" .json | sed 's/v//')
    [ "$num" -gt "$max" ] 2>/dev/null && max=$num
  done
  echo $((max + 1))
}

# Capture current harness state as JSON
capture_state() {
  python3 -c "
import json, os, glob

state = {'agents': {}, 'skills': [], 'config': {}, 'scripts': []}

# Capture agent configs (model, skills from frontmatter)
for agent_file in sorted(glob.glob('.pi/agents/*.md')):
    name = os.path.basename(agent_file).replace('.md', '')
    with open(agent_file) as f:
        content = f.read()
    # Extract YAML frontmatter
    if content.startswith('---'):
        end = content.index('---', 3)
        fm = content[3:end]
        model = ''
        for line in fm.split('\n'):
            if line.strip().startswith('model:'):
                model = line.split(':', 1)[1].strip()
        state['agents'][name] = {'model': model, 'file': agent_file, 'size': len(content)}

# Capture skills
for skill_dir in sorted(glob.glob('.pi/skills/*/SKILL.md')):
    skill_name = os.path.basename(os.path.dirname(skill_dir))
    with open(skill_dir) as f:
        size = len(f.read())
    state['skills'].append({'name': skill_name, 'file': skill_dir, 'size': size})

# Capture key scripts
for script in sorted(glob.glob('scripts/*.sh')):
    name = os.path.basename(script)
    with open(script) as f:
        size = len(f.read())
    state['scripts'].append({'name': name, 'size': size})

# Capture config.sh key values
if os.path.exists('.pi/config.sh'):
    with open('.pi/config.sh') as f:
        for line in f:
            line = line.strip()
            if '=' in line and not line.startswith('#'):
                key, _, val = line.partition('=')
                key = key.strip()
                val = val.strip().strip('\"')
                if key in ['PROJECT_NAME', 'REPO', 'TEST_RUNNER', 'DEV_COMMAND']:
                    state['config'][key] = val

print(json.dumps(state, indent=2))
" 2>/dev/null
}

case "${1:-current}" in
  snapshot)
    LABEL="${2:-}"
    VERSION=$(next_version)
    VERSION_FILE="$VERSIONS_DIR/v${VERSION}.json"
    
    # Capture state to temp file, then add metadata
    TMPFILE=$(mktemp)
    capture_state > "$TMPFILE"
    
    python3 -c "
import json, sys
state = json.load(open('$TMPFILE'))
state['version'] = $VERSION
state['created'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
state['label'] = '$LABEL'
state['agent_count'] = len(state.get('agents', {}))
state['skill_count'] = len(state.get('skills', []))
json.dump(state, open('$VERSION_FILE', 'w'), indent=2)
"
    rm -f "$TMPFILE"
    
    # Update current
    rm -f "$VERSIONS_DIR/current"
    echo "$VERSION" > "$VERSIONS_DIR/current"
    
    echo "✓ Harness snapshot saved: v$VERSION"
    [ -n "$LABEL" ] && echo "  Label: $LABEL"
    python3 -c "
import json
d = json.load(open('$VERSION_FILE'))
print(f'  Agents: {d.get(\"agent_count\",\"?\")}')
print(f'  Skills: {d.get(\"skill_count\",\"?\")}')
" 2>/dev/null
    ;;

  rollback)
    CURRENT_VERSION=$(cat "$VERSIONS_DIR/current" 2>/dev/null || echo "0")
    if [ "$CURRENT_VERSION" -le 1 ] 2>/dev/null; then
      echo "Cannot rollback — already at v1 or no versions exist."
      exit 1
    fi
    
    PREV=$((CURRENT_VERSION - 1))
    PREV_FILE="$VERSIONS_DIR/v${PREV}.json"
    
    if [ ! -f "$PREV_FILE" ]; then
      echo "Previous version v$PREV not found."
      exit 1
    fi
    
    echo "Rolling back from v$CURRENT_VERSION to v$PREV..."
    echo "⚠ This restores the harness state from v$PREV."
    echo "  Note: Only metadata is tracked. To fully restore, use git:"
    echo "    git diff HEAD~1 -- .pi/agents/ .pi/skills/ scripts/"
    echo "    git checkout HEAD~1 -- .pi/agents/ .pi/skills/"
    
    echo "$PREV" > "$VERSIONS_DIR/current"
    echo "✓ Current version set to v$PREV"
    ;;

  list)
    echo "Harness versions:"
    CURRENT=$(cat "$VERSIONS_DIR/current" 2>/dev/null || echo "0")
    for f in "$VERSIONS_DIR"/v*.json; do
      [ -f "$f" ] || continue
      VERSION=$(basename "$f" .json)
      NUM=$(echo "$VERSION" | sed 's/v//')
      MARKER=""
      [ "$NUM" = "$CURRENT" ] && MARKER=" ← current"
      
      CREATED=$(python3 -c "import json; print(json.load(open('$f')).get('created','?'))" 2>/dev/null)
      LABEL=$(python3 -c "import json; l=json.load(open('$f')).get('label',''); print(f' ({l})' if l else '')" 2>/dev/null)
      AGENTS=$(python3 -c "import json; print(json.load(open('$f')).get('agent_count','?'))" 2>/dev/null)
      SKILLS=$(python3 -c "import json; print(json.load(open('$f')).get('skill_count','?'))" 2>/dev/null)
      
      echo "  $VERSION  $CREATED  ${AGENTS}a/${SKILLS}s${LABEL}${MARKER}"
    done
    ;;

  compare)
    V1="${2:-}"
    V2="${3:-}"
    if [ -z "$V1" ] || [ -z "$V2" ]; then
      echo "Usage: ./scripts/harness-version.sh compare v1 v2"
      exit 1
    fi
    F1="$VERSIONS_DIR/${V1}.json"
    F2="$VERSIONS_DIR/${V2}.json"
    if [ ! -f "$F1" ] || [ ! -f "$F2" ]; then
      echo "Version file not found. Check: $F1 $F2"
      exit 1
    fi
    
    python3 -c "
import json

a = json.load(open('$F1'))
b = json.load(open('$F2'))

print(f'Comparing $V1 → $V2')
print()

# Agent changes
a_agents = set(a.get('agents', {}).keys())
b_agents = set(b.get('agents', {}).keys())
added = b_agents - a_agents
removed = a_agents - b_agents
if added: print(f'  Agents added: {added}')
if removed: print(f'  Agents removed: {removed}')

# Model changes
for name in a_agents & b_agents:
    ma = a['agents'][name].get('model', '')
    mb = b['agents'][name].get('model', '')
    if ma != mb:
        print(f'  {name}: model {ma} → {mb}')

# Skill changes
a_skills = set(s['name'] for s in a.get('skills', []))
b_skills = set(s['name'] for s in b.get('skills', []))
s_added = b_skills - a_skills
s_removed = a_skills - b_skills
if s_added: print(f'  Skills added: {s_added}')
if s_removed: print(f'  Skills removed: {s_removed}')

# Size changes
for name in a_agents & b_agents:
    sa = a['agents'][name].get('size', 0)
    sb = b['agents'][name].get('size', 0)
    diff = sb - sa
    if abs(diff) > 50:
        print(f'  {name}: prompt size {sa} → {sb} ({diff:+d} chars)')

print()
print(f'  $V1: {a.get(\"agent_count\",\"?\")} agents, {a.get(\"skill_count\",\"?\")} skills')
print(f'  $V2: {b.get(\"agent_count\",\"?\")} agents, {b.get(\"skill_count\",\"?\")} skills')
"
    ;;

  export)
    VERSION="${2:-}"
    if [ -z "$VERSION" ]; then
      VERSION="v$(cat "$VERSIONS_DIR/current" 2>/dev/null || echo "1")"
    fi
    FILE="$VERSIONS_DIR/${VERSION}.json"
    if [ ! -f "$FILE" ]; then
      echo "Version $VERSION not found."
      exit 1
    fi
    cat "$FILE"
    ;;

  current)
    CURRENT=$(cat "$VERSIONS_DIR/current" 2>/dev/null || echo "none")
    if [ "$CURRENT" = "none" ]; then
      echo "No harness version tracked yet. Run: ./scripts/harness-version.sh snapshot"
    else
      echo "Current harness: v$CURRENT"
      FILE="$VERSIONS_DIR/v${CURRENT}.json"
      if [ -f "$FILE" ]; then
        python3 -c "
import json
d = json.load(open('$FILE'))
print(f'  Created: {d.get(\"created\",\"?\")}')
label = d.get('label', '')
if label: print(f'  Label: {label}')
print(f'  Agents: {d.get(\"agent_count\",\"?\")}')
print(f'  Skills: {d.get(\"skill_count\",\"?\")}')
"
      fi
    fi
    ;;

  *)
    echo "Usage: ./scripts/harness-version.sh {snapshot|rollback|list|compare|export|current}"
    ;;
esac
