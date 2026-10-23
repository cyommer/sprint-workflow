#!/bin/bash
# Install the workflow kit into a target repository.
#
#   ./install.sh /path/to/your/repo [--project-name "My App"] [--force]
#
# Copies the kit's files into the target, never overwriting an existing file
# unless --force is given. Then prints the manual steps that remain
# (config.json, CLAUDE.md snippet, .gitignore lines).
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?Usage: install.sh <target-repo> [--project-name NAME] [--force]}"
shift
PROJECT_NAME=""
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-name) PROJECT_NAME="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

TARGET="$(cd "$TARGET" && pwd)"
[[ -d "$TARGET/.git" ]] || { echo "Error: $TARGET is not a git repository" >&2; exit 1; }
[[ -n "$PROJECT_NAME" ]] || PROJECT_NAME="$(basename "$TARGET")"

GRN='\033[32m'; YLW='\033[33m'; DIM='\033[2m'; BLD='\033[1m'; RST='\033[0m'
copied=0; skipped=0

copy_one() {
    local rel="$1" src="$KIT_DIR/$1" dst="$TARGET/$1"
    if [[ -e "$dst" && "$FORCE" != true ]]; then
        printf "  ${YLW}skip${RST} %s (exists)\n" "$rel"; skipped=$((skipped+1)); return
    fi
    mkdir -p "$(dirname "$dst")"
    sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" "$src" > "$dst"
    [[ -x "$src" ]] && chmod +x "$dst"
    printf "  ${GRN}add ${RST} %s\n" "$rel"; copied=$((copied+1))
}

printf "${BLD}Installing workflow kit into %s${RST} (project: %s)\n\n" "$TARGET" "$PROJECT_NAME"

# Everything under these roots, plus the top-level files.
while IFS= read -r f; do
    copy_one "${f#./}"
done < <(cd "$KIT_DIR" && find . \
    \( -path './.git' -o -path './tests' -o -path './ralph-logs' -o -path './.pytest_cache' -o -name '__pycache__' \) -prune -o \
    -type f \( -path './.claude/*' -o -path './workflow/*' -o -path './docs/*' \) -print \
    | grep -v 'workflow/workflow.db' | sort)
copy_one "ralph.sh"
copy_one "CLAUDE.md.snippet"

# .gitignore lines
GI="$TARGET/.gitignore"
touch "$GI"
for line in "workflow/workflow.db" "ralph-logs/" ".claude/settings.local.json"; do
    grep -qxF "$line" "$GI" || { echo "$line" >> "$GI"; printf "  ${GRN}gitignore${RST} %s\n" "$line"; }
done

printf "\n${BLD}Done.${RST} %d files added, %d skipped.\n\n" "$copied" "$skipped"
cat <<EOF
Next steps (manual, ~10 minutes):
  1. Edit workflow/config.json: baseBranch, quality gate commands, preFinishGates, neverStage.
  2. Paste CLAUDE.md.snippet into your CLAUDE.md (then delete the snippet file).
  3. Edit the "Project Context" bullets in .claude/review-agents/*.md.
     Move anything you want from .claude/review-agents/optional/ up one level.
  4. Seed docs/wiki/: write one entity page per major subsystem, list them in index.md,
     and set state.md "Next Up". Keep index.md + state.md under 200 lines combined.
  5. Create the base branch if it does not exist (default: develop).
  6. Open a Claude Code session; the wiki banner should appear. Run /sprint-plan.
EOF
