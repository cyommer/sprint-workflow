#!/bin/bash
# ── Ralph loop ───────────────────────────────────────────────────────
# Autonomous story-by-story implementation loop.
#
#   ./ralph.sh [iterations]      default 5
#
# For each iteration: pick the next story from workflow.db, create (or
# resume) its branch off the sprint branch, generate a focused prompt from
# the PRD, run `claude -p` with the implementation model, check the result,
# run a lightweight spec-compliance review with the story_review model,
# retry once with the review feedback, then merge the story branch into
# the sprint branch and record progress.
#
# The agent never touches branches: prompts tell it to commit to the
# current branch only. All git plumbing and DB writes happen here.
set -o pipefail

ITERATIONS="${1:-5}"
source "$(dirname "$0")/workflow/lib.sh"
cd "$REPO_ROOT"

LOG_DIR="ralph-logs"
mkdir -p "$LOG_DIR"
TEST_PATTERN="$(cfg testFilePattern test_)"
mapfile -t CLAUDE_FLAGS < <(cfg claudeExtraFlags)

# ── Streaming formatter ──────────────────────────────────────────────
# Renders claude's stream-json output as a readable transcript.
format_stream() {
  PYTHONUNBUFFERED=1 python3 -u "$WORKFLOW_DIR/scripts/format-stream.py"
}

# ── DB helpers ───────────────────────────────────────────────────────
next_story() {
    db_query "SELECT story_id, title, status, branch_name FROM stories
              WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active')
              AND status IN ('in_progress', 'pending')
              ORDER BY
                  CASE status WHEN 'in_progress' THEN 0 ELSE 1 END,
                  CAST(REPLACE(story_id, 'US-', '') AS INTEGER)
              LIMIT 1;"
}

update_story_status() {
    local story_id="$1" new_status="$2" ts field=""
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    [[ "$new_status" == "in_progress" ]] && field=", started_at='$ts'"
    [[ "$new_status" =~ ^(passed|blocked|failed)$ ]] && field=", completed_at='$ts'"
    db_query "UPDATE stories SET status='$new_status' $field
              WHERE story_id='$story_id'
              AND sprint_id = (SELECT id FROM sprints WHERE status = 'active');"
}

update_story_branch() {
    db_query "UPDATE stories SET branch_name='$2'
              WHERE story_id='$1'
              AND sprint_id = (SELECT id FROM sprints WHERE status = 'active');"
}

record_story_progress() {
    local story_id="$1" sprint_branch="$2" story_branch="$3"
    WF_DB="$WORKFLOW_DB" python3 - "$story_id" "$sprint_branch" "$story_branch" "$TEST_PATTERN" <<'PY'
import os, sqlite3, subprocess, sys
story_id, sprint_branch, story_branch, test_pattern = sys.argv[1:5]
def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()
files = git("diff", "--name-only", f"{sprint_branch}...{story_branch}")
tests = "\n".join(f for f in files.splitlines() if test_pattern in f)
notes = git("log", "--format=%b", "-1", story_branch)[:500]
db = sqlite3.connect(os.environ["WF_DB"])
sid = db.execute("SELECT id FROM sprints WHERE status = 'active'").fetchone()[0]
db.execute(
    "INSERT OR REPLACE INTO story_progress (sprint_id, story_id, files_changed, tests_modified, notes) VALUES (?, ?, ?, ?, ?)",
    (sid, story_id, files, tests, notes),
)
db.commit()
PY
}

story_branch_slug() {
    local slug
    slug=$(echo "$2" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//' | cut -c1-40 | sed 's/-$//')
    echo "$1-$slug"
}

story_passes() {
    python3 -c "
import json, sys
stories = json.load(open(sys.argv[1]))['userStories']
s = next((s for s in stories if s['id'] == sys.argv[2]), None)
print('true' if s and s.get('passes') else 'false')
" "$PRD_PATH" "$1" 2>/dev/null || echo "false"
}

run_claude() {
    # $1 = model, $2 = log file, $3 = stderr file; prompt on stdin
    claude -p --model "$1" --verbose --output-format stream-json "${CLAUDE_FLAGS[@]}" \
        2>"$3" | stdbuf -oL tee "$2" | format_stream || true
}

review_story() {
    local story_id="$1" story_branch="$2" sprint_branch="$3"
    local criteria diff_stat full_diff
    criteria=$(python3 -c "
import json, sys
prd = json.load(open(sys.argv[1]))
story = next((s for s in prd['userStories'] if s['id'] == sys.argv[2]), None)
for c in (story or {}).get('acceptanceCriteria', []):
    print(f'- {c}')
" "$PRD_PATH" "$story_id")
    diff_stat=$(git diff "$sprint_branch"..."$story_branch" --stat 2>/dev/null)
    full_diff=$(git diff "$sprint_branch"..."$story_branch" 2>/dev/null | head -500)

    cat <<PROMPT | claude -p --model "$REVIEW_MODEL" --output-format stream-json "${CLAUDE_FLAGS[@]}" 2>/dev/null
@CLAUDE.md

You are reviewing the implementation of $story_id.

## Acceptance Criteria
$criteria

## Files Changed
$diff_stat

## Diff (first 500 lines)
\`\`\`
$full_diff
\`\`\`

## Review Checklist
1. Does every acceptance criterion have a corresponding implementation? List each criterion and whether it appears to be met.
2. Were test files created or modified? Do the tests verify the acceptance criteria (not just smoke tests)?
3. Any obvious bugs, security issues, or missing error handling?

If ALL criteria appear met and tests are adequate, output exactly: <review>PASS</review>
If any criteria are missed or tests are inadequate, output exactly: <review>FAIL</review>
Then list the specific gaps that need to be addressed.
PROMPT
}

extract_text() {
    # Pull assistant text out of a stream-json log
    python3 -c "
import json, sys
parts = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        parts.append(line); continue
    if ev.get('type') == 'result':
        parts.append(ev.get('result', ''))
    elif ev.get('type') == 'assistant':
        for b in ev.get('message', {}).get('content', []):
            if b.get('type') == 'text':
                parts.append(b.get('text', ''))
print('\n'.join(parts))
"
}

# ── Pre-loop setup ───────────────────────────────────────────────────
[[ -f "$WORKFLOW_DB" ]] || die "No workflow DB. Run ./workflow/scripts/sprint-start.sh first."
SPRINT_BRANCH=$(db_query "SELECT branch_name FROM sprints WHERE status = 'active';")
[[ -n "$SPRINT_BRANCH" ]] || die "No active sprint. Run ./workflow/scripts/sprint-start.sh first."
PRD_PATH=$(db_query "SELECT prd_path FROM sprints WHERE status = 'active';")
RALPH_MODEL=$("$WORKFLOW_DIR/scripts/get-model.sh" implementation)
REVIEW_MODEL=$("$WORKFLOW_DIR/scripts/get-model.sh" story_review)
command -v claude >/dev/null || die "claude CLI not found on PATH"

printf "${BLD}══════════════════════════════════════${RST}\n"
printf "${BLD}  Ralph Loop — %d iterations${RST}\n" "$ITERATIONS"
printf "${BLD}  Sprint: %s  Model: %s${RST}\n" "$SPRINT_BRANCH" "$RALPH_MODEL"
printf "${BLD}══════════════════════════════════════${RST}\n"
printf "${DIM}Logs: %s/${RST}\n\n" "$LOG_DIR"

# ── Main loop ────────────────────────────────────────────────────────
for ((i=1; i<=ITERATIONS; i++)); do
  LOGFILE="$LOG_DIR/iteration-$i.jsonl"
  ERRLOG="$LOG_DIR/iteration-$i.stderr"
  ln -sf "iteration-$i.jsonl" "$LOG_DIR/latest.jsonl"

  STORY_ROW=$(next_story)
  if [[ -z "$STORY_ROW" ]]; then
    printf "\n${GRN}${BLD}✓ All stories complete after %d iterations!${RST}\n" "$((i-1))"
    exit 0
  fi
  IFS='|' read -r STORY_ID STORY_TITLE STORY_STATUS STORY_BRANCH_DB <<< "$STORY_ROW"

  printf "\n\033[35m${BLD}━━━ Iteration %d of %d ━━━ %s: %s${RST}\n" "$i" "$ITERATIONS" "$STORY_ID" "$STORY_TITLE"

  # ── Branch management ─────────────────────────────────────────────
  if [[ "$STORY_STATUS" == "in_progress" && -n "$STORY_BRANCH_DB" ]]; then
    printf "${YLW}  Resuming %s on branch %s${RST}\n" "$STORY_ID" "$STORY_BRANCH_DB"
    git checkout "$STORY_BRANCH_DB"
    STORY_BRANCH="$STORY_BRANCH_DB"
  else
    STORY_BRANCH=$(story_branch_slug "$STORY_ID" "$STORY_TITLE")
    git checkout "$SPRINT_BRANCH"
    git checkout -b "$STORY_BRANCH"
    update_story_status "$STORY_ID" "in_progress"
    update_story_branch "$STORY_ID" "$STORY_BRANCH"
    printf "\033[36m  Branch: %s${RST}\n" "$STORY_BRANCH"
  fi

  # ── Prompt ────────────────────────────────────────────────────────
  PREV_NOTES=$(git log --format='%b' -1 "$SPRINT_BRANCH" 2>/dev/null | head -10)
  STORY_PROMPT=$(python3 "$WORKFLOW_DIR/scripts/generate-prompt.py" --story "$STORY_ID" --prd "$PRD_PATH" --prev-notes "$PREV_NOTES")
  if [[ -z "$STORY_PROMPT" ]]; then
    printf "${RED}  ⚠ Failed to generate prompt for %s — skipping${RST}\n" "$STORY_ID"
    git checkout "$SPRINT_BRANCH"; continue
  fi

  # ── Implement ─────────────────────────────────────────────────────
  echo "$STORY_PROMPT" | run_claude "$RALPH_MODEL" "$LOGFILE" "$ERRLOG"
  echo ""

  # Only assistant text counts: tool inputs/results echo the literal tag.
  if python3 "$WORKFLOW_DIR/scripts/check-promise.py" "$LOGFILE" '<promise>BLOCKED</promise>' 2>/dev/null; then
    update_story_status "$STORY_ID" "blocked"
    git checkout "$SPRINT_BRANCH"
    printf "${RED}${BLD}✗ %s blocked after 3 attempts — check %s${RST}\n" "$STORY_ID" "$LOGFILE"
    exit 1
  fi

  if [[ ! -s "$LOGFILE" ]]; then
    printf "${RED}  ⚠ No output from claude. stderr:${RST}\n"; head -5 "$ERRLOG"; printf "\n"
    git checkout "$SPRINT_BRANCH"; continue
  fi

  if [[ "$(story_passes "$STORY_ID")" != "true" ]]; then
    git checkout "$SPRINT_BRANCH"
    printf "${YLW}  %s not yet passing — branch preserved${RST}\n" "$STORY_ID"
    continue
  fi

  # ── Test file check ───────────────────────────────────────────────
  if [[ "$(git diff --name-only "$SPRINT_BRANCH"..."$STORY_BRANCH" | grep -c "$TEST_PATTERN" || true)" == "0" ]]; then
    printf "${YLW}  ⚠ No test files changed for %s${RST}\n" "$STORY_ID"
  fi

  # ── Per-story review ──────────────────────────────────────────────
  printf "\033[36m  Reviewing %s...${RST}\n" "$STORY_ID"
  REVIEW_LOG="$LOG_DIR/review-$STORY_ID.jsonl"
  REVIEW_OUTPUT=$(review_story "$STORY_ID" "$STORY_BRANCH" "$SPRINT_BRANCH" | tee "$REVIEW_LOG")

  if echo "$REVIEW_OUTPUT" | grep -q '<review>FAIL</review>'; then
    printf "${YLW}  Review found gaps — retrying %s with feedback${RST}\n" "$STORY_ID"
    REVIEW_FEEDBACK=$(echo "$REVIEW_OUTPUT" | extract_text)
    RETRY_PROMPT="$STORY_PROMPT

## Review Feedback (fix these gaps)
$REVIEW_FEEDBACK

Fix ONLY the gaps listed above. Do not re-implement what already works.
Run quality gates after fixing. Update the PRD and commit."

    echo "$RETRY_PROMPT" | run_claude "$RALPH_MODEL" "$LOG_DIR/retry-$STORY_ID.jsonl" "$LOG_DIR/retry-$STORY_ID.stderr"

    if [[ "$(story_passes "$STORY_ID")" != "true" ]]; then
      git checkout "$SPRINT_BRANCH"
      printf "${YLW}  %s still not passing after retry — branch preserved${RST}\n" "$STORY_ID"
      continue
    fi
    printf "${GRN}  ✓ %s fixed after review feedback${RST}\n" "$STORY_ID"
  else
    printf "${GRN}  ✓ Review passed for %s${RST}\n" "$STORY_ID"
  fi

  # ── Record and merge ──────────────────────────────────────────────
  record_story_progress "$STORY_ID" "$SPRINT_BRANCH" "$STORY_BRANCH"
  update_story_status "$STORY_ID" "passed"
  git checkout "$SPRINT_BRANCH"
  git merge --no-ff "$STORY_BRANCH" -m "Merge $STORY_ID: $STORY_TITLE"
  git branch -d "$STORY_BRANCH"
  printf "${GRN}  ✓ %s merged to %s${RST}\n" "$STORY_ID" "$SPRINT_BRANCH"

  REMAINING=$(db_query "SELECT COUNT(*) FROM stories
      WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active')
      AND status NOT IN ('passed', 'failed', 'blocked');")
  if [[ "$REMAINING" == "0" ]]; then
    printf "\n${GRN}${BLD}✓ All stories complete after %d iterations!${RST}\n" "$i"
    exit 0
  fi
  printf "${YLW}  Progress: %s — continuing...${RST}\n" "$(db_query "SELECT SUM(CASE WHEN status = 'passed' THEN 1 ELSE 0 END) || '/' || COUNT(*) FROM stories WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active');")"
done

printf "\n${RED}${BLD}✗ Reached max iterations (%d).${RST}\n" "$ITERATIONS"
exit 1
