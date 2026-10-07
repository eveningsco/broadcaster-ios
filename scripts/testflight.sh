#!/usr/bin/env bash
# Dispatch the TestFlight workflow for a branch and print the run URL and the
# build number the upload will get. Needs GH_TOKEN with `repo` scope (the
# workflow must already exist on main; see scripts/ci/testflight.yml).
#
#   GH_TOKEN=... scripts/testflight.sh                # current branch
#   GH_TOKEN=... scripts/testflight.sh thread/abc123  # a specific branch
set -euo pipefail
REPO=${REPO:-eveningsco/broadcaster-ios}
REF=${1:-$(git rev-parse --abbrev-ref HEAD)}
API="https://api.github.com/repos/$REPO"
AUTH="Authorization: Bearer ${GH_TOKEN:?set GH_TOKEN (repo scope)}"

code=$(curl -s -o /tmp/testflight-dispatch.txt -w '%{http_code}' -X POST -H "$AUTH" \
  "$API/actions/workflows/testflight.yml/dispatches" -d "{\"ref\":\"$REF\"}")
if [ "$code" != "204" ]; then
  echo "dispatch failed ($code): $(cat /tmp/testflight-dispatch.txt)" >&2
  exit 1
fi

# The run appears a few seconds after the dispatch; find the newest one for REF.
for _ in $(seq 1 15); do
  sleep 2
  run=$(curl -s -H "$AUTH" "$API/actions/workflows/testflight.yml/runs?branch=$REF&per_page=1" \
    | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["workflow_runs"]; print(f"{r[0][\"id\"]} {r[0][\"run_number\"]} {r[0][\"html_url\"]}") if r else ""')
  [ -n "$run" ] && break
done
[ -n "${run:-}" ] || { echo "dispatched, but no run showed up for $REF yet" >&2; exit 1; }
set -- $run
echo "run $1 → $3"
echo "build number will be $((100 + $2)).1 (TestFlight app shows it under Evenings → Previous Builds after ~20–30 min)"
