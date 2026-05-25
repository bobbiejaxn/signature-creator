# Pi Launchpad

Autonomous agent orchestration layer for any software project. Drop it into your repo and get **60 specialist AI agents** that plan, build, review, and ship verified features end-to-end.

## What You Get

- **CEO agent** — autonomous PLAN→DELEGATE→REVIEW→VERIFY loop for high-level goals
- **Dynamic CEO** — strategic layer that audits assets, sets OKRs, manages crons, routes tasks
- **Board deliberation** — 8 advisors with competing biases debate before committing
- **54 specialist agents** — architects, implementers, reviewers, researchers, verifiers, team leads
- **28 slash commands** — `/ship`, `/ceo`, `/deliberate`, `/verify-loop`, `/generate`, etc.
- **17 TypeScript extensions** — runtime enforcement, model routing, trace recording, domain locking, session intelligence
- **186 skills** — composable behaviors from code quality to Google Workspace to ad management
- **6 hard-enforcement gates** — deterministic checks no agent can bypass
- **Zero-trust review** — cross-model review, completion auditor, adversarial testing
- **Pi-to-Pi network** — agents communicate across Mac ↔ Hostinger ↔ NetCup
- **Self-healing** — heartbeat + Telegram alerts + safe-update with auto-rollback
- **Self-optimizing harness** — traces every call, diagnoses failures, proposes improvements
- **Session intelligence** — automatic orientation on session start, rule proposals on session end
- **Overnight automation** — label GitHub issues, wake up to open PRs

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
├── agents/          60 agents (52 core + 8 board)
├── prompts/         28 slash commands
├── extensions/      17 TypeScript extensions (subagent, CEO, model-router, session-intel, etc.)
├── skills/          186 composable behaviors
├── config.sh        Project settings (single source of truth)
├── expertise/       Per-agent mental models (compound over time)
├── learnings/       Self-learning loop (patterns auto-promote at 3+ recurrences)
├── multi-team/      Team configs and multi-team agents
├── verifier/        Domain verifier scripts and prompts
└── traces/          Execution trace filesystem (powers harness evolver)

scripts/             43 enforcement and automation scripts
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

17 runtime extensions that enforce rules, capture traces, and continuously improve the harness.

| Extension | What it does |
|-----------|-------------|
| **subagent** | Multi-agent delegation — parallel, chain, single modes |
| **ceo** | Autonomous CEO loop — plan, delegate, review |
| **model-router** | Dynamic Ollama Cloud model selection and frontier sweeps |
| **session-intel** | START: injects git orientation; STOP: proposes rule/skill updates |
| **trace-recorder** | Captures every tool call, result, and cost to JSONL traces |
| **domain-enforcer** | Per-agent file access rules — read, write, delete boundaries |
| **command-hygiene** | Blocks dangerous bash patterns (rm -rf, sudo, etc.) |
| **bash-whitelist** | Restricts bash to an explicit allowlist |
| **no-bash** | Read-only mode — blocks all bash execution |
| **damage-control** | Safety net for destructive operations |
| **brave-search** | Brave Search API integration |
| **context7-tools** | Context7 documentation lookup |
| **github-tools** | GitHub issues, PRs, and repo operations |
| **obsidian-write** | Write directly to Obsidian vault |
| **deepseek** | DeepSeek model provider routing |
| **straico** | Straico multi-model API gateway |
| **coms-net** | Pi-to-Pi network — cross-server agent communication |

## Documentation

| Doc | Contents |
|-----|----------|
| [Agents](docs/agents.md) | Full roster — 60 agents, models, roles, tools |
| [Extensions](docs/extensions.md) | 17 runtime extensions — what they intercept and enforce |
| [CEO & Board](docs/ceo-and-board.md) | CEO loop, dynamic CEO, board deliberation |
| [Ship Pipeline](docs/ship-pipeline.md) | /ship phases, code quality enforcement, verifiers |
| [Harness & Learning](docs/harness-and-learning.md) | Self-optimizing harness, mental models, learning loop |
| [Cron Automation](docs/cron-automation.md) | Overnight shipping, dynamic cron management |
| [Model Routing](docs/model-routing.md) | Multi-provider routing, frontier sweep |
| [Skills Catalog](docs/skills-catalog.md) | 186 skills by category |
| [Setup Reference](docs/setup-reference.md) | Setup, update, config reference, supported stacks |

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
