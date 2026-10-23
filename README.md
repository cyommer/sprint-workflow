# Claude Code Sprint Workflow Kit

A drop-in sprint workflow for solo developers (or small teams) building with Claude Code. It gives you:

- **A knowledge layer** (`docs/wiki/`) that Claude reads automatically at the start of every session and is *forced* to update at the end of every sprint.
- **A planning sequence** (`/sprint-plan`) that will not let Claude skip from "sounds good" to writing code: brainstorm → spec → PRD → plan → sprint start.
- **An autonomous implementation loop** (`ralph.sh`) that works one PRD story at a time on its own branch, runs your quality gates, has a second model review the diff against the acceptance criteria, retries once, and merges.
- **A multi-agent phase review** (`/phase-review`) with a devil's advocate that challenges the other reviewers and spot-checks their claims against real files, producing findings in three confidence tiers.
- **Lifecycle scripts** (`sprint-start.sh`, `sprint-finish.sh`, `health-check.sh`) that keep git, a small SQLite index, and the PRD JSON in agreement, and refuse to merge a sprint whose knowledge was never written down.

Nothing here is specific to a language or framework. Project-specific commands live in one file, `workflow/config.json`.

> **Status: a snapshot, shared to show the approach.** This was extracted in October 2026 from a solo web project that ran it for a couple of dozen sprints. It is not actively maintained as a product. Claude Code has absorbed some of what it does since it was built (plan mode, native memory, multi-agent review workflows), so parts of the agent-dispatch mechanics are dated. The process layer (PRD as contract, the two wiki gates, story branches, the implement-review-retry step) is the durable part. See [Start small](#start-small) before installing all of it.

## The loop

```
  /sprint-plan ──► docs/specs/*.md ──► docs/prds/current.json ──► docs/plans/*.md
                                                 │
                                                 ▼
                              ./workflow/scripts/sprint-start.sh <name>
                                   (branch, DB rows, wiki state.md)
                                                 │
                                                 ▼
                                           ./ralph.sh
                        ┌── per story ────────────────────────────────────┐
                        │ branch ► focused prompt ► claude -p (impl)      │
                        │ ► quality gates ► claude -p (story review)      │
                        │ ► retry once with feedback ► merge to sprint    │
                        └─────────────────────────────────────────────────┘
                                                 │
                                                 ▼
                     /phase-review  (N reviewers in parallel + devil's advocate)
                                                 │
                                                 ▼
                     /wiki-ingest   (update wiki pages, write the sigil to log.md)
                                                 │
                                                 ▼
                              ./workflow/scripts/sprint-finish.sh
                      (pre-finish gates ► sigil check ► merge ► archive PRD)
```

Two gates make the knowledge layer trustworthy without discipline:

1. **Read side.** A `SessionStart` hook injects `docs/wiki/index.md` and `docs/wiki/state.md` into every session. Claude always starts oriented.
2. **Write side.** `sprint-finish.sh` greps `docs/wiki/log.md` for `## <date> — sprint-finish: <sprint-name>` and refuses to merge without it. `/wiki-ingest` is the only thing that writes that line, and it only does so after it has updated the affected pages and you have approved the plan.

Everything between the gates is advisory. That is the point: the structure holds even on the days you do not.

## Quickstart

Requirements: `git`, `python3` (3.10+), the `claude` CLI. `sqlite3` CLI is optional; the scripts fall back to Python's `sqlite3` module.

```bash
git clone <this repo> ~/workflow-kit
~/workflow-kit/install.sh /path/to/your/project --project-name "My App"
cd /path/to/your/project
```

Then, about ten minutes of setup:

1. **`workflow/config.json`** — set `baseBranch`, the three quality gate commands, any `preFinishGates`, and `neverStage`. Example for a Django project (a Node project would use `npm run lint`, `npx vitest run {targets}`, and `npm test`):
   ```json
   "qualityGates": {
     "before": ["ruff check .", "ruff format --check ."],
     "test": "pytest {targets} --tb=short",
     "testAll": "pytest --tb=short",
     "after": ["python manage.py check"]
   },
   "preFinishGates": { "commands": ["python manage.py makemigrations --check --dry-run"] }
   ```
   `{targets}` is replaced by the story's `testScope` (or the test files the agent touched) so per-story runs stay fast; the full suite runs at phase review.
2. **`CLAUDE.md`** — paste `CLAUDE.md.snippet` in. It teaches Claude the banner, the retrieval rule, the mandatory planning sequence, and the branching model.
3. **`.claude/review-agents/*.md`** — fill the Project Context bullets at the top of each. Move anything you want from `optional/` up one level; `/phase-review` dispatches whatever files it finds there.
4. **`docs/wiki/`** — write one entity page per major subsystem (50–150 lines each), list them in `index.md`, set `state.md` "Next Up". Keep `index.md` + `state.md` under 200 lines combined; they load every session.
5. Make sure the base branch exists. Open a Claude Code session: you should see the wiki banner. Run `/sprint-plan`.

## What's in the box

| Path | What it is |
|---|---|
| `.claude/settings.json`, `.claude/hooks/session-start-wiki.sh` | The read-side gate |
| `.claude/skills/sprint-plan/` | Six-step planning sequence with a gate after each step |
| `.claude/skills/prd-template/` | The PRD JSON schema `ralph.sh` consumes, with acceptance-criteria conventions |
| `.claude/skills/phase-review/` | Parallel reviewers + sequential devil's advocate + confidence tiers + PRD update |
| `.claude/skills/wiki-ingest/` | Five-step post-sprint ingest with a hard user-approval gate; writes the sigil |
| `.claude/skills/lint-wiki/` | Six objective drift checks; deliberately no age-based staleness |
| `.claude/review-agents/` | Prompts for security, architecture, phase-completion, product-owner, developer-experience, devil's advocate; `optional/` holds data-model and frontend templates |
| `workflow/config.json` | Every project-specific knob |
| `workflow/models.json` | Model per stage (planning/review strong, implementation cheap) |
| `workflow/schema.sql`, `workflow/lib.sh` | SQLite index of sprint/story state and the shared bash helpers |
| `workflow/scripts/sprint-start.sh` | Branch + DB rows + wiki state, idempotent wiki writes |
| `workflow/scripts/sprint-finish.sh` | Pre-finish gates → ingest gate → merge → archive PRD → cleanup |
| `workflow/scripts/health-check.sh` | DB ↔ git ↔ PRD consistency, exit 1 on drift |
| `workflow/scripts/generate-prompt.py` | Builds the focused per-story prompt from the PRD + config + wiki pages |
| `workflow/scripts/check-promise.py` | Finds `<promise>BLOCKED</promise>` only in assistant text, never in tool I/O |
| `workflow/scripts/format-stream.py` | Renders `claude -p` stream-json as a readable live transcript |
| `ralph.sh` | The loop |
| `docs/wiki/` | Seed wiki: conventions, index, state, log, one concept page |
| `docs/prds/example.json` | A PRD in the expected shape |
| `tests/` | Sandbox tests that install the kit into a temp repo and run the real scripts |

## Start small

The kit is the full set. Most of its value is in four pieces, and the rest earns its place only once you feel a specific pain. Suggested order:

1. **The two wiki gates.** `.claude/settings.json` + `.claude/hooks/session-start-wiki.sh`, `docs/wiki/{index,state,log}.md`, and the sigil check in `sprint-finish.sh`. This alone fixes "Claude forgets the project between sessions." A few hours of seeding pages.
2. **A PRD per sprint.** `/prd-template` and `docs/prds/current.json`. Testable acceptance criteria are what make everything downstream work, whether or not you ever run the loop.
3. **The loop**, when you want to walk away. `sprint-start.sh`, `ralph.sh`, story branches, the per-story review. Add `/sprint-plan` when you notice Claude skipping from "sounds good" to editing files.
4. **Phase review**, when sprints get big enough that you cannot hold the whole diff in your head. Start with three reviewers and the devil's advocate; add more if they find things.

Things you can skip entirely and lose little: `/lint-wiki`, `health-check.sh`, the `docs/plans/` implementation plan (the loop reads the PRD, not the plan), and `workflow.db` if you are not running the loop (the PRD `passes` flags and git branches already hold the state).

## Design notes

See [docs/design-notes.md](docs/design-notes.md) for the reasoning behind each piece and the lessons that shaped it. The short version:

- **Automate the mechanical, keep human judgment.** Scripts do branching, DB rows, and consistency checks. You drive brainstorming, PRD content, and the review verdict.
- **PRD JSON and git are the truth.** The SQLite DB is a convenience index. `health-check.sh` reports drift; it never "fixes" it.
- **Claude implements, ralph orchestrates.** The agent is told to commit to the current branch and never run `git checkout`. It has no idea the DB exists.
- **Context is budgeted, not dumped.** Per-story prompts inline only the story's `wikiPages`; the session hook injects two short files; skills tell Claude to grep the wiki rather than load it.
- **Signals come from assistant text only.** `check-promise.py` exists because a naive `grep BLOCKED` on the transcript matched the literal tag inside tool inputs and results.

## Running the kit's own tests

```bash
pip install pytest   # or: uv run --with pytest pytest
pytest
```

The tests create a throwaway git repo per test, run `install.sh` into it, and exercise `sprint-start.sh`, `sprint-finish.sh`, `health-check.sh`, `generate-prompt.py`, `check-promise.py`, and the SessionStart hook. They do not call the `claude` CLI.

## Adapting

- Different base branch or PRD location: `workflow/config.json`.
- Different wiki location: `wikiDir` in config; the hook and prompt generator both read it.
- More or fewer reviewers: add or remove files in `.claude/review-agents/`.
- Permission mode for the autonomous loop: `claudeExtraFlags` in config. The default is `--dangerously-skip-permissions` because in `claude -p` there is nobody to answer a prompt; a tool call that needs approval simply fails and the story stalls. For a narrower blast radius replace it with an allowlist, e.g. `["--allowedTools", "Edit,Write,Read,Grep,Glob,Bash(pytest*),Bash(git add*),Bash(git commit*)"]`, and run the loop in a container or sandbox either way.
- No wiki at all: delete `docs/wiki/`; `sprint-finish.sh` skips the ingest gate when `log.md` is absent, and the hook prints a one-line notice.
