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
| `dry_run` | Build + generate changelog only. No commit/tag/push, no publish. Use this to preview. |

What a full run does, in order:

1. Computes the new version.
2. Collects commit messages since the last `v*` tag.
3. Asks GitHub Models to turn them into Factorio-format changelog bullets.
4. Assembles + **validates** the changelog (`assemble_changelog.py` re-indents the
   model output to exact Factorio format; if the model produced nothing usable it
   falls back to the raw commit list; the build fails if the result is malformed).
5. Writes the new version into `info.json`.
6. Builds `Fridge_<version>.zip` (also uploaded as a run artifact).
7. Commits `info.json` + `changelog.txt`, tags `v<version>`, pushes.
8. Uploads the zip to the mod portal.

**Tip:** run once with `dry_run = true` to eyeball the generated changelog and the
zip contents, then run for real. The portal rejects re-uploading a version that
already exists, so the version must be new on every real run.

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
| `.github/scripts/assemble_changelog.py` | Turn model/commit text into a valid entry and prepend it. |
| `.github/scripts/validate_changelog.py` | Strict Factorio-format validator (also runnable standalone). |
| `.github/scripts/publish_portal.sh` | `init` + `upload` against the mod-portal v2 API. |

## Security

The API key grants publish rights to the mod. If it has ever been pasted into a
chat, email, or shared screen, **rotate it** at <https://factorio.com/profile> and
update the `FACTORIO_MOD_PLATFORM_KEY` secret. Rotating is free and invalidates the
old key.
