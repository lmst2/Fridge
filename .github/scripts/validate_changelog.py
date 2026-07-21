#!/usr/bin/env python3
"""Validate a Factorio-format changelog.txt.

The Factorio mod portal / in-game parser is strict about structure. This
checks the rules that actually break parsing:

  * separator lines are runs of dashes (>= 3; we emit 99)
  * each block starts `Version: X.Y.Z`
  * an optional `Date:` line follows the version, with no indent
  * category headers are indented exactly 2 spaces and end with `:`
  * entries are indented exactly 4 spaces and start with `- `
  * entry continuation lines are indented 6+ spaces
  * no tab characters anywhere
  * every category has at least one entry

Exit code is non-zero (and errors are printed) when the file is invalid,
so it can gate a release workflow.
"""
import re
import sys

SEP_RE = re.compile(r"^-{3,}$")
VERSION_RE = re.compile(r"^Version: \d+\.\d+\.\d+\s*$")
DATE_RE = re.compile(r"^Date: .+$")
CATEGORY_RE = re.compile(r"^  (\S.*):$")
ENTRY_RE = re.compile(r"^    - \S.*$")
CONT_RE = re.compile(r"^      \S.*$")


def validate(path):
    errors = []
    with open(path, encoding="utf-8") as f:
        lines = [ln.rstrip("\n") for ln in f]

    while lines and lines[-1].strip() == "":
        lines.pop()
    if not lines:
        return [f"{path}: file is empty"]

    state = "expect_separator"
    current_category_has_entry = True  # no open category yet
    open_category_line = 0

    for i, raw in enumerate(lines, start=1):
        if "\t" in raw:
            errors.append(f"line {i}: contains a TAB character (use spaces)")

        if raw.strip() == "":
            continue

        if state == "expect_separator":
            if SEP_RE.match(raw):
                state = "expect_version"
            else:
                errors.append(f"line {i}: expected a separator line of dashes, got: {raw!r}")
            continue

        if state == "expect_version":
            if VERSION_RE.match(raw):
                state = "expect_date_or_body"
            else:
                errors.append(f"line {i}: expected 'Version: X.Y.Z', got: {raw!r}")
                state = "expect_date_or_body"
            continue

        if SEP_RE.match(raw):
            if not current_category_has_entry:
                errors.append(f"line {open_category_line}: category has no entries")
            state = "expect_version"
            current_category_has_entry = True
            continue

        if state == "expect_date_or_body" and DATE_RE.match(raw):
            state = "in_body"
            continue

        state = "in_body"

        if CATEGORY_RE.match(raw):
            if not current_category_has_entry:
                errors.append(f"line {open_category_line}: category has no entries")
            current_category_has_entry = False
            open_category_line = i
        elif ENTRY_RE.match(raw):
            current_category_has_entry = True
        elif CONT_RE.match(raw):
            pass  # continuation of the previous entry
        else:
            errors.append(
                f"line {i}: unexpected line (need 2-space category ending ':', "
                f"4-space '- entry', or 6-space continuation): {raw!r}"
            )

    if state == "in_body" and not current_category_has_entry:
        errors.append(f"line {open_category_line}: category has no entries")

    return errors


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "changelog.txt"
    errors = validate(path)
    if errors:
        print(f"INVALID changelog: {path}", file=sys.stderr)
        for e in errors:
            print("  - " + e, file=sys.stderr)
        sys.exit(1)
    print(f"OK: {path} is a valid Factorio changelog")


if __name__ == "__main__":
    main()
