#!/usr/bin/env bash
# build-skill-index.sh — Scan .pi/skills/*/SKILL.md and emit .pi/skills/index.json
#
# The index is a flat array of { name, description, triggers, path } records
# extracted from each skill's YAML frontmatter. It's the source of truth for
# lazy skill retrieval — the skill-loader extension reads this file at startup
# and uses it for matching, never loading full SKILL.md bodies until requested.
#
# Run from repo root: ./scripts/build-skill-index.sh
# Or via pre-commit: included automatically.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/.pi/skills"
INDEX_FILE="$SKILLS_DIR/index.json"

if [ ! -d "$SKILLS_DIR" ]; then
  echo "No .pi/skills/ directory at $SKILLS_DIR" >&2
  exit 1
fi

python3 - "$SKILLS_DIR" "$INDEX_FILE" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

skills_dir = Path(sys.argv[1])
index_file = Path(sys.argv[2])

def parse_frontmatter(text):
    """Extract YAML frontmatter. Handles: simple scalars, lists, and folded scalars (> / >-)."""
    m = re.match(r"^---\s*\n(.*?)\n---\s*(?:\n|$)", text, re.DOTALL)
    if not m:
        return {}
    lines = m.group(1).split("\n")
    out = {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m2 = re.match(r"^(\w[\w_-]*)\s*:\s*(.*)$", line)
        if not m2:
            i += 1
            continue
        key, raw = m2.group(1), m2.group(2).strip()
        if raw.startswith(">"):
            # Folded scalar — join indented continuation lines with spaces
            parts = []
            i += 1
            while i < len(lines):
                cont = lines[i]
                if cont.startswith(" ") or cont.startswith("\t"):
                    parts.append(cont.strip())
                    i += 1
                else:
                    break
            out[key] = " ".join(parts).strip()
            continue
        if raw == "":
            # List follows on indented lines starting with "- "
            items = []
            i += 1
            while i < len(lines):
                cont = lines[i]
                if cont.lstrip().startswith("- ") and (cont.startswith(" ") or cont.startswith("\t")):
                    items.append(cont.lstrip()[2:].strip().strip('"').strip("'"))
                    i += 1
                elif cont.strip() == "":
                    i += 1
                else:
                    break
            out[key] = items
            continue
        out[key] = raw.strip('"').strip("'")
        i += 1
    return out

records = []
for skill_path in sorted(skills_dir.glob("*/SKILL.md")):
    text = skill_path.read_text(encoding="utf-8", errors="replace")
    fm = parse_frontmatter(text)
    name = fm.get("name") or skill_path.parent.name
    description = fm.get("description", "").strip()
    triggers = fm.get("triggers", [])
    if isinstance(triggers, str):
        triggers = [triggers]
    records.append({
        "name": name,
        "description": description,
        "triggers": triggers,
        "path": str(skill_path.relative_to(skills_dir.parent.parent)),
    })

index_file.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
print(f"Indexed {len(records)} skills → {index_file.relative_to(Path.cwd())}")
PY
