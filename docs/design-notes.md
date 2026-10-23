# Design Notes

Why the kit is shaped the way it is. Distilled from a couple of dozen sprints of use on a solo web project before it was extracted.

## Problems this solves

1. **Claude forgets the project between sessions.** Re-explaining architecture every session is slow and lossy, and docs written "for later" rot. Fix: a small wiki whose index and state are injected by a hook on every session start, and whose update is mechanically required before a sprint can merge.
2. **Claude skips planning.** Given a feature description it will cheerfully start editing files. Fix: a skill that owns the planning sequence, with a user-confirmation gate after each step, and a rule in `CLAUDE.md` that no sprint starts without a PRD.
3. **Autonomous loops drift.** A loop that feeds the whole PRD to the agent each iteration wastes context and lets the agent "help" with other stories. Fix: a per-story prompt that inlines only that story, its wiki pages, and the project's gate commands; a hard "only work on this story" instruction; story-level branches so a bad run is contained.
4. **Reviews are either shallow or noisy.** One reviewer misses things; seven reviewers inflate severities and contradict each other. Fix: run the domain reviewers in parallel, then a devil's advocate that reads their reports, challenges severities, flags contradictions, and spot-checks at least five claims against real files. Findings get a confidence tier so you know which ones to act on blindly.
5. **Process state lives in three places and disagrees.** Git, the PRD, and whatever tracker you use. Fix: PRD JSON and git are the truth; a tiny SQLite index speeds up the loop; `health-check.sh` reports disagreement and never silently repairs it.

## Principles

- **Automate the mechanical, keep human judgment.** Branching, DB rows, archive, merge, consistency checks are scripted. Brainstorming, acceptance criteria, review verdicts, wiki approval are yours.
- **Structural over behavioral guardrails.** A rule in `CLAUDE.md` is advice. A script that exits 1 is a guardrail. The two gates (session hook, sprint-finish sigil) are the only ones that must hold; everything else can slip and the system recovers next cycle.
- **Claude implements, ralph orchestrates.** The agent never runs `git checkout`, never sees the DB, never chooses a model. All of that happens around the `claude -p` call.
- **Budget context like money.** Two short files per session. One story per prompt. Wiki pages named explicitly in the PRD, not discovered by reading the tree. Skills say "grep the wiki, then read one or two pages."
- **Nothing project-specific in code.** Every command, branch name, path, and pattern lives in `workflow/config.json`. Reviewer prompts carry a Project Context section you fill in once.

## Pieces and their rationale

### The wiki (`docs/wiki/`)

Karpathy-style LLM wiki: `index.md` (catalog, one line per page), `state.md` (active sprint, recent completion, next up), `log.md` (append-only), `entities/` (one page per thing), `concepts/` (cross-cutting), `sources/` (immutable inputs such as phase reviews). Page budget 50–150 lines; `index.md` + `state.md` under 200 lines combined because they load every session.

Knowledge and execution are separate layers on purpose. PRDs, specs, and plans are archived at sprint end and never read again, so drift there is harmless. Drift in the wiki compounds, so that is where the lint and the gate live.

### The PRD (`docs/prds/current.json`)

JSON, not Markdown, because three scripts parse it. Stories carry `acceptanceCriteria` (the contract), `wikiPages` (the context), optional `testScope` (what `{targets}` expands to), and `passes` (the completion flag the agent flips). The last criterion of every story is the full test suite passing.

Conventions that turned out to matter: criteria must be testable sentences, not "works correctly"; every story has at least one `Test:` criterion or an explicit `testScope: "manual"`; stories are ordered by dependency and processed in that order.

### `ralph.sh`

Named after the "Ralph Wiggum loop" idea: keep re-running the agent until the work is done. The additions that made it reliable:

- **Story branches.** `US-003-short-slug` off the sprint branch. A failed story leaves its branch for inspection; a passed one is merged with `--no-ff` and deleted. Re-running resumes `in_progress` stories first.
- **Focused prompts** from `generate-prompt.py`, with TDD instructions when the story has tests and an explicit "no tests, skip TDD" when it does not. Per-story runs use targeted tests; the full suite runs once at phase review.
- **Promise tags.** The agent outputs `<promise>BLOCKED</promise>` after three failed gate attempts. `check-promise.py` only looks at assistant text blocks in the stream-json log. A plain `grep` matched the literal tag inside tool inputs and results and produced false blocks.
- **Per-story review.** A second, cheaper `claude -p` call reads the acceptance criteria and the diff and answers `<review>PASS</review>` or `FAIL` with gaps. One retry with the gaps appended. This caught "implemented but untested" far more often than expected.
- **Model per stage** from `models.json`: a strong model for planning and review, a cheap one for implementation and the story review.

### Lifecycle scripts

- `sprint-start.sh` refuses to run unless you are on the base branch with a clean tree and no sprint is active. It writes the wiki state idempotently so re-running does not duplicate log entries.
- `sprint-finish.sh` runs `preFinishGates` first (the place for checks per-story gates can miss, such as "model changed but no migration committed"), then the ingest gate, then merge, archive, DB update, branch delete. `--skip-ingest` exists for emergencies and leaves a `(skipped)` mark that `/lint-wiki` counts.
- `health-check.sh` is read-only. It compares DB status to the PRD `passes` flags and git branches and exits 1 on contradiction.

### `/phase-review`

Reads the PRD, runs the gates once and passes the output to every reviewer so none of them re-run a slow suite, dispatches one agent per file in `.claude/review-agents/` (self-discovering, so adding a reviewer is adding a file), then the devil's advocate. Findings are tiered:

- Tier 1, mechanically verified: confirmed by a spot-check or a binary acceptance criterion.
- Tier 2, debate-tested: not challenged by the devil's advocate.
- Tier 3, judgment required: challenged, contradicted, or a blind spot.

The report is filed as an immutable wiki source. The PRD gets a `review` block and per-story `findings` so the next PRD can look back at what was deferred.

### `/wiki-ingest` and `/lint-wiki`

Ingest is five steps with a hard approval gate before any edit, and it is the only writer of the sigil. Lint runs six objective checks (broken links, oversized pages, orphans, stale stubs, sprint-finish coverage, skip rate). It deliberately has no "page not touched in N days" check; age is a bad proxy for correctness and such checks train people to ignore the output.

### `/sprint-plan`

Exists because generic brainstorming and planning skills skip the PRD. Step 5.5, the path cross-check between spec, PRD, and plan, exists because a plan once named a different test directory than the PRD did; the agent followed the PRD, the plan was stale, and two loop iterations were lost before anyone noticed.

## Known limits

- Designed for one active sprint at a time and one developer driving. Two people running `ralph.sh` on the same repo would collide on the DB and branches.
- `ralph.sh` runs `claude -p` with `--dangerously-skip-permissions`. Run it somewhere you are comfortable with that.
- The story reviewer sees the first 500 lines of the diff. Very large stories should be split; the PRD skill says so.
- The wiki only stays correct if `/wiki-ingest` is run honestly. The gate checks for the sigil, not for the quality of the edits. `/lint-wiki` catches structural drift, not wrong facts.
- The quality-gate commands run through `bash -c`; Windows users need WSL or Git Bash.
