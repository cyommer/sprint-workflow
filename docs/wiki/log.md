# Log

Append-only chronological record of ingests, sprint completions, lint passes, and wiki operations. Newest entries at the top.

Format: `## [YYYY-MM-DD] <type> | <short description>` for general entries.
Sprint-finish entries use the enforcement-contract sigil format: `## YYYY-MM-DD — sprint-finish: <sprint-name>` (the grep pattern in `sprint-finish.sh`).

Types: `sprint-start`, `sprint-finish`, `ingest`, `lint`, `wiki-op`, `backlog-triage`, `external`.

---
