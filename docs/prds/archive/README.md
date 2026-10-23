# PRD Archive

`sprint-finish.sh` copies `current.json` here as `YYYY-MM-DD-<sprint-name>.json` and deletes `current.json`.

Archives are institutional memory:
- Pattern recognition across sprints (recurring finding types)
- Velocity tracking (stories per sprint)
- Context for the next PRD (what was deferred, which findings need follow-up)

Before writing a new PRD, skim the last two archives' `deferred` and `review.findings` arrays.
