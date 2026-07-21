# Mod portal discussion watch

The Factorio mod portal has **no API, no RSS and no webhooks** for discussions —
only a server-rendered HTML page. This mirrors that page into GitHub issues so
feedback lands next to the code instead of only on the portal.

Workflow: [`.github/workflows/portal-watch.yml`](workflows/portal-watch.yml) —
runs every 6 hours, and on demand from the Actions tab.

## How it works

1. `watch_discussion.py` fetches `mods.factorio.com/mod/Fridge/discussion` and
   parses each `<tr class="discussion-list-message">`.
   Change detection uses the **exact ISO timestamp** the portal puts in the
   `title` attribute of each relative-time span — not the `"3 hours ago"` text
   and not the reply count.
2. It diffs against `.github/state/discussion.json` (committed, so the snapshot
   survives between runs) and emits only new threads and new replies.
   Replies whose last message is the maintainer's are ignored — no issue for
   our own answers.
3. `sync_issues.py` files one issue per thread, tagging it `portal-feedback`
   plus `bug` / `enhancement` from the portal tag. The portal thread id is
   embedded in the issue body as `<!-- portal-thread-id: … -->`, so later
   replies **comment on the existing issue** instead of opening duplicates
   (and reopen it if it had been closed).

The portal page stays the source of truth: issues carry a link, not a copy of
the discussion.

## Operating it

- **First run** used a committed baseline of the 31 existing threads, so no
  backlog was filed. Only activity from that point on becomes an issue.
- **Re-baseline** (e.g. after changing the parser): run the workflow with
  `baseline_only = true` to refresh the snapshot without filing anything.
- **If the layout changes**, `watch_discussion.py` exits non-zero rather than
  silently reporting "no threads", so the run fails loudly instead of going
  quiet.

## Limits worth knowing

- **Posting replies is not possible from automation.** The portal exposes no
  API for it, and `factorio.com/login` returns `403` to non-browser clients, so
  even a stored session cookie may be blocked by bot protection. Replies are
  written by hand on the portal.
- Only the thread *list* is scraped, not message bodies. Anything that needs
  the full conversation should read the linked thread.
