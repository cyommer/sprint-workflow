# Sprint Workflow

How sprints progress from planning to merge, and where the knowledge layer (`docs/wiki/`) fits alongside the execution layer (`docs/prds/`, `docs/specs/`, `docs/plans/`, `workflow/workflow.db`).

## Two layers

- **Knowledge layer** — `docs/wiki/`, `docs/roadmap.md`, `docs/backlog.md`. What the system is and what's next. Compounds over time. Lint-checked.
- **Execution layer** — `docs/prds/`, `docs/specs/`, `docs/plans/`, `workflow/workflow.db`, sprint branches. Artifacts of a specific sprint. Ephemeral. Archived at sprint finish.

The separation matters: drift is only a problem in the knowledge layer (which persists). Execution artifacts get archived and never read again.

## The cycle

1. **Orient** — new session. The SessionStart hook (`.claude/hooks/session-start-wiki.sh`) injects `index.md` + `state.md` automatically.
2. **Brainstorm + spec** — interactive design. Context pulls are targeted via `grep docs/wiki/`. Spec written to `docs/specs/YYYY-MM-DD-<topic>-design.md`.
3. **PRD** — `/prd-template` produces `docs/prds/current.json`. Each story lists `wikiPages`; ralph loads them at story start.
4. **Plan** — `docs/plans/YYYY-MM-DD-<feature>.md`. TDD task breakdown with exact file paths, test commands, commit messages.
5. **Sprint start** — `./workflow/scripts/sprint-start.sh <name>` creates the sprint branch, seeds `workflow.db`, writes the "Active Sprint" section of `state.md`, appends a `sprint-start` entry to `log.md`.
6. **Ralph loop** — `./ralph.sh` iterates stories: branch, focused prompt, implement, quality gates, per-story review, merge to sprint branch.
7. **Phase review (new session)** — `/phase-review` dispatches review agents in parallel plus a devil's advocate. Verdict APPROVE / CONDITIONAL / BLOCK. Report filed as an immutable source at `docs/wiki/sources/YYYY-MM-DD-<sprint>-review.md`.
8. **Wrap-up + ingest** — Tier 1/2 findings fixed in-session. `/wiki-ingest` updates entity and concept pages, appends the `sprint-finish` sigil to `log.md`, updates `state.md`. Tier 3 findings go to `docs/backlog.md`.
9. **Sprint finish** — `./workflow/scripts/sprint-finish.sh` runs pre-finish gates, verifies the sigil, merges sprint → base branch, archives the PRD, deletes the branch.
10. **Cycle restarts** — next session's hook injects current state. No drift.

## Enforcement gates

Freshness depends on exactly two gates:

1. **SessionStart hook** — guarantees Claude sees current `state.md` and `index.md` every session. Read-side enforcement.
2. **`sprint-finish.sh`** — guarantees ingest happened before merge. Write-side enforcement.

Everything in between is advisory. If both gates hold, the wiki stays authoritative without per-step discipline.

## Scripts and skills

| Artifact | Purpose |
|---|---|
| `.claude/hooks/session-start-wiki.sh` | Inject wiki index + state at session start |
| `/sprint-plan` | Full planning sequence (orient → brainstorm → spec → PRD → plan → sprint-start) |
| `/prd-template` | PRD JSON generator; enforces `wikiPages` per story |
| `/phase-review` | Post-sprint multi-agent review; files report as a wiki source |
| `/wiki-ingest` | Propagate sprint changes into wiki pages; writes the sigil |
| `/lint-wiki` | Drift detector across the wiki |
| `workflow/scripts/sprint-start.sh` | Create sprint branch + seed DB + update `state.md` + append `log.md` |
| `workflow/scripts/sprint-finish.sh` | Pre-finish gates + ingest gate + merge + archive |
| `workflow/scripts/health-check.sh` | DB ↔ git ↔ PRD consistency |
| `./ralph.sh` | Execute sprint stories with targeted wiki context |

## Related

- [CONVENTIONS](../CONVENTIONS.md) — wiki structure, writing discipline, ingest/lint/query operations
- [State](../state.md), [Log](../log.md) — live top-of-session artifacts
