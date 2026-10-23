# Development Workflow Guide

Human-facing quick reference for the full sprint lifecycle. Claude does not load this file.

## 1. Orient

Open a Claude Code session. The SessionStart hook injects `docs/wiki/index.md` + `docs/wiki/state.md`; Claude prints a short banner. Your first message can be:

> What's next based on state.md? Show me roadmap and backlog options.

Or go straight to `/sprint-plan`.

## 2. Close the previous sprint (if one is still active)

```bash
./workflow/scripts/health-check.sh      # anything drifted?
./workflow/scripts/sprint-finish.sh     # needs the ingest sigil; see step 7
```

## 3. Brainstorm (interactive)

`/sprint-plan` Step 2. Describe what you want. Claude asks one question at a time, proposes 2–3 approaches, presents the design section by section. Ends with `docs/specs/YYYY-MM-DD-<topic>-design.md`.

## 4. PRD and plan (same session)

`/sprint-plan` Steps 4–5. `/prd-template` produces `docs/prds/current.json`; the plan lands in `docs/plans/`. Review the acceptance criteria carefully. They are the contract the implementation agent and the story reviewer both read. Vague criteria produce vague code.

## 5. Start the sprint

```bash
./workflow/scripts/sprint-start.sh <sprint-name>
```

Creates `sprint/<name>` off the base branch, seeds `workflow/workflow.db`, writes "Active Sprint" into `state.md`, appends a `sprint-start` entry to `log.md`.

## 6. Build

**Autonomous:** `./ralph.sh [iterations]`. Each iteration handles one story: branch, prompt, implement, gates, review, merge. Walk away or watch the transcript. Logs in `ralph-logs/`.

**Interactive:** work in a Claude Code session story by story. Skills fire as you go. Set `passes: true` in the PRD and update the DB yourself, or just let `health-check.sh` tell you what drifted.

**Mixed:** ralph for the straightforward stories, interactive for the design-heavy ones.

If ralph reports a story as blocked, read `ralph-logs/iteration-N.jsonl`, fix the root cause on the preserved story branch, and re-run; the loop resumes in-progress stories first.

## 7. Review and wrap up (one fresh session)

1. `/phase-review` — runs quality gates once, dispatches the reviewers in parallel, then the devil's advocate. Report lands in `docs/wiki/sources/`. PRD gets a `review` block and per-story `findings`.
2. Fix Tier 1 and quick Tier 2 items in the same session.
3. `/wiki-ingest` — reads the sprint diff, proposes which wiki pages change, waits for your approval, applies edits, updates `state.md`, appends the `sprint-finish` sigil to `log.md`.
4. Update `docs/roadmap.md` and `docs/backlog.md` if you keep them; the ingest skill does not touch them.

## 8. Finish

```bash
./workflow/scripts/sprint-finish.sh [--yes]
```

Runs `preFinishGates`, verifies the sigil, merges `sprint/<name>` into the base branch, archives the PRD to `docs/prds/archive/`, marks the sprint complete, deletes the branch. `--skip-ingest` bypasses the gate but writes a `(skipped)` entry that `/lint-wiki` counts against you.

## 9. Ship

PR from the base branch to `main`. Manual and intentional.

## Where your time goes

| Step | Creative? | Your input |
|---|---|---|
| Orient | No | Reading |
| Brainstorm | **Yes** | Scope, trade-offs, UX decisions |
| PRD review | **Yes** | Acceptance-criteria quality |
| Build | Sometimes | Unblocking stories, design calls |
| Review + wrap-up | **Yes** | Verdicts on Tier 3 items, wiki approval |
| Everything else | No | Scripts |
