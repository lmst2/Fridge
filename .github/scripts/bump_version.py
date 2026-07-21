#!/usr/bin/env python3
"""Bump or set the mod version in info.json (Factorio X.Y.Z scheme).

Prints `version=` / `previous=` lines suitable for $GITHUB_OUTPUT.
With --write, persists the new version back into info.json.
"""
import argparse
import json
import re
import sys

VER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--info", default="info.json")
    ap.add_argument("--bump", choices=["patch", "minor", "major"], default="patch")
    ap.add_argument("--custom", default="", help="explicit X.Y.Z; overrides --bump")
    ap.add_argument("--write", action="store_true", help="write result back to info.json")
    args = ap.parse_args()

    with open(args.info, encoding="utf-8") as f:
        data = json.load(f)
    current = str(data["version"]).strip()

    if args.custom.strip():
        new = args.custom.strip()
        if not VER_RE.match(new):
            sys.exit(f"--custom must be X.Y.Z, got {new!r}")
    else:
        m = VER_RE.match(current)
        if not m:
            sys.exit(f"info.json version is not X.Y.Z: {current!r}")
        major, minor, patch = (int(x) for x in m.groups())
        if args.bump == "major":
            major, minor, patch = major + 1, 0, 0
        elif args.bump == "minor":
            minor, patch = minor + 1, 0
        else:
            patch += 1
        new = f"{major}.{minor}.{patch}"

    if args.write:
        data["version"] = new
        with open(args.info, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")

    print(f"version={new}")
    print(f"previous={current}")


if __name__ == "__main__":
    main()
