# Pi Launchpad

Autonomous agent orchestration layer for any software project. Drop it into your repo and get **62 specialist AI agents** that plan, build, review, and ship verified features end-to-end.

## What You Get

- **CEO agent** — autonomous PLAN→DELEGATE→REVIEW→VERIFY loop for high-level goals
- **Dynamic CEO** — strategic layer that audits assets, sets OKRs, manages crons, routes tasks
- **Board deliberation** — 8 advisors with competing biases debate before committing
- **62 specialist agents** — architects, implementers, reviewers, researchers, verifiers, team leads
- **28 slash commands** — `/ship`, `/ceo`, `/deliberate`, `/verify-loop`, `/generate`, etc.
- **24 TypeScript extensions** — runtime enforcement, model routing, trace recording, domain locking, session intelligence, post-edit lint, damage control, Sentry/VPS/HTTP tools, steer, supadata
- **210 skills** — composable behaviors from code quality to Google Workspace to ad management
- **50 enforcement and automation scripts** — cron, ship, deploy, cost tracking, morning reports, acceptance tests

### Autonomy Stack

The core loop that ships code without human review:

- **Worktree isolation** — parallel agents get isolated git worktrees, no file clobbering
- **Auto-merge on CI** — agent PRs labeled `agent-generated` merge automatically when tests pass
- **Serial dispatch** — complex features decompose into ordered tasks, each gated on PR merge
- **Enforced delegation** — lead agents are structurally read-only, must delegate to builders
- **Agent restart on crash** — transient failures (timeout, rate limit) retried with exponential backoff
- **Per-session cost guard** — $3.00 cumulative ceiling prevents unbounded spend in parallel swarms
- **Conflict prediction** — `git merge-tree` dry-run before each worktree merge

### Safety & Enforcement

- **6 hard-enforcement gates** — deterministic checks no agent can bypass
- **Tool allowlist** — agents with `tools:` frontmatter are structurally restricted to declared tools only
- **Domain enforcement** — 15 agents with path-level read/write/delete restrictions
- **Zero-trust review** — cross-model review, completion auditor, adversarial testing
- **Zombie cleanup** — sweeps stale PID files, orphan steer files, and dead worktrees at session start
- **Steer mid-run** — course-correct running agents without killing them

### Visibility

- **Cost visibility** — per-run Telegram alerts + daily cost digest + budget threshold warnings
- **Morning report** — daily Telegram summary: open issues, runs, cost, stale agents, top bugs
- **Per-run manifest** — JSON summary of every parallel/single execution with cost and task outcomes
- **Session intelligence** — automatic orientation on session start, rule proposals on session end

### Cross-Project

- **Pi-to-Pi network** — agents communicate across Mac ↔ Hostinger ↔ NetCup via coms-net
- **Convex knowledge layer** — 11 tables: agents, projects, lessons, memories, patterns, runs, events, inbox
- **Tiered model routing** — right model, right machine, right price (`.pi/routing.yaml`)
- **Self-optimizing harness** — traces every call, diagnoses failures, proposes improvements

## Quick Start

```bash
./setup.sh /path/to/your/project

# Then in your project:
/prime                      # Orient on codebase
/ship "Add dark mode"       # Full delivery: spec → implement → verify → PR
/ceo Build auth with JWT    # Autonomous goal pursuit
```

See [Quick Start Guide](docs/QUICKSTART.md) for the walkthrough.

## Architecture

```
.pi/
├── agents/          62 agents (54 core + 8 board)
├── prompts/         28 slash commands
├── extensions/      24 TypeScript extensions
├── skills/          210 composable behaviors
├── convex/          Convex schema (11 tables for memory, intelligence, runs)
├── peers/           Pi-to-Pi peer definitions
├── routing.yaml     Tiered model routing across machines
├── config.sh        Project settings (single source of truth)
├── expertise/       Per-agent mental models (compound over time)
├── learnings/       Self-learning loop (patterns auto-promote at 3+ recurrences)
├── multi-team/      Team configs and multi-team agents
├── verifier/        Domain verifier scripts and prompts
└── traces/          Execution trace filesystem (powers harness evolver)

scripts/             50 enforcement and automation scripts
  acceptance/        End-to-end acceptance tests (steer, cost guard, ...)
```

## Commands

| Command | What it does |
|---------|-------------|
| `/prime` | Orient on codebase + load learnings |
| `/ship <feature>` | Full delivery — spec → implement → verify → PR |
| `/ship-fast <feature>` | Streamlined — no PM, no USVA |
| `/ceo <goal>` | Autonomous CEO loop |
| `/dynamic-ceo <goal>` | Strategic CEO — asset audit, OKRs, cron management |
| `/fix <issue>` | Fix a GitHub issue end-to-end |
| `/fix-bug <symptom>` | Fix a bug without a GitHub issue |
| `/fix-gh-issue <N>` | Fix GitHub issue with full agent pipeline |
| `/feature <feature>` | Full feature cycle: plan, TDD, review |
| `/plan <task>` | Plan before coding |
| `/tdd <task>` | Test-driven development |
| `/review` | Pre-commit review |
| `/verify` | Run verification checks |
| `/verify-loop <domain>` | 3-iteration domain verifier sidecar |
| `/generate <brand> <N>` | Brand-consistent UI generation |
| `/deliberate <question>` | Board debate with 8 competing advisors |
| `/evolve [focus]` | Harness self-optimization from traces |
| `/idea <idea>` | Capture idea as GitHub issue |
| `/research <q>` | Quick web research |
| `/deep-research <q>` | Multi-source deep analysis |
| `/office-hours <idea>` | YC-style product reframe — challenges your framing before coding |
| `/land-and-deploy <PR>` | Merge PR → CI → deploy → verify production health |
| `/retro` | Weekly retro — shipping stats, gate health, learnings |
| `/status` | Pipeline health check |
| `/opsx:propose` | OpenSpec: propose a change |
| `/opsx:explore` | OpenSpec: explore ideas |
| `/opsx:apply` | OpenSpec: implement tasks |
| `/opsx:archive` | OpenSpec: archive a change |

## Extensions

24 runtime extensions that enforce rules, capture traces, manage VPS, and continuously improve the harness.

| Extension | What it does |
|-----------|-------------|
| **subagent** | Multi-agent delegation — parallel, chain, single modes with worktree isolation, cost guard, restart, conflict prediction |
| **ceo** | Autonomous CEO loop — plan, delegate, review |
| **steer** | Mid-run course correction — inject steer messages at tool_result/turn_start, consume-once |
| **skill-loader** | Lazy skill retrieval — `skill_search` / `skill_load` instead of eager-loading all 210 SKILL.md files |
| **model-router** | Dynamic Ollama Cloud model selection and frontier sweeps |
| **session-intel** | START: injects git orientation + cleans stale agents; STOP: proposes rule/skill updates |
| **trace-recorder** | Captures every tool call, result, and cost to JSONL traces |
| **domain-enforcer** | Per-agent file access rules — read, write, delete boundaries with bash heuristics |
| **command-hygiene** | Blocks dangerous bash patterns (rm -rf, sudo, etc.) |
| **bash-whitelist** | Restricts bash to an explicit allowlist |
| **no-bash** | Read-only mode — blocks all bash execution |
| **damage-control** | Safety net for destructive operations |
| **post-edit-lint** | Lints + type-checks edited files immediately after write |
| **brave-search** | Brave Search API integration |
| **context7-tools** | Context7 documentation lookup |
| **github-tools** | GitHub issues, PRs, and repo operations |
| **http-tools** | HTTP fetch + REST tooling without bash curl |
| **obsidian-write** | Write directly to Obsidian vault |
| **supadata** | Supadata.ai REST API — video transcripts, web scrape/crawl, AI extraction |
| **sentry-tools** | Sentry issues, releases, and error monitoring API |
| **deepseek** | DeepSeek model provider routing |
| **straico** | Straico multi-model API gateway |
| **coms-net** | Pi-to-Pi network — cross-server agent communication |
| **vps-tools** | SSH-less VPS operations (file ops, service control, deploys) |

## Documentation

| Doc | Contents |
|-----|----------|
| [Agents](docs/agents.md) | Full roster — 62 agents, models, roles, tools |
| [Extensions](docs/extensions.md) | 24 runtime extensions — what they intercept and enforce |
| [CEO & Board](docs/ceo-and-board.md) | CEO loop, dynamic CEO, board deliberation |
| [Ship Pipeline](docs/ship-pipeline.md) | /ship phases, code quality enforcement, verifiers, serial dispatch |
| [Harness & Learning](docs/harness-and-learning.md) | Self-optimizing harness, mental models, learning loop |
| [Cron Automation](docs/cron-automation.md) | Overnight shipping, dynamic cron management |
| [Model Routing](docs/model-routing.md) | Multi-provider routing, frontier sweep |
| [Skills Catalog](docs/skills-catalog.md) | 210 skills by category |
| [Setup Reference](docs/setup-reference.md) | Setup, update, config reference, supported stacks |
| [Research Agents](docs/research-agents.md) | Research agent roster — what each does, when to use |
| [Agentic Access](docs/agentic-access-audit.md) | Tool allowlist and domain enforcement audit |
| [Gotchas](docs/GOTCHAS.md) | Known footguns, fixed bugs, and operational warnings |
| [Workflows](docs/workflows/README.md) | Step-by-step guides: setup, ship, fix, review, self-learning |
| [References](docs/REFERENCES.md) | External references and resources |

## Setup & Update

```bash
# First time
./setup.sh /path/to/project

# Update existing project after pi_launchpad changes
./scripts/update.sh

# Non-interactive (for agents)
./setup.sh --config setup.json --auto /path/to/project
```

See [Setup Reference](docs/setup-reference.md) for details.

## Requirements

- Pi CLI (`npm install -g @mariozechner/pi-coding-agent`)
- `gh` CLI (GitHub integration)
- Git

No Anthropic dependency. Models via Ollama Cloud, ZAI, MiniMax, and Straico.

## License

MIT
