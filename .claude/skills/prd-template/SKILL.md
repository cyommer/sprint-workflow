---
name: prd-template
description: >
  Generate consistent PRD JSON files for sprint planning. Ensures every PRD has
  the same structure, required fields, and conventions. Use when creating a new
  PRD during planning sessions, or when the user says "create prd", "new prd",
  "write the prd".
---

# PRD Template

When generating a PRD for a new sprint, follow this exact structure. PRDs are
JSON files stored at `prdPath` from `workflow/config.json` (default
`docs/prds/current.json`) while active, and archived to `docs/prds/archive/`
by `sprint-finish.sh` after sprint completion.

The PRD is the contract between planning and execution. `sprint-start.sh` reads
it to create the branch and DB records. `ralph.sh` and `generate-prompt.py`
read it for story definitions. **No PRD = no sprint.**

## Canonical Structure

```json
{
  "sprintName": "<kebab-case-name>",
  "description": "<1-3 sentence summary of what this sprint delivers and why>",
  "contextFiles": [
    "docs/specs/YYYY-MM-DD-<topic>-design.md",
    "<other docs the implementing agent must read for every story>"
  ],
  "prerequisites": [
    "<things that must be true before starting: open bugs, branch state, etc.>"
  ],
  "userStories": [
    {
      "id": "US-001",
      "title": "<imperative phrase: Add X, Create Y, Fix Z>",
      "description": "As a <role>, I want <goal> so that <benefit>.",
      "acceptanceCriteria": [
        "<specific, testable statements; see conventions below>",
        "Quality gate: the project's full test command (qualityGates.testAll in workflow/config.json) passes with 0 failures"
      ],
      "priority": 1,
      "passes": false,
      "wikiPages": [
        "entities/<relevant-entity>.md",
        "concepts/<relevant-concept>.md"
      ],
      "testScope": "<optional: test path/glob, or \"manual\">",
      "notes": "<implementation hints, dependencies, gotchas; optional>"
    }
  ],
  "deferred": [
    {
      "item": "<what was considered but cut>",
      "reason": "<why: complexity, uncertainty, lower priority>"
    }
  ]
}
```

## Required Fields

| Field | Required | Notes |
|-------|----------|-------|
| `sprintName` | Yes | Kebab-case, descriptive (e.g., `search-indexing`, `notification-polish`) |
| `description` | Yes | What + why in 1-3 sentences |
| `contextFiles` | Yes | Paths to the spec and any docs the agent should read for every story |
| `userStories` | Yes | At least 1 story |
| `wikiPages` (per story) | Yes | Paths relative to `wikiDir`. Empty array allowed for wiki-independent stories. `ralph.sh` loads these at story start. |
| `testScope` (per story) | No | A test path or glob substituted for `{targets}` in `qualityGates.test`, or the string `"manual"` for stories with no automated tests (skips the TDD instructions and the test gate for that story). Omit to let the agent run the test files it created or modified. |
| `prerequisites` | No | Omit if none. Include open bugs that should be fixed first |
| `deferred` | No | Omit if nothing was explicitly cut |

## Fields NOT Included (and why)

| Field | Why omitted |
|-------|-------------|
| `project` | Always `projectName` from config; redundant |
| `branchName` | Derived by `sprint-start.sh` as `sprint/<sprintName>` |
| `techStack` | Documented in `CLAUDE.md`, never changes per sprint |
| `qualityGates` | Live in `workflow/config.json`; `generate-prompt.py` injects them |

## Post-Sprint Fields (added after implementation + review)

After `/phase-review` completes, the PRD is updated with:

```json
{
  "review": {
    "signOff": "APPROVE | CONDITIONAL | BLOCK",
    "reportPath": "docs/wiki/sources/<date>-<sprint-name>-review.md",
    "reviewDate": "<YYYY-MM-DD>"
  }
}
```

and each story gains a `findings` array:

```json
"findings": [
  {
    "source": "<agent that found it: security, architecture, product_owner, dx, completion, ...>",
    "tier": 1,
    "severity": "must_fix | should_fix | consider",
    "description": "<what's wrong and where>",
    "status": "open | done | deferred"
  }
]
```

These are populated by `/phase-review`, not during planning.

## Story Conventions

### Story IDs
- Sequential: `US-001`, `US-002`, ...
- Reset to `US-001` for each sprint (IDs are sprint-scoped)

### Story Titles
- Start with a verb: Add, Create, Fix, Update, Remove, Implement
- Be specific: "Add pin toggle endpoint" not "Handle pinning"

### Story Descriptions
- "As a <role>" format. Roles are project-specific; define them once in
  `CLAUDE.md` and reuse them (e.g., developer, end user, admin).
- The "so that" clause states the user benefit, not the implementation.

### Priority
- Integer starting at 1 (highest priority, implement first)
- Order stories so dependencies come first; ralph processes them in story-ID
  order, so IDs and priorities should agree

### Acceptance Criteria

**Be specific and testable.** Each criterion must be verifiable by reading code
or running a test.

Mix these per story:

1. **Implementation criteria** — what the code must do:
   ```
   "POST /items/<id>/pin toggles the item's pinned field"
   "Returns 403 if the caller doesn't own the item"
   "Route registered with name 'toggle_pin'"
   ```

2. **Test criteria** — explicit test cases, prefixed `Test:`:
   ```
   "Test: toggle from unpinned to pinned"
   "Test: ownership required (other user's item returns 403)"
   ```
   `generate-prompt.py` detects `Test:` criteria to decide whether to inject
   TDD instructions. A criterion containing the word "manual" (e.g.
   `"Test: manual check in two browsers"`) does not count as automated.

3. **Quality gate** — always the last criterion:
   ```
   "Quality gate: the project's full test command (qualityGates.testAll in workflow/config.json) passes with 0 failures"
   ```

Criteria should NOT:
- Be vague: "Works correctly" / "Handles errors properly"
- Duplicate other criteria with different wording
- Include implementation details that don't affect behavior (variable names)

### wikiPages

Lists the wiki pages the story depends on. `ralph.sh` loads them into the
agent's context at story start, before the implementation prompt runs. This is
per-story context, not sprint-wide.

**Path format:** relative to `wikiDir`, e.g. `entities/search-index.md` or
`concepts/auth-flow.md`. No leading `/`, no `docs/wiki/` prefix.

**When to populate:** any story touching a documented entity or concept. If the
story changes shared sprint process, include `concepts/sprint-workflow.md`.

**When to leave empty:** genuinely wiki-independent stories (version bumps,
pure infrastructure, CI-only changes). Empty arrays are allowed but flagged by
`/lint-wiki` as worth double-checking.

**Format:** flat array of strings. Explain the "why" in `description` or
`notes`, not in the array.

### Context Files

`contextFiles` is sprint-wide: the spec from planning plus any document every
story needs. Keep it short. Story-specific knowledge belongs in that story's
`wikiPages`, so each story loads only what it needs.

### Notes
- Optional but valuable for complex stories
- Include: dependencies on other stories, implementation hints, gotchas,
  references to spec sections
- Do NOT duplicate acceptance criteria

## Deferred Items

Explicitly track what was considered but cut:

```json
{
  "item": "Drag-and-drop reordering",
  "reason": "Needs a drag library. Manual ordering field is sufficient for now."
}
```

This creates a paper trail for scope decisions and feeds the backlog.

## Workflow Integration

1. **Planning:** create the PRD at `prdPath` following this template
2. **Sprint start:** `./workflow/scripts/sprint-start.sh <sprintName>` reads it
3. **Implementation:** `ralph.sh` and `generate-prompt.py` read stories,
   `contextFiles`, and `wikiPages`
4. **Review:** `/phase-review` populates the `review` section and `findings`
5. **Finish:** `./workflow/scripts/sprint-finish.sh` archives it to
   `docs/prds/archive/YYYY-MM-DD-<sprintName>.json`

## Checklist

Before starting a sprint with this PRD:

- [ ] `sprintName` is kebab-case and descriptive
- [ ] `description` explains what AND why
- [ ] `contextFiles` includes the spec and any sprint-wide docs
- [ ] Every story has a unique `US-XXX` ID
- [ ] Stories are ordered by dependency (lower numbers first)
- [ ] Every story has at least one `Test:` criterion, or `"testScope": "manual"`
- [ ] Every story ends with the quality gate criterion
- [ ] Every story has a `wikiPages` field (empty array allowed but flagged)
- [ ] `notes` explains dependencies and gotchas for complex stories
- [ ] `deferred` captures anything explicitly cut from scope
- [ ] `prerequisites` lists open bugs or branch requirements
