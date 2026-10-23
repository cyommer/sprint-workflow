---
name: lint-wiki
description: >
  Drift detector for the wiki knowledge layer (docs/wiki/). Runs six checks:
  broken internal links, oversized pages (>200 lines), orphaned pages not linked
  from index.md, stub markers persisting too long, sprint-finish coverage (every
  complete sprint in workflow.db must have a log.md entry), and high skip-ingest
  rate. Produces a structured report with severity levels. Use when the user
  asks to lint, audit, or check wiki health, or periodically between sprints.
  Invoke via /lint-wiki.
---

# Lint Wiki

Detect drift and systematic bypass in the wiki (`wikiDir` in
`workflow/config.json`, default `docs/wiki/`). Six objective checks, one
severity-tagged report. No age-based staleness heuristics: age is not a proxy
for correctness, and those checks train people to ignore output.

## When to Use

- Between sprints, as a lightweight audit
- Before writing the next PRD
- When the user reports "the wiki feels off" or asks to lint
- After a `sprint-finish.sh --skip-ingest`, to confirm the skip was isolated
  rather than systematic

## The Six Checks

Run each check and collect findings. Report at the end with severity levels:
**ERROR** (must-fix), **WARN** (should-fix), **INFO** (consider).

Set `WIKI=$(workflow/scripts/get-config.py wikiDir)` first; the snippets below
assume `docs/wiki`.

### Check 1: Broken internal links (ERROR)

Scan every `.md` file under the wiki for markdown links to other `.md` files
and verify each target exists relative to the source file.

```bash
grep -rEn '\]\([^)]+\.md\)' docs/wiki/ --include='*.md'
```

For each hit, resolve the link target relative to the source file's directory
and check existence. Ignore links starting with `http`.

Report: `ERROR: docs/wiki/<source>:<line> -> <target> (missing)`

### Check 2: Oversized pages (WARN)

Per `docs/wiki/CONVENTIONS.md`, `entities/` and `concepts/` pages stay under
200 lines. `sources/` and `CONVENTIONS.md` are exempt: sources are immutable
inputs whose size is whatever arrives, and CONVENTIONS.md is the schema.

```bash
find docs/wiki -name '*.md' -type f \
    | grep -vE '^docs/wiki/(sources/|CONVENTIONS\.md$)' \
    | while read f; do
        lines=$(wc -l < "$f")
        [ "$lines" -gt 200 ] && echo "$lines $f"
    done
```

Report: `WARN: <path> is <lines> lines (budget: 200)`

### Check 3: Orphaned pages (WARN)

Every `.md` under the wiki (except `index.md`, `state.md`, `log.md`,
`CONVENTIONS.md`, and any `README.md`) must be referenced from `index.md`.
`README.md` files are directory scaffolds, not content pages.

```bash
find docs/wiki -name '*.md' -type f \
    | grep -vE '/(index|state|log|CONVENTIONS|README)\.md$' \
    | while read f; do
        rel=${f#docs/wiki/}
        stem=$(basename "$f" .md)
        grep -q -E "($rel|$stem)" docs/wiki/index.md || echo "ORPHAN: $rel"
    done
```

Report: `WARN: <path> is orphaned (not linked from index.md)`

### Check 4: Stub markers persisting too long (INFO)

Stub placeholders (`_More X to come..._`, `_No pages yet_`, `TODO:`, `FIXME:`)
that have persisted across more than 2 sprint-finish entries.

The placeholder pattern uses a non-greedy interior to tolerate punctuation and
embedded markdown; a stricter `[^_]*` misses placeholders whose interior text
contains an underscore.

```bash
grep -rn -E '_More.*?to come[^_]*_|_No pages yet_|TODO:|FIXME:' docs/wiki/ --include='*.md'
```

For each hit, `git blame` the line to find when the marker was introduced, then
count `sprint-finish:` entries in `log.md` since that date. Report if more
than 2.

```bash
git blame -L <line>,<line> <file>
grep -c '^## .* sprint-finish: ' docs/wiki/log.md
```

Report: `INFO: <path>:<line> stub marker persisted across <N> sprints`

### Check 5: Sprint-finish coverage (ERROR)

Every sprint completed **on or after the enforcement gate went live** must have
a matching `sprint-finish: <name>` entry (clean or `(skipped)`) in `log.md`.

**Cutoff rule (derived, not hardcoded):** the cutoff is the date of the
*earliest* `sprint-finish:` sigil in `log.md`. Sprints completed before that
date predate the gate and are accepted as historical debt; no retroactive
backfill. Deriving the cutoff from the log makes the check self-adjusting: on a
new project or after a wiki migration, the cutoff becomes that project's first
real ingest.

If no `sprint-finish:` sigil exists yet, the check is a no-op.

```bash
CUTOFF=$(grep -oE '^## [0-9]{4}-[0-9]{2}-[0-9]{2} — sprint-finish:' docs/wiki/log.md \
    | awk '{print $2}' | sort | head -1)

if [ -z "$CUTOFF" ]; then
    echo "INFO: no sprint-finish sigils in log.md — enforcement gate has not run yet"
else
    source workflow/lib.sh
    db_query "SELECT name FROM sprints WHERE status='complete' AND date(completed_at) >= date('${CUTOFF}');" \
        | while read sprint; do
            grep -qE "^## .* sprint-finish: ${sprint}( \(skipped\))?\$" docs/wiki/log.md \
                || echo "ERROR: sprint '${sprint}' completed on or after ${CUTOFF} but missing from log.md"
        done
fi
```

`db_query` comes from `workflow/lib.sh` and works with or without the
`sqlite3` CLI installed.

Report: `ERROR: sprint '<name>' completed in DB but missing from log.md`

### Check 6: High skip-ingest rate (WARN)

Count `(skipped)` entries among the last 10 sprint-finish entries. Warn if more
than 20% were skipped.

```bash
LAST10=$(grep '^## .* sprint-finish: ' docs/wiki/log.md | tail -10)
skipped=$(printf '%s\n' "$LAST10" | grep -c '(skipped)')
total=$(printf '%s\n' "$LAST10" | grep -c .)
if [ "$total" -gt 0 ] && [ $((skipped * 100 / total)) -gt 20 ]; then
    echo "WARN: ${skipped} of last ${total} sprint-finish entries skipped"
fi
```

Report: `WARN: <N> of last 10 sprint-finish entries were skipped (>20% threshold)`

## Report Format

```markdown
# Wiki Lint Report — YYYY-MM-DD

## Summary
- N ERROR, M WARN, K INFO

## Errors
<ERROR findings>

## Warnings
<WARN findings>

## Info
<INFO findings>

## Clean
<checks that passed with zero findings>
```

Optionally append a `## YYYY-MM-DD lint | <summary>` entry to `log.md`.

## What NOT To Check

- **Age-based staleness.** "Page not touched in 90 days" is a bad proxy for
  correctness. Do not add this check without explicit design review. The noise
  ratio is worse than skipping it.
- **Content quality.** Grammar, clarity, tone are judgment calls, not lint.
- **External link validity.** http/https liveness is out of scope.
- **CONVENTIONS.md conformance beyond page size.** Formatting discipline is
  developer responsibility, not lint.
