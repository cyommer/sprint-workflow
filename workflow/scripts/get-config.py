#!/usr/bin/env python3
"""Read a value from workflow/config.json.

Usage: get-config.py <dotted.key> [default]

Scalars print as-is. Lists print one item per line. Objects print as JSON.
Missing keys print the default (or nothing) and exit 0, so callers can rely
on `[[ -n "$(cfg key)" ]]` without set -e tripping.
"""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: get-config.py <dotted.key> [default]", file=sys.stderr)
        return 2
    key, default = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
    config_path = Path(__file__).resolve().parent.parent / "config.json"
    try:
        node = json.loads(config_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"get-config: cannot read {config_path}: {exc}", file=sys.stderr)
        print(default)
        return 0
    for part in key.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            print(default)
            return 0
    if isinstance(node, list):
        for item in node:
            print(item if isinstance(item, str) else json.dumps(item))
    elif isinstance(node, dict):
        print(json.dumps(node))
    elif isinstance(node, bool):
        print("true" if node else "false")
    else:
        print(node)
    return 0


if __name__ == "__main__":
    sys.exit(main())
