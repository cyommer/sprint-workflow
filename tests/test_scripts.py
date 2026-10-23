"""End-to-end tests for the workflow scripts, run against a sandbox repo."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from conftest import KIT_ROOT, db, git, run, write_prd


# ── get-config / lib.sh ──────────────────────────────────────────────


class TestConfig:
    def test_scalar_and_default(self, sandbox_repo):
        assert run("source workflow/lib.sh && cfg baseBranch", sandbox_repo).stdout.strip() == "develop"
        assert run("source workflow/lib.sh && cfg nope fallback", sandbox_repo).stdout.strip() == "fallback"

    def test_list_prints_one_per_line(self, sandbox_repo):
        out = run("source workflow/lib.sh && cfg qualityGates.before", sandbox_repo).stdout
        assert out.splitlines() == ["echo lint"]

    def test_db_query_works_without_sqlite_cli(self, sandbox_repo):
        env = {"PATH": "/usr/bin:/bin", "HOME": "/tmp"}
        out = run(
            'source workflow/lib.sh && command -v sqlite3 >/dev/null && echo HAS_CLI; db_query "SELECT COUNT(*) FROM sprints;"',
            sandbox_repo,
            env=env,
        ).stdout
        # Either path must answer; when the CLI is absent, the python fallback does.
        assert out.strip().splitlines()[-1] == "0"


# ── sprint-start ─────────────────────────────────────────────────────


class TestSprintStart:
    def test_creates_branch_db_rows_and_wiki_state(self, active_sprint):
        assert git(active_sprint, "branch", "--show-current") == "sprint/fake-sprint"
        assert db(active_sprint, "SELECT name, status FROM sprints;") == "fake-sprint|active"
        assert db(active_sprint, "SELECT story_id, status FROM stories;") == "US-001|pending"
        state = (active_sprint / "docs/wiki/state.md").read_text()
        assert "**fake-sprint** — started" in state
        log = (active_sprint / "docs/wiki/log.md").read_text()
        assert "sprint-start: fake-sprint" in log
        assert git(active_sprint, "log", "-1", "--format=%s") == "Update wiki state: start sprint fake-sprint"

    def test_refuses_when_not_on_base_branch(self, sandbox_repo):
        write_prd(sandbox_repo)
        git(sandbox_repo, "checkout", "-q", "-b", "feature/stray")
        r = run(["bash", "workflow/scripts/sprint-start.sh", "x"], sandbox_repo, check=False)
        assert r.returncode == 1 and "Must be on 'develop'" in r.stderr

    def test_refuses_second_active_sprint(self, active_sprint):
        git(active_sprint, "checkout", "-q", "develop")
        r = run(["bash", "workflow/scripts/sprint-start.sh", "other"], active_sprint, check=False)
        assert r.returncode == 1 and "still active" in r.stderr

    def test_honors_custom_base_branch(self, sandbox_repo):
        cfg_path = sandbox_repo / "workflow/config.json"
        cfg = json.loads(cfg_path.read_text())
        cfg["baseBranch"] = "main"
        cfg_path.write_text(json.dumps(cfg))
        git(sandbox_repo, "commit", "-qam", "base=main")
        git(sandbox_repo, "checkout", "-q", "main")
        git(sandbox_repo, "merge", "-q", "develop")
        write_prd(sandbox_repo, "on-main")
        run(["bash", "workflow/scripts/sprint-start.sh", "on-main"], sandbox_repo)
        assert git(sandbox_repo, "branch", "--show-current") == "sprint/on-main"


# ── sprint-finish ────────────────────────────────────────────────────


def _append_sigil(sandbox: Path, name: str) -> None:
    log = sandbox / "docs/wiki/log.md"
    log.write_text(log.read_text() + f"\n## 2026-01-01 — sprint-finish: {name}\nUpdated: entities/foo.md\n")
    git(sandbox, "add", "docs/wiki/log.md")
    git(sandbox, "commit", "-q", "-m", "ingest")


class TestSprintFinish:
    def test_blocks_without_sigil(self, active_sprint):
        r = run(["bash", "workflow/scripts/sprint-finish.sh", "--yes"], active_sprint, check=False)
        assert r.returncode == 1 and "Ingest not verified" in r.stderr
        assert git(active_sprint, "branch", "--show-current") == "sprint/fake-sprint"

    def test_full_finish_with_sigil(self, active_sprint):
        db(active_sprint, "UPDATE stories SET status='passed';")
        _append_sigil(active_sprint, "fake-sprint")
        r = run(["bash", "workflow/scripts/sprint-finish.sh", "--yes"], active_sprint)
        assert "Ingest verified" in r.stdout
        assert git(active_sprint, "branch", "--show-current") == "develop"
        assert db(active_sprint, "SELECT status FROM sprints;") == "complete"
        assert not (active_sprint / "docs/prds/current.json").exists()
        archived = list((active_sprint / "docs/prds/archive").glob("*-fake-sprint.json"))
        assert len(archived) == 1
        assert "sprint/fake-sprint" not in git(active_sprint, "branch", "--list")

    def test_skip_ingest_logs_skipped_entry(self, active_sprint):
        run(["bash", "workflow/scripts/sprint-finish.sh", "--yes", "--skip-ingest"], active_sprint)
        log = (active_sprint / "docs/wiki/log.md").read_text()
        assert "sprint-finish: fake-sprint (skipped)" in log

    def test_pre_finish_gate_failure_blocks(self, active_sprint):
        cfg_path = active_sprint / "workflow/config.json"
        cfg = json.loads(cfg_path.read_text())
        cfg["preFinishGates"] = {"commands": ["false"]}
        cfg_path.write_text(json.dumps(cfg))
        git(active_sprint, "commit", "-qam", "failing gate")
        _append_sigil(active_sprint, "fake-sprint")
        r = run(["bash", "workflow/scripts/sprint-finish.sh", "--yes"], active_sprint, check=False)
        assert r.returncode == 1 and "Pre-finish gate failed" in r.stderr


# ── health-check ─────────────────────────────────────────────────────


class TestHealthCheck:
    def test_clean_sprint_passes(self, active_sprint):
        r = run(["bash", "workflow/scripts/health-check.sh"], active_sprint)
        assert "All checks passed" in r.stdout

    def test_detects_db_prd_mismatch(self, active_sprint):
        db(active_sprint, "UPDATE stories SET status='passed';")
        r = run(["bash", "workflow/scripts/health-check.sh"], active_sprint, check=False)
        assert r.returncode == 1 and "DB=passed but PRD passes=false" in r.stdout

    def test_no_active_sprint(self, sandbox_repo):
        r = run(["bash", "workflow/scripts/health-check.sh"], sandbox_repo)
        assert "No active sprint" in r.stdout


# ── generate-prompt ──────────────────────────────────────────────────


def _gen(sandbox: Path, story_id: str = "US-001") -> subprocess.CompletedProcess:
    return run(["python3", "workflow/scripts/generate-prompt.py", "--story", story_id, "--prd", "docs/prds/current.json"], sandbox)


class TestGeneratePrompt:
    def test_gates_pattern_table_and_criteria(self, active_sprint):
        out = _gen(active_sprint).stdout
        assert "echo lint" in out and "echo after" in out
        assert "echo test <test files you created or modified>" in out
        assert "| Writing tests | .claude/skills/testing/SKILL.md |" in out
        assert "- Test: thing works" in out
        assert "<promise>BLOCKED</promise>" in out
        assert "Write failing tests FIRST" in out

    def test_test_scope_substitutes_targets(self, sandbox_repo):
        write_prd(sandbox_repo, stories=[{
            "id": "US-001", "title": "T", "acceptanceCriteria": ["Test: x"], "passes": False,
            "testScope": "tests/test_x.py",
        }])
        out = _gen(sandbox_repo).stdout
        assert "echo test tests/test_x.py" in out

    def test_manual_story_skips_tdd_and_tests(self, sandbox_repo):
        write_prd(sandbox_repo, stories=[{
            "id": "US-001", "title": "T", "acceptanceCriteria": ["Manual: looks right"], "passes": False,
            "testScope": "manual",
        }])
        out = _gen(sandbox_repo).stdout
        assert "no automated tests" in out
        assert "echo test" not in out
        assert "echo lint" in out

    def test_wiki_pages_inlined_with_hook_header_format(self, sandbox_repo):
        (sandbox_repo / "docs/wiki/entities/foo.md").write_text("# Foo\n\nFoo facts.\n")
        write_prd(sandbox_repo, stories=[{
            "id": "US-001", "title": "T", "acceptanceCriteria": ["Test: x"], "passes": False,
            "wikiPages": ["entities/foo.md", "entities/missing.md"],
        }])
        r = _gen(sandbox_repo)
        assert "=== docs/wiki/entities/foo.md ===" in r.stdout
        assert "Foo facts." in r.stdout
        assert "wikiPages entry not found: docs/wiki/entities/missing.md" in r.stderr

    def test_unknown_story_fails(self, active_sprint):
        r = run(["python3", "workflow/scripts/generate-prompt.py", "--story", "US-999", "--prd", "docs/prds/current.json"], active_sprint, check=False)
        assert r.returncode == 1


# ── check-promise ────────────────────────────────────────────────────


class TestCheckPromise:
    def _log(self, tmp_path: Path, events: list[dict]) -> Path:
        p = tmp_path / "log.jsonl"
        p.write_text("\n".join(json.dumps(e) for e in events) + "\n")
        return p

    def test_found_in_assistant_text(self, tmp_path):
        log = self._log(tmp_path, [{"type": "assistant", "message": {"content": [{"type": "text", "text": "done <promise>BLOCKED</promise>"}]}}])
        r = subprocess.run(["python3", str(KIT_ROOT / "workflow/scripts/check-promise.py"), str(log), "<promise>BLOCKED</promise>"])
        assert r.returncode == 0

    def test_ignored_in_tool_input_and_results(self, tmp_path):
        log = self._log(tmp_path, [
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": "echo '<promise>BLOCKED</promise>'"}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "<promise>BLOCKED</promise>"}]}},
        ])
        r = subprocess.run(["python3", str(KIT_ROOT / "workflow/scripts/check-promise.py"), str(log), "<promise>BLOCKED</promise>"])
        assert r.returncode == 1


# ── install.sh ───────────────────────────────────────────────────────


class TestInstall:
    def test_install_is_idempotent_and_substitutes_project_name(self, sandbox_repo):
        agent = (sandbox_repo / ".claude/review-agents/security-review.md").read_text()
        assert "{{PROJECT_NAME}}" not in agent and "Sandbox" in agent
        gi = (sandbox_repo / ".gitignore").read_text()
        assert "workflow/workflow.db" in gi
        r = run([str(KIT_ROOT / "install.sh"), str(sandbox_repo)], sandbox_repo)
        assert "0 files added" in r.stdout

    def test_session_start_hook_emits_index_and_state(self, sandbox_repo):
        r = run(["bash", ".claude/hooks/session-start-wiki.sh"], sandbox_repo)
        assert "=== docs/wiki/index.md" in r.stdout and "=== docs/wiki/state.md" in r.stdout
        assert "## Active Sprint" in r.stdout
