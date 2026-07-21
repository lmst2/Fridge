#!/usr/bin/env python3
"""Fetch one mod portal discussion thread as plain text.

The list scraper only sees titles; the agent needs what people actually wrote.
Output is deliberately plain and unstructured - it is untrusted input that gets
wrapped in explicit markers before any model sees it.

  fetch_thread.py <thread-url> [--maintainer NAME]
"""
import argparse
import html
import re
import sys
import urllib.request

UA = "Mozilla/5.0 (compatible; FridgeModWatcher/1.0; +https://github.com/lmst2/Fridge)"

MSG_RE = re.compile(r'<div class="discussion-message flex.*?(?=<div class="discussion-message flex|'
                    r'<div class="discussion-message-new-info|<div class="discussion-message-editor)', re.S)
AUTHOR_RE = re.compile(r'discussion-message-author[^>]*>(.*?)</', re.S)
BODY_RE = re.compile(r'<div class="discussion-message-body p16">(.*?)</div>', re.S)
TIME_RE = re.compile(r'<span title="([0-9]{4}-[0-9]{2}-[0-9]{2}T[^"]*)"')
TITLE_RE = re.compile(r'<h2[^>]*>\s*(.*?)\s*</h2>', re.S)
TAG_RE = re.compile(r'discussion-message-tag[^>]*>\s*<[^>]*>\s*([^<]+?)\s*<', re.S)
OWNER_RE = re.compile(r'discussion-message-header-owner')


def strip_html(fragment: str) -> str:
    f = re.sub(r'<br\s*/?>', '\n', fragment)
    f = re.sub(r'</p\s*>', '\n\n', f)
    f = re.sub(r'<[^>]+>', '', f)
    f = html.unescape(f)
    f = re.sub(r'\n{3,}', '\n\n', f)
    return f.strip()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--maintainer", default="")
    # The list scrape already knows these; the thread page's own <h2> is the
    # mod title, not the thread title.
    ap.add_argument("--title", default="")
    ap.add_argument("--tag", default="")
    args = ap.parse_args()

    req = urllib.request.Request(args.url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        page = r.read().decode("utf-8", "replace")

    if args.title:
        title = args.title
    else:
        tm = TITLE_RE.search(page)
        title = strip_html(tm.group(1)) if tm else "(untitled)"
    if args.tag:
        tag = args.tag
    else:
        tg = TAG_RE.search(page)
        tag = tg.group(1).strip() if tg else ""

    print(f"Title: {title}")
    if tag:
        print(f"Tag: {tag}")
    print(f"Thread: {args.url}")
    print()

    blocks = MSG_RE.findall(page)
    if not blocks:
        print("ERROR: no messages parsed - the page layout probably changed",
              file=sys.stderr)
        sys.exit(1)

    for i, b in enumerate(blocks, start=1):
        am = AUTHOR_RE.search(b)
        author = strip_html(am.group(1)) if am else "(unknown)"
        bm = BODY_RE.search(b)
        body = strip_html(bm.group(1)) if bm else ""
        tmv = TIME_RE.search(b)
        when = tmv.group(1)[:19] if tmv else ""
        who = f"{author} (mod author)" if OWNER_RE.search(b) else author
        print(f"--- message {i} by {who}{'  ' + when if when else ''} ---")
        print(body if body else "(empty)")
        print()


if __name__ == "__main__":
    main()
