#!/usr/bin/env bash
# Work out what the next changelog entry should describe, and who to credit.
#
# The baseline is the MOST RECENT of:
#   * the commit that last touched changelog.txt - a contributor may have
#     documented their own work in their PR, and we must not restate it
#   * the last v* release tag - a skip_changelog release edits no changelog,
#     so the tag is the newer marker in that case
#
# Writes:
#   commits.txt      raw subject lines (fallback if the model fails)
#   contributors.txt external contributors merged in this range
#   user_prompt.txt  the prompt handed to the model
set -euo pipefail

VERSION="${1:?usage: collect_changes.sh <version> [maintainer-handle ...]}"
shift
MAINTAINERS=("$@")

CL_COMMIT="$(git log -1 --format=%H -- changelog.txt 2>/dev/null || true)"
LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
TAG_COMMIT=""
if [ -n "$LAST_TAG" ]; then
  TAG_COMMIT="$(git rev-list -n1 "$LAST_TAG" 2>/dev/null || true)"
fi

BASE=""
WHY=""
if [ -n "$CL_COMMIT" ] && [ -n "$TAG_COMMIT" ]; then
  if git merge-base --is-ancestor "$CL_COMMIT" "$TAG_COMMIT"; then
    BASE="$TAG_COMMIT"; WHY="release tag ${LAST_TAG}"
  else
    BASE="$CL_COMMIT";  WHY="last changelog.txt edit"
  fi
elif [ -n "$CL_COMMIT" ]; then
  BASE="$CL_COMMIT"; WHY="last changelog.txt edit"
elif [ -n "$TAG_COMMIT" ]; then
  BASE="$TAG_COMMIT"; WHY="release tag ${LAST_TAG}"
fi

if [ -n "$BASE" ]; then
  echo "Baseline: $(git rev-parse --short "$BASE") (${WHY})"
  RANGE=("${BASE}..HEAD")
else
  echo "No baseline found; using full history"
  RANGE=()
fi

git log "${RANGE[@]+"${RANGE[@]}"}" --no-merges --pretty=format:'%s' > commits.txt || true
head -n 100 commits.txt > .commits.tmp && mv .commits.tmp commits.txt

# External contributors, taken from "Merge pull request #N from <user>/<branch>"
git log "${RANGE[@]+"${RANGE[@]}"}" --merges --pretty=format:'%s' 2>/dev/null \
  | sed -nE 's|^Merge pull request #[0-9]+ from ([^/]+)/.*$|\1|p' \
  | sort -u > .all_contributors.tmp || true
: > contributors.txt
while read -r handle; do
  [ -z "$handle" ] && continue
  skip=""
  for m in "${MAINTAINERS[@]+"${MAINTAINERS[@]}"}"; do
    if [ "${handle,,}" = "${m,,}" ]; then skip=1; break; fi
  done
  [ -z "$skip" ] && echo "$handle" >> contributors.txt
done < .all_contributors.tmp
rm -f .all_contributors.tmp

# Commit subjects with author attribution, so the model can match a credit to
# the change that contributor actually made.
git log "${RANGE[@]+"${RANGE[@]}"}" --no-merges --pretty=format:'%s [by %an]' > .attributed.tmp || true
head -n 100 .attributed.tmp > attributed_commits.txt && rm -f .attributed.tmp

echo "Commits considered:"; cat commits.txt; echo
echo "External contributors:"; cat contributors.txt; echo

{
  echo "Mod: Cold Chain Logistics (Fridge)"
  echo "New version being released: ${VERSION}"
  echo ""
  echo "Summarize the following commit messages into a player-facing changelog."
  echo ""
  echo "Commit messages (with author attribution):"
  cat attributed_commits.txt
  echo
  if [ -s contributors.txt ]; then
    echo ""
    echo "Pull requests from external contributors were merged in this range, by:"
    while read -r h; do echo "- @${h}"; done < contributors.txt
    echo ""
    echo "If (and only if) one of those contributors authored a commit listed"
    echo "above, append \" (thanks @handle)\" to the bullet describing that"
    echo "change. If their work is not among the commits above, add nothing -"
    echo "it was already documented in an earlier changelog entry. Never invent"
    echo "a bullet just to credit someone."
  fi
} > user_prompt.txt
