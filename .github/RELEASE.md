# Releasing to the Factorio Mod Portal

This repo ships a **manual** GitHub Actions pipeline that packages the mod,
bumps the version, writes a changelog entry (drafted by an LLM), tags the
release, and uploads it to the [Factorio mod portal](https://mods.factorio.com/).

Workflow file: [`.github/workflows/release.yml`](workflows/release.yml)

## Setup

The only required secret is **`FACTORIO_MOD_PLATFORM_KEY`** — a mod-portal API key
with upload/publish rights, stored under
**Settings → Secrets and variables → Actions**. It is encrypted, only decrypted on
the runner, and masked in logs.

> The changelog LLM step uses **GitHub Models** via the built-in `GITHUB_TOKEN`
> (`permissions: models: read`) — no extra key needed.

Factorio requires the changelog file to be named **`changelog.txt`** (lowercase).
This repo previously used `Changelog.txt`; it has been converted to the official
Factorio format and renamed. Don't re-add the capitalised name.

## Running a release

**Actions tab → “Release to Factorio Mod Portal” → Run workflow**, then choose:

| Input | Meaning |
|-------|---------|
| `bump` | `patch` / `minor` / `major` — how to raise the version from `info.json`. |
| `custom_version` | Exact version like `0.3.0`. Overrides `bump` when set. |
| `publish_to_portal` | Upload the built zip to the portal (default on). |
| `skip_changelog` | Ship `changelog.txt` exactly as committed — no entry is generated. Use it when you've hand-written the entry. |
| `dry_run` | Build + generate changelog only. No commit/tag/push, no publish. Use this to preview. |

What a full run does, in order:

1. Computes the new version.
2. Collects commit messages since the **changelog baseline** (see below).
3. Asks GitHub Models to turn them into Factorio-format changelog bullets,
   crediting external contributors with `(thanks @handle)`.
4. Assembles + **validates** the changelog (`assemble_changelog.py` re-indents the
   model output to exact Factorio format; if the model produced nothing usable it
   falls back to the raw commit list; the build fails if the result is malformed).
5. Writes the new version into `info.json`.
6. Builds `Fridge_<version>.zip` (also uploaded as a run artifact).
7. Commits `info.json` + `changelog.txt`, tags `v<version>`, pushes.
8. Uploads the zip to the mod portal.

**Tip:** run once with `dry_run = true` to eyeball the generated changelog and the
zip contents, then run for real. The portal rejects uploading a version that is
already published, so each real run needs a new version — but if you delete a
release on the portal first, that same version number can be re-uploaded (this
was verified when 0.3.0 was re-published to add a contributor credit).

## The changelog baseline

**We write the changelog and we decide the version number.** The baseline is our
last release — the newest `v*` tag — and *everything* merged since then belongs
in the new entry, contributors' pull requests included.

### When a contributor writes their own changelog

Contributors often add a changelog entry inside their PR, under a version number
we never published. That entry is **reference material, not a finished entry**:

1. `extract_drafts.py` lifts every entry above the last released version out of
   `changelog.txt` — so a made-up version never survives as an orphan that
   matches no release on the portal.
2. Their text is handed to the model as reference for wording and detail, to be
   rewritten in our voice and merged with the rest of the release.
3. They get credited (see below).

So a contributor's notes improve the entry we write; they never replace it, and
their work is never dropped from the release notes.

### Crediting contributors

`collect_changes.sh` reads `Merge pull request #N from <user>/<branch>` commits in
range to find contributors, and attributes every commit `[by Author]` so the
model can match a credit to the right change. It appends `(thanks @handle)` to
the bullet(s) describing each contributor's work, crediting **all** of them.

Maintainer handles are passed in and filtered out, as are bots and AI coding
agents (`claude*`, `gpt*`, `copilot*`, `cursor*`, `dependabot*`, `*[bot]`, …) —
they appear as commit authors and fork owners but must never be thanked.

### If the model fails

The entry falls back, in order, to: the model's output → the contributor's draft
notes → the raw commit subjects. The drafts step matters because those notes were
already removed from `changelog.txt`, so folding them back in is what keeps a
model outage from silently losing a contributor's detail.

## Changelog: how the LLM part works

- Model: `openai/gpt-4o` through GitHub Models (swap the `model:` line in the
  workflow for `openai/gpt-4o-mini` to save quota, or another catalog model).
- It only drafts the **bullet content**; the `Version:`/`Date:`/separator header is
  generated deterministically in code, never by the model.
- `.github/scripts/validate_changelog.py` gates the release, so a bad draft can
  never ship a broken changelog.
- Prefer to hand-write an entry? Run with `dry_run`, or just edit `changelog.txt`
  afterwards.

## Scripts

| File | Role |
|------|------|
| `.github/scripts/bump_version.py` | Compute / write the `X.Y.Z` version in `info.json`. |
| `.github/scripts/collect_changes.sh` | Pick the baseline, gather commits, contributors and contributor drafts. |
| `.github/scripts/extract_drafts.py` | Lift unreleased draft entries out of `changelog.txt` for reuse as reference. |
| `.github/scripts/assemble_changelog.py` | Turn model/commit text into a valid entry and prepend it. |
| `.github/scripts/validate_changelog.py` | Strict Factorio-format validator (also runnable standalone). |
| `.github/scripts/publish_portal.sh` | `init` + `upload` against the mod-portal v2 API. |

## Security

The API key grants publish rights to the mod. If it has ever been pasted into a
chat, email, or shared screen, **rotate it** at <https://factorio.com/profile> and
update the `FACTORIO_MOD_PLATFORM_KEY` secret. Rotating is free and invalidates the
old key.
