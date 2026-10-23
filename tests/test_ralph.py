"""End-to-end ralph.sh runs against a stub `claude` binary.

The stub reads the prompt on stdin. For an implementation prompt it writes a
test file, flips the story's `passes` flag, commits, and prints a stream-json
assistant message. For a review prompt it prints <review>PASS</review>. A
STUB_MODE env var switches it to emit <promise>BLOCKED</promise> instead.
"""

from __future__ import annotations

import os
import stat
from pathlib import Path

from conftest import db, git, run, write_prd

STUB = r'''#!/bin/bash
prompt=$(cat)
say() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$1"; }
if echo "$prompt" | grep -q "You are reviewing the implementation"; then
  say "<review>PASS</review>"; exit 0
fi
sid=$(echo "$prompt" | grep -oE 'You are implementing US-[0-9]+' | grep -oE 'US-[0-9]+')
if [[ "${STUB_MODE:-}" == "blocked" ]]; then
  say "gates failed three times <promise>BLOCKED</promise>"; exit 0
fi
echo "def test_${sid//-/_}(): pass" > "test_${sid}.py"
python3 - "$sid" <<'PY'
import json, sys
p = "docs/prds/current.json"; prd = json.load(open(p))
for s in prd["userStories"]:
    if s["id"] == sys.argv[1]:
        s["passes"] = True
json.dump(prd, open(p, "w"), indent=2)
PY
git add -A >/dev/null && git commit -qm "$sid: stub implementation

note for next story: nothing special"
say "implemented $sid"
'''


def _install_stub(sandbox: Path) -> dict:
    bindir = sandbox.parent / "bin"
    bindir.mkdir(exist_ok=True)
    stub = bindir / "claude"
    stub.write_text(STUB)
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    env = dict(os.environ)
    env["PATH"] = f"{bindir}:{env['PATH']}"
    return env


def _two_story_prd(sandbox: Path) -> None:
    write_prd(sandbox, stories=[
        {"id": "US-001", "title": "First thing", "acceptanceCriteria": ["Test: a"], "passes": False, "wikiPages": []},
        {"id": "US-002", "title": "Second thing", "acceptanceCriteria": ["Test: b"], "passes": False, "wikiPages": []},
    ])


class TestRalphLoop:
    def test_happy_path_merges_every_story(self, sandbox_repo):
        _two_story_prd(sandbox_repo)
        run(["bash", "workflow/scripts/sprint-start.sh", "ralph-sprint"], sandbox_repo)
        env = _install_stub(sandbox_repo)

        r = run(["bash", "ralph.sh", "5"], sandbox_repo, env=env, check=False)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "All stories complete after 2 iterations" in r.stdout

        assert db(sandbox_repo, "SELECT story_id, status FROM stories ORDER BY story_id;") == "US-001|passed\nUS-002|passed"
        assert git(sandbox_repo, "branch", "--show-current") == "sprint/ralph-sprint"
        branches = git(sandbox_repo, "branch", "--list", "US-*")
        assert branches == "", f"story branches should be deleted after merge: {branches}"
        subjects = git(sandbox_repo, "log", "--format=%s", "-6")
        assert "Merge US-001: First thing" in subjects and "Merge US-002: Second thing" in subjects
        assert (sandbox_repo / "test_US-001.py").exists() and (sandbox_repo / "test_US-002.py").exists()
        progress = db(sandbox_repo, "SELECT story_id, tests_modified FROM story_progress ORDER BY story_id;")
        assert "US-001|test_US-001.py" in progress
        assert (sandbox_repo / "ralph-logs" / "iteration-1.jsonl").exists()
        assert (sandbox_repo / "ralph-logs" / "review-US-001.jsonl").exists()

    def test_blocked_story_stops_loop_and_preserves_branch(self, sandbox_repo):
        _two_story_prd(sandbox_repo)
        run(["bash", "workflow/scripts/sprint-start.sh", "ralph-sprint"], sandbox_repo)
        env = _install_stub(sandbox_repo)
        env["STUB_MODE"] = "blocked"

        r = run(["bash", "ralph.sh", "5"], sandbox_repo, env=env, check=False)
        assert r.returncode == 1
        assert "US-001 blocked" in r.stdout
        assert db(sandbox_repo, "SELECT story_id, status FROM stories ORDER BY story_id;") == "US-001|blocked\nUS-002|pending"
        assert "US-001-first-thing" in git(sandbox_repo, "branch", "--list", "US-*")
        assert git(sandbox_repo, "branch", "--show-current") == "sprint/ralph-sprint"

    def test_resumes_in_progress_story(self, sandbox_repo):
        """A story left in_progress (e.g. after an interrupted run) is picked up on its existing branch."""
        _two_story_prd(sandbox_repo)
        run(["bash", "workflow/scripts/sprint-start.sh", "ralph-sprint"], sandbox_repo)
        git(sandbox_repo, "checkout", "-q", "-b", "US-001-first-thing")
        git(sandbox_repo, "checkout", "-q", "sprint/ralph-sprint")
        db(sandbox_repo, "UPDATE stories SET status='in_progress', branch_name='US-001-first-thing' WHERE story_id='US-001';")
        env = _install_stub(sandbox_repo)

        r = run(["bash", "ralph.sh", "1"], sandbox_repo, env=env, check=False)
        assert "Resuming US-001 on branch US-001-first-thing" in r.stdout
        assert db(sandbox_repo, "SELECT status FROM stories WHERE story_id='US-001';") == "passed"
