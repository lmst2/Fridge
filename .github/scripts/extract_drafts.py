#!/usr/bin/env python3
"""Lift unreleased draft entries out of changelog.txt.

A contributor often writes their own changelog entry inside their PR, picking
a version number we never published. We decide versions and we write the
entry, so those drafts must not survive as orphan versions in the file.

Everything above the entry for the last released version is treated as a
draft: it is removed from changelog.txt and written to --out, where it becomes
reference material for the model writing the real entry.

If the last released version isn't found in the file, nothing is touched.
"""
import argparse
import re
import sys

SEP_RE = re.compile(r"^-{3,}$")
VERSION_RE = re.compile(r"^Version:\s*(\S+)\s*$")


def split_entries(text):
    """Return [(version, block_text), ...] in file order."""
    lines = text.splitlines(keepends=True)
    entries, cur, ver = [], [], None
    for i, line in enumerate(lines):
        if SEP_RE.match(line.rstrip("\n")):
            if cur:
                entries.append((ver, "".join(cur)))
            cur, ver = [line], None
        else:
            m = VERSION_RE.match(line.rstrip("\n"))
            if m and ver is None:
                ver = m.group(1)
            cur.append(line)
    if cur:
        entries.append((ver, "".join(cur)))
    return entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--changelog", default="changelog.txt")
    ap.add_argument("--last-released", required=True,
                    help="version of the newest published release, e.g. 0.3.0")
    ap.add_argument("--out", default="drafts.txt")
    args = ap.parse_args()

    last = args.last_released.strip().lstrip("v")
    with open(args.changelog, encoding="utf-8") as f:
        text = f.read()

    entries = split_entries(text)
    idx = next((i for i, (v, _) in enumerate(entries) if v == last), None)

    if idx is None:
        print(f"Last released version {last!r} not found in {args.changelog}; "
              f"leaving the file untouched.")
        open(args.out, "w", encoding="utf-8").close()
        return
    if idx == 0:
        print("No unreleased draft entries.")
        open(args.out, "w", encoding="utf-8").close()
        return

    drafts = entries[:idx]
    kept = entries[idx:]

    with open(args.out, "w", encoding="utf-8") as f:
        for ver, block in drafts:
            # strip separator / Version / Date lines - only the content matters
            for line in block.splitlines():
                if SEP_RE.match(line) or VERSION_RE.match(line) or line.startswith("Date:"):
                    continue
                f.write(line + "\n")

    with open(args.changelog, "w", encoding="utf-8") as f:
        f.write("".join(block for _, block in kept))

    versions = ", ".join(v or "?" for v, _ in drafts)
    print(f"Lifted {len(drafts)} unreleased draft entry(ies) [{versions}] "
          f"into {args.out}; they will be folded into the new entry.")


if __name__ == "__main__":
    main()
