#!/usr/bin/env python3
"""Check whether a claude -p stream-json log contains a specific promise tag
in an assistant **text** message (not in tool inputs or tool results).

Ralph's story-dispatch loop uses promise tags like `<promise>BLOCKED</promise>`
and `<promise>COMPLETE</promise>` as explicit signals from the subagent. A
naive `grep` over the log file produces false positives because the same tag
strings appear in:

  - Tool inputs — when a test invokes `generate-prompt.py`, the generated
    prompt's instructions contain the literal BLOCKED tag as guidance to the
    model. The test subprocess captures that output and it ends up in the log.

  - Tool results — when the subagent reads `generate-prompt.py` source, the
    file contents (including the literal tag strings) land in the log.

The only place a promise tag should be treated as authoritative is inside an
assistant text block — i.e., the subagent's actual spoken output.

Stream format: each line is a JSON event. Assistant-spoken text lives at:

    {"type": "assistant", "message": {"content": [{"type": "text", "text": ...}, ...]}}

Usage:
    check-promise.py <logfile> <tag>

Exit codes:
    0 — tag found in at least one assistant text block
    1 — tag not found
    2 — logfile missing or unreadable
"""

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <logfile> <tag>", file=sys.stderr)
        return 2

    logfile, tag = sys.argv[1], sys.argv[2]

    if not Path(logfile).is_file():
        print(f"check-promise: logfile not found: {logfile}", file=sys.stderr)
        return 2

    with open(logfile) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            if event.get("type") != "assistant":
                continue

            message = event.get("message") or {}
            for block in message.get("content") or []:
                if block.get("type") != "text":
                    continue
                if tag in (block.get("text") or ""):
                    return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
