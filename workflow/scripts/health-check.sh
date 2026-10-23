#!/bin/bash
set -euo pipefail

# ── Workflow Health Check ────────────────────────────────────────────
# Verifies consistency between workflow.db, git branches, and the PRD JSON.
# Exit 0: all critical checks pass (warnings are informational).
# Exit 1: at least one critical inconsistency found.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
cd "$REPO_ROOT"

CRITICAL_FAIL=0
WARNINGS=0
pass() { printf "  ${GRN}✓${RST} %s\n" "$1"; }
warn() { printf "  ${YLW}⚠${RST} %s\n" "$1"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf "  ${RED}✗${RST} %s\n" "$1"; CRITICAL_FAIL=$((CRITICAL_FAIL + 1)); }

printf "${BLD}Workflow Health Check${RST}\n"
printf "─────────────────────\n"

if [[ ! -f "$WORKFLOW_DB" ]]; then
    fail "No workflow DB found at $WORKFLOW_DB"
    printf "\n${RED}${BLD}Health check failed.${RST}\n"
    exit 1
fi

SPRINT_ROW=$(db_query "SELECT name, branch_name, status, prd_path FROM sprints WHERE status = 'active' LIMIT 1;")
if [[ -z "$SPRINT_ROW" ]]; then
    printf "No active sprint.\n"
    printf "${DIM}Completed sprints: %s${RST}\n" "$(db_query "SELECT COUNT(*) FROM sprints WHERE status = 'complete';")"
    exit 0
fi

SPRINT_NAME=$(echo "$SPRINT_ROW" | cut -d'|' -f1)
SPRINT_BRANCH=$(echo "$SPRINT_ROW" | cut -d'|' -f2)
SPRINT_STATUS=$(echo "$SPRINT_ROW" | cut -d'|' -f3)
PRD_PATH=$(echo "$SPRINT_ROW" | cut -d'|' -f4)

count() { db_query "SELECT COUNT(*) FROM stories WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active') $1;"; }
PASSED=$(count "AND status = 'passed'")
IN_PROGRESS=$(count "AND status = 'in_progress'")
PENDING=$(count "AND status = 'pending'")
BLOCKED=$(count "AND status = 'blocked'")
TOTAL=$(count "")

printf "Sprint: %s (%s)\n" "$SPRINT_NAME" "$SPRINT_STATUS"
printf "Branch: %s\n" "$SPRINT_BRANCH"
printf "Stories: %s/%s passed" "$PASSED" "$TOTAL"
[[ "$IN_PROGRESS" -gt 0 ]] && printf ", %s in_progress" "$IN_PROGRESS"
[[ "$PENDING" -gt 0 ]] && printf ", %s pending" "$PENDING"
[[ "$BLOCKED" -gt 0 ]] && printf ", %s blocked" "$BLOCKED"
printf "\n\nChecks:\n"

# ── DB ↔ Git ─────────────────────────────────────────────────────────

if git rev-parse --verify "$SPRINT_BRANCH" >/dev/null 2>&1; then
    pass "Sprint branch $SPRINT_BRANCH exists"
else
    fail "Sprint branch $SPRINT_BRANCH does not exist in git"
fi

while IFS='|' read -r sid sbranch; do
    [[ -z "$sid" ]] && continue
    if [[ -z "$sbranch" ]]; then
        warn "$sid is in_progress but has no branch_name in DB"
    elif git rev-parse --verify "$sbranch" >/dev/null 2>&1; then
        pass "Active story branch $sbranch exists"
    else
        fail "$sid branch $sbranch not found in git"
    fi
done < <(db_query "SELECT story_id, branch_name FROM stories
    WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active') AND status = 'in_progress';")

while read -r branch_name; do
    [[ -z "$branch_name" ]] && continue
    if [[ "$(db_query "SELECT COUNT(*) FROM stories WHERE branch_name = '$branch_name';")" == "0" ]]; then
        warn "Orphaned branch $branch_name (not tracked in DB)"
    fi
done < <(git branch --list --format='%(refname:short)' 'US-*' 2>/dev/null)

# ── DB ↔ PRD ─────────────────────────────────────────────────────────

if [[ -n "$PRD_PATH" && -f "$PRD_PATH" ]]; then
    PRD_STORY_COUNT=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['userStories']))" "$PRD_PATH" 2>/dev/null || echo 0)
    if [[ "$TOTAL" == "$PRD_STORY_COUNT" ]]; then
        pass "Story count matches PRD ($TOTAL)"
    else
        fail "DB has $TOTAL stories but PRD has $PRD_STORY_COUNT"
    fi

    DB_ROWS=$(db_query "SELECT story_id, status FROM stories WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active');")
    MISMATCHES=$(DB_ROWS="$DB_ROWS" python3 - "$PRD_PATH" <<'PY'
import json, os, sys
prd = {s["id"]: s.get("passes", False) for s in json.load(open(sys.argv[1]))["userStories"]}
for row in os.environ["DB_ROWS"].splitlines():
    if not row:
        continue
    sid, status = row.split("|")
    if status == "passed" and not prd.get(sid, False):
        print(f"{sid}: DB=passed but PRD passes=false")
    elif status == "pending" and prd.get(sid, False):
        print(f"{sid}: DB=pending but PRD passes=true")
PY
)
    if [[ -z "$MISMATCHES" ]]; then
        pass "DB story status matches PRD passes flags"
    else
        while IFS= read -r line; do fail "$line"; done <<< "$MISMATCHES"
    fi
else
    warn "PRD file not found at $PRD_PATH — skipping PRD checks"
fi

# ── General ──────────────────────────────────────────────────────────

if [[ "$PASSED" == "$TOTAL" && "$TOTAL" -gt 0 ]]; then
    warn "All $TOTAL stories passed but sprint is still active (run sprint-finish?)"
fi

printf "\n"
if [[ "$CRITICAL_FAIL" -gt 0 ]]; then
    printf "${RED}${BLD}%d critical issue(s) found.${RST}\n" "$CRITICAL_FAIL"; exit 1
elif [[ "$WARNINGS" -gt 0 ]]; then
    printf "${YLW}All critical checks passed.${RST} ${DIM}(%d warning(s))${RST}\n" "$WARNINGS"; exit 0
else
    printf "${GRN}${BLD}All checks passed.${RST}\n"; exit 0
fi
