#!/usr/bin/env python3
"""Assemble a new Factorio changelog entry and prepend it to changelog.txt.

Takes free-form category/bullet text (typically produced by an LLM) plus a
fallback commit log. It re-emits the content with exact Factorio indentation
so the result always parses, regardless of how sloppy the model output was.
The Version/Date header is generated here (never trusted to the model) and
the whole file is validated before we're done.

Usage:
  assemble_changelog.py --version 0.3.0 --date 2026-07-21 \
      --ai-file ai.txt --commits-file commits.txt --changelog changelog.txt
"""
import argparse
import datetime
import os
import re
import sys

import validate_changelog

SEP = "-" * 99

# Map common synonyms to canonical Factorio categories. Unknown names are
# kept as-is (the portal accepts arbitrary category names).
CANON = {
    "bugfix": "Bugfixes",
    "bugfixes": "Bugfixes",
    "bug fix": "Bugfixes",
    "bug fixes": "Bugfixes",
    "fix": "Bugfixes",
    "fixes": "Bugfixes",
    "feature": "Features",
    "features": "Features",
    "major feature": "Major Features",
    "major features": "Major Features",
    "minor feature": "Minor Features",
    "minor features": "Minor Features",
    "change": "Changes",
    "changes": "Changes",
    "modification": "Changes",
    "modifications": "Changes",
    "graphic": "Graphics",
    "graphics": "Graphics",
    "optimization": "Optimizations",
    "optimizations": "Optimizations",
    "balance": "Balancing",
    "balancing": "Balancing",
    "locale": "Locale",
    "translation": "Translation",
    "gui": "Gui",
}


def canon_category(name):
    key = name.strip().rstrip(":").strip().lower()
    return CANON.get(key, name.strip().rstrip(":").strip())


def parse_blocks(text):
    """Parse loose 'Category:' + '- entry' text into ordered categories."""
    blocks = []
    current = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        stripped = line.strip()
        # strip markdown fences / stray formatting
        if stripped.startswith("```"):
            continue
        # A category header: a line ending in ':' that is not a bullet
        if stripped.endswith(":") and not re.match(r"^[-*]", stripped):
            current = (canon_category(stripped), [])
            blocks.append(current)
            continue
        # A bullet entry
        m = re.match(r"^[-*]\s+(.*)$", stripped)
        if m:
            entry = m.group(1).strip()
            if not entry:
                continue
            if current is None:
                current = ("Changes", [])
                blocks.append(current)
            current[1].append(entry)
            continue
        # Loose text with no bullet -> treat as an entry
        if current is None:
            current = ("Changes", [])
            blocks.append(current)
        current[1].append(stripped)
    return [(c, e) for (c, e) in blocks if e]


def commits_fallback(text):
    entries = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return [("Changes", entries)] if entries else []


def render_entry(version, date, blocks):
    out = [SEP, f"Version: {version}", f"Date: {date}"]
    for category, entries in blocks:
        out.append(f"  {category}:")
        for e in entries:
            out.append(f"    - {e}")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--ai-file", default="")
    ap.add_argument("--drafts-file", default="",
                    help="contributor-written entry text, used if the model fails")
    ap.add_argument("--commits-file", default="")
    ap.add_argument("--changelog", default="changelog.txt")
    args = ap.parse_args()

    ai_text = ""
    if args.ai_file and os.path.exists(args.ai_file):
        with open(args.ai_file, encoding="utf-8") as f:
            ai_text = f.read()

    blocks = parse_blocks(ai_text)
    if blocks:
        print("Using model-generated changelog content.")
    # The drafts were lifted out of changelog.txt, so if the model failed we
    # must fold them back in here or the contributor's notes are simply lost.
    if not blocks and args.drafts_file and os.path.exists(args.drafts_file):
        with open(args.drafts_file, encoding="utf-8") as f:
            blocks = parse_blocks(f.read())
        if blocks:
            print("Model output unusable; falling back to contributor draft notes.")
    if not blocks and args.commits_file and os.path.exists(args.commits_file):
        print("Model output unusable; falling back to raw commit list.")
        with open(args.commits_file, encoding="utf-8") as f:
            blocks = commits_fallback(f.read())

    if not blocks:
        blocks = [("Changes", ["Maintenance release"])]

    entry = render_entry(args.version, args.date, blocks)

    existing = ""
    if os.path.exists(args.changelog):
        with open(args.changelog, encoding="utf-8") as f:
            existing = f.read()

    with open(args.changelog, "w", encoding="utf-8") as f:
        f.write(entry)
        if existing.strip():
            f.write(existing.lstrip("\n"))

    errors = validate_changelog.validate(args.changelog)
    if errors:
        print("Generated changelog is INVALID:", file=sys.stderr)
        for e in errors:
            print("  - " + e, file=sys.stderr)
        sys.exit(1)

    print(f"Prepended entry for {args.version} to {args.changelog}")
    print("---- new entry ----")
    print(entry)


if __name__ == "__main__":
    main()
