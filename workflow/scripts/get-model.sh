#!/bin/bash
# Read the model for a workflow stage from workflow/models.json.
# Usage: get-model.sh <stage>     stages: planning implementation review story_review quickfix
# Falls back to "sonnet" if the file or stage is missing.

STAGE="${1:?Usage: get-model.sh <stage>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/../models.json"

python3 -c "
import json, sys
try:
    with open('$CONFIG') as f:
        print(json.load(f).get('$STAGE', 'sonnet'))
except Exception:
    print('sonnet')
" 2>/dev/null || echo "sonnet"
