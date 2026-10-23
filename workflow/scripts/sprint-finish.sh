#!/bin/bash
set -euo pipefail

# ── Sprint Finish ────────────────────────────────────────────────────
# Wraps up a sprint: pre-finish gates, ingest gate, merge to base branch,
# archive PRD, mark sprint complete, delete sprint branch.
# Usage: sprint-finish.sh [--yes] [--skip-ingest]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

YES_MODE=false
SKIP_INGEST=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES_MODE=true ;;
        --skip-ingest) SKIP_INGEST=true ;;
    esac
done

BASE_BRANCH="$(cfg baseBranch develop)"
WIKI_DIR="$(cfg wikiDir docs/wiki)"
cd "$REPO_ROOT"

# ── Preconditions ────────────────────────────────────────────────────

[[ -f "$WORKFLOW_DB" ]] || die "No workflow DB found."

SPRINT_ROW=$(db_query "SELECT name, branch_name, prd_path FROM sprints WHERE status = 'active' LIMIT 1;")
[[ -n "$SPRINT_ROW" ]] || die "No active sprint."
SPRINT_NAME=$(echo "$SPRINT_ROW" | cut -d'|' -f1)
SPRINT_BRANCH=$(echo "$SPRINT_ROW" | cut -d'|' -f2)
PRD_PATH=$(echo "$SPRINT_ROW" | cut -d'|' -f3)

REMAINING=$(db_query "SELECT COUNT(*) FROM stories
    WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active')
    AND status IN ('pending', 'in_progress');")

if [[ "$REMAINING" -gt 0 ]]; then
    printf "${YLW}Warning:${RST} %s stories still pending/in_progress:\n" "$REMAINING"
    db_query "SELECT story_id, title, status FROM stories
        WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active')
        AND status IN ('pending', 'in_progress');" | while IFS='|' read -r sid title status; do
        printf "  ${YLW}%s${RST} (%s) — %s\n" "$sid" "$status" "$title"
    done
    printf "\n"
    if [[ "$YES_MODE" == true ]]; then
        printf "${YLW}  Continuing (--yes)${RST}\n"
    else
        read -rp "Continue anyway? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    fi
fi

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "$SPRINT_BRANCH" ]]; then
    printf "${DIM}Switching to %s...${RST}\n" "$SPRINT_BRANCH"
    git checkout "$SPRINT_BRANCH"
fi
[[ -z "$(git status --porcelain)" ]] || die "Uncommitted changes. Commit or stash first."

# ── Pre-finish gates ─────────────────────────────────────────────────
# Checks that per-story gates can miss (e.g. a model change committed
# without its migration). Configured in workflow/config.json.

while IFS= read -r gate; do
    [[ -z "$gate" ]] && continue
    printf "${DIM}Pre-finish gate: %s${RST}\n" "$gate"
    if ! bash -c "$gate"; then
        die "Pre-finish gate failed: $gate"
    fi
done < <(cfg preFinishGates.commands)
printf "${GRN}  ✓ Pre-finish gates passed${RST}\n"

# ── Ingest gate ──────────────────────────────────────────────────────
# The /wiki-ingest skill appends this sigil to log.md. No sigil, no merge.

LOG_PATH="$WIKI_DIR/log.md"
SIGIL_REGEX="^## .* sprint-finish: ${SPRINT_NAME}\$"

if [[ ! -f "$LOG_PATH" ]]; then
    printf "${YLW}  ⚠ No %s — wiki not set up, skipping ingest gate${RST}\n" "$LOG_PATH"
elif grep -qE "$SIGIL_REGEX" "$LOG_PATH"; then
    printf "${GRN}  ✓ Ingest verified${RST}\n"
elif [[ "$SKIP_INGEST" == true ]]; then
    printf "${YLW}  ⚠ --skip-ingest set, bypassing gate${RST}\n"
    {
        echo ""
        echo "## $(date +%Y-%m-%d) — sprint-finish: ${SPRINT_NAME} (skipped)"
        echo "Reason: bypass via --skip-ingest flag"
    } >> "$LOG_PATH"
    git add "$LOG_PATH"
    git commit -q -m "Log skipped ingest for ${SPRINT_NAME}"
    printf "${DIM}  (skipped entry appended to log.md)${RST}\n"
else
    printf "\n${RED}${BLD}Error:${RST} Ingest not verified for sprint '${SPRINT_NAME}'.\n" >&2
    printf "  Run ${BLD}/wiki-ingest${RST} to update wiki pages and append a sprint-finish entry\n" >&2
    printf "  to %s, or pass ${BLD}--skip-ingest${RST} to bypass (logged as skipped).\n" "$LOG_PATH" >&2
    exit 1
fi

# ── Story summary ────────────────────────────────────────────────────

PASSED=$(db_query "SELECT COUNT(*) FROM stories WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active') AND status = 'passed';")
TOTAL=$(db_query "SELECT COUNT(*) FROM stories WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active');")
BLOCKED=$(db_query "SELECT COUNT(*) FROM stories WHERE sprint_id = (SELECT id FROM sprints WHERE status = 'active') AND status = 'blocked';")

printf "\n${BLD}Sprint: %s${RST}\n" "$SPRINT_NAME"
printf "  Stories: %s/%s passed" "$PASSED" "$TOTAL"
[[ "$BLOCKED" -gt 0 ]] && printf ", %s blocked" "$BLOCKED"
printf "\n\n"

# ── Merge to base branch ─────────────────────────────────────────────

printf "${BLD}Merging %s → %s...${RST}\n" "$SPRINT_BRANCH" "$BASE_BRANCH"
git checkout "$BASE_BRANCH"
git merge --no-ff "$SPRINT_BRANCH" -m "Merge sprint/$SPRINT_NAME into $BASE_BRANCH"
printf "${GRN}  ✓ Merged${RST}\n"

# ── Archive PRD ──────────────────────────────────────────────────────

if [[ -n "$PRD_PATH" && -f "$PRD_PATH" ]]; then
    ARCHIVE_DIR="$(dirname "$PRD_PATH")/archive"
    mkdir -p "$ARCHIVE_DIR"
    ARCHIVE_NAME="$(date +%Y-%m-%d)-${SPRINT_NAME}.json"
    cp "$PRD_PATH" "$ARCHIVE_DIR/$ARCHIVE_NAME"
    rm -f "$PRD_PATH"
    git add "$ARCHIVE_DIR/$ARCHIVE_NAME" "$PRD_PATH"
    git commit -q -m "Archive PRD: $SPRINT_NAME"
    printf "${GRN}  ✓ PRD archived, %s removed${RST}\n" "$(basename "$PRD_PATH")"
fi

# ── Update workflow DB ───────────────────────────────────────────────

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
db_query "UPDATE sprints SET status = 'complete', completed_at = '$TS' WHERE status = 'active';"
printf "${GRN}  ✓ Sprint marked complete in DB${RST}\n"

# ── Delete sprint branch ────────────────────────────────────────────

git branch -d "$SPRINT_BRANCH" 2>/dev/null && \
    printf "${GRN}  ✓ Deleted branch %s${RST}\n" "$SPRINT_BRANCH" || \
    printf "${YLW}  ⚠ Could not delete %s (may already be gone)${RST}\n" "$SPRINT_BRANCH"

printf "\n${GRN}${BLD}✓ Sprint %s finished.${RST} Merged to %s, PRD archived, branch cleaned up.\n" "$SPRINT_NAME" "$BASE_BRANCH"
