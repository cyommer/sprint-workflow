#!/bin/bash
# Shared helpers for the workflow scripts. Source this; do not execute it.
#
#   source "$(dirname "$0")/../lib.sh"      # from workflow/scripts/*.sh
#   source workflow/lib.sh                   # from the repo root (ralph.sh)
#
# Provides:
#   REPO_ROOT, WORKFLOW_DIR, WORKFLOW_DB, SCHEMA, CONFIG
#   colors: RED GRN YLW BLD DIM RST
#   die <msg>            print error and exit 1
#   cfg <dotted.key>     read a scalar or list from workflow/config.json
#   db_query <sql>       run SQL against workflow.db ('|' separated rows).
#                        Uses the sqlite3 CLI when present, else python3's
#                        sqlite3 module, so the only hard dependency is python3.
#   db_init              create workflow.db from schema.sql if missing

WORKFLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$WORKFLOW_DIR")"
WORKFLOW_DB="$WORKFLOW_DIR/workflow.db"
SCHEMA="$WORKFLOW_DIR/schema.sql"
CONFIG="$WORKFLOW_DIR/config.json"

RED='\033[31m'; GRN='\033[32m'; YLW='\033[33m'; BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

die() { printf "${RED}${BLD}Error:${RST} %s\n" "$1" >&2; exit 1; }

cfg() { python3 "$WORKFLOW_DIR/scripts/get-config.py" "$@"; }

db_query() {
    local sql="$1"
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 -separator '|' "$WORKFLOW_DB" "$sql"
    else
        WF_DB="$WORKFLOW_DB" WF_SQL="$sql" python3 - <<'PY'
import os, sqlite3
db = sqlite3.connect(os.environ["WF_DB"])
cur = db.cursor()
# executescript() returns no rows, so multi-statement input (writes) goes
# through it while a single statement goes through execute() to get rows back.
sql = os.environ["WF_SQL"].strip()
stmts = [s for s in sql.split(";") if s.strip()]
if len(stmts) > 1:
    cur.executescript(sql)
else:
    cur.execute(stmts[0])
    for row in cur.fetchall():
        print("|".join("" if v is None else str(v) for v in row))
db.commit()
db.close()
PY
    fi
}

db_init() {
    if [[ ! -f "$WORKFLOW_DB" ]]; then
        [[ -f "$SCHEMA" ]] || die "Schema not found: $SCHEMA"
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$WORKFLOW_DB" < "$SCHEMA"
        else
            WF_DB="$WORKFLOW_DB" WF_SCHEMA="$SCHEMA" python3 -c 'import os,sqlite3; sqlite3.connect(os.environ["WF_DB"]).executescript(open(os.environ["WF_SCHEMA"]).read())'
        fi
        printf "${DIM}Created workflow DB from schema.sql${RST}\n"
    fi
}
