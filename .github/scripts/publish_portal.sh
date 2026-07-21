#!/usr/bin/env bash
# Upload a new release of an existing mod to the Factorio mod portal.
#
# Usage: publish_portal.sh <mod-name> <path-to-zip>
# Requires env FACTORIO_MOD_PLATFORM_KEY (a mod-portal API key with upload /
# publish rights). Uses the documented v2 init + upload flow.
set -euo pipefail

MOD="${1:?usage: publish_portal.sh <mod> <zip>}"
ZIP="${2:?usage: publish_portal.sh <mod> <zip>}"
: "${FACTORIO_MOD_PLATFORM_KEY:?FACTORIO_MOD_PLATFORM_KEY is not set (add it as an Actions secret)}"

if [[ ! -f "$ZIP" ]]; then
  echo "::error::zip not found: $ZIP" >&2
  exit 1
fi

API="https://mods.factorio.com/api/v2/mods/releases"

echo "==> init upload for mod '$MOD'"
INIT_JSON="$(curl -sS --fail-with-body \
  -H "Authorization: Bearer ${FACTORIO_MOD_PLATFORM_KEY}" \
  -F "mod=${MOD}" \
  "${API}/init_upload")"
echo "init response: ${INIT_JSON}"

UPLOAD_URL="$(printf '%s' "$INIT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["upload_url"])')"
if [[ -z "$UPLOAD_URL" ]]; then
  echo "::error::no upload_url in init response" >&2
  exit 1
fi

echo "==> uploading $ZIP"
# Capture the body and status separately: curl's --fail-with-body exits before
# the caller sees why, and "HTTP 400" alone is not a diagnosis.
UP_JSON="$(curl -sS -w '\n%{http_code}' \
  -H "Authorization: Bearer ${FACTORIO_MOD_PLATFORM_KEY}" \
  -F "file=@${ZIP}" \
  "${UPLOAD_URL}")"
UP_CODE="$(tail -n1 <<<"$UP_JSON")"
UP_JSON="$(sed '$d' <<<"$UP_JSON")"
echo "upload response (HTTP ${UP_CODE}): ${UP_JSON}"
if [ "$UP_CODE" != "200" ]; then
  echo "::error::portal rejected ${ZIP} with HTTP ${UP_CODE}: ${UP_JSON}"
  exit 1
fi

printf '%s' "$UP_JSON" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if d.get("success"):
    print("==> published successfully")
else:
    sys.exit("::error::portal rejected upload: " + json.dumps(d))
'
