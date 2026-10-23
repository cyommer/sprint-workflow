---
name: sprint-plan
description: >
  Full sprint planning workflow. Guides the conversation through orient,
  brainstorm, spec, PRD, implementation plan, and sprint start, in that exact
  order. Use whenever the user asks to plan a sprint, start planning, begin a
  new feature sprint, or says anything like "let's plan", "new sprint", "plan
  the next sprint", "start planning". Also use when the user provides a list of
  work items and wants to turn them into a sprint. While this skill is active,
  do not let generic brainstorming or planning skills take over the sequence.
---

# Sprint Planning Workflow

This skill runs the full sprint planning sequence for the project named in
`workflow/config.json` (`projectName`). It exists because the workflow has a
specific order (orient -> brainstorm -> spec -> PRD -> plan -> start) that must
be followed. Generic brainstorming and planning skills don't know about the PRD
step and will skip it.

**The most important rule: follow the steps in order. Do not skip steps. Do not
let other skills take over the sequence.**

## The Sequence

```
Step 1: Orient
Step 2: Brainstorm (interactive, no skill invocation)
Step 3: Write spec
Step 4: Write PRD (using /prd-template skill)
Step 5: Write implementation plan
Step 6: Sprint start
```

Each step has a gate. Complete it and get user confirmation before moving on.
If the user says "looks good" or "let's move on", proceed. If they have
feedback, incorporate it before advancing.

---

## Step 1: Orient

`docs/wiki/state.md` and `docs/wiki/index.md` are already injected at session
start by the `.claude/hooks/session-start-wiki.sh` SessionStart hook. Do not
re-read them unless the hook didn't fire. Step 1 covers the artifacts outside
the wiki, if they exist:

- `docs/roadmap.md` — development phases and architecture direction
- `docs/backlog.md` — prioritized work items

Also read any files the user references. Summarize what you understand about
the work to be done, including the "Next Up" item from the injected `state.md`.
This is a brief status check, not a deep dive.

**Gate:** Present your understanding. Wait for confirmation.

---

## Step 2: Brainstorm

An interactive design session with the user. Do NOT invoke a generic
brainstorming skill. It will hijack the workflow and skip the PRD.

Do this yourself:

1. **Analyze the gap** between current state and desired outcome. For
   layout/design work, read mockups and compare against the current
   implementation. For feature work, identify what needs to be built.

   **Targeted wiki retrieval:** Consult `docs/wiki/index.md` (already injected)
   to find 1-3 relevant entity or concept pages. Grep `docs/wiki/` for specific
   nouns from the task (e.g., `grep -rl <Noun> docs/wiki/`). Read only the
   targeted pages. Do not load siblings or linked pages preemptively.

2. **Ask clarifying questions one at a time.** Prefer multiple choice. Focus on
   decisions that affect implementation, not open-ended exploration. Stop
   asking when you have enough to propose a design.

3. **Propose 2-3 approaches** with trade-offs and your recommendation.

4. **Present the design** section by section, getting approval as you go.

Keep it conversational and focused: a productive design meeting, not a
requirements interview.

**Gate:** User approves the overall design. Proceed to spec.

---

## Step 3: Write Spec

Write the validated design to a spec file:

- Path: `docs/specs/YYYY-MM-DD-<topic>-design.md`
- Include: problem statement, design decisions, section-by-section details,
  and links to the wiki pages it depends on
- Self-review: scan for TBDs, contradictions, ambiguity. Fix inline.

Commit the spec.

**Gate:** Tell the user the spec is written and ask them to review. Wait for
approval.

---

## Step 4: Write PRD

This is the step that gets skipped when other skills take over. It is
mandatory.

Invoke the `/prd-template` skill to generate the PRD at the path in
`workflow/config.json` (`prdPath`, default `docs/prds/current.json`). Key
requirements:

- `sprintName` in kebab-case
- `contextFiles` pointing to the spec from Step 3 and relevant docs
- `userStories` with sequential IDs (US-001, US-002, ...), ordered by dependency
- Every story has acceptance criteria with at least one `Test:` criterion (or
  `"testScope": "manual"` when there is genuinely nothing to automate)
- Every story ends with the quality gate criterion: the project's full test
  command (`qualityGates.testAll` in `workflow/config.json`) passes with 0
  failures
- Every story has a `wikiPages` array
- `deferred` section for anything explicitly cut

Commit the PRD.

**Gate:** Tell the user the PRD is written. Wait for approval.

---

## Step 5: Write Implementation Plan

Write a detailed implementation plan:

- Path: `docs/plans/YYYY-MM-DD-<feature-name>.md`
- Each task maps to a user story from the PRD
- Tasks contain exact file paths, code blocks, test commands, commit messages
- TDD: write test -> verify fail -> implement -> verify pass -> commit
- No placeholders. Every step has actual content.

Reference the spec (Step 3) and PRD (Step 4) while writing. The plan should be
executable by an engineer with zero context about the codebase.

### Step 5.5: Self-review — cross-check paths against spec and PRD

**Before committing the plan, run this cross-check.** The plan is the third
document in the chain (spec -> PRD -> plan). Any path, filename, or identifier
in the spec or PRD must appear in the plan with the same value. Drift between
these documents is a common failure mode: the agent running stories reads the
PRD, not the plan, so PRD-vs-plan drift silently breaks ralph execution.

Adjust the path prefix regex to your repo layout, then run both diffs:

```bash
SPEC=docs/specs/YYYY-MM-DD-<topic>-design.md
PRD=$(workflow/scripts/get-config.py prdPath)
PLAN=docs/plans/YYYY-MM-DD-<feature-name>.md
PATHS='(src|app|lib|tests|docs|workflow|\.claude)/[^ `)"'"'"']*'

# Spec vs plan: every path in the spec should appear in the plan
diff <(grep -oE "$PATHS" "$SPEC" | sort -u) <(grep -oE "$PATHS" "$PLAN" | sort -u)

# PRD vs plan: every path in the PRD must appear in the plan
diff <(grep -oE "$PATHS" "$PRD" | sort -u) <(grep -oE "$PATHS" "$PLAN" | sort -u)
```

Lines marked `<` (in spec/PRD but not plan) are the dangerous ones. They mean
the plan diverged from an earlier decision. Before committing:

- For each `<` line, verify the plan uses the same path or update the plan.
- If the plan intentionally differs, the spec or PRD is wrong and should be
  updated too (go back to Step 3 or 4, fix, recommit, then return here).
- Never commit a plan whose PRD-vs-plan diff contains `<` lines.

Lines marked `>` (in plan but not spec/PRD) are usually fine. The plan
legitimately adds implementation detail the earlier docs didn't cover.

**Why this step exists:** in the project this kit came from, a plan's test
paths drifted from the PRD (plan said one test directory, PRD said another).
The implementation agent followed the PRD and the plan was stale. The sprint
lost two iterations before the drift was caught. One diff command would have
caught it.

Commit the plan.

**Gate:** Present execution options to the user:
1. Autonomous — run `./ralph.sh` and let the loop implement stories one per
   iteration on story branches
2. Inline — implement in this session, story by story, following the plan
3. Manual — the user runs `sprint-start.sh` and `ralph.sh` themselves

---

## Step 6: Sprint Start

Only if the user chooses option 1 or 2:

```bash
./workflow/scripts/sprint-start.sh <sprintName>
```

This creates the sprint branch from `baseBranch` (config), populates the
workflow DB, and writes the "Active Sprint" section of `docs/wiki/state.md`.

Then either run `./ralph.sh` (option 1) or start implementing US-001 in this
session (option 2).

---

## What NOT To Do

- Do NOT invoke generic brainstorming or plan-writing skills — they skip the PRD
- Do NOT skip from spec straight to implementation plan
- Do NOT start writing code before the PRD exists at `prdPath`
- Do NOT combine multiple steps into one message (each step needs its own gate)

## Recovery

If you realize you've skipped a step, stop and go back. It's better to pause
and say "I need to write the PRD before the plan" than to continue out of
order.
