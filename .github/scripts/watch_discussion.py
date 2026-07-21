#!/usr/bin/env python3
"""Scrape the mod portal discussion list and report what changed.

The portal exposes no API, no RSS and no webhooks for discussions, so we poll
the server-rendered HTML. Threads are matched by their portal id; activity is
detected from the ISO timestamp the portal puts in the title attribute of each
relative-time span, which is exact and stable, unlike the "2 hours ago" text.

  python3 watch_discussion.py --mod Fridge --state .github/state/discussion.json

Prints a JSON list of changed threads on stdout and updates the state file.
"""
import argparse
import html
import json
import os
import re
import sys
import urllib.request

UA = "Mozilla/5.0 (compatible; FridgeModWatcher/1.0; +https://github.com/lmst2/Fridge)"

# Threads are table rows, and each carries absolute ISO timestamps in the
# title attribute of its relative-time spans - far better change signals than
# the "3 hours ago" text or a reply count.
BLOCK_RE = re.compile(
    r'<tr class="discussion-list-message">(.*?)</tr>', re.S)
HREF_RE = re.compile(r'href="(/mod/[^/]+/discussion/([0-9a-f]+))"')
TITLE_RE = re.compile(r'<a href="/mod/[^/]+/discussion/[0-9a-f]+"[^>]*>([^<]*)</a>')
USER_RE = re.compile(r'href="/user/([^"]+)"')
TIME_RE = re.compile(r'<span title="([0-9]{4}-[0-9]{2}-[0-9]{2}T[^"]*)"')
TAGCELL_RE = re.compile(r'<td class="text-center sm-none">\s*([^<]+?)\s*</td>', re.S)
REPLIES_RE = re.compile(r'<div class="text-right">\s*(\d+)\s*<i class="fa fa-comments">', re.S)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def parse(page_html, mod):
    threads = []
    for block in BLOCK_RE.findall(page_html):
        m = HREF_RE.search(block)
        if not m:
            continue
        url, tid = m.group(1), m.group(2)
        tm = TITLE_RE.search(block)
        title = html.unescape(tm.group(1)).strip() if tm else "(untitled)"

        users = USER_RE.findall(block)
        times = TIME_RE.findall(block)
        tagcell = TAGCELL_RE.search(block)
        rep = REPLIES_RE.search(block)

        threads.append({
            "id": tid,
            "title": title,
            "url": f"https://mods.factorio.com{url}",
            "author": html.unescape(users[0]) if users else "",
            "tag": html.unescape(tagcell.group(1)).strip() if tagcell else "",
            "replies": int(rep.group(1)) if rep else 0,
            "posted_at": times[0] if times else "",
            "last_message_by": html.unescape(users[-1]) if len(users) > 1 else "",
            "last_message_at": times[-1] if times else "",
        })
    return threads


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mod", default="Fridge")
    ap.add_argument("--state", default=".github/state/discussion.json")
    ap.add_argument("--maintainer", default="", help="ignore threads whose last message is ours")
    ap.add_argument("--dump", action="store_true", help="just print what was parsed")
    args = ap.parse_args()

    page = fetch(f"https://mods.factorio.com/mod/{args.mod}/discussion")
    threads = parse(page, args.mod)
    if not threads:
        print("ERROR: parsed 0 threads - the page layout probably changed",
              file=sys.stderr)
        sys.exit(1)

    if args.dump:
        for t in threads:
            print(f"[{t['tag'] or '-':<22}] {t['replies']:>3} replies  "
                  f"{t['title'][:58]:<60} by {t['author']:<18} last: {t['last_message_by']}")
        print(f"\ntotal: {len(threads)} threads")
        return

    old = {}
    if os.path.exists(args.state):
        with open(args.state, encoding="utf-8") as f:
            old = {t["id"]: t for t in json.load(f).get("threads", [])}

    changed = []
    for t in threads:
        prev = old.get(t["id"])
        if prev is None:
            t["change"] = "new_thread"
            changed.append(t)
        elif t["last_message_at"] != prev.get("last_message_at"):
            # someone replied - but not if the last word was ours
            if args.maintainer and t["last_message_by"].lower() == args.maintainer.lower():
                continue
            t["change"] = "new_reply"
            changed.append(t)

    os.makedirs(os.path.dirname(args.state) or ".", exist_ok=True)
    with open(args.state, "w", encoding="utf-8") as f:
        json.dump({"threads": threads}, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(json.dumps(changed, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
