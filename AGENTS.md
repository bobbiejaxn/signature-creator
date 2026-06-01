# Agentic Launchpad

## Setup Check

Run `grep -cE '\{\{[A-Z][A-Z_]+\}\}' .pi/config.sh` — if count > 0, the agentic layer isn't configured. (Plain `grep '{{'` has false positives from `style={{}}` in CSS rules.) Ask the user for project details, then run `./setup.sh .`. If no `.pi/config.sh` exists, the template isn't installed — clone from `bobbiejaxn/pi_launchpad`.

Agent setup: `./setup.sh --config /tmp/setup.json` (non-interactive). See README.md for details.

---

## Subagent Calls

Always set `confirmProjectAgents: false` when invoking subagents:
```json
{ "agentScope": "both", "confirmProjectAgents": false }
```

## Model Provider Routing

| Provider | Models | API | Auth |
|----------|--------|-----|------|
| **Zai** (direct) | `zai/glm-5`, `zai/glm-5.1`, `zai/glm-4.5-air` | `api.z.ai/api/coding/paas/v4` | `ZAI_API_KEY` env var |
| **Ollama Cloud** | `deepseek-v4-flash:cloud`, `deepseek-v4-pro:cloud`, `kimi-k2.6:cloud`, `minimax-m2.7:cloud`, `qwen3-coder:480b-cloud` | `localhost:11434/v1` | Free (no key) |
| **Straico** | `straico/perplexity/sonar`, `straico/perplexity/sonar-deep-research` | Straico API | `STRAICO_API_KEY` env var |
| **Claude** (Oracle) | `claude-sonnet-4-20250514` | Claude Code OAuth | `claude -p` (subscription) |

**Key rule:** GLM models MUST use `zai/` prefix in agent `model:` fields. Other models keep `:cloud` suffix for Ollama Cloud.

---

---

## Credentials-First Rule (Non-Negotiable)

On brownfield projects (anything already deployed or in /root/projects/), ALL env vars, API keys, tokens, and secrets already exist on disk. **Find them — never claim they're missing.**

Check before asking anyone:
- `.env`, `.env.local`, `.env.production`, `.env.vercel` in project root
- `~/.netrc` (GitHub, etc.)
- `~/.config/` (Vercel, Stripe, Umami CLIs)
- SSH keys in `~/.ssh/`
- Docker-compose env vars / secrets
- Project deploy scripts
- `.pi/config.sh`
- `/opt/<project>/` deployed env files
- `~/go/bin/` installed CLIs with auth

**Only ask for credentials on genuinely greenfield projects** (brand new, never deployed).

**Off-task blockers** (missing/broken creds not related to current task) → create a GitHub issue. Do not interrupt the user.

## Quality Bar (applies to ALL agents, including subagents)

**"Done" = working end-to-end in the running app.** The user must be able to actually use the feature and have it do what was asked.

The following are necessary checkpoints, but NONE of them mean "done":
- ❌ TypeScript compiles
- ❌ Tests pass
- ❌ Build succeeds
- ❌ Lint clean
- ❌ Subagent returned "success"

**Think end-to-end BEFORE coding.** Trace the full path the change touches: user action → frontend component → API/Convex call (args shape) → handler (auth, DB query, returns) → schema → every other consumer. Most production bugs are isolated-layer changes that break the contract with the next layer.

**Verification evidence is mandatory.** When declaring a task complete (yourself or via subagent), include:
- What was changed (file paths)
- How it was verified end-to-end (specific URL, command, query, or test that exercises the runtime path — not just "tsc passes")
- What remains unverified, if anything (be honest)

**When delegating to a subagent:** carry this bar with the delegation. Include in the task brief: "Done = working end-to-end. Compiling is not done. Report verification evidence, not just file changes." A subagent declaring victory at compile-clean is not actually done.

**No premature victory declarations.** Mock data, stubs, TODO placeholders, "looks right to me" — all explicitly NOT done. If something isn't fully verified, say so.

**This rule overrides token-efficiency and speed concerns.** A fast wrong answer is worse than a slow right one — the user can't debug what you produced.

## Working Agreement

- **"Done" = working end-to-end.** Code written is not done. Tests passing is not done. Done = the user can actually use it, and it works. *(See Quality Bar above for full definition.)*
- **No premature victory declarations.** Be honest about what's missing. Never say "completed" until the gates pass and the PR is open.
- **Mock data = technical debt.** Only use mock/placeholder data with an explicit plan to replace it. If you stub something, leave a TODO with the real data source.
- **Be resourceful before asking.** Try to figure it out first. Come back with answers, not questions. Read the code, check the schema, search the repo.
- **Trust tool output.** When a tool returns success, it's done. Don't re-run "just to be safe." Don't double-send messages. Don't re-verify what already passed.
- **Trust edit results.** After an `edit` call returns success, do NOT re-read the file to verify.
- **Keep it concise.** No filler, no fluff, no restating what the user already said. Action-focused responses. Speed matters.
- **External actions = ask first.** Anything that touches the outside world — emails, posts, deploys, public APIs — confirm with the user before executing.
- **Verify once per batch.** After a batch of edits, run verification once. Use `vibe-verify.sh --quick` for combined tsc+lint.
- **Delegate over scouting.** If you need to read 3+ files to understand a codebase area, delegate to a scout subagent.
- **Never create public repos.** All `gh repo create` calls must include `--private`. No exceptions.
- **Never use trivial passwords.** No passwords under 12 characters.
- **Never write unsafe code.** No `eval()`, no `innerHTML` without sanitization, no SQL string concatenation, no `shell=True`, no `verify=False`, no CORS `*` in production.
- **Never hardcode secrets.** API keys belong in environment variables or secret managers.

## Tool Call Budget

- **Max 200 tool calls per session.** If you exceed 200 tool calls, stop and report to the user with a summary of what you've done.
- **Max 5 identical tool calls.** If you call the same tool with the same input 5+ times, you are in a loop. Stop, reassess, and try a different approach.
- **Max 10M input tokens per session.** If context approaches this limit, compact your context or stop and ask the user how to proceed.
- **Autoresearch sessions are exempt** — experiment loops are intentional and budgeted separately.

## Bash Command Rules

**NEVER prefix with `cd`.** The working directory is always the project root.

```
Bad:  cd src && npm test
Good: npm test --prefix src

Bad:  cd .pi/agents && grep model *.md
Good: grep model .pi/agents/*.md

Bad:  # Check types\ntsc --noEmit
Good: tsc --noEmit
```

Every `cd` prefix wastes a tool call. Every `#` comment wastes a tool call. Just run the command.

## Verification Protocol

After completing a batch of edits:
1. Run `./scripts/vibe-verify.sh --quick` for combined tsc + lint checks
2. Only if that fails, run individual commands to diagnose
3. NEVER run tsc, lint, or codegen individually as a first check
4. NEVER run the same verification command more than once per batch

## Visibility During Work

### For UI/frontend work:
After making visual changes, commit them and tell the user to check:
"Run `npm run dev` to preview the changes at localhost:PORT"
The user should see work BEFORE it's finalized.

### For all work:
When completing a non-trivial task, summarize:
1. What was changed (file paths)
2. Why (1-line rationale per file)
3. What to verify (specific test or URL to check)

Never complete a task without telling the user how to verify it.

---

## Pi Quick Reference

| Command | What it does |
|---------|-------------|
| `/prime` | Orient on codebase + load learnings |
| `/ship <feature>` | Full delivery — spec → implement → verify → PR |
| `/fix <issue-number>` | Fix a GitHub issue end-to-end |
| `/plan <task>` | Plan before coding, wait for confirmation |
| `/tdd <task>` | Test-driven development |
| `/review` | Pre-commit code review |
| `/verify` | Run verification checks |
| `/deliberate <brief>` | Board deliberation — 7 advisors debate |

## Configuration

All project-specific values live in `.pi/config.sh`. Edit that file — not the agents or scripts.

## Context Budget — Avoid Re-reading Files

- **Never re-read a file** you've already read this session. Trust your memory.
- When delegating to subagents, load `.pi/reference/agents-catalog.md` for orchestration tables.
- For long sessions, prefer delegating to subagents over accumulating context in the main session.

## Anti-Patterns (Hard Rules)

These are never acceptable in any output.

### Code
- No `any` types — use `unknown`, specific types, or generics
- No `eslint-disable` — fix the lint error
- No inline styles when a CSS class or styled-component exists
- No `eval()`, `innerHTML` without sanitization, SQL string concat
- No TODO without an associated issue number
- No placeholder/mock data without a `TODO: replace with real data source`

### UI
- No Inter, Roboto, Arial, system-ui as primary font — use the project's font
- No aggressive gradient backgrounds unless the design system uses them
- No emoji in UI unless the brand explicitly uses them
- No rounded containers with left-border accent color
- No SVG illustrations drawn by AI — use placeholders or real assets
- No filler sections — every element earns its place

### Writing
- No "In conclusion" or "To summarize" padding
- No "It's worth noting" or "At the end of the day" hedging
- No rule-of-three lists that add no information
- No meta-commentary ("I've made the changes you requested")

### Scope
- No adding features the user didn't ask for
- No padding designs with extra sections
- No inventing requirements not in the spec

---

## Session Intelligence

The `session-intel` extension (`.pi/extensions/session-intel/`) provides continuous self-improvement:

| Hook | Event | What it does |
|------|-------|-------------|
| START | `before_agent_start` | Injects git orientation (branch, status, recent commits) into every session |
| STOP | `session_shutdown` | Writes rule/skill update proposals to `.pi/session-intel/proposals/` |

Proposals are **never auto-applied** — they're review artifacts for the orchestrator or user. This is the "self-improving AI layer" pattern: rules evolve continuously without manual maintenance.

Config: `.pi/session-intel/config.json`

---

## Rule source of truth

`AGENTS.md` (this file). Skills point to it, never restate. When rules conflict, AGENTS.md wins.

## Voice & Tone

All agents load `~/.pi/agent/voice.md` for consistent output style. Reference it when writing user-facing content, docs, or chat responses.
