"""Sandbox fixtures for the workflow scripts.

`sandbox_repo` builds an isolated git repo in tmp_path with the kit installed
via install.sh, a seeded docs/wiki/, a base branch, and a workflow.db created
from schema.sql. Tests run the real scripts via subprocess with the sandbox
as cwd, so they exercise exactly what an adopter would run.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

KIT_ROOT = Path(__file__).resolve().parents[1]


def run(cmd, cwd: Path, check: bool = True, **kwargs) -> subprocess.CompletedProcess:
    if isinstance(cmd, str):
        kwargs.setdefault("shell", True)
        kwargs.setdefault("executable", "/bin/bash")
    return subprocess.run(cmd, cwd=cwd, check=check, capture_output=True, text=True, **kwargs)


def git(sandbox: Path, *args: str, check: bool = True) -> str:
    return run(["git", *args], sandbox, check=check).stdout.strip()


def db(sandbox: Path, sql: str) -> str:
    """Run SQL through the kit's db_query helper (sqlite3 CLI or python fallback)."""
    return run(f'source workflow/lib.sh && db_query "{sql}"', sandbox).stdout.strip()


def write_prd(sandbox: Path, name: str = "fake-sprint", stories: list | None = None) -> Path:
    if stories is None:
        stories = [
            {
                "id": "US-001",
                "title": "Add a thing",
                "description": "As a dev...",
                "acceptanceCriteria": ["Thing exists", "Test: thing works"],
                "priority": 1,
                "passes": False,
                "wikiPages": [],
            }
        ]
    prd_dir = sandbox / "docs" / "prds"
    prd_dir.mkdir(parents=True, exist_ok=True)
    prd = prd_dir / "current.json"
    prd.write_text(json.dumps({"sprintName": name, "contextFiles": [], "userStories": stories}, indent=2))
    git(sandbox, "add", "docs/prds/current.json")
    git(sandbox, "commit", "-q", "-m", f"PRD for {name}")
    return prd


@pytest.fixture
def sandbox_repo(tmp_path: Path) -> Path:
    sandbox = tmp_path / "sandbox"
    sandbox.mkdir()
    run(["git", "init", "-b", "main", "--quiet"], sandbox)
    run(["git", "config", "user.email", "test@example.com"], sandbox)
    run(["git", "config", "user.name", "Test"], sandbox)
    run(["git", "config", "commit.gpgsign", "false"], sandbox)
    (sandbox / "README.md").write_text("sandbox\n")
    (sandbox / "CLAUDE.md").write_text("# Sandbox\n")
    git(sandbox, "add", ".")
    git(sandbox, "commit", "-q", "-m", "initial")
    git(sandbox, "checkout", "-q", "-b", "develop")

    # Install the kit the way an adopter would
    run([str(KIT_ROOT / "install.sh"), str(sandbox), "--project-name", "Sandbox"], sandbox)
    # Real-looking quality gates so generated prompts have content to assert on
    cfg_path = sandbox / "workflow" / "config.json"
    cfg = json.loads(cfg_path.read_text())
    cfg["qualityGates"] = {
        "before": ["echo lint"],
        "test": "echo test {targets}",
        "testAll": "echo test-all",
        "after": ["echo after"],
    }
    cfg["patternSkills"] = {"rows": [{"when": "Writing tests", "read": ".claude/skills/testing/SKILL.md"}]}
    cfg_path.write_text(json.dumps(cfg, indent=2))

    git(sandbox, "add", ".")
    git(sandbox, "commit", "-q", "-m", "install workflow kit")
    run("source workflow/lib.sh && db_init", sandbox)
    return sandbox


@pytest.fixture
def active_sprint(sandbox_repo: Path) -> Path:
    """A sandbox with a PRD committed and sprint-start.sh already run."""
    write_prd(sandbox_repo)
    run(["bash", "workflow/scripts/sprint-start.sh", "fake-sprint"], sandbox_repo)
    return sandbox_repo
