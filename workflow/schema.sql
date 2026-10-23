-- Workflow Infrastructure Schema
-- Solo-dev tooling for sprint lifecycle tracking.
-- Source of truth: PRD JSON files + git. This DB is a convenience index.
-- Rebuild: source workflow/lib.sh && rm workflow/workflow.db && db_init
--
-- Three tables: sprints (metadata), stories (ralph loop state),
-- story_progress (per-story build log). Findings and reviews live in
-- docs/ as markdown and in the PRD JSON, not here.

CREATE TABLE IF NOT EXISTS sprints (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    branch_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'planning'
        CHECK (status IN ('planning', 'active', 'review', 'complete')),
    prd_path TEXT,
    started_at TEXT,
    completed_at TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS stories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sprint_id INTEGER NOT NULL REFERENCES sprints(id),
    story_id TEXT NOT NULL,
    title TEXT NOT NULL,
    branch_name TEXT,
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'in_progress', 'passed', 'failed', 'blocked')),
    started_at TEXT,
    completed_at TEXT,
    UNIQUE (sprint_id, story_id)
);

CREATE TABLE IF NOT EXISTS story_progress (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sprint_id INTEGER NOT NULL REFERENCES sprints(id),
    story_id TEXT NOT NULL,
    files_changed TEXT,
    tests_modified TEXT,
    notes TEXT,
    recorded_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE (sprint_id, story_id)
);
