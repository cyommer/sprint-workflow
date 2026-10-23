# Wiki Conventions

Rules that keep `docs/wiki/` efficient, findable, and maintainable. Every page-writing or page-editing operation must follow these.

## Purpose

The wiki is the **knowledge layer** of the project — a curated synthesis of how the system works, what's current, and what's happened. Separate from the **execution layer** (PRDs, sprint specs, implementation plans) which is ephemeral and consumed by `ralph.sh`.

Knowledge belongs in the wiki. Execution artifacts stay in `docs/specs/`, `docs/plans/` and `docs/prds/`.

## Structure

```
docs/wiki/
├── CONVENTIONS.md    ← this file
├── index.md          ← content catalog (always read first)
├── state.md          ← current project snapshot
├── log.md            ← append-only chronological record
├── entities/         ← one page per concrete thing (User, Invoice, SearchIndex, …)
├── concepts/         ← cross-cutting topics (auth-flow, caching-strategy, …)
└── sources/          ← immutable inputs, filed by date (phase reviews, design docs)
```

### What goes where

- **`entities/`** — *things with boundaries*: a model, a view, a reusable component, a named subsystem. Each page answers "what is this thing and what do I need to know to work with it?"
- **`concepts/`** — *topics that cross multiple entities*. If a fact needs to be referenced from 3+ entity pages, it belongs in a concept page.
- **`sources/`** — *immutable inputs*: phase reviews, external research, design snapshots. Filename format: `YYYY-MM-DD-short-name.md`. Never edited after creation; corrections go in a new source.

## Hard rules

### Page size budget

- **Target:** 50–150 lines per page for `entities/` and `concepts/`.
- **Below 30 lines:** merge up into a parent page.
- **Above 200 lines:** split. If you can't split, the topic is too broad — reshape it.
- `sources/` and `CONVENTIONS.md` are exempt (sources are whatever arrives; this file is the schema).

### One concept per page

Every page has a single clear subject. If a page needs two unrelated top-level headers, it's two pages.

### Link discipline (retrieval rule)

When reading the wiki to gather context for a task:

- **Follow cross-references only when directly needed for the current task.** Do not preemptively load linked pages.
- Treat links as pointers, not inclusions.
- If you find yourself loading 5+ pages for one task, stop — either the task scope is too broad, or a concept page is missing.

### No duplication of facts

A given fact should live in exactly one place. Prefer: concept page owns the fact; entity pages link to it. Duplicated prose is flagged by lint.

### Index format

`index.md` entries are **one line each** — title, path, one-line summary. No more:

```markdown
- [Rate Limiter](entities/rate-limiter.md) — token bucket per API key, middleware hook, config knobs
```

The index must stay cheap enough to load on every session.

### SessionStart payload budget

`index.md` + `state.md` combined must stay **under 200 lines total**. They are loaded on every session via the SessionStart hook and count against every task's context window. Treat as a critical resource.

## Writing discipline for `state.md` and `log.md`

These two files sit at the top of every session (via the SessionStart hook) so their discipline is stricter than regular pages — drift in either is immediately visible to every task.

### `state.md`

**Contents:**

- **Active Sprint** — name, branch, status, story count (empty when no sprint is active)
- **Recent Completion** — 1–2 paragraphs about what just shipped
- **Next Up** — critical path in priority order
- **Opportunistic** — side tasks, not blocking

**Does NOT contain:** historical details (→ `log.md`), open questions (→ `backlog.md`), architectural decisions (→ entity/concept pages or `roadmap.md`).

**Update triggers:**

- **Sprint start** — `sprint-start.sh` writes "Active Sprint".
- **Sprint finish** — ingest step updates "Recent Completion" and clears "Active Sprint"; adjusts "Next Up".
- **Mid-sprint** — only when direction changes materially. In-progress details belong in the conversation or log entries, not here.

**Size guard:** stay under 80 lines so `index.md + state.md` fits the 200-line SessionStart budget.

### `log.md`

Append-only chronological record of significant events.

**What goes in:** sprint starts, sprint finishes, wrap-ups, sprint reviews, ingest operations, lint passes, major wiki operations (scaffold, migration, reorganization), external inputs (design docs, gist ingests, external reviews), backlog triage sessions, significant course corrections.

**Does NOT contain:** every commit (use `git log`), every conversation, per-story implementation details (those live in sprint reviews under `sources/`).

**Entry format:**

```
## [YYYY-MM-DD] <type> | <short description>

<1–2 paragraphs: what happened, why it matters, where to find more detail>
```

Valid types: `sprint-start`, `sprint-finish`, `wrap-up`, `sprint-review`, `ingest`, `lint`, `wiki-op`, `backlog-triage`, `external`.

**Cadence:** expect 3–8 entries per sprint. Grows monotonically.

**Append-only:** never edit existing entries. If a past entry was wrong, file a correction as a new entry referencing the original by date.

**Archival:** when `log.md` exceeds ~500 lines, move pre-year entries to `log-YYYY.md` and link from the top.

## Operations

### Ingest — after a phase review or external input

1. File the source in `sources/YYYY-MM-DD-<name>.md` (immutable).
2. Identify affected entity and concept pages.
3. Update those pages. Flag unresolved contradictions with `<!-- contradicts: sources/X.md -->`.
4. Update `index.md` if new pages were created.
5. Append an entry to `log.md`.

A single ingest may touch 5–10 wiki pages. That's expected.

### Lint — periodic, every 3 sprints or on demand

Run `/lint-wiki`. Agent reads the full wiki and flags:

- Contradictions between pages
- Stale claims (references to renamed/deleted code, outdated fields, etc.)
- Orphan pages (no inbound links)
- Broken cross-references
- Duplicated prose across pages
- Pages over the size budget
- Undocumented subsystems (code with no entity/concept coverage)

Output: a findings file. Findings triage into the backlog or get fixed inline.

### Query — during any task

1. Read `index.md` (usually already loaded via SessionStart hook).
2. Identify 1–3 relevant pages. Prefer specific entity pages over broad concept pages.
3. Load only those pages. Do not load siblings speculatively.
4. If a loaded page references another and you *need* that information, load it then — not before.

## Non-goals

- Not a replacement for reading source code. The wiki is a navigation aid and context primer, not a substitute for Grep/Read on actual files.
- Not for execution artifacts. PRDs, sprint specs, implementation plans stay in `docs/prds/`, `docs/specs/` and `docs/plans/`.
- Not a human-only resource. Designed for LLM retrieval first, human browsing second.
