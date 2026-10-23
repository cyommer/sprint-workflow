---
name: phase-review
description: >
  Use when a PRD sprint is complete and needs review before merging. Triggers on
  sprint completion, after all user stories pass, before wiki-ingest and
  sprint-finish. Dispatches every review agent in .claude/review-agents/ in
  parallel, then a devil's advocate agent to challenge the findings, and
  produces a unified report with confidence tiers. Invoke via /phase-review.
---

# Phase Review

Structured review of a completed sprint. Dispatches one specialized review
agent per file in `.claude/review-agents/` in parallel, then a devil's advocate
agent to challenge severities and spot-check claims. Cross-references findings
against PRD acceptance criteria and produces a unified report with confidence
tiers (Verified / Debate-Tested / Judgment Required).

## When to Use

- A sprint has been fully implemented (all user stories `passes: true`)
- Quality gates pass
- Before `/wiki-ingest` and `sprint-finish.sh`
- When the user says "review this sprint" or invokes `/phase-review`

## Inputs

Optional argument: the PRD path. Defaults to `prdPath` from
`workflow/config.json` (`docs/prds/current.json`).

## The Agent Set

The set is self-discovering: **every `*.md` file directly in
`.claude/review-agents/` except `devils-advocate.md` is a review agent.** Add a
file to add a perspective; delete one to remove it. Do not edit this skill to
change the roster.

Core five shipped with the kit:

- `security-review.md` — real, exploitable vulnerabilities: auth gaps, IDOR,
  injection, secret exposure, unsafe input handling
- `architecture-review.md` — violations of the conventions in `CLAUDE.md` and
  anti-patterns that create technical debt
- `phase-completion.md` — every acceptance criterion in every story marked
  PASS / FAIL / PARTIAL with evidence
- `product-owner-review.md` — does what was built serve the user workflow;
  UX gaps; enhancement ideas for future sprints
- `developer-experience-review.md` — can a newcomer navigate, understand, and
  extend the codebase; documentation drift

`.claude/review-agents/optional/` holds domain templates (`data-model-auditor.md`,
`frontend-review.md`). Activate one by moving it up one directory.

`devils-advocate.md` always runs last, sequentially, with all reports inline.

## Workflow

```
Read PRD + context files
  -> Run quality gates once (stop if red)
  -> Dispatch N review agents in parallel
  -> Collect reports
  -> Dispatch devil's advocate with all reports inline
  -> Cross-reference against PRD + assign confidence tiers
  -> Write unified report to docs/wiki/sources/
  -> Update index.md Sources + PRD review/findings
```

### 1. Read the PRD and context files

Read the PRD and extract user story IDs, titles, and acceptance criteria, plus
the `contextFiles` array. Read `CLAUDE.md` and each file in `contextFiles`.
Consult `docs/wiki/index.md` for entity/concept pages relevant to the sprint.

### 2. Run quality gates first

Run, in order, every command in `qualityGates.before`, then
`qualityGates.testAll`, then every command in `qualityGates.after` from
`workflow/config.json`:

```bash
workflow/scripts/get-config.py qualityGates.before
workflow/scripts/get-config.py qualityGates.testAll
workflow/scripts/get-config.py qualityGates.after
```

If any gate fails, stop and report the failure. Do not dispatch review agents.

**Capture the full output** (pass/fail, test counts, failures). You will pass
it to every agent so they do NOT re-run the suite. Large suites are slow;
running once here is sufficient.

### 3. Dispatch review agents in parallel

List the roster: `ls .claude/review-agents/*.md | grep -v devils-advocate`.

Launch all of them simultaneously with the Agent tool
(`subagent_type: general-purpose`). Each prompt includes:

- "Read `.claude/review-agents/<file>` for your full instructions."
- "Read `CLAUDE.md` for project conventions."
- The PRD path and the `contextFiles` list; the wiki pages relevant to the
  sprint
- **The quality gate output from Step 2**, with: "Quality gates have already
  been run. Do NOT re-run tests, linters, or framework checks. Use the
  provided results."
- "Prefix each finding with `[VERIFIED]` or `[INFERRED]` per your agent file."

### 3.5. Dispatch the devil's advocate (sequential)

After all reports are collected, dispatch one more general-purpose agent.
Include every report verbatim under labeled headings (`## Security Report`,
`## Architecture Report`, ...), then: "Read
`.claude/review-agents/devils-advocate.md` for your full instructions."

It runs after the parallel agents because it needs their complete output. It
challenges inflated severities, flags contradictions, spot-checks `file:line`
claims against actual code, and identifies shared blind spots.

Reports go inline in the prompt (not temp files): a handful of reports is a few
thousand tokens, well within budget, with no file I/O to clean up.

### 4. Collect and cross-reference

After all agents return (including the devil's advocate):

1. Merge findings into a single report
2. Cross-reference findings against specific user stories
3. Identify acceptance criteria marked FAIL or PARTIAL
4. Flag items multiple agents raised (high-confidence issues)
5. Pull product-owner enhancement ideas into a forward-looking section
6. Apply confidence tiers using the devil's advocate output:
   - **Tier 1 (Mechanically Verified):** findings the DA spot-checked and
     marked CONFIRMED, plus all completion-agent PASS/FAIL criteria (binary)
   - **Tier 2 (Debate-Tested):** findings the DA did not challenge
   - **Tier 3 (Judgment Required):** findings where the DA raised a challenge,
     flagged a contradiction, or identified a shared blind spot

### 5. Produce the unified report

Save to `docs/wiki/sources/YYYY-MM-DD-<sprint-name>-review.md`. This is an
immutable wiki source. Do not edit it after filing.

Then add one line to the Sources section of `docs/wiki/index.md`:

```markdown
- [<Sprint> Review (YYYY-MM-DD)](sources/YYYY-MM-DD-<sprint>-review.md) — N/M ACs, N must-fix, N should-fix, sign-off
```

Report template (one `## <Agent> Findings` section per agent that ran):

```markdown
# Phase Review Report: <sprintName>
**Date:** YYYY-MM-DD
**PRD:** <prdPath>
**Branch:** sprint/<sprintName>

## Executive Summary
- Acceptance criteria: X/Y passing
- Must-fix findings: N (Tier 1: N, Tier 2: N)
- Quality gates: all green / N failing
- Confidence: N verified, N debate-tested, N judgment-required
- Devil's advocate: N severity challenges, N contradictions, calibration <verdict>

## Quality Gates
| Gate | Status |
|---|---|
| <each command from config> | PASS/FAIL (details) |

## <Agent> Findings
[One section per agent, grouped by that agent's severity scheme]

## Acceptance Criteria
[From the completion agent: full matrix of story / criterion / status]

## Devil's Advocate Analysis
### Severity Challenges
### Contradictions
### Shared Blind Spots
### Calibration

## Action Items
### Tier 1 — Mechanically Verified (act with high confidence)
- MUST FIX: ...
- SHOULD FIX: ...
### Tier 2 — Debate-Tested (review for context fit)
- MUST FIX / SHOULD FIX / CONSIDER: ...
### Tier 3 — Judgment Required (evaluate trade-offs)
- [finding] — Counter-argument: [DA] — Decision: [what the human must decide]

## Enhancement Backlog
[From product owner, organized by effort/impact]

## Sign-Off Recommendation
- APPROVE: no Tier 1 MUST FIX items, all acceptance criteria pass
- CONDITIONAL: only Tier 2/3 items remain; Tier 3 flagged for human review
- BLOCK: unresolved Tier 1 MUST FIX items or Tier 1 acceptance criteria failures
```

### 6. Update the PRD with review results

1. Add a `findings` array to each affected user story:
   ```json
   "findings": [
     {"source": "security", "tier": 1, "severity": "must_fix",
      "description": "Upload handler skips content-type validation", "status": "open"}
   ]
   ```
2. Set the PRD's `review` object:
   ```json
   "review": {"signOff": "APPROVE|CONDITIONAL|BLOCK",
              "reportPath": "docs/wiki/sources/YYYY-MM-DD-<sprint>-review.md",
              "reviewDate": "YYYY-MM-DD"}
   ```
3. Commit the report, index, and PRD.

## After the Review

- Fix Tier 1 MUST FIX items before proceeding; mark them `done` in the PRD
- Quick Tier 2 items: fix in the same session while context is fresh
- Tier 3 items and enhancement ideas: append to `docs/backlog.md` if the
  project keeps one
- Then run `/wiki-ingest`, then `./workflow/scripts/sprint-finish.sh`
- Update `CLAUDE.md` and wiki pages if conventions or architecture changed
- Refine review agent files based on what was signal vs noise

## What NOT To Do

- Do NOT skip the devil's advocate. It is the most valuable part.
- Do NOT run review agents sequentially. They are independent; run in parallel.
- Do NOT let agents re-run the test suite. Pass the Step 2 output instead.
- Do NOT auto-resolve Tier 3 items. Those need human judgment.
- Do NOT review a sprint that isn't substantially complete. Finish the stories
  first.
- Do NOT edit a report after filing it in `sources/`. Corrections go in a new
  source.
