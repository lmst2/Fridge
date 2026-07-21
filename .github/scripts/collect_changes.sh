#!/usr/bin/env bash
# Work out what the next changelog entry should describe, and who to credit.
#
# The baseline is our last release (the newest v* tag): everything published
# since then belongs in the new entry, including contributors' pull requests.
#
# A contributor may have written their own changelog entry inside their PR,
# under a version number we never released. We decide versions and we write
# the entry, so those drafts are lifted out of changelog.txt and handed to the
# model as reference material instead of surviving as orphan versions.
#
# Writes:
#   commits.txt            raw subject lines (fallback if the model fails)
#   attributed_commits.txt subjects with "[by Author]" attribution
#   contributors.txt       human external contributors in this range
#   drafts.txt             contributor-written changelog text (reference)
#   user_prompt.txt        the prompt handed to the model
set -euo pipefail

VERSION="${1:?usage: collect_changes.sh <version> [maintainer-handle ...]}"
shift
MAINTAINERS=("$@")

LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$LAST_TAG" ]; then
  echo "Baseline: last release ${LAST_TAG}"
  RANGE=("${LAST_TAG}..HEAD")
else
  echo "No release tag yet; using full history"
  RANGE=()
fi

git log "${RANGE[@]+"${RANGE[@]}"}" --no-merges --pretty=format:'%s' > commits.txt || true
head -n 100 commits.txt > .t && mv .t commits.txt

git log "${RANGE[@]+"${RANGE[@]}"}" --no-merges --pretty=format:'%s [by %an]' > .a || true
head -n 100 .a > attributed_commits.txt && rm -f .a

# Credit real people only. Bots and AI coding agents never get thanked, even
# though they show up as commit authors and branch owners.
is_bot() {
  case "${1,,}" in
    *'[bot]'*|*-bot|bot|dependabot*|renovate*|github-actions*|*'actions-user'*) return 0 ;;
    claude*|*anthropic*|cursor*|gpt*|chatgpt*|openai*|codex*|copilot*|*-copilot|devin*|codeium*|windsurf*|aider*) return 0 ;;
  esac
  return 1
}

git log "${RANGE[@]+"${RANGE[@]}"}" --merges --pretty=format:'%s' 2>/dev/null \
  | sed -nE 's|^Merge pull request #[0-9]+ from ([^/]+)/.*$|\1|p' \
  | sort -u > .all || true
: > contributors.txt
while read -r handle; do
  [ -z "$handle" ] && continue
  skip=""
  for m in "${MAINTAINERS[@]+"${MAINTAINERS[@]}"}"; do
    if [ "${handle,,}" = "${m,,}" ]; then skip=1; break; fi
  done
  if [ -z "$skip" ] && is_bot "$handle"; then
    echo "Skipping non-human contributor: ${handle}"
    skip=1
  fi
  [ -z "$skip" ] && echo "$handle" >> contributors.txt
done < .all
rm -f .all

# Lift any contributor-written draft entries out of the changelog
: > drafts.txt
if [ -n "$LAST_TAG" ]; then
  python3 "$(dirname "$0")/extract_drafts.py" \
    --changelog changelog.txt \
    --last-released "${LAST_TAG#v}" \
    --out drafts.txt
fi

echo "Commits considered:"; cat commits.txt; echo
echo "External contributors:"; cat contributors.txt; echo

{
  echo "Mod: Cold Chain Logistics (Fridge)"
  echo "New version being released: ${VERSION}"
  echo ""
  echo "Write the changelog entry for this release."
  echo ""
  echo "Commit messages (with author attribution):"
  cat attributed_commits.txt
  echo
  if [ -s drafts.txt ]; then
    echo ""
    echo "Notes a contributor wrote about their own work in their pull request."
    echo "Use them as reference for wording and detail. Do NOT copy their"
    echo "version numbers or headings - we set the version. Rewrite in our"
    echo "voice and merge with everything else in this release:"
    cat drafts.txt
    echo
  fi
  if [ -s contributors.txt ]; then
    echo ""
    echo "This release includes pull requests from these external contributors:"
    while read -r h; do echo "- @${h}"; done < contributors.txt
    echo ""
    echo "Append \" (thanks @handle)\" to the bullet(s) describing each one's"
    echo "work. Credit every contributor listed; if one bullet covers work by"
    echo "several of them, thank them all on it. Use the [by Author] attribution"
    echo "to match a contributor to their change."
    echo "Credit only the human handles listed above. Never thank an AI coding"
    echo "assistant or bot (Claude, GPT, Copilot, Cursor, Devin, dependabot,"
    echo "github-actions, ...) even if one appears as a commit author."
  fi
} > user_prompt.txt
