#!/usr/bin/env bash
# Injects docs/wiki/index.md and docs/wiki/state.md into every Claude Code
# session. Wired via .claude/settings.json (SessionStart hook).
#
# Payload budget: index.md + state.md should stay under 200 lines total.
# See docs/wiki/CONVENTIONS.md.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$REPO_ROOT" ] || { echo "(session-start-wiki: not in a git repo, skipping)"; exit 0; }

WIKI_DIR="$REPO_ROOT/docs/wiki"
if [ -f "$REPO_ROOT/workflow/config.json" ]; then
  CFG_DIR=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("wikiDir","docs/wiki"))' "$REPO_ROOT/workflow/config.json" 2>/dev/null || echo "docs/wiki")
  WIKI_DIR="$REPO_ROOT/$CFG_DIR"
fi
[ -d "$WIKI_DIR" ] || { echo "(session-start-wiki: $WIKI_DIR not found, skipping)"; exit 0; }

REL="${WIKI_DIR#"$REPO_ROOT"/}"
echo "=== $REL/index.md (wiki content catalog) ==="
[ -f "$WIKI_DIR/index.md" ] && cat "$WIKI_DIR/index.md" || echo "(index.md not present)"
echo
echo "=== $REL/state.md (current project state) ==="
[ -f "$WIKI_DIR/state.md" ] && cat "$WIKI_DIR/state.md" || echo "(state.md not present)"
