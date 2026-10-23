#!/bin/bash
set -euo pipefail

# ── Sprint Start ─────────────────────────────────────────────────────
# Creates the sprint branch off the base branch, seeds workflow.db with the
# sprint and its stories, and writes the "Active Sprint" section of the wiki.
# Usage: sprint-start.sh <sprint-name> [prd-path]

SPRINT_NAME="${1:?Usage: sprint-start.sh <sprint-name> [prd-path]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

BASE_BRANCH="$(cfg baseBranch develop)"
PRD_PATH="${2:-$(cfg prdPath docs/prds/current.json)}"
WIKI_DIR="$(cfg wikiDir docs/wiki)"

cd "$REPO_ROOT"

# ── Preconditions ────────────────────────────────────────────────────

[[ -f "$PRD_PATH" ]] || die "PRD file not found: $PRD_PATH"
STORY_COUNT=$(python3 - "$PRD_PATH" <<'PY' 2>/dev/null
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    stories = data.get("userStories", [])
    if not stories:
        sys.exit(1)
    print(len(stories))
except (json.JSONDecodeError, KeyError, OSError):
    sys.exit(1)
PY
) || die "Invalid PRD or no userStories in $PRD_PATH"

db_init

ACTIVE=$(db_query "SELECT name FROM sprints WHERE status = 'active' LIMIT 1;")
[[ -z "$ACTIVE" ]] || die "Sprint '$ACTIVE' is still active. Finish it first."

CURRENT_BRANCH=$(git branch --show-current)
[[ "$CURRENT_BRANCH" == "$BASE_BRANCH" ]] || die "Must be on '$BASE_BRANCH' (currently on '$CURRENT_BRANCH')"
[[ -z "$(git status --porcelain)" ]] || die "Uncommitted changes on $BASE_BRANCH. Commit or stash first."

# ── Create sprint branch ─────────────────────────────────────────────

SPRINT_BRANCH="sprint/$SPRINT_NAME"
git checkout -b "$SPRINT_BRANCH" "$BASE_BRANCH"
printf "${GRN}Created branch:${RST} %s\n" "$SPRINT_BRANCH"

# ── Populate DB ──────────────────────────────────────────────────────

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WF_DB="$WORKFLOW_DB" python3 - "$SPRINT_NAME" "$SPRINT_BRANCH" "$PRD_PATH" "$TS" <<'PY'
import json, os, sqlite3, sys
name, branch, prd_path, ts = sys.argv[1:5]
stories = json.load(open(prd_path))["userStories"]
db = sqlite3.connect(os.environ["WF_DB"])
db.execute(
    "INSERT INTO sprints (name, branch_name, status, prd_path, started_at) VALUES (?, ?, 'active', ?, ?)",
    (name, branch, prd_path, ts),
)
sprint_id = db.execute("SELECT id FROM sprints WHERE name = ?", (name,)).fetchone()[0]
for s in stories:
    db.execute(
        "INSERT INTO stories (sprint_id, story_id, title, status) VALUES (?, ?, ?, 'pending')",
        (sprint_id, s["id"], s["title"]),
    )
db.commit()
PY

# ── Update wiki state ────────────────────────────────────────────────

WIKI_STATE="$WIKI_DIR/state.md"
WIKI_LOG="$WIKI_DIR/log.md"
TODAY=$(date +%Y-%m-%d)

if [[ -f "$WIKI_STATE" && -f "$WIKI_LOG" ]]; then
    # Idempotent: only append the log entry once
    if ! grep -qE "^## .* sprint-start: ${SPRINT_NAME}\$" "$WIKI_LOG"; then
        {
            echo ""
            echo "## ${TODAY} — sprint-start: ${SPRINT_NAME}"
            echo "Branch: ${SPRINT_BRANCH}"
            echo "PRD: ${PRD_PATH}"
        } >> "$WIKI_LOG"
    fi

    python3 - "$WIKI_STATE" "$SPRINT_NAME" "$TODAY" "$SPRINT_BRANCH" "$PRD_PATH" <<'PY'
import re, sys
from pathlib import Path
state_path, name, today, branch, prd = sys.argv[1:6]
p = Path(state_path)
content = p.read_text()
new_section = f"## Active Sprint\n\n**{name}** — started {today} on branch `{branch}`. PRD: `{prd}`.\n"
pattern = re.compile(r"## Active Sprint\n.*?(?=\n## |\Z)", re.DOTALL)
if pattern.search(content):
    content = pattern.sub(new_section.rstrip() + "\n", content)
else:
    content = re.sub(r"(# [^\n]+\n)", r"\1\n" + new_section.rstrip() + "\n\n", content, count=1)
p.write_text(content)
PY

    git add "$WIKI_STATE" "$WIKI_LOG"
    if ! git diff --cached --quiet; then
        git commit -q -m "Update wiki state: start sprint ${SPRINT_NAME}"
        printf "${GRN}  Wiki state updated${RST}\n"
    else
        printf "${DIM}  (wiki state already current)${RST}\n"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────

MODEL=$("$SCRIPT_DIR/get-model.sh" implementation)
printf "\n${BLD}Sprint started${RST}\n"
printf "  Name:    %s\n" "$SPRINT_NAME"
printf "  Branch:  %s\n" "$SPRINT_BRANCH"
printf "  Stories: %s (all pending)\n" "$STORY_COUNT"
printf "  Model:   %s (implementation)\n" "$MODEL"
printf "  PRD:     %s\n" "$PRD_PATH"
printf "\n${DIM}Ready to run: ./ralph.sh${RST}\n"
