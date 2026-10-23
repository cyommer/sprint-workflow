---
name: wiki-ingest
description: >
  Post-sprint ingest into the wiki knowledge layer. Walks Claude through reading
  the sprint's git diff, identifying affected wiki pages, proposing an update
  plan, waiting for user approval, then editing pages and appending a
  sprint-finish entry to docs/wiki/log.md with the sigil that sprint-finish.sh
  verifies. Use at sprint wrap-up, after all stories pass and before running
  sprint-finish.sh. Triggers: "ingest", "wiki-ingest", "wrap up the sprint".
---

# Wiki Ingest

Propagate a just-finished sprint's knowledge into the wiki (`wikiDir` in
`workflow/config.json`, default `docs/wiki/`). This is the write side of the
wiki enforcement loop. Without it, `sprint-finish.sh` refuses to finish the
sprint.

## When to Use

- All stories in the current sprint are passing
- Quality gates are green
- `/phase-review` has run and Tier 1 items are fixed
- Before running `./workflow/scripts/sprint-finish.sh`
- When the user says "ingest" or "wrap up the sprint" or invokes `/wiki-ingest`

## The 5-Step Checklist

Do not skip steps. Do not combine steps. The user-approval gate (Step 4) is
mandatory. Do not edit any wiki pages before it.

### Step 1: Read the sprint's git diff

The sprint branch was cut from `baseBranch` (config, default `develop`):

```bash
BASE=$(git merge-base HEAD "$(workflow/scripts/get-config.py baseBranch)")
git log --stat "${BASE}..HEAD"
```

Look at the commit messages and file statistics. Build a mental model of what
this sprint actually changed: new modules, new endpoints, new skills, new
concepts, renamed files, deleted features. Note any surprising or out-of-scope
changes.

### Step 2: Consult the wiki index

Read `docs/wiki/index.md` and identify candidate pages that may need updates:

- **Entity pages** (`entities/*.md`) — update when a documented entity's data
  model, API, or behavior changed. Create a new entity page if the sprint
  introduced a new documented thing (a new model, subsystem, or skill).
- **Concept pages** (`concepts/*.md`) — update when a documented cross-cutting
  concept changed. Create a new concept page if the sprint introduced a new
  cross-cutting pattern worth naming.
- **Sources** (`sources/*.md`) — never edit existing sources; they are
  immutable. If a phase review just ran, `/phase-review` filed it here already.
- **State and log** — `state.md` and `log.md` are updated in Step 5, not here.

Follow `docs/wiki/CONVENTIONS.md` for any new pages: page size budget (under
200 lines), link discipline, naming.

### Step 3: Propose the update plan

Present a written plan to the user as a list. For each candidate page:

- **Page path** (e.g., `entities/search-index.md`)
- **What changed** in the sprint that affects this page
- **Proposed edit** (one sentence: what you'll add, rewrite, or remove)

Also list:

- **New pages** you propose to create (path + one-line purpose)
- **Changes to `state.md`**: Recent Completion summary (2-3 sentences), Next Up
  item (1 line)
- **The `log.md` entry** you will append, in the sigil format below

**Do not edit anything yet.**

### Step 4: Wait for user approval

This is a hard gate. Do not proceed to edits until the user approves the plan
or asks for revisions. If the user asks for revisions, update the plan and
re-present. Only after explicit approval ("yes", "go ahead", "approved",
"looks good") proceed to Step 5.

If you are uncertain whether the user has approved, ask explicitly. Do not
guess.

### Step 5: Apply edits and append log entry

Apply the approved edits to entity and concept pages. Add any new pages to
`index.md` (one line each). Then update `docs/wiki/state.md`:

- Clear the "Active Sprint" section (set to `None. <sprint-name> merged <date>.`)
- Update "Recent Completion" with the summary from Step 3
- Update "Next Up" with the next sprint or roadmap item

Finally, append a sprint-finish entry to `docs/wiki/log.md` in exactly this
format:

```markdown
## {YYYY-MM-DD} — sprint-finish: {sprint-name}
Updated: {comma-separated list of wiki paths}
```

The sigil prefix `sprint-finish: {sprint-name}` is what `sprint-finish.sh`
greps for (regex `^## .* sprint-finish: <name>$`). Do not change the format.
It is part of the enforcement contract. You may add 1-2 paragraphs of
narrative under the `Updated:` line.

Example:

```markdown
## 2026-01-15 — sprint-finish: search-indexing
Updated: concepts/sprint-workflow.md, entities/search-index.md, entities/indexer-job.md
```

Commit the wiki changes.

## What NOT To Do

- Do NOT edit wiki pages before Step 4 approval.
- Do NOT edit files in `sources/`. Those are immutable.
- Do NOT change the sigil format. It is the enforcement contract.
- Do NOT invoke `/wiki-ingest` mid-sprint. Only at wrap-up, after all stories
  pass.
- Do NOT silently skip `state.md` or `log.md` updates. Both are mandatory.

## After Ingest

Once Step 5 is complete and committed, the user can run:

```bash
./workflow/scripts/sprint-finish.sh
```

The script greps `log.md` for the sigil you just wrote and proceeds with the
merge. If the sigil is missing or malformed, the script refuses to finish and
points the user back to this skill.
