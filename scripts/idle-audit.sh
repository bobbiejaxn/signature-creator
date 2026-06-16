#!/usr/bin/env bash
# idle-audit.sh — Identify agents and skills that haven't been used recently.
#
# Reads the trace corpus at .pi/traces/runs/* and cross-references against the
# currently installed agents and skills. Emits:
#
#   .pi/traces/analysis/idle-report.json   — machine-readable audit
#   .pi/traces/analysis/idle-report.md     — human review summary
#
# Idle classification (last N days, default 30):
#   ACTIVE      — used at least once in the window
#   DORMANT     — used historically but not in the window
#   NEVER_USED  — installed but no trace record
#
# Usage:
#   ./scripts/idle-audit.sh                # default: last 30 days
#   ./scripts/idle-audit.sh --days 90      # last 90 days
#   ./scripts/idle-audit.sh --all-time     # all trace history
#
# The harness-evolver can consume idle-report.json to write pruning proposals.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DAYS=30
ALL_TIME=false
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --all-time) ALL_TIME=true; shift ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

TRACES_DIR=".pi/traces"
ANALYSIS_DIR="$TRACES_DIR/analysis"
mkdir -p "$ANALYSIS_DIR"

JSON_OUT="$ANALYSIS_DIR/idle-report.json"
MD_OUT="$ANALYSIS_DIR/idle-report.md"

python3 - "$REPO_ROOT" "$DAYS" "$ALL_TIME" "$JSON_OUT" "$MD_OUT" <<'PY'
import json
import os
import re
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

repo_root = Path(sys.argv[1])
days_window = int(sys.argv[2])
all_time = sys.argv[3] == "true"
json_out = Path(sys.argv[4])
md_out = Path(sys.argv[5])

agents_dir = repo_root / ".pi/agents"
skills_dir = repo_root / ".pi/skills"
traces_dir = repo_root / ".pi/traces/runs"

# ── Discover installed surface ───────────────────────────────────────
installed_agents = set()
for p in agents_dir.glob("*.md"):
    installed_agents.add(p.stem)
for p in (agents_dir / "board").glob("*.md") if (agents_dir / "board").exists() else []:
    installed_agents.add(p.stem)

installed_skills = set()
for p in skills_dir.glob("*/SKILL.md"):
    installed_skills.add(p.parent.name)

# ── Walk traces ──────────────────────────────────────────────────────
now = datetime.now(timezone.utc)
cutoff = now - timedelta(days=days_window) if not all_time else None

agent_usage = {}  # name -> { count, last_seen, runs }
skill_usage = {}  # name -> { count, last_seen, runs }

def touch(d, key, when, run_id):
    rec = d.setdefault(key, {"count": 0, "last_seen": None, "runs": set()})
    rec["count"] += 1
    rec["runs"].add(run_id)
    if rec["last_seen"] is None or when > rec["last_seen"]:
        rec["last_seen"] = when

if traces_dir.exists():
    for run_dir in sorted(traces_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        run_id = run_dir.name
        # Try to get a run timestamp from manifest or directory name
        manifest = run_dir / "manifest.json"
        run_time = None
        if manifest.exists():
            try:
                data = json.load(manifest.open())
                if isinstance(data, list) and data:
                    started = data[0].get("started")
                    if started:
                        run_time = datetime.fromisoformat(started.replace("Z", "+00:00"))
            except Exception:
                pass
        if run_time is None:
            m = re.match(r"run-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})", run_id)
            if m:
                try:
                    run_time = datetime.strptime(m.group(1), "%Y-%m-%dT%H-%M-%S").replace(tzinfo=timezone.utc)
                except Exception:
                    pass
        if run_time is None:
            run_time = datetime.fromtimestamp(run_dir.stat().st_mtime, tz=timezone.utc)

        if cutoff is not None and run_time < cutoff:
            continue

        # Agents fired in this run: derived from per-agent JSONL files
        for jsonl in run_dir.glob("*.jsonl"):
            agent_name = jsonl.stem
            touch(agent_usage, agent_name, run_time, run_id)

            # Skills referenced inside the agent's trace (best-effort grep on tool input/output text)
            try:
                with jsonl.open(encoding="utf-8", errors="replace") as f:
                    for line in f:
                        for skill_name in installed_skills:
                            # Loose match: skill name with word boundaries or quoted
                            if f'"{skill_name}"' in line or f"'{skill_name}'" in line or f"/{skill_name}/" in line or f"skill_load" in line and skill_name in line:
                                touch(skill_usage, skill_name, run_time, run_id)
            except Exception:
                pass

# ── Classify ─────────────────────────────────────────────────────────
def classify(installed, usage):
    out = []
    for name in sorted(installed):
        if name in usage:
            u = usage[name]
            out.append({
                "name": name,
                "status": "ACTIVE",
                "count": u["count"],
                "last_seen": u["last_seen"].isoformat() if u["last_seen"] else None,
                "runs": len(u["runs"]),
            })
        else:
            out.append({
                "name": name,
                "status": "NEVER_USED" if not any(name in u.get("runs", set()) for u in usage.values()) else "DORMANT",
                "count": 0,
                "last_seen": None,
                "runs": 0,
            })
    return out

agents = classify(installed_agents, agent_usage)
skills = classify(installed_skills, skill_usage)

active_agents = [a for a in agents if a["status"] == "ACTIVE"]
idle_agents = [a for a in agents if a["status"] != "ACTIVE"]
active_skills = [s for s in skills if s["status"] == "ACTIVE"]
idle_skills = [s for s in skills if s["status"] != "ACTIVE"]

report = {
    "generated_at": now.isoformat(),
    "window_days": "all-time" if all_time else days_window,
    "totals": {
        "installed_agents": len(installed_agents),
        "active_agents": len(active_agents),
        "idle_agents": len(idle_agents),
        "installed_skills": len(installed_skills),
        "active_skills": len(active_skills),
        "idle_skills": len(idle_skills),
    },
    "agents": agents,
    "skills": skills,
}

json_out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

# ── Markdown summary ─────────────────────────────────────────────────
md = []
window_label = "all time" if all_time else f"last {days_window} days"
md.append(f"# Idle Audit — {window_label}\n")
md.append(f"Generated: {now.isoformat()}\n")
md.append("## Totals\n")
md.append(f"- Installed agents: {len(installed_agents)} (active: {len(active_agents)}, idle: {len(idle_agents)})")
md.append(f"- Installed skills: {len(installed_skills)} (active: {len(active_skills)}, idle: {len(idle_skills)})\n")

md.append("## Active agents\n")
if active_agents:
    for a in sorted(active_agents, key=lambda x: -x["count"]):
        md.append(f"- **{a['name']}** — {a['count']} calls across {a['runs']} runs (last: {a['last_seen']})")
else:
    md.append("_None._")
md.append("")

md.append("## Idle agents (candidates for pruning)\n")
if idle_agents:
    for a in idle_agents:
        md.append(f"- {a['name']} — {a['status']}")
else:
    md.append("_None._")
md.append("")

md.append("## Active skills\n")
if active_skills:
    for s in sorted(active_skills, key=lambda x: -x["count"])[:30]:
        md.append(f"- **{s['name']}** — {s['count']} mentions across {s['runs']} runs")
    if len(active_skills) > 30:
        md.append(f"_(+{len(active_skills) - 30} more)_")
else:
    md.append("_None — skill usage is not yet tracked in traces._")
md.append("")

md.append("## Idle skills (candidates for pruning)\n")
md.append(f"_{len(idle_skills)} skills with no observed usage in window. See idle-report.json for full list._")
if idle_skills[:20]:
    md.append("")
    md.append("Sample:")
    for s in idle_skills[:20]:
        md.append(f"- {s['name']}")
md.append("")

md.append("## Next step\n")
md.append("Review the lists above. To prune an idle item:")
md.append("1. Confirm it's truly unused (skill mentions may not appear in traces yet — the skill-loader extension will improve this)")
md.append("2. Move to `.pi/.archived/` or delete from `.pi/agents/` / `.pi/skills/`")
md.append("3. Run `./scripts/build-skill-index.sh` to refresh the index")
md.append("4. Commit with rationale\n")

md_out.write_text("\n".join(md), encoding="utf-8")

print(f"Idle audit complete:")
print(f"  Window:  {window_label}")
print(f"  Agents:  {len(active_agents)} active / {len(idle_agents)} idle of {len(installed_agents)} installed")
print(f"  Skills:  {len(active_skills)} active / {len(idle_skills)} idle of {len(installed_skills)} installed")
print(f"  JSON:    {json_out}")
print(f"  Markdown: {md_out}")
PY
