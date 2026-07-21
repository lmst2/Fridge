#!/usr/bin/env python3
"""Turn changed portal discussion threads into GitHub issues.

Reads the JSON emitted by watch_discussion.py on stdin. One issue per portal
thread, matched by the thread id recorded in the issue body, so a thread that
gets several replies over time keeps accumulating comments on one issue rather
than spawning duplicates.
"""
import json
import subprocess
import sys

MARKER = "portal-thread-id:"

# Portal tag -> issue labels. Everything also gets portal-feedback.
TAG_LABELS = {
    "Bugs": ["bug"],
    "Ideas & suggestions": ["enhancement"],
    "General": [],
    "Announcements": [],
}


def gh(*args, check=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"gh {' '.join(args)} failed: {r.stderr}", file=sys.stderr)
    return r.stdout.strip(), r.returncode


def find_issue(thread_id):
    out, _ = gh("issue", "list", "--state", "all", "--limit", "200",
                "--search", thread_id, "--json", "number,body")
    try:
        for it in json.loads(out or "[]"):
            if f"{MARKER} {thread_id}" in (it.get("body") or ""):
                return it["number"]
    except json.JSONDecodeError:
        pass
    return None


def body_for(t):
    return "\n".join([
        f"**Portal thread:** {t['url']}",
        f"**Opened by:** `{t['author']}`  |  **Tag:** {t['tag'] or 'n/a'}  "
        f"|  **Replies:** {t['replies']}",
        f"**Last message:** `{t['last_message_by']}` at {t['last_message_at']}",
        "",
        "---",
        "",
        "_Filed automatically from the Factorio mod portal, which has no API "
        "for discussions. Read the thread at the link above — the portal page "
        "is the source of truth._",
        "",
        f"<!-- {MARKER} {t['id']} -->",
    ])


def main():
    changed = json.load(sys.stdin)
    if not changed:
        print("No changed threads.")
        return

    for t in changed:
        num = find_issue(t["id"])
        if num:
            note = (f"New activity on the portal thread — last message by "
                    f"`{t['last_message_by']}` at {t['last_message_at']} "
                    f"({t['replies']} replies).\n\n{t['url']}")
            gh("issue", "comment", str(num), "--body", note)
            gh("issue", "reopen", str(num), check=False)
            print(f"commented on #{num}: {t['title']}")
            continue

        labels = ["portal-feedback"] + TAG_LABELS.get(t["tag"], [])
        args = ["issue", "create",
                "--title", f"[portal] {t['title']}",
                "--body", body_for(t)]
        for l in labels:
            args += ["--label", l]
        out, rc = gh(*args)
        print(f"created {out}" if rc == 0 else f"FAILED to create for {t['title']}")


if __name__ == "__main__":
    main()
