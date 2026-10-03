#!/usr/bin/env bash
# Run the test suite in Docker. Extra arguments go to busted, e.g.
#   bash spec/run.sh --filter="Space Age"
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
docker build -q -t fridge-tests -f "$root/spec/Dockerfile" "$root/spec" >/dev/null
# MSYS_NO_PATHCONV stops Git Bash on Windows from rewriting /mod into a host path.
MSYS_NO_PATHCONV=1 docker run --rm -v "$root:/mod" fridge-tests "$@"
