#!/usr/bin/env python3
"""Render `claude -p --output-format stream-json` as a readable live transcript.

ralph.sh pipes claude's stdout through this. Each JSON line becomes a short
line showing assistant text, tool calls (with a one-line summary of the
input), and the first line of each tool result.
"""

import os, sys, json

stdin = os.fdopen(sys.stdin.fileno(), "r", 1)

C    = "\033[36m"
D    = "\033[2m"
B    = "\033[1m"
R    = "\033[0m"
RED  = "\033[31m"
GRN  = "\033[32m"

ICONS = {
    "Bash": "$", "Read": ">", "Write": "<", "Edit": "~",
    "Glob": "*", "Grep": "/", "Task": ">>", "Skill": "!",
    "TaskCreate": "+", "TaskUpdate": "=", "TaskList": "?",
    "TodoWrite": "[]", "TodoRead": "[]", "WebFetch": "@",
    "WebSearch": "?", "NotebookEdit": "nb",
}

def show_tool_use(name, inp):
    icon = ICONS.get(name, "#")
    print(f"\n{C}[{icon}] {name}{R}", end="", flush=True)
    cmd  = inp.get("command", "")
    fp   = inp.get("file_path", "")
    pat  = inp.get("pattern", "")
    desc = inp.get("description", "")
    prompt = inp.get("prompt", "")
    if cmd:
        show = (cmd[:160] + "...") if len(cmd) > 160 else cmd
        lbl = f"  ({desc})" if desc else ""
        print(f"\n  {D}$ {show}{lbl}{R}", flush=True)
    elif fp:
        print(f" {D}{fp}{R}", flush=True)
        if inp.get("old_string"):
            preview = inp["old_string"].strip().split(chr(10))[0][:80]
            print(f"    {D}replacing: {preview}{R}", flush=True)
        if inp.get("new_string"):
            preview = inp["new_string"].strip().split(chr(10))[0][:80]
            print(f"    {D}    with: {preview}{R}", flush=True)
    elif pat:
        path = inp.get("path", ".")
        print(f" {D}{pat} in {path}{R}", flush=True)
    elif prompt:
        show = (prompt[:120] + "...") if len(prompt) > 120 else prompt
        print(f" {D}{show}{R}", flush=True)
    else:
        items = [(k, str(v)[:80]) for k, v in list(inp.items())[:4]]
        if items:
            summary = ", ".join(f"{k}={v}" for k, v in items)
            print(f" {D}{summary}{R}", flush=True)
        else:
            print("", flush=True)

def show_tool_result(result_str, is_error=False):
    if not result_str:
        return
    if is_error:
        show = (result_str[:200] + "...") if len(result_str) > 200 else result_str
        print(f"  {RED}✗ {show}{R}", flush=True)
    else:
        first_line = result_str.strip().split(chr(10))[0][:120]
        if first_line:
            print(f"  {D}→ {first_line}{R}", flush=True)

while True:
    line = stdin.readline()
    if not line:
        break
    stripped = line.strip()
    if not stripped:
        continue
    try:
        event = json.loads(stripped)
    except json.JSONDecodeError:
        print(f"{D}{stripped}{R}", flush=True)
        continue

    etype = event.get("type", "")

    if etype == "assistant":
        message = event.get("message", {})
        for block in message.get("content", []):
            btype = block.get("type", "")
            if btype == "text":
                text = block.get("text", "")
                if text.strip():
                    print(text, flush=True)
            elif btype == "tool_use":
                show_tool_use(block.get("name", "?"), block.get("input", {}))
    elif etype == "user":
        result = event.get("tool_use_result", "")
        if isinstance(result, dict):
            result = result.get("content", "") or json.dumps(result)[:200]
        if isinstance(result, list):
            result = str(result)[:200]
        result = str(result) if result else ""
        if result:
            is_err = result.startswith("Error:") or result.startswith("error:")
            show_tool_result(result, is_error=is_err)
        else:
            message = event.get("message", {})
            for block in message.get("content", []):
                if block.get("type") == "tool_result":
                    content = block.get("content", "")
                    if not isinstance(content, str):
                        content = json.dumps(content)[:200] if content else ""
                    show_tool_result(content, is_error=block.get("is_error", False))
    elif etype == "result":
        result_text = event.get("result", "")
        if result_text:
            print(f"\n{B}Result:{R} {result_text[:500]}", flush=True)
    elif etype in ("content_block_start", "content_block_delta", "content_block_stop",
                    "message_start", "message_delta", "message_stop"):
        inner = event.get("event", event)
        itype = inner.get("type", etype)
        if itype == "content_block_start":
            block = inner.get("content_block", {})
            if block.get("type") == "tool_use":
                show_tool_use(block.get("name", "?"), block.get("input", {}))
        elif itype == "content_block_delta":
            delta = inner.get("delta", {})
            if delta.get("type") == "text_delta":
                sys.stdout.write(delta.get("text", ""))
                sys.stdout.flush()
