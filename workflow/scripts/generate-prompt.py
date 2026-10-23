#!/usr/bin/env python3
"""Generate a focused, per-story implementation prompt from a PRD JSON file.

Usage: generate-prompt.py --story US-001 --prd docs/prds/current.json [--prev-notes "..."]

Prints the complete prompt to stdout. ralph.sh pipes this to `claude -p`.

Everything project-specific (quality gate commands, pattern skills, wiki
directory, files that must never be staged) comes from workflow/config.json,
so this file should not need editing when the kit is adopted.
"""

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG_PATH = HERE.parent / "config.json"


def load_config() -> dict:
    try:
        return json.loads(CONFIG_PATH.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warning: cannot read {CONFIG_PATH}: {exc}", file=sys.stderr)
        return {}


def _has_automated_tests(story: dict) -> bool:
    """Does this story need automated tests (vs manual-only verification)?"""
    if "testScope" in story:
        return story["testScope"] != "manual"
    return any(
        c.startswith("Test:") and "manual" not in c.lower()
        for c in story.get("acceptanceCriteria", [])
    )


def _gate_block(cfg: dict, story: dict) -> str:
    """Render the quality-gate command list for this story."""
    gates = cfg.get("qualityGates", {})
    before = [g for g in gates.get("before", []) if isinstance(g, str)]
    after = [g for g in gates.get("after", []) if isinstance(g, str)]
    test_cmd = gates.get("test", "")
    scope = story.get("testScope", "")

    lines = list(before)
    if _has_automated_tests(story) and test_cmd:
        if scope and scope != "manual":
            lines.append(test_cmd.replace("{targets}", scope))
            note = f"Only run the targeted tests ({scope}). The full suite runs at phase review."
        else:
            lines.append(test_cmd.replace("{targets}", "<test files you created or modified>"))
            note = "Only run test files you created or modified, NOT the full suite. The full suite runs at phase review."
    else:
        note = "This story has no automated tests; skip the test command. The full suite runs at phase review."
    lines.extend(after)
    if not lines:
        lines = ["echo 'no quality gates configured in workflow/config.json'"]
    cmds = "\n".join(f"   {c}" for c in lines)
    return f"{cmds}\n   {note}"


def _build_instructions(cfg: dict, story: dict, prd_path: str, story_id: str) -> str:
    automated = _has_automated_tests(story)
    if automated:
        step1 = (
            "1. **Write failing tests FIRST.** For each acceptance criterion that specifies a test,\n"
            "   write the test before writing any implementation code. Run the test to confirm it\n"
            "   fails for the right reason. Only then write the minimum implementation to make it pass."
        )
    else:
        step1 = (
            "1. **This story has no automated tests to write.** Do not invoke a TDD skill and do not\n"
            "   run the full test suite until the quality gate step."
        )

    never_stage = ", ".join(cfg.get("neverStage", [])) or "secrets or generated artifacts"
    suite_notes = cfg.get("testSuiteNotes", "").strip()
    suite_block = f"\n## Test Runner Rules\n{suite_notes}\n" if suite_notes else ""

    return f"""## Instructions

{step1}
2. Implement the remaining acceptance criteria.
   Follow the conventions in CLAUDE.md and the pattern skills listed above.
3. Run quality gates:
{_gate_block(cfg, story)}
4. If quality gates fail, fix the issues and re-run.
   If they still fail after 3 attempts, output <promise>BLOCKED</promise> and stop.
5. If quality gates pass, update {prd_path} (set passes: true for {story_id}).
6. Stage only files you created or modified. Never stage {never_stage}.
   git add <specific files> && git commit -m "{story_id}: brief description

   Include any notes for the next iteration in the commit message body."
7. Do NOT run git checkout, git branch, or git merge. You are on a story branch
   managed by ralph.sh. Commit your changes to the current branch only.

ONLY WORK ON THIS STORY. Do not implement anything else.
{suite_block}
This codebase will outlive you. Every shortcut you take becomes
someone else's burden. Write tests first, write them well, and
leave the codebase better than you found it.

If ALL stories in {prd_path} have passes: true and all quality gates pass,
output <promise>COMPLETE</promise>."""


def _build_wiki_section(cfg: dict, story: dict, cwd: str | None = None) -> str:
    """Inline the story's wikiPages, using the same === header format as the SessionStart hook."""
    wiki_paths = story.get("wikiPages", [])
    if not wiki_paths:
        return ""
    wiki_dir = cfg.get("wikiDir", "docs/wiki")
    base = cwd or os.getcwd()
    chunks = []
    for rel in wiki_paths:
        full = os.path.join(base, wiki_dir, rel)
        if not os.path.isfile(full):
            print(f"warning: wikiPages entry not found: {wiki_dir}/{rel}", file=sys.stderr)
            continue
        with open(full) as f:
            body = f.read()
        chunks.append(f"=== {wiki_dir}/{rel} ===\n{body.rstrip()}\n")
    if not chunks:
        return ""
    return "\n## Wiki Context\n\n" + "\n".join(chunks) + "\n"


def _build_pattern_table(cfg: dict) -> str:
    rows = cfg.get("patternSkills", {}).get("rows", [])
    rows = [r for r in rows if isinstance(r, dict) and r.get("when") and r.get("read")]
    if not rows:
        return ""
    table = "\n".join(f"| {r['when']} | {r['read']} |" for r in rows)
    return f"""
## Coding Patterns

Before writing each type of code, read the relevant skill file and follow its checklist.

| When you're... | Read this first |
|----------------|----------------|
{table}
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate per-story implementation prompt")
    parser.add_argument("--story", required=True, help="Story ID (e.g. US-001)")
    parser.add_argument("--prd", required=True, help="Path to PRD JSON file")
    parser.add_argument("--prev-notes", default="", help="Notes from previous story (optional)")
    args = parser.parse_args()

    cfg = load_config()

    try:
        with open(args.prd) as f:
            prd = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        print(f"Error reading PRD: {exc}", file=sys.stderr)
        sys.exit(1)

    story = next((s for s in prd.get("userStories", []) if s["id"] == args.story), None)
    if not story:
        print(f"Story {args.story} not found in PRD", file=sys.stderr)
        sys.exit(1)

    # @file references are expanded by `claude -p`
    context_files = ["@CLAUDE.md"]
    for cf in prd.get("contextFiles", []) + story.get("contextFiles", []):
        if f"@{cf}" not in context_files:
            context_files.append(f"@{cf}")

    criteria = "\n".join(f"- {c}" for c in story.get("acceptanceCriteria", []))
    story_notes = story.get("notes", "")
    wiki_section = _build_wiki_section(cfg, story)
    prev_section = f"\n## Previous Story Context\n{args.prev_notes}\n" if args.prev_notes else ""
    pattern_table = _build_pattern_table(cfg)
    instructions = _build_instructions(cfg, story, args.prd, args.story)

    prompt = f"""{" ".join(context_files)}

You are implementing {args.story}: {story["title"]}

{story.get("description", "")}

## Acceptance Criteria
{criteria}

## Story Notes
{story_notes}
{wiki_section}{prev_section}{pattern_table}
{instructions}
"""
    print(prompt)


if __name__ == "__main__":
    main()
